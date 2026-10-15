#!/bin/sh
#
# Add include hooks for the MCP configuration to the base image's nginx.
#
# The base image (jlesage/baseimage-gui) has no generic conf.d hook: nginx.conf
# includes the mime types and default_site.conf, and default_site.conf includes
# a fixed list of runtime files. BrowserOS neo serves MCP from that same nginx
# (instead of a second nginx process), so it needs one include line per level:
#
#   http   -> /var/tmp/nginx/mcp_site[.]conf
#             Server block, used when MCP_LISTENING_PORT differs from
#             WEB_LISTENING_PORT.
#   server -> /var/tmp/nginx/mcp[.]conf
#             Locations, used when both ports are the same.
#
# Both files are generated at container start by 55-mcp.sh. A missing or empty
# file matches nothing, which is harmless for nginx.
#
# The guards fail the build instead of letting the MCP endpoint silently
# disappear when the base image changes.
#
set -eu

DEFAULT_SITE=/opt/base/etc/nginx/default_site.conf
NGINX_CONF=/opt/base/etc/nginx/nginx.conf
TAB="$(printf '\t')"

# install_after FILE ANCHOR DIRECTIVE
#
# Insert "DIRECTIVE" (indented with a tab) right after the line of FILE whose
# content, ignoring leading whitespace, is exactly ANCHOR.
install_after() {
    file="$1"
    anchor="$2"
    directive="$3"
    line="${TAB}${directive}"

    if grep -qF "${line}" "${file}"; then
        echo "${file}: ${directive} already present."
        return 0
    fi

    if [ "$(grep -cF "${anchor}" "${file}" || true)" -ne 1 ]; then
        echo "ERROR: ${file} does not contain exactly one line matching:" >&2
        echo "    ${anchor}" >&2
        echo "    The base image changed its nginx layout; update this script." >&2
        exit 1
    fi

    awk -v anchor="${anchor}" -v line="${line}" '
        { print }
        { trimmed = $0; sub(/^[[:blank:]]+/, "", trimmed) }
        trimmed == anchor { print line }
    ' "${file}" > "${file}.tmp"
    mv "${file}.tmp" "${file}"

    if [ "$(grep -cF "${line}" "${file}")" -ne 1 ]; then
        echo "ERROR: failed to add ${directive} to ${file}." >&2
        exit 1
    fi
    echo "${file}: added ${directive}"
}

install_after \
    "${DEFAULT_SITE}" \
    "include /opt/base/etc/nginx/include/vnc.conf;" \
    "include /var/tmp/nginx/mcp[.]conf;"

install_after \
    "${NGINX_CONF}" \
    "include /opt/base/etc/nginx/default_site.conf;" \
    "include /var/tmp/nginx/mcp_site[.]conf;"
