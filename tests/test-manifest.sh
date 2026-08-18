#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
[[ -f MANIFEST.sha256 ]] || { echo 'MANIFEST.sha256 missing' >&2; exit 1; }
sha256sum -c MANIFEST.sha256 >/dev/null
printf '%s\n' 'manifest: all recorded files verified'
