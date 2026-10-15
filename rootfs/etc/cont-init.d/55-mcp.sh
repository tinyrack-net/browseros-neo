#!/bin/sh

set -e # Exit immediately if a command exits with a non-zero status.
set -u # Treat unset variables as an error.

#
# Generate the MCP configuration for the base image's nginx.
#
# BrowserOS neo serves MCP on 127.0.0.1:9010 only and rejects any Host header
# other than localhost. This nginx therefore authenticates the endpoint with a
# Bearer token and forwards requests over loopback.
#
# The endpoint is served by the same nginx as the web GUI, and its port is
# picked this way:
#
#   MCP_LISTENING_PORT == WEB_LISTENING_PORT
#       The locations are added to the web server itself: the GUI keeps its
#       login page on / and MCP answers on /mcp of the same port.
#   MCP_LISTENING_PORT != WEB_LISTENING_PORT
#       A second server block listens on MCP_LISTENING_PORT and serves MCP only.
#   MCP_LISTENING_PORT == -1
#       The endpoint is disabled, just like WEB_LISTENING_PORT == -1.
#
# Both files are included by the base image's nginx configuration, patched by
# scripts/patch-nginx-includes.sh. Anything else leaves them empty, which is a
# no-op for nginx.
#

MCP_CONF=/var/tmp/nginx/mcp.conf
MCP_SITE_CONF=/var/tmp/nginx/mcp_site.conf

MCP_AUTH_TOKEN="${MCP_AUTH_TOKEN:-}"
MCP_LISTENING_PORT="${MCP_LISTENING_PORT:-9300}"
WEB_LISTENING_PORT="${WEB_LISTENING_PORT:-5800}"

# 10-nginx.sh clears /var/tmp/nginx/*.conf and creates the directory, but the
# compiled-in temp paths are what the proxy needs, and nginx expects them to
# exist.
mkdir -p /var/tmp/nginx/client_body /var/tmp/nginx/proxy

generate_locations() {
    cat <<EOF
location = /healthz {
    # Used by container health checks, on the web port as well.
    auth_request off;

    access_log off;
    default_type text/plain;
    return 200 "ok";
}

# The token check of /mcp answers with 401, and the base image maps 401 to its
# login page when web authentication is enabled. Take the code back here so MCP
# clients get a plain 401 challenge instead of a login redirect.
location @mcp_unauthorized {
    auth_request off;

    add_header WWW-Authenticate 'Bearer realm="BrowserOS neo MCP"' always;
    default_type application/json;
    return 401 '{"error":"invalid_token"}';
}

location /mcp {
    # The login page guards the web GUI (a server-level auth_request of the
    # base image); MCP authenticates with its own Bearer token instead.
    auth_request off;
    error_page 401 = @mcp_unauthorized;

    # Plain string comparison: a map would put the token into a hash whose
    # bucket size is too small for long tokens.
    if (\$http_authorization != "Bearer ${MCP_AUTH_TOKEN}") {
        return 401;
    }

    # The web server allows 1m for the GUI; MCP payloads can be larger.
    client_max_body_size 50m;

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
EOF
}

check_port() {
    # $1 = value, $2 = variable name
    case "$1" in
        -1) return 0 ;;
    esac
    case "$1" in
        ''|*[!0-9]*)
            echo "ERROR: invalid $2: $1."
            exit 1
            ;;
    esac
    if [ "$1" -lt 1 ] || [ "$1" -gt 65535 ]; then
        echo "ERROR: invalid $2: $1."
        exit 1
    fi
}

# Start from a clean state: nginx ignores empty include files.
rm -f "${MCP_CONF}" "${MCP_SITE_CONF}"
: > "${MCP_CONF}"
: > "${MCP_SITE_CONF}"

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

check_port "${MCP_LISTENING_PORT}" MCP_LISTENING_PORT
check_port "${WEB_LISTENING_PORT}" WEB_LISTENING_PORT

if [ "${MCP_LISTENING_PORT}" -eq -1 ]; then
    echo "MCP_LISTENING_PORT is -1: the MCP endpoint is disabled."
    exit 0
fi

(
    umask 077
    if [ "${MCP_LISTENING_PORT}" -eq "${WEB_LISTENING_PORT}" ]; then
        generate_locations > "${MCP_CONF}"
    else
        {
            echo "server {"
            echo "    listen ${MCP_LISTENING_PORT};"
            generate_locations | sed 's/^/    /'
            echo "}"
        } > "${MCP_SITE_CONF}"
    fi
)

chown "${USER_ID:-0}:${GROUP_ID:-0}" "${MCP_CONF}" "${MCP_SITE_CONF}" 2>/dev/null || true

if [ "${MCP_LISTENING_PORT}" -eq "${WEB_LISTENING_PORT}" ]; then
    echo "MCP endpoint enabled on the web port ${MCP_LISTENING_PORT} (path /mcp)."
else
    echo "MCP endpoint enabled on port ${MCP_LISTENING_PORT} (path /mcp)."
fi
