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

python3 - "$ROOT/install.sh" <<'PY'
from pathlib import Path
import sys
s = Path(sys.argv[1]).read_text()
required = [
    'BOOTSTRAP_DEFAULT_TAG="v2.1.0"',
    'bootstrap_release()',
    'bootstrap_tagged_release()',
    'normalize_release_tag()',
    'refs/tags/${tag}/install.sh',
    'DRAGON_FRUIT_REVISION="$tag"',
    '--version',
    'releases/download/${tag}',
    'SHA256SUMS',
    'sha256sum -c',
]
for item in required:
    assert item in s, f'public release bootstrap contract missing: {item}'

start = s.index('normalize_release_tag() {')
end = s.index('\n}\n', start) + 3
normalize_body = s[start:end]
assert 'tag=$(normalize_release_tag "$tag")' not in normalize_body, 'normalize_release_tag must not recursively call itself'
assert '[[ "$tag" == v* ]] || tag="v${tag}"' in normalize_body, 'normalize_release_tag must add the v prefix'
assert 'Invalid Dragon Fruit Relay release tag' in normalize_body, 'normalize_release_tag must validate release tags'

assert s.rfind('bootstrap_release "$@"') > s.rfind('main "$@"'), 'bootstrap/local dispatch contract missing'
PY
printf '%s\n' 'installer bootstrap: release tag selection and SHA-256 verification contract OK'

if [[ ${EUID:-$(id -u)} -eq 0 ]] && command -v zip >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; then
    B=$(mktemp -d)
    mkdir -p "$B/pkg/dragon-fruit-relay-2.1.0/main-engine" "$B/bin" "$B/run"
    cat > "$B/pkg/dragon-fruit-relay-2.1.0/install.sh" <<'CHILD'
#!/usr/bin/env bash
printf 'BOOTSTRAP_CHILD_OK\n'
CHILD
    printf '#!/usr/bin/env bash\nexit 0\n' > "$B/pkg/dragon-fruit-relay-2.1.0/main-engine/dragon-fruit-relay-egress.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$B/pkg/dragon-fruit-relay-2.1.0/main-engine/dragon-fruit-relay-ingress.sh"
    chmod 0755 "$B/pkg/dragon-fruit-relay-2.1.0/install.sh" "$B/pkg/dragon-fruit-relay-2.1.0/main-engine/"*.sh
    (cd "$B/pkg" && zip -qr "$B/dragon-fruit-relay-2.1.0.zip" dragon-fruit-relay-2.1.0)
    (cd "$B" && sha256sum dragon-fruit-relay-2.1.0.zip > SHA256SUMS)
    cat > "$B/bin/curl" <<CURL
#!/usr/bin/env bash
set -e
out=''; last=''
while ((\$#)); do
    case "\$1" in
        -o) out="\$2"; shift 2 ;;
        *) last="\$1"; shift ;;
    esac
done
case "\$last" in
    */SHA256SUMS) cp "$B/SHA256SUMS" "\$out" ;;
    */dragon-fruit-relay-2.1.0.zip) cp "$B/dragon-fruit-relay-2.1.0.zip" "\$out" ;;
    *) printf 'unexpected bootstrap URL: %s\n' "\$last" >&2; exit 2 ;;
esac
CURL
    chmod 0755 "$B/bin/curl"
    cp "$ROOT/install.sh" "$B/run/install.sh"
    bout=$(PATH="$B/bin:$PATH" bash "$B/run/install.sh")
    grep -q 'dragon-fruit-relay-2.1.0.zip: OK' <<<"$bout"
    grep -q 'BOOTSTRAP_CHILD_OK' <<<"$bout"
    rm -rf "$B"
    printf '%s\n' 'installer bootstrap: latest stable exact release ZIP checksum verified before packaged installer launch OK'

    V=$(mktemp -d)
    mkdir -p "$V/bin" "$V/run"
    cat > "$V/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -e
out=''
last=''
while (($#)); do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        *) last="$1"; shift ;;
    esac
done
case "$last" in
    */refs/tags/v2.0.2/install.sh)
        cat > "$out" <<'TAGGED'
#!/usr/bin/env bash
printf 'TAGGED_INSTALLER_OK\n'
printf 'TAGGED_REVISION=%s\n' "${DRAGON_FRUIT_REVISION:-}"
printf 'TAGGED_REPOSITORY=%s\n' "${DRAGON_FRUIT_REPOSITORY:-}"
TAGGED
        ;;
    *)
        printf 'unexpected tagged installer URL: %s\n' "$last" >&2
        exit 2
        ;;
esac
CURL
    chmod 0755 "$V/bin/curl"
    cp "$ROOT/install.sh" "$V/run/install.sh"
    vout=$(PATH="$V/bin:$PATH" bash "$V/run/install.sh" v2.0.2)
    grep -q '^TAGGED_INSTALLER_OK$' <<<"$vout"
    grep -q '^TAGGED_REVISION=v2.0.2$' <<<"$vout"
    grep -q '^TAGGED_REPOSITORY=ozimellow/dragon-fruit-relay$' <<<"$vout"
    rm -rf "$V"
    printf '%s\n' 'installer bootstrap: positional version tag selects the exact tagged installer OK'
fi

python3 - "$ROOT/README.md" <<'PY'
from pathlib import Path
import sys
s = Path(sys.argv[1]).read_text()
main_url = 'raw.githubusercontent.com/ozimellow/dragon-fruit-relay/main/install.sh'
assert main_url in s
assert f'{main_url}) v2.0.2' in s
assert 'refs/tags/v2.1.0/install.sh' not in s
assert 'release/v2.1.0-rc.1/install.sh' not in s
PY
printf '%s\n' 'README installer contract: latest main installer + positional specific-version tag OK'
