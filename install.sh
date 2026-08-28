#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly APP_NAME="Dragon Fruit Relay"
readonly APP_VERSION="v2.1.0"
readonly PRODUCT_ID="dragon-fruit-relay"
readonly PRODUCT_LINEAGE="standalone-dfr"
readonly BOOTSTRAP_REPO="ozimellow/dragon-fruit-relay"
readonly BOOTSTRAP_DEFAULT_TAG="v2.1.0"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
EGRESS_ENGINE="${SCRIPT_DIR}/main-engine/dragon-fruit-relay-egress.sh"
INGRESS_ENGINE="${SCRIPT_DIR}/main-engine/dragon-fruit-relay-ingress.sh"
ETC_ROOT="${DFR_TEST_ETC_ROOT:-/etc}"
CONFIG_ROOT="${ETC_ROOT}/dragon-fruit-relay"

if [[ -t 1 && "${TERM:-dumb}" != dumb ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_CYAN=$'\033[36m'; C_MAGENTA=$'\033[35m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'
else
    C_RESET=''; C_BOLD=''; C_DIM=''; C_CYAN=''; C_MAGENTA=''; C_GREEN=''; C_YELLOW=''; C_RED=''
fi

ui_width() {
    local w=120
    if [[ -t 1 ]]; then w=$(tput cols 2>/dev/null || printf 120); fi
    ((w>150)) && w=150; ((w<72)) && w=72
    printf '%s' "$w"
}
ui_rule() { local w; w=$(ui_width); printf '%*s' "$((w-4))" '' | tr ' ' '─'; }
ui_header() {
    local title="$1"
    printf '\n  %s%sDRAGON FRUIT RELAY %s%s  %s|%s  %s%s%s\n' "$C_BOLD" "$C_CYAN" "$APP_VERSION" "$C_RESET" "$C_DIM" "$C_RESET" "$C_BOLD" "$title" "$C_RESET"
    printf '  %s%s%s\n' "$C_DIM" "$(ui_rule)" "$C_RESET"
}
section() {
    printf '\n  %s%s%s%s\n' "$C_BOLD" "$C_MAGENTA" "$1" "$C_RESET"
    printf '  %s%s%s\n' "$C_DIM" "$(ui_rule)" "$C_RESET"
}
row() { printf '  %s%-24s%s %s\n' "$C_DIM" "$1" "$C_RESET" "$2"; }
check() {
    local state="$1" label="$2" value="$3" badge color
    case "$state" in pass) badge=OK; color="$C_GREEN" ;; warn) badge='!'; color="$C_YELLOW" ;; fail) badge=X; color="$C_RED" ;; *) badge=i; color="$C_CYAN" ;; esac
    printf '    %s[%s]%s %-28s %s\n' "$color" "$badge" "$C_RESET" "$label" "$value"
}
menu_item() { local key="$1" label="$2" color="$C_CYAN"; [[ "$key" == 1 ]] && color="$C_GREEN"; printf '  %s[%s]%s  %s\n' "$color" "$key" "$C_RESET" "$label"; }

config_value() {
    local file="$1" key="$2"
    [[ -r "$file" ]] || return 1
    sed -nE "s/^${key}=([^[:space:]]+).*/\\1/p" "$file" | head -n1 | tr -d "'\""
}

platform_name() {
    if [[ -r /etc/os-release ]]; then . /etc/os-release; printf '%s' "${PRETTY_NAME:-Debian}"; else printf 'Debian'; fi
}
default_interface() { ip -4 route show default 2>/dev/null | awk 'NR==1{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}'; }
default_gateway() { ip -4 route show default 2>/dev/null | awk 'NR==1{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1);exit}}'; }

installer_clear_screen() {
    [[ "${DFR_INSTALLER_TEST_MODE:-0}" == 1 ]] && return 0
    [[ -t 1 && "${TERM:-dumb}" != dumb ]] || return 0
    # Start the installer on a genuinely fresh terminal page. 2J clears the
    # visible screen, 3J clears supported terminal scrollback, and H homes
    # the cursor before any Dragon Fruit Relay UI is rendered.
    printf '\033[2J\033[3J\033[H'
}

dispatch() {
    local role="$1" mode="$2" engine=''
    case "$role" in
        egress-hub) engine="$EGRESS_ENGINE" ;;
        ingress|ingress-client) engine="$INGRESS_ENGINE" ;;
        *) printf 'ERROR: Unsupported Dragon Fruit Relay role: %s\n' "$role" >&2; exit 2 ;;
    esac
    [[ -x "$engine" ]] || { printf 'ERROR: Missing executable engine: %s\n' "$engine" >&2; exit 1; }
    if [[ "${DFR_INSTALLER_TEST_MODE:-0}" == 1 ]]; then
        printf 'ROLE=%s\nMODE=%s\nENGINE=%s\n' "$role" "$mode" "$(basename "$engine")"
        return 0
    fi
    if [[ "$mode" == init ]]; then export DFR_SETUP_UI_ACTIVE=yes; fi
    exec "$engine" "$mode"
}


bootstrap_usage() {
    cat <<'EOF'
Dragon Fruit Relay installer

Usage:
  install.sh
  install.sh TAG
  install.sh --version TAG

Examples:
  install.sh
  install.sh v2.0.2
EOF
}

normalize_release_tag() {
    local tag="$1"
    [[ "$tag" == v* ]] || tag="v${tag}"
    if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9][A-Za-z0-9.-]*)?$ ]]; then
        printf 'ERROR: Invalid Dragon Fruit Relay release tag: %s\n' "$tag" >&2
        exit 2
    fi
    printf '%s' "$tag"
}

bootstrap_tagged_release() {
    local tag tmp url
    tag=$(normalize_release_tag "$1")

    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        printf 'ERROR: Run the Dragon Fruit Relay installer as root.\n' >&2
        exit 1
    fi
    command -v curl >/dev/null 2>&1 || {
        printf 'ERROR: curl is required.\n' >&2
        exit 1
    }

    tmp=$(mktemp -d -t dragon-fruit-relay-version.XXXXXXXX)
    trap "rm -rf -- '$tmp'" EXIT
    url="https://raw.githubusercontent.com/${BOOTSTRAP_REPO}/refs/tags/${tag}/install.sh"

    printf '[INFO] Installing Dragon Fruit Relay %s...\n' "$tag"
    curl -fL --retry 3 --connect-timeout 15 -o "$tmp/install.sh" "$url"
    chmod 0700 "$tmp/install.sh"

    # v2.0.x bootstrap installers read DRAGON_FRUIT_REVISION when fetching
    # their runtime. Pin it to the requested tag so an old version can never
    # accidentally fetch the current main branch.
    DRAGON_FRUIT_REVISION="$tag" \
    DRAGON_FRUIT_REPOSITORY="$BOOTSTRAP_REPO" \
        bash "$tmp/install.sh"
}

bootstrap_release() {
    local tag="$BOOTSTRAP_DEFAULT_TAG" version archive base_url tmp checksum_line

    # 3x-ui-style public interface:
    #   install.sh          -> latest stable
    #   install.sh v2.0.2   -> exact tagged release
    if (($# == 1)) && [[ "$1" != -* ]]; then
        bootstrap_tagged_release "$1"
        return
    fi

    while (($#)); do
        case "$1" in
            --version)
                [[ $# -ge 2 && -n "$2" ]] || { printf 'ERROR: --version requires a release tag.\n' >&2; exit 2; }
                tag="$2"; shift 2 ;;
            --version=*) tag="${1#*=}"; shift ;;
            -h|--help) bootstrap_usage; exit 0 ;;
            *) printf 'ERROR: Unknown installer option: %s\n' "$1" >&2; bootstrap_usage >&2; exit 2 ;;
        esac
    done

    tag=$(normalize_release_tag "$tag")

    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        printf 'ERROR: Run the Dragon Fruit Relay installer as root.\n' >&2
        exit 1
    fi
    command -v curl >/dev/null 2>&1 || { printf 'ERROR: curl is required.\n' >&2; exit 1; }
    command -v sha256sum >/dev/null 2>&1 || { printf 'ERROR: sha256sum is required.\n' >&2; exit 1; }

    if ! command -v unzip >/dev/null 2>&1; then
        command -v apt-get >/dev/null 2>&1 || { printf 'ERROR: unzip is required.\n' >&2; exit 1; }
        printf '[INFO] Installing unzip...\n'
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends unzip ca-certificates >/dev/null
    fi

    version="${tag#v}"
    version="${version%%-*}"
    archive="dragon-fruit-relay-${version}.zip"
    base_url="https://github.com/${BOOTSTRAP_REPO}/releases/download/${tag}"
    tmp=$(mktemp -d -t dragon-fruit-relay.XXXXXXXX)
    trap "rm -rf -- '$tmp'" EXIT

    printf '[INFO] Installing Dragon Fruit Relay %s...\n' "$tag"
    curl -fL --retry 3 --connect-timeout 15 -o "$tmp/$archive" "$base_url/$archive"
    curl -fL --retry 3 --connect-timeout 15 -o "$tmp/SHA256SUMS" "$base_url/SHA256SUMS"

    checksum_line=$(awk -v file="$archive" '$2 == file { print; found=1 } END { if (!found) exit 1 }' "$tmp/SHA256SUMS") || {
        printf 'ERROR: %s is not listed in the release checksum file.\n' "$archive" >&2
        exit 1
    }
    printf '%s\n' "$checksum_line" > "$tmp/$archive.sha256"
    (cd "$tmp" && sha256sum -c "$archive.sha256")

    unzip -q "$tmp/$archive" -d "$tmp"
    [[ -f "$tmp/dragon-fruit-relay-${version}/install.sh" ]] || {
        printf 'ERROR: Release archive does not contain the expected installer.\n' >&2
        exit 1
    }
    chmod 0755 "$tmp/dragon-fruit-relay-${version}/install.sh" \
        "$tmp/dragon-fruit-relay-${version}/main-engine/dragon-fruit-relay-egress.sh" \
        "$tmp/dragon-fruit-relay-${version}/main-engine/dragon-fruit-relay-ingress.sh"

    "$tmp/dragon-fruit-relay-${version}/install.sh"
}

main() {
    local existing_file='' role='' product='' lineage='' iface gateway choice platform
    installer_clear_screen
    if [[ -r "${CONFIG_ROOT}/host.conf" && -r "${CONFIG_ROOT}/dragon-fruit-relay.conf" ]]; then
        printf 'ERROR: Both Server and Client configuration files exist. Resolve the conflicting state before installation.\n' >&2; exit 2
    elif [[ -r "${CONFIG_ROOT}/host.conf" ]]; then existing_file="${CONFIG_ROOT}/host.conf"
    elif [[ -r "${CONFIG_ROOT}/dragon-fruit-relay.conf" ]]; then existing_file="${CONFIG_ROOT}/dragon-fruit-relay.conf"
    fi

    if [[ -n "$existing_file" ]]; then
        role=$(config_value "$existing_file" ROLE || true); product=$(config_value "$existing_file" PRODUCT_ID || true); lineage=$(config_value "$existing_file" PRODUCT_LINEAGE || true)
        if [[ "$product" != "$PRODUCT_ID" || "$lineage" != "$PRODUCT_LINEAGE" ]]; then
            printf 'ERROR: Existing state is not from the standalone Dragon Fruit Relay lineage. v2.1.0 does not import or upgrade pre-lineage installations.\n' >&2; exit 2
        fi
        if [[ "${DFR_INSTALLER_TEST_MODE:-0}" != 1 ]]; then
            ui_header 'INSTALLER | UPDATE'
            section 'Detected installation'
            row 'Product lineage' 'Standalone Dragon Fruit Relay'
            case "$role" in egress-hub) row 'Current role' 'Egress Hub (Server)' ;; ingress|ingress-client) row 'Current role' 'Ingress Client (Client)' ;; esac
            row 'Target release' "$APP_VERSION"
            check pass 'Upgrade routing' 'Existing role preserved automatically'
        fi
        case "$role" in egress-hub) dispatch egress-hub upgrade ;; ingress|ingress-client) dispatch ingress upgrade ;; *) printf 'ERROR: Existing Dragon Fruit Relay role is invalid: %s\n' "$role" >&2; exit 2 ;; esac
        return
    fi

    if [[ "${DFR_INSTALLER_TEST_MODE:-0}" != 1 && ${EUID:-$(id -u)} -ne 0 ]]; then printf 'ERROR: Run install.sh as root.\n' >&2; exit 1; fi
    if [[ "${DFR_INSTALLER_TEST_MODE:-0}" != 1 ]]; then
        platform=$(platform_name); iface=$(default_interface || true); gateway=$(default_gateway || true)
        ui_header 'INSTALLER'
        section 'System preflight'
        check pass 'Platform' "$platform with systemd"
        [[ -n "$iface" ]] && check pass 'Internet interface' "$iface" || check warn 'Internet interface' 'not detected yet'
        [[ -n "$gateway" ]] && check info 'Default gateway' "$gateway" || check warn 'Default gateway' 'not detected yet'
        check pass 'Existing DFR state' 'none; fresh standalone installation'
        section 'Choose this machine role'
        menu_item 1 'Egress Hub (Server)'
        row '' 'Hosts and manages one or more Client connections and provides Internet egress.'
        menu_item 2 'Ingress Client (Client)'
        row '' 'Enrolls into an Egress Hub with a one-time DFR1 token.'
        printf '\n  %s[Q]%s  Exit without making changes\n\n' "$C_RED" "$C_RESET"
        printf '  Select a role: '
    fi
    IFS= read -r choice
    case "$choice" in 1) dispatch egress-hub init ;; 2) dispatch ingress init ;; q|Q|0) exit 0 ;; *) printf 'ERROR: Select 1 or 2.\n' >&2; exit 2 ;; esac
}
if [[ -f "$EGRESS_ENGINE" && -f "$INGRESS_ENGINE" ]]; then
    main "$@"
else
    bootstrap_release "$@"
fi
