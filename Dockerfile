# syntax=docker/dockerfile:1

ARG BASEIMAGE=jlesage/baseimage-gui:debian-13-v4.14.0

FROM ${BASEIMAGE}

# BrowserOS neo release to package. Both values are required; CI resolves them
# from the GitHub release (see .github/workflows/build.yml).
ARG BROWSEROS_VERSION
ARG BROWSEROS_SHA256
ARG BROWSEROS_DEB_URL=https://github.com/browseros-ai/BrowserOS/releases/download/browserclaw/v${BROWSEROS_VERSION}/BrowserOS_neo_v${BROWSEROS_VERSION}_amd64.deb

# Install BrowserOS neo from the official Debian package. add-pkg prepares the
# environment package scripts expect (e.g. /var/log -> /config/log) and cleans
# up afterwards.
RUN \
    set -eu; \
    test -n "${BROWSEROS_VERSION}" || { echo "BROWSEROS_VERSION is required" >&2; exit 1; }; \
    test -n "${BROWSEROS_SHA256}" || { echo "BROWSEROS_SHA256 is required" >&2; exit 1; }; \
    add-pkg ca-certificates; \
    add-pkg --virtual build-deps curl; \
    curl -fsSL --retry 3 -o /tmp/browseros-neo.deb "${BROWSEROS_DEB_URL}"; \
    echo "${BROWSEROS_SHA256}  /tmp/browseros-neo.deb" | sha256sum -c -; \
    add-pkg /tmp/browseros-neo.deb fonts-noto-cjk; \
    del-pkg build-deps; \
    test -x /usr/bin/browserclaw; \
    rm -f /tmp/browseros-neo.deb

# Generate and install favicons from the icon shipped in the package.
RUN install_app_icon.sh file:///usr/share/icons/hicolor/256x256/apps/browserclaw.png

COPY rootfs/ /

RUN \
    set-cont-env APP_NAME "BrowserOS neo" && \
    set-cont-env APP_VERSION "${BROWSEROS_VERSION}" && \
    set-cont-env DOCKER_IMAGE_VERSION "${BROWSEROS_VERSION}"

# Public environment variables.
ENV \
    KEEP_APP_RUNNING=1 \
    BROWSER_SANDBOX=auto \
    MCP_LISTENING_PORT=9300

EXPOSE 5800 9300

LABEL \
    org.opencontainers.image.title="browseros-neo" \
    org.opencontainers.image.description="BrowserOS neo with a web GUI (noVNC) and a token-protected MCP endpoint" \
    org.opencontainers.image.source="https://github.com/tinyrack-net/browseros-neo" \
    org.opencontainers.image.version="${BROWSEROS_VERSION}"
