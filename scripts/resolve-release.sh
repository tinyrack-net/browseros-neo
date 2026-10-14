#!/usr/bin/env bash
#
# Resolve a BrowserOS neo release and print GitHub Actions style outputs:
#   version=<x.y.z.w>
#   sha256=<hex>
#   url=<deb download url>
#
# Usage: resolve-release.sh [VERSION]
#   Without VERSION, the latest non-prerelease "browserclaw/v*" release is used.
#
# Uses the GitHub CLI when available (authenticated, higher rate limits),
# otherwise falls back to curl.

set -euo pipefail

REPO="browseros-ai/BrowserOS"
VERSION="${1:-}"
VERSION="${VERSION#v}"

api() {
    if command -v gh >/dev/null 2>&1 && [ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]; then
        gh api "$1"
    else
        curl -fsSL -H "Accept: application/vnd.github+json" "https://api.github.com/$1"
    fi
}

if [ -n "${VERSION}" ]; then
    release="$(api "repos/${REPO}/releases/tags/browserclaw/v${VERSION}")"
else
    release="$(
        api "repos/${REPO}/releases?per_page=100" | jq -c '
            [ .[]
              | select(.draft == false and .prerelease == false)
              | select(.tag_name | test("^browserclaw/v[0-9]+(\\.[0-9]+)*$"))
            ]
            | sort_by(.tag_name | sub("^browserclaw/v"; "") | split(".") | map(tonumber))
            | last // empty'
    )"
    if [ -z "${release}" ]; then
        echo "No browserclaw release found." >&2
        exit 1
    fi
    VERSION="$(jq -r '.tag_name | sub("^browserclaw/v"; "")' <<<"${release}")"
fi

asset="$(jq -c --arg name "BrowserOS_neo_v${VERSION}_amd64.deb" '.assets[] | select(.name == $name)' <<<"${release}")"
if [ -z "${asset}" ]; then
    echo "Release ${VERSION} has no amd64 .deb asset." >&2
    exit 1
fi

url="$(jq -r '.browser_download_url' <<<"${asset}")"
digest="$(jq -r '.digest // empty' <<<"${asset}")"

if [[ "${digest}" == sha256:* ]]; then
    sha256="${digest#sha256:}"
else
    echo "Release asset has no digest; downloading to compute SHA256." >&2
    tmp="$(mktemp)"
    trap 'rm -f "${tmp}"' EXIT
    curl -fsSL --retry 3 -o "${tmp}" "${url}"
    sha256="$(sha256sum "${tmp}" | cut -d' ' -f1)"
fi

echo "version=${VERSION}"
echo "sha256=${sha256}"
echo "url=${url}"
