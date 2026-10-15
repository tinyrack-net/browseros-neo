#!/usr/bin/env bash
#
# Smoke test a built image.
#
# Usage: smoke.sh IMAGE
#
# The image serves MCP from the same nginx as the web GUI. Both ports default
# to 9300, so a single port carries everything unless MCP_LISTENING_PORT is
# moved elsewhere. The three cases below are covered:
#
#   shared  MCP and the GUI on one port (the defaults),
#   auth    the same, with the web login page in front of the GUI,
#   split   the GUI and MCP on different ports.
#
# Every case verifies that:
#   - the web GUI answers,
#   - MCP rejects requests without a valid token with 401 + WWW-Authenticate,
#   - MCP initialize succeeds with the token and reports browseros-neo,
#   - MCP tools/list returns tools,
#   - an event stream (SSE) passes through the proxy without buffering,
#   - the renderer runs with the Chromium sandbox.

set -euo pipefail

IMAGE="${1:?usage: smoke.sh IMAGE}"
# 64 hex characters, the same shape as `openssl rand -hex 32`.
TOKEN="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
WEB_USERNAME="smoke"
WEB_PASSWORD="smoke-password-0123456789abcdef"
TIMEOUT="${SMOKE_TIMEOUT:-180}"
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}'

CONTAINER=""

cleanup() {
    status=$?
    if [ "${status}" -ne 0 ] && [ -n "${CONTAINER}" ]; then
        echo "---- container logs (${CONTAINER}) ----"
        docker logs "${CONTAINER}" 2>&1 | tail -n 200 || true
    fi
    if [ -n "${CONTAINER}" ]; then
        docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
    fi
    exit "${status}"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "OK: $*"; }

start_container() {
    # $1 = scenario name, the rest = docker run arguments
    local name="$1"
    shift
    CONTAINER="browseros-neo-smoke-$$-${name}"
    docker run -d --name "${CONTAINER}" \
        --shm-size 2g \
        --security-opt seccomp=unconfined \
        "$@" "${IMAGE}" >/dev/null
}

stop_container() {
    if [ -n "${CONTAINER}" ]; then
        docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
        CONTAINER=""
    fi
}

host_port() {
    docker port "${CONTAINER}" "$1/tcp" | head -n1 | sed 's/.*://'
}

# mcp URL TOKEN BODY [extra curl args...]
mcp() {
    local url="$1" token="$2" body="$3"
    shift 3
    curl -sS -m 15 \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -d "${body}" "$@" "${url}"
}

# wait_status URL EXPECTED_CODES DESCRIPTION
wait_status() {
    local url="$1" want="$2" what="$3" code
    local deadline=$((SECONDS + TIMEOUT))
    while :; do
        code="$(curl -s -o /dev/null -w '%{http_code}' "${url}" || true)"
        if [ "${want#*${code}}" != "${want}" ]; then
            return 0
        fi
        [ "${SECONDS}" -lt "${deadline}" ] || fail "${what} did not answer (last status ${code})"
        sleep 2
    done
}

# wait_mcp URL DESCRIPTION
wait_mcp() {
    local url="$1" what="$2"
    local deadline=$((SECONDS + TIMEOUT))
    while :; do
        if mcp "${url}" "${TOKEN}" "${INIT}" 2>/dev/null | grep -q '"serverInfo"'; then
            return 0
        fi
        [ "${SECONDS}" -lt "${deadline}" ] || fail "${what} did not become ready"
        sleep 3
    done
}

# check_stream URL SESSION LABEL
check_stream() {
    local url="$1" session="$2" label="$3" body status
    body="$(mktemp)"
    # The server keeps this stream open and flushes its first event right away.
    # A buffering proxy would deliver nothing until the connection closed, so
    # seeing an event while curl is still running out its timeout proves that
    # the response passes through.
    status="$(curl -sS -N -m 8 -o "${body}" -w '%{http_code}' \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Mcp-Session-Id: ${session}" \
        -H 'Accept: text/event-stream' "${url}" 2>/dev/null || true)"
    [ "${status}" = 200 ] || fail "${label}: event stream returned status ${status}, want 200"
    grep -q '^data:' "${body}" || fail "${label}: event stream delivered no event before its timeout"
    rm -f "${body}"
    ok "${label}: event stream (SSE) passes through the proxy"
}

# check_mcp URL LABEL
check_mcp() {
    local url="$1" label="$2" code headers body session tools

    code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d "${INIT}" "${url}")"
    [ "${code}" = 401 ] || fail "${label}: request without a token returned ${code}, want 401"
    curl -s -D - -o /dev/null -X POST -H 'Content-Type: application/json' -d "${INIT}" "${url}" \
        | grep -qi '^www-authenticate:' || fail "${label}: 401 without a WWW-Authenticate challenge"
    ok "${label}: MCP without a token returns 401 with a challenge"

    code="$(mcp "${url}" "wrong-token-0123456789abcdef" "${INIT}" -o /dev/null -w '%{http_code}')"
    [ "${code}" = 401 ] || fail "${label}: request with a wrong token returned ${code}, want 401"

    headers="$(mktemp)"
    body="$(mcp "${url}" "${TOKEN}" "${INIT}" -D "${headers}")"
    grep -q '"name":"browseros-neo"' <<<"${body}" || fail "${label}: unexpected initialize response: ${body}"
    session="$(grep -i '^mcp-session-id:' "${headers}" | head -n1 | cut -d' ' -f2 | tr -d '\r')"
    rm -f "${headers}"
    [ -n "${session}" ] || fail "${label}: initialize returned no session id"
    ok "${label}: MCP initialize reports browseros-neo (session ${session})"

    mcp "${url}" "${TOKEN}" '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
        -H "Mcp-Session-Id: ${session}" -H "MCP-Protocol-Version: 2025-06-18" -o /dev/null
    tools="$(mcp "${url}" "${TOKEN}" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
        -H "Mcp-Session-Id: ${session}" -H "MCP-Protocol-Version: 2025-06-18")"
    grep -q '"tools"' <<<"${tools}" || fail "${label}: unexpected tools/list response: ${tools}"
    ok "${label}: MCP tools/list returns tools"

    check_stream "${url}" "${session}" "${label}"
}

check_sandbox() {
    if docker exec "${CONTAINER}" sh -c 'pgrep -f -- "--type=renderer" | head -n1 | xargs -I{} cat /proc/{}/cmdline' \
        | tr '\0' '\n' | grep -qx -- '--no-sandbox'; then
        fail "the renderer runs without the Chromium sandbox"
    fi
    ok "Chromium sandbox enabled"
}

# MCP and the GUI on the same port (the defaults).
echo "== MCP and the web GUI on one port"
start_container shared \
    -e MCP_AUTH_TOKEN="${TOKEN}" \
    -p 127.0.0.1::9300
PORT="$(host_port 9300)"
WEB_URL="http://127.0.0.1:${PORT}"
wait_status "${WEB_URL}/" 200 "the web GUI"
[ "$(curl -s "${WEB_URL}/healthz")" = "ok" ] || fail "the health check does not return ok"
wait_mcp "${WEB_URL}/mcp" "MCP"
check_mcp "${WEB_URL}/mcp" "shared port"
check_sandbox
stop_container

# The same port, now with the login page in front of the GUI. MCP must keep
# answering with 401 instead of being redirected to the login page.
echo "== MCP on the web port with web authentication enabled"
start_container auth \
    -e MCP_AUTH_TOKEN="${TOKEN}" \
    -e WEB_AUTHENTICATION=1 \
    -e WEB_AUTHENTICATION_ALLOW_INSECURE=1 \
    -e WEB_AUTHENTICATION_USERNAME="${WEB_USERNAME}" \
    -e WEB_AUTHENTICATION_PASSWORD="${WEB_PASSWORD}" \
    -p 127.0.0.1::9300
PORT="$(host_port 9300)"
WEB_URL="http://127.0.0.1:${PORT}"
wait_status "${WEB_URL}/" 302 "the login redirect"
curl -s -D - -o /dev/null "${WEB_URL}/" | grep -qi '^location: /login/' \
    || fail "the web GUI does not redirect to the login page"
ok "the web GUI redirects to the login page"
wait_mcp "${WEB_URL}/mcp" "MCP"
check_mcp "${WEB_URL}/mcp" "web authentication"
stop_container

# MCP on a port of its own.
echo "== MCP on its own port"
start_container split \
    -e MCP_AUTH_TOKEN="${TOKEN}" \
    -e WEB_LISTENING_PORT=5800 \
    -e MCP_LISTENING_PORT=9300 \
    -p 127.0.0.1::5800 \
    -p 127.0.0.1::9300
WEB_URL="http://127.0.0.1:$(host_port 5800)"
MCP_URL="http://127.0.0.1:$(host_port 9300)"
wait_status "${WEB_URL}/" 200 "the web GUI"
[ "$(curl -s "${MCP_URL}/healthz")" = "ok" ] || fail "the health check does not return ok"
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d "${INIT}" "${WEB_URL}/mcp")"
[ "${code}" = 404 ] || fail "the web port answered ${code} for /mcp, want 404"
ok "the web port serves no MCP when the ports differ"
wait_mcp "${MCP_URL}/mcp" "MCP"
check_mcp "${MCP_URL}/mcp" "separate port"
stop_container

echo "All smoke tests passed."
