#!/bin/sh

set -e # Exit immediately if a command exits with a non-zero status.
set -u # Treat unset variables as an error.

#
# Generate the configuration of the MCP proxy.
#
# BrowserOS neo serves MCP on 127.0.0.1:9010 only and rejects any Host header
# other than localhost. This nginx instance exposes it on MCP_LISTENING_PORT,
# requires a Bearer token and forwards requests over loopback.
#

CONF_DIR=/var/tmp/mcp-proxy
RUN_DIR=/var/run/mcp-proxy
LOG_DIR=/config/log/mcp-proxy
CONF_FILE="${CONF_DIR}/nginx.conf"

MCP_AUTH_TOKEN="${MCP_AUTH_TOKEN:-}"
MCP_LISTENING_PORT="${MCP_LISTENING_PORT:-9300}"

rm -rf "${CONF_DIR}" "${RUN_DIR}"

if [ -z "${MCP_AUTH_TOKEN}" ]; then
    echo "MCP_AUTH_TOKEN is not set: the MCP endpoint is disabled."
    exit 0
fi

case "${MCP_AUTH_TOKEN}" in
    *[!A-Za-z0-9._~+/=-]*)
        echo "ERROR: MCP_AUTH_TOKEN contains unsupported characters (allowed: A-Z a-z 0-9 . _ ~ + / = -)."
        exit 1
        ;;
esac

if [ "${#MCP_AUTH_TOKEN}" -lt 16 ]; then
    echo "ERROR: MCP_AUTH_TOKEN must be at least 16 characters long."
    exit 1
fi

case "${MCP_LISTENING_PORT}" in
    ''|*[!0-9]*)
        echo "ERROR: invalid MCP_LISTENING_PORT: ${MCP_LISTENING_PORT}."
        exit 1
        ;;
esac

mkdir -p "${CONF_DIR}" "${RUN_DIR}" "${LOG_DIR}"

(
    umask 077
    cat > "${CONF_FILE}" <<EOF
worker_processes 1;
pid ${RUN_DIR}/nginx.pid;
error_log ${LOG_DIR}/error.log warn;

events {
    worker_connections 256;
}

http {
    server_tokens off;
    default_type application/octet-stream;

    access_log ${LOG_DIR}/access.log;

    client_body_temp_path ${RUN_DIR}/client_body;
    proxy_temp_path ${RUN_DIR}/proxy;
    client_max_body_size 50m;

    map \$http_authorization \$mcp_authorized {
        default 0;
        "Bearer ${MCP_AUTH_TOKEN}" 1;
    }

    server {
        listen ${MCP_LISTENING_PORT};

        location = /healthz {
            access_log off;
            default_type text/plain;
            return 200 "ok";
        }

        location /mcp {
            if (\$mcp_authorized = 0) {
                add_header WWW-Authenticate 'Bearer realm="BrowserOS neo MCP"' always;
                return 401;
            }

            proxy_pass http://127.0.0.1:9010;
            proxy_http_version 1.1;

            # BrowserOS neo only accepts loopback Host headers and rejects
            # cross-origin requests.
            proxy_set_header Host 127.0.0.1:9010;
            proxy_set_header Origin "";
            proxy_set_header Authorization "";
            proxy_set_header Connection "";

            # Streamable HTTP / SSE.
            proxy_buffering off;
            proxy_request_buffering off;
            proxy_read_timeout 1h;
            proxy_send_timeout 1h;
        }

        location / {
            return 404;
        }
    }
}
EOF
)

chown -R "${USER_ID}:${GROUP_ID}" "${CONF_DIR}" "${RUN_DIR}" "${LOG_DIR}"

echo "MCP endpoint enabled on port ${MCP_LISTENING_PORT} (path /mcp)."
