#!/usr/bin/env bash
#
# Smoke test a built image.
#
# Usage: smoke.sh IMAGE
#
# Starts the container, then verifies that:
#   - the web GUI answers on port 5800,
#   - MCP rejects requests without a valid token (401),
#   - MCP initialize succeeds with the token and reports browseros-neo,
#   - MCP tools/list returns tools.

set -euo pipefail

IMAGE="${1:?usage: smoke.sh IMAGE}"
NAME="browseros-neo-smoke-$$"
# 64 hex characters, the same shape as `openssl rand -hex 32`.
TOKEN="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
TIMEOUT="${SMOKE_TIMEOUT:-180}"

cleanup() {
    status=$?
    if [ "${status}" -ne 0 ]; then
        echo "---- container logs ----"
        docker logs "${NAME}" 2>&1 | tail -n 200 || true
    fi
    docker rm -f "${NAME}" >/dev/null 2>&1 || true
    exit "${status}"
}
trap cleanup EXIT

docker run -d --name "${NAME}" \
    --shm-size 2g \
    --security-opt seccomp=unconfined \
    -e MCP_AUTH_TOKEN="${TOKEN}" \
    -p 127.0.0.1::5800 \
    -p 127.0.0.1::9300 \
    "${IMAGE}" >/dev/null

WEB_PORT="$(docker port "${NAME}" 5800/tcp | head -n1 | sed 's/.*://')"
MCP_PORT="$(docker port "${NAME}" 9300/tcp | head -n1 | sed 's/.*://')"
WEB_URL="http://127.0.0.1:${WEB_PORT}"
MCP_URL="http://127.0.0.1:${MCP_PORT}/mcp"

INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}'

mcp() {
    # mcp <token> <body> [extra curl args...]
    local token="$1" body="$2"
    shift 2
    curl -sS -m 15 \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -d "${body}" "$@" "${MCP_URL}"
}

echo "Waiting for the web GUI (${WEB_URL})..."
deadline=$((SECONDS + TIMEOUT))
until [ "$(curl -s -o /dev/null -w '%{http_code}' "${WEB_URL}/" || true)" = "200" ]; do
    [ "${SECONDS}" -lt "${deadline}" ] || { echo "FAIL: web GUI did not answer"; exit 1; }
    sleep 2
done
echo "OK: web GUI returns 200"

echo "Waiting for MCP (${MCP_URL})..."
until mcp "${TOKEN}" "${INIT}" 2>/dev/null | grep -q '"serverInfo"'; do
    [ "${SECONDS}" -lt "${deadline}" ] || { echo "FAIL: MCP did not become ready"; exit 1; }
    sleep 3
done

code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Content-Type: application/json" -d "${INIT}" "${MCP_URL}")"
[ "${code}" = "401" ] || { echo "FAIL: request without token returned ${code}"; exit 1; }
echo "OK: MCP without token returns 401"

code="$(mcp "wrong-token-0123456789abcdef" "${INIT}" -o /dev/null -w '%{http_code}')"
[ "${code}" = "401" ] || { echo "FAIL: request with wrong token returned ${code}"; exit 1; }
echo "OK: MCP with wrong token returns 401"

headers="$(mktemp)"
trap 'rm -f "${headers}"; cleanup' EXIT
body="$(mcp "${TOKEN}" "${INIT}" -D "${headers}")"
grep -q '"name":"browseros-neo"' <<<"${body}" || { echo "FAIL: unexpected initialize response: ${body}"; exit 1; }
SESSION="$(grep -i '^mcp-session-id:' "${headers}" | head -n1 | cut -d' ' -f2 | tr -d '\r')"
echo "OK: MCP initialize reports browseros-neo (session ${SESSION})"

mcp "${TOKEN}" '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    -H "Mcp-Session-Id: ${SESSION}" -H "MCP-Protocol-Version: 2025-06-18" -o /dev/null
tools="$(mcp "${TOKEN}" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
    -H "Mcp-Session-Id: ${SESSION}" -H "MCP-Protocol-Version: 2025-06-18")"
grep -q '"tools"' <<<"${tools}" || { echo "FAIL: unexpected tools/list response: ${tools}"; exit 1; }
echo "OK: MCP tools/list returns tools"

if docker exec "${NAME}" sh -c 'pgrep -f -- "--type=renderer" | head -n1 | xargs -I{} cat /proc/{}/cmdline' | tr '\0' '\n' | grep -qx -- '--no-sandbox'; then
    echo "FAIL: renderer runs without the Chromium sandbox"
    exit 1
fi
echo "OK: Chromium sandbox enabled"

echo "All smoke tests passed."
