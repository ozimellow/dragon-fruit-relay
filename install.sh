#!/usr/bin/env bash
# Dragon Fruit Relay bootstrap installer
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
umask 077

readonly RELEASE_VERSION="2.0.0"
readonly REPOSITORY="${DRAGON_FRUIT_REPOSITORY:-ozimellow/dragon-fruit-relay}"
readonly REVISION="${DRAGON_FRUIT_REVISION:-main}"
readonly SOURCE_URL="https://raw.githubusercontent.com/${REPOSITORY}/${REVISION}/dragon-fruit-relay.sh"

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

command -v curl >/dev/null 2>&1 || die 'curl is required.'

installer=$(mktemp /tmp/dragon-fruit-relay.XXXXXX.sh)
cleanup() {
    rm -f -- "$installer"
}
trap cleanup EXIT HUP INT TERM

printf '[INFO] Downloading Dragon Fruit Relay %s...\n' "$RELEASE_VERSION"
curl --proto '=https' --tlsv1.2 -fLsS "$SOURCE_URL" -o "$installer" || \
    die "Could not download ${SOURCE_URL}"
chmod 0700 "$installer"

bash "$installer" "$@"
