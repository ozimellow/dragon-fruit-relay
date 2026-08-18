#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

out=$(printf '1\n' | DFR_INSTALLER_TEST_MODE=1 DFR_TEST_ETC_ROOT="$T/etc" "$ROOT/install.sh")
grep -q 'ROLE=egress-hub' <<<"$out"; grep -q '^MODE=init$' <<<"$out"; grep -q 'dragon-fruit-relay-egress.sh' <<<"$out"
out=$(printf '2\n' | DFR_INSTALLER_TEST_MODE=1 DFR_TEST_ETC_ROOT="$T/etc" "$ROOT/install.sh")
grep -q 'ROLE=ingress' <<<"$out"; grep -q '^MODE=init$' <<<"$out"; grep -q 'dragon-fruit-relay-ingress.sh' <<<"$out"

mkdir -p "$T/etc/dragon-fruit-relay"
printf 'ROLE=egress-hub\n' > "$T/etc/dragon-fruit-relay/host.conf"
if out=$(DFR_INSTALLER_TEST_MODE=1 DFR_TEST_ETC_ROOT="$T/etc" "$ROOT/install.sh" 2>&1); then
    echo 'unmarked pre-lineage state was accepted' >&2; exit 1
fi
grep -q 'does not import or upgrade pre-lineage installations' <<<"$out"

printf 'PRODUCT_ID=dragon-fruit-relay\nPRODUCT_LINEAGE=standalone-dfr\nROLE=egress-hub\n' > "$T/etc/dragon-fruit-relay/host.conf"
out=$(DFR_INSTALLER_TEST_MODE=1 DFR_TEST_ETC_ROOT="$T/etc" "$ROOT/install.sh")
grep -q '^ROLE=egress-hub$' <<<"$out"; grep -q '^MODE=upgrade$' <<<"$out"

rm -f "$T/etc/dragon-fruit-relay/host.conf"
printf 'PRODUCT_ID=dragon-fruit-relay\nPRODUCT_LINEAGE=standalone-dfr\nROLE=ingress\n' > "$T/etc/dragon-fruit-relay/dragon-fruit-relay.conf"
out=$(DFR_INSTALLER_TEST_MODE=1 DFR_TEST_ETC_ROOT="$T/etc" "$ROOT/install.sh")
grep -q '^ROLE=ingress$' <<<"$out"; grep -q '^MODE=upgrade$' <<<"$out"

printf '%s\n' 'installer dispatch: fresh roles, standalone-lineage gate, role-preserving DFR upgrades OK'

python3 - "$ROOT/install.sh" <<'PY'
from pathlib import Path
import sys
s = Path(sys.argv[1]).read_text()
assert "printf '\\033[2J\\033[3J\\033[H'" in s, 'installer full-screen clear sequence is missing'
main = s.index('main() {')
clear_call = s.index('    installer_clear_screen', main)
state_probe = s.index('    if [[ -r "${CONFIG_ROOT}/host.conf"', main)
assert clear_call < state_probe, 'installer clear must run before any install/update state UI'
PY
printf '%s\n' 'installer presentation: full-screen clear occurs before fresh/update state handling OK'
