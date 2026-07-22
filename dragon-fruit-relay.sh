#!/usr/bin/env bash
# Dragon Fruit Relay - Production-style Debian route-based IKEv2/IPsec installer
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
umask 077

# Run all platform checks before creating logs, directories, or changing files.
# This must remain at the top of the script so unprivileged users receive a
# visible error instead of a permission-denied message from a later operation.
early_error() {
    if [[ -t 2 ]]; then
        printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
    else
        printf '[ERROR] %s\n' "$*" >&2
    fi
}

early_exit() {
    early_error "$1"
    exit "${2:-1}"
}

if (( EUID != 0 )); then
    early_exit "Dragon Fruit Relay must be run as root. Re-run it with: sudo ./dragon-fruit-relay.sh"
fi

[[ -r /etc/os-release ]] || early_exit "Cannot identify the operating system: /etc/os-release is missing or unreadable."

# shellcheck disable=SC1091
source /etc/os-release

if [[ "${ID:-}" != "debian" ]]; then
    early_exit "Unsupported operating system: ${PRETTY_NAME:-${ID:-unknown}}. Dragon Fruit Relay supports Debian only."
fi

if [[ ! -d /run/systemd/system ]]; then
    early_exit "systemd is not the active init system. Dragon Fruit Relay requires systemd."
fi

readonly APP_NAME="Dragon Fruit Relay"
readonly APP_VERSION="2.0.0"

# Canonical Dragon Fruit Relay tree. Application-owned scripts and state live here.
readonly CONFIG_DIR="/etc/dragonfruit-relay"
readonly CONFIG_FILE="${CONFIG_DIR}/dragonfruit-relay.conf"
readonly LIB_DIR="${CONFIG_DIR}/bin"
readonly UNIT_DIR="${CONFIG_DIR}/systemd"
readonly SYSCTL_DIR="${CONFIG_DIR}/sysctl"
readonly RESOLVER_DIR="${CONFIG_DIR}/resolver"
readonly SECRETS_DIR="${CONFIG_DIR}/secrets"
readonly MANAGED_README="${CONFIG_DIR}/README.managed"
readonly INSTALLER_COPY="${CONFIG_DIR}/dragonfruit-relay.sh"
readonly CLI_COMMAND="/usr/local/sbin/dragon-fruit-relay"
readonly TOKEN_FILE="${SECRETS_DIR}/pairing-token.txt"

# Dragon Fruit Relay 2.x egress-hub layout. Each named client has an
# independent daemon, VICI socket, UDP transport, XFRM interface and token.
readonly HOST_CONFIG_FILE="${CONFIG_DIR}/host.conf"
readonly CLIENTS_DIR="${CONFIG_DIR}/clients"
readonly HUB_BIN_DIR="${CONFIG_DIR}/hub-bin"
readonly SWANCTL_CLIENT_ROOT="/etc/swanctl/dragonfruit-relay"
readonly STRONGSWAN_CLIENT_ROOT="/etc/strongswan.d/dragonfruit-relay"
readonly CLIENT_UNIT_TEMPLATE="${SYSTEMD_DIR:-/etc/systemd/system}/dragonfruit-relay-client@.service"
readonly HUB_SCHEMA_CURRENT="2"
readonly PROFILE_SCHEMA_CURRENT="2"
readonly PROFILE_TOKEN_VERSION="5"
readonly PROFILE_NAME_MAX="32"
readonly PROFILE_PORT_MIN="20000"
readonly PROFILE_PORT_MAX="59999"
readonly PROFILE_PORT_FIRST="45001"
readonly PROFILE_XFRM_ID_BASE="1000"
readonly PROFILE_TUNNEL_POOL="10.10.0.0/16"

# Mutable state and logs follow normal Linux filesystem conventions.
readonly STATE_DIR="/var/lib/dragonfruit-relay"
readonly BACKUP_DIR="${STATE_DIR}/original"
readonly MANIFEST_FILE="${BACKUP_DIR}/manifest.tsv"
readonly PACKAGE_STATE_FILE="${STATE_DIR}/package-state.conf"
readonly IPTABLES_RUNTIME_BACKUP="${BACKUP_DIR}/iptables.runtime.v4"
readonly IP6TABLES_RUNTIME_BACKUP="${BACKUP_DIR}/ip6tables.runtime.v6"
readonly SYSCTL_RUNTIME_BACKUP="${BACKUP_DIR}/sysctl.runtime.tsv"
readonly LOG_DIR="/var/log/dragonfruit-relay"
readonly LOG_FILE="${LOG_DIR}/installer.log"
readonly LOCK_FILE="/run/lock/dragonfruit-relay.lock"

# Standard integration locations. strongSwan configuration is written directly
# to its canonical directories; Dragon Fruit Relay scripts remain centralized.
readonly SYSTEMD_DIR="/etc/systemd/system"
readonly SWANCTL_FILE="/etc/swanctl/swanctl.conf"
readonly STRONGSWAN_ROUTE_FILE="/etc/strongswan.d/99-dragonfruit-relay.conf"
readonly STRONGSWAN_OVERRIDE_DIR="/etc/systemd/system/strongswan.service.d"
readonly STRONGSWAN_OVERRIDE_FILE="${STRONGSWAN_OVERRIDE_DIR}/dragonfruit-relay.conf"
readonly SYSCTL_FILE="/etc/sysctl.d/99-dragonfruit-relay.conf"
readonly SYSCTL_MANAGED_FILE="${SYSCTL_DIR}/99-dragonfruit-relay.conf"
readonly RESOLVER_MANAGED_FILE="${RESOLVER_DIR}/resolv.conf"
readonly DHCPCD_CONFIG_FILE="/etc/dhcpcd.conf"
readonly INGRESS_CONFIG_DIR="${CONFIG_DIR}/ingress"
readonly INGRESS_SWANCTL_SOURCE="${INGRESS_CONFIG_DIR}/swanctl.conf"
readonly INGRESS_SWANCTL_DIR="${SWANCTL_CLIENT_ROOT}/ingress"
readonly INGRESS_SWANCTL_CANONICAL="${INGRESS_SWANCTL_DIR}/swanctl.conf"
readonly INGRESS_SWANCTL_MARKER="${INGRESS_SWANCTL_DIR}/.dragonfruit-relay-ingress"
readonly INGRESS_STRONGSWAN_SOURCE="${INGRESS_CONFIG_DIR}/strongswan.conf"
readonly INGRESS_OVERRIDE_SOURCE="${INGRESS_CONFIG_DIR}/strongswan-systemd.conf"
readonly SYSTEMD_OPERATION_TIMEOUT_SECONDS="25"
readonly SWANCTL_OPERATION_TIMEOUT_SECONDS="15"
readonly PUBLIC_IP_LOOKUP_TIMEOUT_SECONDS="6"

# Locations used by older Dragon Fruit Relay releases.
readonly LEGACY_LIB_DIR="/usr/local/lib/dragonfruit-relay"
readonly LEGACY_TOKEN_FILE="/root/dragonfruit-relay-pairing-token.txt"
readonly RT_TABLE_MIN=100
readonly RT_TABLE_MAX=250
readonly RULE_PREF_MIN=10000
readonly RULE_PREF_MAX=30000
readonly DEFAULT_TUNNEL_CIDR="10.10.10.0/30"
readonly DEFAULT_XFRM_ID="42"
readonly DEFAULT_XFRM_IF="xfrm0"
readonly DEFAULT_XFRM_MTU="1400"
readonly DEFAULT_DNS_PRIMARY="1.1.1.1"
readonly DEFAULT_DNS_SECONDARY="8.8.8.8"
readonly DEFAULT_INGRESS_ID="dragonfruit-relay-ingress"
readonly DEFAULT_EGRESS_ID="dragonfruit-relay-egress"
readonly DEFAULT_IKE_PORT="500"
readonly DEFAULT_NATT_PORT="4500"
readonly DEFAULT_CUSTOM_NATT_PORT="45000"
readonly CONNECT_TIMEOUT_SECONDS="18"
readonly CUSTOM_NATT_PORT_MIN="20000"
readonly CUSTOM_NATT_PORT_MAX="59999"
readonly PAIRING_TOKEN_VERSION="4"

TTY_IN="/dev/stdin"
TTY_OUT="/dev/stdout"
if { exec 3</dev/tty 4>/dev/tty; } 2>/dev/null; then
    TTY_IN="/dev/fd/3"
    TTY_OUT="/dev/fd/4"
else
    exec 3<&0 4>&1
fi

command -v flock >/dev/null 2>&1 || early_exit "Required command is missing: flock (util-linux)."
install -d -m 0700 "$LOG_DIR"
exec 9>"$LOCK_FILE"
flock -n 9 || early_exit "Another Dragon Fruit Relay operation is already running."
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

if [[ -t 4 ]]; then
    readonly C_RESET=$'\033[0m'
    readonly C_RED=$'\033[31m'
    readonly C_GREEN=$'\033[32m'
    readonly C_YELLOW=$'\033[33m'
    readonly C_BLUE=$'\033[34m'
    readonly C_MAGENTA=$'\033[35m'
    readonly C_CYAN=$'\033[36m'
    readonly C_WHITE=$'\033[37m'
    readonly C_BOLD=$'\033[1m'
    readonly C_DIM=$'\033[2m'
else
    readonly C_RESET="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE=""
    readonly C_MAGENTA="" C_CYAN="" C_WHITE="" C_BOLD="" C_DIM=""
fi

log_line() {
    local level="$1"
    shift
    printf '%s [%s] %s\n' "$(date -Is)" "$level" "$*" >>"$LOG_FILE"
}

info() {
    log_line INFO "$*"
    printf '%s[INFO]%s %s\n' "$C_BLUE" "$C_RESET" "$*" >"$TTY_OUT"
}

success() {
    log_line OK "$*"
    printf '%s[OK]%s %s\n' "$C_GREEN" "$C_RESET" "$*" >"$TTY_OUT"
}

warn() {
    log_line WARN "$*"
    printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >"$TTY_OUT"
}

error() {
    log_line ERROR "$*"
    printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$*" >"$TTY_OUT"
}

die() {
    error "$*"
    exit 1
}

on_error() {
    local line="$1"
    local command="$2"
    local status="$3"
    error "Command failed at line ${line} with status ${status}: ${command}"
    error "See ${LOG_FILE} for details. Existing backups are kept in ${BACKUP_DIR}."
    exit "$status"
}
trap 'on_error "$LINENO" "$BASH_COMMAND" "$?"' ERR

banner() {
    cat >"$TTY_OUT" <<EOF_BANNER
${C_GREEN}${C_BOLD}                         /\\      /\\
                    ____/  \\____/  \\____
${C_MAGENTA}                 .'                    '.
                /   ${C_WHITE}.  .  .  .  .  .${C_MAGENTA}    \\
               /  ${C_WHITE}.  .  .  .  .  .  .${C_MAGENTA}   \\
              | ${C_WHITE}.  .${C_MAGENTA}   DRAGON FRUIT   ${C_WHITE}.  .${C_MAGENTA} |
              | ${C_WHITE}.  .${C_MAGENTA}      RELAY       ${C_WHITE}.  .${C_MAGENTA} |
               \\  ${C_WHITE}.  .  .  .  .  .  .${C_MAGENTA}   /
                \\   ${C_WHITE}.  .  .  .  .  .${C_MAGENTA}    /
                 '.___              ___. '
${C_GREEN}                      \\____/\\____/
${C_RESET}${C_BOLD}${C_CYAN}                   DRAGON FRUIT RELAY ${APP_VERSION}${C_RESET}
${C_DIM}             Managed IKEv2 / XFRM relay for Debian${C_RESET}
EOF_BANNER
}

require_root_and_platform() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run this installer as root."
    [[ -f /etc/os-release ]] || die "Cannot identify the operating system."

    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == "debian" ]] || die "This installer supports Debian only. Detected: ${ID:-unknown}."
    [[ -d /run/systemd/system ]] || die "systemd must be the active init system."

    local required_command
    for required_command in apt-get apt-cache dpkg-query systemctl ip awk sed grep flock; do
        command -v "$required_command" >/dev/null 2>&1 || \
            die "Required Debian command is missing: ${required_command}"
    done
}

prompt() {
    local text="$1"
    local answer
    printf '%s' "$text" >"$TTY_OUT"
    IFS= read -r answer <"$TTY_IN"
    printf '%s' "$answer"
}

prompt_default() {
    local text="$1"
    local default="$2"
    local answer
    printf '%s [%s]: ' "$text" "$default" >"$TTY_OUT"
    IFS= read -r answer <"$TTY_IN"
    printf '%s' "${answer:-$default}"
}

prompt_secret() {
    local text="$1"
    local answer
    printf '%s' "$text" >"$TTY_OUT"
    IFS= read -r -s answer <"$TTY_IN"
    printf '\n' >"$TTY_OUT"
    printf '%s' "$answer"
}

confirm() {
    local text="$1"
    local default="${2:-yes}"
    local suffix="[Y/n]"
    [[ "$default" == "no" ]] && suffix="[y/N]"

    local answer
    printf '%s %s: ' "$text" "$suffix" >"$TTY_OUT"
    IFS= read -r answer <"$TTY_IN"
    answer="${answer,,}"

    if [[ -z "$answer" ]]; then
        [[ "$default" == "yes" ]]
        return
    fi

    [[ "$answer" == "y" || "$answer" == "yes" ]]
}

validate_ipv4() {
    local ip="$1"
    local a b c d extra
    IFS=. read -r a b c d extra <<<"$ip"
    [[ -z "${extra:-}" && -n "${a:-}" && -n "${b:-}" && -n "${c:-}" && -n "${d:-}" ]] || return 1
    local octet
    for octet in "$a" "$b" "$c" "$d"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
        ((10#$octet >= 0 && 10#$octet <= 255)) || return 1
    done
}

require_ipv4() {
    local description="$1"
    local value="$2"
    validate_ipv4 "$value" || die "Invalid ${description}: ${value}"
}

validate_uint_range() {
    local value="$1" min="$2" max="$3"
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    ((value >= min && value <= max))
}

validate_interface() {
    ip link show dev "$1" >/dev/null 2>&1
}

validate_identity() {
    [[ "$1" =~ ^[A-Za-z0-9._@:-]{1,128}$ ]]
}

detect_default_interface() {
    ip -4 route show default 2>/dev/null | awk 'NR==1 {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

detect_default_gateway() {
    ip -4 route show default 2>/dev/null | awk 'NR==1 {for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}'
}

detect_local_ipv4() {
    local interface="$1"
    ip -4 -o address show dev "$interface" scope global 2>/dev/null | awk 'NR==1 {split($4,a,"/"); print a[1]}'
}

prompt_ipv4_required() {
    local description="$1" value
    while true; do
        value=$(prompt "${description}: ")
        if validate_ipv4 "$value"; then
            printf '%s' "$value"
            return 0
        fi
        warn "Enter a valid IPv4 address."
    done
}

show_detected_network() {
    local gateway="${1:-}"
    section_title 'Detected network'
    print_check pass 'Internet interface' "$WAN_IF"
    print_check info 'Interface address' "$LOCAL_IP (automatic; no input required)"
    [[ -n "$gateway" ]] && print_check info 'Default gateway' "$gateway (detected automatically)"
    [[ -n "${PUBLIC_IP:-}" ]] && print_check info 'Observed public IPv4' "$PUBLIC_IP"
    return 0
}


prompt_ipv4_value() {
    local description="$1" default="$2"
    local value
    while true; do
        value=$(prompt_default "$description" "$default")
        if validate_ipv4 "$value"; then
            printf '%s' "$value"
            return
        fi
        warn "Invalid IPv4 address: ${value}"
    done
}

prompt_uint_value() {
    local description="$1" default="$2" min="$3" max="$4"
    local value
    while true; do
        value=$(prompt_default "$description" "$default")
        if validate_uint_range "$value" "$min" "$max"; then
            printf '%s' "$value"
            return
        fi
        warn "Enter an integer between ${min} and ${max}."
    done
}

prompt_identity_value() {
    local description="$1" default="$2"
    local value
    while true; do
        value=$(prompt_default "$description" "$default")
        if validate_identity "$value"; then
            printf '%s' "$value"
            return
        fi
        warn "Use only letters, numbers, dot, underscore, @, colon, or hyphen."
    done
}

validate_udp_port() {
    validate_uint_range "$1" 1 65535
}

prompt_custom_transport_port() {
    local description="$1" default="$2" min="$3" max="$4" other_port="${5:-}"
    local port

    while true; do
        port=$(prompt_uint_value "$description" "$default" "$min" "$max")

        if [[ -n "$other_port" && "$port" == "$other_port" ]]; then
            warn 'The IKE and NAT-T ports must be different.'
            continue
        fi

        if ss -H -lun 2>/dev/null | grep -Eq "[:.]${port}[[:space:]]"; then
            warn "UDP port ${port} is already in use on this server."
            confirm 'Use it anyway' no || continue
        fi

        printf '%s' "$port"
        return 0
    done
}

prompt_transport_mode() {
    local choice

    section_title 'Tunnel UDP transport'
    cat >"$TTY_OUT" <<EOF_PORTS
  ${C_GREEN}1)${C_RESET} Standard mode
     ${C_DIM}IKE: UDP 500    NAT-T/encrypted traffic: UDP 4500${C_RESET}

  ${C_MAGENTA}2)${C_RESET} Custom direct strongSwan port
     ${C_DIM}Choose one public UDP port for IKE, NAT-T, and encrypted ESP-in-UDP.${C_RESET}
     ${C_DIM}Suggested range: ${CUSTOM_NATT_PORT_MIN}-${CUSTOM_NATT_PORT_MAX}${C_RESET}
EOF_PORTS

    choice=$(prompt_default 'Choose port mode' '1')
    case "$choice" in
        1|'')
            PORT_MODE='standard'
            IKE_PORT="$DEFAULT_IKE_PORT"
            NATT_PORT="$DEFAULT_NATT_PORT"
            ;;
        2)
            PORT_MODE='custom'
            # A custom strongSwan server port is a NAT-T socket. IKE packets
            # use the non-ESP marker and encrypted ESP-in-UDP shares the same
            # remote port; there is no custom equivalent of the 500 -> 4500
            # automatic port switch.
            IKE_PORT="$DEFAULT_IKE_PORT"
            NATT_PORT=$(prompt_custom_transport_port \
                'Custom direct UDP port' \
                "$DEFAULT_CUSTOM_NATT_PORT" \
                "$CUSTOM_NATT_PORT_MIN" \
                "$CUSTOM_NATT_PORT_MAX")
            ;;
        *)
            warn 'Unknown selection; using standard UDP 500 and 4500.'
            PORT_MODE='standard'
            IKE_PORT="$DEFAULT_IKE_PORT"
            NATT_PORT="$DEFAULT_NATT_PORT"
            ;;
    esac
}

transport_label() {
    if [[ "${PORT_MODE:-standard}" == 'custom' ]]; then
        printf 'UDP %s (custom IKE + NAT-T/ESP)' "${NATT_PORT:-$DEFAULT_CUSTOM_NATT_PORT}"
    else
        printf 'UDP %s (IKE) + UDP %s (NAT-T)' \
            "${IKE_PORT:-$DEFAULT_IKE_PORT}" \
            "${NATT_PORT:-$DEFAULT_NATT_PORT}"
    fi
}

transport_description() {
    transport_label
}

transport_forwarding_hint() {
    if [[ "${PORT_MODE:-standard}" == 'custom' ]]; then
        printf 'Forward UDP %s unchanged to this server' "$NATT_PORT"
    else
        printf 'Forward UDP %s for IKE and UDP %s for NAT-T, unchanged, to this server' \
            "$IKE_PORT" "$NATT_PORT"
    fi
}

transport_listener_ok() {
    if [[ "${PORT_MODE:-standard}" == 'custom' ]]; then
        udp_listener_exists "$NATT_PORT"
    else
        udp_listener_exists "$IKE_PORT" && udp_listener_exists "$NATT_PORT"
    fi
}

udp_listener_exists() {
    local port="$1"
    ss -H -lunp 2>/dev/null | grep -Eq "[:.]${port}[[:space:]]"
}

cidr_hosts() {
    local cidr="$1"
    python3 - "$cidr" <<'PY'
import ipaddress
import sys

try:
    network = ipaddress.ip_network(sys.argv[1], strict=True)
except ValueError as exc:
    print(f"ERROR:{exc}")
    raise SystemExit(1)

if network.version != 4 or network.prefixlen != 30:
    print("ERROR:Tunnel network must be an IPv4 /30 network")
    raise SystemExit(1)

hosts = list(network.hosts())
print(network.with_prefixlen)
print(f"{hosts[0]}/{network.prefixlen}")
print(f"{hosts[1]}/{network.prefixlen}")
print(hosts[0])
print(hosts[1])
PY
}

prompt_tunnel_network() {
    local value output
    while true; do
        value=$(prompt_default "Tunnel network (IPv4 /30)" "$DEFAULT_TUNNEL_CIDR")
        if output=$(cidr_hosts "$value" 2>/dev/null); then
            printf '%s\n' "$output"
            return
        fi
        warn "Enter a valid unused IPv4 /30 network, for example ${DEFAULT_TUNNEL_CIDR}."
    done
}

tunnel_network_conflicts() {
    local cidr="$1"
    python3 - "$cidr" <<'PY_CHECK'
import ipaddress
import json
import subprocess
import sys

target = ipaddress.ip_network(sys.argv[1], strict=True)
conflicts = []

try:
    addresses = json.loads(subprocess.check_output(["ip", "-j", "-4", "address", "show"], text=True))
    for link in addresses:
        for item in link.get("addr_info", []):
            if item.get("family") != "inet":
                continue
            network = ipaddress.ip_network(f"{item['local']}/{item['prefixlen']}", strict=False)
            if target.overlaps(network):
                conflicts.append(f"interface {link.get('ifname', '?')}: {network}")
except Exception:
    pass

try:
    routes = json.loads(subprocess.check_output(["ip", "-j", "-4", "route", "show", "table", "main"], text=True))
    for route in routes:
        destination = route.get("dst")
        if not destination or destination == "default":
            continue
        try:
            network = ipaddress.ip_network(destination, strict=False)
        except ValueError:
            continue
        if target.overlaps(network):
            description = destination
            if route.get("dev"):
                description += f" dev {route['dev']}"
            conflicts.append(f"route {description}")
except Exception:
    pass

for conflict in sorted(set(conflicts)):
    print(conflict)

raise SystemExit(0 if conflicts else 1)
PY_CHECK
}

ensure_tunnel_network_available() {
    local cidr="$1"
    local conflicts
    if conflicts=$(tunnel_network_conflicts "$cidr" 2>/dev/null); then
        error "Tunnel network ${cidr} overlaps existing network state:"
        printf '%s\n' "$conflicts" >"$TTY_OUT"
        die "Choose a different tunnel /30 network."
    fi
}

ensure_xfrm_name_available() {
    local interface="$1"
    if ip link show dev "$interface" >/dev/null 2>&1; then
        die "Interface ${interface} already exists. Choose a different XFRM interface name or remove the existing interface first."
    fi
}

route_table_in_use() {
    local table="$1"
    if ip route show table "$table" 2>/dev/null | grep -q .; then
        return 0
    fi
    grep -RhsE "^[[:space:]]*${table}[[:space:]]+" /etc/iproute2/rt_tables /etc/iproute2/rt_tables.d 2>/dev/null | grep -q .
}

find_free_route_table() {
    local table
    for ((table=RT_TABLE_MIN; table<=RT_TABLE_MAX; table++)); do
        if ! route_table_in_use "$table"; then
            printf '%s' "$table"
            return
        fi
    done
    return 1
}

rule_pref_in_use() {
    local pref="$1"
    ip rule show | awk -F: -v p="$pref" '$1 + 0 == p {found=1} END {exit !found}'
}

find_free_rule_prefs() {
    local start
    for ((start=RULE_PREF_MIN; start<=RULE_PREF_MAX-2; start+=3)); do
        if ! rule_pref_in_use "$start" && ! rule_pref_in_use "$((start+1))" && ! rule_pref_in_use "$((start+2))"; then
            printf '%s\n%s\n%s\n' "$start" "$((start+1))" "$((start+2))"
            return
        fi
    done
    return 1
}

package_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'
}

record_initial_package_state() {
    local package="$1"
    mkdir -p "$STATE_DIR"
    touch "$PACKAGE_STATE_FILE"
    if ! grep -qE "^${package}=" "$PACKAGE_STATE_FILE"; then
        if package_installed "$package"; then
            printf '%s=present\n' "$package" >>"$PACKAGE_STATE_FILE"
        else
            printf '%s=absent\n' "$package" >>"$PACKAGE_STATE_FILE"
        fi
    fi
}

record_unit_state_initial() {
    local unit="$1" prefix="$2"
    mkdir -p "$STATE_DIR"
    touch "$PACKAGE_STATE_FILE"
    grep -q "^${prefix}_UNIT_EXISTED=" "$PACKAGE_STATE_FILE" && return 0

    local existed="no" active="no" enabled="no"
    if systemctl cat "$unit" >/dev/null 2>&1; then
        existed="yes"
        systemctl is-active --quiet "$unit" 2>/dev/null && active="yes"
        systemctl is-enabled --quiet "$unit" 2>/dev/null && enabled="yes"
    fi

    printf '%s_UNIT_EXISTED=%s\n' "$prefix" "$existed" >>"$PACKAGE_STATE_FILE"
    printf '%s_UNIT_WAS_ACTIVE=%s\n' "$prefix" "$active" >>"$PACKAGE_STATE_FILE"
    printf '%s_UNIT_WAS_ENABLED=%s\n' "$prefix" "$enabled" >>"$PACKAGE_STATE_FILE"
}

restore_unit_state() {
    local unit="$1" prefix="$2"
    [[ -f "$PACKAGE_STATE_FILE" ]] || return 0

    local existed active enabled
    existed=$(awk -F= -v key="${prefix}_UNIT_EXISTED" '$1==key {print $2}' "$PACKAGE_STATE_FILE")
    active=$(awk -F= -v key="${prefix}_UNIT_WAS_ACTIVE" '$1==key {print $2}' "$PACKAGE_STATE_FILE")
    enabled=$(awk -F= -v key="${prefix}_UNIT_WAS_ENABLED" '$1==key {print $2}' "$PACKAGE_STATE_FILE")

    if [[ "$existed" != "yes" ]]; then
        systemctl disable --now "$unit" >/dev/null 2>&1 || true
        return 0
    fi

    if [[ "$enabled" == "yes" ]]; then
        systemctl enable "$unit" >/dev/null 2>&1 || true
    else
        systemctl disable "$unit" >/dev/null 2>&1 || true
    fi

    if [[ "$active" == "yes" ]]; then
        systemctl restart "$unit" >/dev/null 2>&1 || true
    else
        systemctl stop "$unit" >/dev/null 2>&1 || true
    fi
}

install_dependencies() {
    local required_packages=(
        ca-certificates
        curl
        openssl
        python3-minimal
        iproute2
        iptables
        iptables-persistent
        tcpdump
        strongswan-swanctl
        charon-systemd
        dnsutils
        iputils-ping
    )
    local optional_packages=(
        libstrongswan-extra-plugins
        libcharon-extra-plugins
    )
    local install_packages=() missing_packages=() package

    info "Refreshing Debian package metadata..."
    apt-get update >>"$LOG_FILE" 2>&1

    for package in "${required_packages[@]}"; do
        if apt-cache show "$package" >/dev/null 2>&1; then
            install_packages+=("$package")
            record_initial_package_state "$package"
        else
            missing_packages+=("$package")
        fi
    done

    if ((${#missing_packages[@]})); then
        die "This Debian release/repository does not provide required package(s): ${missing_packages[*]}"
    fi

    for package in "${optional_packages[@]}"; do
        if apt-cache show "$package" >/dev/null 2>&1; then
            install_packages+=("$package")
            record_initial_package_state "$package"
        else
            warn "Optional package is unavailable on this Debian release: ${package}"
        fi
    done

    info "Installing required Debian packages..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y "${install_packages[@]}" >>"$LOG_FILE" 2>&1
    success "Required packages are installed."
}

manifest_contains() {
    local target="$1"
    [[ -f "$MANIFEST_FILE" ]] || return 1
    awk -F '\t' -v target="$target" '
        {
            saved=$2
            if (saved == target || index(target, saved "/") == 1) found=1
        }
        END {exit !found}
    ' "$MANIFEST_FILE"
}

dragonfruit_owned_symlink() {
    local path="$1" link
    [[ -L "$path" ]] || return 1
    link=$(readlink "$path" 2>/dev/null || true)
    case "$link" in
        "$CONFIG_DIR"/*|"$LEGACY_LIB_DIR"/*) return 0 ;;
        *) return 1 ;;
    esac
}

backup_original() {
    local target="$1"
    local saved="${BACKUP_DIR}/files${target}"

    # A prior Dragon Fruit Relay symlink is not host-owned baseline state.
    # Remove stale manifest entries so a fresh installation cannot restore a
    # link to a managed tree that will be deleted during rollback/removal.
    if manifest_contains "$target"; then
        if dragonfruit_owned_symlink "$saved"; then
            awk -F '\t' -v target="$target" '$2 != target' "$MANIFEST_FILE" >"${MANIFEST_FILE}.tmp"
            mv "${MANIFEST_FILE}.tmp" "$MANIFEST_FILE"
            rm -f "$saved"
        else
            return 0
        fi
    fi

    if dragonfruit_owned_symlink "$target"; then
        rm -f "$target"
    fi

    mkdir -p "$BACKUP_DIR/files"
    touch "$MANIFEST_FILE"

    if [[ -e "$target" || -L "$target" ]]; then
        mkdir -p "${BACKUP_DIR}/files$(dirname "$target")"
        cp -a "$target" "${BACKUP_DIR}/files${target}"
        printf 'present\t%s\n' "$target" >>"$MANIFEST_FILE"
    else
        printf 'absent\t%s\n' "$target" >>"$MANIFEST_FILE"
    fi
}

restore_originals() {
    [[ -f "$MANIFEST_FILE" ]] || return 0
    info "Restoring files that existed before Dragon Fruit Relay was installed..."

    local state target
    while IFS=$'\t' read -r state target; do
        [[ -n "$target" ]] || continue

        # These paths are application-owned. Restoring them would resurrect an
        # older or failed Dragon Fruit Relay installation.
        case "$target" in
            "$CONFIG_DIR"|"$CONFIG_DIR"/*|"$LEGACY_LIB_DIR"|"$LEGACY_LIB_DIR"/*|"$LEGACY_TOKEN_FILE")
                continue
                ;;
        esac

        # Older releases sometimes recorded both a directory and files below it.
        # Restoring the parent is authoritative; skip covered descendants.
        if awk -F '\t' -v target="$target" '
            $2 != target && index(target, $2 "/") == 1 {found=1}
            END {exit !found}
        ' "$MANIFEST_FILE"; then
            continue
        fi

        rm -rf -- "$target"
        if [[ "$state" == "present" ]]; then
            local saved="${BACKUP_DIR}/files${target}"
            if dragonfruit_owned_symlink "$saved"; then
                # Never resurrect an integration link into a deleted managed tree.
                continue
            fi
            mkdir -p "$(dirname "$target")"
            cp -a "$saved" "$target"
        fi
    done <"$MANIFEST_FILE"
}

backup_common_paths() {
    record_unit_state_initial strongswan.service STRONGSWAN

    # Only back up host-owned integration files. The managed application tree
    # is never a restoration source because doing so can resurrect stale state.
    backup_original "$SWANCTL_FILE"
    backup_original "$STRONGSWAN_ROUTE_FILE"
    backup_original "$STRONGSWAN_OVERRIDE_FILE"
    backup_original "$SYSTEMD_DIR/dragonfruit-relay-xfrm.service"
}

backup_ingress_paths() {
    backup_common_paths
    backup_original "$INGRESS_SWANCTL_CANONICAL"
    backup_original "$SYSTEMD_DIR/dragonfruit-relay-routing.service"
    backup_original "$SYSTEMD_DIR/dragonfruit-relay-dns.service"
    backup_original "$SYSTEMD_DIR/dragonfruit-relay-healthcheck.service"
    backup_original "$SYSTEMD_DIR/dragonfruit-relay-healthcheck.timer"
    backup_original /etc/resolv.conf
    backup_original "$DHCPCD_CONFIG_FILE"
    backup_original /etc/nsswitch.conf
    backup_original /etc/systemd/resolved.conf
    backup_original /etc/systemd/resolved.conf.d
    backup_original /etc/systemd/system/systemd-resolved.service.d
}

backup_egress_paths() {
    backup_common_paths
    record_unit_state_initial netfilter-persistent.service NETFILTER
    backup_original "$SYSCTL_FILE"
    backup_original /etc/iptables/rules.v4
    backup_original /etc/iptables/rules.v6

    mkdir -p "$BACKUP_DIR"
    if [[ ! -f "$IPTABLES_RUNTIME_BACKUP" ]] && command -v iptables-save >/dev/null 2>&1; then
        iptables-save >"$IPTABLES_RUNTIME_BACKUP"
        chmod 600 "$IPTABLES_RUNTIME_BACKUP"
    fi
    if [[ ! -f "$IP6TABLES_RUNTIME_BACKUP" ]] && command -v ip6tables-save >/dev/null 2>&1; then
        ip6tables-save >"$IP6TABLES_RUNTIME_BACKUP" 2>/dev/null || true
        chmod 600 "$IP6TABLES_RUNTIME_BACKUP" 2>/dev/null || true
    fi
}

backup_egress_runtime_sysctls() {
    [[ -n "${WAN_IF:-}" ]] || return 0
    [[ -f "$SYSCTL_RUNTIME_BACKUP" ]] && return 0

    mkdir -p "$BACKUP_DIR"
    : >"$SYSCTL_RUNTIME_BACKUP"
    chmod 600 "$SYSCTL_RUNTIME_BACKUP"

    local key value
    for key in \
        net.ipv4.ip_forward \
        net.ipv4.conf.all.accept_redirects \
        net.ipv4.conf.default.accept_redirects \
        net.ipv4.conf.all.send_redirects \
        net.ipv4.conf.default.send_redirects \
        net.ipv4.conf.all.rp_filter \
        net.ipv4.conf.default.rp_filter \
        "net.ipv4.conf.${WAN_IF}.rp_filter"; do
        if value=$(sysctl -n "$key" 2>/dev/null); then
            printf '%s\t%s\n' "$key" "$value" >>"$SYSCTL_RUNTIME_BACKUP"
        fi
    done
}

restore_egress_runtime_state() {
    # Restore the exact live firewall snapshot captured before installation.
    if [[ -s "$IPTABLES_RUNTIME_BACKUP" ]] && command -v iptables-restore >/dev/null 2>&1; then
        iptables-restore <"$IPTABLES_RUNTIME_BACKUP" >>"$LOG_FILE" 2>&1 || true
    elif [[ -f /etc/iptables/rules.v4 ]] && command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent reload >>"$LOG_FILE" 2>&1 || true
    fi

    if [[ -s "$IP6TABLES_RUNTIME_BACKUP" ]] && command -v ip6tables-restore >/dev/null 2>&1; then
        ip6tables-restore <"$IP6TABLES_RUNTIME_BACKUP" >>"$LOG_FILE" 2>&1 || true
    fi

    if [[ -s "$SYSCTL_RUNTIME_BACKUP" ]]; then
        local key value
        while IFS=$'\t' read -r key value; do
            [[ -n "$key" ]] || continue
            sysctl -q -w "${key}=${value}" >/dev/null 2>&1 || true
        done <"$SYSCTL_RUNTIME_BACKUP"
    fi
}

ensure_managed_layout() {
    # /etc/resolv.conf points into this managed tree. Unprivileged processes
    # such as APT's _apt helper must be able to traverse both parent
    # directories, but they must not be able to list their contents.
    install -d -m 0751 "$CONFIG_DIR"
    install -d -m 0750 "$LIB_DIR" "$UNIT_DIR" "$SYSCTL_DIR"
    install -d -m 0751 "$RESOLVER_DIR"
    install -d -m 0700 "$SECRETS_DIR"
    install -d -m 0700 "$STATE_DIR" "$BACKUP_DIR"
}

install_cli_command() {
    local source_file="${BASH_SOURCE[0]:-}"
    if [[ -z "$source_file" || ! -r "$source_file" ]]; then
        die 'Cannot install the management command because the current script path is unreadable.'
    fi

    install -d -m 0755 "$(dirname "$CLI_COMMAND")"

    local source_real command_real
    source_real=$(readlink -f -- "$source_file" 2>/dev/null || printf '%s' "$source_file")
    command_real=$(readlink -f -- "$CLI_COMMAND" 2>/dev/null || true)

    # Avoid copying a file over itself when already invoked through
    # /usr/local/sbin/dragon-fruit-relay. Otherwise update atomically so a
    # newer downloaded release immediately replaces the installed command.
    if [[ "$source_real" == "$command_real" ]]; then
        chmod 0755 "$CLI_COMMAND"
        return 0
    fi

    local temporary="${CLI_COMMAND}.tmp.$$"
    install -m 0755 "$source_file" "$temporary"
    mv -f -- "$temporary" "$CLI_COMMAND"
    success "Installed management command: ${CLI_COMMAND}"
}

remove_cli_command() {
    rm -f -- "$CLI_COMMAND"
    if [[ -e "$CLI_COMMAND" || -L "$CLI_COMMAND" ]]; then
        die "Complete uninstall could not remove ${CLI_COMMAND}."
    fi
}

install_self_copy() {
    local source_file="${BASH_SOURCE[0]:-}"
    if [[ -n "$source_file" && -r "$source_file" && "$source_file" != "$INSTALLER_COPY" ]]; then
        install -m 0750 "$source_file" "$INSTALLER_COPY" 2>/dev/null || true
    fi
}

install_managed_link() {
    local managed_file="$1" integration_file="$2"
    mkdir -p "$(dirname "$integration_file")"
    rm -f -- "$integration_file"
    ln -s "$managed_file" "$integration_file"
}

link_managed_unit() {
    local unit="$1"
    install_managed_link "$UNIT_DIR/$unit" "$SYSTEMD_DIR/$unit"
}

cleanup_scattered_legacy_files() {
    rm -rf "$LEGACY_LIB_DIR"
    rm -f "$LEGACY_TOKEN_FILE"
}

write_shell_config() {
    local file="$1"
    shift
    : >"$file"
    chmod 600 "$file"
    local assignment key value
    for assignment in "$@"; do
        key=${assignment%%=*}
        value=${assignment#*=}
        printf '%s=%q\n' "$key" "$value" >>"$file"
    done
}

load_config() {
    [[ -f "$CONFIG_FILE" ]] || die "Dragon Fruit Relay is not configured on this node."
    # This file is root-owned, generated by this installer, and mode 600.
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"

    # Backward-compatible defaults for configurations created by older releases.
    PORT_MODE="${PORT_MODE:-standard}"
    IKE_PORT="${IKE_PORT:-$DEFAULT_IKE_PORT}"
    NATT_PORT="${NATT_PORT:-$DEFAULT_NATT_PORT}"

    # Custom mode exposes one NAT-T socket to the peer. Obsolete dual-port
    # custom configurations can establish IKE but cannot carry ESP-in-UDP on
    # the second custom port because no automatic port switch occurs.
    if [[ "$PORT_MODE" == 'custom' ]]; then
        [[ "$NATT_PORT" != "$DEFAULT_IKE_PORT" ]] ||             die 'Invalid custom transport: the custom direct port may not be UDP 500.'
        # Normalize obsolete v1.2.x dual-port configurations in memory. The
        # custom server port is NATT_PORT; IKE_PORT remains the internal
        # regular socket and is not exposed to the peer in custom mode.
        IKE_PORT="$DEFAULT_IKE_PORT"
    fi
}

write_common_xfrm_files() {
    ensure_managed_layout

    cat >"$LIB_DIR/xfrm-up" <<'EOF_SCRIPT'
#!/usr/bin/env bash
# Managed by Dragon Fruit Relay. Creates the route-based XFRM interface.
set -Eeuo pipefail
# shellcheck disable=SC1091
source /etc/dragonfruit-relay/dragonfruit-relay.conf

if ip link show dev "$XFRM_IF" >/dev/null 2>&1; then
    details=$(ip -d link show dev "$XFRM_IF")
    if ! grep -q 'xfrm' <<<"$details"; then
        echo "Existing interface $XFRM_IF is not an XFRM interface" >&2
        exit 1
    fi
    expected_hex=$(printf '0x%x' "$XFRM_ID")
    if ! grep -Eq "if_id (${XFRM_ID}|${expected_hex})([[:space:]]|$)" <<<"$details"; then
        echo "Existing XFRM interface $XFRM_IF uses a different interface ID" >&2
        exit 1
    fi
else
    ip link add "$XFRM_IF" type xfrm if_id "$XFRM_ID"
fi

ip -4 address flush dev "$XFRM_IF" scope global
ip address add "$XFRM_LOCAL_CIDR" dev "$XFRM_IF"
ip link set "$XFRM_IF" mtu "$XFRM_MTU"
ip link set "$XFRM_IF" up
EOF_SCRIPT

    cat >"$LIB_DIR/xfrm-down" <<'EOF_SCRIPT'
#!/usr/bin/env bash
# Managed by Dragon Fruit Relay. Normal service stops leave the XFRM device
# present but administratively down. This makes restart/reconfigure idempotent
# and avoids kernel/netlink delete operations blocking a systemd stop job.
set -Eeuo pipefail
# shellcheck disable=SC1091
source /etc/dragonfruit-relay/dragonfruit-relay.conf
ip link set "$XFRM_IF" down 2>/dev/null || true
exit 0
EOF_SCRIPT

    chmod 750 "$LIB_DIR/xfrm-up" "$LIB_DIR/xfrm-down"

    cat >"$UNIT_DIR/dragonfruit-relay-xfrm.service" <<EOF_UNIT
# Managed by Dragon Fruit Relay.
[Unit]
Description=Dragon Fruit Relay XFRM interface
Wants=network-online.target
After=network-online.target
Before=strongswan.service

[Service]
Type=oneshot
ExecStart=${LIB_DIR}/xfrm-up
ExecStop=${LIB_DIR}/xfrm-down
RemainAfterExit=yes
TimeoutStartSec=15
TimeoutStopSec=8
KillMode=process

[Install]
WantedBy=multi-user.target
EOF_UNIT
    chmod 0644 "$UNIT_DIR/dragonfruit-relay-xfrm.service"
    link_managed_unit dragonfruit-relay-xfrm.service
}

write_swanctl_egress() {
    ensure_managed_layout
    install -d -m 0755 /etc/swanctl
    rm -f "$SWANCTL_FILE"

    cat >"$SWANCTL_FILE" <<EOF_SWAN
# Managed by Dragon Fruit Relay.
# Role: egress / responder
connections {
    dragonfruit_relay {
        version = 2

        # Accept the paired ingress from any routable source address.
        local_addrs = %any
        remote_addrs = %any

        encap = yes
        mobike = no
        fragmentation = yes
        dpd_delay = 20s
        reauth_time = 0s

        local {
            auth = psk
            id = ${EGRESS_ID}
        }

        remote {
            auth = psk
            id = ${INGRESS_ID}
        }

        children {
            tunnel {
                mode = tunnel
                # Linux policy routing controls which traffic enters xfrm0.
                local_ts = 0.0.0.0/0
                remote_ts = 0.0.0.0/0
                if_id_in = ${XFRM_ID}
                if_id_out = ${XFRM_ID}
            }
        }
    }
}

secrets {
    ike-psk {
        id-1 = ${INGRESS_ID}
        id-2 = ${EGRESS_ID}
        secret = "${PSK}"
    }
}
EOF_SWAN
    chmod 600 "$SWANCTL_FILE"
}

write_ingress_routing_files() {
    ensure_managed_layout

    cat >"$LIB_DIR/routing-apply" <<'EOF_SCRIPT'
#!/usr/bin/env bash
# Managed by Dragon Fruit Relay. Applies deterministic selective routing.
set -Eeuo pipefail
# shellcheck disable=SC1091
source /etc/dragonfruit-relay/dragonfruit-relay.conf

fail() {
    echo "dragonfruit-relay-routing: $*" >&2
    exit 1
}

ip link show dev "$XFRM_IF" >/dev/null 2>&1 || fail "XFRM interface $XFRM_IF does not exist"
ip -4 address show dev "$XFRM_IF" | grep -Fq "${XFRM_LOCAL_IP}/" || \
    fail "XFRM source address $XFRM_LOCAL_IP is not assigned to $XFRM_IF"
[[ "$ROUTE_TABLE" =~ ^[0-9]+$ ]] || fail "Invalid routing table: $ROUTE_TABLE"

# Remove only Dragon Fruit Relay's reserved priorities before rebuilding them.
ip -4 rule del pref "$RULE_DNS_PRIMARY" 2>/dev/null || true
ip -4 rule del pref "$RULE_DNS_SECONDARY" 2>/dev/null || true
ip -4 rule del pref "$RULE_TUNNEL_SOURCE" 2>/dev/null || true
ip -4 route flush table "$ROUTE_TABLE" 2>/dev/null || true

# Any packet selected into this table uses the route-based IPsec interface.
ip -4 route replace default dev "$XFRM_IF" src "$XFRM_LOCAL_IP" table "$ROUTE_TABLE"

# Public DNS uses the remote exit; applications bound to the XFRM source do too.
ip -4 rule add pref "$RULE_DNS_PRIMARY" to "$DNS_PRIMARY/32" lookup "$ROUTE_TABLE"
ip -4 rule add pref "$RULE_DNS_SECONDARY" to "$DNS_SECONDARY/32" lookup "$ROUTE_TABLE"
ip -4 rule add pref "$RULE_TUNNEL_SOURCE" from "$XFRM_LOCAL_IP/32" lookup "$ROUTE_TABLE"

# Validate actual routing decisions rather than relying on display formatting.
tunnel_path=$(ip -4 route get 9.9.9.9 from "$XFRM_LOCAL_IP" 2>/dev/null || true)
primary_dns_path=$(ip -4 route get "$DNS_PRIMARY" 2>/dev/null || true)
secondary_dns_path=$(ip -4 route get "$DNS_SECONDARY" 2>/dev/null || true)

[[ "$tunnel_path" == *"dev $XFRM_IF"* ]] || fail "Tunnel-source traffic uses the wrong path: ${tunnel_path:-no route}"
[[ "$primary_dns_path" == *"dev $XFRM_IF"* ]] || fail "Primary DNS uses the wrong path: ${primary_dns_path:-no route}"
[[ "$secondary_dns_path" == *"dev $XFRM_IF"* ]] || fail "Secondary DNS uses the wrong path: ${secondary_dns_path:-no route}"
EOF_SCRIPT

    cat >"$LIB_DIR/routing-remove" <<'EOF_SCRIPT'
#!/usr/bin/env bash
# Managed by Dragon Fruit Relay. Removes only its policy rules and table.
set -Eeuo pipefail
# shellcheck disable=SC1091
source /etc/dragonfruit-relay/dragonfruit-relay.conf
ip -4 rule del pref "$RULE_DNS_PRIMARY" 2>/dev/null || true
ip -4 rule del pref "$RULE_DNS_SECONDARY" 2>/dev/null || true
ip -4 rule del pref "$RULE_TUNNEL_SOURCE" 2>/dev/null || true
ip -4 route flush table "$ROUTE_TABLE" 2>/dev/null || true
EOF_SCRIPT

    chmod 750 "$LIB_DIR/routing-apply" "$LIB_DIR/routing-remove"

    cat >"$UNIT_DIR/dragonfruit-relay-routing.service" <<EOF_UNIT
# Managed by Dragon Fruit Relay.
[Unit]
Description=Dragon Fruit Relay selective policy routing
Requires=dragonfruit-relay-xfrm.service
After=dragonfruit-relay-xfrm.service strongswan.service

[Service]
Type=oneshot
ExecStart=${LIB_DIR}/routing-apply
ExecStop=${LIB_DIR}/routing-remove
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_UNIT
    chmod 0644 "$UNIT_DIR/dragonfruit-relay-routing.service"
    link_managed_unit dragonfruit-relay-routing.service
}

record_resolved_state() {
    mkdir -p "$STATE_DIR"
    local active="no" enabled="no"
    systemctl is-active --quiet systemd-resolved.service 2>/dev/null && active="yes"
    systemctl is-enabled --quiet systemd-resolved.service 2>/dev/null && enabled="yes"

    if ! grep -q '^RESOLVED_WAS_ACTIVE=' "$PACKAGE_STATE_FILE" 2>/dev/null; then
        printf 'RESOLVED_WAS_ACTIVE=%s\n' "$active" >>"$PACKAGE_STATE_FILE"
        printf 'RESOLVED_WAS_ENABLED=%s\n' "$enabled" >>"$PACKAGE_STATE_FILE"
    fi
}


dhcpcd_resolv_hook_disabled() {
    [[ -r "$DHCPCD_CONFIG_FILE" ]] || return 1
    awk '
        {
            line = $0
            sub(/[[:space:]]*#.*/, "", line)
            if (line !~ /^[[:space:]]*nohook([[:space:]]|$)/) next
            sub(/^[[:space:]]*nohook[[:space:]]*/, "", line)
            gsub(/,/, " ", line)
            count = split(line, hooks, /[[:space:]]+/)
            for (i = 1; i <= count; i++) {
                if (hooks[i] == "resolv.conf") found = 1
            }
        }
        END { exit(found ? 0 : 1) }
    ' "$DHCPCD_CONFIG_FILE"
}

reload_dhcpcd_configuration() {
    command -v dhcpcd >/dev/null 2>&1 || return 0

    local interface="${1:-${WAN_IF:-}}"
    [[ -n "$interface" ]] || interface=$(detect_default_interface 2>/dev/null || true)
    [[ -n "$interface" ]] || return 0

    # dhcpcd can run as a per-interface process without dhcpcd.service.
    # Do not start a new DHCP client; only ask an existing client to reload.
    timeout 15s dhcpcd -n "$interface" >>"$LOG_FILE" 2>&1 || true
}

configure_dhcpcd_resolver_hook() {
    command -v dhcpcd >/dev/null 2>&1 || return 0

    # Fresh setup records this in backup_ingress_paths(). Repeating the backup
    # protects an existing ingress first upgraded through Repair.
    backup_original "$DHCPCD_CONFIG_FILE"

    if [[ ! -e "$DHCPCD_CONFIG_FILE" && ! -L "$DHCPCD_CONFIG_FILE" ]]; then
        install -m 0644 /dev/null "$DHCPCD_CONFIG_FILE"
    fi
    if [[ ! -f "$DHCPCD_CONFIG_FILE" ]]; then
        error "Cannot configure dhcpcd because ${DHCPCD_CONFIG_FILE} is not a regular file."
        return 1
    fi

    if ! dhcpcd_resolv_hook_disabled; then
        cat >>"$DHCPCD_CONFIG_FILE" <<'EOF_DHCPCD_DNS'

# Managed by Dragon Fruit Relay.
# Dragon Fruit Relay owns /etc/resolv.conf while ingress DNS is enabled.
nohook resolv.conf
EOF_DHCPCD_DNS
        info 'Configured dhcpcd to leave /etc/resolv.conf under Dragon Fruit Relay control.'
    fi

    reload_dhcpcd_configuration "$WAN_IF"
    return 0
}

write_egress_sysctl() {
    ensure_managed_layout
    cat >"$SYSCTL_MANAGED_FILE" <<EOF_SYSCTL
# Managed by Dragon Fruit Relay.
# Enable routed egress and disable redirect/reverse-path behaviour that can
# reject legitimate route-based IPsec traffic.
net.ipv4.ip_forward = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.${WAN_IF}.rp_filter = 0
EOF_SYSCTL
    chmod 0644 "$SYSCTL_MANAGED_FILE"
    install_managed_link "$SYSCTL_MANAGED_FILE" "$SYSCTL_FILE"
    sysctl --system >>"$LOG_FILE" 2>&1
}

delete_iptables_rule_all() {
    local table="$1"
    shift
    while iptables -t "$table" -C "$@" 2>/dev/null; do
        iptables -t "$table" -D "$@" 2>/dev/null || break
    done
}

delete_iptables_rules_by_comment() {
    local table="$1" comment="$2" line
    local -a rule

    while IFS= read -r line; do
        [[ "$line" == -A\ * ]] || continue
        line=${line//\"/}
        read -r -a rule <<<"$line"
        rule[0]='-D'
        iptables -t "$table" "${rule[@]}" >/dev/null 2>&1 || true
    done < <(iptables -t "$table" -S 2>/dev/null | grep -F -- "$comment" || true)
}

remove_legacy_firewall_artifacts() {
    # Older releases created an INPUT/OUTPUT firewall service. These rules are
    # not part of the current design and are deleted by their unique comments.
    systemctl disable --now dragonfruit-relay-firewall.service >/dev/null 2>&1 || true
    rm -f "$SYSTEMD_DIR/dragonfruit-relay-firewall.service" \
          "$UNIT_DIR/dragonfruit-relay-firewall.service" \
          "$LIB_DIR/firewall-apply" "$LIB_DIR/firewall-remove"

    local comment
    for comment in \
        dragonfruit-relay-ike \
        dragonfruit-relay-natt \
        dragonfruit-relay-ike-custom \
        dragonfruit-relay-custom-ike-in \
        dragonfruit-relay-custom-ike-out \
        dragonfruit-relay-custom-natt-in \
        dragonfruit-relay-custom-natt-out; do
        delete_iptables_rules_by_comment filter "$comment"
        delete_iptables_rules_by_comment nat "$comment"
    done
    systemctl daemon-reload >/dev/null 2>&1 || true
}

remove_all_dragonfruit_network_rules() {
    local comment
    for comment in \
        dragonfruit-relay-ike \
        dragonfruit-relay-natt \
        dragonfruit-relay-ike-custom \
        dragonfruit-relay-custom-ike-in \
        dragonfruit-relay-custom-ike-out \
        dragonfruit-relay-custom-natt-in \
        dragonfruit-relay-custom-natt-out \
        dragonfruit-relay-forward-out \
        dragonfruit-relay-forward-return \
        dragonfruit-relay-nat; do
        delete_iptables_rules_by_comment filter "$comment"
        delete_iptables_rules_by_comment nat "$comment"
    done
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >>"$LOG_FILE" 2>&1 || true
    fi
}

apply_egress_network_rules() {
    # INPUT filtering is intentionally left to the operator's existing firewall.
    iptables -C FORWARD -i "$XFRM_IF" -o "$WAN_IF" -s "$INGRESS_XFRM_IP/32" \
        -m comment --comment dragonfruit-relay-forward-out -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD 1 -i "$XFRM_IF" -o "$WAN_IF" -s "$INGRESS_XFRM_IP/32" \
        -m comment --comment dragonfruit-relay-forward-out -j ACCEPT

    iptables -C FORWARD -i "$WAN_IF" -o "$XFRM_IF" -d "$INGRESS_XFRM_IP/32" \
        -m conntrack --ctstate ESTABLISHED,RELATED \
        -m comment --comment dragonfruit-relay-forward-return -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD 1 -i "$WAN_IF" -o "$XFRM_IF" -d "$INGRESS_XFRM_IP/32" \
        -m conntrack --ctstate ESTABLISHED,RELATED \
        -m comment --comment dragonfruit-relay-forward-return -j ACCEPT

    iptables -t nat -C POSTROUTING -s "$INGRESS_XFRM_IP/32" -o "$WAN_IF" \
        -m comment --comment dragonfruit-relay-nat -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "$INGRESS_XFRM_IP/32" -o "$WAN_IF" \
        -m comment --comment dragonfruit-relay-nat -j MASQUERADE

    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >>"$LOG_FILE" 2>&1 || true
}

remove_egress_network_rules() {
    delete_iptables_rule_all filter FORWARD -i "$XFRM_IF" -o "$WAN_IF" -s "$INGRESS_XFRM_IP/32" \
        -m comment --comment dragonfruit-relay-forward-out -j ACCEPT
    delete_iptables_rule_all filter FORWARD -i "$WAN_IF" -o "$XFRM_IF" -d "$INGRESS_XFRM_IP/32" \
        -m conntrack --ctstate ESTABLISHED,RELATED \
        -m comment --comment dragonfruit-relay-forward-return -j ACCEPT
    delete_iptables_rule_all nat POSTROUTING -s "$INGRESS_XFRM_IP/32" -o "$WAN_IF" \
        -m comment --comment dragonfruit-relay-nat -j MASQUERADE
    remove_legacy_firewall_artifacts
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >>"$LOG_FILE" 2>&1 || true
}

generate_pairing_token() {
    load_config
    [[ "$ROLE" == "egress" ]] || die "Pairing tokens can only be generated on the egress node."

    local payload token
    payload=$(cat <<EOF_TOKEN
TOKEN_VERSION=${PAIRING_TOKEN_VERSION}
EXIT_PUBLIC_IP=${PUBLIC_IP}
PORT_MODE=${PORT_MODE}
IKE_PORT=${IKE_PORT}
NATT_PORT=${NATT_PORT}
PSK=${PSK}
TUNNEL_CIDR=${TUNNEL_CIDR}
XFRM_ID=${XFRM_ID}
XFRM_IF=${XFRM_IF}
XFRM_MTU=${XFRM_MTU}
INGRESS_XFRM_CIDR=${INGRESS_XFRM_CIDR}
EGRESS_XFRM_CIDR=${EGRESS_XFRM_CIDR}
INGRESS_XFRM_IP=${INGRESS_XFRM_IP}
EGRESS_XFRM_IP=${EGRESS_XFRM_IP}
INGRESS_ID=${INGRESS_ID}
EGRESS_ID=${EGRESS_ID}
DNS_PRIMARY=${DNS_PRIMARY}
DNS_SECONDARY=${DNS_SECONDARY}
EOF_TOKEN
)
    token=$(printf '%s' "$payload" | base64 -w0)
    printf '%s\n' "$token" >"$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    rm -f "$LEGACY_TOKEN_FILE"

    cat >"$TTY_OUT" <<EOF_OUTPUT

${C_BOLD}${C_MAGENTA}PAIRING TOKEN${C_RESET}
${C_YELLOW}This token contains the pre-shared key. Treat it like a password.${C_RESET}
Transport: $(transport_label)

${C_BOLD}${token}${C_RESET}

Paste the complete visible line into the ingress installer.
A protected copy is stored at ${TOKEN_FILE}.
EOF_OUTPUT
}

parse_pairing_token() {
    local token="$1"
    local decoded
    token=$(printf '%s' "$token" | tr -d '[:space:]')
    decoded=$(printf '%s' "$token" | base64 -d 2>/dev/null) || die "The pairing token is not valid Base64."

    local token_version="" exit_public_ip="" psk="" tunnel_cidr="" xfrm_id="" xfrm_if="" xfrm_mtu=""
    local ingress_xfrm_cidr="" egress_xfrm_cidr="" ingress_xfrm_ip="" egress_xfrm_ip=""
    local ingress_id="" egress_id="" dns_primary="" dns_secondary=""
    local port_mode='standard' ike_port="$DEFAULT_IKE_PORT" natt_port="$DEFAULT_NATT_PORT"
    local key value

    while IFS='=' read -r key value; do
        value=${value%$'\r'}
        case "$key" in
            TOKEN_VERSION) token_version="$value" ;;
            EXIT_PUBLIC_IP) exit_public_ip="$value" ;;
            PORT_MODE) port_mode="$value" ;;
            IKE_PORT) ike_port="$value" ;;
            NATT_PORT) natt_port="$value" ;;
            PSK) psk="$value" ;;
            TUNNEL_CIDR) tunnel_cidr="$value" ;;
            XFRM_ID) xfrm_id="$value" ;;
            XFRM_IF) xfrm_if="$value" ;;
            XFRM_MTU) xfrm_mtu="$value" ;;
            INGRESS_XFRM_CIDR) ingress_xfrm_cidr="$value" ;;
            EGRESS_XFRM_CIDR) egress_xfrm_cidr="$value" ;;
            INGRESS_XFRM_IP) ingress_xfrm_ip="$value" ;;
            EGRESS_XFRM_IP) egress_xfrm_ip="$value" ;;
            INGRESS_ID) ingress_id="$value" ;;
            EGRESS_ID) egress_id="$value" ;;
            DNS_PRIMARY) dns_primary="$value" ;;
            DNS_SECONDARY) dns_secondary="$value" ;;
        esac
    done <<<"$decoded"

    # Decode the schema version independently of shell/environment variable
    # names.  Strip a possible UTF-8 BOM and CR left by copied text, then use
    # an explicit case statement so a valid v4 token cannot be rejected by an
    # accidental variable collision.
    token_version=${token_version#$'\xEF\xBB\xBF'}
    token_version=${token_version%$'\r'}
    case "$token_version" in
        1|2|3|4)
            ;;
        '')
            die 'The pairing token does not contain TOKEN_VERSION.'
            ;;
        *)
            die "Unsupported pairing token version '${token_version}'. This installer supports token versions 1-4."
            ;;
    esac

    [[ "$port_mode" == 'standard' || "$port_mode" == 'custom' ]] || die 'Invalid transport mode in token.'
    validate_udp_port "$ike_port" || die 'Invalid IKE port in token.'
    validate_udp_port "$natt_port" || die 'Invalid NAT-T port in token.'
    if [[ "$port_mode" == 'custom' ]]; then
        [[ "$token_version" == "$PAIRING_TOKEN_VERSION" ]] || \
            die 'This is an obsolete dual-port custom token. Migrate or rebuild the egress with the current Dragon Fruit Relay release and generate a new token.'
        [[ "$ike_port" == "$DEFAULT_IKE_PORT" ]] || \
            die 'Invalid custom token: IKE_PORT must remain at the internal default.'
        [[ "$natt_port" != "$DEFAULT_IKE_PORT" ]] || \
            die 'Invalid custom token: the custom direct port may not be UDP 500.'
    fi

    require_ipv4 "egress public IP" "$exit_public_ip"
    require_ipv4 "ingress XFRM IP" "$ingress_xfrm_ip"
    require_ipv4 "egress XFRM IP" "$egress_xfrm_ip"
    require_ipv4 "primary DNS server" "$dns_primary"
    require_ipv4 "secondary DNS server" "$dns_secondary"
    validate_uint_range "$xfrm_id" 1 4294967295 || die "Invalid XFRM interface ID in token."
    validate_uint_range "$xfrm_mtu" 1200 9000 || die "Invalid XFRM MTU in token."
    validate_interface_name "$xfrm_if" || die "Invalid XFRM interface name in token."
    validate_identity "$ingress_id" || die "Invalid ingress identity in token."
    validate_identity "$egress_id" || die "Invalid egress identity in token."
    [[ "$psk" =~ ^[A-Fa-f0-9]{64,128}$ ]] || die "Invalid pre-shared key in token."
    cidr_hosts "$tunnel_cidr" >/dev/null || die "Invalid tunnel CIDR in token."
    [[ "$ingress_xfrm_cidr" == */30 && "$egress_xfrm_cidr" == */30 ]] || die "Invalid XFRM CIDRs in token."

    TOKEN_EXIT_PUBLIC_IP="$exit_public_ip"
    TOKEN_PORT_MODE="$port_mode"
    TOKEN_IKE_PORT="$ike_port"
    TOKEN_NATT_PORT="$natt_port"
    TOKEN_PSK="$psk"
    TOKEN_TUNNEL_CIDR="$tunnel_cidr"
    TOKEN_XFRM_ID="$xfrm_id"
    TOKEN_XFRM_IF="$xfrm_if"
    TOKEN_XFRM_MTU="$xfrm_mtu"
    TOKEN_INGRESS_XFRM_CIDR="$ingress_xfrm_cidr"
    TOKEN_EGRESS_XFRM_CIDR="$egress_xfrm_cidr"
    TOKEN_INGRESS_XFRM_IP="$ingress_xfrm_ip"
    TOKEN_EGRESS_XFRM_IP="$egress_xfrm_ip"
    TOKEN_INGRESS_ID="$ingress_id"
    TOKEN_EGRESS_ID="$egress_id"
    TOKEN_DNS_PRIMARY="$dns_primary"
    TOKEN_DNS_SECONDARY="$dns_secondary"
}

validate_interface_name() {
    [[ "$1" =~ ^[A-Za-z0-9_.-]{1,15}$ ]]
}

write_egress_config() {
    ensure_managed_layout
    {
        cat <<'EOF_CONFIG'
# Dragon Fruit Relay node configuration
# -------------------------------------
# Managed file. Shell syntax is used because helper scripts source it directly.
# Role: egress node (receives IPsec and forwards selected traffic to Internet).
CONFIG_SCHEMA=5
MANAGED_BY_VERSION=2.0.0

# Node and physical network
EOF_CONFIG
        printf 'ROLE=%q\nWAN_IF=%q\nLOCAL_IP=%q\nPUBLIC_IP=%q\n' 'egress' "$WAN_IF" "$LOCAL_IP" "$PUBLIC_IP"
        cat <<'EOF_CONFIG'

# IKE transport
EOF_CONFIG
        printf 'PORT_MODE=%q\nIKE_PORT=%q\nNATT_PORT=%q\n' "$PORT_MODE" "$IKE_PORT" "$NATT_PORT"
        cat <<'EOF_CONFIG'

# Route-based XFRM tunnel
EOF_CONFIG
        printf 'TUNNEL_CIDR=%q\nXFRM_IF=%q\nXFRM_ID=%q\nXFRM_MTU=%q\n' "$TUNNEL_CIDR" "$XFRM_IF" "$XFRM_ID" "$XFRM_MTU"
        printf 'XFRM_LOCAL_CIDR=%q\nXFRM_LOCAL_IP=%q\nXFRM_PEER_IP=%q\n' "$EGRESS_XFRM_CIDR" "$EGRESS_XFRM_IP" "$INGRESS_XFRM_IP"
        printf 'INGRESS_XFRM_CIDR=%q\nEGRESS_XFRM_CIDR=%q\nINGRESS_XFRM_IP=%q\nEGRESS_XFRM_IP=%q\n' "$INGRESS_XFRM_CIDR" "$EGRESS_XFRM_CIDR" "$INGRESS_XFRM_IP" "$EGRESS_XFRM_IP"
        cat <<'EOF_CONFIG'

# IKE identities and DNS destinations shared with ingress
EOF_CONFIG
        printf 'INGRESS_ID=%q\nEGRESS_ID=%q\nDNS_PRIMARY=%q\nDNS_SECONDARY=%q\n' "$INGRESS_ID" "$EGRESS_ID" "$DNS_PRIMARY" "$DNS_SECONDARY"
        cat <<'EOF_CONFIG'

# Secret material - root readable only
EOF_CONFIG
        printf 'PSK=%q\n' "$PSK"
    } >"$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    write_managed_readme
    install_self_copy
}

write_ingress_config() {
    ensure_managed_layout
    {
        cat <<'EOF_CONFIG'
# Dragon Fruit Relay node configuration
# -------------------------------------
# Managed file. Shell syntax is used because helper scripts source it directly.
# Role: ingress node (selects traffic and sends it through the remote egress).
CONFIG_SCHEMA=5
MANAGED_BY_VERSION=2.0.0

# Node and physical network (automatically detected)
EOF_CONFIG
        printf 'ROLE=%q\nPROFILE_NAME=%q\nWAN_IF=%q\nWAN_GATEWAY=%q\nLOCAL_IP=%q\nPUBLIC_IP=%q\nPEER_PUBLIC_IP=%q\n' 'ingress' "${PROFILE_NAME:-legacy-peer}" "$WAN_IF" "$WAN_GATEWAY" "$LOCAL_IP" "$PUBLIC_IP" "$PEER_PUBLIC_IP"
        cat <<'EOF_CONFIG'

# IKE transport imported from the protected pairing token
EOF_CONFIG
        printf 'PORT_MODE=%q\nIKE_PORT=%q\nNATT_PORT=%q\n' "$PORT_MODE" "$IKE_PORT" "$NATT_PORT"
        cat <<'EOF_CONFIG'

# Route-based XFRM tunnel
EOF_CONFIG
        printf 'TUNNEL_CIDR=%q\nXFRM_IF=%q\nXFRM_ID=%q\nXFRM_MTU=%q\n' "$TUNNEL_CIDR" "$XFRM_IF" "$XFRM_ID" "$XFRM_MTU"
        printf 'XFRM_LOCAL_CIDR=%q\nXFRM_LOCAL_IP=%q\nXFRM_PEER_IP=%q\n' "$INGRESS_XFRM_CIDR" "$INGRESS_XFRM_IP" "$EGRESS_XFRM_IP"
        printf 'INGRESS_XFRM_CIDR=%q\nEGRESS_XFRM_CIDR=%q\nINGRESS_XFRM_IP=%q\nEGRESS_XFRM_IP=%q\n' "$INGRESS_XFRM_CIDR" "$EGRESS_XFRM_CIDR" "$INGRESS_XFRM_IP" "$EGRESS_XFRM_IP"
        cat <<'EOF_CONFIG'

# IKE identities
EOF_CONFIG
        printf 'INGRESS_ID=%q\nEGRESS_ID=%q\n' "$INGRESS_ID" "$EGRESS_ID"
        cat <<'EOF_CONFIG'

# Ordered resolver policy: two public resolvers through egress, then local fallback
EOF_CONFIG
        printf 'DNS_PRIMARY=%q\nDNS_SECONDARY=%q\nDNS_FALLBACK=%q\n' "$DNS_PRIMARY" "$DNS_SECONDARY" "$DNS_FALLBACK"
        cat <<'EOF_CONFIG'

# Dedicated Linux policy-routing table and reserved rule priorities
EOF_CONFIG
        printf 'ROUTE_TABLE=%q\nRULE_DNS_PRIMARY=%q\nRULE_DNS_SECONDARY=%q\nRULE_TUNNEL_SOURCE=%q\n' "$ROUTE_TABLE" "$RULE_DNS_PRIMARY" "$RULE_DNS_SECONDARY" "$RULE_TUNNEL_SOURCE"
        cat <<'EOF_CONFIG'

# Secret material - root readable only
EOF_CONFIG
        printf 'PSK=%q\n' "$PSK"
    } >"$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    write_managed_readme
    install_self_copy
}

strongswan_listener_ok() {
    transport_listener_ok
}

show_ike_failure_details() {
    local transcript="$1" outbound_packets="${2:-0}" inbound_packets="${3:-0}" recent
    section_title 'Connection failure'
    [[ -n "$transcript" ]] && printf '%s\n' "$transcript" | tail -n 35 >"$TTY_OUT"

    section_title 'Packet evidence'
    printf '  %-30s %s\n' 'IKE packets sent' "$outbound_packets" >"$TTY_OUT"
    printf '  %-30s %s\n' 'IKE replies received' "$inbound_packets" >"$TTY_OUT"

    recent=$(journalctl -u strongswan.service --since '-3 minutes' --no-pager -o cat 2>/dev/null | \
        grep -Ei 'IKE|CHILD|AUTH|proposal|shared key|peer|retransmit|sending|received|failed|error|no matching|unreachable' | tail -n 60 || true)
    if [[ -n "$recent" ]]; then
        printf '\n%sRecent strongSwan messages:%s\n' "$C_BOLD" "$C_RESET" >"$TTY_OUT"
        printf '%s\n' "$recent" >"$TTY_OUT"
    fi

    if grep -Eqi 'no shared key|AUTHENTICATION_FAILED|authentication failed' <<<"$transcript $recent"; then
        print_check fail 'Likely cause' 'The token/PSK or IKE identities do not match.'
    elif grep -Eqi 'NO_PROPOSAL_CHOSEN|no proposal chosen' <<<"$transcript $recent"; then
        print_check fail 'Likely cause' 'The peers do not agree on cryptographic proposals.'
    elif grep -Eqi 'no matching peer config|no matching config' <<<"$transcript $recent"; then
        print_check fail 'Likely cause' 'The egress responder configuration is missing or identities differ.'
    elif grep -Eqi 'network is unreachable|no route to host|unreachable' <<<"$transcript $recent"; then
        print_check fail 'Likely cause' 'The egress public endpoint is not routable.'
    elif ((outbound_packets > 0 && inbound_packets == 0)); then
        print_check fail 'Likely cause' "Requests left this server, but ${PEER_PUBLIC_IP} sent no reply."
        print_check info 'Check egress path' "Public IP, $(transport_description), cloud firewall, host firewall and router forwarding."
    elif ((inbound_packets > 0)); then
        print_check fail 'Likely cause' 'The egress replied; inspect the authentication/configuration messages above.'
    elif ((outbound_packets == 0)); then
        print_check fail 'Likely cause' 'No IKE packet left the ingress interface.'
        print_check info 'Check local state' 'Loaded connection, strongSwan sockets and the endpoint route.'
    else
        print_check fail 'Likely cause' "No usable IKE response from ${PEER_PUBLIC_IP}:${IKE_PORT}."
    fi
}

attempt_tunnel_connection() {
    local transcript status sas pcap capture_pid capture_text outbound_packets=0 inbound_packets=0
    info "Attempting IKE negotiation (${CONNECT_TIMEOUT_SECONDS}s maximum)..."

    pcap=$(mktemp /tmp/dragonfruit-relay-ike.XXXXXX.pcap)
    if command -v tcpdump >/dev/null 2>&1; then
        local capture_filter
        if [[ "$PORT_MODE" == 'custom' ]]; then
            capture_filter="host $PEER_PUBLIC_IP and udp port $NATT_PORT"
        else
            capture_filter="host $PEER_PUBLIC_IP and (udp port $IKE_PORT or udp port $NATT_PORT)"
        fi
        timeout --signal=TERM "$((CONNECT_TIMEOUT_SECONDS + 4))s" \
            tcpdump -U -ni "$WAN_IF" "$capture_filter" \
            -w "$pcap" >/dev/null 2>&1 &
        capture_pid=$!
        sleep 1
    else
        capture_pid=''
    fi

    set +e
    transcript=$(timeout --signal=TERM "${CONNECT_TIMEOUT_SECONDS}s" swanctl --initiate --child tunnel 2>&1)
    status=$?
    set -e

    if [[ -n "$capture_pid" ]]; then
        kill "$capture_pid" >/dev/null 2>&1 || true
        wait "$capture_pid" 2>/dev/null || true
        capture_text=$(tcpdump -nn -r "$pcap" 2>/dev/null || true)
        outbound_packets=$(awk -v peer="$PEER_PUBLIC_IP." 'index($0, " > " peer) {n++} END {print n+0}' <<<"$capture_text")
        inbound_packets=$(awk -v peer="$PEER_PUBLIC_IP." 'index($0, "IP " peer) {n++} END {print n+0}' <<<"$capture_text")
        {
            printf 'IKE packet capture: outbound=%s inbound=%s\n' "$outbound_packets" "$inbound_packets"
            printf '%s\n' "$capture_text"
        } >>"$LOG_FILE"
    fi
    rm -f "$pcap"

    printf '%s\n' "$transcript" >>"$LOG_FILE"
    sas=$(swanctl --list-sas 2>/dev/null || true)
    if grep -q ESTABLISHED <<<"$sas" && grep -q INSTALLED <<<"$sas"; then
        success 'IKE and CHILD SAs are established.'
        return 0
    fi

    ((status == 124 || status == 143)) && warn 'IKE negotiation timed out.' || warn "IKE negotiation failed with status ${status}."
    show_ike_failure_details "$transcript" "$outbound_packets" "$inbound_packets"
    return 1
}

activate_common_services() {
    timeout 15s systemctl daemon-reload >>"$LOG_FILE" 2>&1 || die 'systemd did not reload the managed units.'
    start_xfrm_checked || die 'Cannot continue without the XFRM interface.'
    systemctl enable strongswan.service >>"$LOG_FILE" 2>&1 || true
    start_unit_checked strongswan.service 'strongSwan service' || die 'Cannot continue without strongSwan.'
    load_strongswan_checked || die 'The generated strongSwan configuration is invalid.'
}

activate_egress() {
    write_egress_sysctl
    remove_legacy_firewall_artifacts
    systemctl daemon-reload
    start_unit_checked dragonfruit-relay-xfrm.service 'XFRM interface service' || die 'Cannot continue without the XFRM interface.'
    systemctl enable strongswan.service >>"$LOG_FILE" 2>&1 || true
    start_unit_checked strongswan.service 'strongSwan service' || die 'Cannot continue without strongSwan.'
    load_strongswan_checked || die 'strongSwan rejected the responder configuration.'
    strongswan_listener_ok || die "strongSwan is not listening on the configured transport: $(transport_description)."
    apply_egress_network_rules
    success 'Egress responder is loaded and listening.'
    warn "Allow or forward $(transport_description) in the host, cloud and router firewall."
}

activate_ingress() {
    activate_common_services
}

wait_for_tunnel() {
    local timeout_seconds="${1:-$CONNECT_TIMEOUT_SECONDS}" elapsed=0 sas
    while ((elapsed < timeout_seconds)); do
        sas=$(swanctl --list-sas 2>/dev/null || true)
        grep -q ESTABLISHED <<<"$sas" && grep -q INSTALLED <<<"$sas" && return 0
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}

verify_ingress_paths() {
    load_config
    info "Verifying ingress routing paths..."

    local route_output direct_ip tunnel_ip
    for route_output in \
        "$(ip -4 route get "$PEER_PUBLIC_IP" 2>/dev/null || true)" \
        "$(ip -4 route get "$DNS_PRIMARY" from "$XFRM_LOCAL_IP" 2>/dev/null || true)" \
        "$(ip -4 route get "$DNS_SECONDARY" from "$XFRM_LOCAL_IP" 2>/dev/null || true)" \
        "$(ip -4 route get 9.9.9.9 from "$XFRM_LOCAL_IP" 2>/dev/null || true)"; do
        [[ -n "$route_output" ]] && printf '%s
' "$route_output" | tee -a "$LOG_FILE" >"$TTY_OUT" || true
    done

    if ping -I "$XFRM_IF" -c 2 -W 3 "$XFRM_PEER_IP" >/dev/null 2>&1; then
        success "The remote XFRM address responds."
    else
        warn "The remote XFRM address did not respond to ping."
    fi

    direct_ip=$(detect_public_ipv4 "$WAN_IF" || true)
    tunnel_ip=$(detect_public_ipv4 "$XFRM_LOCAL_IP" || true)
    [[ -n "$direct_ip" ]] && info "Direct-path public IP consensus: ${direct_ip}" || \
        warn 'Direct-path public IP was not reported because lookup services did not agree.'
    [[ -n "$tunnel_ip" ]] && info "Tunnel public IP consensus: ${tunnel_ip}" || \
        warn 'Tunnel public IP was not reported because lookup services did not agree.'
    return 0
}

delete_rule_pref_all() {
    local pref="${1:-}"
    [[ "$pref" =~ ^[0-9]+$ ]] || return 0
    while ip -4 rule del pref "$pref" 2>/dev/null; do :; done
}

dragonfruit_default_xfrm_signature() {
    local iface="$1" details addresses expected_hex
    ip link show dev "$iface" >/dev/null 2>&1 || return 1
    details=$(ip -d link show dev "$iface" 2>/dev/null || true)
    addresses=$(ip -4 -o address show dev "$iface" 2>/dev/null || true)
    expected_hex=$(printf '0x%x' "$DEFAULT_XFRM_ID")

    grep -q 'xfrm' <<<"$details" || return 1
    grep -Eq "if_id (${DEFAULT_XFRM_ID}|${expected_hex})([[:space:]]|$)" <<<"$details" || return 1
    grep -Eq '10\.10\.10\.(1|2)/30([[:space:]]|$)' <<<"$addresses"
}

verify_managed_runtime_absent() {
    local xfrm_if="${1:-}" route_table="${2:-}" p1="${3:-}" p2="${4:-}" p3="${5:-}"
    local failed=0 pref path target

    if [[ -n "$xfrm_if" ]] && ip link show dev "$xfrm_if" >/dev/null 2>&1; then
        error "Cleanup verification failed: interface $xfrm_if remains."
        failed=1
    fi
    for pref in "$p1" "$p2" "$p3"; do
        [[ "$pref" =~ ^[0-9]+$ ]] || continue
        if ip -4 rule show | awk -F: -v x="$pref" '$1+0==x {found=1} END {exit !found}'; then
            error "Cleanup verification failed: policy rule $pref remains."
            failed=1
        fi
    done
    if [[ "$route_table" =~ ^[0-9]+$ ]] && ip -4 route show table "$route_table" 2>/dev/null | grep -q .; then
        error "Cleanup verification failed: routing table $route_table is not empty."
        failed=1
    fi
    if iptables-save 2>/dev/null | grep -q 'dragonfruit-relay-'; then
        error 'Cleanup verification failed: tagged iptables rules remain.'
        failed=1
    fi
    if [[ -d "$CONFIG_DIR" ]]; then
        error "Cleanup verification failed: $CONFIG_DIR remains."
        failed=1
    fi
    if [[ -e "$INGRESS_SWANCTL_MARKER" || -e "$INGRESS_SWANCTL_CANONICAL" || -L "$INGRESS_SWANCTL_CANONICAL" ]]; then
        error "Cleanup verification failed: managed ingress swanctl namespace remains at $INGRESS_SWANCTL_DIR."
        failed=1
    fi
    for path in "$SWANCTL_FILE" "$INGRESS_SWANCTL_CANONICAL" "$STRONGSWAN_ROUTE_FILE" "$STRONGSWAN_OVERRIDE_FILE" "$SYSCTL_FILE" \
        "$SYSTEMD_DIR"/dragonfruit-relay-*.service "$SYSTEMD_DIR"/dragonfruit-relay-*.timer; do
        [[ -L "$path" ]] || continue
        target=$(readlink -f "$path" 2>/dev/null || true)
        if [[ "$target" == "$CONFIG_DIR"/* ]]; then
            error "Cleanup verification failed: stale managed symlink $path remains."
            failed=1
        fi
    done
    if [[ -L /etc/resolv.conf && "$(readlink -f /etc/resolv.conf 2>/dev/null || true)" == "$RESOLVER_MANAGED_FILE" ]]; then
        error 'Cleanup verification failed: /etc/resolv.conf still points to the managed resolver.'
        failed=1
    fi
    ((failed == 0))
}

clean_abandoned_install_before_setup() {
    [[ ! -f "$CONFIG_FILE" ]] || return 0

    local previous="$STATE_DIR/last-dragonfruit-relay.conf" prior_evidence=no previous_role='unknown'
    if [[ -r "$previous" ]]; then
        prior_evidence=yes
        # Remove runtime state using the exact values from the previous relay.
        (
            set +u
            # shellcheck disable=SC1090
            source "$previous"
            swanctl --terminate --ike dragonfruit_relay >/dev/null 2>&1 || true
            if [[ "${ROLE:-}" == ingress ]]; then
                delete_rule_pref_all "${RULE_DNS_PRIMARY:-}"
                delete_rule_pref_all "${RULE_DNS_SECONDARY:-}"
                delete_rule_pref_all "${RULE_TUNNEL_SOURCE:-}"
                [[ "${ROUTE_TABLE:-}" =~ ^[0-9]+$ ]] && ip -4 route flush table "$ROUTE_TABLE" 2>/dev/null || true
            elif [[ "${ROLE:-}" == egress ]]; then
                remove_egress_network_rules || true
            fi
            delete_link_bounded "${XFRM_IF:-$DEFAULT_XFRM_IF}" || true
        )
        previous_role=$(awk -F= '$1=="ROLE" {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}' "$previous" 2>/dev/null || true)
        previous_role=${previous_role//\'/}
    fi

    [[ -f "$MANIFEST_FILE" || -d "$LEGACY_LIB_DIR" || \
       -e "$SYSTEMD_DIR/dragonfruit-relay-xfrm.service" ]] && prior_evidence=yes

    systemctl disable --now dragonfruit-relay-healthcheck.timer >/dev/null 2>&1 || true
    rm -f "$SYSTEMD_DIR/timers.target.wants/dragonfruit-relay-healthcheck.timer" \
        "$SYSTEMD_DIR/multi-user.target.wants/dragonfruit-relay-xfrm.service" \
        "$SYSTEMD_DIR/multi-user.target.wants/dragonfruit-relay-routing.service" \
        "$SYSTEMD_DIR/multi-user.target.wants/dragonfruit-relay-dns.service"
    systemctl stop dragonfruit-relay-healthcheck.service dragonfruit-relay-dns.service \
        dragonfruit-relay-routing.service >/dev/null 2>&1 || true

    # Remove all uniquely tagged relay rules before restoring original files.
    remove_all_dragonfruit_network_rules || true
    remove_legacy_firewall_artifacts

    if ip link show dev "$DEFAULT_XFRM_IF" >/dev/null 2>&1; then
        if [[ "$prior_evidence" == yes ]] || dragonfruit_default_xfrm_signature "$DEFAULT_XFRM_IF"; then
            delete_link_bounded "$DEFAULT_XFRM_IF" || true
        else
            die "Interface $DEFAULT_XFRM_IF already exists but is not identifiable as Dragon Fruit Relay state. Remove or rename it manually before setup."
        fi
    fi

    # Restore the prior attempt only after all relay runtime state is gone.
    if [[ -f "$MANIFEST_FILE" ]]; then
        restore_package_state || true
        restore_originals || true
        systemctl daemon-reload >/dev/null 2>&1 || true
        if [[ "$previous_role" == egress && -f /etc/iptables/rules.v4 ]] && command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent reload >>"$LOG_FILE" 2>&1 || true
        fi
        restore_unit_state strongswan.service STRONGSWAN || true
        restore_unit_state netfilter-persistent.service NETFILTER || true
    fi

    local stale target
    for stale in \
        "$SWANCTL_FILE" "$INGRESS_SWANCTL_CANONICAL" "$STRONGSWAN_ROUTE_FILE" "$STRONGSWAN_OVERRIDE_FILE" "$SYSCTL_FILE" \
        "$SYSTEMD_DIR/dragonfruit-relay-xfrm.service" \
        "$SYSTEMD_DIR/dragonfruit-relay-routing.service" \
        "$SYSTEMD_DIR/dragonfruit-relay-dns.service" \
        "$SYSTEMD_DIR/dragonfruit-relay-healthcheck.service" \
        "$SYSTEMD_DIR/dragonfruit-relay-healthcheck.timer"; do
        if [[ -L "$stale" ]]; then
            target=$(readlink -f "$stale" 2>/dev/null || true)
            [[ "$target" == "$CONFIG_DIR"/* ]] && rm -f "$stale"
        fi
    done

    [[ -L /etc/resolv.conf && "$(readlink -f /etc/resolv.conf 2>/dev/null || true)" == "$RESOLVER_MANAGED_FILE" ]] && rm -f /etc/resolv.conf || true
    if [[ -e "$INGRESS_SWANCTL_MARKER" ]] || \
       { [[ -f "$INGRESS_SWANCTL_CANONICAL" ]] && grep -q '^# Managed by Dragon Fruit Relay\.' "$INGRESS_SWANCTL_CANONICAL" 2>/dev/null; }; then
        rm -rf -- "$INGRESS_SWANCTL_DIR"
        rmdir "$SWANCTL_CLIENT_ROOT" 2>/dev/null || true
    fi
    rm -rf "$CONFIG_DIR" "$STATE_DIR" "$LEGACY_LIB_DIR"
    rm -f "$SYSTEMD_DIR"/dragonfruit-relay-*.service "$SYSTEMD_DIR"/dragonfruit-relay-*.timer
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed >/dev/null 2>&1 || true
}

rollback_failed_setup() {
    local role="$1"
    local old_xfrm="${XFRM_IF:-$DEFAULT_XFRM_IF}" old_table="${ROUTE_TABLE:-}"
    local p1="${RULE_DNS_PRIMARY:-}" p2="${RULE_DNS_SECONDARY:-}" p3="${RULE_TUNNEL_SOURCE:-}"

    warn 'Setup failed. Restoring the complete pre-install state...'
    remove_runtime_and_files "$role" || true
    remove_all_dragonfruit_network_rules || true
    restore_pre_routevpn_state "$role" || true
    rm -rf "$CONFIG_DIR" "$LEGACY_LIB_DIR"
    delete_link_bounded "$old_xfrm" || true
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed >/dev/null 2>&1 || true

    if verify_managed_runtime_absent "$old_xfrm" "$old_table" "$p1" "$p2" "$p3"; then
        rm -rf "$STATE_DIR"
        success 'Rollback complete; no partial relay installation was retained.'
    else
        error "Rollback could not verify a clean state. Diagnostic backups remain in $STATE_DIR."
        return 1
    fi
}

setup_egress() {
    clear_screen
    banner
    info 'Configuring this server as the Dragon Fruit Relay egress node.'

    if [[ -f "$CONFIG_FILE" ]]; then
        warn 'This node is already configured. Use Rebuild, Repair, or Removal before changing its role.'
        return
    fi

    clean_abandoned_install_before_setup
    backup_egress_paths
    install_dependencies

    local detected_if detected_local detected_public detected_gateway
    detected_if=$(detect_default_interface)
    [[ -n "$detected_if" ]] || die 'No IPv4 default route was detected.'
    WAN_IF="$detected_if"

    detected_local=$(detect_local_ipv4 "$WAN_IF")
    [[ -n "$detected_local" ]] || die "No global IPv4 address was detected on ${WAN_IF}."
    LOCAL_IP="$detected_local"
    detected_gateway=$(detect_default_gateway || true)

    detected_public=$(detect_public_ipv4 || true)
    PUBLIC_IP="${detected_public:-}"
    show_detected_network "$detected_gateway"

    if [[ -n "$detected_public" ]]; then
        PUBLIC_IP=$(prompt_ipv4_value 'Egress public IPv4 reachable by the ingress node' "$detected_public")
    else
        warn 'Automatic public IPv4 detection failed.'
        PUBLIC_IP=$(prompt_ipv4_required 'Enter the egress public IPv4 reachable by the ingress node')
    fi

    if [[ -n "$detected_public" && "$PUBLIC_IP" != "$detected_public" ]]; then
        warn "The entered public IP (${PUBLIC_IP}) differs from the observed Internet IP (${detected_public})."
        warn 'This may be correct with upstream NAT, multiple public addresses, or port forwarding.'
    fi

    prompt_transport_mode

    section_title 'Router / firewall requirement'
    print_check info 'Inbound UDP' "$(transport_forwarding_hint)"
    print_check info 'Port mapping' 'Keep the external and internal UDP port numbers identical'

    confirm "Confirm ${PUBLIC_IP} is the address where $(transport_label) reaches this egress node" yes || {
        PUBLIC_IP=$(prompt_ipv4_required 'Enter the correct egress public IPv4')
    }

    local tunnel_data
    if tunnel_data=$(cidr_hosts "$DEFAULT_TUNNEL_CIDR" 2>/dev/null) && ! tunnel_network_conflicts "$DEFAULT_TUNNEL_CIDR" >/dev/null 2>&1; then
        mapfile -t tunnel_data <<<"$tunnel_data"
    else
        warn "The recommended tunnel network ${DEFAULT_TUNNEL_CIDR} conflicts with existing network state."
        mapfile -t tunnel_data < <(prompt_tunnel_network)
    fi
    ((${#tunnel_data[@]} == 5)) || die 'Failed to derive addresses from the tunnel network.'
    TUNNEL_CIDR=${tunnel_data[0]}
    INGRESS_XFRM_CIDR=${tunnel_data[1]}
    EGRESS_XFRM_CIDR=${tunnel_data[2]}
    INGRESS_XFRM_IP=${tunnel_data[3]}
    EGRESS_XFRM_IP=${tunnel_data[4]}
    ensure_tunnel_network_available "$TUNNEL_CIDR"

    XFRM_IF="$DEFAULT_XFRM_IF"
    XFRM_ID="$DEFAULT_XFRM_ID"
    XFRM_MTU="$DEFAULT_XFRM_MTU"
    INGRESS_ID="$DEFAULT_INGRESS_ID"
    EGRESS_ID="$DEFAULT_EGRESS_ID"
    DNS_PRIMARY="$DEFAULT_DNS_PRIMARY"
    DNS_SECONDARY="$DEFAULT_DNS_SECONDARY"

    if ! confirm 'Use recommended tunnel settings (10.10.10.0/30, xfrm0, ID 42, MTU 1400, Cloudflare/Google DNS)' yes; then
        mapfile -t tunnel_data < <(prompt_tunnel_network)
        TUNNEL_CIDR=${tunnel_data[0]}
        INGRESS_XFRM_CIDR=${tunnel_data[1]}
        EGRESS_XFRM_CIDR=${tunnel_data[2]}
        INGRESS_XFRM_IP=${tunnel_data[3]}
        EGRESS_XFRM_IP=${tunnel_data[4]}
        ensure_tunnel_network_available "$TUNNEL_CIDR"
        XFRM_IF=$(prompt_default 'XFRM interface name' "$DEFAULT_XFRM_IF")
        validate_interface_name "$XFRM_IF" || die 'Invalid XFRM interface name.'
        ensure_xfrm_name_available "$XFRM_IF"
        XFRM_ID=$(prompt_uint_value 'XFRM interface ID' "$DEFAULT_XFRM_ID" 1 4294967295)
        XFRM_MTU=$(prompt_uint_value 'XFRM MTU' "$DEFAULT_XFRM_MTU" 1200 9000)
        INGRESS_ID=$(prompt_identity_value 'Ingress IKE identity' "$DEFAULT_INGRESS_ID")
        EGRESS_ID=$(prompt_identity_value 'Egress IKE identity' "$DEFAULT_EGRESS_ID")
        DNS_PRIMARY=$(prompt_ipv4_value 'Primary public DNS through the tunnel' "$DEFAULT_DNS_PRIMARY")
        DNS_SECONDARY=$(prompt_ipv4_value 'Secondary public DNS through the tunnel' "$DEFAULT_DNS_SECONDARY")
    fi

    ensure_xfrm_name_available "$XFRM_IF"
    backup_egress_runtime_sysctls
    PSK=$(openssl rand -hex 32)

    write_egress_config
    load_config
    if ! (
        write_common_xfrm_files
        write_strongswan_common_files
        write_swanctl_egress
        activate_egress
    ); then
        rollback_failed_setup egress
        return 0
    fi

    if [[ "$LOCAL_IP" != "$PUBLIC_IP" ]]; then
        warn "This node is behind NAT or uses a separate public address. Forward $(transport_label) to this server."
    fi

    if ! generate_pairing_token; then
        rollback_failed_setup egress
        return 0
    fi
    cleanup_scattered_legacy_files

    cat >"$TTY_OUT" <<EOF_SUMMARY

${C_BOLD}${C_GREEN}Egress setup complete${C_RESET}
Role:                    egress
Detected interface:      ${WAN_IF}
Detected interface IP:   ${LOCAL_IP}
Advertised public IP:    ${PUBLIC_IP}
XFRM address:            ${EGRESS_XFRM_CIDR}
Peer XFRM address:       ${INGRESS_XFRM_IP}
IKE transport:           $(transport_label)

Managed files:            ${CONFIG_DIR}

Next: run Dragon Fruit Relay on the ingress node and choose "Configure ingress node".
EOF_SUMMARY
}

setup_ingress() {
    local supplied_token="${1:-}" supplied_fallback="${2:-}"
    clear_screen
    banner
    info 'Configuring this server as a Dragon Fruit Relay ingress client.'

    if hub_configured; then
        die 'This server is already configured as an egress hub. Remove the hub before configuring it as an ingress client.'
    fi

    if [[ -f "$CONFIG_FILE" ]]; then
        warn 'This node is already configured. Use Rebuild, Repair, or Removal before changing its role.'
        return
    fi

    clean_abandoned_install_before_setup
    backup_ingress_paths
    install_dependencies

    local token
    section_title 'Pairing token'
    if [[ -n "$supplied_token" ]]; then
        token="$supplied_token"
        print_check info 'Token input' 'supplied by command line'
    else
        printf '  %sPaste is visible so you can confirm the complete token was received.%s\n' "$C_DIM" "$C_RESET" >"$TTY_OUT"
        token=$(prompt '  Paste token: ')
    fi
    [[ -n "$token" ]] || die 'A pairing token is required.'
    parse_pairing_token "$token"

    local detected_if detected_local detected_public detected_gateway
    detected_if=$(detect_default_interface)
    [[ -n "$detected_if" ]] || die 'No IPv4 default route was detected.'
    WAN_IF="$detected_if"

    detected_local=$(detect_local_ipv4 "$WAN_IF")
    [[ -n "$detected_local" ]] || die "No global IPv4 address was detected on ${WAN_IF}."
    LOCAL_IP="$detected_local"

    detected_gateway=$(detect_default_gateway)
    [[ -n "$detected_gateway" ]] || die 'No IPv4 default gateway was detected.'
    WAN_GATEWAY="$detected_gateway"

    detected_public=$(detect_public_ipv4 || true)
    PUBLIC_IP="${detected_public:-}"
    show_detected_network "$WAN_GATEWAY"

    if [[ -n "$supplied_fallback" ]]; then
        validate_ipv4 "$supplied_fallback" || die 'The supplied local DNS fallback is not a valid IPv4 address.'
        DNS_FALLBACK="$supplied_fallback"
        print_check info 'Local DNS fallback' "$DNS_FALLBACK (preserved)"
    else
        DNS_FALLBACK=$(prompt_ipv4_value 'Local DNS fallback (normally the local gateway/router)' "$WAN_GATEWAY")
    fi

    ROUTE_TABLE=$(find_free_route_table) || die 'No free policy-routing table was found.'
    local prefs
    mapfile -t prefs < <(find_free_rule_prefs)
    ((${#prefs[@]} == 3)) || die 'No free policy-rule priorities were found.'
    RULE_DNS_PRIMARY=${prefs[0]}
    RULE_DNS_SECONDARY=${prefs[1]}
    RULE_TUNNEL_SOURCE=${prefs[2]}

    PEER_PUBLIC_IP=$TOKEN_EXIT_PUBLIC_IP
    PROFILE_NAME=${TOKEN_PROFILE_NAME:-legacy-peer}
    PORT_MODE=$TOKEN_PORT_MODE
    IKE_PORT=$TOKEN_IKE_PORT
    NATT_PORT=$TOKEN_NATT_PORT
    PSK=$TOKEN_PSK
    TUNNEL_CIDR=$TOKEN_TUNNEL_CIDR
    XFRM_ID=$TOKEN_XFRM_ID
    XFRM_IF=$TOKEN_XFRM_IF
    XFRM_MTU=$TOKEN_XFRM_MTU
    INGRESS_XFRM_CIDR=$TOKEN_INGRESS_XFRM_CIDR
    EGRESS_XFRM_CIDR=$TOKEN_EGRESS_XFRM_CIDR
    INGRESS_XFRM_IP=$TOKEN_INGRESS_XFRM_IP
    EGRESS_XFRM_IP=$TOKEN_EGRESS_XFRM_IP
    INGRESS_ID=$TOKEN_INGRESS_ID
    EGRESS_ID=$TOKEN_EGRESS_ID
    DNS_PRIMARY=$TOKEN_DNS_PRIMARY
    DNS_SECONDARY=$TOKEN_DNS_SECONDARY

    ensure_tunnel_network_available "$TUNNEL_CIDR"
    if ip link show dev "$XFRM_IF" >/dev/null 2>&1; then
        die "Interface ${XFRM_IF} already exists. Remove the old/partial tunnel from the Removal menu first."
    fi

    local peer_route
    peer_route=$(ip -4 route get "$PEER_PUBLIC_IP" 2>/dev/null || true)
    [[ -n "$peer_route" ]] || die "The egress public IP ${PEER_PUBLIC_IP} is not routable from this server."
    if grep -q "dev ${XFRM_IF}" <<<"$peer_route"; then
        die 'The egress public IP resolves through the proposed XFRM interface. Fix the main route first.'
    fi

    section_title 'Pairing summary'
    print_check info 'Egress public IPv4' "$PEER_PUBLIC_IP"
    print_check info 'IKE transport' "$(transport_label)"
    print_check info 'Tunnel network' "$TUNNEL_CIDR"
    print_check info 'Ingress XFRM address' "$INGRESS_XFRM_CIDR"
    print_check info 'Public DNS via egress' "$DNS_PRIMARY, $DNS_SECONDARY"
    print_check info 'Local DNS fallback' "$DNS_FALLBACK"

    write_ingress_config
    load_config
    if ! (
        write_common_xfrm_files
        write_strongswan_common_files
        write_swanctl_ingress
        write_ingress_routing_files
        write_ingress_healthcheck_files
        activate_ingress
    ); then
        rollback_failed_setup ingress
        return 1
    fi

    if ! attempt_tunnel_connection; then
        rollback_failed_setup ingress
        return 1
    fi

    if ! ping -I "$XFRM_IF" -c 1 -W 3 "$XFRM_PEER_IP" >/dev/null 2>&1; then
        error 'The CHILD SA exists, but the remote XFRM peer is unreachable.'
        rollback_failed_setup ingress
        return 1
    fi

    if ! finalize_ingress_after_tunnel; then
        rollback_failed_setup ingress
        return 1
    fi

    success 'Required ingress tunnel and policy-routing path are committed.'
    verify_ingress_paths || warn 'Post-install route verification reported a warning.'
    cleanup_scattered_legacy_files || true

    cat >"$TTY_OUT" <<EOF_SUMMARY

${C_BOLD}${C_GREEN}Ingress setup complete${C_RESET}
Role:                    ingress
Detected interface:      ${WAN_IF}
Detected interface IP:   ${LOCAL_IP}
Direct public-IP check: ${PUBLIC_IP:-unavailable (no multi-source consensus)}
Egress public peer:      ${PEER_PUBLIC_IP}
IKE transport:           $(transport_label)
XFRM source address:     ${INGRESS_XFRM_CIDR}
Routing table:           ${ROUTE_TABLE}
DNS order:               ${DNS_PRIMARY}, ${DNS_SECONDARY}, ${DNS_FALLBACK}

Managed files:            ${CONFIG_DIR}

Applications select the remote egress by binding their outbound socket to ${INGRESS_XFRM_IP}.
Resolver or health-monitor warnings can be retried later with: dragon-fruit-relay repair
EOF_SUMMARY
}

repair_current() {
    load_config
    install_dependencies
    info "Reapplying Dragon Fruit Relay configuration for role: ${ROLE}"
    ensure_managed_layout
    write_managed_readme
    install_self_copy
    write_common_xfrm_files
    write_strongswan_common_files

    if [[ "$ROLE" == ingress ]]; then
        write_ingress_config
        write_swanctl_ingress
        write_ingress_routing_files
        write_ingress_healthcheck_files
        activate_ingress
        if attempt_tunnel_connection && ping -I "$XFRM_IF" -c 1 -W 3 "$XFRM_PEER_IP" >/dev/null 2>&1; then
            finalize_ingress_after_tunnel
            verify_ingress_paths
        else
            warn 'Managed files were repaired, but the peer is still disconnected. DNS was not replaced.'
        fi
    elif [[ "$ROLE" == egress ]]; then
        write_egress_config
        write_swanctl_egress
        activate_egress
        generate_pairing_token
    else
        die "Unknown configured role: ${ROLE}"
    fi
    cleanup_scattered_legacy_files
    success 'Dragon Fruit Relay configuration was reapplied.'
}

pause_screen() {
    [[ -t 4 ]] || return 0
    printf '\n%sPress Enter to continue...%s' "$C_DIM" "$C_RESET" >"$TTY_OUT"
    IFS= read -r _ <"$TTY_IN" || true
}

clear_screen() {
    [[ -t 4 ]] && printf '\033[2J\033[H' >"$TTY_OUT" || true
}

section_title() {
    printf '\n%s%s-- %s --%s\n' "$C_BOLD" "$C_CYAN" "$1" "$C_RESET" >"$TTY_OUT"
}

print_check() {
    local level="$1" label="$2" detail="${3:-}"
    local badge color
    case "$level" in
        pass) badge='OK'; color="$C_GREEN" ;;
        warn) badge='!'; color="$C_YELLOW" ;;
        fail) badge='X'; color="$C_RED" ;;
        info) badge='i'; color="$C_BLUE" ;;
        *) badge='-'; color="$C_WHITE" ;;
    esac
    printf '  %s[%s]%s %-30s %s\n' "$color" "$badge" "$C_RESET" "$label" "$detail" >"$TTY_OUT"
}

unit_state() {
    systemctl is-active "$1" 2>/dev/null || true
}


safe_sas() {
    swanctl --list-sas 2>/dev/null || true
}

policy_rule_matches() {
    local pref="$1" selector="$2" address="$3" table="$4"
    ip -4 rule show 2>/dev/null | awk \
        -v pref="${pref}:" \
        -v selector="$selector" \
        -v address="$address" \
        -v table="$table" '
        $1 == pref {
            selector_ok = 0
            table_ok = 0
            for (i = 1; i <= NF; i++) {
                if ($i == selector && ($(i+1) == address || $(i+1) == address "/32")) selector_ok = 1
                if (($i == "lookup" || $i == "table") && $(i+1) == table) table_ok = 1
            }
            if (selector_ok && table_ok) found = 1
        }
        END { exit(found ? 0 : 1) }
    '
}

managed_rule_line() {
    local pref="$1"
    ip -4 rule show 2>/dev/null | awk -v pref="${pref}:" '$1 == pref {print; exit}'
}

service_row() {
    local unit="$1" label="${2:-$1}"
    local load active sub enabled result color badge display boot_color
    load=$(systemctl show "$unit" -p LoadState --value 2>/dev/null || true)
    active=$(systemctl show "$unit" -p ActiveState --value 2>/dev/null || true)
    sub=$(systemctl show "$unit" -p SubState --value 2>/dev/null || true)
    enabled=$(systemctl is-enabled "$unit" 2>/dev/null || true)
    result=$(systemctl show "$unit" -p Result --value 2>/dev/null || true)

    if [[ "$load" == 'not-found' || -z "$load" ]]; then
        color="$C_RED"; badge='X'; display='NOT FOUND'
    elif [[ "$active" == 'active' ]]; then
        color="$C_GREEN"; badge='●'
        case "$sub" in
            running) display='RUNNING' ;;
            exited) display='READY' ;;
            waiting) display='WAITING' ;;
            *) display="${sub^^}" ;;
        esac
    elif [[ "$active" == 'failed' ]]; then
        color="$C_RED"; badge='X'; display='FAILED'
    elif [[ "$active" == 'activating' ]]; then
        color="$C_CYAN"; badge='●'; display='STARTING'
    else
        color="$C_YELLOW"; badge='○'; display="${active^^}"
    fi

    if [[ "$enabled" == 'enabled' || "$enabled" == 'static' ]]; then
        boot_color="$C_GREEN"
    else
        boot_color="$C_YELLOW"
    fi

    printf '  %-31s %s%s %-11s%s  boot:%s%-9s%s  result:%s\n' \
        "$label" "$color" "$badge" "$display" "$C_RESET" \
        "$boot_color" "${enabled:-unknown}" "$C_RESET" "${result:-n/a}" >"$TTY_OUT"
}
route_line() {
    local target="$1" source="${2:-}"
    if [[ -n "$source" ]]; then
        ip -4 route get "$target" from "$source" 2>/dev/null | head -n 1 || true
    else
        ip -4 route get "$target" 2>/dev/null | head -n 1 || true
    fi
}

route_summary() {
    local target="$1" source="${2:-}" line dev via src table output
    line=$(route_line "$target" "$source")
    [[ -n "$line" ]] || { printf 'no route'; return; }

    dev=$(awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' <<<"$line")
    via=$(awk '{for(i=1;i<=NF;i++) if($i=="via") {print $(i+1); exit}}' <<<"$line")
    src=$(awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' <<<"$line")
    table=$(awk '{for(i=1;i<=NF;i++) if($i=="table") {print $(i+1); exit}}' <<<"$line")

    output="${dev:-unknown interface}"
    [[ -n "$via" ]] && output+=" via ${via}"
    [[ -n "$table" ]] && output+=" | table ${table}"
    [[ -n "$src" ]] && output+=" | src ${src}"
    printf '%s' "$output"
}

route_uses_interface() {
    local target="$1" source="${2:-}" expected="$3" line
    line=$(route_line "$target" "$source")
    [[ "$line" == *"dev $expected"* ]]
}

print_route_check() {
    local label="$1" target="$2" source="$3" expected="$4" detail
    detail=$(route_summary "$target" "$source")
    if route_uses_interface "$target" "$source" "$expected"; then
        print_check pass "$label" "$detail"
    else
        print_check fail "$label" "$detail"
    fi
}

xfrm_counter_summary() {
    local iface="$1"
    if [[ ! -d "/sys/class/net/${iface}/statistics" ]]; then
        printf 'unavailable'
        return
    fi
    local rx_bytes tx_bytes rx_packets tx_packets
    rx_bytes=$(cat "/sys/class/net/${iface}/statistics/rx_bytes" 2>/dev/null || echo 0)
    tx_bytes=$(cat "/sys/class/net/${iface}/statistics/tx_bytes" 2>/dev/null || echo 0)
    rx_packets=$(cat "/sys/class/net/${iface}/statistics/rx_packets" 2>/dev/null || echo 0)
    tx_packets=$(cat "/sys/class/net/${iface}/statistics/tx_packets" 2>/dev/null || echo 0)
    if command -v numfmt >/dev/null 2>&1; then
        rx_bytes=$(numfmt --to=iec "$rx_bytes" 2>/dev/null || echo "$rx_bytes")
        tx_bytes=$(numfmt --to=iec "$tx_bytes" 2>/dev/null || echo "$tx_bytes")
    fi
    printf 'RX %s / %s packets | TX %s / %s packets' "$rx_bytes" "$rx_packets" "$tx_bytes" "$tx_packets"
}

config_summary() {
    section_title 'Relay configuration'
    printf '  %-20s %s\n' 'Role' "$ROLE" >"$TTY_OUT"
    printf '  %-20s %s\n' 'Managed root' "$CONFIG_DIR" >"$TTY_OUT"
    printf '  %-20s %s\n' 'Physical interface' "$WAN_IF" >"$TTY_OUT"
    if [[ "$ROLE" == 'egress' ]]; then
        printf '  %-20s %s\n' 'Public endpoint' "$PUBLIC_IP" >"$TTY_OUT"
    else
        printf '  %-20s %s\n' 'Egress endpoint' "$PEER_PUBLIC_IP" >"$TTY_OUT"
    fi
    printf '  %-20s %s\n' 'UDP transport' "$(transport_description)" >"$TTY_OUT"
    printf '  %-20s %s -> %s\n' 'Tunnel' "$XFRM_LOCAL_IP" "$XFRM_PEER_IP" >"$TTY_OUT"
    if [[ "$ROLE" == 'ingress' ]]; then
        printf '  %-20s %s\n' 'Policy table' "$ROUTE_TABLE" >"$TTY_OUT"
        printf '  %-20s %s -> %s -> %s\n' 'DNS order' "$DNS_PRIMARY" "$DNS_SECONDARY" "$DNS_FALLBACK" >"$TTY_OUT"
    fi
}

check_service_for_dashboard() {
    local unit="$1" label="$2" critical="${3:-yes}" state
    state=$(unit_state "$unit")
    if [[ "$state" == 'active' ]]; then
        print_check pass "$label" "$state"
        return 0
    fi
    if [[ "$critical" == 'yes' ]]; then
        print_check fail "$label" "${state:-unknown}"
        return 1
    fi
    print_check warn "$label" "${state:-unknown}"
    return 2
}

diagnostics_tunnel() {
    load_config
    clear_screen
    banner
    section_title 'Tunnel and traffic'
    config_summary

    section_title 'Services'
    service_row dragonfruit-relay-xfrm.service 'XFRM interface'
    service_row strongswan.service 'strongSwan'

    section_title 'Session state'
    local sas
    sas=$(safe_sas)
    if grep -q 'ESTABLISHED' <<<"$sas"; then
        print_check pass 'IKE session' 'ESTABLISHED'
    else
        print_check fail 'IKE session' 'not established'
    fi
    if grep -q 'INSTALLED' <<<"$sas"; then
        print_check pass 'Encrypted channel' 'INSTALLED'
    else
        print_check fail 'Encrypted channel' 'not installed'
    fi
    printf '  %-30s %s\n' 'Interface counters' "$(xfrm_counter_summary "$XFRM_IF")" >"$TTY_OUT"

    if ping -I "$XFRM_IF" -c 2 -W 3 "$XFRM_PEER_IP" >/dev/null 2>&1; then
        print_check pass 'Peer reachability' "$XFRM_PEER_IP responds"
    else
        print_check fail 'Peer reachability' "$XFRM_PEER_IP did not respond"
    fi

    section_title 'Session details'
    if [[ -n "$sas" ]]; then
        local ike_line child_line in_line out_line
        ike_line=$(grep -m1 'ESTABLISHED' <<<"$sas" || true)
        child_line=$(grep -m1 'INSTALLED' <<<"$sas" || true)
        in_line=$(grep -m1 -E '^[[:space:]]+in[[:space:]]' <<<"$sas" || true)
        out_line=$(grep -m1 -E '^[[:space:]]+out[[:space:]]' <<<"$sas" || true)
        [[ -n "$ike_line" ]] && printf '  %sIKE%s    %s\n' "$C_GREEN" "$C_RESET" "${ike_line#  }" >"$TTY_OUT"
        [[ -n "$child_line" ]] && printf '  %sCHILD%s  %s\n' "$C_GREEN" "$C_RESET" "${child_line#  }" >"$TTY_OUT"
        [[ -n "$in_line" ]] && printf '  %-7s %s\n' 'IN' "$(xargs <<<"$in_line")" >"$TTY_OUT"
        [[ -n "$out_line" ]] && printf '  %-7s %s\n' 'OUT' "$(xargs <<<"$out_line")" >"$TTY_OUT"
    else
        print_check fail 'Security associations' 'none loaded'
    fi
}

diagnostics_routing() {
    load_config
    clear_screen
    banner
    section_title 'Routing and DNS paths'

    if [[ "$ROLE" != ingress ]]; then
        print_check info 'Selective policy routing' 'Configured on the ingress node only.'
        printf '  %-28s %s\n' 'Default Internet path' "$(route_summary 9.9.9.9)" >"$TTY_OUT"
        return 0
    fi

    local sas
    sas=$(safe_sas)
    section_title 'Always-valid paths'
    print_route_check 'Direct Internet' 9.9.9.9 '' "$WAN_IF"
    print_route_check 'IKE endpoint exclusion' "$PEER_PUBLIC_IP" '' "$WAN_IF"
    print_route_check 'Local DNS fallback' "$DNS_FALLBACK" '' "$WAN_IF"

    if ! grep -q ESTABLISHED <<<"$sas" || ! grep -q INSTALLED <<<"$sas"; then
        section_title 'Relay paths'
        print_check info 'Policy table' 'PENDING - not installed until IKE and CHILD SAs establish'
        print_check info 'Public DNS routes' 'PENDING - current resolver remains on the local path'
        print_check info 'Next action' 'Run Start / reconnect to see the exact IKE failure.'
        return 0
    fi

    section_title 'Active relay paths'
    print_route_check 'Relay egress' 9.9.9.9 "$XFRM_LOCAL_IP" "$XFRM_IF"
    print_route_check 'Primary DNS' "$DNS_PRIMARY" '' "$XFRM_IF"
    print_route_check 'Secondary DNS' "$DNS_SECONDARY" '' "$XFRM_IF"

    section_title 'Installed policy rules'
    policy_rule_matches "$RULE_DNS_PRIMARY" to "$DNS_PRIMARY" "$ROUTE_TABLE" && \
        print_check pass 'Primary DNS rule' "$(managed_rule_line "$RULE_DNS_PRIMARY")" || \
        print_check fail 'Primary DNS rule' "expected destination $DNS_PRIMARY -> table $ROUTE_TABLE"
    policy_rule_matches "$RULE_DNS_SECONDARY" to "$DNS_SECONDARY" "$ROUTE_TABLE" && \
        print_check pass 'Secondary DNS rule' "$(managed_rule_line "$RULE_DNS_SECONDARY")" || \
        print_check fail 'Secondary DNS rule' "expected destination $DNS_SECONDARY -> table $ROUTE_TABLE"
    policy_rule_matches "$RULE_TUNNEL_SOURCE" from "$XFRM_LOCAL_IP" "$ROUTE_TABLE" && \
        print_check pass 'Relay source rule' "$(managed_rule_line "$RULE_TUNNEL_SOURCE")" || \
        print_check fail 'Relay source rule' "expected source $XFRM_LOCAL_IP -> table $ROUTE_TABLE"

    local table_line
    table_line=$(ip -4 route show table "$ROUTE_TABLE" 2>/dev/null | head -n 1 || true)
    [[ "$table_line" == default*"dev $XFRM_IF"* ]] && \
        print_check pass "Routing table $ROUTE_TABLE" "$table_line" || \
        print_check fail "Routing table $ROUTE_TABLE" "${table_line:-default route missing}"

    section_title 'Resolver order'
    grep -E '^(options|nameserver)' /etc/resolv.conf 2>/dev/null | sed 's/^/  /' >"$TTY_OUT" || print_check warn '/etc/resolv.conf' 'unavailable'
}

write_diagnostic_report() {
    load_config
    local report="${LOG_DIR}/diagnostics-$(date +%Y%m%d-%H%M%S).txt"
    mkdir -p "$LOG_DIR"
    {
        printf 'Dragon Fruit Relay diagnostic report\n'
        printf 'Generated: %s\n' "$(date -Is)"
        printf 'Installer version: %s\n\n' "$APP_VERSION"
        printf '%s\n' '=== SYSTEM ==='
        uname -a
        cat /etc/os-release
        printf '\n%s\n' '=== CONFIGURATION (PSK REDACTED) ==='
        sed -E 's/^PSK=.*/PSK=[REDACTED]/' "$CONFIG_FILE"
        printf '\n%s\n' '=== SERVICE STATES ==='
        systemctl show dragonfruit-relay-xfrm.service strongswan.service \
            -p Id -p LoadState -p ActiveState -p SubState -p UnitFileState -p Result 2>&1 || true
        if [[ "$ROLE" == 'ingress' ]]; then
            systemctl show dragonfruit-relay-routing.service dragonfruit-relay-dns.service dragonfruit-relay-healthcheck.timer \
                -p Id -p LoadState -p ActiveState -p SubState -p UnitFileState -p Result 2>&1 || true
        else
            systemctl show netfilter-persistent.service \
                -p Id -p LoadState -p ActiveState -p SubState -p UnitFileState -p Result 2>&1 || true
        fi
        printf '\n%s\n' '=== STRONGSWAN SAs ==='
        swanctl --list-sas 2>&1 || true
        printf '\n%s\n' '=== XFRM INTERFACE ==='
        ip -d link show dev "$XFRM_IF" 2>&1 || true
        ip -4 address show dev "$XFRM_IF" 2>&1 || true
        ip -s link show dev "$XFRM_IF" 2>&1 || true
        printf '\n%s\n' '=== XFRM STATE AND POLICY ==='
        ip xfrm state 2>&1 | sed -E 's/(auth-trunc|enc|aead) .*/\1 [REDACTED]/' || true
        ip xfrm policy 2>&1 || true
        printf '\n%s\n' '=== ROUTING ==='
        ip rule show 2>&1 || true
        ip -4 route show table main 2>&1 || true
        [[ "$ROLE" == 'ingress' ]] && ip route show table "$ROUTE_TABLE" 2>&1 || true
        printf '\n%s\n' '=== RESOLVER ==='
        cat /etc/resolv.conf 2>&1 || true
        printf '\n%s\n' '=== FIREWALL / NAT ==='
        iptables-save 2>&1 | grep -E 'dragonfruit-relay|^\*|^COMMIT|^-P' || true
        printf '\n%s\n' '=== RECENT JOURNAL ==='
        journalctl -u strongswan.service -u dragonfruit-relay-xfrm.service --since '-2 hours' --no-pager -n 150 2>&1 || true
        printf '\n%s\n' '=== INSTALLER LOG ==='
        tail -n 150 "$LOG_FILE" 2>&1 || true
    } >"$report"
    chmod 600 "$report"
    success "Diagnostic report written to $report"
}

diagnostics_preflight() {
    clear_screen
    banner
    section_title 'Ready to configure'

    local iface gateway public_ip route_default
    iface=$(detect_default_interface || true)
    gateway=$(detect_default_gateway || true)
    public_ip=$(detect_public_ipv4 || true)
    route_default=$(ip -4 route show default 2>/dev/null | head -n 1 || true)

    print_check pass 'Platform' "${PRETTY_NAME:-Debian} with systemd"
    [[ -n "$iface" ]] && print_check pass 'Internet interface' "$iface" || print_check fail 'Internet interface' 'not detected'
    [[ -n "$gateway" ]] && print_check pass 'Default gateway' "$gateway" || print_check warn 'Default gateway' 'not detected'
    [[ -n "$public_ip" ]] && print_check info 'Observed public IPv4' "$public_ip" || print_check warn 'Observed public IPv4' 'external lookup failed'
    print_check info 'Default route' "${route_default:-missing}"

    section_title 'Conflicts'
    if ip link show dev xfrm0 >/dev/null 2>&1; then
        print_check warn 'xfrm0' 'already exists; remove or rebuild the existing relay first'
    else
        print_check pass 'xfrm0' 'available'
    fi
    legacy_routevpn_detected && print_check warn 'Legacy RouteVPN' 'old files or services detected' || print_check pass 'Legacy RouteVPN' 'not detected'

    section_title 'Next step'
    printf '  Choose %sCreate egress%s on the public exit server first, then paste its token into %sCreate ingress%s.\n' \
        "$C_GREEN" "$C_RESET" "$C_GREEN" "$C_RESET" >"$TTY_OUT"
}
diagnostics_menu() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        diagnostics_preflight
        pause_screen
        return 0
    fi

    while true; do
        clear_screen
        banner
        printf '\n%s%sDIAGNOSTICS%s  %sFocused views only%s\n' "$C_BOLD" "$C_MAGENTA" "$C_RESET" "$C_DIM" "$C_RESET" >"$TTY_OUT"
        cat >"$TTY_OUT" <<EOF_MENU

  ${C_GREEN}1)${C_RESET} Health summary
  ${C_CYAN}2)${C_RESET} Tunnel session and traffic counters
  ${C_CYAN}3)${C_RESET} Routing rules and DNS paths
  ${C_CYAN}4)${C_RESET} Services, ports, forwarding and Internet path
  ${C_YELLOW}5)${C_RESET} Recent warnings and failures
  ${C_MAGENTA}6)${C_RESET} Export detailed redacted report
  ${C_RED}0)${C_RESET} Back
EOF_MENU
        local choice
        choice=$(prompt 'Select a diagnostic option: ')
        case "$choice" in
            1) diagnostics_overview || true; pause_screen ;;
            2) diagnostics_tunnel; pause_screen ;;
            3) diagnostics_routing; pause_screen ;;
            4) diagnostics_ports; pause_screen ;;
            5) diagnostics_logs; pause_screen ;;
            6) write_diagnostic_report; pause_screen ;;
            0) return 0 ;;
            *) warn 'Invalid selection.'; sleep 1 ;;
        esac
    done
}
restore_package_state() {
    [[ -f "$PACKAGE_STATE_FILE" ]] || return 0

    local reinstall=()
    local package state
    while IFS='=' read -r package state; do
        case "$package" in
            RESOLVED_WAS_ACTIVE|RESOLVED_WAS_ENABLED|*_UNIT_EXISTED|*_UNIT_WAS_ACTIVE|*_UNIT_WAS_ENABLED) continue ;;
        esac
        if [[ "$state" == 'present' ]] && ! package_installed "$package"; then
            reinstall+=("$package")
        fi
    done <"$PACKAGE_STATE_FILE"

    if ((${#reinstall[@]})); then
        info 'Reinstalling packages that existed before Dragon Fruit Relay...'
        export DEBIAN_FRONTEND=noninteractive
        apt-get update >>"$LOG_FILE" 2>&1
        apt-get install -y "${reinstall[@]}" >>"$LOG_FILE" 2>&1
    fi
}

remove_added_packages() {
    [[ -f "$PACKAGE_STATE_FILE" ]] || return 0
    local remove=()
    local package state
    while IFS='=' read -r package state; do
        case "$package" in
            RESOLVED_WAS_ACTIVE|RESOLVED_WAS_ENABLED|*_UNIT_EXISTED|*_UNIT_WAS_ACTIVE|*_UNIT_WAS_ENABLED) continue ;;
        esac
        if [[ "$state" == 'absent' ]] && package_installed "$package"; then
            remove+=("$package")
        fi
    done <"$PACKAGE_STATE_FILE"

    if ((${#remove[@]})) && confirm 'Remove packages that Dragon Fruit Relay originally installed?' no; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get purge -y "${remove[@]}" >>"$LOG_FILE" 2>&1
    fi
}

remove_managed_integration_path() {
    local path="$1" target=''
    [[ -e "$path" || -L "$path" ]] || return 0
    if [[ -L "$path" ]]; then
        target=$(readlink -f -- "$path" 2>/dev/null || true)
        if [[ "$target" == "$CONFIG_DIR"/* ]]; then
            rm -f -- "$path"
        fi
        return 0
    fi
    if [[ -f "$path" ]] && grep -q '^# Managed by Dragon Fruit Relay\.' "$path" 2>/dev/null; then
        rm -f -- "$path"
    fi
}

remove_runtime_and_files() {
    local role="$1"
    local old_xfrm_if="${XFRM_IF:-$DEFAULT_XFRM_IF}" old_table="${ROUTE_TABLE:-}"
    local p1="${RULE_DNS_PRIMARY:-}" p2="${RULE_DNS_SECONDARY:-}" p3="${RULE_TUNNEL_SOURCE:-}"

    systemctl disable --now dragonfruit-relay-healthcheck.timer >/dev/null 2>&1 || true
    rm -f "$SYSTEMD_DIR/timers.target.wants/dragonfruit-relay-healthcheck.timer" \
        "$SYSTEMD_DIR/multi-user.target.wants/dragonfruit-relay-xfrm.service" \
        "$SYSTEMD_DIR/multi-user.target.wants/dragonfruit-relay-routing.service" \
        "$SYSTEMD_DIR/multi-user.target.wants/dragonfruit-relay-dns.service"
    systemctl stop dragonfruit-relay-healthcheck.service dragonfruit-relay-dns.service dragonfruit-relay-routing.service >/dev/null 2>&1 || true
    swanctl --terminate --ike dragonfruit_relay >/dev/null 2>&1 || true

    if [[ "$role" == ingress ]]; then
        [[ -x "$LIB_DIR/routing-remove" ]] && "$LIB_DIR/routing-remove" >/dev/null 2>&1 || true
        delete_rule_pref_all "$p1"
        delete_rule_pref_all "$p2"
        delete_rule_pref_all "$p3"
        [[ "$old_table" =~ ^[0-9]+$ ]] && ip -4 route flush table "$old_table" 2>/dev/null || true
    elif [[ "$role" == egress ]]; then
        remove_egress_network_rules || true
    fi
    remove_all_dragonfruit_network_rules || true
    remove_legacy_firewall_artifacts

    systemctl stop strongswan.service >/dev/null 2>&1 || true
    systemctl disable --now dragonfruit-relay-xfrm.service >/dev/null 2>&1 || true
    delete_link_bounded "$old_xfrm_if" || true

    rm -f "$SYSTEMD_DIR"/dragonfruit-relay-*.service "$SYSTEMD_DIR"/dragonfruit-relay-*.timer \
        "$INGRESS_SWANCTL_CANONICAL" "$LEGACY_TOKEN_FILE"
    if [[ -e "$INGRESS_SWANCTL_MARKER" ]]; then
        rm -rf -- "$INGRESS_SWANCTL_DIR"
    fi
    remove_managed_integration_path "$SWANCTL_FILE"
    remove_managed_integration_path "$STRONGSWAN_ROUTE_FILE"
    remove_managed_integration_path "$STRONGSWAN_OVERRIDE_FILE"
    remove_managed_integration_path "$SYSCTL_FILE"
    rmdir "$SWANCTL_CLIENT_ROOT" 2>/dev/null || true
    [[ -L /etc/resolv.conf && "$(readlink -f /etc/resolv.conf 2>/dev/null || true)" == "$RESOLVER_MANAGED_FILE" ]] && rm -f /etc/resolv.conf || true
    rm -rf "$LEGACY_LIB_DIR" "$CONFIG_DIR"
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed >/dev/null 2>&1 || true

    REMOVED_XFRM_IF="$old_xfrm_if"
    REMOVED_ROUTE_TABLE="$old_table"
    REMOVED_RULE_DNS_PRIMARY="$p1"
    REMOVED_RULE_DNS_SECONDARY="$p2"
    REMOVED_RULE_TUNNEL_SOURCE="$p3"
}

restore_pre_routevpn_state() {
    local role="$1"
    restore_package_state
    restore_originals
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed >/dev/null 2>&1 || true

    if [[ -f "$PACKAGE_STATE_FILE" ]]; then
        local ra re
        ra=$(awk -F= '$1=="RESOLVED_WAS_ACTIVE" {print $2}' "$PACKAGE_STATE_FILE")
        re=$(awk -F= '$1=="RESOLVED_WAS_ENABLED" {print $2}' "$PACKAGE_STATE_FILE")
        [[ "$re" == yes ]] && systemctl enable systemd-resolved.service >/dev/null 2>&1 || true
        [[ "$ra" == yes ]] && systemctl start systemd-resolved.service >/dev/null 2>&1 || true
    fi

    # Reapply host sysctl files first, then restore any pre-install runtime
    # overrides captured on the egress node.
    sysctl --system >>"$LOG_FILE" 2>&1 || true
    if [[ "$role" == egress ]]; then
        restore_egress_runtime_state
    fi

    restore_unit_state strongswan.service STRONGSWAN
    if [[ "$role" == egress ]]; then
        restore_unit_state netfilter-persistent.service NETFILTER
    elif [[ "$role" == ingress ]]; then
        # restore_originals has restored the pre-install dhcpcd.conf. Reload an
        # already-running per-interface client so the original policy applies.
        reload_dhcpcd_configuration "${WAN_IF:-}"
    fi
    return 0
}

remove_tunnel_configuration() {
    local skip_confirm="${1:-no}"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        local residual=no
        [[ -d "$CONFIG_DIR" || -d "$STATE_DIR" || -d "$LEGACY_LIB_DIR" ]] && residual=yes
        compgen -G "$SYSTEMD_DIR/dragonfruit-relay-*.service" >/dev/null && residual=yes
        compgen -G "$SYSTEMD_DIR/dragonfruit-relay-*.timer" >/dev/null && residual=yes
        ip link show dev "$DEFAULT_XFRM_IF" >/dev/null 2>&1 && residual=yes
        [[ "$residual" == yes ]] || die 'Dragon Fruit Relay is not configured and no residual state was found.'
        [[ "$skip_confirm" == yes ]] || confirm 'Remove residual Dragon Fruit Relay state and restore available backups?' no || return 0
        clean_abandoned_install_before_setup
        rm -rf "$STATE_DIR" "$CONFIG_DIR" "$LEGACY_LIB_DIR"
        success 'Residual relay state was removed and available original state was restored.'
        return 0
    fi

    load_config
    local old_role="$ROLE"
    [[ "$skip_confirm" == yes ]] || confirm 'Delete the relay and restore the exact pre-install state?' no || return 0

    remove_runtime_and_files "$old_role"
    restore_pre_routevpn_state "$old_role"
    delete_link_bounded "$REMOVED_XFRM_IF" || true
    rm -rf "$CONFIG_DIR" "$LEGACY_LIB_DIR"
    systemctl daemon-reload >/dev/null 2>&1 || true

    verify_managed_runtime_absent "$REMOVED_XFRM_IF" "$REMOVED_ROUTE_TABLE" \
        "$REMOVED_RULE_DNS_PRIMARY" "$REMOVED_RULE_DNS_SECONDARY" "$REMOVED_RULE_TUNNEL_SOURCE" || \
        die 'Removal did not complete. The state directory was retained for diagnosis.'

    rm -rf "$STATE_DIR"
    success 'Relay removed; original files, resolver, service states, sysctls and firewall state were restored.'
}

rebuild_tunnel() {
    if [[ -f "$CONFIG_FILE" ]]; then
        confirm 'Destroy the current tunnel and create a new one?' no || return 0
        remove_tunnel_configuration yes
    fi

    clear_screen
    banner
    cat >"$TTY_OUT" <<EOF_ROLE

${C_BOLD}${C_MAGENTA}Create a new tunnel${C_RESET}

${C_GREEN}1)${C_RESET} Configure this server as the egress node
${C_GREEN}2)${C_RESET} Configure this server as the ingress node
${C_RED}0)${C_RESET} Cancel
EOF_ROLE
    local choice
    choice=$(prompt 'Select the new role: ')
    case "$choice" in
        1) setup_egress ;;
        2) setup_ingress ;;
        0) return 0 ;;
        *) warn 'Invalid selection.' ;;
    esac
}

uninstall_routevpn() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        local residual=no
        [[ -d "$CONFIG_DIR" || -d "$STATE_DIR" || -d "$LEGACY_LIB_DIR" ]] && residual=yes
        [[ -e "$CLI_COMMAND" || -L "$CLI_COMMAND" ]] && residual=yes
        compgen -G "$SYSTEMD_DIR/dragonfruit-relay-*.service" >/dev/null && residual=yes
        compgen -G "$SYSTEMD_DIR/dragonfruit-relay-*.timer" >/dev/null && residual=yes
        ip link show dev "$DEFAULT_XFRM_IF" >/dev/null 2>&1 && residual=yes
        [[ "$residual" == yes ]] || die 'No Dragon Fruit Relay installation or residual state was found.'
        confirm 'Remove all residual Dragon Fruit Relay state and restore available backups?' no || return 0
        clean_abandoned_install_before_setup
        remove_added_packages
        rm -rf "$STATE_DIR" "$CONFIG_DIR" "$LEGACY_LIB_DIR"
        rm -f "$LEGACY_TOKEN_FILE"
        remove_cli_command
        success 'Residual Dragon Fruit Relay state and the management command were completely removed.'
        return 0
    fi

    load_config
    local old_role="$ROLE"
    confirm 'Completely uninstall Dragon Fruit Relay and restore original state?' no || return 0
    remove_runtime_and_files "$old_role"
    restore_pre_routevpn_state "$old_role"
    remove_added_packages
    rm -rf "$STATE_DIR" "$CONFIG_DIR" "$LEGACY_LIB_DIR"
    rm -f "$LEGACY_TOKEN_FILE"
    remove_cli_command
    systemctl daemon-reload >/dev/null 2>&1 || true
    success 'Dragon Fruit Relay, its management command, and all managed state were completely removed; the pre-install state was restored.'
}

legacy_routevpn_detected() {
    [[ -e /etc/routevpn/routevpn.conf || -e /etc/systemd/system/routevpn-xfrm.service || -d /usr/local/lib/routevpn ]]
}

cleanup_legacy_routevpn() {
    warn 'A legacy RouteVPN v0.x installation was detected.'
    confirm 'Remove the legacy RouteVPN services and partial tunnel before continuing?' yes || return 1

    local legacy_cfg=/etc/routevpn/routevpn.conf
    local old_xfrm=xfrm0 old_table='' p1='' p2='' p3=''
    if [[ -f "$legacy_cfg" ]]; then
        # shellcheck disable=SC1090
        source "$legacy_cfg" || true
        old_xfrm="${XFRM_IF:-xfrm0}"
        old_table="${ROUTE_TABLE:-}"
        p1="${RULE_DNS_PRIMARY:-}"
        p2="${RULE_DNS_SECONDARY:-}"
        p3="${RULE_TUNNEL_SOURCE:-}"
    fi

    systemctl disable --now routevpn-healthcheck.timer routevpn-dns.service routevpn-routing.service routevpn-xfrm.service 2>/dev/null || true
    [[ -n "$p1" ]] && ip -4 rule del pref "$p1" 2>/dev/null || true
    [[ -n "$p2" ]] && ip -4 rule del pref "$p2" 2>/dev/null || true
    [[ -n "$p3" ]] && ip -4 rule del pref "$p3" 2>/dev/null || true
    [[ -n "$old_table" ]] && ip -4 route flush table "$old_table" 2>/dev/null || true
    delete_link_bounded "$old_xfrm" || true

    rm -f \
        /etc/systemd/system/routevpn-xfrm.service \
        /etc/systemd/system/routevpn-routing.service \
        /etc/systemd/system/routevpn-dns.service \
        /etc/systemd/system/routevpn-healthcheck.service \
        /etc/systemd/system/routevpn-healthcheck.timer \
        /etc/strongswan.d/99-routevpn.conf \
        /etc/systemd/system/strongswan.service.d/routevpn.conf \
        /root/routevpn-pairing-token.txt
    rm -rf /etc/routevpn /usr/local/lib/routevpn
    systemctl daemon-reload
    systemctl reset-failed
    success 'Legacy RouteVPN runtime files were removed. Existing backups under /var/lib/routevpn were left untouched.'
}

handle_legacy_routevpn() {
    if legacy_routevpn_detected && [[ ! -f "$CONFIG_FILE" ]]; then
        clear_screen
        banner
        cleanup_legacy_routevpn || warn 'Legacy installation was not removed. New setup may conflict with xfrm0 or old services.'
        pause_screen
    fi
}

set_live_status() {
    LIVE_STATUS="$1"; LIVE_COLOR="$2"; LIVE_REASON="$3"
}

print_menu() {
    local role='-' transport='-'
    evaluate_live_status
    if [[ -f "$CONFIG_FILE" ]]; then role="$ROLE"; transport=$(transport_label); fi
    cat >"$TTY_OUT" <<EOF_MENU

${C_BOLD}${C_WHITE}Status${C_RESET}  ${LIVE_COLOR}${LIVE_STATUS}${C_RESET}   ${C_BOLD}Role${C_RESET}  ${C_CYAN}${role}${C_RESET}   ${C_BOLD}Transport${C_RESET}  ${transport}
${C_DIM}Health: ${LIVE_REASON}${C_RESET}

${C_BOLD}${C_MAGENTA}SETUP${C_RESET}
  ${C_GREEN}1)${C_RESET} Create egress relay and pairing token
  ${C_GREEN}2)${C_RESET} Create ingress relay from pairing token
  ${C_GREEN}3)${C_RESET} Rebuild as a new relay

${C_BOLD}${C_MAGENTA}OPERATE${C_RESET}
  ${C_CYAN}4)${C_RESET} Health overview
  ${C_CYAN}5)${C_RESET} Diagnostics
  ${C_CYAN}6)${C_RESET} Start / reconnect tunnel
  ${C_YELLOW}7)${C_RESET} Stop tunnel temporarily
  ${C_CYAN}8)${C_RESET} Repair managed configuration
  ${C_CYAN}9)${C_RESET} Run recovery now
  ${C_CYAN}10)${C_RESET} Show pairing token ${C_DIM}(egress)${C_RESET}

${C_BOLD}${C_MAGENTA}REMOVE${C_RESET}
  ${C_YELLOW}11)${C_RESET} Delete relay and restore previous state
  ${C_RED}12)${C_RESET} Uninstall and optionally remove added packages

  ${C_RED}0)${C_RESET} Exit
EOF_MENU
}

hub_configured() {
    [[ -f "$HOST_CONFIG_FILE" ]]
}

legacy_single_configured() {
    [[ -f "$CONFIG_FILE" && ! -f "$HOST_CONFIG_FILE" ]] || return 1
    (
        set +u
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
        [[ "${ROLE:-}" == egress || "${CONFIG_SCHEMA:-0}" != 5 ]]
    )
}

legacy_config_role() {
    [[ -r "$CONFIG_FILE" ]] || return 1
    (
        set +u
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
        printf '%s' "${ROLE:-unknown}"
    )
}

claim_managed_namespace() {
    local directory="$1"
    local marker="$directory/.dragonfruit-relay-root"
    if [[ -d "$directory" && ! -e "$marker" ]]; then
        if find "$directory" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
            die "Refusing to claim non-empty unmanaged directory: ${directory}"
        fi
    elif [[ -e "$directory" && ! -d "$directory" ]]; then
        die "Required managed directory path is not a directory: ${directory}"
    fi
    install -d -m 0750 "$directory"
    : >"$marker"
    chmod 0640 "$marker"
}

ensure_hub_layout() {
    install -d -m 0750 "$CONFIG_DIR" "$CLIENTS_DIR" "$HUB_BIN_DIR" "$SYSCTL_DIR"
    install -d -m 0700 "$SECRETS_DIR" "$STATE_DIR" "$BACKUP_DIR"
    claim_managed_namespace "$SWANCTL_CLIENT_ROOT"
    claim_managed_namespace "$STRONGSWAN_CLIENT_ROOT"
    install -d -m 0755 /run/dragonfruit-relay
}

load_host_config() {
    [[ -r "$HOST_CONFIG_FILE" ]] || die 'This node is not configured as a Dragon Fruit Relay egress hub.'
    # shellcheck disable=SC1090
    source "$HOST_CONFIG_FILE"
    [[ "${ROLE:-}" == 'egress-hub' ]] || die "Invalid hub role in ${HOST_CONFIG_FILE}."
}

profile_dir() { printf '%s/%s' "$CLIENTS_DIR" "$1"; }
profile_config_file() { printf '%s/profile.conf' "$(profile_dir "$1")"; }
profile_token_file() { printf '%s/pairing-token.txt' "$(profile_dir "$1")"; }
profile_swanctl_source() { printf '%s/swanctl.conf' "$(profile_dir "$1")"; }
profile_strongswan_source() { printf '%s/strongswan.conf' "$(profile_dir "$1")"; }
profile_swanctl_dir() { printf '%s/%s' "$SWANCTL_CLIENT_ROOT" "$1"; }
profile_swanctl_canonical() { printf '%s/swanctl.conf' "$(profile_swanctl_dir "$1")"; }
profile_strongswan_canonical() { printf '%s/%s.conf' "$STRONGSWAN_CLIENT_ROOT" "$1"; }
profile_vici_socket() { printf '/run/dragonfruit-relay/%s.vici' "$1"; }
profile_vici_uri() { printf 'unix:///run/dragonfruit-relay/%s.vici' "$1"; }
profile_service() { printf 'dragonfruit-relay-client@%s.service' "$1"; }

profile_exists() {
    [[ -f "$(profile_config_file "$1")" ]]
}

profile_names() {
    [[ -d "$CLIENTS_DIR" ]] || return 0
    local path
    for path in "$CLIENTS_DIR"/*/profile.conf; do
        [[ -f "$path" ]] || continue
        basename "$(dirname "$path")"
    done | LC_ALL=C sort
}

profile_count() {
    local count=0 name
    while IFS= read -r name; do
        [[ -n "$name" ]] && count=$((count + 1))
    done < <(profile_names)
    printf '%s' "$count"
}

validate_profile_name() {
    local value="$1"
    ((${#value} >= 1 && ${#value} <= PROFILE_NAME_MAX)) || return 1
    [[ "$value" =~ ^[a-z0-9][a-z0-9_-]*$ ]]
}

normalize_profile_name() {
    local value="$1"
    value=${value,,}
    value=${value// /-}
    value=$(printf '%s' "$value" | sed -E 's/[^a-z0-9_-]+/-/g; s/[-_]+/-/g; s/^-+//; s/-+$//')
    printf '%s' "${value:0:PROFILE_NAME_MAX}"
}

prompt_profile_name() {
    local entered normalized
    while true; do
        entered=$(prompt 'Connection name: ')
        normalized=$(normalize_profile_name "$entered")
        if ! validate_profile_name "$normalized"; then
            warn "Use a name containing letters, numbers, hyphens or underscores (maximum ${PROFILE_NAME_MAX} characters)."
            continue
        fi
        if profile_exists "$normalized"; then
            warn "A client named '${normalized}' already exists."
            continue
        fi
        if [[ "$entered" != "$normalized" ]]; then
            print_check info 'Profile identifier' "$normalized"
            confirm "Use '${normalized}' as the profile name" yes || continue
        fi
        printf '%s' "$normalized"
        return 0
    done
}

load_client_profile() {
    local name="$1" file
    validate_profile_name "$name" || die "Invalid client profile name: ${name}"
    file=$(profile_config_file "$name")
    [[ -r "$file" ]] || die "Client profile '${name}' does not exist."
    # Clear values that could otherwise leak from a previously loaded profile.
    unset PROFILE_NAME PROFILE_INDEX PORT_MODE IKE_PORT NATT_PORT TUNNEL_CIDR XFRM_IF XFRM_ID XFRM_MTU
    unset INGRESS_XFRM_CIDR EGRESS_XFRM_CIDR INGRESS_XFRM_IP EGRESS_XFRM_IP INGRESS_ID EGRESS_ID
    unset PSK VICI_SOCKET VICI_URI SWANCTL_CANONICAL STRONGSWAN_CANONICAL DNS_PRIMARY DNS_SECONDARY
    # shellcheck disable=SC1090
    source "$file"
    [[ "${PROFILE_NAME:-}" == "$name" ]] || die "Profile metadata mismatch for '${name}'."
}

profile_uses_port() {
    local wanted="$1" except="${2:-}" name
    while IFS= read -r name; do
        [[ -n "$name" && "$name" != "$except" ]] || continue
        if (
            set +u
            # shellcheck disable=SC1090
            source "$(profile_config_file "$name")"
            if [[ "${PORT_MODE:-}" == standard ]]; then
                [[ "$wanted" == 500 || "$wanted" == 4500 ]]
            else
                [[ "${NATT_PORT:-}" == "$wanted" ]]
            fi
        ); then
            return 0
        fi
    done < <(profile_names)
    return 1
}

profile_using_port() {
    local wanted="$1" name
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        if (
            set +u
            # shellcheck disable=SC1090
            source "$(profile_config_file "$name")"
            if [[ "${PORT_MODE:-}" == standard ]]; then
                [[ "$wanted" == 500 || "$wanted" == 4500 ]]
            else
                [[ "${NATT_PORT:-}" == "$wanted" ]]
            fi
        ); then
            printf '%s' "$name"
            return 0
        fi
    done < <(profile_names)
    return 1
}

udp_port_in_use_live() {
    local port="$1"
    ss -H -lun 2>/dev/null | awk -v port=":${port}" '$5 ~ port "$" {found=1} END {exit !found}'
}

standard_transport_available() {
    ! profile_uses_port 500 && ! profile_uses_port 4500 && \
    ! udp_port_in_use_live 500 && ! udp_port_in_use_live 4500
}

custom_port_available() {
    local port="$1" except="${2:-}"
    validate_uint_range "$port" "$PROFILE_PORT_MIN" "$PROFILE_PORT_MAX" || return 1
    ! profile_uses_port "$port" "$except" && ! udp_port_in_use_live "$port"
}

find_next_custom_port() {
    local port
    for ((port=PROFILE_PORT_FIRST; port<=PROFILE_PORT_MAX; port++)); do
        custom_port_available "$port" && { printf '%s' "$port"; return 0; }
    done
    for ((port=PROFILE_PORT_MIN; port<PROFILE_PORT_FIRST; port++)); do
        custom_port_available "$port" && { printf '%s' "$port"; return 0; }
    done
    return 1
}

resolve_requested_transport() {
    local request="${1:-auto}" suggested owner
    case "$request" in
        auto|'')
            if standard_transport_available; then
                NEW_PORT_MODE='standard'; NEW_IKE_PORT=500; NEW_NATT_PORT=4500
            else
                suggested=$(find_next_custom_port) || die 'No available custom UDP port remains in the accepted range.'
                NEW_PORT_MODE='custom'; NEW_IKE_PORT=500; NEW_NATT_PORT="$suggested"
            fi
            ;;
        standard)
            if ! standard_transport_available; then
                owner=$(profile_using_port 500 2>/dev/null || profile_using_port 4500 2>/dev/null || true)
                [[ -n "$owner" ]] && die "Standard UDP 500/4500 is already assigned to profile '${owner}'."
                die 'Standard UDP 500/4500 is already used by another local service.'
            fi
            NEW_PORT_MODE='standard'; NEW_IKE_PORT=500; NEW_NATT_PORT=4500
            ;;
        *[!0-9]* ) die "Invalid port selection '${request}'. Use auto, standard, or a number from ${PROFILE_PORT_MIN}-${PROFILE_PORT_MAX}." ;;
        *)
            validate_uint_range "$request" "$PROFILE_PORT_MIN" "$PROFILE_PORT_MAX" || \
                die "Custom ports must be between ${PROFILE_PORT_MIN} and ${PROFILE_PORT_MAX}."
            if profile_uses_port "$request"; then
                owner=$(profile_using_port "$request" || true)
                die "UDP ${request} is already assigned to profile '${owner}'."
            fi
            udp_port_in_use_live "$request" && die "UDP ${request} is already in use by another local service."
            NEW_PORT_MODE='custom'; NEW_IKE_PORT=500; NEW_NATT_PORT="$request"
            ;;
    esac
}

choose_transport_interactive() {
    local choice suggested owner entered
    section_title 'Transport selection'
    if standard_transport_available; then
        cat >"$TTY_OUT" <<EOF_PORT_SELECT
  ${C_GREEN}[OK]${C_RESET} Standard IKEv2 transport is available.

  Suggested transport:
    UDP 500  - IKE
    UDP 4500 - NAT-T and encrypted ESP-in-UDP

  ${C_GREEN}1)${C_RESET} Use suggested standard ports
  ${C_CYAN}2)${C_RESET} Enter a custom direct UDP port
  ${C_RED}0)${C_RESET} Cancel
EOF_PORT_SELECT
        choice=$(prompt_default 'Select an option' '1')
        case "$choice" in
            1|'') resolve_requested_transport standard; return 0 ;;
            2) ;;
            0) return 1 ;;
            *) warn 'Invalid selection.'; return 1 ;;
        esac
        suggested=$(find_next_custom_port) || die 'No custom UDP port is available.'
    else
        owner=$(profile_using_port 500 2>/dev/null || profile_using_port 4500 2>/dev/null || true)
        suggested=$(find_next_custom_port) || die 'No custom UDP port is available.'
        if [[ -n "$owner" ]]; then
            print_check warn 'Standard UDP 500/4500' "assigned to ${owner}"
        else
            print_check warn 'Standard UDP 500/4500' 'used by another local service'
        fi
        cat >"$TTY_OUT" <<EOF_PORT_SELECT

  Suggested transport:
    Custom direct UDP ${suggested}
    This one port carries IKE, NAT-T and encrypted ESP-in-UDP.

  ${C_GREEN}1)${C_RESET} Use suggested port ${suggested}
  ${C_CYAN}2)${C_RESET} Enter another custom UDP port
  ${C_RED}0)${C_RESET} Cancel
EOF_PORT_SELECT
        choice=$(prompt_default 'Select an option' '1')
        case "$choice" in
            1|'') resolve_requested_transport "$suggested"; return 0 ;;
            2) ;;
            0) return 1 ;;
            *) warn 'Invalid selection.'; return 1 ;;
        esac
    fi

    while true; do
        entered=$(prompt_default "Custom UDP port (${PROFILE_PORT_MIN}-${PROFILE_PORT_MAX})" "$suggested")
        if ! validate_uint_range "$entered" "$PROFILE_PORT_MIN" "$PROFILE_PORT_MAX"; then
            warn "Custom ports must be between ${PROFILE_PORT_MIN} and ${PROFILE_PORT_MAX}."
            continue
        fi
        if profile_uses_port "$entered"; then
            owner=$(profile_using_port "$entered" || true)
            warn "UDP ${entered} is already assigned to profile '${owner}'."
            continue
        fi
        if udp_port_in_use_live "$entered"; then
            warn "UDP ${entered} is already in use by another local service."
            continue
        fi
        resolve_requested_transport "$entered"
        return 0
    done
}

next_profile_index() {
    local index name used
    for ((index=1; index<=9999; index++)); do
        used=no
        while IFS= read -r name; do
            [[ -n "$name" ]] || continue
            if (
                set +u
                # shellcheck disable=SC1090
                source "$(profile_config_file "$name")"
                [[ "${PROFILE_INDEX:-}" == "$index" || "${XFRM_IF:-}" == "dfr$(printf '%04d' "$index")" || "${XFRM_ID:-}" == "$((PROFILE_XFRM_ID_BASE + index))" ]]
            ); then
                used=yes; break
            fi
        done < <(profile_names)
        [[ "$used" == no ]] || continue
        ip link show dev "dfr$(printf '%04d' "$index")" >/dev/null 2>&1 && continue
        printf '%s' "$index"
        return 0
    done
    return 1
}

allocate_tunnel_cidr() {
    local used='' name candidate
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        candidate=$(
            set +u
            # shellcheck disable=SC1090
            source "$(profile_config_file "$name")"
            printf '%s' "${TUNNEL_CIDR:-}"
        )
        [[ -n "$candidate" ]] && used+="${candidate}"$'\n'
    done < <(profile_names)

    python3 - "$PROFILE_TUNNEL_POOL" "$used" <<'PY_ALLOC'
import ipaddress
import json
import subprocess
import sys

pool = ipaddress.ip_network(sys.argv[1], strict=True)
used = []
for line in sys.argv[2].splitlines():
    try:
        used.append(ipaddress.ip_network(line.strip(), strict=False))
    except ValueError:
        pass

try:
    data = json.loads(subprocess.check_output(["ip", "-j", "-4", "address", "show"], text=True))
    for link in data:
        for item in link.get("addr_info", []):
            if item.get("family") == "inet":
                used.append(ipaddress.ip_network(f"{item['local']}/{item['prefixlen']}", strict=False))
except Exception:
    pass

try:
    data = json.loads(subprocess.check_output(["ip", "-j", "-4", "route", "show", "table", "all"], text=True))
    for route in data:
        dst = route.get("dst")
        if dst and dst != "default":
            try:
                used.append(ipaddress.ip_network(dst, strict=False))
            except ValueError:
                pass
except Exception:
    pass

for subnet in pool.subnets(new_prefix=30):
    if subnet.network_address == pool.network_address:
        continue
    if any(subnet.overlaps(other) for other in used):
        continue
    print(subnet.with_prefixlen)
    raise SystemExit(0)
raise SystemExit(1)
PY_ALLOC
}

ensure_managed_symlink() {
    local source="$1" link="$2"
    [[ -f "$source" ]] || die "Cannot link missing managed file: ${source}"
    mkdir -p "$(dirname "$link")"
    if [[ -e "$link" || -L "$link" ]]; then
        if [[ -L "$link" && "$(readlink -f -- "$link" 2>/dev/null || true)" == "$(readlink -f -- "$source")" ]]; then
            return 0
        fi
        die "Refusing to replace unmanaged strongSwan path: ${link}"
    fi
    ln -s "$source" "$link"
}

write_hub_host_config() {
    ensure_hub_layout
    write_shell_config "$HOST_CONFIG_FILE" \
        "HUB_SCHEMA=${HUB_SCHEMA_CURRENT}" \
        'ROLE=egress-hub' \
        "MANAGED_BY_VERSION=${APP_VERSION}" \
        "WAN_IF=${WAN_IF}" \
        "LOCAL_IP=${LOCAL_IP}" \
        "PUBLIC_IP=${PUBLIC_IP}"
    chmod 600 "$HOST_CONFIG_FILE"
}

write_hub_readme() {
    cat >"$MANAGED_README" <<'EOF_HUB_README'
Dragon Fruit Relay 2.x managed directory
========================================

This node is an egress hub. Each directory below clients/ is a completely
independent ingress connection with its own PSK, UDP listener, charon-systemd
process, VICI socket, XFRM interface, XFRM ID, /30 tunnel and firewall rules.

Authoritative files:
  /etc/dragonfruit-relay/clients/<name>/profile.conf
  /etc/dragonfruit-relay/clients/<name>/swanctl.conf
  /etc/dragonfruit-relay/clients/<name>/strongswan.conf
  /etc/dragonfruit-relay/clients/<name>/pairing-token.txt

Canonical strongSwan integration:
  /etc/swanctl/dragonfruit-relay/<name>/swanctl.conf
  /etc/strongswan.d/dragonfruit-relay/<name>.conf

The canonical configuration files are symbolic links to the authoritative
profile files. Standard credential directories are real directories below each
/etc/swanctl/dragonfruit-relay/<name>/ directory.

Run `dragon-fruit-relay` for the interactive shell or use
`dragon-fruit-relay client --help` for automation.
EOF_HUB_README
    chmod 0640 "$MANAGED_README"
}

write_hub_helpers() {
    ensure_hub_layout

    cat >"$HUB_BIN_DIR/client-xfrm-up" <<'EOF_HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail
name="${1:?profile name required}"
[[ "$name" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || exit 2
# shellcheck disable=SC1090
source "/etc/dragonfruit-relay/clients/${name}/profile.conf"
if ip link show dev "$XFRM_IF" >/dev/null 2>&1; then
    details=$(ip -d link show dev "$XFRM_IF")
    grep -q 'xfrm' <<<"$details" || { echo "$XFRM_IF is not an XFRM interface" >&2; exit 1; }
    expected_hex=$(printf '0x%x' "$XFRM_ID")
    grep -Eq "if_id (${XFRM_ID}|${expected_hex})([[:space:]]|$)" <<<"$details" || {
        echo "$XFRM_IF uses a different XFRM interface ID" >&2
        exit 1
    }
else
    ip link add "$XFRM_IF" type xfrm if_id "$XFRM_ID"
fi
ip -4 address flush dev "$XFRM_IF" scope global
ip address add "$EGRESS_XFRM_CIDR" dev "$XFRM_IF"
ip link set "$XFRM_IF" mtu "$XFRM_MTU"
ip link set "$XFRM_IF" up
EOF_HELPER

    cat >"$HUB_BIN_DIR/client-daemon" <<'EOF_HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail
name="${1:?profile name required}"
[[ "$name" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || exit 2
# shellcheck disable=SC1090
source "/etc/dragonfruit-relay/clients/${name}/profile.conf"
install -d -m 0755 /run/dragonfruit-relay
rm -f -- "$VICI_SOCKET"
daemon=$(command -v charon-systemd 2>/dev/null || true)
[[ -n "$daemon" ]] || daemon=/usr/lib/ipsec/charon-systemd
[[ -x "$daemon" ]] || { echo 'charon-systemd executable not found' >&2; exit 1; }
exec env STRONGSWAN_CONF="$STRONGSWAN_CANONICAL" "$daemon"
EOF_HELPER

    cat >"$HUB_BIN_DIR/client-load" <<'EOF_HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail
name="${1:?profile name required}"
[[ "$name" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || exit 2
# shellcheck disable=SC1090
source "/etc/dragonfruit-relay/clients/${name}/profile.conf"
for _ in $(seq 1 100); do
    [[ -S "$VICI_SOCKET" ]] && break
    sleep 0.1
done
[[ -S "$VICI_SOCKET" ]] || { echo "VICI socket did not appear: $VICI_SOCKET" >&2; exit 1; }
swanctl --load-all --uri "$VICI_URI" --noprompt --file "$SWANCTL_CANONICAL"
swanctl --list-conns --uri "$VICI_URI" | grep -Eq '^[[:space:]]*dragonfruit_relay:'
EOF_HELPER

    cat >"$HUB_BIN_DIR/client-xfrm-down" <<'EOF_HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail
name="${1:?profile name required}"
[[ "$name" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || exit 2
file="/etc/dragonfruit-relay/clients/${name}/profile.conf"
[[ -r "$file" ]] || exit 0
# shellcheck disable=SC1090
source "$file"
swanctl --terminate --uri "$VICI_URI" --ike dragonfruit_relay >/dev/null 2>&1 || true
ip link set "$XFRM_IF" down >/dev/null 2>&1 || true
rm -f -- "$VICI_SOCKET" "${VICI_SOCKET%.vici}.dck" "${VICI_SOCKET%.vici}.ctl" "${VICI_SOCKET%.vici}.wlst"
EOF_HELPER
    chmod 0750 "$HUB_BIN_DIR"/*

    cat >"$CLIENT_UNIT_TEMPLATE" <<EOF_UNIT
# Managed by Dragon Fruit Relay ${APP_VERSION}.
[Unit]
Description=Dragon Fruit Relay isolated client %i
Wants=network-online.target
After=network-online.target

[Service]
Type=notify
NotifyAccess=all
ExecStartPre=${HUB_BIN_DIR}/client-xfrm-up %i
ExecStart=${HUB_BIN_DIR}/client-daemon %i
ExecStartPost=${HUB_BIN_DIR}/client-load %i
ExecStopPost=${HUB_BIN_DIR}/client-xfrm-down %i
Restart=on-failure
RestartSec=5s
TimeoutStartSec=35s
TimeoutStopSec=20s

[Install]
WantedBy=multi-user.target
EOF_UNIT
    chmod 0644 "$CLIENT_UNIT_TEMPLATE"
    systemctl daemon-reload
}

write_client_profile() {
    local name="$1"
    local dir
    dir=$(profile_dir "$name")
    install -d -m 0700 "$dir"
    VICI_SOCKET=$(profile_vici_socket "$name")
    VICI_URI=$(profile_vici_uri "$name")
    SWANCTL_CANONICAL=$(profile_swanctl_canonical "$name")
    STRONGSWAN_CANONICAL=$(profile_strongswan_canonical "$name")
    write_shell_config "$dir/profile.conf" \
        "PROFILE_SCHEMA=${PROFILE_SCHEMA_CURRENT}" \
        "MANAGED_BY_VERSION=${APP_VERSION}" \
        "PROFILE_NAME=${name}" \
        "PROFILE_INDEX=${PROFILE_INDEX}" \
        'ROLE=egress-client' \
        "WAN_IF=${WAN_IF}" \
        "LOCAL_IP=${LOCAL_IP}" \
        "PUBLIC_IP=${PUBLIC_IP}" \
        "PORT_MODE=${PORT_MODE}" \
        "IKE_PORT=${IKE_PORT}" \
        "NATT_PORT=${NATT_PORT}" \
        "TUNNEL_CIDR=${TUNNEL_CIDR}" \
        "XFRM_IF=${XFRM_IF}" \
        "XFRM_ID=${XFRM_ID}" \
        "XFRM_MTU=${XFRM_MTU}" \
        "INGRESS_XFRM_CIDR=${INGRESS_XFRM_CIDR}" \
        "EGRESS_XFRM_CIDR=${EGRESS_XFRM_CIDR}" \
        "INGRESS_XFRM_IP=${INGRESS_XFRM_IP}" \
        "EGRESS_XFRM_IP=${EGRESS_XFRM_IP}" \
        "INGRESS_ID=${INGRESS_ID}" \
        "EGRESS_ID=${EGRESS_ID}" \
        "DNS_PRIMARY=${DNS_PRIMARY}" \
        "DNS_SECONDARY=${DNS_SECONDARY}" \
        "PSK=${PSK}" \
        "VICI_SOCKET=${VICI_SOCKET}" \
        "VICI_URI=${VICI_URI}" \
        "SWANCTL_CANONICAL=${SWANCTL_CANONICAL}" \
        "STRONGSWAN_CANONICAL=${STRONGSWAN_CANONICAL}"
    chmod 600 "$dir/profile.conf"
}

write_client_strongswan() {
    local name="$1" source canonical port_lines
    source=$(profile_strongswan_source "$name")
    canonical=$(profile_strongswan_canonical "$name")
    if [[ "$PORT_MODE" == standard ]]; then
        port_lines="    port = 500
    port_nat_t = 4500"
    else
        port_lines="    port = 0
    port_nat_t = ${NATT_PORT}"
    fi
    cat >"$source" <<EOF_STRONGSWAN
# Managed by Dragon Fruit Relay ${APP_VERSION}.
# Profile: ${name}
# Plugin defaults from the Debian package are included explicitly because this
# daemon runs with an isolated STRONGSWAN_CONF file.
include /etc/strongswan.d/charon/*.conf
include /etc/strongswan.d/charon-systemd*.conf

charon {
${port_lines}
    install_routes = no

    plugins {
        vici {
            socket = ${VICI_URI}
        }
        # Route-based XFRM profiles require the kernel-netlink backend.
        # The optional kernel-libipsec backend creates a shared TUN device
        # (for example ipsec0), which conflicts with isolated XFRM instances.
        kernel-libipsec {
            load = no
        }
        kernel-netlink {
            load = yes
            install_routes_xfrmi = no
        }
        # These optional plugins install shared host-wide policies or hooks and
        # are unnecessary for isolated responder instances.
        bypass-lan {
            load = no
        }
        forecast {
            load = no
        }
        resolve {
            load = no
        }
        # Avoid control-socket collisions if optional plugins are installed.
        duplicheck {
            socket = unix:///run/dragonfruit-relay/${name}.dck
        }
        stroke {
            socket = unix:///run/dragonfruit-relay/${name}.ctl
        }
        whitelist {
            socket = unix:///run/dragonfruit-relay/${name}.wlst
        }
    }
}
EOF_STRONGSWAN
    chmod 0600 "$source"
    ensure_managed_symlink "$source" "$canonical"
}

write_client_swanctl() {
    local name="$1" source canonical canonical_dir credential_dir
    source=$(profile_swanctl_source "$name")
    canonical=$(profile_swanctl_canonical "$name")
    canonical_dir=$(profile_swanctl_dir "$name")
    if [[ -d "$canonical_dir" && ! -e "$canonical_dir/.dragonfruit-relay-profile" ]]; then
        if find "$canonical_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
            die "Refusing to modify unmanaged swanctl profile directory: ${canonical_dir}"
        fi
    elif [[ -e "$canonical_dir" && ! -d "$canonical_dir" ]]; then
        die "Canonical swanctl profile path is not a directory: ${canonical_dir}"
    fi
    install -d -m 0750 "$canonical_dir"
    : >"$canonical_dir/.dragonfruit-relay-profile"
    chmod 0640 "$canonical_dir/.dragonfruit-relay-profile"
    for credential_dir in x509 x509ca x509ocsp x509aa x509ac x509crl pubkey private rsa ecdsa pkcs8 pkcs12; do
        local credential_source="$(profile_dir "$name")/$credential_dir"
        local credential_link="$canonical_dir/$credential_dir"
        install -d -m 0700 "$credential_source"
        if [[ -e "$credential_link" || -L "$credential_link" ]]; then
            if [[ -L "$credential_link" && "$(readlink -f -- "$credential_link" 2>/dev/null || true)" == "$(readlink -f -- "$credential_source")" ]]; then
                continue
            fi
            if [[ -d "$credential_link" ]] && ! find "$credential_link" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
                rmdir "$credential_link"
            else
                die "Refusing to replace unmanaged credential path: ${credential_link}"
            fi
        fi
        ln -s "$credential_source" "$credential_link"
    done
    cat >"$source" <<EOF_SWANCTL
# Managed by Dragon Fruit Relay ${APP_VERSION}.
# Egress hub profile: ${name}
connections {
    dragonfruit_relay {
        version = 2
        local_addrs = %any
        remote_addrs = %any
        encap = yes
        mobike = no
        fragmentation = yes
        dpd_delay = 20s
        reauth_time = 0s

        local {
            auth = psk
            id = ${EGRESS_ID}
        }
        remote {
            auth = psk
            id = ${INGRESS_ID}
        }
        children {
            tunnel {
                mode = tunnel
                local_ts = 0.0.0.0/0
                remote_ts = 0.0.0.0/0
                if_id_in = ${XFRM_ID}
                if_id_out = ${XFRM_ID}
                close_action = none
                dpd_action = clear
            }
        }
    }
}
secrets {
    ike-psk {
        id-1 = ${INGRESS_ID}
        id-2 = ${EGRESS_ID}
        secret = "${PSK}"
    }
}
EOF_SWANCTL
    chmod 0600 "$source"
    ensure_managed_symlink "$source" "$canonical"
}

generate_client_token() {
    local name="$1" payload token token_path
    load_client_profile "$name"
    payload=$(cat <<EOF_TOKEN
TOKEN_VERSION=${PROFILE_TOKEN_VERSION}
PROFILE_NAME=${PROFILE_NAME}
EXIT_PUBLIC_IP=${PUBLIC_IP}
PORT_MODE=${PORT_MODE}
IKE_PORT=${IKE_PORT}
NATT_PORT=${NATT_PORT}
PSK=${PSK}
TUNNEL_CIDR=${TUNNEL_CIDR}
XFRM_ID=${XFRM_ID}
INGRESS_XFRM_IF=xfrm0
EGRESS_XFRM_IF=${XFRM_IF}
XFRM_MTU=${XFRM_MTU}
INGRESS_XFRM_CIDR=${INGRESS_XFRM_CIDR}
EGRESS_XFRM_CIDR=${EGRESS_XFRM_CIDR}
INGRESS_XFRM_IP=${INGRESS_XFRM_IP}
EGRESS_XFRM_IP=${EGRESS_XFRM_IP}
INGRESS_ID=${INGRESS_ID}
EGRESS_ID=${EGRESS_ID}
DNS_PRIMARY=${DNS_PRIMARY}
DNS_SECONDARY=${DNS_SECONDARY}
EOF_TOKEN
)
    token=$(printf '%s' "$payload" | base64 -w0)
    token_path=$(profile_token_file "$name")
    printf '%s\n' "$token" >"$token_path"
    chmod 0600 "$token_path"
    printf '%s' "$token"
}

show_client_token() {
    local name="$1" token
    profile_exists "$name" || die "Client profile '${name}' does not exist."
    token=$(generate_client_token "$name")
    load_client_profile "$name"
    cat >"$TTY_OUT" <<EOF_TOKEN_OUT

${C_BOLD}${C_MAGENTA}PAIRING TOKEN — ${name}${C_RESET}
${C_YELLOW}This token contains the pre-shared key. Treat it like a password.${C_RESET}
Transport: $(if [[ "$PORT_MODE" == standard ]]; then printf 'UDP 500 + UDP 4500'; else printf 'UDP %s (custom direct)' "$NATT_PORT"; fi)

${C_BOLD}${token}${C_RESET}

Paste the complete line into Dragon Fruit Relay 2.x on the ingress node.
Protected copy: $(profile_token_file "$name")
EOF_TOKEN_OUT
}

client_rule_comment() {
    printf 'dragonfruit-relay-%s-%s' "$1" "$2"
}

apply_client_network_rules() {
    local name="$1" forward_out forward_return nat
    load_host_config
    load_client_profile "$name"
    forward_out=$(client_rule_comment "$name" forward-out)
    forward_return=$(client_rule_comment "$name" forward-return)
    nat=$(client_rule_comment "$name" nat)

    iptables -C FORWARD -i "$XFRM_IF" -o "$WAN_IF" -s "$INGRESS_XFRM_IP/32" \
        -m comment --comment "$forward_out" -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD 1 -i "$XFRM_IF" -o "$WAN_IF" -s "$INGRESS_XFRM_IP/32" \
        -m comment --comment "$forward_out" -j ACCEPT

    iptables -C FORWARD -i "$WAN_IF" -o "$XFRM_IF" -d "$INGRESS_XFRM_IP/32" \
        -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "$forward_return" -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD 1 -i "$WAN_IF" -o "$XFRM_IF" -d "$INGRESS_XFRM_IP/32" \
        -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "$forward_return" -j ACCEPT

    iptables -t nat -C POSTROUTING -s "$INGRESS_XFRM_IP/32" -o "$WAN_IF" \
        -m comment --comment "$nat" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "$INGRESS_XFRM_IP/32" -o "$WAN_IF" \
        -m comment --comment "$nat" -j MASQUERADE
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >>"$LOG_FILE" 2>&1 || true
}

remove_client_network_rules() {
    local name="$1"
    delete_iptables_rules_by_comment filter "$(client_rule_comment "$name" forward-out)"
    delete_iptables_rules_by_comment filter "$(client_rule_comment "$name" forward-return)"
    delete_iptables_rules_by_comment nat "$(client_rule_comment "$name" nat)"
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >>"$LOG_FILE" 2>&1 || true
}

profile_listener_ok() {
    local name="$1"
    load_client_profile "$name"
    if [[ "$PORT_MODE" == standard ]]; then
        udp_listener_exists 500 && udp_listener_exists 4500
    else
        udp_listener_exists "$NATT_PORT"
    fi
}

client_swanctl() {
    local name="$1" operation
    shift
    operation="${1:?swanctl operation required}"
    shift
    load_client_profile "$name"
    # swanctl 6.0 parses the operation before operation-specific options.
    swanctl "$operation" --uri "$VICI_URI" "$@"
}

start_hub_client() {
    local name="$1" unit
    profile_exists "$name" || die "Client profile '${name}' does not exist."
    unit=$(profile_service "$name")
    systemctl daemon-reload
    if ! systemctl enable --now "$unit" >>"$LOG_FILE" 2>&1; then
        error "Client '${name}' failed to start."
        systemctl status "$unit" --no-pager -l 2>&1 | tail -n 80 >"$TTY_OUT" || true
        journalctl -u "$unit" -n 100 --no-pager -l 2>&1 >"$TTY_OUT" || true
        return 1
    fi
    profile_listener_ok "$name" || {
        error "Client '${name}' started but its configured UDP listener is missing."
        return 1
    }
    apply_client_network_rules "$name"
    success "Client '${name}' is ready."
}

stop_hub_client() {
    local name="$1" disable="${2:-no}" unit
    profile_exists "$name" || die "Client profile '${name}' does not exist."
    unit=$(profile_service "$name")
    remove_client_network_rules "$name"
    if [[ "$disable" == yes ]]; then
        timeout 25s systemctl disable --now "$unit" >/dev/null 2>&1 || true
    else
        timeout 25s systemctl stop "$unit" >/dev/null 2>&1 || true
    fi
    load_client_profile "$name"
    delete_link_bounded "$XFRM_IF" || true
    rm -f -- "$VICI_SOCKET"
}

client_status_word() {
    local name="$1" unit state sas
    profile_exists "$name" || { printf 'MISSING'; return; }
    load_client_profile "$name"
    unit=$(profile_service "$name")
    state=$(systemctl is-active "$unit" 2>/dev/null || true)
    [[ "$state" == active ]] || { [[ "$state" == failed ]] && printf 'FAILED' || printf 'STOPPED'; return; }
    ip link show dev "$XFRM_IF" >/dev/null 2>&1 || { printf 'FAILED'; return; }
    profile_listener_ok "$name" || { printf 'DEGRADED'; return; }
    sas=$(swanctl --list-sas --uri "$VICI_URI" 2>/dev/null || true)
    if grep -q ESTABLISHED <<<"$sas" && grep -q INSTALLED <<<"$sas"; then
        if ping -I "$XFRM_IF" -c 1 -W 1 "$INGRESS_XFRM_IP" >/dev/null 2>&1; then
            printf 'OPERATIONAL'
        else
            printf 'DISCONNECTED'
        fi
    else
        printf 'READY'
    fi
}

remove_client_files() {
    local name="$1" canonical_dir canonical_strong expected_strong
    canonical_dir=$(profile_swanctl_dir "$name")
    canonical_strong=$(profile_strongswan_canonical "$name")
    expected_strong=$(profile_strongswan_source "$name")
    if [[ -e "$canonical_dir/.dragonfruit-relay-profile" ]]; then
        rm -rf -- "$canonical_dir"
    fi
    if [[ -L "$canonical_strong" && "$(readlink -f -- "$canonical_strong" 2>/dev/null || true)" == "$(readlink -f -- "$expected_strong" 2>/dev/null || true)" ]]; then
        rm -f -- "$canonical_strong"
    fi
    rm -rf -- "$(profile_dir "$name")"
}

remove_hub_client() {
    local name="$1" skip_confirm="${2:-no}"
    profile_exists "$name" || die "Client profile '${name}' does not exist."
    [[ "$skip_confirm" == yes ]] || confirm "Remove client '${name}' only? Other clients will stay online." no || return 0
    load_client_profile "$name"
    local old_if="$XFRM_IF" old_socket="$VICI_SOCKET"
    stop_hub_client "$name" yes
    remove_client_files "$name"
    systemctl daemon-reload >/dev/null 2>&1 || true
    delete_link_bounded "$old_if" || true
    rm -f -- "$old_socket"
    if ip link show dev "$old_if" >/dev/null 2>&1 || [[ -e "$(profile_dir "$name")" ]]; then
        die "Client '${name}' removal could not be verified."
    fi
    success "Client '${name}' was removed without changing other profiles."
}

repair_hub_client() {
    local name="$1"
    load_host_config
    load_client_profile "$name"
    write_client_strongswan "$name"
    write_client_swanctl "$name"
    generate_client_token "$name" >/dev/null
    systemctl daemon-reload
    systemctl restart "$(profile_service "$name")" >>"$LOG_FILE" 2>&1 || {
        error "Client '${name}' failed after repair."
        journalctl -u "$(profile_service "$name")" -n 100 --no-pager >"$TTY_OUT" || true
        return 1
    }
    apply_client_network_rules "$name"
    success "Client '${name}' was repaired."
}

prepare_new_client_resources() {
    local name="$1" requested_port="$2" requested_tunnel="${3:-auto}" index tunnel_data
    index=$(next_profile_index) || die 'No free profile index is available.'
    PROFILE_INDEX="$index"
    XFRM_IF="dfr$(printf '%04d' "$index")"
    XFRM_ID=$((PROFILE_XFRM_ID_BASE + index))
    XFRM_MTU="$DEFAULT_XFRM_MTU"

    if [[ "$requested_port" == interactive ]]; then
        choose_transport_interactive || return 1
    else
        resolve_requested_transport "$requested_port"
    fi
    PORT_MODE="$NEW_PORT_MODE"; IKE_PORT="$NEW_IKE_PORT"; NATT_PORT="$NEW_NATT_PORT"

    if [[ "$requested_tunnel" == auto || -z "$requested_tunnel" ]]; then
        TUNNEL_CIDR=$(allocate_tunnel_cidr) || die "No unused /30 remains in ${PROFILE_TUNNEL_POOL}."
    else
        cidr_hosts "$requested_tunnel" >/dev/null || die 'The requested tunnel must be a valid IPv4 /30.'
        ensure_tunnel_network_available "$requested_tunnel"
        TUNNEL_CIDR="$requested_tunnel"
    fi
    mapfile -t tunnel_data < <(cidr_hosts "$TUNNEL_CIDR")
    ((${#tunnel_data[@]} == 5)) || die 'Could not derive tunnel addresses.'
    TUNNEL_CIDR=${tunnel_data[0]}
    INGRESS_XFRM_CIDR=${tunnel_data[1]}
    EGRESS_XFRM_CIDR=${tunnel_data[2]}
    INGRESS_XFRM_IP=${tunnel_data[3]}
    EGRESS_XFRM_IP=${tunnel_data[4]}
    ip link show dev "$XFRM_IF" >/dev/null 2>&1 && die "Interface ${XFRM_IF} already exists."

    INGRESS_ID="dragonfruit-relay-ingress-${name}"
    EGRESS_ID="dragonfruit-relay-egress-${name}"
    DNS_PRIMARY="$DEFAULT_DNS_PRIMARY"
    DNS_SECONDARY="$DEFAULT_DNS_SECONDARY"
    PSK=$(openssl rand -hex 32)
}

create_hub_client() {
    local name="$1" requested_port="${2:-interactive}" requested_tunnel="${3:-auto}"
    load_host_config
    validate_profile_name "$name" || die "Invalid profile name '${name}'."
    profile_exists "$name" && die "Client profile '${name}' already exists."
    prepare_new_client_resources "$name" "$requested_port" "$requested_tunnel" || return 0

    section_title 'New client resources'
    print_check info 'Connection name' "$name"
    print_check info 'Transport' "$(if [[ "$PORT_MODE" == standard ]]; then printf 'UDP 500 + UDP 4500'; else printf 'UDP %s' "$NATT_PORT"; fi)"
    print_check info 'XFRM interface' "$XFRM_IF (ID $XFRM_ID)"
    print_check info 'Tunnel network' "$TUNNEL_CIDR"

    if ! (
        write_client_profile "$name"
        load_client_profile "$name"
        write_client_strongswan "$name"
        write_client_swanctl "$name"
        generate_client_token "$name" >/dev/null
        start_hub_client "$name"
    ); then
        warn "Client '${name}' setup failed; removing only that incomplete profile."
        systemctl disable --now "$(profile_service "$name")" >/dev/null 2>&1 || true
        remove_client_network_rules "$name" || true
        remove_client_files "$name"
        systemctl daemon-reload >/dev/null 2>&1 || true
        return 1
    fi
    show_client_token "$name"
}

add_client_interactive() {
    local name
    name=$(prompt_profile_name)
    create_hub_client "$name" interactive auto
}

write_hub_sysctl() {
    load_host_config
    write_egress_sysctl
}

rollback_hub_initialization() {
    warn 'Hub initialization failed. Restoring the complete pre-install state...'
    local name
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        remove_hub_client "$name" yes || true
    done < <(profile_names)
    systemctl disable --now 'dragonfruit-relay-client@*.service' >/dev/null 2>&1 || true
    rm -f "$CLIENT_UNIT_TEMPLATE"
    [[ -e "$SWANCTL_CLIENT_ROOT/.dragonfruit-relay-root" ]] && rm -rf "$SWANCTL_CLIENT_ROOT" || true
    [[ -e "$STRONGSWAN_CLIENT_ROOT/.dragonfruit-relay-root" ]] && rm -rf "$STRONGSWAN_CLIENT_ROOT" || true
    rm -rf "$CONFIG_DIR"
    restore_pre_routevpn_state egress || true
    systemctl daemon-reload >/dev/null 2>&1 || true
    success 'Hub rollback completed.'
}

setup_egress_hub() {
    clear_screen; banner
    info 'Configuring this server as a multi-client Dragon Fruit Relay egress hub.'
    hub_configured && { warn 'This node is already an egress hub.'; return 0; }
    if [[ -f "$CONFIG_FILE" ]] && ! legacy_single_configured; then
        die 'This server is already configured as an ingress client. Remove the ingress configuration before initializing an egress hub.'
    fi
    if legacy_single_configured; then
        die 'A Dragon Fruit Relay 1.x configuration exists. Use the migration option first.'
    fi

    clean_abandoned_install_before_setup
    backup_egress_paths
    backup_original "$CLIENT_UNIT_TEMPLATE"
    install_dependencies

    WAN_IF=$(detect_default_interface)
    [[ -n "$WAN_IF" ]] || die 'No IPv4 default route was detected.'
    LOCAL_IP=$(detect_local_ipv4 "$WAN_IF")
    [[ -n "$LOCAL_IP" ]] || die "No global IPv4 address was detected on ${WAN_IF}."
    local detected_public detected_gateway
    detected_gateway=$(detect_default_gateway || true)
    detected_public=$(detect_public_ipv4 || true)
    PUBLIC_IP="${detected_public:-}"
    show_detected_network "$detected_gateway"
    if [[ -n "$detected_public" ]]; then
        PUBLIC_IP=$(prompt_ipv4_value 'Egress public IPv4 reachable by ingress clients' "$detected_public")
    else
        PUBLIC_IP=$(prompt_ipv4_required 'Egress public IPv4 reachable by ingress clients')
    fi
    backup_egress_runtime_sysctls

    if ! (
        ensure_hub_layout
        write_hub_host_config
        write_hub_readme
        install_self_copy
        write_hub_helpers
        systemctl disable --now strongswan.service >/dev/null 2>&1 || true
        write_hub_sysctl
    ); then
        rollback_hub_initialization
        return 1
    fi

    success 'The egress hub is initialized.'
    print_check info 'Public endpoint' "$PUBLIC_IP"
    print_check info 'Next step' 'Create the first egress connection for an ingress client.'
    confirm 'Create the first egress connection now' yes && add_client_interactive || true
}

start_all_clients() {
    local name failures=0
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        start_hub_client "$name" || failures=$((failures + 1))
    done < <(profile_names)
    ((failures == 0)) || return 1
}

stop_all_clients() {
    local name
    confirm 'Temporarily stop every egress client? They remain enabled for the next boot.' no || return 0
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        stop_hub_client "$name" no
    done < <(profile_names)
    success 'All egress clients are stopped for the current boot.'
}

repair_all_clients() {
    load_host_config
    write_hub_helpers
    write_hub_sysctl
    local name failures=0
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        repair_hub_client "$name" || failures=$((failures + 1))
    done < <(profile_names)
    ((failures == 0)) && success 'All client profiles were repaired.' || error "${failures} client profile(s) failed repair."
}

remove_egress_hub() {
    local complete="${1:-no}" skip_confirm="${2:-no}" name
    hub_configured || die 'This node is not configured as an egress hub.'
    [[ "$skip_confirm" == yes ]] || {
        if [[ "$complete" == yes ]]; then
            confirm 'Completely uninstall the egress hub, every client, and restore the original host state?' no || return 0
        else
            confirm 'Remove the egress hub and every client, then restore the original host state?' no || return 0
        fi
    }
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        remove_hub_client "$name" yes
    done < <(profile_names)
    rm -f "$CLIENT_UNIT_TEMPLATE"
    [[ -e "$SWANCTL_CLIENT_ROOT/.dragonfruit-relay-root" ]] && rm -rf "$SWANCTL_CLIENT_ROOT" || true
    [[ -e "$STRONGSWAN_CLIENT_ROOT/.dragonfruit-relay-root" ]] && rm -rf "$STRONGSWAN_CLIENT_ROOT" || true
    [[ -L "$SYSCTL_FILE" && "$(readlink -f "$SYSCTL_FILE" 2>/dev/null || true)" == "$SYSCTL_MANAGED_FILE" ]] && rm -f "$SYSCTL_FILE" || true
    rm -rf "$CONFIG_DIR"
    restore_pre_routevpn_state egress
    systemctl daemon-reload >/dev/null 2>&1 || true
    if [[ "$complete" == yes ]]; then
        remove_added_packages
        rm -rf "$STATE_DIR"
        remove_cli_command
        success 'Dragon Fruit Relay 2.x and all client profiles were completely removed.'
    else
        rm -rf "$STATE_DIR"
        success 'The egress hub and every client were removed; the management command remains installed.'
    fi
}

snapshot_legacy_installation() {
    local destination="$1" path
    install -d -m 0700 "$destination"
    iptables-save >"$destination/iptables.v4" 2>/dev/null || true
    ip6tables-save >"$destination/ip6tables.v6" 2>/dev/null || true
    local -a paths=()
    for path in \
        etc/dragonfruit-relay etc/swanctl/swanctl.conf etc/strongswan.d/99-dragonfruit-relay.conf \
        etc/systemd/system/strongswan.service.d/dragonfruit-relay.conf \
        etc/systemd/system/dragonfruit-relay-xfrm.service \
        etc/systemd/system/dragonfruit-relay-routing.service \
        etc/systemd/system/dragonfruit-relay-dns.service \
        etc/systemd/system/dragonfruit-relay-healthcheck.service \
        etc/systemd/system/dragonfruit-relay-healthcheck.timer \
        etc/sysctl.d/99-dragonfruit-relay.conf; do
        [[ -e "/$path" || -L "/$path" ]] && paths+=("$path")
    done
    ((${#paths[@]})) && tar -C / -czf "$destination/files.tar.gz" "${paths[@]}"
}

rollback_legacy_migration() {
    local snapshot="$1"
    warn 'Migration failed; restoring the legacy installation snapshot.'
    local name
    while IFS= read -r name; do [[ -n "$name" ]] && remove_hub_client "$name" yes || true; done < <(profile_names)
    rm -rf "$CONFIG_DIR"
    [[ -e "$SWANCTL_CLIENT_ROOT/.dragonfruit-relay-root" ]] && rm -rf "$SWANCTL_CLIENT_ROOT" || true
    [[ -e "$STRONGSWAN_CLIENT_ROOT/.dragonfruit-relay-root" ]] && rm -rf "$STRONGSWAN_CLIENT_ROOT" || true
    rm -f "$CLIENT_UNIT_TEMPLATE"
    [[ -f "$snapshot/files.tar.gz" ]] && tar -C / -xzf "$snapshot/files.tar.gz"
    [[ -s "$snapshot/iptables.v4" ]] && iptables-restore <"$snapshot/iptables.v4" || true
    [[ -s "$snapshot/ip6tables.v6" ]] && ip6tables-restore <"$snapshot/ip6tables.v6" || true
    systemctl daemon-reload
    systemctl enable --now dragonfruit-relay-xfrm.service strongswan.service >/dev/null 2>&1 || true
    error "Legacy configuration restored. Migration snapshot retained at ${snapshot}."
}

migrate_legacy_egress() {
    legacy_single_configured || die 'No legacy Dragon Fruit Relay configuration was found.'
    [[ "$(legacy_config_role)" == egress ]] || die 'The legacy node is not an egress node.'
    local name="${1:-}" snapshot old_config
    if [[ -z "$name" ]]; then
        name=$(prompt_default 'Name for the existing connection' 'legacy-client')
        name=$(normalize_profile_name "$name")
    fi
    validate_profile_name "$name" || die 'Invalid migration profile name.'
    snapshot="${STATE_DIR}/migration-v1-$(date +%Y%m%d-%H%M%S)"
    snapshot_legacy_installation "$snapshot"
    old_config="$snapshot/legacy.conf"
    cp -a "$CONFIG_FILE" "$old_config"

    # Load every legacy value before replacing the application tree.
    load_config
    local old_wan="$WAN_IF" old_local="$LOCAL_IP" old_public="$PUBLIC_IP"
    local old_port_mode="$PORT_MODE" old_ike="$IKE_PORT" old_natt="$NATT_PORT"
    local old_tunnel="$TUNNEL_CIDR" old_if="$XFRM_IF" old_id="$XFRM_ID" old_mtu="$XFRM_MTU"
    local old_ingress_cidr="$INGRESS_XFRM_CIDR" old_egress_cidr="$EGRESS_XFRM_CIDR"
    local old_ingress_ip="$INGRESS_XFRM_IP" old_egress_ip="$EGRESS_XFRM_IP"
    local old_ingress_id="$INGRESS_ID" old_egress_id="$EGRESS_ID" old_psk="$PSK"
    local old_dns1="$DNS_PRIMARY" old_dns2="$DNS_SECONDARY"

    systemctl disable --now dragonfruit-relay-healthcheck.timer dragonfruit-relay-dns.service \
        dragonfruit-relay-routing.service dragonfruit-relay-xfrm.service strongswan.service >/dev/null 2>&1 || true
    remove_all_dragonfruit_network_rules || true
    delete_link_bounded "$old_if" || true
    rm -f "$SYSTEMD_DIR"/dragonfruit-relay-xfrm.service "$SYSTEMD_DIR"/dragonfruit-relay-routing.service \
        "$SYSTEMD_DIR"/dragonfruit-relay-dns.service "$SYSTEMD_DIR"/dragonfruit-relay-healthcheck.service \
        "$SYSTEMD_DIR"/dragonfruit-relay-healthcheck.timer "$SWANCTL_FILE" "$STRONGSWAN_ROUTE_FILE" "$STRONGSWAN_OVERRIDE_FILE"

    WAN_IF="$old_wan"; LOCAL_IP="$old_local"; PUBLIC_IP="$old_public"
    if ! (
        ensure_hub_layout
        write_hub_host_config
        write_hub_readme
        write_hub_helpers
        write_hub_sysctl

        PROFILE_INDEX=1; PORT_MODE="$old_port_mode"; IKE_PORT="$old_ike"; NATT_PORT="$old_natt"
        TUNNEL_CIDR="$old_tunnel"; XFRM_IF="$old_if"; XFRM_ID="$old_id"; XFRM_MTU="$old_mtu"
        INGRESS_XFRM_CIDR="$old_ingress_cidr"; EGRESS_XFRM_CIDR="$old_egress_cidr"
        INGRESS_XFRM_IP="$old_ingress_ip"; EGRESS_XFRM_IP="$old_egress_ip"
        INGRESS_ID="$old_ingress_id"; EGRESS_ID="$old_egress_id"; PSK="$old_psk"
        DNS_PRIMARY="$old_dns1"; DNS_SECONDARY="$old_dns2"
        write_client_profile "$name"
        load_client_profile "$name"
        write_client_strongswan "$name"
        write_client_swanctl "$name"
        generate_client_token "$name" >/dev/null
        rm -f "$CONFIG_FILE"
        rm -rf "$LIB_DIR" "$UNIT_DIR" "$RESOLVER_DIR"
        rm -f "$TOKEN_FILE" "$LEGACY_TOKEN_FILE"
        start_hub_client "$name"
    ); then
        rollback_legacy_migration "$snapshot"
        return 1
    fi
    success "Legacy egress migrated to hub profile '${name}'."
    print_check info 'Existing ingress' 'It may reconnect without changing its current configuration.'
    show_client_token "$name"
}

migrate_legacy_ingress() {
    legacy_single_configured || die 'No legacy Dragon Fruit Relay configuration was found.'
    [[ "$(legacy_config_role)" == ingress ]] || die 'The legacy node is not an ingress node.'
    cp -a "$CONFIG_FILE" "${CONFIG_FILE}.pre-2.0.4"
    if ! grep -q '^PROFILE_NAME=' "$CONFIG_FILE"; then
        printf 'PROFILE_NAME=%q\n' 'legacy-peer' >>"$CONFIG_FILE"
    fi
    sed -i -E 's/^CONFIG_SCHEMA=.*/CONFIG_SCHEMA=5/; s/^MANAGED_BY_VERSION=.*/MANAGED_BY_VERSION=2.0.0/' "$CONFIG_FILE"
    repair_current
    success 'Legacy ingress upgraded in place to Dragon Fruit Relay 2.0.0 compatibility.'
}

legacy_migration_menu() {
    local role choice name
    role=$(legacy_config_role)
    clear_screen; banner
    section_title 'Previous Dragon Fruit Relay detected'
    print_check info 'Detected role' "$role"
    if [[ "$role" == egress ]]; then
        cat >"$TTY_OUT" <<EOF_MIGRATE
  ${C_GREEN}1)${C_RESET} Migrate the existing tunnel into the first named hub client
  ${C_YELLOW}2)${C_RESET} Remove the old tunnel and create a new egress hub
  ${C_RED}0)${C_RESET} Exit
EOF_MIGRATE
        choice=$(prompt_default 'Select an option' '1')
        case "$choice" in
            1|'') name=$(prompt_default 'Name for the existing connection' 'legacy-client'); migrate_legacy_egress "$(normalize_profile_name "$name")" ;;
            2) remove_tunnel_configuration yes; setup_egress_hub ;;
            0) exit 0 ;;
            *) warn 'Invalid selection.' ;;
        esac
    elif [[ "$role" == ingress ]]; then
        cat >"$TTY_OUT" <<EOF_MIGRATE
  ${C_GREEN}1)${C_RESET} Upgrade this ingress in place
  ${C_YELLOW}2)${C_RESET} Remove it and configure a new ingress
  ${C_RED}0)${C_RESET} Exit
EOF_MIGRATE
        choice=$(prompt_default 'Select an option' '1')
        case "$choice" in
            1|'') migrate_legacy_ingress ;;
            2) remove_tunnel_configuration yes; setup_ingress ;;
            0) exit 0 ;;
            *) warn 'Invalid selection.' ;;
        esac
    else
        die "Unknown legacy role: ${role}"
    fi
}

# Pairing-token parser for legacy schema 1-4 and isolated profile schema 5.
parse_pairing_token() {
    local token="$1" decoded
    token=$(printf '%s' "$token" | tr -d '[:space:]')
    decoded=$(printf '%s' "$token" | base64 -d 2>/dev/null) || die 'The pairing token is not valid Base64.'

    local token_version='' profile_name='' exit_public_ip='' port_mode='standard'
    local ike_port="$DEFAULT_IKE_PORT" natt_port="$DEFAULT_NATT_PORT" psk='' tunnel_cidr=''
    local xfrm_id='' legacy_xfrm_if='' ingress_xfrm_if='' egress_xfrm_if='' xfrm_mtu=''
    local ingress_xfrm_cidr='' egress_xfrm_cidr='' ingress_xfrm_ip='' egress_xfrm_ip=''
    local ingress_id='' egress_id='' dns_primary='' dns_secondary='' key value
    while IFS='=' read -r key value; do
        value=${value%$'\r'}
        case "$key" in
            TOKEN_VERSION) token_version="$value" ;;
            PROFILE_NAME) profile_name="$value" ;;
            EXIT_PUBLIC_IP) exit_public_ip="$value" ;;
            PORT_MODE) port_mode="$value" ;;
            IKE_PORT) ike_port="$value" ;;
            NATT_PORT) natt_port="$value" ;;
            PSK) psk="$value" ;;
            TUNNEL_CIDR) tunnel_cidr="$value" ;;
            XFRM_ID) xfrm_id="$value" ;;
            XFRM_IF) legacy_xfrm_if="$value" ;;
            INGRESS_XFRM_IF) ingress_xfrm_if="$value" ;;
            EGRESS_XFRM_IF) egress_xfrm_if="$value" ;;
            XFRM_MTU) xfrm_mtu="$value" ;;
            INGRESS_XFRM_CIDR) ingress_xfrm_cidr="$value" ;;
            EGRESS_XFRM_CIDR) egress_xfrm_cidr="$value" ;;
            INGRESS_XFRM_IP) ingress_xfrm_ip="$value" ;;
            EGRESS_XFRM_IP) egress_xfrm_ip="$value" ;;
            INGRESS_ID) ingress_id="$value" ;;
            EGRESS_ID) egress_id="$value" ;;
            DNS_PRIMARY) dns_primary="$value" ;;
            DNS_SECONDARY) dns_secondary="$value" ;;
        esac
    done <<<"$decoded"
    token_version=${token_version#$'\xEF\xBB\xBF'}
    case "$token_version" in 1|2|3|4|5) ;; '') die 'The pairing token does not contain TOKEN_VERSION.' ;; *) die "Unsupported pairing token version '${token_version}'." ;; esac
    [[ "$port_mode" == standard || "$port_mode" == custom ]] || die 'Invalid transport mode in token.'
    validate_udp_port "$ike_port" || die 'Invalid IKE port in token.'
    validate_udp_port "$natt_port" || die 'Invalid NAT-T port in token.'
    if [[ "$port_mode" == custom ]]; then
        case "$token_version" in 4|5) ;; *) die 'This obsolete custom-port token must be regenerated on the egress node.' ;; esac
        [[ "$ike_port" == "$DEFAULT_IKE_PORT" ]] || die 'Invalid custom token: IKE_PORT must remain at the internal default.'
        [[ "$natt_port" != "$DEFAULT_IKE_PORT" ]] || die 'Invalid custom token: custom direct port may not be UDP 500.'
    fi
    if [[ "$token_version" == 5 ]]; then
        validate_profile_name "$profile_name" || die 'Invalid or missing profile name in token.'
        validate_interface_name "$ingress_xfrm_if" || die 'Invalid ingress XFRM interface in token.'
    else
        profile_name='legacy-peer'
        ingress_xfrm_if="$legacy_xfrm_if"
        egress_xfrm_if="$legacy_xfrm_if"
    fi
    require_ipv4 'egress public IP' "$exit_public_ip"
    require_ipv4 'ingress XFRM IP' "$ingress_xfrm_ip"
    require_ipv4 'egress XFRM IP' "$egress_xfrm_ip"
    require_ipv4 'primary DNS server' "$dns_primary"
    require_ipv4 'secondary DNS server' "$dns_secondary"
    validate_uint_range "$xfrm_id" 1 4294967295 || die 'Invalid XFRM interface ID in token.'
    validate_uint_range "$xfrm_mtu" 1200 9000 || die 'Invalid XFRM MTU in token.'
    validate_identity "$ingress_id" || die 'Invalid ingress identity in token.'
    validate_identity "$egress_id" || die 'Invalid egress identity in token.'
    [[ "$psk" =~ ^[A-Fa-f0-9]{64,128}$ ]] || die 'Invalid pre-shared key in token.'
    cidr_hosts "$tunnel_cidr" >/dev/null || die 'Invalid tunnel CIDR in token.'

    TOKEN_PROFILE_NAME="$profile_name"
    TOKEN_EXIT_PUBLIC_IP="$exit_public_ip"; TOKEN_PORT_MODE="$port_mode"
    TOKEN_IKE_PORT="$ike_port"; TOKEN_NATT_PORT="$natt_port"; TOKEN_PSK="$psk"
    TOKEN_TUNNEL_CIDR="$tunnel_cidr"; TOKEN_XFRM_ID="$xfrm_id"; TOKEN_XFRM_IF="$ingress_xfrm_if"
    TOKEN_EGRESS_XFRM_IF="$egress_xfrm_if"; TOKEN_XFRM_MTU="$xfrm_mtu"
    TOKEN_INGRESS_XFRM_CIDR="$ingress_xfrm_cidr"; TOKEN_EGRESS_XFRM_CIDR="$egress_xfrm_cidr"
    TOKEN_INGRESS_XFRM_IP="$ingress_xfrm_ip"; TOKEN_EGRESS_XFRM_IP="$egress_xfrm_ip"
    TOKEN_INGRESS_ID="$ingress_id"; TOKEN_EGRESS_ID="$egress_id"
    TOKEN_DNS_PRIMARY="$dns_primary"; TOKEN_DNS_SECONDARY="$dns_secondary"
}

# New dispatchers override the single-peer egress functions while retaining the
# proven 1.x ingress implementation.
setup_egress() { setup_egress_hub; }

configured_ingress() {
    [[ -f "$CONFIG_FILE" && ! -f "$HOST_CONFIG_FILE" ]] || return 1
    (
        set +u
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
        [[ "${ROLE:-}" == ingress ]]
    )
}

current_node_role() {
    if hub_configured; then
        printf 'egress-hub'
    elif configured_ingress; then
        printf 'ingress-client'
    elif [[ -f "$CONFIG_FILE" ]]; then
        printf 'legacy-or-invalid'
    else
        printf 'unconfigured'
    fi
}

dns_query_from_source() {
    local source_ip="$1" server="$2" domain="${3:-example.com}" answer
    answer=$(timeout 7s dig -4 -b "$source_ip" "@${server}" "$domain" A \
        +time=3 +tries=1 +short 2>/dev/null | awk 'NF {print; exit}' || true)
    [[ -n "$answer" ]] || return 1
    printf '%s' "$answer"
}

ping_from_source() {
    local source="$1" target="$2"
    ping -4 -I "$source" -c 2 -W 2 "$target" >/dev/null 2>&1
}

iptables_rule_counters() {
    local table="$1" chain="$2" comment="$3" line
    line=$(iptables -t "$table" -L "$chain" -v -x -n 2>/dev/null | \
        awk -v c="$comment" 'index($0,c) {print; exit}')
    [[ -n "$line" ]] || return 1
    awk '{printf "%s packets / %s bytes", $1, $2}' <<<"$line"
}

ingress_main_dashboard() {
    load_config
    evaluate_live_status
    section_title 'Ingress client'
    printf '  %-22s %s%s%s\n' 'Status' "$LIVE_COLOR" "$LIVE_STATUS" "$C_RESET" >"$TTY_OUT"
    printf '  %-22s %s\n' 'Connection profile' "${PROFILE_NAME:-paired-egress}" >"$TTY_OUT"
    printf '  %-22s %s\n' 'Egress endpoint' "$PEER_PUBLIC_IP" >"$TTY_OUT"
    printf '  %-22s %s\n' 'Transport' "$(transport_description)" >"$TTY_OUT"
    printf '  %-22s %s -> %s\n' 'Tunnel' "$XFRM_LOCAL_IP" "$XFRM_PEER_IP" >"$TTY_OUT"
    printf '  %-22s %s\n' 'Health' "$LIVE_REASON" >"$TTY_OUT"
}

ingress_diagnostics_menu() {
    local choice
    while configured_ingress; do
        clear_screen; banner
        ingress_main_dashboard
        cat >"$TTY_OUT" <<EOF_INGRESS_DIAG

${C_BOLD}${C_MAGENTA}INGRESS DIAGNOSTICS${C_RESET}
  ${C_CYAN}1)${C_RESET} Health summary
  ${C_GREEN}2)${C_RESET} Run end-to-end ping, Internet and DNS-over-NAT tests
  ${C_CYAN}3)${C_RESET} Tunnel session and traffic counters
  ${C_CYAN}4)${C_RESET} Routing rules and DNS paths
  ${C_CYAN}5)${C_RESET} Services, transport and public-IP path
  ${C_YELLOW}6)${C_RESET} Recent warnings and failures
  ${C_MAGENTA}7)${C_RESET} Export detailed redacted report
  ${C_RED}0)${C_RESET} Back
EOF_INGRESS_DIAG
        choice=$(prompt 'Select a diagnostic view: ')
        case "$choice" in
            1) diagnostics_overview || true; pause_screen ;;
            2) ingress_connectivity_tests || true; pause_screen ;;
            3) diagnostics_tunnel; pause_screen ;;
            4) diagnostics_routing; pause_screen ;;
            5) diagnostics_ports; pause_screen ;;
            6) diagnostics_logs; pause_screen ;;
            7) write_diagnostic_report; pause_screen ;;
            0) return 0 ;;
            *) warn 'Invalid selection.'; sleep 1 ;;
        esac
    done
}

diagnostics_menu() {
    if configured_ingress; then
        ingress_diagnostics_menu
    elif hub_configured; then
        hub_diagnostics_menu
    else
        diagnostics_preflight
        pause_screen
    fi
}

hub_connectivity_tests() {
    load_host_config
    clear_screen; banner
    section_title 'Egress hub Internet and DNS tests'
    local failures=0 gateway observed answer name peer_failures=0
    gateway=$(detect_default_gateway || true)

    if [[ -n "$gateway" ]] && ping_from_source "$WAN_IF" "$gateway"; then
        print_check pass 'Default gateway ping' "$gateway responds on $WAN_IF"
    elif [[ -n "$gateway" ]]; then
        print_check fail 'Default gateway ping' "$gateway did not respond on $WAN_IF"
        failures=$((failures + 1))
    else
        print_check warn 'Default gateway ping' 'No gateway address was detected'
    fi

    if ping_from_source "$LOCAL_IP" 1.1.1.1; then
        print_check pass 'Public Internet ping' '1.1.1.1 responds from the hub WAN address'
    else
        print_check fail 'Public Internet ping' '1.1.1.1 did not respond from the hub WAN address'
        failures=$((failures + 1))
    fi

    if answer=$(dns_query_from_source "$LOCAL_IP" "$DEFAULT_DNS_PRIMARY"); then
        print_check pass 'Primary upstream DNS' "$DEFAULT_DNS_PRIMARY returned $answer"
    else
        print_check fail 'Primary upstream DNS' "$DEFAULT_DNS_PRIMARY did not answer from the hub"
        failures=$((failures + 1))
    fi
    if answer=$(dns_query_from_source "$LOCAL_IP" "$DEFAULT_DNS_SECONDARY"); then
        print_check pass 'Secondary upstream DNS' "$DEFAULT_DNS_SECONDARY returned $answer"
    else
        print_check fail 'Secondary upstream DNS' "$DEFAULT_DNS_SECONDARY did not answer from the hub"
        failures=$((failures + 1))
    fi

    observed=$(detect_public_ipv4 || true)
    if [[ -n "$observed" ]]; then
        [[ "$observed" == "$PUBLIC_IP" ]] && \
            print_check pass 'Advertised public IPv4' "$observed" || \
            print_check warn 'Advertised public IPv4' "observed $observed; configured $PUBLIC_IP"
    else
        print_check warn 'Advertised public IPv4' 'External lookup failed'
    fi

    section_title 'Per-connection tunnel peer pings'
    if [[ "$(profile_count)" -eq 0 ]]; then
        print_check info 'Connections' 'No egress connections exist yet.'
    else
        while IFS= read -r name; do
            [[ -n "$name" ]] || continue
            collect_client_runtime "$name"
            if [[ "$SNAP_IKE" != ESTABLISHED || "$SNAP_CHILD" != INSTALLED ]]; then
                print_check warn "$name" 'No active IKE/CHILD session; peer ping skipped'
                continue
            fi
            if ping_from_source "$SNAP_XFRM" "$SNAP_REMOTE_TUNNEL"; then
                print_check pass "$name" "$SNAP_REMOTE_TUNNEL responds through $SNAP_XFRM"
            else
                print_check fail "$name" "$SNAP_REMOTE_TUNNEL is unreachable through $SNAP_XFRM"
                peer_failures=$((peer_failures + 1))
            fi
        done < <(profile_names)
    fi
    failures=$((failures + peer_failures))

    section_title 'Result'
    if ((failures == 0)); then
        printf '  %s%sPASS%s  Hub WAN, upstream DNS and active peer tests succeeded.\n' \
            "$C_BOLD" "$C_GREEN" "$C_RESET" >"$TTY_OUT"
        return 0
    fi
    printf '  %s%sFAIL%s  %d hub or peer test(s) failed.\n' \
        "$C_BOLD" "$C_RED" "$C_RESET" "$failures" >"$TTY_OUT"
    return 1
}

client_diag_dns_nat() {
    local name="$1" answer counters nat_comment
    load_host_config
    collect_client_runtime "$name"
    load_client_profile "$name"
    clear_screen; banner
    section_title "DNS and NAT readiness: ${name}"

    if [[ "$SNAP_IKE" == ESTABLISHED && "$SNAP_CHILD" == INSTALLED ]]; then
        print_check pass 'Encrypted connection' 'IKE and CHILD SAs are active'
    else
        print_check warn 'Encrypted connection' 'No active IKE/CHILD session; remote DNS-over-NAT cannot currently pass'
    fi

    if answer=$(dns_query_from_source "$LOCAL_IP" "$DNS_PRIMARY"); then
        print_check pass 'Primary DNS from egress' "$DNS_PRIMARY returned $answer"
    else
        print_check fail 'Primary DNS from egress' "$DNS_PRIMARY did not answer from the hub WAN address"
    fi
    if answer=$(dns_query_from_source "$LOCAL_IP" "$DNS_SECONDARY"); then
        print_check pass 'Secondary DNS from egress' "$DNS_SECONDARY returned $answer"
    else
        print_check fail 'Secondary DNS from egress' "$DNS_SECONDARY did not answer from the hub WAN address"
    fi

    nat_comment=$(client_rule_comment "$name" nat)
    if counters=$(iptables_rule_counters nat POSTROUTING "$nat_comment"); then
        print_check pass 'Per-connection source NAT' "$counters observed on $nat_comment"
    else
        print_check fail 'Per-connection source NAT' "$nat_comment is missing"
    fi
    print_check info 'SA traffic evidence' "$(snapshot_traffic_text)"
    print_check info 'End-to-end DNS-over-NAT' 'Run Connectivity tests on the paired ingress client for an active query through this NAT rule.'
}


format_seconds_short() {
    local value="${1:-0}" seconds days hours minutes output=''
    value=${value%s}
    [[ "$value" =~ ^[0-9]+$ ]] || { printf '-'; return; }
    seconds=$value
    days=$((seconds / 86400)); seconds=$((seconds % 86400))
    hours=$((seconds / 3600)); seconds=$((seconds % 3600))
    minutes=$((seconds / 60)); seconds=$((seconds % 60))
    ((days > 0)) && output+="${days}d"
    ((hours > 0)) && output+="${hours}h"
    ((minutes > 0)) && output+="${minutes}m"
    [[ -z "$output" || "$seconds" -gt 0 ]] && output+="${seconds}s"
    printf '%s' "$output"
}

format_bytes_short() {
    local value="${1:-0}"
    [[ "$value" =~ ^[0-9]+$ ]] || value=0
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec --suffix=B "$value" 2>/dev/null || printf '%sB' "$value"
    else
        printf '%sB' "$value"
    fi
}

fit_text() {
    local value="$1" width="$2"
    if ((${#value} <= width)); then
        printf '%s' "$value"
    elif ((width > 3)); then
        printf '%s...' "${value:0:width-3}"
    else
        printf '%s' "${value:0:width}"
    fi
}

parse_sa_counter() {
    local sa="$1" direction="$2" line bytes packets ago
    line=$(awk -v d="$direction" '$1 == d {print; exit}' <<<"$sa")
    if [[ -z "$line" ]]; then
        printf '0\t0\t-\n'
        return
    fi
    bytes=$(sed -nE 's/.*\),[[:space:]]*([0-9]+) bytes,.*/\1/p' <<<"$line")
    packets=$(sed -nE 's/.*bytes,[[:space:]]*([0-9]+) packets,.*/\1/p' <<<"$line")
    ago=$(sed -nE 's/.*packets,[[:space:]]*([0-9]+s) ago.*/\1/p' <<<"$line")
    printf '%s\t%s\t%s\n' "${bytes:-0}" "${packets:-0}" "${ago:--}"
}

collect_client_runtime() {
    local name="$1" unit sas rx_line tx_line

    SNAP_NAME="$name"
    SNAP_STATUS='MISSING'
    SNAP_SERVICE='not-found'
    SNAP_ENABLED='unknown'
    SNAP_LISTENER='missing'
    SNAP_IKE='DOWN'
    SNAP_CHILD='DOWN'
    SNAP_PEER='-'
    SNAP_AGE='-'
    SNAP_RX_BYTES='0'
    SNAP_RX_PACKETS='0'
    SNAP_RX_AGO='-'
    SNAP_TX_BYTES='0'
    SNAP_TX_PACKETS='0'
    SNAP_TX_AGO='-'
    SNAP_TRANSPORT='-'
    SNAP_XFRM='-'
    SNAP_XFRM_ID='-'
    SNAP_TUNNEL='-'
    SNAP_LOCAL_TUNNEL='-'
    SNAP_REMOTE_TUNNEL='-'
    SNAP_VICI='-'
    SNAP_PROFILE_FILE='-'
    SNAP_SWANCTL_FILE='-'
    SNAP_STRONGSWAN_FILE='-'

    profile_exists "$name" || return 1
    load_client_profile "$name"
    unit=$(profile_service "$name")
    SNAP_SERVICE=$(systemctl is-active "$unit" 2>/dev/null || true)
    SNAP_ENABLED=$(systemctl is-enabled "$unit" 2>/dev/null || true)
    SNAP_TRANSPORT=$(if [[ "$PORT_MODE" == standard ]]; then printf 'UDP 500/4500'; else printf 'UDP %s' "$NATT_PORT"; fi)
    SNAP_XFRM="$XFRM_IF"
    SNAP_XFRM_ID="$XFRM_ID"
    SNAP_TUNNEL="$TUNNEL_CIDR"
    SNAP_LOCAL_TUNNEL="$EGRESS_XFRM_IP"
    SNAP_REMOTE_TUNNEL="$INGRESS_XFRM_IP"
    SNAP_VICI="$VICI_SOCKET"
    SNAP_PROFILE_FILE=$(profile_config_file "$name")
    SNAP_SWANCTL_FILE=$(profile_swanctl_canonical "$name")
    SNAP_STRONGSWAN_FILE=$(profile_strongswan_canonical "$name")

    if [[ "$SNAP_SERVICE" != active ]]; then
        [[ "$SNAP_SERVICE" == failed ]] && SNAP_STATUS='FAILED' || SNAP_STATUS='STOPPED'
        return 0
    fi
    if ! ip link show dev "$XFRM_IF" >/dev/null 2>&1; then
        SNAP_STATUS='FAILED'
        return 0
    fi
    if profile_listener_ok "$name"; then
        SNAP_LISTENER='listening'
    else
        SNAP_STATUS='DEGRADED'
        return 0
    fi

    sas=$(client_swanctl "$name" --list-sas 2>/dev/null || true)
    if grep -q ESTABLISHED <<<"$sas"; then
        SNAP_IKE='ESTABLISHED'
        SNAP_PEER=$(awk '/^[[:space:]]*remote / {for (i=1; i<=NF; i++) if ($i == "@") {print $(i+1); exit}}' <<<"$sas")
        SNAP_PEER=${SNAP_PEER:--}
        SNAP_AGE=$(awk '/^[[:space:]]*established [0-9]+s ago/ {print $2; exit}' <<<"$sas")
        SNAP_AGE=$(format_seconds_short "${SNAP_AGE:--}")
    fi
    if grep -q INSTALLED <<<"$sas"; then
        SNAP_CHILD='INSTALLED'
    fi

    IFS=$'\t' read -r SNAP_RX_BYTES SNAP_RX_PACKETS SNAP_RX_AGO < <(parse_sa_counter "$sas" in)
    IFS=$'\t' read -r SNAP_TX_BYTES SNAP_TX_PACKETS SNAP_TX_AGO < <(parse_sa_counter "$sas" out)

    if [[ "$SNAP_IKE" == ESTABLISHED && "$SNAP_CHILD" == INSTALLED ]]; then
        if ping -I "$XFRM_IF" -c 1 -W 1 "$INGRESS_XFRM_IP" >/dev/null 2>&1; then
            SNAP_STATUS='OPERATIONAL'
        else
            SNAP_STATUS='DISCONNECTED'
        fi
    else
        SNAP_STATUS='READY'
    fi
}

snapshot_traffic_text() {
    printf 'RX %s/%s pkts | TX %s/%s pkts' \
        "$(format_bytes_short "$SNAP_RX_BYTES")" "$SNAP_RX_PACKETS" \
        "$(format_bytes_short "$SNAP_TX_BYTES")" "$SNAP_TX_PACKETS"
}

status_color_for() {
    case "$1" in
        OPERATIONAL) printf '%s' "$C_GREEN" ;;
        READY) printf '%s' "$C_CYAN" ;;
        STOPPED) printf '%s' "$C_YELLOW" ;;
        DISCONNECTED|DEGRADED) printf '%s' "$C_YELLOW" ;;
        FAILED|MISSING) printf '%s' "$C_RED" ;;
        *) printf '%s' "$C_WHITE" ;;
    esac
}

hub_status_counts() {
    HUB_TOTAL=0 HUB_OPERATIONAL=0 HUB_READY=0 HUB_STOPPED=0 HUB_UNHEALTHY=0
    local name
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        HUB_TOTAL=$((HUB_TOTAL + 1))
        collect_client_runtime "$name"
        case "$SNAP_STATUS" in
            OPERATIONAL) HUB_OPERATIONAL=$((HUB_OPERATIONAL + 1)) ;;
            READY) HUB_READY=$((HUB_READY + 1)) ;;
            STOPPED) HUB_STOPPED=$((HUB_STOPPED + 1)) ;;
            *) HUB_UNHEALTHY=$((HUB_UNHEALTHY + 1)) ;;
        esac
    done < <(profile_names)
}

hub_state_word() {
    if [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || true)" != 1 ]]; then
        printf 'DEGRADED'
    elif ((HUB_TOTAL == 0)); then
        printf 'EMPTY'
    elif ((HUB_UNHEALTHY > 0)); then
        printf 'DEGRADED'
    elif ((HUB_OPERATIONAL > 0)); then
        printf 'OPERATIONAL'
    elif ((HUB_READY > 0)); then
        printf 'READY'
    elif ((HUB_STOPPED == HUB_TOTAL)); then
        printf 'STOPPED'
    else
        printf 'DEGRADED'
    fi
}

hub_main_dashboard() {
    load_host_config
    local name state active_count=0 hub_state
    local -a active_rows=()

    HUB_TOTAL=0 HUB_OPERATIONAL=0 HUB_READY=0 HUB_STOPPED=0 HUB_UNHEALTHY=0
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        HUB_TOTAL=$((HUB_TOTAL + 1))
        collect_client_runtime "$name"
        state="$SNAP_STATUS"
        case "$state" in
            OPERATIONAL)
                HUB_OPERATIONAL=$((HUB_OPERATIONAL + 1))
                active_rows+=("$name|$SNAP_PEER|$SNAP_TRANSPORT|$SNAP_AGE")
                ;;
            READY) HUB_READY=$((HUB_READY + 1)) ;;
            STOPPED) HUB_STOPPED=$((HUB_STOPPED + 1)) ;;
            *) HUB_UNHEALTHY=$((HUB_UNHEALTHY + 1)) ;;
        esac
    done < <(profile_names)
    hub_state=$(hub_state_word)

    section_title 'Egress hub'
    printf '  %-22s %s%s%s\n' 'Hub status' "$(status_color_for "$hub_state")" "$hub_state" "$C_RESET" >"$TTY_OUT"
    printf '  %-22s %s on %s\n' 'Public endpoint' "$PUBLIC_IP" "$WAN_IF" >"$TTY_OUT"
    printf '  %-22s %s total | %s connected | %s waiting | %s stopped | %s unhealthy\n' \
        'Clients' "$HUB_TOTAL" "$HUB_OPERATIONAL" "$HUB_READY" "$HUB_STOPPED" "$HUB_UNHEALTHY" >"$TTY_OUT"

    section_title 'Active egress connections'
    if ((${#active_rows[@]} == 0)); then
        print_check info 'Active sessions' 'No client currently has a verified IKE/CHILD data path.'
        return 0
    fi
    printf '  %-20s %-22s %-15s %s\n' 'CLIENT' 'REMOTE PEER' 'TRANSPORT' 'UPTIME' >"$TTY_OUT"
    printf '  %-20s %-22s %-15s %s\n' '--------------------' '----------------------' '---------------' '--------' >"$TTY_OUT"
    local row client peer transport age
    for row in "${active_rows[@]}"; do
        IFS='|' read -r client peer transport age <<<"$row"
        printf '  %-20s %-22s %-15s %s\n' \
            "$(fit_text "$client" 20)" "$(fit_text "$peer" 22)" "$transport" "$age" >"$TTY_OUT"
        active_count=$((active_count + 1))
    done
}

list_hub_clients() {
    local json="${1:-no}" name first=yes
    load_host_config
    if [[ "$json" == yes ]]; then
        printf '['
        while IFS= read -r name; do
            [[ -n "$name" ]] || continue
            collect_client_runtime "$name"
            [[ "$first" == yes ]] || printf ','
            first=no
            python3 - "$SNAP_NAME" "$SNAP_STATUS" "$SNAP_SERVICE" "$SNAP_ENABLED" "$SNAP_TRANSPORT" \
                "$SNAP_PEER" "$SNAP_AGE" "$SNAP_XFRM" "$SNAP_XFRM_ID" "$SNAP_TUNNEL" \
                "$SNAP_RX_BYTES" "$SNAP_RX_PACKETS" "$SNAP_TX_BYTES" "$SNAP_TX_PACKETS" <<'PY_ROW'
import json, sys
print(json.dumps({
    "name": sys.argv[1], "status": sys.argv[2], "service": sys.argv[3],
    "enabled": sys.argv[4], "transport": sys.argv[5], "peer": sys.argv[6],
    "uptime": sys.argv[7], "xfrm_interface": sys.argv[8], "xfrm_id": int(sys.argv[9]),
    "tunnel": sys.argv[10], "rx_bytes": int(sys.argv[11]), "rx_packets": int(sys.argv[12]),
    "tx_bytes": int(sys.argv[13]), "tx_packets": int(sys.argv[14])
}), end='')
PY_ROW
        done < <(profile_names)
        printf ']\n'
        return 0
    fi

    section_title 'All egress connections - detailed inventory'
    if [[ "$(profile_count)" -eq 0 ]]; then
        print_check info 'Connections' 'No egress connections have been created yet.'
        return 0
    fi
    printf '  %-20s %-12s %-9s %-15s %-22s %s\n' \
        'CLIENT' 'STATUS' 'SERVICE' 'TRANSPORT' 'REMOTE PEER' 'UPTIME' >"$TTY_OUT"
    printf '  %-20s %-12s %-9s %-15s %-22s %s\n' \
        '--------------------' '------------' '---------' '---------------' '----------------------' '--------' >"$TTY_OUT"
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        collect_client_runtime "$name"
        printf '  %-20s %-12s %-9s %-15s %-22s %s\n' \
            "$(fit_text "$SNAP_NAME" 20)" "$SNAP_STATUS" "$SNAP_SERVICE" "$SNAP_TRANSPORT" \
            "$(fit_text "$SNAP_PEER" 22)" "$SNAP_AGE" >"$TTY_OUT"
        printf '    XFRM %-10s ID %-6s | Tunnel %-18s | %s\n' \
            "$SNAP_XFRM" "$SNAP_XFRM_ID" "$SNAP_TUNNEL" "$(snapshot_traffic_text)" >"$TTY_OUT"
    done < <(profile_names)
}

show_client_header() {
    local name="$1"
    collect_client_runtime "$name"
    section_title "Egress connection: ${name}"
    printf '  %-18s %s%s%s\n' 'Status' "$(status_color_for "$SNAP_STATUS")" "$SNAP_STATUS" "$C_RESET" >"$TTY_OUT"
    printf '  %-18s %s\n' 'Transport' "$SNAP_TRANSPORT" >"$TTY_OUT"
    printf '  %-18s %s\n' 'Remote peer' "$SNAP_PEER" >"$TTY_OUT"
    printf '  %-18s %s -> %s\n' 'Tunnel' "$SNAP_LOCAL_TUNNEL" "$SNAP_REMOTE_TUNNEL" >"$TTY_OUT"
}

show_client_status() {
    local name="$1" json="${2:-no}"
    collect_client_runtime "$name"
    if [[ "$json" == yes ]]; then
        python3 - "$SNAP_NAME" "$SNAP_STATUS" "$SNAP_SERVICE" "$SNAP_ENABLED" "$SNAP_LISTENER" \
            "$SNAP_TRANSPORT" "$SNAP_PEER" "$SNAP_AGE" "$SNAP_IKE" "$SNAP_CHILD" \
            "$SNAP_XFRM" "$SNAP_XFRM_ID" "$SNAP_TUNNEL" "$SNAP_LOCAL_TUNNEL" "$SNAP_REMOTE_TUNNEL" \
            "$SNAP_RX_BYTES" "$SNAP_RX_PACKETS" "$SNAP_TX_BYTES" "$SNAP_TX_PACKETS" <<'PY_STATUS'
import json, sys
print(json.dumps({
    "name": sys.argv[1], "status": sys.argv[2], "service": sys.argv[3],
    "enabled": sys.argv[4], "listener": sys.argv[5], "transport": sys.argv[6],
    "peer": sys.argv[7], "uptime": sys.argv[8], "ike": sys.argv[9], "child": sys.argv[10],
    "xfrm_interface": sys.argv[11], "xfrm_id": int(sys.argv[12]), "tunnel": sys.argv[13],
    "egress_xfrm_ip": sys.argv[14], "ingress_xfrm_ip": sys.argv[15],
    "rx_bytes": int(sys.argv[16]), "rx_packets": int(sys.argv[17]),
    "tx_bytes": int(sys.argv[18]), "tx_packets": int(sys.argv[19])
}, indent=2))
PY_STATUS
        return 0
    fi

    clear_screen; banner
    section_title "Connection status: ${name}"
    print_check info 'Overall status' "$SNAP_STATUS"
    print_check info 'Service' "$SNAP_SERVICE (boot: $SNAP_ENABLED)"
    print_check info 'Transport' "$SNAP_TRANSPORT ($SNAP_LISTENER)"
    print_check info 'Remote peer' "$SNAP_PEER"
    print_check info 'IKE session' "$SNAP_IKE"
    print_check info 'CHILD SA' "$SNAP_CHILD"
    print_check info 'Session uptime' "$SNAP_AGE"
    print_check info 'XFRM interface' "$SNAP_XFRM (ID $SNAP_XFRM_ID)"
    print_check info 'Tunnel addresses' "$SNAP_LOCAL_TUNNEL -> $SNAP_REMOTE_TUNNEL"
    print_check info 'Tunnel network' "$SNAP_TUNNEL"
    print_check info 'Traffic' "$(snapshot_traffic_text)"
}

select_client_interactive() {
    local -a names=() name selection index=1
    while IFS= read -r name; do [[ -n "$name" ]] && names+=("$name"); done < <(profile_names)
    ((${#names[@]})) || { warn 'No clients exist.'; return 1; }
    section_title 'Select egress connection'
    printf '  %-4s %-20s %-12s %-22s %s\n' '#' 'CLIENT' 'STATUS' 'REMOTE PEER' 'TRANSPORT' >"$TTY_OUT"
    for name in "${names[@]}"; do
        collect_client_runtime "$name"
        printf '  %-4s %-20s %-12s %-22s %s\n' "$index" "$(fit_text "$name" 20)" "$SNAP_STATUS" \
            "$(fit_text "$SNAP_PEER" 22)" "$SNAP_TRANSPORT" >"$TTY_OUT"
        index=$((index + 1))
    done
    selection=$(prompt 'Select connection: ')
    [[ "$selection" =~ ^[0-9]+$ ]] && ((selection >= 1 && selection <= ${#names[@]})) || { warn 'Invalid selection.'; return 1; }
    printf '%s' "${names[selection-1]}"
}

client_diag_ike() {
    local name="$1"
    collect_client_runtime "$name"
    clear_screen; banner
    section_title "IKE / CHILD summary: ${name}"
    print_check info 'Overall status' "$SNAP_STATUS"
    print_check info 'Remote peer' "$SNAP_PEER"
    print_check info 'IKE session' "$SNAP_IKE"
    print_check info 'CHILD SA' "$SNAP_CHILD"
    print_check info 'Session uptime' "$SNAP_AGE"
    print_check info 'Last inbound packet' "$SNAP_RX_AGO"
    print_check info 'Last outbound packet' "$SNAP_TX_AGO"
    print_check info 'Traffic' "$(snapshot_traffic_text)"
}

client_diag_network() {
    local name="$1"
    collect_client_runtime "$name"
    clear_screen; banner
    section_title "Network path: ${name}"
    ip link show dev "$SNAP_XFRM" >/dev/null 2>&1 && \
        print_check pass 'XFRM interface' "$SNAP_XFRM (ID $SNAP_XFRM_ID)" || \
        print_check fail 'XFRM interface' 'missing'
    ip -4 address show dev "$SNAP_XFRM" 2>/dev/null | grep -Fq "$SNAP_LOCAL_TUNNEL/" && \
        print_check pass 'Local tunnel address' "$SNAP_LOCAL_TUNNEL" || \
        print_check fail 'Local tunnel address' "$SNAP_LOCAL_TUNNEL not assigned"
    ping -I "$SNAP_XFRM" -c 1 -W 2 "$SNAP_REMOTE_TUNNEL" >/dev/null 2>&1 && \
        print_check pass 'Tunnel peer' "$SNAP_REMOTE_TUNNEL responds" || \
        print_check fail 'Tunnel peer' "$SNAP_REMOTE_TUNNEL is unreachable"
    print_check info 'Tunnel network' "$SNAP_TUNNEL"
    print_check info 'Interface counters' "$(xfrm_counter_summary "$SNAP_XFRM")"
    print_check info 'SA traffic' "$(snapshot_traffic_text)"
}

client_diag_service() {
    local name="$1" expected actual
    collect_client_runtime "$name"
    clear_screen; banner
    section_title "Service and configuration: ${name}"
    service_row "$(profile_service "$name")" "$name"
    [[ "$SNAP_LISTENER" == listening ]] && print_check pass 'UDP listener' "$SNAP_TRANSPORT" || print_check fail 'UDP listener' "$SNAP_TRANSPORT missing"
    [[ -S "$SNAP_VICI" ]] && print_check pass 'VICI socket' "$SNAP_VICI" || print_check fail 'VICI socket' "$SNAP_VICI missing"
    expected=$(profile_swanctl_source "$name")
    actual=$(readlink -f "$SNAP_SWANCTL_FILE" 2>/dev/null || true)
    [[ -f "$expected" && -L "$SNAP_SWANCTL_FILE" && "$actual" == "$(readlink -f "$expected" 2>/dev/null || true)" ]] && \
        print_check pass 'swanctl link' "$SNAP_SWANCTL_FILE" || print_check fail 'swanctl link' "$SNAP_SWANCTL_FILE"
    expected=$(profile_strongswan_source "$name")
    actual=$(readlink -f "$SNAP_STRONGSWAN_FILE" 2>/dev/null || true)
    [[ -f "$expected" && -L "$SNAP_STRONGSWAN_FILE" && "$actual" == "$(readlink -f "$expected" 2>/dev/null || true)" ]] && \
        print_check pass 'strongSwan link' "$SNAP_STRONGSWAN_FILE" || print_check fail 'strongSwan link' "$SNAP_STRONGSWAN_FILE"
    print_check info 'Profile metadata' "$SNAP_PROFILE_FILE"
}

client_diag_firewall() {
    local name="$1" forward_out forward_return nat
    load_host_config
    load_client_profile "$name"
    clear_screen; banner
    section_title "Forwarding and NAT: ${name}"
    forward_out=$(client_rule_comment "$name" forward-out)
    forward_return=$(client_rule_comment "$name" forward-return)
    nat=$(client_rule_comment "$name" nat)
    [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || true)" == 1 ]] && \
        print_check pass 'IPv4 forwarding' enabled || print_check fail 'IPv4 forwarding' disabled
    iptables -C FORWARD -i "$XFRM_IF" -o "$WAN_IF" -s "$INGRESS_XFRM_IP/32" \
        -m comment --comment "$forward_out" -j ACCEPT 2>/dev/null && \
        print_check pass 'Outbound forwarding' "$forward_out" || print_check fail 'Outbound forwarding' missing
    iptables -C FORWARD -i "$WAN_IF" -o "$XFRM_IF" -d "$INGRESS_XFRM_IP/32" \
        -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "$forward_return" -j ACCEPT 2>/dev/null && \
        print_check pass 'Return forwarding' "$forward_return" || print_check fail 'Return forwarding' missing
    iptables -t nat -C POSTROUTING -s "$INGRESS_XFRM_IP/32" -o "$WAN_IF" \
        -m comment --comment "$nat" -j MASQUERADE 2>/dev/null && \
        print_check pass 'Source NAT' "$nat" || print_check fail 'Source NAT' missing
}

run_client_live_capture() {
    local name="$1" mode="$2"
    local capture_interface capture_filter='' capture_pid='' status=0
    local -a capture_args=()

    load_host_config
    load_client_profile "$name"
    clear_screen; banner

    command -v tcpdump >/dev/null 2>&1 || {
        section_title "Live packet capture: ${name}"
        print_check fail 'tcpdump' 'Required command is not installed.'
        return 1
    }

    if ! ip link show dev "$XFRM_IF" >/dev/null 2>&1; then
        section_title "Live packet capture: ${name}"
        print_check fail 'XFRM interface' "${XFRM_IF} does not exist. Start the connection first."
        return 1
    fi

    case "$mode" in
        dns)
            section_title "Live DNS forwarding capture: ${name}"
            capture_interface='any'
            capture_filter="(host ${DNS_PRIMARY} or host ${DNS_SECONDARY}) and (udp port 53 or tcp port 53)"
            capture_args=(-i "$capture_interface" -nn -tttt -l -vv -s 512 "$capture_filter")
            print_check info 'Selected connection' "$name on $XFRM_IF"
            print_check info 'DNS servers' "$DNS_PRIMARY, $DNS_SECONDARY"
            print_check info 'Expected query path' "$XFRM_IF In -> $WAN_IF Out"
            print_check info 'Expected reply path' "$WAN_IF In -> $XFRM_IF Out"
            printf '\n  Run a DNS lookup on the paired ingress while this capture is active.\n' >"$TTY_OUT"
            printf '  Seeing the query on %s and then on %s verifies forwarding/NAT.\n' "$XFRM_IF" "$WAN_IF" >"$TTY_OUT"
            ;;
        traffic)
            section_title "Live tunnel traffic capture: ${name}"
            capture_interface="$XFRM_IF"
            capture_args=(-i "$capture_interface" -nn -tttt -l -vv)
            print_check info 'Capture interface' "$XFRM_IF"
            print_check info 'Traffic shown' 'All decrypted traffic crossing this connection'
            printf '\n  Generate traffic on the paired ingress to watch it cross the tunnel.\n' >"$TTY_OUT"
            ;;
        *)
            die "Unknown live-capture mode: ${mode}"
            ;;
    esac

    if ! systemctl is-active --quiet "$(profile_service "$name")" 2>/dev/null; then
        print_check warn 'Connection service' 'Not active; the capture will wait for traffic.'
    fi

    printf '  Press Ctrl+C to stop the live capture and return to diagnostics.\n\n' >"$TTY_OUT"
    log_line INFO "Starting live ${mode} capture for profile=${name} interface=${capture_interface}"

    local capture_interrupted=0
    trap 'capture_interrupted=1; [[ -n "${capture_pid:-}" ]] && kill -TERM "$capture_pid" >/dev/null 2>&1 || true' INT

    tcpdump "${capture_args[@]}" >"$TTY_OUT" 2>&1 &
    capture_pid=$!

    # Keep wait in a conditional context so Ctrl+C/status 130 never reaches
    # the installer's global ERR trap. The signal handler stops tcpdump and
    # this function then returns normally to the diagnostics menu.
    if wait "$capture_pid"; then
        status=0
    else
        status=$?
    fi

    if ((capture_interrupted)); then
        kill -TERM "$capture_pid" >/dev/null 2>&1 || true
        wait "$capture_pid" 2>/dev/null || true
        status=130
    fi

    trap - INT
    capture_pid=''

    printf '\n' >"$TTY_OUT"
    case "$status" in
        0|2|130|143)
            print_check info 'Live capture' 'Stopped.'
            ;;
        *)
            print_check fail 'Live capture' "tcpdump exited with status ${status}."
            return 1
            ;;
    esac
}

client_diag_live_dns() {
    run_client_live_capture "$1" dns
}

client_diag_live_traffic() {
    run_client_live_capture "$1" traffic
}

client_diag_logs() {
    local name="$1" unit
    unit=$(profile_service "$name")
    clear_screen; banner
    section_title "Recent warnings and errors: ${name}"
    journalctl -u "$unit" --since '-30 minutes' --no-pager -o short-iso 2>/dev/null | \
        grep -Ei 'warn|error|fail|retransmit|authentication|proposal|unreachable|timeout' | tail -n 80 >"$TTY_OUT" || true
    if ! journalctl -u "$unit" --since '-30 minutes' --no-pager -o cat 2>/dev/null | \
        grep -Eqi 'warn|error|fail|retransmit|authentication|proposal|unreachable|timeout'; then
        print_check pass 'Recent service log' 'No matching warning or error messages.'
    fi
}

client_diag_raw() {
    local name="$1" sas conns
    clear_screen; banner
    section_title "Advanced raw strongSwan output: ${name}"
    warn 'This view is intended for troubleshooting and may be verbose.'
    sas=$(client_swanctl "$name" --list-sas 2>&1 || true)
    conns=$(client_swanctl "$name" --list-conns 2>&1 || true)
    printf '\n%s-- Loaded connection --%s\n%s\n' "$C_BOLD" "$C_RESET" "${conns:-No connection output.}" >"$TTY_OUT"
    printf '\n%s-- IKE / CHILD state --%s\n%s\n' "$C_BOLD" "$C_RESET" "${sas:-No active security association.}" >"$TTY_OUT"
}


client_diagnostics_menu() {
    local name="$1" choice
    while profile_exists "$name"; do
        clear_screen; banner
        show_client_header "$name"
        cat >"$TTY_OUT" <<EOF_CLIENT_DIAG

${C_BOLD}${C_MAGENTA}EGRESS CONNECTION DIAGNOSTICS${C_RESET}
  ${C_CYAN}1)${C_RESET} IKE / CHILD and traffic summary
  ${C_GREEN}2)${C_RESET} Tunnel peer ping and XFRM path
  ${C_GREEN}3)${C_RESET} DNS and per-connection NAT readiness
  ${C_CYAN}4)${C_RESET} Service, listener and canonical configuration links
  ${C_CYAN}5)${C_RESET} Forwarding and NAT rules
  ${C_YELLOW}6)${C_RESET} Recent warnings and errors
  ${C_RED}7)${C_RESET} Advanced raw strongSwan output
  ${C_GREEN}8)${C_RESET} Live DNS forwarding capture
  ${C_GREEN}9)${C_RESET} Live tunnel traffic capture
  ${C_RED}0)${C_RESET} Back
EOF_CLIENT_DIAG
        choice=$(prompt 'Select a diagnostic view: ')
        case "$choice" in
            1) client_diag_ike "$name"; pause_screen ;;
            2) client_diag_network "$name"; pause_screen ;;
            3) client_diag_dns_nat "$name"; pause_screen ;;
            4) client_diag_service "$name"; pause_screen ;;
            5) client_diag_firewall "$name"; pause_screen ;;
            6) client_diag_logs "$name"; pause_screen ;;
            7) client_diag_raw "$name"; pause_screen ;;
            8) client_diag_live_dns "$name"; pause_screen ;;
            9) client_diag_live_traffic "$name"; pause_screen ;;
            0) return 0 ;;
            *) warn 'Invalid selection.'; sleep 1 ;;
        esac
    done
}

hub_runtime_overview() {
    load_host_config
    hub_status_counts
    local hub_state
    hub_state=$(hub_state_word)
    section_title 'Hub runtime'
    print_check info 'Hub status' "$hub_state"
    print_check info 'Public endpoint' "$PUBLIC_IP"
    print_check info 'Physical interface' "$WAN_IF"
    print_check info 'Connection totals' "$HUB_TOTAL total | $HUB_OPERATIONAL connected | $HUB_READY waiting | $HUB_STOPPED stopped | $HUB_UNHEALTHY unhealthy"
    [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || true)" == 1 ]] && \
        print_check pass 'IPv4 forwarding' enabled || print_check fail 'IPv4 forwarding' disabled
    [[ -f "$CLIENT_UNIT_TEMPLATE" ]] && print_check pass 'Client unit template' "$CLIENT_UNIT_TEMPLATE" || print_check fail 'Client unit template' missing
    [[ -d "$SWANCTL_CLIENT_ROOT" ]] && print_check pass 'swanctl namespace' "$SWANCTL_CLIENT_ROOT" || print_check fail 'swanctl namespace' missing
    [[ -d "$STRONGSWAN_CLIENT_ROOT" ]] && print_check pass 'strongSwan namespace' "$STRONGSWAN_CLIENT_ROOT" || print_check fail 'strongSwan namespace' missing
}

hub_listener_inventory() {
    local name
    clear_screen; banner
    section_title 'Per-connection UDP listeners'
    printf '  %-20s %-15s %-10s %s\n' 'CLIENT' 'TRANSPORT' 'LISTENER' 'SERVICE' >"$TTY_OUT"
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        collect_client_runtime "$name"
        printf '  %-20s %-15s %-10s %s\n' "$(fit_text "$name" 20)" "$SNAP_TRANSPORT" "$SNAP_LISTENER" "$SNAP_SERVICE" >"$TTY_OUT"
    done < <(profile_names)
}

hub_firewall_inventory() {
    local name
    clear_screen; banner
    section_title 'Per-connection forwarding and NAT'
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        load_host_config
        load_client_profile "$name"
        printf '\n  %s%s%s\n' "$C_BOLD" "$name" "$C_RESET" >"$TTY_OUT"
        iptables -C FORWARD -i "$XFRM_IF" -o "$WAN_IF" -s "$INGRESS_XFRM_IP/32" \
            -m comment --comment "$(client_rule_comment "$name" forward-out)" -j ACCEPT 2>/dev/null && \
            print_check pass 'Outbound forwarding' installed || print_check fail 'Outbound forwarding' missing
        iptables -C FORWARD -i "$WAN_IF" -o "$XFRM_IF" -d "$INGRESS_XFRM_IP/32" \
            -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "$(client_rule_comment "$name" forward-return)" -j ACCEPT 2>/dev/null && \
            print_check pass 'Return forwarding' installed || print_check fail 'Return forwarding' missing
        iptables -t nat -C POSTROUTING -s "$INGRESS_XFRM_IP/32" -o "$WAN_IF" \
            -m comment --comment "$(client_rule_comment "$name" nat)" -j MASQUERADE 2>/dev/null && \
            print_check pass 'Source NAT' installed || print_check fail 'Source NAT' missing
    done < <(profile_names)
}

hub_recent_errors() {
    clear_screen; banner
    section_title 'Recent hub warnings and errors'
    local output
    output=$(journalctl --since '-30 minutes' --no-pager -o short-iso 2>/dev/null | \
        grep -E 'dragonfruit-relay-client@|charon-systemd' | \
        grep -Ei 'warn|error|fail|retransmit|authentication|proposal|unreachable|timeout' | tail -n 100 || true)
    [[ -n "$output" ]] && printf '%s\n' "$output" >"$TTY_OUT" || print_check pass 'Recent logs' 'No matching hub or client errors.'
}

hub_health_overview() {
    clear_screen; banner
    hub_runtime_overview
    local name issues=0
    section_title 'Connections requiring attention'
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        collect_client_runtime "$name"
        case "$SNAP_STATUS" in
            OPERATIONAL|READY) ;;
            *)
                printf '  %-20s %-13s %s\n' "$(fit_text "$name" 20)" "$SNAP_STATUS" "$SNAP_TRANSPORT" >"$TTY_OUT"
                issues=$((issues + 1))
                ;;
        esac
    done < <(profile_names)
    ((issues == 0)) && print_check pass 'Connection health' 'No failed, degraded, disconnected or stopped profiles.'
}


hub_diagnostics_menu() {
    local choice selected
    while hub_configured; do
        clear_screen; banner
        section_title 'Egress hub diagnostics'
        printf '  Choose a focused test. Raw strongSwan output is available only inside one connection.\n' >"$TTY_OUT"
        cat >"$TTY_OUT" <<EOF_HUB_DIAG

  ${C_CYAN}1)${C_RESET} Hub runtime and managed integration
  ${C_GREEN}2)${C_RESET} Run hub Internet, DNS and active peer ping tests
  ${C_CYAN}3)${C_RESET} Diagnose one egress connection
  ${C_CYAN}4)${C_RESET} UDP listener inventory
  ${C_CYAN}5)${C_RESET} Per-connection forwarding and NAT inventory
  ${C_YELLOW}6)${C_RESET} Recent hub warnings and errors
  ${C_RED}0)${C_RESET} Back
EOF_HUB_DIAG
        choice=$(prompt 'Select a diagnostic view: ')
        case "$choice" in
            1) clear_screen; banner; hub_runtime_overview; pause_screen ;;
            2) hub_connectivity_tests || true; pause_screen ;;
            3) selected=$(select_client_interactive) && client_diagnostics_menu "$selected" ;;
            4) hub_listener_inventory; pause_screen ;;
            5) hub_firewall_inventory; pause_screen ;;
            6) hub_recent_errors; pause_screen ;;
            0) return 0 ;;
            *) warn 'Invalid selection.'; sleep 1 ;;
        esac
    done
}


manage_client_menu() {
    local name="$1" choice
    while profile_exists "$name"; do
        clear_screen; banner
        show_client_header "$name"
        cat >"$TTY_OUT" <<EOF_CONNECTION_MENU

${C_BOLD}${C_MAGENTA}MANAGE EGRESS CONNECTION${C_RESET}
  ${C_CYAN}1)${C_RESET} Status overview
  ${C_CYAN}2)${C_RESET} Diagnostics
  ${C_GREEN}3)${C_RESET} Run peer ping and NAT/DNS readiness tests
  ${C_CYAN}4)${C_RESET} Show ingress pairing token
  ${C_GREEN}5)${C_RESET} Start / listen
  ${C_YELLOW}6)${C_RESET} Stop temporarily
  ${C_CYAN}7)${C_RESET} Restart
  ${C_CYAN}8)${C_RESET} Repair configuration
  ${C_RED}9)${C_RESET} Remove this connection
  ${C_RED}0)${C_RESET} Back
EOF_CONNECTION_MENU
        choice=$(prompt 'Select an option: ')
        case "$choice" in
            1) show_client_status "$name" no; pause_screen ;;
            2) client_diagnostics_menu "$name" ;;
            3) client_diag_network "$name"; pause_screen; client_diag_dns_nat "$name"; pause_screen ;;
            4) show_client_token "$name"; pause_screen ;;
            5) start_hub_client "$name"; pause_screen ;;
            6) stop_hub_client "$name" no; pause_screen ;;
            7) systemctl restart "$(profile_service "$name")"; apply_client_network_rules "$name"; success "Egress connection '${name}' restarted."; pause_screen ;;
            8) repair_hub_client "$name"; pause_screen ;;
            9) remove_hub_client "$name" no; pause_screen; return ;;
            0) return ;;
            *) warn 'Invalid selection.'; sleep 1 ;;
        esac
    done
}


hub_interactive_menu() {
    local choice selected
    while hub_configured; do
        clear_screen; banner
        hub_main_dashboard
        cat >"$TTY_OUT" <<EOF_HUB_MENU

${C_BOLD}${C_MAGENTA}EGRESS CONNECTIONS${C_RESET}
  ${C_GREEN}1)${C_RESET} Add egress connection and generate ingress token
  ${C_CYAN}2)${C_RESET} All connections - detailed inventory
  ${C_CYAN}3)${C_RESET} Manage a connection

${C_BOLD}${C_MAGENTA}OPERATE EGRESS HUB${C_RESET}
  ${C_CYAN}4)${C_RESET} Hub status summary
  ${C_CYAN}5)${C_RESET} Diagnostics
  ${C_GREEN}6)${C_RESET} Run hub Internet, DNS and peer tests
  ${C_GREEN}7)${C_RESET} Start all connections
  ${C_YELLOW}8)${C_RESET} Stop all connections temporarily
  ${C_CYAN}9)${C_RESET} Repair all configurations

${C_BOLD}${C_MAGENTA}REMOVE${C_RESET}
  ${C_YELLOW}10)${C_RESET} Remove hub and restore previous state
  ${C_RED}11)${C_RESET} Completely uninstall Dragon Fruit Relay
  ${C_RED}0)${C_RESET} Exit
EOF_HUB_MENU
        choice=$(prompt 'Select an option: ')
        case "$choice" in
            1) add_client_interactive; pause_screen ;;
            2) clear_screen; banner; list_hub_clients no; pause_screen ;;
            3) selected=$(select_client_interactive) && manage_client_menu "$selected" ;;
            4) hub_health_overview; pause_screen ;;
            5) hub_diagnostics_menu ;;
            6) hub_connectivity_tests || true; pause_screen ;;
            7) start_all_clients || true; pause_screen ;;
            8) stop_all_clients; pause_screen ;;
            9) repair_all_clients; pause_screen ;;
            10) remove_egress_hub no no; pause_screen; return ;;
            11) remove_egress_hub yes no; return ;;
            0) exit 0 ;;
            *) warn 'Invalid selection.'; sleep 1 ;;
        esac
    done
}


client_cli() {
    local action="${1:-help}"; shift || true
    local name='' port='interactive' tunnel='auto' json=no arg view
    case "$action" in
        add)
            while (($#)); do
                arg="$1"; shift
                case "$arg" in
                    --name) name="${1:-}"; shift || true ;;
                    --port) port="${1:-}"; shift || true ;;
                    --tunnel) tunnel="${1:-}"; shift || true ;;
                    --auto) port=auto ;;
                    *) die "Unknown connection add option: ${arg}" ;;
                esac
            done
            hub_configured || die 'Configure this server as an egress hub first.'
            [[ -n "$name" ]] || name=$(prompt_profile_name)
            name=$(normalize_profile_name "$name")
            create_hub_client "$name" "$port" "$tunnel"
            ;;
        list)
            hub_configured || die 'This server is not configured as an egress hub.'
            [[ "${1:-}" == --json ]] && json=yes
            list_hub_clients "$json"
            ;;
        status)
            hub_configured || die 'This server is not configured as an egress hub.'
            name="${1:-}"; [[ -n "$name" ]] || die 'Connection name is required.'
            [[ "${2:-}" == --json ]] && json=yes
            show_client_status "$name" "$json"
            ;;
        diagnostics|diag)
            hub_configured || die 'This server is not configured as an egress hub.'
            name="${1:-}"; [[ -n "$name" ]] || die 'Connection name is required.'
            view="${2:-menu}"
            case "$view" in
                menu) client_diagnostics_menu "$name" ;;
                ike) client_diag_ike "$name" ;;
                network|ping|connectivity) client_diag_network "$name" ;;
                dns|nat|dns-nat) client_diag_dns_nat "$name" ;;
                service) client_diag_service "$name" ;;
                firewall) client_diag_firewall "$name" ;;
                logs) client_diag_logs "$name" ;;
                raw) client_diag_raw "$name" ;;
                live-dns|dns-live) client_diag_live_dns "$name" ;;
                live-traffic|traffic-live|capture) client_diag_live_traffic "$name" ;;
                *) die "Unknown connection diagnostic view: ${view}" ;;
            esac
            ;;
        test)
            hub_configured || die 'This server is not configured as an egress hub.'
            name="${1:-}"; [[ -n "$name" ]] || die 'Connection name is required.'
            client_diag_network "$name"
            client_diag_dns_nat "$name"
            ;;
        start) name="${1:-}"; [[ -n "$name" ]] || die 'Connection name is required.'; start_hub_client "$name" ;;
        stop) name="${1:-}"; [[ -n "$name" ]] || die 'Connection name is required.'; stop_hub_client "$name" no ;;
        restart) name="${1:-}"; [[ -n "$name" ]] || die 'Connection name is required.'; systemctl restart "$(profile_service "$name")"; apply_client_network_rules "$name" ;;
        repair) name="${1:-}"; [[ -n "$name" ]] || die 'Connection name is required.'; repair_hub_client "$name" ;;
        token) name="${1:-}"; [[ -n "$name" ]] || die 'Connection name is required.'; show_client_token "$name" ;;
        remove) name="${1:-}"; [[ -n "$name" ]] || die 'Connection name is required.'; remove_hub_client "$name" no ;;
        help|-h|--help)
            cat <<'EOF_CONNECTION_HELP'
Usage: dragon-fruit-relay connection <action> [options]
       dragon-fruit-relay client <action> [options]   # backward-compatible alias

Actions:
  add [--name NAME] [--port auto|standard|PORT] [--tunnel CIDR]
  list [--json]
  status NAME [--json]
  diagnostics NAME [ike|network|dns-nat|service|firewall|logs|raw|live-dns|live-traffic]
  test NAME
  start NAME
  stop NAME
  restart NAME
  repair NAME
  token NAME
  remove NAME
EOF_CONNECTION_HELP
            ;;
        *) die "Unknown connection action: ${action}" ;;
    esac
}


detect_public_ipv4() {
    local bind="${1:-}" url candidate best='' best_count=0 count
    local -a curl_args=(-4 -f -sS --noproxy '*' --connect-timeout 3 --max-time "$PUBLIC_IP_LOOKUP_TIMEOUT_SECONDS")
    [[ -n "$bind" ]] && curl_args+=(--interface "$bind")

    declare -A observations=()
    for url in \
        'https://api.ipify.org' \
        'https://checkip.amazonaws.com' \
        'https://ipv4.icanhazip.com' \
        'https://ifconfig.me/ip'; do
        candidate=$(env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
            -u ALL_PROXY -u all_proxy -u NO_PROXY -u no_proxy \
            curl "${curl_args[@]}" "$url" 2>/dev/null | tr -d '[:space:]' || true)
        validate_ipv4 "$candidate" || continue
        observations["$candidate"]=$(( ${observations["$candidate"]:-0} + 1 ))
    done

    for candidate in "${!observations[@]}"; do
        count=${observations["$candidate"]}
        if ((count > best_count)); then
            best="$candidate"
            best_count=$count
        fi
    done

    # Never publish an arbitrary single HTTP observation as authoritative.
    # Two independent services must agree on the address seen on the bound path.
    if [[ -n "$best" && "$best_count" -ge 2 ]]; then
        printf '%s' "$best"
        return 0
    fi
    return 1
}

install_ingress_canonical_link() {
    local source="$1" link="$2"
    [[ -f "$source" ]] || die "Cannot install missing managed source: ${source}"
    install -d -m 0755 "$(dirname "$link")"

    if [[ -e "$link" || -L "$link" ]]; then
        if [[ -L "$link" && "$(readlink -f -- "$link" 2>/dev/null || true)" == "$(readlink -f -- "$source")" ]]; then
            return 0
        fi
        if [[ -f "$link" ]] && grep -q '^# Managed by Dragon Fruit Relay\.' "$link" 2>/dev/null; then
            rm -f -- "$link"
        elif dragonfruit_owned_symlink "$link"; then
            rm -f -- "$link"
        else
            die "Refusing to replace unmanaged integration path: ${link}"
        fi
    fi
    ln -s "$source" "$link"
}

enable_managed_unit_link() {
    local unit="$1" target="$2" source="${UNIT_DIR}/${unit}"
    [[ -f "$source" ]] || return 1
    install -d -m 0755 "${SYSTEMD_DIR}/${target}.wants"
    ln -sfn "$source" "${SYSTEMD_DIR}/${target}.wants/${unit}"
}

delete_link_bounded() {
    local ifname="${1:-}" pid elapsed=0
    [[ -n "$ifname" ]] || return 0
    ip link show dev "$ifname" >/dev/null 2>&1 || return 0
    ip link set "$ifname" down >/dev/null 2>&1 || true

    ip link delete "$ifname" >/dev/null 2>&1 &
    pid=$!
    while ((elapsed < 5)); do
        if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid" 2>/dev/null || true
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    kill -TERM "$pid" 2>/dev/null || true
    sleep 1
    kill -KILL "$pid" 2>/dev/null || true
    disown "$pid" 2>/dev/null || true
    warn "The kernel did not complete deletion of interface $ifname within 5 seconds. A reboot may be required to clear the stale netlink operation."
    return 1
}

xfrm_runtime_ready() {
    local details expected_hex
    ip link show dev "$XFRM_IF" >/dev/null 2>&1 || return 1
    details=$(ip -d link show dev "$XFRM_IF" 2>/dev/null || true)
    grep -q 'xfrm' <<<"$details" || return 1
    expected_hex=$(printf '0x%x' "$XFRM_ID")
    grep -Eq "if_id (${XFRM_ID}|${expected_hex})([[:space:]]|$)" <<<"$details" || return 1
    ip -4 address show dev "$XFRM_IF" 2>/dev/null | grep -Fq "${XFRM_LOCAL_CIDR%/*}/" || return 1
}

start_xfrm_checked() {
    local unit='dragonfruit-relay-xfrm.service' state job elapsed=0
    info 'Starting XFRM interface service...'
    enable_managed_unit_link "$unit" multi-user.target || true
    timeout 8s systemctl enable "$unit" >>"$LOG_FILE" 2>&1 || true

    state=$(systemctl is-active "$unit" 2>/dev/null || true)
    job=$(systemctl show "$unit" -p Job --value 2>/dev/null || true)
    if [[ "$state" == deactivating || "$state" == activating ]]; then
        [[ "$job" =~ ^[0-9]+$ && "$job" != 0 ]] && timeout 4s systemctl cancel "$job" >>"$LOG_FILE" 2>&1 || true
    fi
    timeout 5s systemctl reset-failed "$unit" >>"$LOG_FILE" 2>&1 || true

    # Apply the idempotent helper directly first. It never deletes an existing
    # matching XFRM device, so a repair does not require a stop/restart cycle.
    if ! timeout 12s "$LIB_DIR/xfrm-up" >>"$LOG_FILE" 2>&1; then
        error 'The managed XFRM interface could not be created or refreshed.'
        return 1
    fi

    timeout 8s systemctl start --no-block "$unit" >>"$LOG_FILE" 2>&1 || true
    while ((elapsed < 12)); do
        state=$(systemctl is-active "$unit" 2>/dev/null || true)
        if [[ "$state" == active ]] && xfrm_runtime_ready; then
            success 'XFRM interface service is active.'
            return 0
        fi
        if xfrm_runtime_ready && [[ "$state" != deactivating ]]; then
            warn "XFRM interface $XFRM_IF is ready, but systemd reports '$state'. Continuing with the working data path."
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    if xfrm_runtime_ready; then
        warn "XFRM interface $XFRM_IF is ready, but the old systemd job is still clearing. Continuing without restarting the unit."
        return 0
    fi
    error 'The XFRM interface did not become ready within the allowed time.'
    systemctl status "$unit" --no-pager -l 2>&1 | tail -n 60 >"$TTY_OUT" || true
    return 1
}

start_unit_checked() {
    local unit="$1" description="$2" elapsed=0 state job
    info "Starting ${description}..."

    if [[ -f "${UNIT_DIR}/${unit}" ]]; then
        if [[ "$unit" == *.timer ]]; then
            enable_managed_unit_link "$unit" timers.target || true
        elif grep -q '^WantedBy=multi-user.target$' "${UNIT_DIR}/${unit}" 2>/dev/null; then
            enable_managed_unit_link "$unit" multi-user.target || true
        fi
    fi

    timeout 10s systemctl enable "$unit" >>"$LOG_FILE" 2>&1 || true
    timeout 10s systemctl reset-failed "$unit" >>"$LOG_FILE" 2>&1 || true
    if ! timeout 10s systemctl restart --no-block "$unit" >>"$LOG_FILE" 2>&1; then
        error "${description} could not be queued for startup: ${unit}"
        return 1
    fi

    while ((elapsed < SYSTEMD_OPERATION_TIMEOUT_SECONDS)); do
        state=$(systemctl is-active "$unit" 2>/dev/null || true)
        job=$(systemctl show "$unit" -p Job --value 2>/dev/null || true)
        if [[ "$state" == active && ( -z "$job" || "$job" == 0 ) ]]; then
            success "${description} is active."
            return 0
        fi
        if [[ "$state" == failed ]]; then
            break
        fi
        if [[ ( -z "$job" || "$job" == 0 ) && "$state" != activating && "$state" != deactivating ]]; then
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    error "${description} did not become active within ${SYSTEMD_OPERATION_TIMEOUT_SECONDS}s: ${unit}"
    timeout 5s systemctl stop --no-block "$unit" >/dev/null 2>&1 || true
    systemctl status "$unit" --no-pager -l 2>&1 | tail -n 60 >"$TTY_OUT" || true
    journalctl -u "$unit" -n 60 --no-pager -l 2>&1 >"$TTY_OUT" || true
    return 1
}

load_strongswan_checked() {
    local load_output load_status list_output list_status retry_output retry_status
    if [[ ! -s "$INGRESS_SWANCTL_SOURCE" ]]; then
        error "Managed strongSwan source is missing or empty: $INGRESS_SWANCTL_SOURCE"
        return 1
    fi
    if [[ ! -s "$INGRESS_SWANCTL_CANONICAL" || ! -r "$INGRESS_SWANCTL_CANONICAL" ]]; then
        error "Canonical strongSwan configuration is missing or unreadable: $INGRESS_SWANCTL_CANONICAL"
        return 1
    fi
    if ! cmp -s -- "$INGRESS_SWANCTL_SOURCE" "$INGRESS_SWANCTL_CANONICAL"; then
        error "Canonical strongSwan configuration differs from the managed source: $INGRESS_SWANCTL_CANONICAL"
        return 1
    fi

    set +e
    load_output=$(timeout "${SWANCTL_OPERATION_TIMEOUT_SECONDS}s" swanctl --load-all --noprompt --file "$INGRESS_SWANCTL_CANONICAL" 2>&1)
    load_status=$?
    set -e
    printf '%s\n' "$load_output" >>"$LOG_FILE"

    set +e
    list_output=$(timeout "${SWANCTL_OPERATION_TIMEOUT_SECONDS}s" swanctl --list-conns 2>&1)
    list_status=$?
    set -e
    printf '%s\n' "$list_output" >>"$LOG_FILE"

    if ((load_status != 0 || list_status != 0)) || \
       ! grep -Eq '^[[:space:]]*dragonfruit_relay:' <<<"$list_output"; then
        set +e
        retry_output=$(timeout "${SWANCTL_OPERATION_TIMEOUT_SECONDS}s" swanctl --load-conns --file "$INGRESS_SWANCTL_CANONICAL" 2>&1)
        retry_status=$?
        list_output=$(timeout "${SWANCTL_OPERATION_TIMEOUT_SECONDS}s" swanctl --list-conns 2>&1)
        list_status=$?
        set -e
        printf '%s\n%s\n' "$retry_output" "$list_output" >>"$LOG_FILE"
        if ((retry_status != 0 || list_status != 0)) || \
           ! grep -Eq '^[[:space:]]*dragonfruit_relay:' <<<"$list_output"; then
            error 'The Dragon Fruit Relay connection was not loaded within the allowed time.'
            printf '%s\n' '--- swanctl --load-all ---' >"$TTY_OUT"
            printf '%s\n' "${load_output:-no output}" >"$TTY_OUT"
            printf '%s\n' '--- swanctl --load-conns ---' >"$TTY_OUT"
            printf '%s\n' "${retry_output:-no output}" >"$TTY_OUT"
            printf '%s\n' '--- swanctl --list-conns ---' >"$TTY_OUT"
            printf '%s\n' "${list_output:-no output}" >"$TTY_OUT"
            return 1
        fi
    fi
    success 'Dragon Fruit Relay strongSwan connection is loaded.'
}

remove_systemd_resolved() {
    record_resolved_state
    record_initial_package_state systemd-resolved
    record_initial_package_state libnss-resolve

    backup_original /etc/resolv.conf
    backup_original /etc/nsswitch.conf
    backup_original /etc/systemd/resolved.conf
    backup_original /etc/systemd/resolved.conf.d
    backup_original /etc/systemd/system/systemd-resolved.service.d

    # Stopping the resolver is sufficient. Purging packages on every peer
    # replacement was slow and made rollback/reconfiguration unnecessarily
    # fragile. Package state remains recorded and is restored on removal.
    timeout 15s systemctl disable --now systemd-resolved.service >/dev/null 2>&1 || true
}

write_strongswan_common_files() {
    ensure_managed_layout
    install -d -m 0700 "$INGRESS_CONFIG_DIR"
    install -d -m 0755 /etc/strongswan.d "$STRONGSWAN_OVERRIDE_DIR"

    local custom_port_lines=''
    if [[ "$ROLE" == egress && "$PORT_MODE" == custom ]]; then
        custom_port_lines=$(printf '    port_nat_t = %s\n' "$NATT_PORT")
    fi

    cat >"$INGRESS_STRONGSWAN_SOURCE" <<EOF_STRONGSWAN_204
# Managed by Dragon Fruit Relay.
charon {
    install_routes = no
${custom_port_lines}
    plugins {
        kernel-libipsec { load = no }
        kernel-netlink {
            load = yes
            install_routes_xfrmi = no
        }
    }
}
EOF_STRONGSWAN_204
    chmod 0644 "$INGRESS_STRONGSWAN_SOURCE"

    cat >"$INGRESS_OVERRIDE_SOURCE" <<'EOF_OVERRIDE_204'
# Managed by Dragon Fruit Relay.
[Unit]
Requires=dragonfruit-relay-xfrm.service
After=dragonfruit-relay-xfrm.service
EOF_OVERRIDE_204
    chmod 0644 "$INGRESS_OVERRIDE_SOURCE"

    install_ingress_canonical_link "$INGRESS_STRONGSWAN_SOURCE" "$STRONGSWAN_ROUTE_FILE"
    install_ingress_canonical_link "$INGRESS_OVERRIDE_SOURCE" "$STRONGSWAN_OVERRIDE_FILE"

    systemctl disable --now dragonfruit-relay-firewall.service >/dev/null 2>&1 || true
    rm -f "$SYSTEMD_DIR/dragonfruit-relay-firewall.service" \
          "$UNIT_DIR/dragonfruit-relay-firewall.service" \
          "$LIB_DIR/firewall-apply" "$LIB_DIR/firewall-remove"
}

prepare_ingress_swanctl_layout() {
    local path target credential_dir unknown=''

    install -d -m 0755 /etc/swanctl

    # Older or failed releases may have left either namespace component as a
    # symlink into the managed application tree.  Such a parent symlink can
    # make the canonical file alias its own source or become dangling after an
    # uninstall.  Convert only Dragon Fruit Relay-owned symlinks to real dirs.
    for path in "$SWANCTL_CLIENT_ROOT" "$INGRESS_SWANCTL_DIR"; do
        if [[ -L "$path" ]]; then
            target=$(readlink -f -- "$path" 2>/dev/null || readlink -- "$path" 2>/dev/null || true)
            case "$target" in
                "$CONFIG_DIR"|"$CONFIG_DIR"/*|"$LEGACY_LIB_DIR"|"$LEGACY_LIB_DIR"/*)
                    rm -f -- "$path"
                    ;;
                *)
                    die "Refusing to replace unmanaged swanctl namespace symlink: ${path} -> ${target:-unknown}"
                    ;;
            esac
        elif [[ -e "$path" && ! -d "$path" ]]; then
            die "Required swanctl namespace path is not a directory: ${path}"
        fi
    done

    install -d -m 0755 "$SWANCTL_CLIENT_ROOT"

    # Adopt or clear only recognisable remnants from a previous ingress
    # attempt.  Unknown files are preserved and cause a safe failure.
    if [[ -d "$INGRESS_SWANCTL_DIR" && ! -e "$INGRESS_SWANCTL_MARKER" ]]; then
        while IFS= read -r path; do
            case "$(basename "$path")" in
                swanctl.conf)
                    if [[ -L "$path" ]]; then
                        target=$(readlink -f -- "$path" 2>/dev/null || true)
                        [[ "$target" == "$CONFIG_DIR"/* || "$target" == "$LEGACY_LIB_DIR"/* ]] || unknown="$path"
                    elif [[ -f "$path" ]] && grep -q '^# Managed by Dragon Fruit Relay\.' "$path" 2>/dev/null; then
                        :
                    else
                        unknown="$path"
                    fi
                    ;;
                x509|x509ca|x509ocsp|x509aa|x509ac|x509crl|pubkey|private|rsa|ecdsa|pkcs8|pkcs12)
                    if [[ -d "$path" ]] && ! find "$path" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
                        :
                    else
                        unknown="$path"
                    fi
                    ;;
                *) unknown="$path" ;;
            esac
            [[ -z "$unknown" ]] || break
        done < <(find "$INGRESS_SWANCTL_DIR" -mindepth 1 -maxdepth 1 -print 2>/dev/null)

        [[ -z "$unknown" ]] || die "Refusing to remove unmanaged swanctl ingress content: ${unknown}"
        rm -rf -- "$INGRESS_SWANCTL_DIR"
    fi

    install -d -m 0750 "$INGRESS_SWANCTL_DIR"
    : >"$INGRESS_SWANCTL_MARKER"
    chmod 0640 "$INGRESS_SWANCTL_MARKER"

    # --file changes swanctl's credential-directory context to this directory.
    # Create the complete expected layout so load-all is deterministic and
    # does not depend on stale directories from an earlier installation.
    for credential_dir in x509 x509ca x509ocsp x509aa x509ac x509crl pubkey private rsa ecdsa pkcs8 pkcs12; do
        path="$INGRESS_SWANCTL_DIR/$credential_dir"
        if [[ -L "$path" ]]; then
            target=$(readlink -f -- "$path" 2>/dev/null || true)
            case "$target" in
                "$CONFIG_DIR"/*|"$LEGACY_LIB_DIR"/*) rm -f -- "$path" ;;
                *) die "Refusing to replace unmanaged swanctl credential link: ${path}" ;;
            esac
        elif [[ -e "$path" && ! -d "$path" ]]; then
            die "Required swanctl credential path is not a directory: ${path}"
        fi
        install -d -m 0700 "$path"
    done
}

install_ingress_canonical_copy() {
    local source="$1" destination="$2" temporary
    [[ -f "$source" ]] || die "Cannot install missing managed source: ${source}"
    temporary="${destination}.tmp.$$"
    install -m 0600 "$source" "$temporary"
    mv -f -- "$temporary" "$destination"
}

write_swanctl_ingress() {
    ensure_managed_layout
    install -d -m 0700 "$INGRESS_CONFIG_DIR"
    prepare_ingress_swanctl_layout

    local remote_port_line=''
    if [[ "$PORT_MODE" == custom ]]; then
        remote_port_line=$(printf '        local_port = %s\n        remote_port = %s' "$DEFAULT_NATT_PORT" "$NATT_PORT")
    fi

    cat >"$INGRESS_SWANCTL_SOURCE" <<EOF_SWANCTL_204
# Managed by Dragon Fruit Relay.
# Role: ingress / initiator
connections {
    dragonfruit_relay {
        version = 2
        local_addrs = %any
        remote_addrs = ${PEER_PUBLIC_IP}
${remote_port_line}
        encap = yes
        mobike = no
        fragmentation = yes
        dpd_delay = 20s
        reauth_time = 0s
        local {
            auth = psk
            id = ${INGRESS_ID}
        }
        remote {
            auth = psk
            id = ${EGRESS_ID}
        }
        children {
            tunnel {
                mode = tunnel
                local_ts = 0.0.0.0/0
                remote_ts = 0.0.0.0/0
                if_id_in = ${XFRM_ID}
                if_id_out = ${XFRM_ID}
                start_action = start
                close_action = start
                dpd_action = restart
            }
        }
    }
}
secrets {
    ike-psk {
        id-1 = ${INGRESS_ID}
        id-2 = ${EGRESS_ID}
        secret = "${PSK}"
    }
}
EOF_SWANCTL_204
    chmod 0600 "$INGRESS_SWANCTL_SOURCE"
    install_ingress_canonical_copy "$INGRESS_SWANCTL_SOURCE" "$INGRESS_SWANCTL_CANONICAL"

    # 2.0.4 briefly used /etc/swanctl/swanctl.conf as a managed symlink.
    # Remove only that Dragon Fruit Relay-owned integration; never touch a
    # package- or administrator-owned top-level swanctl.conf.
    if dragonfruit_owned_symlink "$SWANCTL_FILE" ||
       { [[ -f "$SWANCTL_FILE" ]] && grep -q '^# Managed by Dragon Fruit Relay\.' "$SWANCTL_FILE" 2>/dev/null; }; then
        rm -f -- "$SWANCTL_FILE"
        if manifest_contains "$SWANCTL_FILE"; then
            local saved="${BACKUP_DIR}/files${SWANCTL_FILE}"
            local state
            state=$(awk -F '\t' -v target="$SWANCTL_FILE" '$2 == target {print $1; exit}' "$MANIFEST_FILE" 2>/dev/null || true)
            if [[ "$state" == present && -e "$saved" ]]; then
                install -d -m 0755 "$(dirname "$SWANCTL_FILE")"
                cp -a "$saved" "$SWANCTL_FILE"
            fi
        fi
    fi
}

write_ingress_dns_files() {
    local apply_now="${1:-yes}"
    ensure_managed_layout

    cat >"$LIB_DIR/dns-apply" <<'EOF_DNS_APPLY_204'
#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck disable=SC1091
source /etc/dragonfruit-relay/dragonfruit-relay.conf
# /etc/resolv.conf is a symlink into this tree. Keep both directories
# searchable by unprivileged package helpers without allowing directory lists.
install -d -m 0751 /etc/dragonfruit-relay
install -d -m 0751 /etc/dragonfruit-relay/resolver
tmp=$(mktemp /etc/dragonfruit-relay/resolver/.resolv.conf.XXXXXX)
trap 'rm -f "$tmp"' EXIT
{
    echo '# Managed by Dragon Fruit Relay.'
    echo '# Public resolvers use the encrypted egress; local DNS is timeout fallback.'
    echo 'options timeout:1 attempts:1'
    echo "nameserver $DNS_PRIMARY"
    echo "nameserver $DNS_SECONDARY"
    [[ -n "${DNS_FALLBACK:-}" ]] && echo "nameserver $DNS_FALLBACK"
} >"$tmp"
install -m 0644 "$tmp" /etc/dragonfruit-relay/resolver/resolv.conf
rm -f /etc/resolv.conf
ln -s /etc/dragonfruit-relay/resolver/resolv.conf /etc/resolv.conf
[[ "$(readlink -f /etc/resolv.conf 2>/dev/null || true)" == /etc/dragonfruit-relay/resolver/resolv.conf ]]
EOF_DNS_APPLY_204
    chmod 0750 "$LIB_DIR/dns-apply"

    cat >"$UNIT_DIR/dragonfruit-relay-dns.service" <<EOF_DNS_UNIT_204
# Managed by Dragon Fruit Relay.
[Unit]
Description=Apply Dragon Fruit Relay static DNS configuration
Requires=dragonfruit-relay-routing.service
After=network-online.target dragonfruit-relay-routing.service

[Service]
Type=oneshot
ExecStart=${LIB_DIR}/dns-apply
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_DNS_UNIT_204
    chmod 0644 "$UNIT_DIR/dragonfruit-relay-dns.service"
    link_managed_unit dragonfruit-relay-dns.service

    if [[ -f /etc/nsswitch.conf ]]; then
        if grep -q '^hosts:' /etc/nsswitch.conf; then
            sed -i 's/^hosts:.*/hosts: files dns/' /etc/nsswitch.conf
        else
            printf '\nhosts: files dns\n' >>/etc/nsswitch.conf
        fi
    fi

    [[ "$apply_now" == yes ]] && "$LIB_DIR/dns-apply"
}

write_ingress_healthcheck_files() {
    ensure_managed_layout
    cat >"$LIB_DIR/healthcheck" <<'EOF_HEALTHCHECK_204'
#!/usr/bin/env bash
set -u
# shellcheck disable=SC1091
source /etc/dragonfruit-relay/dragonfruit-relay.conf
ike_ready() {
    local sas
    sas=$(timeout 10s swanctl --list-sas 2>/dev/null || true)
    grep -q ESTABLISHED <<<"$sas" && grep -q INSTALLED <<<"$sas"
}
healthy() {
    ip link show dev "$XFRM_IF" >/dev/null 2>&1 &&
    ike_ready &&
    ping -I "$XFRM_IF" -c 1 -W 3 "$XFRM_PEER_IP" >/dev/null 2>&1
}
resolver_runtime_ok() {
    [[ -r /etc/resolv.conf ]] || return 1
    [[ "$(readlink -f /etc/resolv.conf 2>/dev/null || true)" == /etc/dragonfruit-relay/resolver/resolv.conf ]] || return 1
    [[ "$(stat -c '%a' /etc/dragonfruit-relay 2>/dev/null || true)" == 751 ]] || return 1
    [[ "$(stat -c '%a' /etc/dragonfruit-relay/resolver 2>/dev/null || true)" == 751 ]] || return 1
    [[ "$(stat -c '%a' /etc/dragonfruit-relay/resolver/resolv.conf 2>/dev/null || true)" == 644 ]] || return 1
    awk -v primary="$DNS_PRIMARY" -v secondary="$DNS_SECONDARY" '
        $1 == "nameserver" && $2 == primary { primary_found = 1 }
        $1 == "nameserver" && $2 == secondary { secondary_found = 1 }
        END { exit(primary_found && secondary_found ? 0 : 1) }
    ' /etc/resolv.conf
}
activate_data_path() {
    timeout 15s systemctl start dragonfruit-relay-routing.service >/dev/null 2>&1 || return 1
    if resolver_runtime_ok; then
        timeout 15s systemctl start dragonfruit-relay-dns.service >/dev/null 2>&1 || return 1
    else
        logger -t dragonfruit-relay-healthcheck '/etc/resolv.conf was replaced; restarting the managed DNS service'
        timeout 15s systemctl restart dragonfruit-relay-dns.service >/dev/null 2>&1 || return 1
    fi
}
if healthy; then
    activate_data_path || true
    exit 0
fi
logger -t dragonfruit-relay-healthcheck 'Tunnel unhealthy; initiating CHILD SA'
timeout 12s swanctl --load-all --noprompt --file /etc/swanctl/dragonfruit-relay/ingress/swanctl.conf >/dev/null 2>&1 || true
timeout 15s swanctl --initiate --child tunnel >/dev/null 2>&1 || true
sleep 2
if healthy; then
    activate_data_path || true
    exit 0
fi
logger -t dragonfruit-relay-healthcheck 'Tunnel still unhealthy; restarting strongSwan'
timeout 20s systemctl restart strongswan.service >/dev/null 2>&1 || true
sleep 2
timeout 12s swanctl --load-all --noprompt --file /etc/swanctl/dragonfruit-relay/ingress/swanctl.conf >/dev/null 2>&1 || true
timeout 15s swanctl --initiate --child tunnel >/dev/null 2>&1 || true
sleep 2
healthy && { activate_data_path || true; exit 0; }
exit 1
EOF_HEALTHCHECK_204
    chmod 0750 "$LIB_DIR/healthcheck"

    cat >"$UNIT_DIR/dragonfruit-relay-healthcheck.service" <<EOF_HEALTH_UNIT_204
# Managed by Dragon Fruit Relay.
[Unit]
Description=Check and recover the Dragon Fruit Relay ingress tunnel
Requires=dragonfruit-relay-xfrm.service
After=dragonfruit-relay-xfrm.service strongswan.service

[Service]
Type=oneshot
TimeoutStartSec=55
ExecStart=${LIB_DIR}/healthcheck
EOF_HEALTH_UNIT_204

    cat >"$UNIT_DIR/dragonfruit-relay-healthcheck.timer" <<'EOF_HEALTH_TIMER_204'
# Managed by Dragon Fruit Relay.
[Unit]
Description=Run Dragon Fruit Relay ingress health checks

[Timer]
OnBootSec=45s
OnUnitActiveSec=60s
AccuracySec=10s
Unit=dragonfruit-relay-healthcheck.service
Persistent=true

[Install]
WantedBy=timers.target
EOF_HEALTH_TIMER_204
    chmod 0644 "$UNIT_DIR/dragonfruit-relay-healthcheck.service" "$UNIT_DIR/dragonfruit-relay-healthcheck.timer"
    link_managed_unit dragonfruit-relay-healthcheck.service
    link_managed_unit dragonfruit-relay-healthcheck.timer
}

resolver_runtime_ok() {
    [[ -r /etc/resolv.conf ]] || return 1
    [[ "$(readlink -f /etc/resolv.conf 2>/dev/null || true)" == "$RESOLVER_MANAGED_FILE" ]] || return 1
    [[ "$(stat -c '%a' "$CONFIG_DIR" 2>/dev/null || true)" == 751 ]] || return 1
    [[ "$(stat -c '%a' "$RESOLVER_DIR" 2>/dev/null || true)" == 751 ]] || return 1
    [[ "$(stat -c '%a' "$RESOLVER_MANAGED_FILE" 2>/dev/null || true)" == 644 ]] || return 1
    grep -Eq "^[[:space:]]*nameserver[[:space:]]+${DNS_PRIMARY//./\\.}([[:space:]]|$)" /etc/resolv.conf || return 1
    grep -Eq "^[[:space:]]*nameserver[[:space:]]+${DNS_SECONDARY//./\\.}([[:space:]]|$)" /etc/resolv.conf || return 1
}

start_health_monitor_best_effort() {
    local unit='dragonfruit-relay-healthcheck.timer' elapsed=0 state
    info 'Starting Health monitor timer...'

    if ! enable_managed_unit_link "$unit" timers.target; then
        warn 'Could not create the health-monitor timer enablement link. The tunnel remains usable.'
        return 0
    fi
    timeout 10s systemctl daemon-reload >>"$LOG_FILE" 2>&1 || {
        warn 'systemd did not reload the health-monitor timer. The tunnel remains usable.'
        return 0
    }
    timeout 6s systemctl reset-failed "$unit" >>"$LOG_FILE" 2>&1 || true
    if ! timeout 8s systemctl start --no-block "$unit" >>"$LOG_FILE" 2>&1; then
        warn 'The health-monitor timer could not be queued. The tunnel remains usable.'
        return 0
    fi

    while ((elapsed < 10)); do
        state=$(systemctl is-active "$unit" 2>/dev/null || true)
        if [[ "$state" == active ]]; then
            success 'Health monitor timer is active.'
            return 0
        fi
        [[ "$state" == failed ]] && break
        sleep 1
        elapsed=$((elapsed + 1))
    done

    warn "Health monitor timer is ${state:-inactive}. The active tunnel is preserved; run Repair to retry monitor activation."
    return 0
}

ensure_ingress_runtime_files() {
    load_config
    [[ "$ROLE" == ingress ]] || return 0
    info 'Rebuilding managed ingress service and resolver definitions...'
    ensure_managed_layout
    write_managed_readme
    install_self_copy
    write_common_xfrm_files
    write_strongswan_common_files
    write_swanctl_ingress
    write_ingress_routing_files
    write_ingress_dns_files no
    write_ingress_healthcheck_files
    timeout 15s systemctl daemon-reload >>"$LOG_FILE" 2>&1 || {
        error 'systemd did not reload the managed ingress units within 15 seconds.'
        return 1
    }
}

finalize_ingress_after_tunnel() {
    # Policy routing is part of the required ingress data path.
    start_unit_checked dragonfruit-relay-routing.service 'Selective routing service' || return 1

    # Resolver and monitor integration must never destroy an already working
    # encrypted path. Failures here are maintenance warnings and can be retried.
    remove_systemd_resolved || true
    if ! configure_dhcpcd_resolver_hook; then
        warn 'Could not stop dhcpcd from managing /etc/resolv.conf. The tunnel remains active, but DHCP may replace the managed resolver.'
    fi
    if ! write_ingress_dns_files no; then
        warn 'Could not rebuild the static resolver definition. The tunnel remains active.'
    fi
    if ! write_ingress_healthcheck_files; then
        warn 'Could not rebuild the health-monitor definition. The tunnel remains active.'
    fi
    timeout 15s systemctl daemon-reload >>"$LOG_FILE" 2>&1 || \
        warn 'systemd did not reload the resolver and monitor units within 15 seconds.'

    if start_unit_checked dragonfruit-relay-dns.service 'Static resolver service'; then
        if ! resolver_runtime_ok; then
            warn 'The resolver unit ran, but /etc/resolv.conf is not using the managed resolver file.'
        fi
    else
        warn 'The encrypted tunnel remains active, but the static resolver service needs Repair.'
    fi

    start_health_monitor_best_effort || true
    return 0
}

start_tunnel() {
    load_config
    [[ "$ROLE" == ingress ]] || {
        error 'This start path is only for an ingress client.'
        return 1
    }

    section_title 'Starting ingress connection'
    print_check info 'Stage 1 of 5' 'Reconstruct managed files and units'
    ensure_ingress_runtime_files || return 1

    print_check info 'Stage 2 of 5' 'Start XFRM interface and strongSwan'
    start_xfrm_checked || return 1
    start_unit_checked strongswan.service 'strongSwan service' || return 1

    print_check info 'Stage 3 of 5' 'Load and negotiate IKE / CHILD SA'
    load_strongswan_checked || return 1
    attempt_tunnel_connection || return 1

    print_check info 'Stage 4 of 5' 'Verify encrypted peer reachability'
    if ! ping -I "$XFRM_IF" -c 1 -W 3 "$XFRM_PEER_IP" >/dev/null 2>&1; then
        error 'IKE is established, but the remote XFRM peer is unreachable.'
        return 1
    fi
    print_check pass 'Encrypted peer' "$XFRM_PEER_IP responds through $XFRM_IF"

    print_check info 'Stage 5 of 5' 'Activate routing, resolver and health monitor'
    finalize_ingress_after_tunnel || return 1
    success 'Ingress connection start sequence completed.'
}


stop_tunnel() {
    load_config
    confirm 'Temporarily stop the ingress connection now? It remains enabled for the next boot.' no || return 0
    timeout 12s systemctl stop dragonfruit-relay-healthcheck.timer dragonfruit-relay-healthcheck.service >/dev/null 2>&1 || true
    timeout 12s systemctl stop dragonfruit-relay-dns.service dragonfruit-relay-routing.service >/dev/null 2>&1 || true
    timeout 12s swanctl --terminate --ike dragonfruit_relay >/dev/null 2>&1 || true
    timeout 12s systemctl stop strongswan.service dragonfruit-relay-xfrm.service >/dev/null 2>&1 || true
    success 'The ingress connection is stopped for the current boot.'
}

run_recovery() {
    load_config
    [[ "$ROLE" == ingress ]] || { error 'Recovery is available on an ingress client only.'; return 1; }
    info 'Running bounded ingress recovery...'
    if start_tunnel; then
        success 'Recovery completed and the ingress connection is healthy.'
        return 0
    fi
    error 'Recovery finished, but the ingress connection still requires diagnostics.'
    return 1
}

generate_current_ingress_token() {
    load_config
    [[ "$ROLE" == ingress ]] || return 1
    local payload
    payload=$(cat <<EOF_CURRENT_TOKEN
TOKEN_VERSION=${PROFILE_TOKEN_VERSION}
PROFILE_NAME=${PROFILE_NAME:-paired-egress}
EXIT_PUBLIC_IP=${PEER_PUBLIC_IP}
PORT_MODE=${PORT_MODE}
IKE_PORT=${IKE_PORT}
NATT_PORT=${NATT_PORT}
PSK=${PSK}
TUNNEL_CIDR=${TUNNEL_CIDR}
XFRM_ID=${XFRM_ID}
INGRESS_XFRM_IF=${XFRM_IF}
EGRESS_XFRM_IF=xfrm-egress
XFRM_MTU=${XFRM_MTU}
INGRESS_XFRM_CIDR=${INGRESS_XFRM_CIDR}
EGRESS_XFRM_CIDR=${EGRESS_XFRM_CIDR}
INGRESS_XFRM_IP=${INGRESS_XFRM_IP}
EGRESS_XFRM_IP=${EGRESS_XFRM_IP}
INGRESS_ID=${INGRESS_ID}
EGRESS_ID=${EGRESS_ID}
DNS_PRIMARY=${DNS_PRIMARY}
DNS_SECONDARY=${DNS_SECONDARY}
EOF_CURRENT_TOKEN
)
    printf '%s' "$payload" | base64 -w0
}

replace_ingress_connection() {
    configured_ingress || die 'This server is not configured as an ingress client.'
    load_config
    local supplied_token="${1:-}" old_token old_fallback="$DNS_FALLBACK" new_name

    clear_screen
    banner
    section_title 'Replace ingress connection'
    print_check info 'Current profile' "${PROFILE_NAME:-paired-egress}"
    print_check info 'Current endpoint' "$PEER_PUBLIC_IP"
    printf '  The new token is validated before the current connection is removed.\n' >"$TTY_OUT"
    printf '  If the new setup fails, Dragon Fruit Relay attempts to restore this connection.\n' >"$TTY_OUT"

    if [[ -z "$supplied_token" ]]; then
        supplied_token=$(prompt '  Paste the new pairing token: ')
    fi
    [[ -n "$supplied_token" ]] || { warn 'Replacement cancelled: no token was supplied.'; return 1; }

    if ! ( parse_pairing_token "$supplied_token" ); then
        error 'The new pairing token is invalid. The current connection was not changed.'
        return 1
    fi
    parse_pairing_token "$supplied_token"
    new_name=${TOKEN_PROFILE_NAME:-paired-egress}
    print_check pass 'Validated new profile' "$new_name at $TOKEN_EXIT_PUBLIC_IP"
    confirm "Replace the current ingress connection with '${new_name}'?" no || return 0

    old_token=$(generate_current_ingress_token)
    remove_tunnel_configuration yes

    if ( setup_ingress "$supplied_token" "$old_fallback" ); then
        success "Ingress connection replaced with '${new_name}'."
        return 0
    fi

    error 'The new ingress connection failed. Attempting to restore the previous connection...'
    [[ -f "$CONFIG_FILE" || -d "$CONFIG_DIR" || -d "$STATE_DIR" ]] && clean_abandoned_install_before_setup || true
    if ( setup_ingress "$old_token" "$old_fallback" ); then
        warn 'The previous ingress connection was restored successfully.'
        return 1
    fi
    error 'Automatic restoration also failed. The host was returned as close as possible to its original state.'
    return 1
}

evaluate_live_status() {
    if hub_configured; then
        local total=0 healthy=0 ready=0 bad=0 name state
        while IFS= read -r name; do
            [[ -n "$name" ]] || continue
            total=$((total + 1)); state=$(client_status_word "$name")
            case "$state" in OPERATIONAL) healthy=$((healthy + 1));; READY) ready=$((ready + 1));; *) bad=$((bad + 1));; esac
        done < <(profile_names)
        if ((bad > 0)); then set_live_status DEGRADED "$C_YELLOW" "$bad of $total connection(s) are unhealthy."
        elif ((total == 0)); then set_live_status READY "$C_CYAN" 'Hub initialized; no connections exist.'
        elif ((healthy > 0)); then set_live_status OPERATIONAL "$C_GREEN" "$healthy connected, $ready waiting."
        else set_live_status READY "$C_CYAN" "$ready connection(s) waiting for ingress peers."
        fi
        return
    fi

    set_live_status 'NOT CONFIGURED' "$C_DIM" 'No relay configuration is installed.'
    [[ -f "$CONFIG_FILE" ]] || return 0
    load_config
    local sas degraded=0
    systemctl is-active --quiet dragonfruit-relay-xfrm.service || { set_live_status STOPPED "$C_YELLOW" 'XFRM service is not active.'; return; }
    systemctl is-active --quiet strongswan.service || { set_live_status STOPPED "$C_YELLOW" 'strongSwan is not active.'; return; }
    ip link show dev "$XFRM_IF" >/dev/null 2>&1 || { set_live_status FAILED "$C_RED" 'XFRM interface is missing.'; return; }
    sas=$(safe_sas)
    if ! grep -q ESTABLISHED <<<"$sas" || ! grep -q INSTALLED <<<"$sas"; then
        set_live_status DISCONNECTED "$C_RED" 'No live IKE/CHILD session exists.'; return
    fi
    ping -I "$XFRM_IF" -c 1 -W 1 "$XFRM_PEER_IP" >/dev/null 2>&1 || {
        set_live_status DISCONNECTED "$C_RED" 'Encrypted peer is not responding.'; return
    }

    systemctl is-active --quiet dragonfruit-relay-routing.service || degraded=$((degraded + 1))
    route_uses_interface 9.9.9.9 "$XFRM_LOCAL_IP" "$XFRM_IF" || degraded=$((degraded + 1))
    resolver_runtime_ok || degraded=$((degraded + 1))

    if ((degraded > 0)); then
        set_live_status DEGRADED "$C_YELLOW" 'Encrypted tunnel is healthy; one or more managed data-path components need Repair.'
    elif ! systemctl is-active --quiet dragonfruit-relay-healthcheck.timer; then
        set_live_status DEGRADED "$C_YELLOW" 'Tunnel and DNS are healthy; automatic recovery monitor is inactive.'
    else
        set_live_status OPERATIONAL "$C_GREEN" "Peer $XFRM_PEER_IP, routing, resolver and monitor are healthy."
    fi
}

diagnostics_overview() {
    if [[ ! -f "$CONFIG_FILE" ]]; then diagnostics_preflight; return 0; fi
    clear_screen; banner; load_config
    section_title 'Health summary'
    config_summary
    evaluate_live_status
    section_title 'Live state'
    printf '  %s%s%s%s  %s\n' "$LIVE_COLOR" "$C_BOLD" "$LIVE_STATUS" "$C_RESET" "$LIVE_REASON" >"$TTY_OUT"

    local core_failures=0 data_failures=0 warnings=0 sas ike_ready=no
    section_title 'Core tunnel'
    check_service_for_dashboard dragonfruit-relay-xfrm.service 'XFRM interface service' || core_failures=$((core_failures + 1))
    check_service_for_dashboard strongswan.service 'strongSwan' || core_failures=$((core_failures + 1))
    sas=$(safe_sas)
    if grep -q ESTABLISHED <<<"$sas" && grep -q INSTALLED <<<"$sas"; then
        ike_ready=yes
        print_check pass 'IKE / CHILD SA' 'ESTABLISHED / INSTALLED'
        if ping -I "$XFRM_IF" -c 1 -W 2 "$XFRM_PEER_IP" >/dev/null 2>&1; then
            print_check pass 'Tunnel peer' "$XFRM_PEER_IP responds"
        else
            print_check fail 'Tunnel peer' 'unreachable'
            core_failures=$((core_failures + 1))
        fi
    else
        print_check fail 'IKE / CHILD SA' 'No encrypted session exists'
        core_failures=$((core_failures + 1))
    fi

    if [[ "$ROLE" == ingress ]]; then
        section_title 'Ingress data path'
        if [[ "$ike_ready" != yes ]]; then
            print_check info 'Policy routing' 'PENDING until the tunnel establishes'
            print_check info 'Managed resolver' 'PENDING; host resolver remains available'
            print_check info 'Health monitor' 'PENDING'
        else
            if systemctl is-active --quiet dragonfruit-relay-routing.service && \
               route_uses_interface 9.9.9.9 "$XFRM_LOCAL_IP" "$XFRM_IF"; then
                print_check pass 'Policy routing' "active through $XFRM_IF / table $ROUTE_TABLE"
            else
                print_check fail 'Policy routing' 'service or relay-source route is inactive'
                data_failures=$((data_failures + 1))
            fi

            if resolver_runtime_ok; then
                print_check pass 'Managed resolver runtime' "$DNS_PRIMARY -> $DNS_SECONDARY -> $DNS_FALLBACK"
            else
                print_check fail 'Managed resolver runtime' '/etc/resolv.conf is not using the generated resolver file'
                data_failures=$((data_failures + 1))
            fi

            if systemctl is-active --quiet dragonfruit-relay-dns.service; then
                print_check pass 'Resolver apply unit' 'active'
            else
                print_check warn 'Resolver apply unit' "$(unit_state dragonfruit-relay-dns.service); Repair reconstructs it"
                warnings=$((warnings + 1))
            fi

            if systemctl is-active --quiet dragonfruit-relay-healthcheck.timer; then
                print_check pass 'Health monitor' 'active and waiting'
            else
                print_check warn 'Health monitor' "$(unit_state dragonfruit-relay-healthcheck.timer); automatic recovery is not running"
                warnings=$((warnings + 1))
            fi

            print_route_check 'Primary DNS path' "$DNS_PRIMARY" '' "$XFRM_IF"
            print_route_check 'Secondary DNS path' "$DNS_SECONDARY" '' "$XFRM_IF"
        fi
    fi

    section_title 'Result'
    if ((core_failures > 0)); then
        printf '  %s%sDISCONNECTED / UNHEALTHY%s  %d tunnel failure(s).\n' "$C_BOLD" "$C_RED" "$C_RESET" "$core_failures" >"$TTY_OUT"
    elif ((data_failures > 0)); then
        printf '  %s%sDEGRADED%s  Tunnel is connected; %d managed data-path issue(s) require Repair.\n' "$C_BOLD" "$C_YELLOW" "$C_RESET" "$data_failures" >"$TTY_OUT"
    elif ((warnings > 0)); then
        printf '  %s%sHEALTHY WITH WARNINGS%s  Tunnel and traffic path are operational; %d maintenance warning(s).\n' "$C_BOLD" "$C_YELLOW" "$C_RESET" "$warnings" >"$TTY_OUT"
    else
        printf '  %s%sHEALTHY%s  Tunnel, routing, resolver and monitor are operational.\n' "$C_BOLD" "$C_GREEN" "$C_RESET" >"$TTY_OUT"
    fi
}

diagnostics_ports() {
    load_config
    clear_screen; banner
    section_title 'Services and network'
    service_row dragonfruit-relay-xfrm.service 'XFRM interface'
    service_row strongswan.service 'strongSwan'
    if [[ "$ROLE" == ingress ]]; then
        service_row dragonfruit-relay-routing.service 'Selective policy routing'
        service_row dragonfruit-relay-dns.service 'Resolver apply unit'
        service_row dragonfruit-relay-healthcheck.timer 'Health monitor'
        resolver_runtime_ok && print_check pass 'Resolver runtime' "$RESOLVER_MANAGED_FILE" || \
            print_check fail 'Resolver runtime' '/etc/resolv.conf is not linked to the managed resolver'
    fi

    section_title 'Transport and path'
    printf '  %-24s %s\n' 'Configured transport' "$(transport_description)" >"$TTY_OUT"
    if [[ "$ROLE" == ingress ]]; then
        if [[ "$PORT_MODE" == custom ]]; then
            printf '  %-24s %s:%s\n' 'Egress endpoint' "$PEER_PUBLIC_IP" "$NATT_PORT" >"$TTY_OUT"
        else
            printf '  %-24s %s:%s\n' 'Egress endpoint' "$PEER_PUBLIC_IP" "$IKE_PORT" >"$TTY_OUT"
        fi
        print_route_check 'Endpoint path' "$PEER_PUBLIC_IP" '' "$WAN_IF"
        local direct_ip='' tunnel_ip='' sas
        direct_ip=$(detect_public_ipv4 "$WAN_IF" || true)
        if [[ -n "$direct_ip" ]]; then
            printf '  %-24s %s\n' 'Direct-path public IP' "$direct_ip (multi-source consensus)" >"$TTY_OUT"
        else
            printf '  %-24s %s\n' 'Direct-path public IP' 'unavailable: route-bound lookup services did not agree' >"$TTY_OUT"
        fi
        sas=$(safe_sas)
        if grep -q ESTABLISHED <<<"$sas" && grep -q INSTALLED <<<"$sas"; then
            tunnel_ip=$(detect_public_ipv4 "$XFRM_LOCAL_IP" || true)
            if [[ -n "$tunnel_ip" ]]; then
                printf '  %-24s %s\n' 'Tunnel public IP' "$tunnel_ip (multi-source consensus)" >"$TTY_OUT"
            else
                printf '  %-24s %s\n' 'Tunnel public IP' 'unavailable: tunnel-bound lookup services did not agree' >"$TTY_OUT"
            fi
        else
            print_check info 'Tunnel public IP' 'skipped until IKE is established'
        fi
    fi
}

ingress_connectivity_tests() {
    load_config
    clear_screen; banner
    section_title 'Ingress end-to-end connectivity tests'

    local sas failures=0 warnings=0 answer tunnel_ip direct_ip
    sas=$(safe_sas)
    if ! systemctl is-active --quiet dragonfruit-relay-xfrm.service || \
       ! systemctl is-active --quiet strongswan.service || \
       ! grep -q ESTABLISHED <<<"$sas" || ! grep -q INSTALLED <<<"$sas"; then
        print_check fail 'Encrypted tunnel' 'IKE and CHILD SAs must be established before data-path tests can run.'
        return 1
    fi

    section_title 'Tunnel and Internet'
    if ping_from_source "$XFRM_IF" "$XFRM_PEER_IP"; then
        print_check pass 'Tunnel peer ping' "$XFRM_PEER_IP responds through $XFRM_IF"
    else
        print_check fail 'Tunnel peer ping' "$XFRM_PEER_IP is unreachable through $XFRM_IF"
        failures=$((failures + 1))
    fi
    if ping_from_source "$XFRM_LOCAL_IP" 1.1.1.1; then
        print_check pass 'Internet ping through relay' '1.1.1.1 responds using the tunnel source address'
    else
        print_check fail 'Internet ping through relay' 'No response from 1.1.1.1 using the tunnel source address'
        failures=$((failures + 1))
    fi

    direct_ip=$(detect_public_ipv4 "$WAN_IF" || true)
    [[ -n "$direct_ip" ]] && print_check info 'Direct-path public IPv4' "$direct_ip (multi-source consensus)" || \
        print_check info 'Direct-path public IPv4' 'not reported because independent route-bound services disagreed'

    tunnel_ip=$(detect_public_ipv4 "$XFRM_LOCAL_IP" || true)
    if [[ -n "$tunnel_ip" ]]; then
        if [[ "$tunnel_ip" == "$PEER_PUBLIC_IP" ]]; then
            print_check pass 'Relay public IPv4' "$tunnel_ip matches the configured egress endpoint"
        else
            print_check warn 'Relay public IPv4' "$tunnel_ip differs from configured endpoint $PEER_PUBLIC_IP"
            warnings=$((warnings + 1))
        fi
    else
        print_check warn 'Relay public IPv4' 'lookup services did not reach consensus; ping and DNS tests remain authoritative'
        warnings=$((warnings + 1))
    fi

    section_title 'DNS through tunnel and egress NAT'
    if answer=$(dns_query_from_source "$XFRM_LOCAL_IP" "$DNS_PRIMARY"); then
        print_check pass 'Primary DNS over relay/NAT' "$DNS_PRIMARY returned $answer"
    else
        print_check fail 'Primary DNS over relay/NAT' "$DNS_PRIMARY did not answer through the tunnel source"
        failures=$((failures + 1))
    fi
    if answer=$(dns_query_from_source "$XFRM_LOCAL_IP" "$DNS_SECONDARY"); then
        print_check pass 'Secondary DNS over relay/NAT' "$DNS_SECONDARY returned $answer"
    else
        print_check fail 'Secondary DNS over relay/NAT' "$DNS_SECONDARY did not answer through the tunnel source"
        failures=$((failures + 1))
    fi
    if [[ -n "${DNS_FALLBACK:-}" ]]; then
        if answer=$(dns_query_from_source "$LOCAL_IP" "$DNS_FALLBACK"); then
            print_check pass 'Local fallback DNS' "$DNS_FALLBACK returned $answer on the direct path"
        else
            print_check warn 'Local fallback DNS' "$DNS_FALLBACK did not answer on the direct path"
            warnings=$((warnings + 1))
        fi
    fi

    section_title 'Result'
    if ((failures == 0)); then
        if ((warnings > 0)); then
            printf '  %s%sPASS WITH WARNINGS%s  Required tunnel, Internet and DNS-over-NAT tests succeeded.\n' "$C_BOLD" "$C_YELLOW" "$C_RESET" >"$TTY_OUT"
        else
            printf '  %s%sPASS%s  Tunnel, Internet, public-IP and DNS-over-NAT tests succeeded.\n' "$C_BOLD" "$C_GREEN" "$C_RESET" >"$TTY_OUT"
        fi
        return 0
    fi
    printf '  %s%sFAIL%s  %d required end-to-end test(s) failed.\n' "$C_BOLD" "$C_RED" "$C_RESET" "$failures" >"$TTY_OUT"
    return 1
}

write_managed_readme() {
    cat >"$MANAGED_README" <<'EOF_README_204'
Dragon Fruit Relay managed directory
====================================

This directory is the authoritative source for the configured node.

Ingress source files:
  ingress/swanctl.conf
  ingress/strongswan.conf
  ingress/strongswan-systemd.conf

Canonical strongSwan integration links:
  /etc/swanctl/dragonfruit-relay/ingress/swanctl.conf
  /etc/strongswan.d/99-dragonfruit-relay.conf
  /etc/systemd/system/strongswan.service.d/dragonfruit-relay.conf

Runtime helpers and units:
  bin/
  systemd/
  resolver/

The ingress menu can start, stop, repair, replace, or remove the current peer.
Replacing a peer validates the new token before deleting the current connection
and attempts to restore the previous connection if the replacement fails.
EOF_README_204
    chmod 0640 "$MANAGED_README"
}

diagnostics_logs() {
    load_config
    clear_screen; banner
    section_title 'Recent strongSwan warnings and errors'
    journalctl -u strongswan.service --since '-30 minutes' --no-pager -o short-iso 2>/dev/null | \
        grep -Ei 'failed|error|AUTH|proposal|shared key|retransmit|unreachable|timeout' | tail -n 80 >"$TTY_OUT" || true
    section_title 'Recent managed-service warnings and errors'
    journalctl -u dragonfruit-relay-xfrm.service -u dragonfruit-relay-routing.service \
        -u dragonfruit-relay-dns.service -u dragonfruit-relay-healthcheck.service \
        --since '-30 minutes' -p warning --no-pager -o short-iso 2>/dev/null | tail -n 80 >"$TTY_OUT" || true
    section_title 'Current command invocation'
    awk '/\[SESSION\]/{buffer=""} {buffer=buffer $0 ORS} END{printf "%s", buffer}' "$LOG_FILE" 2>/dev/null | \
        grep -E '\[(ERROR|WARN|SESSION)\]' | tail -n 60 >"$TTY_OUT" || true
}

ingress_interactive_menu() {
    local choice
    while configured_ingress; do
        clear_screen; banner
        ingress_main_dashboard
        cat >"$TTY_OUT" <<EOF_INGRESS_MENU_204

${C_BOLD}${C_MAGENTA}CONNECTION${C_RESET}
  ${C_CYAN}1)${C_RESET} Status overview
  ${C_CYAN}2)${C_RESET} Diagnostics
  ${C_GREEN}3)${C_RESET} Run end-to-end connectivity tests
  ${C_GREEN}4)${C_RESET} Start / reconnect tunnel
  ${C_YELLOW}5)${C_RESET} Stop tunnel temporarily
  ${C_CYAN}6)${C_RESET} Replace peer using a new pairing token
  ${C_CYAN}7)${C_RESET} Repair / reconfigure current peer
  ${C_CYAN}8)${C_RESET} Run recovery now

${C_BOLD}${C_MAGENTA}REMOVE${C_RESET}
  ${C_YELLOW}9)${C_RESET} Remove current ingress connection and restore host state
  ${C_RED}10)${C_RESET} Completely uninstall Dragon Fruit Relay
  ${C_RED}0)${C_RESET} Exit
EOF_INGRESS_MENU_204
        choice=$(prompt 'Select an option: ')
        case "$choice" in
            1) diagnostics_overview || true; pause_screen ;;
            2) ingress_diagnostics_menu ;;
            3) ingress_connectivity_tests || true; pause_screen ;;
            4) start_tunnel || true; sleep 1 ;;
            5) stop_tunnel; sleep 1 ;;
            6) replace_ingress_connection || true; sleep 1 ;;
            7) repair_current || true; sleep 1 ;;
            8) run_recovery || true; sleep 1 ;;
            9) remove_tunnel_configuration; return ;;
            10) uninstall_routevpn; return ;;
            0) exit 0 ;;
            *) warn 'Invalid selection.'; sleep 1 ;;
        esac
    done
}

unconfigured_menu() {
    local choice
    while [[ "$(current_node_role)" == unconfigured ]]; do
        clear_screen; banner; diagnostics_preflight
        cat >"$TTY_OUT" <<EOF_UNCONFIGURED_204

${C_BOLD}${C_MAGENTA}CHOOSE THIS SERVER'S ROLE${C_RESET}
  ${C_GREEN}1)${C_RESET} Configure as a multi-connection egress hub
  ${C_GREEN}2)${C_RESET} Configure as an ingress client
  ${C_CYAN}3)${C_RESET} Diagnostics / preflight
  ${C_RED}0)${C_RESET} Exit
EOF_UNCONFIGURED_204
        choice=$(prompt 'Select a role or action: ')
        case "$choice" in
            1) setup_egress_hub; return ;;
            2) setup_ingress; return ;;
            3) diagnostics_preflight; pause_screen ;;
            0) exit 0 ;;
            *) warn 'Invalid selection.'; sleep 1 ;;
        esac
    done
}

interactive_main() {
    handle_legacy_routevpn
    while true; do
        if legacy_single_configured; then
            legacy_migration_menu
            continue
        fi
        case "$(current_node_role)" in
            egress-hub) hub_interactive_menu ;;
            ingress-client) ingress_interactive_menu ;;
            unconfigured) unconfigured_menu ;;
            legacy-or-invalid) die 'A legacy or invalid Dragon Fruit Relay configuration was detected. Use migration or removal before continuing.' ;;
            *) die 'Unable to determine this server role.' ;;
        esac
    done
}

usage() {
    cat <<'EOF_USAGE_204'
Usage: dragon-fruit-relay [command]

Role selection:
  menu                                  Open the role-aware interactive shell
  egress init                           Configure this server as an egress hub
  ingress [--token TOKEN]               Configure this server as an ingress client

Ingress connection lifecycle:
  ingress replace [--token TOKEN]       Validate and replace the current peer
  ingress reconfigure                   Rebuild current peer files and services
  ingress remove                        Remove only the current ingress connection
  status|diagnostics|test               Inspect the ingress connection
  start|stop|repair|recover             Operate the ingress connection

Egress hub commands:
  connection add [options]              Add an egress responder connection
  connection list [--json]              List all connections
  connection status NAME [--json]       Show one connection
  connection diagnostics NAME VIEW      Focused diagnostics
  connection test NAME                  Peer and DNS/NAT readiness tests
  connection start|stop|restart NAME    Operate one connection
  connection repair|token|remove NAME   Manage one connection
  client ...                            Backward-compatible alias
  start|stop|repair --all               Operate all hub connections

Migration and removal:
  migrate [NAME]                        Migrate a 1.x installation
  remove                                Remove the configured role
  uninstall                             Complete removal, including the command
  version                               Show version
EOF_USAGE_204
}

main() {
    require_root_and_platform
    install_cli_command
    local command="${1:-menu}" sub="${2:-}" role token=''
    role=$(current_node_role)
    case "$command" in
        menu) interactive_main ;;
        egress)
            [[ "$role" == unconfigured || "$role" == legacy-or-invalid ]] || \
                die "This server is configured as ${role}. Remove that role before configuring an egress hub."
            case "$sub" in init|'') setup_egress_hub ;; *) die "Unknown egress action: ${sub}" ;; esac
            ;;
        ingress)
            case "$sub" in
                replace)
                    [[ "$role" == ingress-client ]] || die 'Ingress replacement requires a configured ingress client.'
                    if [[ "${3:-}" == --token ]]; then
                        token="${4:-}"; [[ -n "$token" ]] || die 'The --token option requires a pairing token.'
                    elif [[ -n "${3:-}" ]]; then
                        die "Unknown ingress replace option: ${3}"
                    fi
                    replace_ingress_connection "$token"
                    ;;
                reconfigure|repair)
                    [[ "$role" == ingress-client ]] || die 'No ingress connection is configured.'
                    repair_current
                    ;;
                remove)
                    [[ "$role" == ingress-client ]] || die 'No ingress connection is configured.'
                    remove_tunnel_configuration
                    ;;
                ''|--token)
                    [[ "$role" == unconfigured || "$role" == legacy-or-invalid ]] || \
                        die "This server is configured as ${role}. Use 'ingress replace' to change the peer."
                    handle_legacy_routevpn
                    if [[ "$sub" == --token ]]; then
                        token="${3:-}"; [[ -n "$token" ]] || die 'The --token option requires a pairing token.'
                        setup_ingress "$token"
                    else
                        setup_ingress
                    fi
                    ;;
                *) die "Unknown ingress action: ${sub}" ;;
            esac
            ;;
        connection|client) shift; client_cli "$@" ;;
        migrate)
            legacy_single_configured || die 'No legacy Dragon Fruit Relay installation was detected.'
            if [[ "$(legacy_config_role)" == egress ]]; then migrate_legacy_egress "${2:-}"; else migrate_legacy_ingress; fi
            ;;
        diagnostics|diag)
            case "$role" in
                egress-hub) hub_diagnostics_menu ;;
                ingress-client) ingress_diagnostics_menu ;;
                unconfigured) diagnostics_preflight ;;
                *) die 'Resolve or migrate the existing legacy configuration first.' ;;
            esac
            ;;
        health|status)
            case "$role" in
                egress-hub) hub_health_overview ;;
                ingress-client) diagnostics_overview || true ;;
                unconfigured) diagnostics_preflight ;;
                *) die 'Resolve or migrate the existing legacy configuration first.' ;;
            esac
            ;;
        test)
            case "$role" in
                egress-hub) hub_connectivity_tests ;;
                ingress-client) ingress_connectivity_tests ;;
                *) die 'Configure this server before running tests.' ;;
            esac
            ;;
        start)
            if [[ "$role" == egress-hub ]]; then start_all_clients
            elif [[ "$role" == ingress-client ]]; then start_tunnel
            else die 'No configured role is available to start.'; fi
            ;;
        stop)
            if [[ "$role" == egress-hub ]]; then stop_all_clients
            elif [[ "$role" == ingress-client ]]; then stop_tunnel
            else die 'No configured role is available to stop.'; fi
            ;;
        repair)
            if [[ "$role" == egress-hub ]]; then repair_all_clients
            elif [[ "$role" == ingress-client ]]; then repair_current
            else die 'No configured role is available to repair.'; fi
            ;;
        recover)
            [[ "$role" == ingress-client ]] || die 'Recovery is an ingress-client operation.'
            run_recovery
            ;;
        token)
            [[ "$role" == egress-hub ]] || die 'Pairing tokens are generated on an egress hub.'
            [[ -n "$sub" ]] || die 'Specify a connection name.'
            show_client_token "$sub"
            ;;
        remove)
            case "$role" in
                egress-hub) remove_egress_hub no no ;;
                ingress-client) remove_tunnel_configuration ;;
                *) die 'No configured Dragon Fruit Relay role was found.' ;;
            esac
            ;;
        rebuild)
            [[ "$role" == ingress-client ]] || die 'Hub connections are rebuilt individually.'
            replace_ingress_connection
            ;;
        uninstall)
            case "$role" in
                egress-hub) remove_egress_hub yes no ;;
                ingress-client|legacy-or-invalid|unconfigured) uninstall_routevpn ;;
            esac
            ;;
        version) printf '%s %s\n' "$APP_NAME" "$APP_VERSION" ;;
        -h|--help|help) usage ;;
        *) usage; exit 1 ;;
    esac
}

if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" ]]; then
    log_line SESSION "version=${APP_VERSION} pid=$$ command=${*:-menu}"
    main "$@"
fi

# Keep the managed resolver traversable by unprivileged package helpers while preserving the resolver lifecycle and live-diagnostics behavior.
