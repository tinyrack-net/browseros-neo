#!/bin/sh

set -e # Exit immediately if a command exits with a non-zero status.
set -u # Treat unset variables as an error.

PROFILE_DIR=/config/profile
BROWSER_SANDBOX="${BROWSER_SANDBOX:-auto}"

mkdir -p "${PROFILE_DIR}"

# A previous container may have left Chromium's singleton locks behind. They
# reference a hostname/PID that no longer exists and would block startup.
rm -f \
    "${PROFILE_DIR}/SingletonLock" \
    "${PROFILE_DIR}/SingletonCookie" \
    "${PROFILE_DIR}/SingletonSocket"

# Chromium's sandbox needs unprivileged user namespaces. Docker's default
# seccomp profile blocks them, so the sandbox only works when the container
# runs with a seccomp profile that allows them (e.g. seccomp=unconfined).
userns_available() {
    unshare --user --map-root-user true >/dev/null 2>&1
}

case "${BROWSER_SANDBOX}" in
    on|1|true|yes)
        SANDBOX_ARGS=
        ;;
    off|0|false|no)
        echo "WARNING: Chromium sandbox disabled (BROWSER_SANDBOX=${BROWSER_SANDBOX})."
        SANDBOX_ARGS=--no-sandbox
        ;;
    auto)
        if userns_available; then
            echo "Chromium sandbox enabled."
            SANDBOX_ARGS=
        else
            echo "WARNING: user namespaces are not available; starting without the Chromium sandbox."
            echo "WARNING: run the container with '--security-opt seccomp=unconfined' to enable it."
            SANDBOX_ARGS=--no-sandbox
        fi
        ;;
    *)
        echo "ERROR: invalid BROWSER_SANDBOX value: ${BROWSER_SANDBOX} (expected auto, on or off)."
        exit 1
        ;;
esac

# shellcheck disable=SC2086 # SANDBOX_ARGS is intentionally word-split.
exec /usr/bin/browserclaw \
    ${SANDBOX_ARGS} \
    --disable-dev-shm-usage \
    --no-first-run \
    --user-data-dir="${PROFILE_DIR}" \
    "$@"
