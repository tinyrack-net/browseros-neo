#!/bin/sh

set -e # Exit immediately if a command exits with a non-zero status.
set -u # Treat unset variables as an error.

PROFILE_DIR=/config/profile

mkdir -p "${PROFILE_DIR}"

# A previous container may have left Chromium's singleton locks behind. They
# reference a hostname/PID that no longer exists and would block startup.
rm -f \
    "${PROFILE_DIR}/SingletonLock" \
    "${PROFILE_DIR}/SingletonCookie" \
    "${PROFILE_DIR}/SingletonSocket"

exec /usr/bin/browserclaw \
    --no-sandbox \
    --disable-dev-shm-usage \
    --no-first-run \
    --user-data-dir="${PROFILE_DIR}" \
    "$@"
