#!/usr/bin/env bash
# Dragon Fruit Relay Egress - Production-style Debian route-based IKEv2/IPsec installer
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Alireza Ghaffari

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
readonly APP_VERSION="v2.1.0"
readonly DFR_PRODUCT_ID="dragon-fruit-relay"
readonly DFR_PRODUCT_LINEAGE="standalone-dfr"

# Canonical Dragon Fruit Relay tree. Application-owned scripts and state live here.
readonly CONFIG_DIR="/etc/dragon-fruit-relay"
readonly CONFIG_FILE="${CONFIG_DIR}/dragon-fruit-relay.conf"
readonly LIB_DIR="${CONFIG_DIR}/bin"
readonly UNIT_DIR="${CONFIG_DIR}/systemd"
readonly SYSCTL_DIR="${CONFIG_DIR}/sysctl"
readonly RESOLVER_DIR="${CONFIG_DIR}/resolver"
readonly SECRETS_DIR="${CONFIG_DIR}/secrets"
readonly MANAGED_README="${CONFIG_DIR}/README.managed"
readonly INSTALLER_COPY="${CONFIG_DIR}/dragon-fruit-relay.sh"
readonly CLI_COMMAND="/usr/local/sbin/dragon-fruit-relay"
readonly TOKEN_FILE="${SECRETS_DIR}/pairing-token.txt"

# Dragon Fruit Relay Server layout. Each named Client has an
# independent daemon, VICI socket, UDP transport, XFRM interface and token.
readonly HOST_CONFIG_FILE="${CONFIG_DIR}/host.conf"
readonly CLIENTS_DIR="${CONFIG_DIR}/clients"
readonly HUB_BIN_DIR="${CONFIG_DIR}/hub-bin"
readonly SWANCTL_CLIENT_ROOT="/etc/swanctl/dragon-fruit-relay"
readonly STRONGSWAN_CLIENT_ROOT="/etc/strongswan.d/dragon-fruit-relay"
readonly CLIENT_UNIT_TEMPLATE="${UNIT_DIR}/dragon-fruit-relay-client@.service"
readonly RELEASE_SCHEMA_CURRENT="1"
readonly CONFIG_SCHEMA_CURRENT="1"
readonly HUB_SCHEMA_CURRENT="1"
readonly PROFILE_SCHEMA_CURRENT="1"
readonly PROFILE_TOKEN_VERSION="1"
readonly PROFILE_NAME_MAX="32"
readonly PROFILE_PORT_MIN="20000"
readonly PROFILE_PORT_MAX="59999"
readonly PROFILE_PORT_FIRST="45001"
readonly PROFILE_XFRM_ID_BASE="1000"
readonly PROFILE_TUNNEL_POOL="10.10.0.0/16"

# Mutable state and logs follow normal Linux filesystem conventions.
readonly STATE_DIR="/var/lib/dragon-fruit-relay"
readonly BACKUP_DIR="${STATE_DIR}/original"
readonly MANIFEST_FILE="${BACKUP_DIR}/manifest.tsv"
readonly PACKAGE_STATE_FILE="${STATE_DIR}/package-state.conf"
readonly IPTABLES_RUNTIME_BACKUP="${BACKUP_DIR}/iptables.runtime.v4"
readonly IP6TABLES_RUNTIME_BACKUP="${BACKUP_DIR}/ip6tables.runtime.v6"
readonly SYSCTL_RUNTIME_BACKUP="${BACKUP_DIR}/sysctl.runtime.tsv"
readonly LOG_DIR="/var/log/dragon-fruit-relay"
readonly LOG_FILE="${LOG_DIR}/installer.log"
readonly LOCK_FILE="/run/lock/dragon-fruit-relay.lock"

# Standard integration locations. strongSwan configuration is written directly
# to its canonical directories; Dragon Fruit Relay scripts remain centralized.
readonly SYSTEMD_DIR="/etc/systemd/system"
readonly SWANCTL_FILE="/etc/swanctl/swanctl.conf"
readonly STRONGSWAN_ROUTE_FILE="/etc/strongswan.d/99-dragon-fruit-relay.conf"
readonly STRONGSWAN_OVERRIDE_DIR="/etc/systemd/system/strongswan.service.d"
readonly STRONGSWAN_OVERRIDE_FILE="${STRONGSWAN_OVERRIDE_DIR}/dragon-fruit-relay.conf"
readonly SYSCTL_FILE="/etc/sysctl.d/99-dragon-fruit-relay.conf"
readonly SYSCTL_MANAGED_FILE="${SYSCTL_DIR}/99-dragon-fruit-relay.conf"
readonly RESOLVER_MANAGED_FILE="${RESOLVER_DIR}/resolv.conf"
readonly DHCPCD_CONFIG_FILE="/etc/dhcpcd.conf"
readonly INGRESS_CONFIG_DIR="${CONFIG_DIR}/ingress"
readonly INGRESS_SWANCTL_SOURCE="${INGRESS_CONFIG_DIR}/swanctl.conf"
readonly INGRESS_SWANCTL_DIR="${SWANCTL_CLIENT_ROOT}/ingress"
readonly INGRESS_SWANCTL_CANONICAL="${INGRESS_SWANCTL_DIR}/swanctl.conf"
readonly INGRESS_SWANCTL_MARKER="${INGRESS_SWANCTL_DIR}/.dragon-fruit-relay-ingress"
readonly INGRESS_STRONGSWAN_SOURCE="${INGRESS_CONFIG_DIR}/strongswan.conf"
readonly INGRESS_OVERRIDE_SOURCE="${INGRESS_CONFIG_DIR}/strongswan-systemd.conf"
readonly SYSTEMD_OPERATION_TIMEOUT_SECONDS="25"
readonly SWANCTL_OPERATION_TIMEOUT_SECONDS="15"
readonly PUBLIC_IP_LOOKUP_TIMEOUT_SECONDS="6"

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
readonly DEFAULT_INGRESS_ID="dragon-fruit-relay-ingress"
readonly DEFAULT_EGRESS_ID="dragon-fruit-relay-egress"
readonly DEFAULT_IKE_PORT="45000"
readonly DEFAULT_NATT_PORT="45000"
readonly DEFAULT_CUSTOM_NATT_PORT="45000"
readonly CONNECT_TIMEOUT_SECONDS="18"
readonly CUSTOM_NATT_PORT_MIN="20000"
readonly CUSTOM_NATT_PORT_MAX="59999"
readonly PAIRING_TOKEN_VERSION="1"

# Standalone DFR registry / subscription control plane.
# Persistent registry / subscription control plane. Runtime configuration
# under /etc is reproducible; this SQLite registry is the portable source of truth.
readonly REGISTRY_SCHEMA_CURRENT="1"
readonly REGISTRY_DIR="${STATE_DIR}/database"
readonly REGISTRY_DB="${REGISTRY_DIR}/registry.sqlite3"
readonly REGISTRY_BACKUP_DIR="${STATE_DIR}/backups"
readonly REGISTRY_HELPER="${HUB_BIN_DIR}/registry"
readonly REGISTRY_UNIT="dragon-fruit-relay-registry.service"
readonly REGISTRY_UNIT_FILE="${UNIT_DIR}/${REGISTRY_UNIT}"
readonly REGISTRY_RUNTIME_API_REQUIRED="1"
readonly REGISTRY_RUNTIME_ID_REQUIRED="dfr-schema1-monitoring-live-v1"
readonly REGISTRY_RUNTIME_STATE="/run/dragon-fruit-relay/registry-runtime.json"
readonly FLEET_UI_SNAPSHOT="/run/dragon-fruit-relay/fleet-ui-snapshot.json"

# Tunnel-only subscriber status protocol for authenticated Clients.
readonly SUBSCRIPTION_PROTOCOL_VERSION="1"
readonly DEFAULT_SUBSCRIPTION_PORT="39892"
SUBSCRIPTION_PORT="$DEFAULT_SUBSCRIPTION_PORT"
readonly SUBSCRIPTION_RESPONDER="${HUB_BIN_DIR}/subscription-responder"
readonly SUBSCRIPTION_UNIT="dragon-fruit-relay-subscription.service"
readonly SUBSCRIPTION_UNIT_FILE="${UNIT_DIR}/${SUBSCRIPTION_UNIT}"

# Managed ingress control plane. CONTROL/1 is reachable only over each
# connection's XFRM addresses and is authenticated again with a per-connection
# HMAC key.  Software releases are signed independently of IPsec transport.
readonly CONTROL_PROTOCOL_VERSION="1"
readonly DEFAULT_CONTROL_PORT="39893"
CONTROL_PORT="$DEFAULT_CONTROL_PORT"
readonly CONTROL_RESPONDER="${HUB_BIN_DIR}/control-responder"
readonly CONTROL_UNIT="dragon-fruit-relay-control.service"
readonly CONTROL_UNIT_FILE="${UNIT_DIR}/${CONTROL_UNIT}"
readonly CONTROL_TX_HELPER="${HUB_BIN_DIR}/config-transaction"
readonly RELEASE_DIR="${STATE_DIR}/releases/ingress"
readonly UPDATE_SIGNING_KEY="${SECRETS_DIR}/ingress-update-ed25519.key"
readonly UPDATE_PUBLIC_KEY="${SECRETS_DIR}/ingress-update-ed25519.pub"
readonly UPDATE_PUBLIC_KEY_B64_FILE="${SECRETS_DIR}/ingress-update-public.b64"
readonly ENROLLMENT_TOKEN_TTL_SECONDS="1800"
readonly BUNDLED_INGRESS_VERSION="v2.1.0"
readonly BUNDLED_INGRESS_SHA256="0d411f0afd5da3faa56d7889d88f48b8daf32d924b0623b66e114ba2be85ad54"


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
if [[ "${DFR_INTERNAL_NO_MAIN_LOCK:-0}" != 1 && "${BASH_SOURCE[0]:-}" == "$0" ]]; then
    # Canonicalize the installer path before the flock wrapper re-executes it.
    # This keeps all invocation forms valid, including `bash installer.sh upgrade`
    # where $0 contains no slash and therefore is not PATH-resolvable by env.
    self_path="${BASH_SOURCE[0]:-$0}"
    if [[ "$self_path" != /* ]]; then
        self_dir=$(cd -- "$(dirname -- "$self_path")" 2>/dev/null && pwd -P) || early_exit "Unable to resolve installer directory."
        self_path="${self_dir}/$(basename -- "$self_path")"
    fi
    set +e
    flock -n -E 75 -o "$LOCK_FILE" env DFR_INTERNAL_NO_MAIN_LOCK=1 bash "$self_path" "$@"
    lock_rc=$?
    set -e
    ((lock_rc == 75)) && early_exit "Another Dragon Fruit Relay operation is already running."
    exit "$lock_rc"
fi
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


add_client_interactive () 
{ 
    local name;
    name=$(prompt_profile_name);
    if ! create_hub_client "$name" interactive auto; then
        warn "Connection '${name}' was not created; the incomplete profile was cleaned up.";
        return 0;
    fi
}


apply_client_network_rules ()
{
    local name="$1" forward_out forward_return nat mgmt_in mgmt_out ping_in ping_out ports
    load_host_config
    load_client_profile "$name"
    forward_out=$(client_rule_comment "$name" forward-out)
    forward_return=$(client_rule_comment "$name" forward-return)
    nat=$(client_rule_comment "$name" nat)
    mgmt_in=$(client_rule_comment "$name" management-in)
    mgmt_out=$(client_rule_comment "$name" management-out)
    ping_in=$(client_rule_comment "$name" peer-ping-in)
    ping_out=$(client_rule_comment "$name" peer-ping-out)
    ports="${SUBSCRIPTION_PORT},${CONTROL_PORT}"
    iptables -C FORWARD -i "$XFRM_IF" -o "$WAN_IF" -s "$INGRESS_XFRM_IP/32" -m comment --comment "$forward_out" -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i "$XFRM_IF" -o "$WAN_IF" -s "$INGRESS_XFRM_IP/32" -m comment --comment "$forward_out" -j ACCEPT || return 1
    iptables -C FORWARD -i "$WAN_IF" -o "$XFRM_IF" -d "$INGRESS_XFRM_IP/32" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "$forward_return" -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i "$WAN_IF" -o "$XFRM_IF" -d "$INGRESS_XFRM_IP/32" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "$forward_return" -j ACCEPT || return 1
    iptables -t nat -C POSTROUTING -s "$INGRESS_XFRM_IP/32" -o "$WAN_IF" -m comment --comment "$nat" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s "$INGRESS_XFRM_IP/32" -o "$WAN_IF" -m comment --comment "$nat" -j MASQUERADE || return 1
    # CONTROL/1 and SUBSCRIPTION/1 are deliberately tunnel-scoped. Permit only
    # this paired Client address, on this Client's XFRM interface, to this
    # Server-side XFRM address. These rules make the management plane reliable
    # even when the host's default INPUT policy is DROP/REJECT.
    iptables -C INPUT -i "$XFRM_IF" -s "$INGRESS_XFRM_IP/32" -d "$EGRESS_XFRM_IP/32" -p tcp -m multiport --dports "$ports" -m comment --comment "$mgmt_in" -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -i "$XFRM_IF" -s "$INGRESS_XFRM_IP/32" -d "$EGRESS_XFRM_IP/32" -p tcp -m multiport --dports "$ports" -m comment --comment "$mgmt_in" -j ACCEPT || return 1
    iptables -C OUTPUT -o "$XFRM_IF" -s "$EGRESS_XFRM_IP/32" -d "$INGRESS_XFRM_IP/32" -p tcp -m multiport --sports "$ports" -m conntrack --ctstate ESTABLISHED -m comment --comment "$mgmt_out" -j ACCEPT 2>/dev/null || iptables -I OUTPUT 1 -o "$XFRM_IF" -s "$EGRESS_XFRM_IP/32" -d "$INGRESS_XFRM_IP/32" -p tcp -m multiport --sports "$ports" -m conntrack --ctstate ESTABLISHED -m comment --comment "$mgmt_out" -j ACCEPT || return 1
    iptables -C INPUT -i "$XFRM_IF" -s "$INGRESS_XFRM_IP/32" -d "$EGRESS_XFRM_IP/32" -p icmp --icmp-type echo-request -m comment --comment "$ping_in" -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -i "$XFRM_IF" -s "$INGRESS_XFRM_IP/32" -d "$EGRESS_XFRM_IP/32" -p icmp --icmp-type echo-request -m comment --comment "$ping_in" -j ACCEPT || return 1
    iptables -C OUTPUT -o "$XFRM_IF" -s "$EGRESS_XFRM_IP/32" -d "$INGRESS_XFRM_IP/32" -p icmp --icmp-type echo-reply -m comment --comment "$ping_out" -j ACCEPT 2>/dev/null || iptables -I OUTPUT 1 -o "$XFRM_IF" -s "$EGRESS_XFRM_IP/32" -d "$INGRESS_XFRM_IP/32" -p icmp --icmp-type echo-reply -m comment --comment "$ping_out" -j ACCEPT || return 1
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >> "$LOG_FILE" 2>&1 || true
}

backup_common_paths () 
{ 
    record_unit_state_initial strongswan.service STRONGSWAN;
    backup_original "$SWANCTL_FILE";
    backup_original "$STRONGSWAN_ROUTE_FILE";
    backup_original "$STRONGSWAN_OVERRIDE_FILE";
    backup_original "$SYSTEMD_DIR/dragon-fruit-relay-xfrm.service"
}

backup_egress_paths () 
{ 
    backup_common_paths;
    record_unit_state_initial netfilter-persistent.service NETFILTER;
    backup_original "$SYSCTL_FILE";
    backup_original /etc/iptables/rules.v4;
    backup_original /etc/iptables/rules.v6;
    mkdir -p "$BACKUP_DIR";
    if [[ ! -f "$IPTABLES_RUNTIME_BACKUP" ]] && command -v iptables-save > /dev/null 2>&1; then
        iptables-save > "$IPTABLES_RUNTIME_BACKUP";
        chmod 600 "$IPTABLES_RUNTIME_BACKUP";
    fi;
    if [[ ! -f "$IP6TABLES_RUNTIME_BACKUP" ]] && command -v ip6tables-save > /dev/null 2>&1; then
        ip6tables-save > "$IP6TABLES_RUNTIME_BACKUP" 2> /dev/null || true;
        chmod 600 "$IP6TABLES_RUNTIME_BACKUP" 2> /dev/null || true;
    fi
}

backup_egress_runtime_sysctls () 
{ 
    [[ -n "${WAN_IF:-}" ]] || return 0;
    [[ -f "$SYSCTL_RUNTIME_BACKUP" ]] && return 0;
    mkdir -p "$BACKUP_DIR";
    : > "$SYSCTL_RUNTIME_BACKUP";
    chmod 600 "$SYSCTL_RUNTIME_BACKUP";
    local key value;
    for key in net.ipv4.ip_forward net.ipv4.conf.all.accept_redirects net.ipv4.conf.default.accept_redirects net.ipv4.conf.all.send_redirects net.ipv4.conf.default.send_redirects net.ipv4.conf.all.rp_filter net.ipv4.conf.default.rp_filter "net.ipv4.conf.${WAN_IF}.rp_filter";
    do
        if value=$(sysctl -n "$key" 2> /dev/null); then
            printf '%s\t%s\n' "$key" "$value" >> "$SYSCTL_RUNTIME_BACKUP";
        fi;
    done
}

backup_original () 
{ 
    local target="$1";
    local saved="${BACKUP_DIR}/files${target}";
    if manifest_contains "$target"; then
        if dragonfruit_owned_symlink "$saved"; then
            awk -F '\t' -v target="$target" '$2 != target' "$MANIFEST_FILE" > "${MANIFEST_FILE}.tmp";
            mv "${MANIFEST_FILE}.tmp" "$MANIFEST_FILE";
            rm -f "$saved";
        else
            return 0;
        fi;
    fi;
    if dragonfruit_owned_symlink "$target"; then
        rm -f "$target";
    fi;
    mkdir -p "$BACKUP_DIR/files";
    touch "$MANIFEST_FILE";
    if [[ -e "$target" || -L "$target" ]]; then
        mkdir -p "${BACKUP_DIR}/files$(dirname "$target")";
        cp -a "$target" "${BACKUP_DIR}/files${target}";
        printf 'present\t%s\n' "$target" >> "$MANIFEST_FILE";
    else
        printf 'absent\t%s\n' "$target" >> "$MANIFEST_FILE";
    fi
}


cidr_hosts () 
{ 
    local cidr="$1";
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

claim_managed_namespace () 
{ 
    local directory="$1";
    local marker="$directory/.dragon-fruit-relay-root";
    if [[ -d "$directory" && ! -e "$marker" ]]; then
        if find "$directory" -mindepth 1 -maxdepth 1 -print -quit 2> /dev/null | grep -q .; then
            die "Refusing to claim non-empty unmanaged directory: ${directory}";
        fi;
    else
        if [[ -e "$directory" && ! -d "$directory" ]]; then
            die "Required managed directory path is not a directory: ${directory}";
        fi;
    fi;
    install -d -m 0750 "$directory";
    : > "$marker";
    chmod 0640 "$marker"
}

clean_abandoned_install_before_setup () 
{ 
    [[ ! -f "$CONFIG_FILE" ]] || return 0;
    local previous="$STATE_DIR/last-dragon-fruit-relay.conf" prior_evidence=no previous_role='unknown';
    if [[ -r "$previous" ]]; then
        prior_evidence=yes;
        ( set +u;
        source "$previous";
        swanctl --terminate --ike dragonfruit_relay > /dev/null 2>&1 || true;
        if [[ "${ROLE:-}" == ingress ]]; then
            delete_rule_pref_all "${RULE_DNS_PRIMARY:-}";
            delete_rule_pref_all "${RULE_DNS_SECONDARY:-}";
            delete_rule_pref_all "${RULE_TUNNEL_SOURCE:-}";
            [[ "${ROUTE_TABLE:-}" =~ ^[0-9]+$ ]] && ip -4 route flush table "$ROUTE_TABLE" 2> /dev/null || true;
        else
            if [[ "${ROLE:-}" == egress ]]; then
                remove_egress_network_rules || true;
            fi;
        fi;
        delete_link_bounded "${XFRM_IF:-$DEFAULT_XFRM_IF}" || true );
        previous_role=$(awk -F= '$1=="ROLE" {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}' "$previous" 2> /dev/null || true);
        previous_role=${previous_role//\'/};
    fi;
    [[ -f "$MANIFEST_FILE" || -e "$SYSTEMD_DIR/dragon-fruit-relay-xfrm.service" ]] && prior_evidence=yes;
    systemctl disable --now dragon-fruit-relay-healthcheck.timer > /dev/null 2>&1 || true;
    rm -f "$SYSTEMD_DIR/timers.target.wants/dragon-fruit-relay-healthcheck.timer" "$SYSTEMD_DIR/multi-user.target.wants/dragon-fruit-relay-xfrm.service" "$SYSTEMD_DIR/multi-user.target.wants/dragon-fruit-relay-routing.service" "$SYSTEMD_DIR/multi-user.target.wants/dragon-fruit-relay-dns.service";
    systemctl stop dragon-fruit-relay-healthcheck.service dragon-fruit-relay-dns.service dragon-fruit-relay-routing.service > /dev/null 2>&1 || true;
    remove_all_dragonfruit_network_rules || true;
    cleanup_dragonfruit_managed_xfrm_interfaces || die 'One or more stale managed XFRM interfaces could not be removed safely.';
    if [[ -f "$MANIFEST_FILE" ]]; then
        restore_package_state || true;
        restore_originals || true;
        systemctl daemon-reload > /dev/null 2>&1 || true;
        if [[ "$previous_role" == egress && -f /etc/iptables/rules.v4 ]] && command -v netfilter-persistent > /dev/null 2>&1; then
            netfilter-persistent reload >> "$LOG_FILE" 2>&1 || true;
        fi;
        restore_unit_state strongswan.service STRONGSWAN || true;
        restore_unit_state netfilter-persistent.service NETFILTER || true;
    fi;
    local stale target;
    for stale in "$SWANCTL_FILE" "$INGRESS_SWANCTL_CANONICAL" "$STRONGSWAN_ROUTE_FILE" "$STRONGSWAN_OVERRIDE_FILE" "$SYSCTL_FILE" "$SYSTEMD_DIR/dragon-fruit-relay-xfrm.service" "$SYSTEMD_DIR/dragon-fruit-relay-routing.service" "$SYSTEMD_DIR/dragon-fruit-relay-dns.service" "$SYSTEMD_DIR/dragon-fruit-relay-healthcheck.service" "$SYSTEMD_DIR/dragon-fruit-relay-healthcheck.timer";
    do
        if [[ -L "$stale" ]]; then
            target=$(readlink -f "$stale" 2> /dev/null || true);
            [[ "$target" == "$CONFIG_DIR"/* ]] && rm -f "$stale";
        fi;
    done;
    [[ -L /etc/resolv.conf && "$(readlink -f /etc/resolv.conf 2> /dev/null || true)" == "$RESOLVER_MANAGED_FILE" ]] && rm -f /etc/resolv.conf || true;
    if [[ -e "$INGRESS_SWANCTL_MARKER" ]] || { 
        [[ -f "$INGRESS_SWANCTL_CANONICAL" ]] && grep -q '^# Managed by Dragon Fruit Relay\.' "$INGRESS_SWANCTL_CANONICAL" 2> /dev/null
    }; then
        rm -rf -- "$INGRESS_SWANCTL_DIR";
        rmdir "$SWANCTL_CLIENT_ROOT" 2> /dev/null || true;
    fi;
    rm -rf "$CONFIG_DIR" "$STATE_DIR";
    rm -f "$SYSTEMD_DIR"/dragon-fruit-relay-*.service "$SYSTEMD_DIR"/dragon-fruit-relay-*.timer;
    systemctl daemon-reload > /dev/null 2>&1 || true;
    systemctl reset-failed > /dev/null 2>&1 || true
}



clear_screen () 
{ 
    [[ -t 4 ]] && printf '\033[2J\033[H' > "$TTY_OUT" || true
}

client_cli () 
{ 
    local action="${1:-help}";
    shift || true;
    local name='' port='interactive' tunnel='auto' json=no arg view;
    case "$action" in 
        add)
            while (($#)); do
                arg="$1";
                shift;
                case "$arg" in 
                    --name)
                        name="${1:-}";
                        shift || true
                    ;;
                    --port)
                        port="${1:-}";
                        shift || true
                    ;;
                    --tunnel)
                        tunnel="${1:-}";
                        shift || true
                    ;;
                    --auto)
                        port=auto
                    ;;
                    *)
                        die "Unknown connection add option: ${arg}"
                    ;;
                esac;
            done;
            hub_configured || die 'Configure this machine as a Dragon Fruit Relay Server first.';
            [[ -n "$name" ]] || name=$(prompt_profile_name);
            name=$(normalize_profile_name "$name");
            create_hub_client "$name" "$port" "$tunnel"
        ;;
        list)
            hub_configured || die 'This machine is not configured as a Dragon Fruit Relay Server.';
            [[ "${1:-}" == --json ]] && json=yes;
            list_hub_clients "$json"
        ;;
        status)
            hub_configured || die 'This machine is not configured as a Dragon Fruit Relay Server.';
            name="${1:-}";
            [[ -n "$name" ]] || die 'Connection name is required.';
            [[ "${2:-}" == --json ]] && json=yes;
            show_client_status "$name" "$json"
        ;;
        diagnostics | diag)
            hub_configured || die 'This machine is not configured as a Dragon Fruit Relay Server.';
            name="${1:-}";
            [[ -n "$name" ]] || die 'Connection name is required.';
            view="${2:-menu}";
            case "$view" in 
                menu)
                    client_diagnostics_menu "$name"
                ;;
                ike)
                    client_diag_ike "$name"
                ;;
                network | ping | connectivity)
                    client_diag_network "$name"
                ;;
                dns | nat | dns-nat)
                    client_diag_dns_nat "$name"
                ;;
                service)
                    client_diag_service "$name"
                ;;
                firewall)
                    client_diag_firewall "$name"
                ;;
                logs)
                    client_diag_logs "$name"
                ;;
                raw)
                    client_diag_raw "$name"
                ;;
                live-dns | dns-live)
                    client_diag_live_dns "$name"
                ;;
                live-traffic | traffic-live | capture)
                    client_diag_live_traffic "$name"
                ;;
                *)
                    die "Unknown connection diagnostic view: ${view}"
                ;;
            esac
        ;;
        test)
            hub_configured || die 'This machine is not configured as a Dragon Fruit Relay Server.';
            name="${1:-}";
            [[ -n "$name" ]] || die 'Connection name is required.';
            client_diag_network "$name";
            client_diag_dns_nat "$name"
        ;;
        start)
            name="${1:-}";
            [[ -n "$name" ]] || die 'Connection name is required.';
            start_hub_client "$name"
        ;;
        stop)
            name="${1:-}";
            [[ -n "$name" ]] || die 'Connection name is required.';
            stop_hub_client "$name" no
        ;;
        restart)
            name="${1:-}";
            [[ -n "$name" ]] || die 'Connection name is required.';
            systemctl restart "$(profile_service "$name")";
            apply_client_network_rules "$name"
        ;;
        repair)
            name="${1:-}";
            [[ -n "$name" ]] || die 'Connection name is required.';
            repair_hub_client "$name"
        ;;
        token)
            name="${1:-}";
            [[ -n "$name" ]] || die 'Connection name is required.';
            show_client_token "$name"
        ;;
        management)
            name="${1:-}";
            [[ -n "$name" ]] || die 'Connection name is required.';
            show_managed_ingress_status "$name"
        ;;
        reconcile)
            name="${1:-}";
            [[ -n "$name" ]] || die 'Connection name is required.';
            registry_command management-set "$name" --pending-action reconcile;
            success "Reconcile request queued for '${name}'."
        ;;
        edit)
            name="${1:-}";
            [[ -n "$name" ]] || die 'Connection name is required.';
            shift || true;
            local -a edit_args=(config-stage "$name");
            while (($#)); do
                arg="$1"; shift;
                case "$arg" in
                    --udp-port|--xfrm-mtu|--dns-primary|--dns-secondary)
                        [[ -n "${1:-}" ]] || die "${arg} requires a value.";
                        edit_args+=("$arg" "$1"); shift
                    ;;
                    --rotate-psk)
                        edit_args+=("$arg")
                    ;;
                    *) die "Unknown connection edit option: ${arg}" ;;
                esac;
            done;
            registry_command "${edit_args[@]}"
        ;;
        remove)
            name="${1:-}";
            [[ -n "$name" ]] || die 'Connection name is required.';
            remove_hub_client "$name" no
        ;;
        help | -h | --help)
            cat <<'EOF_CONNECTION_HELP'
Usage: dragon-fruit-relay connection <action> [options]
       dragon-fruit-relay client <action> [options]   # backward-compatible alias

Actions:
  add [--name NAME] [--port auto|PORT] [--tunnel CIDR]
  list [--json]
  status NAME [--json]
  diagnostics NAME [ike|network|dns-nat|service|firewall|logs|raw|live-dns|live-traffic]
  test NAME
  start NAME
  stop NAME
  restart NAME
  repair NAME
  token NAME
  management NAME
  reconcile NAME
  edit NAME [--udp-port PORT] [--xfrm-mtu MTU] [--dns-primary IP] [--dns-secondary IP] [--rotate-psk]
  remove NAME                              # permanently delete this Server connection
EOF_CONNECTION_HELP

        ;;
        *)
            die "Unknown connection action: ${action}"
        ;;
    esac
}

client_diag_dns_nat () 
{ 
    local name="$1" answer counters nat_comment;
    load_host_config;
    collect_client_runtime "$name";
    load_client_profile "$name";
    clear_screen;
    dfr_ui_header 'CONNECTION DNS & NAT';
    section_title "DNS and NAT readiness: ${name}";
    if [[ "$SNAP_IKE" == ESTABLISHED && "$SNAP_CHILD" == INSTALLED ]]; then
        print_check pass 'Encrypted connection' 'IKE and CHILD SAs are active';
    else
        print_check warn 'Encrypted connection' 'No active IKE/CHILD session; remote DNS-over-NAT cannot currently pass';
    fi;
    if answer=$(dns_query_from_source "$LOCAL_IP" "$DNS_PRIMARY"); then
        print_check pass 'Primary DNS through Server' "$DNS_PRIMARY returned $answer";
    else
        print_check fail 'Primary DNS through Server' "$DNS_PRIMARY did not answer from the Server WAN address";
    fi;
    if answer=$(dns_query_from_source "$LOCAL_IP" "$DNS_SECONDARY"); then
        print_check pass 'Secondary DNS through Server' "$DNS_SECONDARY returned $answer";
    else
        print_check fail 'Secondary DNS through Server' "$DNS_SECONDARY did not answer from the Server WAN address";
    fi;
    nat_comment=$(client_rule_comment "$name" nat);
    if counters=$(iptables_rule_counters nat POSTROUTING "$nat_comment"); then
        print_check pass 'Per-connection source NAT' "$counters observed on $nat_comment";
    else
        print_check fail 'Per-connection source NAT' "$nat_comment is missing";
    fi;
    print_check info 'SA traffic evidence' "$(snapshot_traffic_text)";
    print_check info 'End-to-end DNS-over-NAT' 'Run connectivity tests on the paired Client for an active query through this NAT rule.'
}

client_diag_firewall ()
{
    local name="$1" forward_out forward_return nat mgmt_in mgmt_out ping_in ping_out ports
    load_host_config
    load_client_profile "$name"
    clear_screen
    dfr_ui_header 'CONNECTION FIREWALL & NAT'
    section_title "Forwarding and NAT: ${name}"
    forward_out=$(client_rule_comment "$name" forward-out)
    forward_return=$(client_rule_comment "$name" forward-return)
    nat=$(client_rule_comment "$name" nat)
    mgmt_in=$(client_rule_comment "$name" management-in)
    mgmt_out=$(client_rule_comment "$name" management-out)
    ping_in=$(client_rule_comment "$name" peer-ping-in)
    ping_out=$(client_rule_comment "$name" peer-ping-out)
    ports="${SUBSCRIPTION_PORT},${CONTROL_PORT}"
    [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || true)" == 1 ]] && print_check pass 'IPv4 forwarding' enabled || print_check fail 'IPv4 forwarding' disabled
    iptables -C FORWARD -i "$XFRM_IF" -o "$WAN_IF" -s "$INGRESS_XFRM_IP/32" -m comment --comment "$forward_out" -j ACCEPT 2>/dev/null && print_check pass 'Outbound forwarding' "$forward_out" || print_check fail 'Outbound forwarding' missing
    iptables -C FORWARD -i "$WAN_IF" -o "$XFRM_IF" -d "$INGRESS_XFRM_IP/32" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "$forward_return" -j ACCEPT 2>/dev/null && print_check pass 'Return forwarding' "$forward_return" || print_check fail 'Return forwarding' missing
    iptables -t nat -C POSTROUTING -s "$INGRESS_XFRM_IP/32" -o "$WAN_IF" -m comment --comment "$nat" -j MASQUERADE 2>/dev/null && print_check pass 'Source NAT' "$nat" || print_check fail 'Source NAT' missing
    section_title 'Tunnel-scoped management'
    iptables -C INPUT -i "$XFRM_IF" -s "$INGRESS_XFRM_IP/32" -d "$EGRESS_XFRM_IP/32" -p tcp -m multiport --dports "$ports" -m comment --comment "$mgmt_in" -j ACCEPT 2>/dev/null && print_check pass 'CONTROL / subscription input' "${INGRESS_XFRM_IP} -> ${EGRESS_XFRM_IP} TCP ${ports}" || print_check fail 'CONTROL / subscription input' 'missing'
    iptables -C OUTPUT -o "$XFRM_IF" -s "$EGRESS_XFRM_IP/32" -d "$INGRESS_XFRM_IP/32" -p tcp -m multiport --sports "$ports" -m conntrack --ctstate ESTABLISHED -m comment --comment "$mgmt_out" -j ACCEPT 2>/dev/null && print_check pass 'Management response output' "${EGRESS_XFRM_IP} -> ${INGRESS_XFRM_IP}" || print_check fail 'Management response output' 'missing'
    iptables -C INPUT -i "$XFRM_IF" -s "$INGRESS_XFRM_IP/32" -d "$EGRESS_XFRM_IP/32" -p icmp --icmp-type echo-request -m comment --comment "$ping_in" -j ACCEPT 2>/dev/null && print_check pass 'Peer health ICMP input' "$INGRESS_XFRM_IP" || print_check fail 'Peer health ICMP input' 'missing'
    iptables -C OUTPUT -o "$XFRM_IF" -s "$EGRESS_XFRM_IP/32" -d "$INGRESS_XFRM_IP/32" -p icmp --icmp-type echo-reply -m comment --comment "$ping_out" -j ACCEPT 2>/dev/null && print_check pass 'Peer health ICMP output' "$INGRESS_XFRM_IP" || print_check fail 'Peer health ICMP output' 'missing'
}

client_diag_ike () 
{ 
    local name="$1";
    collect_client_runtime "$name";
    clear_screen;
    dfr_ui_header 'IKE / CHILD DIAGNOSTICS';
    section_title "IKE / CHILD summary: ${name}";
    print_check info 'Overall status' "$SNAP_STATUS";
    print_check info 'Remote peer' "$SNAP_PEER" accent;
    print_check info 'IKE session' "$SNAP_IKE";
    print_check info 'CHILD SA' "$SNAP_CHILD";
    print_check info 'Session uptime' "$SNAP_AGE";
    print_check info 'Last inbound packet' "$SNAP_RX_AGO";
    print_check info 'Last outbound packet' "$SNAP_TX_AGO";
    print_check info 'Traffic' "$(snapshot_traffic_text)"
}

client_diag_live_dns () 
{ 
    run_client_live_capture "$1" dns
}

client_diag_live_traffic () 
{ 
    run_client_live_capture "$1" traffic
}

client_diag_logs () 
{ 
    local name="$1" unit;
    unit=$(profile_service "$name");
    clear_screen;
    dfr_ui_header 'CONNECTION WARNINGS & ERRORS';
    section_title "Recent warnings and errors: ${name}";
    journalctl -u "$unit" --since '-30 minutes' --no-pager -o short-iso 2> /dev/null | grep -Ei 'warn|error|fail|retransmit|authentication|proposal|unreachable|timeout' | tail -n 80 > "$TTY_OUT" || true;
    if ! journalctl -u "$unit" --since '-30 minutes' --no-pager -o cat 2> /dev/null | grep -Eqi 'warn|error|fail|retransmit|authentication|proposal|unreachable|timeout'; then
        print_check pass 'Recent service log' 'No matching warning or error messages.';
    fi
}

client_diag_network () 
{ 
    local name="$1";
    collect_client_runtime "$name";
    clear_screen;
    dfr_ui_header 'TUNNEL PATH DIAGNOSTICS';
    section_title "Network path: ${name}";
    ip link show dev "$SNAP_XFRM" > /dev/null 2>&1 && print_check pass 'XFRM interface' "$SNAP_XFRM (ID $SNAP_XFRM_ID)" identity || print_check fail 'XFRM interface' 'missing';
    ip -4 address show dev "$SNAP_XFRM" 2> /dev/null | grep -Fq "$SNAP_LOCAL_TUNNEL/" && print_check pass 'Local tunnel address' "$SNAP_LOCAL_TUNNEL" || print_check fail 'Local tunnel address' "$SNAP_LOCAL_TUNNEL not assigned";
    ping -I "$SNAP_XFRM" -c 1 -W 2 "$SNAP_REMOTE_TUNNEL" > /dev/null 2>&1 && print_check pass 'Tunnel peer' "$SNAP_REMOTE_TUNNEL responds" || print_check fail 'Tunnel peer' "$SNAP_REMOTE_TUNNEL is unreachable";
    print_check info 'Tunnel network' "$SNAP_TUNNEL" accent;
    print_check info 'Interface counters' "$(xfrm_counter_summary "$SNAP_XFRM")";
    print_check info 'SA traffic' "$(snapshot_traffic_text)"
}

client_diag_raw () 
{ 
    local name="$1" sas conns;
    clear_screen;
    dfr_ui_header 'RAW STRONGSWAN OUTPUT';
    section_title "Advanced raw strongSwan output: ${name}";
    warn 'This view is intended for troubleshooting and may be verbose.';
    sas=$(client_swanctl "$name" --list-sas 2>&1 || true);
    conns=$(client_swanctl "$name" --list-conns 2>&1 || true);
    section_title 'LOADED CONNECTION';
    printf '%s
' "${conns:-No connection output.}" > "$TTY_OUT";
    printf '\n%s-- IKE / CHILD state --%s\n' "$C_BOLD" "$C_RESET" > "$TTY_OUT"
    if [[ -n "$sas" ]]; then
        printf '%s\n' "$sas" > "$TTY_OUT"
    else
        semantic_colorize_line 'No active security association.' > "$TTY_OUT"
        printf '\n' > "$TTY_OUT"
    fi
}

client_diag_service () 
{ 
    local name="$1" expected actual;
    collect_client_runtime "$name";
    clear_screen;
    dfr_ui_header 'SERVICE & CONFIGURATION';
    section_title "Service and configuration: ${name}";
    service_row "$(profile_service "$name")" "$name";
    [[ "$SNAP_LISTENER" == listening ]] && print_check pass 'UDP listener' "$SNAP_TRANSPORT" || print_check fail 'UDP listener' "$SNAP_TRANSPORT missing";
    [[ -S "$SNAP_VICI" ]] && print_check pass 'VICI socket' "$SNAP_VICI" || print_check fail 'VICI socket' "$SNAP_VICI missing";
    expected=$(profile_swanctl_source "$name");
    actual=$(readlink -f "$SNAP_SWANCTL_FILE" 2> /dev/null || true);
    [[ -f "$expected" && -L "$SNAP_SWANCTL_FILE" && "$actual" == "$(readlink -f "$expected" 2> /dev/null || true)" ]] && print_check pass 'swanctl link' "$SNAP_SWANCTL_FILE" || print_check fail 'swanctl link' "$SNAP_SWANCTL_FILE";
    expected=$(profile_strongswan_source "$name");
    actual=$(readlink -f "$SNAP_STRONGSWAN_FILE" 2> /dev/null || true);
    [[ -f "$expected" && -L "$SNAP_STRONGSWAN_FILE" && "$actual" == "$(readlink -f "$expected" 2> /dev/null || true)" ]] && print_check pass 'strongSwan link' "$SNAP_STRONGSWAN_FILE" || print_check fail 'strongSwan link' "$SNAP_STRONGSWAN_FILE";
    print_check info 'Profile metadata' "$SNAP_PROFILE_FILE" identity
}


client_diagnostics_menu ()
{
    local name="$1" choice
    while profile_exists "$name"; do
        clear_screen
        dfr_ui_header 'CONNECTION DIAGNOSTICS'
        client_diagnostic_summary "$name"
        section_title 'Diagnostics'
        cat > "$TTY_OUT" <<EOF_CLIENT_DIAG
     ${C_CYAN}[1]${C_RESET}  IKE / CHILD SA & Traffic
     ${C_GREEN}[2]${C_RESET}  Tunnel / XFRM Path
     ${C_GREEN}[3]${C_RESET}  DNS & NAT Readiness
     ${C_CYAN}[4]${C_RESET}  Service & Configuration
     ${C_CYAN}[5]${C_RESET}  Forwarding & NAT Rules
     ${C_YELLOW}[7]${C_RESET}  Recent Warnings & Errors

  ${C_BOLD}${C_MAGENTA}ADVANCED & LIVE${C_RESET}
  ${C_DIM}$(ui_rule $'\u2500')${C_RESET}
     ${C_RED}[8]${C_RESET}  Raw strongSwan State
     ${C_GREEN}[9]${C_RESET}  Live DNS Capture
    ${C_GREEN}[10]${C_RESET}  Live Tunnel Capture

  ${C_BOLD}${C_MAGENTA}ACTIONS${C_RESET}
  ${C_DIM}$(ui_rule $'\u2500')${C_RESET}
    ${C_GREEN}[11]${C_RESET}  Start / Listen
    ${C_YELLOW}[12]${C_RESET}  Stop Temporarily
    ${C_CYAN}[13]${C_RESET}  Restart Connection
    ${C_CYAN}[14]${C_RESET}  Repair Configuration
    ${C_CYAN}[15]${C_RESET}  Edit Configuration
    ${C_CYAN}[16]${C_RESET}  Show Enrollment Token
EOF_CLIENT_DIAG
        ui_navigation_footer
        choice=$(prompt '  Select diagnostic or action: ') || return 0
        case "$choice" in
            1) client_diag_ike "$name"; pause_screen ;;
            2) client_diag_network "$name"; pause_screen ;;
            3) client_diag_dns_nat "$name"; pause_screen ;;
            4) client_diag_service "$name"; pause_screen ;;
            5) client_diag_firewall "$name"; pause_screen ;;
            7) client_diag_logs "$name"; pause_screen ;;
            8) client_diag_raw "$name"; pause_screen ;;
            9) client_diag_live_dns "$name" ;;
            10) client_diag_live_traffic "$name" ;;
            11) start_hub_client "$name" || warn "Client '${name}' could not be started."; pause_screen ;;
            12) if stop_hub_client "$name" no; then success "Client '${name}' was stopped temporarily."; else warn "Client '${name}' could not be stopped."; fi; pause_screen ;;
            13) registry_final_sync || true; if systemctl restart "$(profile_service "$name")"; then apply_client_network_rules "$name" || true; registry_command apply >/dev/null 2>&1 || true; success "Client '${name}' restarted."; else warn "Client '${name}' could not be restarted."; fi; pause_screen ;;
            14) repair_hub_client "$name" || warn "Configuration repair failed for '${name}'."; pause_screen ;;
            15) managed_connection_edit_menu "$name" || true ;;
            16) show_client_token "$name"; pause_screen ;;
            g|G|90) ui_global_navigation ;;
            b|B|0) return 0 ;;
            q|Q|99) exit 0 ;;
            *) warn 'Invalid selection.'; sleep 0.35 ;;
        esac
    done
}

client_rule_comment () 
{ 
    printf 'dragon-fruit-relay-%s-%s' "$1" "$2"
}

# Return the locally cached/effective managed-ingress health.  This never
# probes the remote ingress; management-show reads the local registry and
# derives STALE/OFFLINE from the cached heartbeat timestamp.
managed_ingress_effective_health_cached ()
{
    local name="$1" health=''
    [[ -x "$REGISTRY_HELPER" && -f "$REGISTRY_DB" ]] || { printf '-'; return 0; }
    health=$("$REGISTRY_HELPER" management-show "$name" 2>/dev/null |
        awk '$1=="HEALTH" {print $2; exit}' || true)
    printf '%s' "${health:--}"
}

client_swanctl () 
{ 
    local name="$1" operation;
    shift;
    operation="${1:?swanctl operation required}";
    shift;
    load_client_profile "$name";
    swanctl "$operation" --uri "$VICI_URI" "$@"
}

collect_client_runtime () 
{ 
    local name="$1" unit sas rx_line tx_line;
    SNAP_NAME="$name";
    SNAP_STATUS='MISSING';
    SNAP_SERVICE='not-found';
    SNAP_ENABLED='unknown';
    SNAP_LISTENER='missing';
    SNAP_IKE='DOWN';
    SNAP_CHILD='DOWN';
    SNAP_PEER='-';
    SNAP_AGE='-';
    SNAP_RX_BYTES='0';
    SNAP_RX_PACKETS='0';
    SNAP_RX_AGO='-';
    SNAP_TX_BYTES='0';
    SNAP_TX_PACKETS='0';
    SNAP_TX_AGO='-';
    SNAP_TRANSPORT='-';
    SNAP_XFRM='-';
    SNAP_XFRM_ID='-';
    SNAP_TUNNEL='-';
    SNAP_LOCAL_TUNNEL='-';
    SNAP_REMOTE_TUNNEL='-';
    SNAP_VICI='-';
    SNAP_PROFILE_FILE='-';
    SNAP_SWANCTL_FILE='-';
    SNAP_STRONGSWAN_FILE='-';
    profile_exists "$name" || return 1;
    load_client_profile "$name";
    unit=$(profile_service "$name");
    SNAP_SERVICE=$(systemctl is-active "$unit" 2> /dev/null || true);
    SNAP_ENABLED=$(systemctl is-enabled "$unit" 2> /dev/null || true);
    SNAP_TRANSPORT=$(printf 'UDP %s' "$NATT_PORT");
    SNAP_XFRM="$XFRM_IF";
    SNAP_XFRM_ID="$XFRM_ID";
    SNAP_TUNNEL="$TUNNEL_CIDR";
    SNAP_LOCAL_TUNNEL="$EGRESS_XFRM_IP";
    SNAP_REMOTE_TUNNEL="$INGRESS_XFRM_IP";
    SNAP_VICI="$VICI_SOCKET";
    SNAP_PROFILE_FILE=$(profile_config_file "$name");
    SNAP_SWANCTL_FILE=$(profile_swanctl_canonical "$name");
    SNAP_STRONGSWAN_FILE=$(profile_strongswan_canonical "$name");
    if [[ "$SNAP_SERVICE" != active ]]; then
        [[ "$SNAP_SERVICE" == failed ]] && SNAP_STATUS='FAILED' || SNAP_STATUS='STOPPED';
        return 0;
    fi;
    if ! ip link show dev "$XFRM_IF" > /dev/null 2>&1; then
        SNAP_STATUS='FAILED';
        return 0;
    fi;
    if profile_listener_ok "$name"; then
        SNAP_LISTENER='listening';
    else
        SNAP_STATUS='DEGRADED';
        return 0;
    fi;
    sas=$(client_swanctl "$name" --list-sas 2> /dev/null || true);
    if grep -q ESTABLISHED <<< "$sas"; then
        SNAP_IKE='ESTABLISHED';
        SNAP_PEER=$(awk '/^[[:space:]]*remote / {for (i=1; i<=NF; i++) if ($i == "@") {print $(i+1); exit}}' <<< "$sas");
        SNAP_PEER=${SNAP_PEER:--};
        SNAP_AGE=$(awk '/^[[:space:]]*established [0-9]+s ago/ {print $2; exit}' <<< "$sas");
        SNAP_AGE=$(format_seconds_short "${SNAP_AGE:--}");
    fi;
    if grep -q INSTALLED <<< "$sas"; then
        SNAP_CHILD='INSTALLED';
    fi;
    IFS='	' read -r SNAP_RX_BYTES SNAP_RX_PACKETS SNAP_RX_AGO < <(parse_sa_counter "$sas" in);
    IFS='	' read -r SNAP_TX_BYTES SNAP_TX_PACKETS SNAP_TX_AGO < <(parse_sa_counter "$sas" out);
    if [[ "$SNAP_IKE" == ESTABLISHED && "$SNAP_CHILD" == INSTALLED ]]; then
        SNAP_STATUS='OPERATIONAL'
        local managed_health
        managed_health=$(managed_ingress_effective_health_cached "$name")
        case "$managed_health" in
            OFFLINE) SNAP_STATUS='READY' ;;
            STALE) SNAP_STATUS='DEGRADED' ;;
        esac
    else
        SNAP_STATUS='READY'
    fi
}


confirm ()
{
    local text="$1"
    local default="${2:-yes}"
    local suffix='[Y/n]'
    local answer=''
    local TMOUT=0
    [[ "$default" == no ]] && suffix='[y/N]'
    printf '%s %s: ' "$text" "$suffix" > "$TTY_OUT"
    IFS= read -r answer < "$TTY_IN" || answer=''
    answer=${answer%$'\r'}
    answer=${answer,,}
    if [[ -z "$answer" ]]; then
        [[ "$default" == yes ]]
        return
    fi
    [[ "$answer" == y || "$answer" == yes ]]
}



delete_iptables_rule_all () 
{ 
    local table="$1";
    shift;
    while iptables -t "$table" -C "$@" 2> /dev/null; do
        iptables -t "$table" -D "$@" 2> /dev/null || break;
    done
}

delete_iptables_rules_by_comment () 
{ 
    local table="$1" comment="$2" line;
    local -a rule;
    while IFS= read -r line; do
        [[ "$line" == -A\ * ]] || continue;
        line=${line//\"/};
        read -r -a rule <<< "$line";
        rule[0]='-D';
        iptables -t "$table" "${rule[@]}" > /dev/null 2>&1 || true;
    done < <(iptables -t "$table" -S 2> /dev/null | grep -F -- "$comment" || true)
}

delete_link_bounded () 
{ 
    local ifname="${1:-}" pid elapsed=0;
    [[ -n "$ifname" ]] || return 0;
    ip link show dev "$ifname" > /dev/null 2>&1 || return 0;
    ip link set "$ifname" down > /dev/null 2>&1 || true;
    ip link delete "$ifname" > /dev/null 2>&1 & pid=$!;
    while ((elapsed < 5)); do
        if ! kill -0 "$pid" 2> /dev/null; then
            wait "$pid" 2> /dev/null || true;
            return 0;
        fi;
        sleep 1;
        elapsed=$((elapsed + 1));
    done;
    kill -TERM "$pid" 2> /dev/null || true;
    sleep 1;
    kill -KILL "$pid" 2> /dev/null || true;
    disown "$pid" 2> /dev/null || true;
    warn "The kernel did not complete deletion of interface $ifname within 5 seconds. A reboot may be required to clear the stale netlink operation.";
    return 1
}

delete_rule_pref_all () 
{ 
    local pref="${1:-}";
    [[ "$pref" =~ ^[0-9]+$ ]] || return 0;
    while ip -4 rule del pref "$pref" 2> /dev/null; do
        :;
    done
}

detect_default_gateway () 
{ 
    ip -4 route show default 2> /dev/null | awk 'NR==1 {for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}'
}

detect_default_interface () 
{ 
    ip -4 route show default 2> /dev/null | awk 'NR==1 {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

detect_local_ipv4 () 
{ 
    local interface="$1";
    ip -4 -o address show dev "$interface" scope global 2> /dev/null | awk 'NR==1 {split($4,a,"/"); print a[1]}'
}

detect_public_ipv4 () 
{ 
    local bind="${1:-}" url candidate best='' best_count=0 count;
    local -a curl_args=(-4 -f -sS --noproxy '*' --connect-timeout 3 --max-time "$PUBLIC_IP_LOOKUP_TIMEOUT_SECONDS");
    [[ -n "$bind" ]] && curl_args+=(--interface "$bind");
    declare -A observations=();
    for url in 'https://api.ipify.org' 'https://checkip.amazonaws.com' 'https://ipv4.icanhazip.com' 'https://ifconfig.me/ip';
    do
        candidate=$(env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy -u NO_PROXY -u no_proxy curl "${curl_args[@]}" "$url" 2> /dev/null | tr -d '[:space:]' || true);
        validate_ipv4 "$candidate" || continue;
        observations["$candidate"]=$(( ${observations["$candidate"]:-0} + 1 ));
    done;
    for candidate in "${!observations[@]}";
    do
        count=${observations["$candidate"]};
        if ((count > best_count)); then
            best="$candidate";
            best_count=$count;
        fi;
    done;
    if [[ -n "$best" && "$best_count" -ge 2 ]]; then
        printf '%s' "$best";
        return 0;
    fi;
    return 1
}

diagnostics_preflight ()
{
    clear_screen; dfr_ui_header 'SERVER PRE-FLIGHT'; section_title 'Ready to configure'
    local iface gateway public_ip route_default
    iface=$(detect_default_interface || true); gateway=$(detect_default_gateway || true); public_ip=$(detect_public_ipv4 || true); route_default=$(ip -4 route show default 2>/dev/null | head -n 1 || true)
    print_check pass 'Platform' "${PRETTY_NAME:-Debian} with systemd"
    [[ -n "$iface" ]] && print_check pass 'Internet interface' "$iface" identity || print_check fail 'Internet interface' 'not detected'
    [[ -n "$gateway" ]] && print_check pass 'Default gateway' "$gateway" || print_check warn 'Default gateway' 'not detected'
    [[ -n "$public_ip" ]] && print_check info 'Observed public IPv4' "$public_ip" accent || print_check warn 'Observed public IPv4' 'external lookup failed'
    print_check info 'Default route' "${route_default:-missing}" identity
    section_title 'Conflicts'; xfrm_preflight_rows
    section_title 'Next step'; printf '  Initialize this machine as the Server, then create a connection and enroll the Client with its token.\n' > "$TTY_OUT"
}

die () 
{ 
    error "$*";
    exit 1
}

dns_query_from_source () 
{ 
    local source_ip="$1" server="$2" domain="${3:-example.com}" answer;
    answer=$(timeout 7s dig -4 -b "$source_ip" "@${server}" "$domain" A +time=3 +tries=1 +short 2> /dev/null | awk 'NF {print; exit}' || true);
    [[ -n "$answer" ]] || return 1;
    printf '%s' "$answer"
}



dragonfruit_managed_xfrm_signature ()
{
    local iface="$1" details addresses id_token id_value suffix expected_id;
    [[ "$iface" =~ ^(dfr[0-9]{4}|xfrm[0-9]+)$ ]] || return 1;
    ip link show dev "$iface" > /dev/null 2>&1 || return 1;
    details=$(ip -d link show dev "$iface" 2> /dev/null || true);
    grep -q 'xfrm' <<< "$details" || return 1;
    id_token=$(sed -nE 's/.*if_id[[:space:]]+([^[:space:]]+).*/\1/p' <<< "$details" | head -n 1);
    [[ -n "$id_token" ]] || return 1;
    if [[ "$id_token" =~ ^0x[0-9a-fA-F]+$ ]]; then
        id_value=$((id_token));
    elif [[ "$id_token" =~ ^[0-9]+$ ]]; then
        id_value=$((10#$id_token));
    else
        return 1;
    fi;
    addresses=$(ip -4 -o address show dev "$iface" 2> /dev/null || true);
    if [[ "$iface" =~ ^dfr([0-9]{4})$ ]]; then
        suffix="${BASH_REMATCH[1]}";
        expected_id=$((PROFILE_XFRM_ID_BASE + 10#$suffix));
        [[ "$id_value" -eq "$expected_id" ]] || return 1;
        return 0;
    fi;
    if [[ "$iface" == xfrm0 ]]; then
        if [[ "$id_value" -eq "$DEFAULT_XFRM_ID" ]] || (( id_value > PROFILE_XFRM_ID_BASE && id_value <= PROFILE_XFRM_ID_BASE + 9999 )); then
            return 0;
        fi;
        return 1;
    fi;
    (( id_value > PROFILE_XFRM_ID_BASE && id_value <= PROFILE_XFRM_ID_BASE + 9999 )) || return 1;
    grep -Eq 'inet[[:space:]]+10\.10\.[0-9]+\.[0-9]+/[0-9]+' <<< "$addresses"
}

dragonfruit_xfrm_candidate_interfaces ()
{
    local path iface;
    for path in /sys/class/net/dfr* /sys/class/net/xfrm*; do
        [[ -e "$path" ]] || continue;
        iface=${path##*/};
        [[ "$iface" =~ ^(dfr[0-9]{4}|xfrm[0-9]+)$ ]] || continue;
        printf '%s\n' "$iface";
    done | sort -V -u
}

dragonfruit_managed_xfrm_interfaces ()
{
    local iface;
    while IFS= read -r iface; do
        [[ -n "$iface" ]] || continue;
        dragonfruit_managed_xfrm_signature "$iface" && printf '%s\n' "$iface";
    done < <(dragonfruit_xfrm_candidate_interfaces)
}

dragonfruit_unmanaged_xfrm_candidates ()
{
    local iface;
    while IFS= read -r iface; do
        [[ -n "$iface" ]] || continue;
        dragonfruit_managed_xfrm_signature "$iface" || printf '%s\n' "$iface";
    done < <(dragonfruit_xfrm_candidate_interfaces)
}

cleanup_dragonfruit_managed_xfrm_interfaces ()
{
    local iface failed=0;
    local -a interfaces=();
    mapfile -t interfaces < <(dragonfruit_managed_xfrm_interfaces);
    for iface in "${interfaces[@]}"; do
        [[ -n "$iface" ]] || continue;
        warn "Removing stale managed XFRM interface ${iface}.";
        delete_link_bounded "$iface" || failed=1;
    done;
    for iface in "${interfaces[@]}"; do
        [[ -n "$iface" ]] || continue;
        if ip link show dev "$iface" > /dev/null 2>&1; then
            error "Stale managed XFRM interface ${iface} is still present.";
            failed=1;
        fi;
    done;
    (( failed == 0 ))
}

xfrm_preflight_rows ()
{
    local managed unmanaged;
    managed=$(dragonfruit_managed_xfrm_interfaces | paste -sd ', ' - || true);
    unmanaged=$(dragonfruit_unmanaged_xfrm_candidates | paste -sd ', ' - || true);
    if [[ -n "$managed" ]]; then
        print_check warn 'Managed XFRM residuals' "${managed} (will be removed before setup)";
    else
        print_check pass 'Managed XFRM residuals' 'none; checked dfr* and xfrm*';
    fi;
    if [[ -n "$unmanaged" ]]; then
        print_check warn 'Other XFRM interfaces' "${unmanaged} (not owned; will not be modified)";
    else
        print_check pass 'Other XFRM interfaces' 'none detected';
    fi
}

dragonfruit_owned_symlink ()
{
    local path="$1" link
    [[ -L "$path" ]] || return 1
    link=$(readlink "$path" 2>/dev/null || true)
    [[ "$link" == "$CONFIG_DIR"/* ]]
}

ensure_hub_layout () 
{ 
    install -d -m 0750 "$CONFIG_DIR" "$CLIENTS_DIR" "$HUB_BIN_DIR" "$SYSCTL_DIR" "$UNIT_DIR";
    install -d -m 0700 "$SECRETS_DIR" "$STATE_DIR" "$BACKUP_DIR";
    claim_managed_namespace "$SWANCTL_CLIENT_ROOT";
    claim_managed_namespace "$STRONGSWAN_CLIENT_ROOT";
    install -d -m 0755 /run/dragon-fruit-relay;
    rmdir -- "$LIB_DIR" "$RESOLVER_DIR" 2>/dev/null || true;
    rmdir -- "$CLIENTS_DIR/Debian GNU/Linux" 2>/dev/null || true;
    rmdir -- "$CLIENTS_DIR/Debian GNU" 2>/dev/null || true
}


ensure_managed_symlink () 
{ 
    local source="$1" link="$2";
    [[ -f "$source" ]] || die "Cannot link missing managed file: ${source}";
    mkdir -p "$(dirname "$link")";
    if [[ -e "$link" || -L "$link" ]]; then
        if [[ -L "$link" && "$(readlink -f -- "$link" 2> /dev/null || true)" == "$(readlink -f -- "$source")" ]]; then
            return 0;
        fi;
        die "Refusing to replace unmanaged strongSwan path: ${link}";
    fi;
    ln -s "$source" "$link"
}



error () 
{ 
    log_line ERROR "$*";
    if [[ "${DFR_SETUP_UI_ACTIVE:-no}" == yes ]]; then
        print_check fail 'Failure' "$*"
    else
        printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$*" > "$TTY_OUT"
    fi
}



find_next_custom_port () 
{ 
    local port;
    for ((port=PROFILE_PORT_FIRST; port<=PROFILE_PORT_MAX; port++))
    do
        custom_port_available "$port" && { 
            printf '%s' "$port";
            return 0
        };
    done;
    for ((port=PROFILE_PORT_MIN; port<PROFILE_PORT_FIRST; port++))
    do
        custom_port_available "$port" && { 
            printf '%s' "$port";
            return 0
        };
    done;
    return 1
}

fit_text () 
{ 
    local value="$1" width="$2";
    if ((${#value} <= width)); then
        printf '%s' "$value";
    else
        if ((width > 3)); then
            printf '%s...' "${value:0:width-3}";
        else
            printf '%s' "${value:0:width}";
        fi;
    fi
}

# DFR_HISTORY_WRAPPED_COLUMNS
history_wrap_lines ()
{
    local value="${1:-}"
    local width="${2:-1}"

    [[ "$width" =~ ^[0-9]+$ ]] || width=1
    (( width > 0 )) || width=1

    if [[ -z "$value" ]]; then
        printf '\n'
        return 0
    fi

    printf '%s\n' "$value" | fold -s -w "$width"
}



format_bytes_short () 
{ 
    local value="${1:-0}";
    [[ "$value" =~ ^[0-9]+$ ]] || value=0;
    if command -v numfmt > /dev/null 2>&1; then
        numfmt --to=iec --suffix=B "$value" 2> /dev/null || printf '%sB' "$value";
    else
        printf '%sB' "$value";
    fi
}

format_seconds_short () 
{ 
    local value="${1:-0}" seconds days hours minutes output='';
    value=${value%s};
    [[ "$value" =~ ^[0-9]+$ ]] || { 
        printf '-';
        return
    };
    seconds=$value;
    days=$((seconds / 86400));
    seconds=$((seconds % 86400));
    hours=$((seconds / 3600));
    seconds=$((seconds % 3600));
    minutes=$((seconds / 60));
    seconds=$((seconds % 60));
    ((days > 0)) && output+="${days}d";
    ((hours > 0)) && output+="${hours}h";
    ((minutes > 0)) && output+="${minutes}m";
    [[ -z "$output" || "$seconds" -gt 0 ]] && output+="${seconds}s";
    printf '%s' "$output"
}


hub_configured () 
{ 
    [[ -f "$HOST_CONFIG_FILE" ]]
}

hub_connectivity_tests ()
{
    local mode="${1:-standalone}"
    load_host_config
    if [[ "$mode" != embedded ]]; then
        clear_screen
        dfr_ui_header 'SERVER CONNECTIVITY TESTS'
    fi
    section_title 'Server Internet, DNS and active client tests'
    local failures=0 gateway observed answer name peer_failures=0;
    gateway=$(detect_default_gateway || true);
    if [[ -n "$gateway" ]] && ping_from_source "$WAN_IF" "$gateway"; then
        print_check pass 'Default gateway ping' "$gateway responds on $WAN_IF";
    else
        if [[ -n "$gateway" ]]; then
            print_check fail 'Default gateway ping' "$gateway did not respond on $WAN_IF";
            failures=$((failures + 1));
        else
            print_check warn 'Default gateway ping' 'No gateway address was detected';
        fi;
    fi;
    if ping_from_source "$LOCAL_IP" 1.1.1.1; then
        print_check pass 'Public Internet ping' '1.1.1.1 responds from the Server WAN address';
    else
        print_check fail 'Public Internet ping' '1.1.1.1 did not respond from the Server WAN address';
        failures=$((failures + 1));
    fi;
    if answer=$(dns_query_from_source "$LOCAL_IP" "$DEFAULT_DNS_PRIMARY"); then
        print_check pass 'Primary upstream DNS' "$DEFAULT_DNS_PRIMARY returned $answer";
    else
        print_check fail 'Primary upstream DNS' "$DEFAULT_DNS_PRIMARY did not answer from the Server";
        failures=$((failures + 1));
    fi;
    if answer=$(dns_query_from_source "$LOCAL_IP" "$DEFAULT_DNS_SECONDARY"); then
        print_check pass 'Secondary upstream DNS' "$DEFAULT_DNS_SECONDARY returned $answer";
    else
        print_check fail 'Secondary upstream DNS' "$DEFAULT_DNS_SECONDARY did not answer from the Server";
        failures=$((failures + 1));
    fi;
    observed=$(detect_public_ipv4 || true);
    if [[ -n "$observed" ]]; then
        [[ "$observed" == "$PUBLIC_IP" ]] && print_check pass 'Advertised public IPv4' "$observed" accent || print_check warn 'Advertised public IPv4' "observed $observed; configured $PUBLIC_IP";
    else
        print_check warn 'Advertised public IPv4' 'External lookup failed';
    fi;
    section_title 'Per-connection tunnel peer pings';
    if [[ "$(profile_count)" -eq 0 ]]; then
        print_check info 'Client connections' 'No Client connections exist yet.';
    else
        while IFS= read -r name; do
            [[ -n "$name" ]] || continue;
            collect_client_runtime "$name";
            if [[ "$SNAP_IKE" != ESTABLISHED || "$SNAP_CHILD" != INSTALLED ]]; then
                print_check warn "$name" 'No active IKE/CHILD session; peer ping skipped';
                continue;
            fi;
            if ping_from_source "$SNAP_XFRM" "$SNAP_REMOTE_TUNNEL"; then
                print_check pass "$name" "$SNAP_REMOTE_TUNNEL responds through $SNAP_XFRM";
            else
                print_check fail "$name" "$SNAP_REMOTE_TUNNEL is unreachable through $SNAP_XFRM";
                peer_failures=$((peer_failures + 1));
            fi;
        done < <(profile_names);
    fi;
    failures=$((failures + peer_failures));
    section_title 'Result';
    if ((failures == 0)); then
        printf '  %s%sPASS%s  Server WAN, upstream DNS and active Client peer tests succeeded.\n' "$C_BOLD" "$C_GREEN" "$C_RESET" > "$TTY_OUT";
        return 0;
    fi;
    printf '  %s%sFAIL%s  %d Server or Client peer tests failed.\n' "$C_BOLD" "$C_RED" "$C_RESET" "$failures" > "$TTY_OUT";
    return 1
}

client_connections_workspace ()
{
    local choice selected snapshot
    while hub_configured; do
        clear_screen
        dfr_ui_header 'CONNECTIONS'
        snapshot=$(fleet_snapshot_file 2>/dev/null || true)
        [[ -n "$snapshot" ]] && fleet_print_compact_summary "$snapshot"
        section_title 'Connection Management'
        ui_menu_item 1 'Add Connection' positive
        ui_menu_item 2 'Browse / Search Connections' neutral
        ui_menu_item 3 'Client Alerts' caution
        ui_menu_item R 'Refresh' neutral
        ui_navigation_footer
        choice=$(prompt '  Select an option: ') || return 0
        case "$choice" in
            1) add_client_interactive; pause_screen ;;
            2) selected=$(select_client_interactive) && manage_client_menu "$selected" ;;
            3) selected=$(select_client_interactive attention) && manage_client_menu "$selected" ;;
            r|R|9) continue ;;
            g|G|90) ui_global_navigation ;;
            b|B|0) return 0 ;;
            q|Q|99) exit 0 ;;
            *) warn 'Invalid selection.'; sleep 0.35 ;;
        esac
    done
}

managed_software_state_display ()
{
    case "${1:-}" in
        APPLYING) printf 'INSTALLING' ;;
        ROLLED_BACK) printf 'ROLLED BACK' ;;
        '') printf 'UNKNOWN' ;;
        *) printf '%s' "$1" ;;
    esac
}

endpoint_state_color ()
{
    semantic_state_color "${1:-UNKNOWN}"
}



endpoint_transition_json ()
{
    registry_command server-endpoint-status --json 2>/dev/null || printf '{}'
}




change_server_endpoint ()
{
    local old_endpoint new_endpoint resolved count snapshot name file failed=no detected_public
    load_host_config; old_endpoint="$SERVER_ENDPOINT"; detected_public=$(detect_public_ipv4 || true); [[ -n "$detected_public" ]] || detected_public="$PUBLIC_IP"
    clear_screen; dfr_ui_header 'SERVER ENDPOINT'; section_title 'Change Server Endpoint'
    print_check info 'Current endpoint' "$old_endpoint" accent; print_check info 'Detected public IPv4' "$detected_public" accent
    printf '\n  Valid targets are a public IPv4 address or an FQDN resolving to this Server.\n  Online compatible Clients converge through authenticated CONTROL/1.\n\n' > "$TTY_OUT"
    new_endpoint=$(prompt '  New Server endpoint (IPv4 or FQDN, 0 to cancel): '); [[ "$new_endpoint" == 0 ]] && return 0; new_endpoint=$(normalize_server_endpoint "$new_endpoint")
    validate_server_endpoint "$new_endpoint" || { warn 'Enter a valid public IPv4 address or FQDN.'; return 1; }
    [[ "$new_endpoint" == "$old_endpoint" ]] && { print_check info 'Server endpoint' 'No change requested.'; return 0; }
    if validate_ipv4 "$new_endpoint"; then
        [[ "$new_endpoint" == "$detected_public" ]] || { error "${new_endpoint} does not match the detected public IPv4 ${detected_public}."; return 1; }
    else
        resolved=$(resolve_endpoint_ipv4s "$new_endpoint" || true); count=$(grep -c . <<<"$resolved" || true); [[ "$count" -eq 1 ]] || { error "${new_endpoint} must resolve to exactly one IPv4 address; found ${count}."; return 1; }; [[ "$resolved" == "$detected_public" ]] || { error "${new_endpoint} resolves to ${resolved}, but this Server is ${detected_public}."; return 1; }; print_check pass 'DNS validation' "${new_endpoint} -> ${resolved}"
    fi
    confirm "Change the Server endpoint from ${old_endpoint} to ${new_endpoint}" no || return 0
    snapshot="${STATE_DIR}/endpoint-snapshots/$(date -u +%Y%m%dT%H%M%SZ)"; install -d -m 0700 "$snapshot/clients"; cp -a "$HOST_CONFIG_FILE" "$snapshot/hub.conf"
    while IFS= read -r name; do [[ -n "$name" ]] || continue; file=$(profile_config_file "$name"); [[ -f "$file" ]] && cp -a "$file" "$snapshot/clients/${name}.conf"; done < <(profile_names)
    SERVER_ENDPOINT="$new_endpoint"; PUBLIC_IP="$detected_public"; write_hub_host_config
    while IFS= read -r name; do [[ -n "$name" ]] || continue; file=$(profile_config_file "$name"); upsert_shell_assignment "$file" SERVER_ENDPOINT "$new_endpoint" || failed=yes; done < <(profile_names)
    if [[ "$failed" == yes ]] || ! registry_command server-endpoint-set "$new_endpoint" >/dev/null; then
        install -m 0600 "$snapshot/hub.conf" "$HOST_CONFIG_FILE"; while IFS= read -r name; do [[ -f "$snapshot/clients/${name}.conf" ]] && install -m 0600 "$snapshot/clients/${name}.conf" "$(profile_config_file "$name")"; done < <(profile_names); error 'Endpoint update failed; previous Server configuration was restored.'; return 1
    fi
    while IFS= read -r name; do [[ -n "$name" ]] && rm -f -- "$(profile_dir "$name")/pairing-token.txt"; done < <(profile_names)
    section_title 'Client delivery path'
    if refresh_client_management_plane; then
        print_check pass 'Endpoint delivery' 'The management plane is ready for Client synchronization.'
    else
        print_check warn 'Endpoint delivery' 'The endpoint is saved, but one or more active Client management paths require attention.'
    fi
    registry_command server-endpoint-reconcile >/dev/null 2>&1 || warn 'Endpoint work could not be reconciled immediately.'
    success "Server endpoint changed to ${new_endpoint}."; print_check info 'Recovery snapshot' "$snapshot" identity; server_endpoint_sync_summary
}

server_health_report ()
{
    local resolved count unit name rules status_color listener_color rules_color managed_color managed_health

    clear_screen
    dfr_ui_header 'SERVER HEALTH CHECK'
    hub_runtime_overview

    section_title 'Server endpoint'
    load_host_config
    if validate_ipv4 "$SERVER_ENDPOINT"; then
        if [[ "$SERVER_ENDPOINT" == "$PUBLIC_IP" ]]; then
            print_check pass 'IPv4 endpoint' "${SERVER_ENDPOINT} (direct; DNS disabled)"
        else
            print_check fail 'IPv4 endpoint' "${SERVER_ENDPOINT}; detected public IPv4 is ${PUBLIC_IP}"
        fi
    else
        resolved=$(resolve_endpoint_ipv4s "$SERVER_ENDPOINT" || true)
        count=$(grep -c . <<<"$resolved" || true)
        if [[ "$count" -eq 1 && "$resolved" == "$PUBLIC_IP" ]]; then
            print_check pass 'FQDN endpoint' "${SERVER_ENDPOINT} -> ${resolved}"
        else
            print_check fail 'FQDN endpoint' "${SERVER_ENDPOINT} -> ${resolved:-no public IPv4}; expected ${PUBLIC_IP}"
        fi
    fi

    section_title 'Management services'
    for unit in "$REGISTRY_UNIT" "$CONTROL_UNIT" "$SUBSCRIPTION_UNIT"; do
        if systemctl is-active --quiet "$unit"; then
            print_check pass "$unit" active
        else
            print_check fail "$unit" "$(systemctl is-active "$unit" 2>/dev/null || printf inactive)"
        fi
    done

    hub_connectivity_tests embedded || true

    section_title 'Client runtime integration'
    printf '  %s%-20s %-13s %-11s %-12s %s%s\n' \
        "$C_DIM" 'CLIENT' 'STATE' 'LISTENER' 'RULES' 'MANAGED HEALTH' "$C_RESET" > "$TTY_OUT"
    printf '  %s%-20s %-13s %-11s %-12s %s%s\n' \
        "$C_DIM" '--------------------' '-------------' '-----------' '------------' '----------------' "$C_RESET" > "$TTY_OUT"

    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        collect_client_runtime "$name"
        load_host_config
        load_client_profile "$name"
        rules='OK'
        iptables -C FORWARD -i "$XFRM_IF" -o "$WAN_IF" -s "$INGRESS_XFRM_IP/32" -m comment --comment "$(client_rule_comment "$name" forward-out)" -j ACCEPT 2>/dev/null || rules='MISSING'
        iptables -C FORWARD -i "$WAN_IF" -o "$XFRM_IF" -d "$INGRESS_XFRM_IP/32" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "$(client_rule_comment "$name" forward-return)" -j ACCEPT 2>/dev/null || rules='MISSING'
        iptables -t nat -C POSTROUTING -s "$INGRESS_XFRM_IP/32" -o "$WAN_IF" -m comment --comment "$(client_rule_comment "$name" nat)" -j MASQUERADE 2>/dev/null || rules='MISSING'
        iptables -C INPUT -i "$XFRM_IF" -s "$INGRESS_XFRM_IP/32" -d "$EGRESS_XFRM_IP/32" -p tcp -m multiport --dports "${SUBSCRIPTION_PORT},${CONTROL_PORT}" -m comment --comment "$(client_rule_comment "$name" management-in)" -j ACCEPT 2>/dev/null || rules='MISSING'
        iptables -C OUTPUT -o "$XFRM_IF" -s "$EGRESS_XFRM_IP/32" -d "$INGRESS_XFRM_IP/32" -p tcp -m multiport --sports "${SUBSCRIPTION_PORT},${CONTROL_PORT}" -m conntrack --ctstate ESTABLISHED -m comment --comment "$(client_rule_comment "$name" management-out)" -j ACCEPT 2>/dev/null || rules='MISSING'
        if [[ "$SNAP_SERVICE" == active ]] && ! client_management_listeners_ready "$name"; then rules='MGMT DOWN'; fi
        managed_health=$(management_field "$name" health 2>/dev/null || printf '-')
        status_color=$(status_color_for "$SNAP_STATUS")
        listener_color=$(semantic_state_color "${SNAP_LISTENER^^}")
        rules_color=$(semantic_state_color "${rules^^}")
        managed_color=$(semantic_state_color "${managed_health^^}")
        printf '  %-20s %s%-13s%s %s%-11s%s %s%-12s%s %s%s%s\n' \
            "$(fit_text "$name" 20)" "$status_color" "$SNAP_STATUS" "$C_RESET" \
            "$listener_color" "$SNAP_LISTENER" "$C_RESET" \
            "$rules_color" "$rules" "$C_RESET" \
            "$managed_color" "$managed_health" "$C_RESET" > "$TTY_OUT"
    done < <(profile_names)

    server_endpoint_sync_summary
}

server_endpoint_workspace ()
{
    local choice result status_json safe fallback_count migration_state management_ok blocking enrolled synced

    while hub_configured; do
        clear_screen
        dfr_ui_header 'SERVER ENDPOINT'
        status_json=$(endpoint_transition_json)
        server_endpoint_sync_summary "$status_json"
        fallback_count=${SERVER_ENDPOINT_UI_FALLBACK_COUNT:-0}
        safe=${SERVER_ENDPOINT_UI_SAFE:-no}
        migration_state=${SERVER_ENDPOINT_UI_MIGRATION_STATE:-IDLE}
        blocking=${SERVER_ENDPOINT_UI_BLOCKING:-0}
        enrolled=${SERVER_ENDPOINT_UI_ENROLLED:-0}
        synced=${SERVER_ENDPOINT_UI_SYNCED:-0}

        section_title 'Operations'
        case "$migration_state" in
            ACTIVE) ui_menu_item 1 'Synchronize pending Clients now' positive ;;
            'READY TO FINISH') ui_menu_item 1 'Verify synchronized Clients now' neutral ;;
            *)
                if (( blocking > 0 )); then ui_menu_item 1 'Synchronize Client endpoint drift now' positive
                else ui_menu_item 1 'Verify Client endpoint synchronization' neutral; fi
                ;;
        esac
        ui_menu_item 2 'Change Server endpoint (IPv4 or FQDN)' neutral
        if (( fallback_count > 0 )) && [[ "$safe" == yes ]]; then
            ui_menu_item 3 'Finish migration after handling previous endpoint' positive
        fi
        ui_navigation_footer

        choice=$(prompt '  Select an option: ')
        case "$choice" in
            1)
                clear_screen
                dfr_ui_header 'SERVER ENDPOINT | SYNCHRONIZATION'
                section_title 'Management-plane verification'
                management_ok=yes
                refresh_client_management_plane || management_ok=no

                section_title 'Endpoint reconciliation'
                result=$(registry_command server-endpoint-reconcile 2>/dev/null || true)
                if [[ -n "$result" ]]; then
                    readarray -t _endpoint_retry < <(python3 - "$result" <<'PY_ENDPOINT_RETRY_RESULT'
import json,sys
try: d=json.loads(sys.argv[1])
except Exception: d={}
q=d.get('queue') or {}
print(q.get('queued_updates') or 0)
print(q.get('queued_refreshes') or 0)
print(q.get('already_queued') or 0)
print(q.get('manual_clients') or 0)
print(q.get('release_missing_clients') or 0)
print(q.get('failed_clients') or 0)
print(d.get('errors_cleared') or 0)
s=d.get('status') or {}
print(s.get('blocking_clients') or 0)
print(s.get('migration_state') or 'IDLE')
PY_ENDPOINT_RETRY_RESULT
)
                    print_check pass 'Synchronization' 'Endpoint state was reconciled against the active Server endpoint.'
                    print_check info 'Software updates queued' "${_endpoint_retry[0]:-0}"
                    print_check info 'Runtime refreshes queued' "${_endpoint_retry[1]:-0}"
                    [[ "${_endpoint_retry[2]:-0}" == 0 ]] || print_check info 'Already in progress' "${_endpoint_retry[2]} Clients"
                    [[ "${_endpoint_retry[3]:-0}" == 0 ]] || print_check warn 'Manual updates required' "${_endpoint_retry[3]} Clients"
                    [[ "${_endpoint_retry[4]:-0}" == 0 ]] || print_check warn 'Compatible release missing' "${_endpoint_retry[4]} Clients"
                    [[ "${_endpoint_retry[5]:-0}" == 0 ]] || print_check warn 'Failed updates requeued' "${_endpoint_retry[5]} Clients"
                    [[ "${_endpoint_retry[6]:-0}" == 0 ]] || print_check info 'Previous errors cleared' "${_endpoint_retry[6]}"
                    blocking=${_endpoint_retry[7]:-0}
                    migration_state=${_endpoint_retry[8]:-IDLE}
                else
                    print_check fail 'Synchronization' 'Registry reconciliation failed.'
                    blocking=1
                fi

                if (( blocking > 0 )); then
                    print_check info 'Client delivery' 'Observing one CONTROL polling window (up to 15 seconds)...'
                    local elapsed=0 remaining="$blocking" final_json
                    while (( elapsed < 15 && remaining > 0 )); do
                        sleep 2
                        elapsed=$((elapsed+2))
                        final_json=$(endpoint_transition_json)
                        remaining=$(python3 - "$final_json" <<'PY_ENDPOINT_BLOCKING'
import json,sys
try:d=json.loads(sys.argv[1])
except Exception:d={}
print(int(d.get('blocking_clients') or 0))
PY_ENDPOINT_BLOCKING
)
                    done
                    registry_command server-endpoint-reconcile >/dev/null 2>&1 || true
                    final_json=$(endpoint_transition_json)
                    readarray -t _endpoint_final < <(python3 - "$final_json" <<'PY_ENDPOINT_FINAL'
import json,sys
try:d=json.loads(sys.argv[1])
except Exception:d={}
print(int(d.get('blocking_clients') or 0))
print(d.get('migration_state') or 'IDLE')
print(len(d.get('fallback_server_endpoints') or []))
PY_ENDPOINT_FINAL
)
                    blocking=${_endpoint_final[0]:-0}; migration_state=${_endpoint_final[1]:-IDLE}; fallback_count=${_endpoint_final[2]:-0}
                fi

                if (( blocking == 0 )); then
                    if [[ "$migration_state" == 'READY TO FINISH' ]]; then
                        print_check pass 'Endpoint convergence' 'Every enrolled Client is synchronized. Previous endpoint tracking is retained until Finish migration.'
                    else
                        print_check pass 'Endpoint convergence' 'Every enrolled Client reports the active Server endpoint.'
                    fi
                else
                    print_check warn 'Endpoint convergence' "$blocking Client(s) still require synchronization; stopped/offline Clients remain deferred."
                fi
                [[ "$management_ok" == yes ]] || print_check warn 'Management plane' 'One or more active Client management paths still require repair.'
                pause_screen
                ;;
            2)
                change_server_endpoint || true
                pause_screen
                ;;
            3)
                if (( fallback_count == 0 )) || [[ "$safe" != yes ]]; then
                    warn 'The retained previous endpoint is not ready to retire.'
                    sleep 0.35
                    continue
                fi
                printf '\n  Remove or intentionally retain the listed previous endpoint(s) only after every Client has converged.\n' > "$TTY_OUT"
                printf '  This action clears DFR previous-endpoint tracking; the active endpoint and Client state remain unchanged.\n\n' > "$TTY_OUT"
                if confirm "Finish migration and clear ${fallback_count} retained previous endpoint entries" no; then
                    if registry_command server-endpoint-retire-previous >/dev/null; then
                        success 'Endpoint migration finished. The active Server endpoint remains authoritative and synchronization returns to IDLE.'
                    else
                        warn 'Previous-endpoint tracking could not be cleared.'
                    fi
                    pause_screen
                fi
                ;;
            g|G|90) ui_global_navigation ;;
            b|B|0) return 0 ;;
            q|Q|99) exit 0 ;;
            *) warn 'Invalid selection.'; sleep 0.35 ;;
        esac
    done
}

server_operations_workspace ()
{
    local choice
    while hub_configured; do
        load_host_config
        clear_screen
        dfr_ui_header 'SERVER OPERATIONS'
        server_operations_overview
        section_title 'Server Operations'
        ui_menu_item 1 'Detailed Server Health' positive
        ui_menu_item 2 'Runtime & Services' neutral
        ui_menu_item 3 'Server Configuration' neutral
        ui_menu_item 5 'Client Software' neutral
        ui_menu_item 6 'Backups & Recovery' neutral
        ui_menu_item 7 'Server Logs' neutral

        section_title 'Fleet Actions'
        ui_menu_item 8 'Start All Connections' positive
        ui_menu_item 9 'Stop All Connections Temporarily' caution
        ui_menu_item 10 'Repair All Connection Configurations' neutral
        ui_navigation_footer
        choice=$(prompt '  Select an option: ') || return 0
        case "$choice" in
            1) server_health_report; pause_screen ;;
            2) server_runtime_services_screen; pause_screen ;;
            3) server_configuration_workspace ;;
            5) ingress_release_workspace ;;
            6) backup_workspace ;;
            7) hub_history_screen ;;
            8) start_all_clients || warn 'One or more connections could not be started.'; pause_screen ;;
            9) stop_all_clients || warn 'One or more connections could not be stopped.'; pause_screen ;;
            10) repair_all_clients || warn 'One or more connection configurations could not be repaired.'; pause_screen ;;
            g|G|90) ui_global_navigation ;;
            b|B|0) return 0 ;;
            q|Q|99) exit 0 ;;
            *) warn 'Invalid selection.'; sleep 0.35 ;;
        esac
    done
}

hub_diagnostics_menu ()
{
    server_operations_workspace
}


hub_health_overview ()
{
    server_health_report
}


attention_client_summary_rows ()
{
    local snapshot="$1" filter="${2:-all}" search="${3:-}" offset="${4:-0}" limit="${5:-4}"
    python3 - "$snapshot" "$filter" "$search" "$offset" "$limit" <<'PY_ATTN_SUMMARY_ROWS'
import json,re,sys
D=json.load(open(sys.argv[1], encoding='utf-8')); mode=sys.argv[2]; query=sys.argv[3].strip().lower(); offset=max(0,int(sys.argv[4])); limit=max(0,int(sys.argv[5]))
rank={'CRITICAL':0,'WARNING':1,'ADVISORY':2}
def nat(v): return [int(x) if x.isdigit() else x.lower() for x in re.split(r'(\d+)',str(v))]
def keep(x):
    if mode=='all': return True
    if ':' not in mode: return True
    kind,value=mode.split(':',1)
    area=str(x.get('area','')).upper(); severity=str(x.get('severity','')).upper()
    if kind=='severity': return severity==value
    if kind=='area': return area==value
    if mode=='group:ENDPOINT': return area in ('ENDPOINT','CONFIGURATION','CONTROL')
    if mode=='group:POLICY': return area == 'SUBSCRIPTION'
    return True
def clean(v): return str(v if v not in (None,'') else '-').replace('\t',' ').replace('\n',' ')
groups={}
for x in D.get('attention') or []:
    if not keep(x): continue
    name=clean(x.get('connection_name')); uuid=clean(x.get('uuid_short'))
    if query and query not in name.lower() and query not in uuid.lower(): continue
    groups.setdefault((name,uuid),[]).append(x)
ordered=[]
for (name,uuid),items in groups.items():
    items.sort(key=lambda x:(rank.get(str(x.get('severity','')).upper(),9),str(x.get('area','')),str(x.get('headline',''))))
    sev=str(items[0].get('severity','ADVISORY')).upper()
    areas=[]
    for x in items:
        area=str(x.get('area','')).upper()
        if area and area not in areas: areas.append(area)
    ordered.append((rank.get(sev,9),nat(name),uuid,sev,name,uuid,len(items),' / '.join(areas),clean(items[0].get('headline'))))
ordered.sort(key=lambda x:(x[0],x[1],x[2]))
for row in ordered[offset:offset+limit] if limit else []:
    print('\t'.join(clean(v) for v in row[3:]))
PY_ATTN_SUMMARY_ROWS
}

print_attention_client_summary_table ()
{
    local snapshot="$1" limit="${2:-4}" filter="${3:-all}" search="${4:-}"
    local cols severity name uuid issues areas primary color primary_width
    cols=$(ui_terminal_columns)

    if ((cols >= 110)); then
        primary_width=$((cols-79))
        ((primary_width < 24)) && primary_width=24
        printf '  %s%-18s  %-12s  %-9s  %-6s  %-20s  %s%s\n' "$C_DIM" 'CONNECTION' 'UUID' 'LEVEL' 'ISSUES' 'AREAS' 'PRIMARY ISSUE' "$C_RESET" > "$TTY_OUT"
        printf '  %s%-18s  %-12s  %-9s  %-6s  %-20s  %s%s\n' "$C_DIM" '──────────────────' '────────────' '─────────' '──────' '────────────────────' '────────────────────────' "$C_RESET" > "$TTY_OUT"
        while IFS=$'\t' read -r severity name uuid issues areas primary; do
            [[ -n "$name" ]] || continue
            color=$(semantic_state_color "$severity")
            printf '  %s%-18s%s  %s%-12s%s  %s%-9s%s  %-6s  %-20s  %s\n' \
                "$C_RESET" "$(fit_text "$name" 18)" "$C_RESET" "$C_DIM" "$(fit_text "$uuid" 12)" "$C_RESET" \
                "$color" "$(fit_text "$severity" 9)" "$C_RESET" "$issues" "$(fit_text "$areas" 20)" "$(fit_text "$primary" "$primary_width")" > "$TTY_OUT"
        done < <(attention_client_summary_rows "$snapshot" "$filter" "$search" 0 "$limit")
    else
        primary_width=$((cols-60))
        ((primary_width < 20)) && primary_width=20
        printf '  %s%-16s  %-12s  %-8s  %-6s  %s%s\n' "$C_DIM" 'CONNECTION' 'UUID' 'LEVEL' 'ISSUES' 'PRIMARY ISSUE' "$C_RESET" > "$TTY_OUT"
        printf '  %s%-16s  %-12s  %-8s  %-6s  %s%s\n' "$C_DIM" '────────────────' '────────────' '────────' '──────' '────────────────────────' "$C_RESET" > "$TTY_OUT"
        while IFS=$'\t' read -r severity name uuid issues areas primary; do
            [[ -n "$name" ]] || continue
            color=$(semantic_state_color "$severity")
            printf '  %s%-16s%s  %s%-12s%s  %s%-8s%s  %-6s  %s\n' \
                "$C_RESET" "$(fit_text "$name" 16)" "$C_RESET" "$C_DIM" "$(fit_text "$uuid" 12)" "$C_RESET" \
                "$color" "$(fit_text "$severity" 8)" "$C_RESET" "$issues" "$(fit_text "$primary" "$primary_width")" > "$TTY_OUT"
        done < <(attention_client_summary_rows "$snapshot" "$filter" "$search" 0 "$limit")
    fi
}

attention_client_group_meta ()
{
    local snapshot="$1" filter="${2:-all}" search="${3:-}" page="${4:-1}" size="${5:-3}"
    python3 - "$snapshot" "$filter" "$search" "$page" "$size" <<'PY_ATTN_GROUP_META'
import json,sys
D=json.load(open(sys.argv[1], encoding='utf-8')); mode=sys.argv[2]; query=sys.argv[3].strip().lower(); page=max(1,int(sys.argv[4])); size=max(1,int(sys.argv[5]))
def keep(x):
    if mode=='all': return True
    if ':' not in mode: return True
    kind,value=mode.split(':',1)
    area=str(x.get('area','')).upper(); severity=str(x.get('severity','')).upper()
    if kind=='severity': return severity==value
    if kind=='area': return area==value
    if mode=='group:ENDPOINT': return area in ('ENDPOINT','CONFIGURATION','CONTROL')
    if mode=='group:POLICY': return area == 'SUBSCRIPTION'
    return True
rows=[]
for x in D.get('attention') or []:
    if not keep(x): continue
    name=str(x.get('connection_name') or ''); uuid=str(x.get('uuid_short') or '')
    if query and query not in name.lower() and query not in uuid.lower(): continue
    rows.append(x)
clients=len({str(x.get('connection_name','')) for x in rows})
pages=max(1,(clients+size-1)//size); page=min(page,pages)
print(f'{page}\t{pages}\t{clients}\t{len(rows)}')
PY_ATTN_GROUP_META
}

attention_client_group_pick ()
{
    local snapshot="$1" filter="$2" search="$3" page="$4" size="$5" pick="$6"
    python3 - "$snapshot" "$filter" "$search" "$page" "$size" "$pick" <<'PY_ATTN_GROUP_PICK'
import json,re,sys
D=json.load(open(sys.argv[1], encoding='utf-8')); mode=sys.argv[2]; query=sys.argv[3].strip().lower(); page=max(1,int(sys.argv[4])); size=max(1,int(sys.argv[5])); pick=int(sys.argv[6])
rank={'CRITICAL':0,'WARNING':1,'ADVISORY':2}
def nat(v): return [int(x) if x.isdigit() else x.lower() for x in re.split(r'(\d+)',str(v))]
def keep(x):
    if mode=='all': return True
    if ':' not in mode: return True
    kind,value=mode.split(':',1)
    area=str(x.get('area','')).upper(); severity=str(x.get('severity','')).upper()
    if kind=='severity': return severity==value
    if kind=='area': return area==value
    if mode=='group:ENDPOINT': return area in ('ENDPOINT','CONFIGURATION','CONTROL')
    if mode=='group:POLICY': return area == 'SUBSCRIPTION'
    return True
groups={}
for x in D.get('attention') or []:
    if not keep(x): continue
    name=str(x.get('connection_name') or ''); uuid=str(x.get('uuid_short') or '')
    if query and query not in name.lower() and query not in uuid.lower(): continue
    groups.setdefault((name,uuid),[]).append(x)
ordered=[]
for (name,uuid),items in groups.items():
    sev=min((str(x.get('severity','ADVISORY')).upper() for x in items),key=lambda z:rank.get(z,9))
    ordered.append((rank.get(sev,9),nat(name),uuid,name))
ordered.sort()
part=ordered[(page-1)*size:page*size]
if 1<=pick<=len(part): print(part[pick-1][3])
PY_ATTN_GROUP_PICK
}

operations_center_overview ()
{
    local snapshot="$1" total operational ready stopped degraded failed online stale offline never_seen attention critical warning advisory work
    local attention_clients attention_issues work_clients work_items
    local name uuid issue_count areas headline cols detail_width when connection action detail event event_color

    IFS=$'\t' read -r total operational ready stopped degraded failed online stale offline never_seen attention critical warning advisory work \
        < <(fleet_summary_line "$snapshot")
    IFS=$'\t' read -r attention_clients attention_issues work_clients work_items \
        < <(fleet_ops_client_summary_line "$snapshot")

    fleet_print_compact_summary "$snapshot"

    section_title 'Client Alerts'
    if ((attention_clients == 0)); then
        ui_summary_row 'Status' 'No active alerts' muted
    else
        print_attention_client_summary_table "$snapshot" 4
        if ((attention_clients > 4)); then
            printf '  %s+ %s more clients need attention · Open [1] Client Alerts for the full queue.%s\n' \
                "$C_DIM" "$((attention_clients-4))" "$C_RESET" > "$TTY_OUT"
        fi
    fi

    section_title 'Active Work'
    if ((work_items == 0)); then
        ui_summary_row 'Status' 'No active work' muted
    else
        local work_output work_cols work_conn_width work_uuid_width work_count_width work_areas_width work_desc_width
        work_output=$(python3 - "$snapshot" <<'PY_OPS_WORK_CLIENTS'
import json,re,sys
D=json.load(open(sys.argv[1], encoding='utf-8'))
def nat(v): return [int(x) if x.isdigit() else x.lower() for x in re.split(r'(\d+)',str(v))]
def clean(v): return str(v if v not in (None,'') else '-').replace('\t',' ').replace('\n',' ')
g={}
for x in D.get('active_work') or []:
    name=clean(x.get('connection_name'))
    q=g.setdefault(name,{'uuid':clean(x.get('uuid_short')),'items':[]})
    q['items'].append(x)
for name,q in sorted(g.items(),key=lambda kv:nat(kv[0]))[:4]:
    areas=[]
    for x in q['items']:
        area=clean(x.get('area')).upper()
        if area not in areas:
            areas.append(area)
    first=clean(q['items'][0].get('headline'))
    extra=len(q['items'])-1
    if extra > 0:
        first=f'{first} (+{extra} more)'
    vals=(name,q['uuid'],len(q['items']),' / '.join(areas),first)
    print('\t'.join(clean(v) for v in vals))
PY_OPS_WORK_CLIENTS
)
        work_cols=$(ui_content_width)
        if ((work_cols >= 116)); then
            work_conn_width=18; work_uuid_width=12; work_count_width=6; work_areas_width=22
        elif ((work_cols >= 94)); then
            work_conn_width=16; work_uuid_width=10; work_count_width=6; work_areas_width=18
        else
            work_conn_width=14; work_uuid_width=8; work_count_width=6; work_areas_width=13
        fi
        work_desc_width=$((work_cols-work_conn_width-work_uuid_width-work_count_width-work_areas_width-12))
        ((work_desc_width < 14)) && work_desc_width=14

        printf '  %s%-*s | %-*s | %-*s | %-*s | %s%s\n' \
            "$C_DIM" "$work_conn_width" 'CONNECTION' "$work_uuid_width" 'UUID' \
            "$work_count_width" 'ACTIVE' "$work_areas_width" 'AREAS' 'WORK' "$C_RESET" > "$TTY_OUT"
        printf '  %s%s%s\n' "$C_DIM" "$(ui_rule $'─' "$work_cols")" "$C_RESET" > "$TTY_OUT"
        while IFS=$'\t' read -r name uuid issue_count areas headline; do
            [[ -n "$name" ]] || continue
            printf '  %s%-*s%s %s|%s %s%-*s%s %s|%s %s%-*s%s %s|%s %-*s %s|%s ' \
                "$C_RESET" "$work_conn_width" "$(fit_text "$name" "$work_conn_width")" "$C_RESET" \
                "$C_DIM" "$C_RESET" "$C_DIM" "$work_uuid_width" "$(fit_text "$uuid" "$work_uuid_width")" "$C_RESET" \
                "$C_DIM" "$C_RESET" "$C_RESET" "$work_count_width" "$(fit_text "$issue_count" "$work_count_width")" "$C_RESET" \
                "$C_DIM" "$C_RESET" "$work_areas_width" "$(fit_text "$areas" "$work_areas_width")" \
                "$C_DIM" "$C_RESET" > "$TTY_OUT"
            semantic_colorize_line "$(fit_text "$headline" "$work_desc_width")" > "$TTY_OUT"
            printf '\n' > "$TTY_OUT"
        done <<<"$work_output"
        if ((work_clients > 4)); then
            printf '  %s+ %s more clients have active work.%s\n' \
                "$C_DIM" "$((work_clients-4))" "$C_RESET" > "$TTY_OUT"
        fi
    fi

    section_title 'Recent Logs'
    local preview_output
    preview_output=$(python3 - "$snapshot" <<'PY_OPS_ACTIVITY'
import datetime as dt,json,sys
D=json.load(open(sys.argv[1], encoding='utf-8'))
for x in (D.get('recent_activity') or [])[:6]:
    ts=int(x.get('occurred_at') or 0)
    when=dt.datetime.fromtimestamp(ts).strftime('%m-%d %H:%M:%S') if ts else '-'
    vals=(when,x.get('connection_name') or 'SERVER',x.get('action') or '-',x.get('detail') or '-')
    print('\t'.join(str(v).replace('\t',' ').replace('\n',' ') for v in vals))
PY_OPS_ACTIVITY
)
    IFS=$'\t' read -r connection_width event_width detail_width < <(activity_table_widths "$preview_output")
    # The preview omits the row-number column, so donate that saved width to DETAIL.
    detail_width=$((detail_width+5))
    printf '  %s%-14s %-*s %-*s | %s%s\n' "$C_DIM" 'TIME' "$connection_width" 'SOURCE' "$event_width" 'EVENT' 'DETAIL' "$C_RESET" > "$TTY_OUT"
    printf '  %s%s%s\n' "$C_DIM" "$(ui_rule $'─')" "$C_RESET" > "$TTY_OUT"
    while IFS=$'\t' read -r when connection action detail; do
        [[ -n "$when" ]] || continue
        event=$(activity_event_label_for "$action")
        event_color=$(activity_event_color_for "$action")
        printf '  %s%-14s%s %s%-*s%s %s%-*s%s %s|%s %s\n' \
            "$C_DIM" "$when" "$C_RESET" "$C_RESET" "$connection_width" "$(fit_text "$connection" "$connection_width")" "$C_RESET" \
            "$event_color" "$event_width" "$(fit_text "$event" "$event_width")" "$C_RESET" "$C_DIM" "$C_RESET" "$(fit_text "$detail" "$detail_width")" > "$TTY_OUT"
    done <<<"$preview_output"
    printf '  %sOpen Recent Logs for full timestamps and complete event details.%s\n' "$C_DIM" "$C_RESET" > "$TTY_OUT"
}

activity_event_label_for ()
{
    case "${1:-}" in
        connection-created) printf 'CREATED' ;;
        connection-updated) printf 'UPDATED' ;;
        connection-enrolled) printf 'ENROLLED' ;;
        connection-enrollment-issued) printf 'ENROLLMENT ISSUED' ;;
        connection-presence-connected) printf 'CONNECTED' ;;
        connection-presence-disconnected) printf 'DISCONNECTED' ;;
        connection-presence-offline) printf 'OFFLINE' ;;
        connection-removed) printf 'REMOVED' ;;
        connection-management) printf 'MANAGEMENT' ;;
        connection-control-key-rotated) printf 'CONTROL KEY ROTATED' ;;
        connection-bootstrap-credential-rotation) printf 'BOOTSTRAP KEY STAGED' ;;
        connection-config-staged) printf 'CONFIG STAGED' ;;
        connection-config-prepared) printf 'CONFIG PREPARED' ;;
        connection-config-committed) printf 'CONFIG VERIFIED' ;;
        connection-config-rollback) printf 'CONFIG ROLLBACK' ;;
        ingress-release-published) printf 'RELEASE PUBLISHED' ;;
        ingress-release-status) printf 'RELEASE STATUS' ;;
        ingress-release-replaced) printf 'RELEASE REPLACED' ;;
        ingress-release-deleted) printf 'RELEASE DELETED' ;;
        ingress-release-purged) printf 'RELEASE PURGED' ;;
        server-endpoint|server-endpoint|server-endpoint-set) printf 'ENDPOINT CHANGED' ;;
        server-endpoint-synced) printf 'ENDPOINT SYNCED' ;;
        server-endpoint-reconcile) printf 'ENDPOINT RETRY' ;;
        server-endpoint-retired) printf 'ENDPOINT RETIRED' ;;
        server-endpoint-finalized) printf 'ENDPOINT COMPLETE' ;;
        subscription-change) printf 'SUBSCRIPTION' ;;
        renew) printf 'RENEWED' ;;
        suspend) printf 'SUSPENDED' ;;
        resume) printf 'RESUMED' ;;
        traffic-reset) printf 'TRAFFIC RESET' ;;
        *) printf '%s' "$(printf '%s' "${1:--}" | tr '[:lower:]-' '[:upper:] ')" ;;
    esac
}

activity_event_color_for ()
{
    case "${1:-}" in
        connection-presence-offline|connection-removed|suspend|*failed*|*error*) printf '%s' "$C_RED" ;;
        *) printf '%s' "$C_CYAN" ;;
    esac
}

activity_table_widths ()
{
    local output="${1:-}" cols max_connection_len=10 max_event_len=10
    local max_connection_width min_detail_width fixed_width available_event_width
    local connection_width event_width detail_width timestamp connection action detail event n
    cols=$(ui_terminal_columns); ((cols < 72)) && cols=72
    if [[ -n "$output" ]]; then
        while IFS=$'\t' read -r timestamp connection action detail; do
            [[ -n "$timestamp" ]] || continue
            [[ "$connection" == '-' || -z "$connection" ]] && connection='SERVER'
            event=$(activity_event_label_for "$action")
            n=${#connection}; ((n > max_connection_len)) && max_connection_len=$n
            n=${#event}; ((n > max_event_len)) && max_event_len=$n
        done <<<"$output"
    fi

    if ((cols >= 120)); then
        max_connection_width=24; min_detail_width=34
    elif ((cols >= 96)); then
        max_connection_width=20; min_detail_width=28
    else
        max_connection_width=16; min_detail_width=22
    fi

    connection_width=$max_connection_len
    ((connection_width < 10)) && connection_width=10
    ((connection_width > max_connection_width)) && connection_width=$max_connection_width

    # EVENT is standardized globally: known labels get at least 22 characters,
    # it may grow to 32, and DETAIL only competes after that policy is honored.
    fixed_width=26
    available_event_width=$((cols-fixed_width-connection_width-min_detail_width))
    ((available_event_width < 12)) && available_event_width=12
    event_width=$max_event_len
    ((event_width < 22)) && event_width=22
    ((event_width > 32)) && event_width=32
    ((event_width > available_event_width)) && event_width=$available_event_width

    detail_width=$((cols-fixed_width-connection_width-event_width))
    ((detail_width < 16)) && detail_width=16
    printf '%s\t%s\t%s\n' "$connection_width" "$event_width" "$detail_width"
}

activity_print_full_row ()
{
    local index="$1" when="$2" connection="$3" event="$4" detail="$5" event_color="$6" connection_width="$7" event_width="$8" detail_width="$9"
    local -a detail_lines=()
    local count i index_cell when_cell connection_cell event_cell detail_cell
    mapfile -t detail_lines < <(history_wrap_lines "$detail" "$detail_width")
    ((${#detail_lines[@]})) || detail_lines=('')
    count=${#detail_lines[@]}
    for ((i=0; i<count; i++)); do
        if ((i == 0)); then
            index_cell=$(printf '[%2s]' "$index")
            when_cell="$when"
            connection_cell=$(fit_text "$connection" "$connection_width")
            event_cell=$(fit_text "$event" "$event_width")
        else
            index_cell=''; when_cell=''; connection_cell=''; event_cell=''
        fi
        detail_cell="${detail_lines[i]:-}"
        printf '  %-4s %-14s %-*s %s%-*s%s %s|%s %-*s\n' \
            "$index_cell" "$when_cell" "$connection_width" "$connection_cell" \
            "$event_color" "$event_width" "$event_cell" "$C_RESET" "$C_DIM" "$C_RESET" "$detail_width" "$detail_cell" > "$TTY_OUT"
    done
}

operations_recent_activity_screen ()
{
    local page=1 size choice offset output rows timestamp connection action detail local_time event event_color cols idx
    local connection_width event_width detail_width fixed_width min_detail_width max_connection_width available_event_width
    local max_connection_len max_event_len n connection_rule event_rule detail_rule
    size=$(ui_activity_page_size)
    while true; do
        offset=$(((page-1)*size))
        output=$(registry_command audit --scope all --limit "$size" --offset "$offset" 2>/dev/null || true)
        rows=$(grep -c . <<<"$output" || true)
        clear_screen
        dfr_ui_header 'OPERATIONS CENTER | RECENT LOGS'
        section_title 'Recent Logs'
        ui_timezone_line
        printf '  %sEvent labels stay on one row. Detail text receives the remaining terminal width and wraps only when required.%s\n' "$C_DIM" "$C_RESET" > "$TTY_OUT"
        IFS=$'\t' read -r connection_width event_width detail_width < <(activity_table_widths "$output")
        printf '\n  %s%-4s %-14s %-*s %-*s | %-*s%s\n' "$C_DIM" '#' 'TIME' "$connection_width" 'CONNECTION' "$event_width" 'EVENT' "$detail_width" 'DETAIL' "$C_RESET" > "$TTY_OUT"
        printf '  %s%s%s\n' "$C_DIM" "$(ui_rule $'\u2500')" "$C_RESET" > "$TTY_OUT"
        if [[ -z "$output" ]]; then
            ((page == 1)) && printf '  %sNo logs have been recorded.%s\n' "$C_DIM" "$C_RESET" > "$TTY_OUT" || printf '  %sNo more log records.%s\n' "$C_DIM" "$C_RESET" > "$TTY_OUT"
        else
            idx=0
            while IFS=$'\t' read -r timestamp connection action detail; do
                [[ -n "$timestamp" ]] || continue
                idx=$((idx+1))
                local_time=$(date -d "$timestamp" '+%m-%d %H:%M:%S' 2>/dev/null || printf '%s' "$timestamp")
                [[ "$connection" == '-' || -z "$connection" ]] && connection='SERVER'
                event=$(activity_event_label_for "$action")
                event_color=$(activity_event_color_for "$action")
                activity_print_full_row "$idx" "$local_time" "$connection" "$event" "$detail" "$event_color" "$connection_width" "$event_width" "$detail_width"
            done <<<"$output"
        fi
        printf '\n  %sPage %s | %s records shown | target %s rows/page%s\n' "$C_DIM" "$page" "$rows" "$size" "$C_RESET" > "$TTY_OUT"
        ui_view_controls basic
        ui_navigation_controls
        printf '\n' > "$TTY_OUT"
        choice=$(prompt '  Select an action: ') || return 0
        case "$choice" in
            n|N|16) ((rows == size)) && page=$((page+1)) ;;
            p|P|17) ((page > 1)) && page=$((page-1)) ;;
            r|R|18) ;;
            g|G|90) ui_global_navigation ;;
            b|B|0) return 0 ;;
            q|Q|99) exit 0 ;;
            *) warn 'Invalid selection.'; sleep 0.35 ;;
        esac
    done
}

operations_attention_filter_prompt ()
{
    local choice
    section_title 'Attention Filter'
    ui_status_menu_item 1 'All clients with actionable issues'
    ui_status_menu_item 2 'Critical only'
    ui_status_menu_item 3 'Warning only'
    ui_status_menu_item 4 'Advisory only'
    ui_status_menu_item 5 'Presence'
    ui_status_menu_item 6 'Runtime'
    ui_status_menu_item 7 'Software'
    ui_status_menu_item 8 'Endpoint / configuration'
    ui_status_menu_item 9 'Subscription'
    ui_menu_item B 'Back' back
    choice=$(prompt '  Filter: ')
    case "$choice" in
        1) printf 'all' ;;
        2) printf 'severity:CRITICAL' ;;
        3) printf 'severity:WARNING' ;;
        4) printf 'severity:ADVISORY' ;;
        5) printf 'area:PRESENCE' ;;
        6) printf 'area:RUNTIME' ;;
        7) printf 'area:SOFTWARE' ;;
        8) printf 'group:ENDPOINT' ;;
        9) printf 'group:POLICY' ;;
        b|B|0) return 1 ;;
        *) return 1 ;;
    esac
}

attention_filter_label ()
{
    case "${1:-all}" in
        all) printf 'All clients with actionable issues' ;;
        severity:CRITICAL) printf 'Critical only' ;;
        severity:WARNING) printf 'Warning only' ;;
        severity:ADVISORY) printf 'Advisory only' ;;
        area:PRESENCE) printf 'Presence' ;;
        area:RUNTIME) printf 'Runtime' ;;
        area:SOFTWARE) printf 'Software' ;;
        group:ENDPOINT) printf 'Endpoint / configuration' ;;
        group:POLICY) printf 'Subscription' ;;
        *) printf '%s' "$1" ;;
    esac
}

operations_attention_queue ()
{
    local snapshot="$1" page=1 size choice filter='all' search='' meta pages client_count issue_count offset
    local severity name uuid issues areas primary color selected cols primary_w
    size=$(ui_attention_page_size)
    # The alert queue is client-oriented, not symptom-oriented. One connection
    # occupies one selectable row even when several independent issues exist.
    while true; do
        meta=$(attention_client_group_meta "$snapshot" "$filter" "$search" "$page" "$size")
        IFS=$'\t' read -r page pages client_count issue_count <<<"$meta"
        offset=$(((page-1)*size))
        clear_screen
        dfr_ui_header 'OPERATIONS CENTER | CLIENT ALERTS'
        section_title 'Client Alerts'
        printf '  %sFilter:%s %s  %s|%s  %sSearch:%s %s  %s|%s  %s%s clients, %s issues%s\n' \
            "$C_DIM" "$C_RESET" "$(attention_filter_label "$filter")" "$C_DIM" "$C_RESET" \
            "$C_DIM" "$C_RESET" "${search:-All}" "$C_DIM" "$C_RESET" "$C_DIM" "$client_count" "$issue_count" "$C_RESET" > "$TTY_OUT"
        if ((client_count == 0)); then
            print_check pass 'Client Alerts' 'No active client alerts match this view.'
        else
            cols=$(ui_terminal_columns); ((cols < 76)) && cols=76
            primary_w=$((cols-72)); ((primary_w < 22)) && primary_w=22
            printf '\n  %s%-4s %-18s %-12s %-9s %-6s %-18s %s%s\n' "$C_DIM" '#' 'CONNECTION' 'UUID' 'LEVEL' 'ISSUES' 'AREAS' 'PRIMARY ISSUE' "$C_RESET" > "$TTY_OUT"
            printf '  %s%s%s\n' "$C_DIM" "$(ui_rule $'\u2500')" "$C_RESET" > "$TTY_OUT"
            local idx=0
            while IFS=$'\t' read -r severity name uuid issues areas primary; do
                [[ -n "$name" ]] || continue
                idx=$((idx+1))
                color=$(semantic_state_color "$severity")
                printf '  [%d]  %-18s %-12s %s%-9s%s %-6s %-18s %s\n' \
                    "$idx" "$(fit_text "$name" 18)" "$(fit_text "$uuid" 12)" "$color" "$(fit_text "$severity" 9)" "$C_RESET" \
                    "$issues" "$(fit_text "$areas" 18)" "$(fit_text "$primary" "$primary_w")" > "$TTY_OUT"
            done < <(attention_client_summary_rows "$snapshot" "$filter" "$search" "$offset" "$size")
        fi
        printf '\n  %sPage %s/%s | %s clients/page%s\n' "$C_DIM" "$page" "$pages" "$size" "$C_RESET" > "$TTY_OUT"
        ui_view_controls filter
        ui_navigation_controls
        printf '\n' > "$TTY_OUT"
        choice=$(prompt '  Open client or action: ') || return 0
        case "$choice" in
            n|N|16) ((page < pages)) && page=$((page+1)) ;;
            p|P|17) ((page > 1)) && page=$((page-1)) ;;
            s|S|18) search=$(prompt '  Search connection name or UUID (empty clears): ') || true; page=1 ;;
            f|F|19) filter=$(operations_attention_filter_prompt) || true; page=1 ;;
            r|R|20) snapshot=$(fleet_snapshot_file 2>/dev/null || true); page=1 ;;
            g|G|90) ui_global_navigation ;;
            b|B|0) return 0 ;;
            q|Q|99) exit 0 ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]]; then
                    selected=$(attention_client_group_pick "$snapshot" "$filter" "$search" "$page" "$size" "$choice")
                    if [[ -n "$selected" ]]; then manage_client_menu "$selected"; else warn 'No client exists at that position.'; sleep 0.35; fi
                else
                    warn 'Invalid selection.'; sleep 0.35
                fi
                ;;
        esac
    done
}

operations_center_workspace ()
{
    local choice snapshot selected
    while true; do
        snapshot=$(fleet_snapshot_file 2>/dev/null || true)
        clear_screen
        dfr_ui_header 'OPERATIONS CENTER'
        [[ -n "$snapshot" ]] || { print_check fail 'Operations Center' 'Fleet snapshot is unavailable.'; pause_screen; return 1; }
        operations_center_overview "$snapshot"
        section_title 'Operations'
        ui_menu_item 1 'Client Alerts' caution
        ui_menu_item 2 'Recent Logs' neutral
        ui_menu_item 3 'Browse / Search Connections' neutral
        ui_menu_item R 'Refresh' neutral
        ui_navigation_footer
        choice=$(prompt '  Select an option: ') || return 0
        case "$choice" in
            1) operations_attention_queue "$snapshot" ;;
            2) operations_recent_activity_screen ;;
            3) selected=$(select_client_interactive) && manage_client_menu "$selected" ;;
            r|R|9) continue ;;
            g|G|90) ui_global_navigation ;;
            b|B|0) return 0 ;;
            q|Q|99) exit 0 ;;
            *) warn 'Invalid selection.'; sleep 0.35 ;;
        esac
    done
}

hub_interactive_menu ()
{
    local choice
    while hub_configured; do
        clear_screen
        dfr_ui_header 'MAIN MENU'
        hub_main_dashboard
        section_title 'Operations'
        ui_menu_item 1 'Operations Center' neutral
        ui_menu_item 2 'Connections' neutral
        ui_menu_item 3 'Server Operations' neutral

        section_title 'System'
        ui_menu_item 4 'Remove Server Configuration' caution
        ui_menu_item 5 'Uninstall Dragon Fruit Relay' destructive

        section_title 'Session'
        ui_menu_item R 'Refresh' neutral
        ui_menu_item Q 'Exit' destructive

        choice=$(prompt '  Select an option: ') || exit 0
        case "$choice" in
            1) operations_center_workspace ;;
            2) client_connections_workspace ;;
            3) server_operations_workspace ;;
            4) remove_egress_hub no no; pause_screen; return ;;
            5) remove_egress_hub yes no; return ;;
            r|R|9) continue ;;
            q|Q|0) exit 0 ;;
            *) warn 'Invalid selection.'; sleep 0.35 ;;
        esac
    done
}

dfr_ui_header ()
{
    local title="${1:-SERVER}" width
    width=$(ui_content_width)
    printf '\n  %s%sDRAGON FRUIT RELAY %s%s  %s|%s  %s%s%s\n' \
        "$C_BOLD" "$C_CYAN" "$APP_VERSION" "$C_RESET" \
        "$C_DIM" "$C_RESET" "$C_BOLD" "$title" "$C_RESET" > "$TTY_OUT"
    printf '  %s%s%s\n' "$C_DIM" "$(ui_rule $'\u2500' "$width")" "$C_RESET" > "$TTY_OUT"
}



hub_runtime_overview () 
{ 
    load_host_config;
    hub_status_counts;
    local hub_state;
    hub_state=$(hub_state_word);
    section_title 'Server runtime';
    print_check info 'Server status' "$hub_state";
    print_check info 'Public IPv4' "$PUBLIC_IP" accent;
    print_check info 'Physical interface' "$WAN_IF" identity;
    print_check info 'Client totals' "$HUB_TOTAL total | $HUB_OPERATIONAL connected | $HUB_READY waiting | $HUB_STOPPED stopped | $HUB_UNHEALTHY unhealthy";
    [[ "$(sysctl -n net.ipv4.ip_forward 2> /dev/null || true)" == 1 ]] && print_check pass 'IPv4 forwarding' enabled || print_check fail 'IPv4 forwarding' disabled;
    [[ -f "$CLIENT_UNIT_TEMPLATE" ]] && print_check pass 'Client unit template' "$CLIENT_UNIT_TEMPLATE" || print_check fail 'Client unit template' missing;
    [[ -d "$SWANCTL_CLIENT_ROOT" ]] && print_check pass 'swanctl namespace' "$SWANCTL_CLIENT_ROOT" || print_check fail 'swanctl namespace' missing;
    [[ -d "$STRONGSWAN_CLIENT_ROOT" ]] && print_check pass 'strongSwan namespace' "$STRONGSWAN_CLIENT_ROOT" || print_check fail 'strongSwan namespace' missing
}

hub_state_word () 
{ 
    if [[ "$(sysctl -n net.ipv4.ip_forward 2> /dev/null || true)" != 1 ]]; then
        printf 'DEGRADED';
    else
        if ((HUB_TOTAL == 0)); then
            printf 'EMPTY';
        else
            if ((HUB_UNHEALTHY > 0)); then
                printf 'DEGRADED';
            else
                if ((HUB_OPERATIONAL > 0)); then
                    printf 'OPERATIONAL';
                else
                    if ((HUB_READY > 0)); then
                        printf 'READY';
                    else
                        if ((HUB_STOPPED == HUB_TOTAL)); then
                            printf 'STOPPED';
                        else
                            printf 'DEGRADED';
                        fi;
                    fi;
                fi;
            fi;
        fi;
    fi
}

hub_status_counts ()
{
    HUB_TOTAL=0 HUB_OPERATIONAL=0 HUB_READY=0 HUB_STOPPED=0 HUB_UNHEALTHY=0
    local snapshot
    snapshot=$(fleet_snapshot_file 2>/dev/null || true)
    [[ -n "$snapshot" && -r "$snapshot" ]] || return 0
    read -r HUB_TOTAL HUB_OPERATIONAL HUB_READY HUB_STOPPED HUB_UNHEALTHY < <(python3 - "$snapshot" <<'PY_DFR_HUB_COUNTS'
import json,sys
try:d=json.load(open(sys.argv[1],encoding='utf-8'))
except Exception:d={}
s=d.get('summary') or {}
total=int(s.get('total') or 0)
oper=int(s.get('operational') or 0)
ready=int(s.get('ready') or 0)
stopped=int(s.get('stopped') or 0)
unhealthy=int(s.get('degraded') or 0)+int(s.get('failed') or 0)+int(s.get('unknown') or 0)
print(total,oper,ready,stopped,unhealthy)
PY_DFR_HUB_COUNTS
)
}

info () 
{ 
    log_line INFO "$*";
    if [[ "${DFR_SETUP_UI_ACTIVE:-no}" == yes ]]; then
        print_check info 'Progress' "$*"
    else
        printf '%s[INFO]%s %s\n' "$C_BLUE" "$C_RESET" "$*" > "$TTY_OUT"
    fi
}

install_cli_command () 
{ 
    local source_file="${BASH_SOURCE[0]:-}";
    if [[ -z "$source_file" || ! -r "$source_file" ]]; then
        die 'Cannot install the management command because the current script path is unreadable.';
    fi;
    install -d -m 0755 "$(dirname "$CLI_COMMAND")";
    local source_real command_real;
    source_real=$(readlink -f -- "$source_file" 2> /dev/null || printf '%s' "$source_file");
    command_real=$(readlink -f -- "$CLI_COMMAND" 2> /dev/null || true);
    if [[ "$source_real" == "$command_real" ]]; then
        chmod 0755 "$CLI_COMMAND";
        return 0;
    fi;
    local temporary="${CLI_COMMAND}.tmp.$$";
    install -m 0755 "$source_file" "$temporary";
    mv -f -- "$temporary" "$CLI_COMMAND";
    success "Installed management command: ${CLI_COMMAND}"
}

install_dependencies ()
{
    local required_packages=(ca-certificates curl openssl python3-minimal iproute2 iptables iptables-persistent nftables tcpdump strongswan-swanctl charon-systemd dnsutils iputils-ping)
    local optional_packages=(libstrongswan-extra-plugins libcharon-extra-plugins)
    local install_packages=() missing_packages=() package
    section_title 'System preparation'
    print_check info 'Package metadata' 'Refreshing Debian repositories...'
    apt-get update >> "$LOG_FILE" 2>&1
    print_check pass 'Package metadata' 'Repository metadata is current.'
    for package in "${required_packages[@]}"; do
        if apt-cache show "$package" >/dev/null 2>&1; then install_packages+=("$package"); record_initial_package_state "$package"; else missing_packages+=("$package"); fi
    done
    ((${#missing_packages[@]}==0)) || die "This Debian release/repository does not provide required packages: ${missing_packages[*]}"
    for package in "${optional_packages[@]}"; do
        if apt-cache show "$package" >/dev/null 2>&1; then install_packages+=("$package"); record_initial_package_state "$package"; else print_check warn 'Optional package' "${package} is unavailable; continuing without it."; fi
    done
    print_check info 'Required packages' "Installing/verifying ${#install_packages[@]} packages..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y "${install_packages[@]}" >> "$LOG_FILE" 2>&1
    print_check pass 'Required packages' 'Installed and verified.'
}

install_managed_link () 
{ 
    local managed_file="$1" integration_file="$2";
    mkdir -p "$(dirname "$integration_file")";
    rm -f -- "$integration_file";
    ln -s "$managed_file" "$integration_file"
}

install_self_copy () 
{ 
    local source_file="${BASH_SOURCE[0]:-}";
    if [[ -n "$source_file" && -r "$source_file" && "$source_file" != "$INSTALLER_COPY" ]]; then
        install -m 0750 "$source_file" "$INSTALLER_COPY" 2> /dev/null || true;
    fi
}

iptables_rule_counters () 
{ 
    local table="$1" chain="$2" comment="$3" line;
    line=$(iptables -t "$table" -L "$chain" -v -x -n 2> /dev/null | awk -v c="$comment" 'index($0,c) {print; exit}');
    [[ -n "$line" ]] || return 1;
    awk '{printf "%s packets / %s bytes", $1, $2}' <<< "$line"
}




link_managed_unit () 
{ 
    local unit="$1";
    install_managed_link "$UNIT_DIR/$unit" "$SYSTEMD_DIR/$unit"
}







load_client_profile () 
{ 
    local name="$1" file;
    validate_profile_name "$name" || die "Invalid client profile name: ${name}";
    file=$(profile_config_file "$name");
    [[ -r "$file" ]] || die "Client profile '${name}' does not exist.";
    unset PROFILE_SCHEMA PROFILE_NAME PROFILE_INDEX PORT_MODE IKE_PORT NATT_PORT TUNNEL_CIDR XFRM_IF XFRM_ID XFRM_MTU;
    unset INGRESS_XFRM_CIDR EGRESS_XFRM_CIDR INGRESS_XFRM_IP EGRESS_XFRM_IP INGRESS_ID EGRESS_ID;
    unset PSK VICI_SOCKET VICI_URI SWANCTL_CANONICAL STRONGSWAN_CANONICAL DNS_PRIMARY DNS_SECONDARY;
    # shellcheck disable=SC1090
    source "$file";
    [[ "${PROFILE_SCHEMA:-}" == "$PROFILE_SCHEMA_CURRENT" ]] || \
        die "Unsupported profile schema in ${file}: ${PROFILE_SCHEMA:-missing}; expected ${PROFILE_SCHEMA_CURRENT}.";
    [[ "${PROFILE_NAME:-}" == "$name" ]] || die "Profile metadata mismatch for '${name}'."
}

load_host_config ()
{
    [[ -r "$HOST_CONFIG_FILE" ]] || die 'This machine is not configured as a Dragon Fruit Relay Server.'
    unset PRODUCT_ID PRODUCT_LINEAGE HUB_SCHEMA ROLE MANAGED_BY_VERSION WAN_IF LOCAL_IP PUBLIC_IP SERVER_ENDPOINT SUBSCRIPTION_PORT CONTROL_PORT
    # shellcheck disable=SC1090
    source "$HOST_CONFIG_FILE"
    [[ "${PRODUCT_ID:-}" == "$DFR_PRODUCT_ID" && "${PRODUCT_LINEAGE:-}" == "$DFR_PRODUCT_LINEAGE" ]] || die "This Server configuration is not from the standalone Dragon Fruit Relay lineage."
    [[ "${HUB_SCHEMA:-}" == "$HUB_SCHEMA_CURRENT" ]] || die "Unsupported Server schema in ${HOST_CONFIG_FILE}: ${HUB_SCHEMA:-missing}; expected ${HUB_SCHEMA_CURRENT}."
    [[ "${ROLE:-}" == 'egress-hub' ]] || die "Invalid Server role in ${HOST_CONFIG_FILE}."
    SERVER_ENDPOINT="${SERVER_ENDPOINT:-}"
    validate_server_endpoint "$SERVER_ENDPOINT" || die "Invalid Server endpoint in ${HOST_CONFIG_FILE}: ${SERVER_ENDPOINT:-missing}."
    SUBSCRIPTION_PORT="${SUBSCRIPTION_PORT:-$DEFAULT_SUBSCRIPTION_PORT}"
    CONTROL_PORT="${CONTROL_PORT:-$DEFAULT_CONTROL_PORT}"
    validate_uint_range "$SUBSCRIPTION_PORT" 1 65535 || die "Invalid subscription port in ${HOST_CONFIG_FILE}: ${SUBSCRIPTION_PORT}."
    validate_uint_range "$CONTROL_PORT" 1 65535 || die "Invalid CONTROL port in ${HOST_CONFIG_FILE}: ${CONTROL_PORT}."
    [[ "$SUBSCRIPTION_PORT" != "$CONTROL_PORT" ]] || die 'Subscription and CONTROL ports must be unique.'
}


log_line () 
{ 
    local level="$1";
    shift;
    printf '%s [%s] %s\n' "$(date -Is)" "$level" "$*" >> "$LOG_FILE"
}

# DFR_EGRESS_MANAGED_INGRESS_UI
management_json ()
{
    registry_command management-show "$1" --json
}

management_field ()
{
    local name="$1" field="$2"
    management_json "$name" | python3 -c 'import json,sys; d=json.load(sys.stdin); v=d.get(sys.argv[1]); print("-" if v in (None,"") else v)' "$field"
}

management_last_seen_text ()
{
    local value="$1" now age
    if [[ ! "$value" =~ ^[0-9]+$ || "$value" -eq 0 ]]; then printf 'Never enrolled / not yet seen'; return; fi
    now=$(date +%s); age=$((now-value)); if ((age < 0)); then age=0; fi
    if (( age < 60 )); then printf '%ss ago' "$age"
    elif (( age < 3600 )); then printf '%sm ago' "$((age/60))"
    elif (( age < 86400 )); then printf '%sh ago' "$((age/3600))"
    else date -d "@$value" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || printf '%s' "$value"; fi
}

fleet_age_text ()
{
    local value="$1" now age
    if [[ ! "$value" =~ ^[0-9]+$ || "$value" -eq 0 ]]; then printf 'never'; return; fi
    now=$(date +%s); age=$((now-value)); if ((age < 0)); then age=0; fi
    if (( age < 60 )); then printf '%ss ago' "$age"
    elif (( age < 3600 )); then printf '%sm ago' "$((age/60))"
    elif (( age < 86400 )); then printf '%sh ago' "$((age/3600))"
    elif (( age < 604800 )); then printf '%sd ago' "$((age/86400))"
    else printf '%sw ago' "$((age/604800))"; fi
}

presence_timestamp_text ()
{
    local value="$1" exact
    if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then printf 'Never'; return; fi
    exact=$(date -d "@$value" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || printf '%s' "$value")
    printf '%s · %s' "$exact" "$(fleet_age_text "$value")"
}





managed_connection_is_enrolled ()
{
    local last
    last=$(management_field "$1" last_seen_at 2>/dev/null || true)
    [[ "$last" =~ ^[1-9][0-9]*$ ]]
}


select_published_release ()
{
    local mode="${1:-active}"
    local -a versions=() statuses=()
    local version status sha created path n choice

    while IFS=$'\t' read -r version status sha created path; do
        [[ -n "$version" ]] || continue
        case "$mode" in
            active) [[ "$status" != revoked ]] || continue ;;
            revoked) [[ "$status" == revoked ]] || continue ;;
            all) ;;
            *) return 1 ;;
        esac
        versions+=("$version"); statuses+=("$status")
    done < <(registry_command release-list 2>/dev/null || true)

    if ((${#versions[@]} == 0)); then
        case "$mode" in
            revoked) warn 'No REVOKED client releases are available.' ;;
            active) warn 'No active client releases are published.' ;;
            *) warn 'No client releases are published.' ;;
        esac
        return 1
    fi

    printf '\n' >"$TTY_OUT"
    for ((n=0;n<${#versions[@]};n++)); do
        printf '    %s[%d]%s  %-18s ' "$C_CYAN" "$((n+1))" "$C_RESET" "${versions[n]}" >"$TTY_OUT"
        semantic_colorize_line "${statuses[n]^^}" >"$TTY_OUT"
        printf '\n' >"$TTY_OUT"
    done
    printf '    %s[B]%s  Back\n' "$C_DIM" "$C_RESET" >"$TTY_OUT"
    choice=$(prompt '  Select release: ')
    [[ "$choice" =~ ^[bB]$ ]] && return 1
    [[ "$choice" =~ ^[0-9]+$ ]] || return 1
    ((choice>=1 && choice<=${#versions[@]})) || return 1
    printf '%s' "${versions[choice-1]}"
}


managed_config_stage_notice ()
{
    local name="$1" transaction_id="$2"
    : "$name" "$transaction_id"
    section_title 'Configuration change queued'
    print_check pass 'Change status' 'QUEUED' 
    print_check info 'Current tunnel' 'remains authoritative until the Client prepares the change'
    print_check info 'Safety' 'both peers use coordinated apply time + independent rollback deadlines'
    print_check info 'Delivery' 'the Client pulls the candidate over CONTROL/1; no new enrollment token is required'
}

managed_connection_edit_menu ()
{
    local name="$1" choice entered entered2 transaction_id owner
    managed_connection_is_enrolled "$name" || {
        warn "Client '${name}' has not completed managed enrollment yet. Issue a fresh enrollment token and enroll it before remote configuration changes."
        pause_screen
        return 0
    }

    while profile_exists "$name"; do
        clear_screen; dfr_ui_header 'EDIT MANAGED CONNECTION'; show_client_header "$name"; show_managed_ingress_status "$name"
        load_client_profile "$name"
        section_title 'Configuration Actions'
        ui_menu_item 1 "Change UDP Transport Port (${NATT_PORT})" neutral
        ui_menu_item 2 "Change XFRM MTU (${XFRM_MTU})" neutral
        ui_menu_item 3 "Change DNS Resolvers (${DNS_PRIMARY}, ${DNS_SECONDARY})" neutral
        ui_menu_item 4 'Rotate Connection Credentials' caution
        ui_menu_item 5 'Cancel Pending Change' caution
        ui_navigation_footer
        choice=$(prompt '  Select an option: ')
        case "$choice" in
            1)
                entered=$(prompt_default "New UDP port (${PROFILE_PORT_MIN}-${PROFILE_PORT_MAX})" "$NATT_PORT")
                validate_uint_range "$entered" "$PROFILE_PORT_MIN" "$PROFILE_PORT_MAX" || { warn 'Invalid UDP port.'; pause_screen; continue; }
                [[ "$entered" != "$NATT_PORT" ]] || { warn 'That is already the committed UDP port.'; pause_screen; continue; }
                owner=$(registry_active_owner udp_port "$entered" "$name" 2>/dev/null || true)
                [[ -z "$owner" ]] || { warn "UDP ${entered} belongs to '${owner}'."; pause_screen; continue; }
                udp_port_in_use_live "$entered" && { warn "UDP ${entered} is currently occupied by another local process."; pause_screen; continue; }
                transaction_id=$(registry_command config-stage "$name" --udp-port "$entered") || { pause_screen; continue; }
                managed_config_stage_notice "$name" "$transaction_id"; pause_screen
                ;;
            2)
                entered=$(prompt_default 'New XFRM MTU (1200-9000)' "$XFRM_MTU")
                validate_uint_range "$entered" 1200 9000 || { warn 'Invalid XFRM MTU.'; pause_screen; continue; }
                [[ "$entered" != "$XFRM_MTU" ]] || { warn 'That MTU is already committed.'; pause_screen; continue; }
                transaction_id=$(registry_command config-stage "$name" --xfrm-mtu "$entered") || { pause_screen; continue; }
                managed_config_stage_notice "$name" "$transaction_id"; pause_screen
                ;;
            3)
                entered=$(prompt_default 'Primary DNS IPv4' "$DNS_PRIMARY"); validate_ipv4 "$entered" || { warn 'Invalid primary DNS IPv4.'; pause_screen; continue; }
                entered2=$(prompt_default 'Secondary DNS IPv4' "$DNS_SECONDARY"); validate_ipv4 "$entered2" || { warn 'Invalid secondary DNS IPv4.'; pause_screen; continue; }
                transaction_id=$(registry_command config-stage "$name" --dns-primary "$entered" --dns-secondary "$entered2") || { pause_screen; continue; }
                managed_config_stage_notice "$name" "$transaction_id"; pause_screen
                ;;
            4)
                confirm "Rotate the IKE pre-shared key for '${name}' using a coordinated transaction?" no || continue
                transaction_id=$(registry_command config-stage "$name" --rotate-psk) || { pause_screen; continue; }
                managed_config_stage_notice "$name" "$transaction_id"
                print_check info 'Credential handling' 'new PSK stays inside the managed transaction; unused enrollment tokens are revoked on commit'
                pause_screen
                ;;
            5)
                if registry_command config-cancel "$name" --reason 'cancelled by administrator'; then success 'Pending configuration candidate cancelled.'; else warn 'Candidate is already prepared/applying; it must finish or roll back automatically.'; fi
                pause_screen
                ;;
            g|G|90) ui_global_navigation ;;
            b|B|0) return 0 ;;
            q|Q|99) exit 0 ;;
            *) warn 'Invalid selection.'; sleep 0.35 ;;
        esac
    done
}

managed_connection_workspace ()
{
    local name="$1" choice policy release
    while profile_exists "$name"; do
        clear_screen; dfr_ui_header 'MANAGED CLIENT'; show_client_header "$name"; show_managed_ingress_status "$name"
        section_title 'CONTROL Actions'
        ui_menu_item 1 'Request Client Reconcile' positive
        ui_menu_item 2 'Edit Configuration' neutral
        ui_menu_item 3 'Deploy Published Client Release' neutral
        ui_menu_item 4 'Change Update Policy' neutral
        ui_menu_item 5 'Issue Fresh Enrollment Token' neutral
        ui_navigation_footer
        choice=$(prompt '  Select an option: ')
        case "$choice" in
            1) if registry_command management-set "$name" --pending-action reconcile; then success 'Reconcile request queued for the Client.'; else warn 'Reconcile request could not be queued.'; fi; pause_screen ;;
            2) managed_connection_edit_menu "$name" ;;
            3)
                managed_connection_is_enrolled "$name" || { warn 'Client has not enrolled yet.'; pause_screen; continue; }
                release=$(select_published_release) || continue
                if registry_command management-set "$name" --desired-version "$release" --desired-source manual; then
                    success "Client release ${release} queued for '${name}'."
                    print_check info 'Software policy' 'MANUAL hold is active for the selected release.'
                else
                    warn "Client release ${release} could not be queued for '${name}'."
                fi
                pause_screen
                ;;
            4)
                ui_status_menu_item 1 'Automatic stable releases'
                ui_status_menu_item 2 'Manual deployment'
                ui_status_menu_item 3 'Pinned (never change automatically)'
                choice=$(prompt '  Policy: ')
                case "$choice" in 1) policy=auto ;; 2) policy=manual ;; 3) policy=pinned ;; *) warn 'Invalid policy.'; pause_screen; continue ;; esac
                if registry_command management-set "$name" --update-policy "$policy"; then success "Update policy set to ${policy}."; else warn 'Update policy was not changed.'; fi; pause_screen
                ;;
            5) show_client_token "$name"; pause_screen ;;
            g|G|90) ui_global_navigation ;;
            b|B|0) return 0 ;;
            q|Q|99) exit 0 ;;
            *) warn 'Invalid selection.'; sleep 0.35 ;;
        esac
    done
}

ingress_release_details ()
{
    local version="$1" info
    local status sha created path desired applied ever_applied deletable when
    info=$(registry_command release-info "$version") || return 1
    readarray -t _ri < <(python3 - "$info" <<'PY_RELEASE_INFO'
import json,sys
d=json.loads(sys.argv[1])
for k in ('status','sha256','created_at','payload_path','desired_clients','applied_clients','ever_applied_clients','deletable'):
 print(d.get(k,''))
PY_RELEASE_INFO
)
    status=${_ri[0]}; sha=${_ri[1]}; created=${_ri[2]}; path=${_ri[3]}; desired=${_ri[4]}; applied=${_ri[5]}; ever_applied=${_ri[6]}; deletable=${_ri[7]}
    when=$(date -d "@$created" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || printf '%s' "$created")
    section_title "Release details: ${version}"
    print_check info 'Status' "${status^^}"
    print_check info 'Published' "$when"
    print_check info 'SHA256' "$sha"
    print_check info 'Desired by clients' "$desired"
    print_check info 'Currently applied' "$applied"
    print_check info 'Ever applied' "$ever_applied"
    # DFR_RELEASE_REMOVE_POLICY_V3_NO_ARCHIVE
    if [[ "$status" != revoked ]]; then
        print_check info 'Removal' 'Revoke first before permanent deletion'
    elif (( desired > 0 || applied > 0 )); then
        print_check warn 'Permanent delete' 'Blocked while desired by or currently applied on any Client'
    elif (( ever_applied > 0 )); then
        print_check warn 'Permanent delete' 'Available with destructive confirmation; historical release-usage rows will be erased'
    else
        print_check pass 'Permanent delete' 'Safe; release was never desired or applied'
    fi
    print_check info 'Payload' "$path" identity
}

ingress_release_delete_revoked ()
{
    local version="$1" info desired applied ever typed
    ingress_release_details "$version" || return 1
    info=$(registry_command release-info "$version") || return 1
    readarray -t _rd < <(python3 - "$info" <<'PY_RELEASE_REMOVE_INFO'
import json,sys
d=json.loads(sys.argv[1])
for k in ('desired_clients','applied_clients','ever_applied_clients'):
    print(int(d.get(k,0) or 0))
PY_RELEASE_REMOVE_INFO
)
    desired=${_rd[0]:-0}; applied=${_rd[1]:-0}; ever=${_rd[2]:-0}

    if (( desired > 0 || applied > 0 )); then
        warn "Permanent deletion is blocked: desired=${desired}, currently applied=${applied}."
        return 1
    fi

    if (( ever > 0 )); then
        warn "${version} was previously applied on ${ever} Client records. Permanent deletion will erase its release-usage record and payload."
        typed=$(prompt "  Type DELETE ${version} to continue: ")
        [[ "$typed" == "DELETE ${version}" ]] || { warn 'Permanent deletion cancelled.'; return 0; }
        registry_command release-purge "$version" --force-history
    else
        confirm "Permanently delete revoked release '${version}', its catalog record and payload?" no || return 0
        registry_command release-purge "$version"
    fi

    success "Release ${version} was permanently deleted."
}

ingress_release_promote_auto ()
{
    local version="$1"
    registry_command release-status "$version" stable
    success "${version} is STABLE; AUTO Clients now converge to this exact build automatically."
}





manifest_contains () 
{ 
    local target="$1";
    [[ -f "$MANIFEST_FILE" ]] || return 1;
    awk -F '\t' -v target="$target" '
        {
            saved=$2
            if (saved == target || index(target, saved "/") == 1) found=1
        }
        END {exit !found}
    ' "$MANIFEST_FILE"
}



normalize_profile_name () 
{ 
    local value="$1";
    value=${value,,};
    value=${value// /-};
    value=$(printf '%s' "$value" | sed -E 's/[^a-z0-9_-]+/-/g; s/[-_]+/-/g; s/^-+//; s/-+$//');
    printf '%s' "${value:0:PROFILE_NAME_MAX}"
}

on_error () 
{ 
    local line="$1";
    local command="$2";
    local status="$3";
    error "Command failed at line ${line} with status ${status}: ${command}";
    error "See ${LOG_FILE} for details. Existing backups are kept in ${BACKUP_DIR}.";
    exit "$status"
}

package_installed () 
{ 
    dpkg-query -W -f='${Status}' "$1" 2> /dev/null | grep -q '^install ok installed$'
}

parse_sa_counter () 
{ 
    local sa="$1" direction="$2" line bytes packets ago;
    line=$(awk -v d="$direction" '$1 == d {print; exit}' <<< "$sa");
    if [[ -z "$line" ]]; then
        printf '0\t0\t-\n';
        return;
    fi;
    bytes=$(sed -nE 's/.*\),[[:space:]]*([0-9]+) bytes,.*/\1/p' <<< "$line");
    packets=$(sed -nE 's/.*bytes,[[:space:]]*([0-9]+) packets,.*/\1/p' <<< "$line");
    ago=$(sed -nE 's/.*packets,[[:space:]]*([0-9]+s) ago.*/\1/p' <<< "$line");
    printf '%s\t%s\t%s\n' "${bytes:-0}" "${packets:-0}" "${ago:--}"
}

pause_screen () 
{ 
    [[ -t 4 ]] || return 0;
    printf '\n%sPress Enter to continue...%s' "$C_DIM" "$C_RESET" > "$TTY_OUT";
    IFS= read -r _ < "$TTY_IN" || true
}

ping_from_source () 
{ 
    local source="$1" target="$2";
    ping -4 -I "$source" -c 2 -W 2 "$target" > /dev/null 2>&1
}


prepare_new_client_resources () 
{ 
    local name="$1" requested_port="$2" requested_tunnel="${3:-auto}" index tunnel_data;
    cleanup_orphan_hub_interfaces;
    index=$(next_profile_index) || die 'No free profile index is available.';
    PROFILE_INDEX="$index";
    XFRM_IF="dfr$(printf '%04d' "$index")";
    XFRM_ID=$((PROFILE_XFRM_ID_BASE + index));
    XFRM_MTU="$DEFAULT_XFRM_MTU";
    if [[ "$requested_port" == interactive ]]; then
        choose_transport_interactive || return 1;
    else
        resolve_requested_transport "$requested_port";
    fi;
    PORT_MODE="$NEW_PORT_MODE";
    IKE_PORT="$NEW_IKE_PORT";
    NATT_PORT="$NEW_NATT_PORT";
    if [[ "$requested_tunnel" == auto || -z "$requested_tunnel" ]]; then
        TUNNEL_CIDR=$(allocate_tunnel_cidr) || die "No unused /30 remains in ${PROFILE_TUNNEL_POOL}.";
    else
        cidr_hosts "$requested_tunnel" > /dev/null || die 'The requested tunnel must be a valid IPv4 /30.';
        ensure_tunnel_network_available "$requested_tunnel";
        TUNNEL_CIDR="$requested_tunnel";
    fi;
    mapfile -t tunnel_data < <(cidr_hosts "$TUNNEL_CIDR");
    ((${#tunnel_data[@]} == 5)) || die 'Could not derive tunnel addresses.';
    TUNNEL_CIDR=${tunnel_data[0]};
    INGRESS_XFRM_CIDR=${tunnel_data[1]};
    EGRESS_XFRM_CIDR=${tunnel_data[2]};
    INGRESS_XFRM_IP=${tunnel_data[3]};
    EGRESS_XFRM_IP=${tunnel_data[4]};
    ip link show dev "$XFRM_IF" > /dev/null 2>&1 && die "Interface ${XFRM_IF} already exists.";
    INGRESS_ID="dragon-fruit-relay-ingress-${name}";
    EGRESS_ID="dragon-fruit-relay-egress-${name}";
    DNS_PRIMARY="$DEFAULT_DNS_PRIMARY";
    DNS_SECONDARY="$DEFAULT_DNS_SECONDARY";
    PSK=$(openssl rand -hex 32)
}

print_check ()
{
    local level="$1";
    local label="$2";
    local detail="${3:-}";
    local kind="${4:-auto}";

    local badge color;

    case "$level" in

        pass)
            badge='OK';
            color="$C_GREEN"
            ;;

        warn)
            badge='!';
            color="$C_YELLOW"
            ;;

        fail)
            badge='X';
            color="$C_RED"
            ;;

        info)
            badge='i';
            color="$C_CYAN"
            ;;

        *)
            badge='-';
            color="$C_WHITE"
            ;;
    esac;

    printf '    %s[%s]%s %-28s ' "$color" "$badge" "$C_RESET" "$label" > "$TTY_OUT"
    case "$kind" in
        accent) printf '%s%s%s' "$C_CYAN" "$detail" "$C_RESET" > "$TTY_OUT" ;;
        identity|plain) printf '%s' "$detail" > "$TTY_OUT" ;;
        muted) printf '%s%s%s' "$C_DIM" "$detail" "$C_RESET" > "$TTY_OUT" ;;
        *) semantic_colorize_line "$detail" > "$TTY_OUT" ;;
    esac
    printf '\n' > "$TTY_OUT";

    return 0;
}


profile_config_file () 
{ 
    printf '%s/profile.conf' "$(profile_dir "$1")"
}

profile_count () 
{ 
    local count=0 name;
    while IFS= read -r name; do
        [[ -n "$name" ]] && count=$((count + 1));
    done < <(profile_names);
    printf '%s' "$count"
}

profile_dir () 
{ 
    printf '%s/%s' "$CLIENTS_DIR" "$1"
}

profile_exists () 
{ 
    [[ -f "$(profile_config_file "$1")" ]]
}

profile_names ()
{
    # Fleet views are ordered by connection identity, never by transport port.
    # GNU version sort gives operators the expected natural order:
    # client-2 before client-10. Connection names are unique in schema 6, so
    # the name itself is the deterministic primary identity for this filesystem view.
    [[ -d "$CLIENTS_DIR" ]] || return 0

    local path
    for path in "$CLIENTS_DIR"/*/profile.conf; do
        [[ -f "$path" ]] || continue
        basename "$(dirname "$path")"
    done | LC_ALL=C sort -V
}

profile_service () 
{ 
    printf 'dragon-fruit-relay-client@%s.service' "$1"
}

profile_strongswan_canonical () 
{ 
    printf '%s/%s.conf' "$STRONGSWAN_CLIENT_ROOT" "$1"
}

profile_strongswan_source () 
{ 
    printf '%s/strongswan.conf' "$(profile_dir "$1")"
}

profile_swanctl_canonical () 
{ 
    printf '%s/swanctl.conf' "$(profile_swanctl_dir "$1")"
}

profile_swanctl_dir () 
{ 
    printf '%s/%s' "$SWANCTL_CLIENT_ROOT" "$1"
}

profile_swanctl_source () 
{ 
    printf '%s/swanctl.conf' "$(profile_dir "$1")"
}

profile_token_file () 
{ 
    printf '%s/pairing-token.txt' "$(profile_dir "$1")"
}

profile_vici_socket () 
{ 
    printf '/run/dragon-fruit-relay/%s.vici' "$1"
}

profile_vici_uri () 
{ 
    printf 'unix:///run/dragon-fruit-relay/%s.vici' "$1"
}

prompt ()
{
    local text="$1"
    local answer=''
    # Bash applies an inherited TMOUT to every read, including reads from
    # /dev/tty.  Disable it locally so dashboards never manufacture an empty
    # choice and print "Invalid selection" while the operator is only reading.
    local TMOUT=0
    printf '%s' "$text" > "$TTY_OUT"
    if ! IFS= read -r answer < "$TTY_IN"; then
        printf '\n[WARN] Interactive terminal input is unavailable; ending this Dragon Fruit Relay session.\n' > "$TTY_OUT"
        # prompt() is normally evaluated inside command substitution, so `exit`
        # would only terminate that subshell and nested menus would keep
        # unwinding noisily. $$ remains the owning shell PID in Bash command
        # substitutions; terminate that session once and let the outer flock
        # wrapper release normally.
        kill -TERM "$$" 2>/dev/null || true
        return 1
    fi
    answer=${answer%$'\r'}
    printf '%s' "$answer"
}


prompt_default ()
{
    local text="$1"
    local default="$2"
    local answer=''
    local TMOUT=0
    printf '%s [%s]: ' "$text" "$default" > "$TTY_OUT"
    if ! IFS= read -r answer < "$TTY_IN"; then
        printf '\n[WARN] Interactive input closed; cancelling the prompt.\n' > "$TTY_OUT"
        return 1
    fi
    answer=${answer%$'\r'}
    printf '%s' "${answer:-$default}"
}




prompt_profile_name () 
{ 
    local entered normalized;
    while true; do
        entered=$(prompt 'Connection name: ');
        normalized=$(normalize_profile_name "$entered");
        if ! validate_profile_name "$normalized"; then
            warn "Use a name containing letters, numbers, hyphens or underscores (maximum ${PROFILE_NAME_MAX} characters).";
            continue;
        fi;
        if profile_exists "$normalized"; then
            warn "A client named '${normalized}' already exists.";
            continue;
        fi;
        if [[ "$entered" != "$normalized" ]]; then
            print_check info 'Profile identifier' "$normalized" identity;
            confirm "Use '${normalized}' as the profile name" yes || continue;
        fi;
        printf '%s' "$normalized";
        return 0;
    done
}




record_initial_package_state () 
{ 
    local package="$1";
    mkdir -p "$STATE_DIR";
    touch "$PACKAGE_STATE_FILE";
    if ! grep -qE "^${package}=" "$PACKAGE_STATE_FILE"; then
        if package_installed "$package"; then
            printf '%s=present\n' "$package" >> "$PACKAGE_STATE_FILE";
        else
            printf '%s=absent\n' "$package" >> "$PACKAGE_STATE_FILE";
        fi;
    fi
}

record_unit_state_initial () 
{ 
    local unit="$1" prefix="$2";
    mkdir -p "$STATE_DIR";
    touch "$PACKAGE_STATE_FILE";
    grep -q "^${prefix}_UNIT_EXISTED=" "$PACKAGE_STATE_FILE" && return 0;
    local existed="no" active="no" enabled="no";
    if systemctl cat "$unit" > /dev/null 2>&1; then
        existed="yes";
        systemctl is-active --quiet "$unit" 2> /dev/null && active="yes";
        systemctl is-enabled --quiet "$unit" 2> /dev/null && enabled="yes";
    fi;
    printf '%s_UNIT_EXISTED=%s\n' "$prefix" "$existed" >> "$PACKAGE_STATE_FILE";
    printf '%s_UNIT_WAS_ACTIVE=%s\n' "$prefix" "$active" >> "$PACKAGE_STATE_FILE";
    printf '%s_UNIT_WAS_ENABLED=%s\n' "$prefix" "$enabled" >> "$PACKAGE_STATE_FILE"
}

remove_added_packages () 
{ 
    local package_state_file="${1:-$PACKAGE_STATE_FILE}";
    [[ -f "$package_state_file" ]] || return 0;
    local remove=();
    local package state;
    while IFS='=' read -r package state; do
        case "$package" in 
            RESOLVED_WAS_ACTIVE | RESOLVED_WAS_ENABLED | *_UNIT_EXISTED | *_UNIT_WAS_ACTIVE | *_UNIT_WAS_ENABLED)
                continue
            ;;
        esac;
        if [[ "$state" == 'absent' ]] && package_installed "$package"; then
            remove+=("$package");
        fi;
    done < "$package_state_file";
    if ((${#remove[@]})) && confirm 'Remove packages that Dragon Fruit Relay originally installed?' no; then
        export DEBIAN_FRONTEND=noninteractive;
        apt-get purge -y "${remove[@]}" >> "$LOG_FILE" 2>&1;
    fi
}

remove_all_dragonfruit_network_rules () 
{ 
    local comment;
    for comment in dragon-fruit-relay-ike dragon-fruit-relay-natt dragon-fruit-relay-ike-custom dragon-fruit-relay-custom-ike-in dragon-fruit-relay-custom-ike-out dragon-fruit-relay-custom-natt-in dragon-fruit-relay-custom-natt-out dragon-fruit-relay-forward-out dragon-fruit-relay-forward-return dragon-fruit-relay-nat;
    do
        delete_iptables_rules_by_comment filter "$comment";
        delete_iptables_rules_by_comment nat "$comment";
    done;
    if command -v netfilter-persistent > /dev/null 2>&1; then
        netfilter-persistent save >> "$LOG_FILE" 2>&1 || true;
    fi
}

remove_cli_command () 
{ 
    rm -f -- "$CLI_COMMAND";
    if [[ -e "$CLI_COMMAND" || -L "$CLI_COMMAND" ]]; then
        die "Complete uninstall could not remove ${CLI_COMMAND}.";
    fi
}

remove_client_files () 
{ 
    local name="$1" canonical_dir canonical_strong expected_strong;
    canonical_dir=$(profile_swanctl_dir "$name");
    canonical_strong=$(profile_strongswan_canonical "$name");
    expected_strong=$(profile_strongswan_source "$name");
    if [[ -e "$canonical_dir/.dragon-fruit-relay-profile" ]]; then
        rm -rf -- "$canonical_dir";
    fi;
    if [[ -L "$canonical_strong" && "$(readlink -f -- "$canonical_strong" 2> /dev/null || true)" == "$(readlink -f -- "$expected_strong" 2> /dev/null || true)" ]]; then
        rm -f -- "$canonical_strong";
    fi;
    rm -rf -- "$(profile_dir "$name")"
}

remove_client_network_rules ()
{
    local name="$1"
    delete_iptables_rules_by_comment filter "$(client_rule_comment "$name" forward-out)"
    delete_iptables_rules_by_comment filter "$(client_rule_comment "$name" forward-return)"
    delete_iptables_rules_by_comment filter "$(client_rule_comment "$name" management-in)"
    delete_iptables_rules_by_comment filter "$(client_rule_comment "$name" management-out)"
    delete_iptables_rules_by_comment filter "$(client_rule_comment "$name" peer-ping-in)"
    delete_iptables_rules_by_comment filter "$(client_rule_comment "$name" peer-ping-out)"
    delete_iptables_rules_by_comment nat "$(client_rule_comment "$name" nat)"
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >> "$LOG_FILE" 2>&1 || true
}

remove_egress_hub ()
{
    local complete="${1:-no}" skip_confirm="${2:-no}" name
    hub_configured || die 'This machine is not configured as a Dragon Fruit Relay Server.'
    [[ "$skip_confirm" == yes ]] || {
        if [[ "$complete" == yes ]]; then confirm 'Completely uninstall the Server, every Client, and restore the original host state?' no || return 0
        else confirm 'Remove the Server and every Client, then restore the original host state?' no || return 0; fi
    }
    systemctl disable --now "$CONTROL_UNIT" "$SUBSCRIPTION_UNIT" "$REGISTRY_UNIT" >/dev/null 2>&1 || true
    while IFS= read -r name; do [[ -n "$name" ]] && remove_hub_client "$name" yes || true; done < <(profile_names)
    rm -f "$CLIENT_UNIT_TEMPLATE" "$CONTROL_UNIT_FILE" "$SUBSCRIPTION_UNIT_FILE" "$REGISTRY_UNIT_FILE"
    [[ -e "$SWANCTL_CLIENT_ROOT/.dragon-fruit-relay-root" ]] && rm -rf "$SWANCTL_CLIENT_ROOT" || true
    [[ -e "$STRONGSWAN_CLIENT_ROOT/.dragon-fruit-relay-root" ]] && rm -rf "$STRONGSWAN_CLIENT_ROOT" || true
    [[ -L "$SYSCTL_FILE" && "$(readlink -f "$SYSCTL_FILE" 2>/dev/null || true)" == "$SYSCTL_MANAGED_FILE" ]] && rm -f "$SYSCTL_FILE" || true
    rm -rf "$CONFIG_DIR"
    restore_pre_routevpn_state egress
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf "$STATE_DIR"
    if [[ "$complete" == yes ]]; then remove_added_packages; remove_cli_command; success 'Dragon Fruit Relay and all Client profiles were completely removed.'
    else success 'The Server and every Client connection were removed; the management command remains installed.'; fi
}



repair_all_clients () 
{ 
    load_host_config;
    write_hub_helpers;
    write_hub_sysctl;
    local name failures=0;
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue;
        repair_hub_client "$name" || failures=$((failures + 1));
    done < <(profile_names);
    ((failures == 0)) && success 'All client profiles were repaired.' || error "${failures} client profiles failed repair."
}

repair_hub_client ()
{
    local name="$1"
    load_host_config
    registry_final_sync
    if [[ -x "$REGISTRY_HELPER" && -f "$REGISTRY_DB" ]] && registry_command export-shell "$name" >/dev/null 2>&1; then
        registry_materialize_connection "$name"
    else
        load_client_profile "$name"
        write_client_strongswan "$name"
        write_client_swanctl "$name"
    fi
    systemctl daemon-reload
    systemctl restart "$(profile_service "$name")" >> "$LOG_FILE" 2>&1 || {
        error "Client '${name}' failed after repair."
        journalctl -u "$(profile_service "$name")" -n 100 --no-pager > "$TTY_OUT" || true
        return 1
    }
    apply_client_network_rules "$name" || { error "Client '${name}' firewall/runtime rules could not be repaired."; return 1; }
    write_subscription_responder || true
    start_subscription_responder || true
    ensure_control_plane_current || true
    if ! wait_client_management_listeners "$name"; then
        error "Client '${name}' tunnel is active, but CONTROL/subscription listeners are not reachable on its Server XFRM address."
        return 1
    fi
    registry_command apply >/dev/null 2>&1 || warn "Subscription/speed policy could not be reapplied for ${name}."
    success "Client '${name}' was repaired from the persistent registry, including its management plane."
}



require_root_and_platform () 
{ 
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run this installer as root.";
    [[ -f /etc/os-release ]] || die "Cannot identify the operating system.";
    source /etc/os-release;
    [[ "${ID:-}" == "debian" ]] || die "This installer supports Debian only. Detected: ${ID:-unknown}.";
    [[ -d /run/systemd/system ]] || die "systemd must be the active init system.";
    local required_command;
    for required_command in apt-get apt-cache dpkg-query systemctl ip awk sed grep flock;
    do
        command -v "$required_command" > /dev/null 2>&1 || die "Required Debian command is missing: ${required_command}";
    done
}

restore_egress_runtime_state () 
{ 
    if [[ -s "$IPTABLES_RUNTIME_BACKUP" ]] && command -v iptables-restore > /dev/null 2>&1; then
        iptables-restore < "$IPTABLES_RUNTIME_BACKUP" >> "$LOG_FILE" 2>&1 || true;
    else
        if [[ -f /etc/iptables/rules.v4 ]] && command -v netfilter-persistent > /dev/null 2>&1; then
            netfilter-persistent reload >> "$LOG_FILE" 2>&1 || true;
        fi;
    fi;
    if [[ -s "$IP6TABLES_RUNTIME_BACKUP" ]] && command -v ip6tables-restore > /dev/null 2>&1; then
        ip6tables-restore < "$IP6TABLES_RUNTIME_BACKUP" >> "$LOG_FILE" 2>&1 || true;
    fi;
    if [[ -s "$SYSCTL_RUNTIME_BACKUP" ]]; then
        local key value;
        while IFS='	' read -r key value; do
            [[ -n "$key" ]] || continue;
            sysctl -q -w "${key}=${value}" > /dev/null 2>&1 || true;
        done < "$SYSCTL_RUNTIME_BACKUP";
    fi
}

restore_originals ()
{
    [[ -f "$MANIFEST_FILE" ]] || return 0
    info 'Restoring files that existed before Dragon Fruit Relay was installed...'
    local state target
    while IFS=$'\t' read -r state target; do
        [[ -n "$target" ]] || continue
        case "$target" in "$CONFIG_DIR"|"$CONFIG_DIR"/*) continue ;; esac
        if awk -F '\t' -v target="$target" '$2 != target && index(target, $2 "/") == 1 {found=1} END {exit !found}' "$MANIFEST_FILE"; then continue; fi
        rm -rf -- "$target"
        if [[ "$state" == present ]]; then
            local saved="${BACKUP_DIR}/files${target}"
            dragonfruit_owned_symlink "$saved" && continue
            mkdir -p "$(dirname "$target")"; cp -a "$saved" "$target"
        fi
    done < "$MANIFEST_FILE"
}

restore_package_state () 
{ 
    [[ -f "$PACKAGE_STATE_FILE" ]] || return 0;
    local reinstall=();
    local package state;
    while IFS='=' read -r package state; do
        case "$package" in 
            RESOLVED_WAS_ACTIVE | RESOLVED_WAS_ENABLED | *_UNIT_EXISTED | *_UNIT_WAS_ACTIVE | *_UNIT_WAS_ENABLED)
                continue
            ;;
        esac;
        if [[ "$state" == 'present' ]] && ! package_installed "$package"; then
            reinstall+=("$package");
        fi;
    done < "$PACKAGE_STATE_FILE";
    if ((${#reinstall[@]})); then
        info 'Reinstalling packages that existed before Dragon Fruit Relay...';
        export DEBIAN_FRONTEND=noninteractive;
        apt-get update >> "$LOG_FILE" 2>&1;
        apt-get install -y "${reinstall[@]}" >> "$LOG_FILE" 2>&1;
    fi
}

restore_pre_routevpn_state () 
{ 
    local role="$1";
    restore_package_state;
    restore_originals;
    systemctl daemon-reload > /dev/null 2>&1 || true;
    systemctl reset-failed > /dev/null 2>&1 || true;
    if [[ -f "$PACKAGE_STATE_FILE" ]]; then
        local ra re;
        ra=$(awk -F= '$1=="RESOLVED_WAS_ACTIVE" {print $2}' "$PACKAGE_STATE_FILE");
        re=$(awk -F= '$1=="RESOLVED_WAS_ENABLED" {print $2}' "$PACKAGE_STATE_FILE");
        [[ "$re" == yes ]] && systemctl enable systemd-resolved.service > /dev/null 2>&1 || true;
        [[ "$ra" == yes ]] && systemctl start systemd-resolved.service > /dev/null 2>&1 || true;
    fi;
    sysctl --system >> "$LOG_FILE" 2>&1 || true;
    if [[ "$role" == egress ]]; then
        restore_egress_runtime_state;
    fi;
    restore_unit_state strongswan.service STRONGSWAN;
    if [[ "$role" == egress ]]; then
        restore_unit_state netfilter-persistent.service NETFILTER;
    else
        if [[ "$role" == ingress ]]; then
            reload_dhcpcd_configuration "${WAN_IF:-}";
        fi;
    fi;
    return 0
}

restore_unit_state () 
{ 
    local unit="$1" prefix="$2";
    [[ -f "$PACKAGE_STATE_FILE" ]] || return 0;
    local existed active enabled;
    existed=$(awk -F= -v key="${prefix}_UNIT_EXISTED" '$1==key {print $2}' "$PACKAGE_STATE_FILE");
    active=$(awk -F= -v key="${prefix}_UNIT_WAS_ACTIVE" '$1==key {print $2}' "$PACKAGE_STATE_FILE");
    enabled=$(awk -F= -v key="${prefix}_UNIT_WAS_ENABLED" '$1==key {print $2}' "$PACKAGE_STATE_FILE");
    if [[ "$existed" != "yes" ]]; then
        systemctl disable --now "$unit" > /dev/null 2>&1 || true;
        return 0;
    fi;
    if [[ "$enabled" == "yes" ]]; then
        systemctl enable "$unit" > /dev/null 2>&1 || true;
    else
        systemctl disable "$unit" > /dev/null 2>&1 || true;
    fi;
    if [[ "$active" == "yes" ]]; then
        systemctl restart "$unit" > /dev/null 2>&1 || true;
    else
        systemctl stop "$unit" > /dev/null 2>&1 || true;
    fi
}


rollback_hub_initialization () 
{ 
    warn 'Server initialization failed. Restoring the complete pre-install state...';
    local name;
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue;
        remove_hub_client "$name" yes || true;
    done < <(profile_names);
    systemctl disable --now 'dragon-fruit-relay-client@*.service' > /dev/null 2>&1 || true;
    rm -f "$CLIENT_UNIT_TEMPLATE";
    [[ -e "$SWANCTL_CLIENT_ROOT/.dragon-fruit-relay-root" ]] && rm -rf "$SWANCTL_CLIENT_ROOT" || true;
    [[ -e "$STRONGSWAN_CLIENT_ROOT/.dragon-fruit-relay-root" ]] && rm -rf "$STRONGSWAN_CLIENT_ROOT" || true;
    rm -rf "$CONFIG_DIR";
    rm -rf "$STATE_DIR";
    restore_pre_routevpn_state egress || true;
    systemctl daemon-reload > /dev/null 2>&1 || true;
    success 'Server rollback completed.'
}







run_tty_interruptible_command ()
{
    # Run an interactive foreground-style command without allowing terminal
    # Ctrl+C to signal Dragon Fruit Relay's entire process group. This matters
    # because the session is held by an outer flock --close wrapper: a normal
    # terminal SIGINT would kill that lock wrapper even if the inner menu shell
    # ignored SIGINT, handing the TTY back to the login shell while DFR kept
    # running in the background. Subsequent /dev/tty reads then fail with EIO.
    #
    # Instead, temporarily disable terminal ISIG, consume Ctrl+C as byte 0x03,
    # and deliver SIGINT only to the child command. Terminal state is restored
    # before returning to the menu.
    local status=0
    if python3 - "$@" > "$TTY_OUT" 2>&1 <<'PY_DFR_TTY_INTERRUPT'
import os
import select
import signal
import subprocess
import sys
import termios

cmd = sys.argv[1:]
if not cmd:
    raise SystemExit(2)

fd = None
saved = None
child = None
class SessionSignal(Exception):
    def __init__(self, signum):
        self.signum = signum


def session_signal(signum, _frame):
    raise SessionSignal(signum)

try:
    try:
        fd = os.open('/dev/tty', os.O_RDWR)
    except OSError as exc:
        print(f'Interactive terminal is unavailable: {exc}', file=sys.stderr)
        raise SystemExit(2)

    saved = termios.tcgetattr(fd)
    raw = termios.tcgetattr(fd)
    raw[3] &= ~(termios.ICANON | termios.ECHO | termios.ISIG)
    raw[6][termios.VMIN] = 1
    raw[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, raw)

    for signum in (signal.SIGHUP, signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, session_signal)

    child = subprocess.Popen(cmd, stdin=subprocess.DEVNULL)

    while True:
        rc = child.poll()
        if rc is not None:
            raise SystemExit(rc)

        readable, _, _ = select.select([fd], [], [], 0.20)
        if not readable:
            continue

        data = os.read(fd, 1)
        if data != b'\x03':
            # Live captures intentionally reserve keyboard input for Ctrl+C.
            # Other keystrokes are consumed so they cannot leak into the next
            # Dragon Fruit Relay menu prompt after the capture ends.
            continue

        try:
            child.send_signal(signal.SIGINT)
        except ProcessLookupError:
            pass

        try:
            rc = child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.terminate()
            try:
                rc = child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                child.kill()
                rc = child.wait()
        raise SystemExit(rc if rc is not None else 130)

except SessionSignal as exc:
    if child is not None and child.poll() is None:
        try:
            child.send_signal(signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            child.wait(timeout=2)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
    raise SystemExit(128 + exc.signum)
finally:
    if saved is not None and fd is not None:
        try:
            termios.tcsetattr(fd, termios.TCSANOW, saved)
        except Exception:
            pass
    if fd is not None:
        try:
            os.close(fd)
        except Exception:
            pass
PY_DFR_TTY_INTERRUPT
    then
        status=0
    else
        status=$?
    fi
    return "$status"
}

run_client_live_capture () 
{ 
    local name="$1" mode="$2";
    local capture_interface capture_filter='' status=0;
    local -a capture_args=();
    load_host_config;
    load_client_profile "$name";
    clear_screen;
    dfr_ui_header 'LIVE PACKET CAPTURE';
    command -v tcpdump > /dev/null 2>&1 || { 
        section_title "Live packet capture: ${name}";
        print_check fail 'tcpdump' 'Required command is not installed.';
        return 1
    };
    if ! ip link show dev "$XFRM_IF" > /dev/null 2>&1; then
        section_title "Live packet capture: ${name}";
        print_check fail 'XFRM interface' "${XFRM_IF} does not exist. Start the connection first.";
        return 1;
    fi;
    case "$mode" in 
        dns)
            section_title "Live DNS forwarding capture: ${name}";
            capture_interface='any';
            capture_filter="(host ${DNS_PRIMARY} or host ${DNS_SECONDARY}) and (udp port 53 or tcp port 53)";
            capture_args=(-i "$capture_interface" -nn -tttt -l -vv -s 512 "$capture_filter");
            print_check info 'Selected connection' "$name on $XFRM_IF" identity;
            print_check info 'DNS servers' "$DNS_PRIMARY, $DNS_SECONDARY";
            print_check info 'Expected query path' "$XFRM_IF In -> $WAN_IF Out";
            print_check info 'Expected reply path' "$WAN_IF In -> $XFRM_IF Out";
            printf '\n  Run a DNS lookup on the paired Client while this capture is active.\n' > "$TTY_OUT";
            printf '  Seeing the query on %s and then on %s verifies forwarding/NAT.\n' "$XFRM_IF" "$WAN_IF" > "$TTY_OUT"
        ;;
        traffic)
            section_title "Live tunnel traffic capture: ${name}";
            capture_interface="$XFRM_IF";
            capture_args=(-i "$capture_interface" -nn -tttt -l -vv);
            print_check info 'Capture interface' "$XFRM_IF" identity;
            print_check info 'Traffic shown' 'All decrypted traffic crossing this connection';
            printf '\n  Generate traffic on the paired Client to watch it cross the tunnel.\n' > "$TTY_OUT"
        ;;
        *)
            die "Unknown live-capture mode: ${mode}"
        ;;
    esac;
    if ! systemctl is-active --quiet "$(profile_service "$name")" 2> /dev/null; then
        print_check warn 'Connection service' 'Not active; the capture will wait for traffic.';
    fi;
    printf '  Press Ctrl+C to stop the live capture and return to diagnostics.\n\n' > "$TTY_OUT";
    log_line INFO "Starting live ${mode} capture for profile=${name} interface=${capture_interface}";
    if run_tty_interruptible_command tcpdump "${capture_args[@]}"; then
        status=0
    else
        status=$?
    fi
    printf '\n' > "$TTY_OUT";
    case "$status" in 
        0 | 2 | 130 | 143)
            print_check info 'Live capture' 'Stopped.'
        ;;
        *)
            print_check fail 'Live capture' "tcpdump exited with status ${status}.";
            return 1
        ;;
    esac
}


section_title ()
{
    local title="$1" width
    width=$(ui_content_width)
    printf '\n  %s%s%s%s\n' "$C_BOLD" "$C_MAGENTA" "$title" "$C_RESET" > "$TTY_OUT"
    printf '  %s%s%s\n' "$C_DIM" "$(ui_rule $'\u2500' "$width")" "$C_RESET" > "$TTY_OUT"
}


fleet_snapshot_file ()
{
    local dir tmp
    dir=$(dirname "$FLEET_UI_SNAPSHOT")
    install -d -m 0755 "$dir"
    tmp=$(mktemp "${dir}/.fleet-ui-snapshot.XXXXXX") || return 1

    # Monitoring state is authoritative per render.  Do not reuse a time-based
    # snapshot across screens: CONTROL presence can change between two menu
    # selections and the operator must never see different epochs in one UI.
    if ! registry_command fleet-snapshot --json > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi

    if ! python3 - "$tmp" <<'PY_FLEET_VALIDATE'
import json,sys
with open(sys.argv[1], 'r', encoding='utf-8') as fh:
    data=json.load(fh)
if not isinstance(data, dict) or not isinstance(data.get('connections', []), list):
    raise SystemExit(1)
PY_FLEET_VALIDATE
    then
        rm -f "$tmp"
        return 1
    fi

    chmod 0600 "$tmp"
    mv -f "$tmp" "$FLEET_UI_SNAPSHOT"
    printf '%s' "$FLEET_UI_SNAPSHOT"
}

ui_terminal_lines ()
{
    local lines
    lines=$(tput lines 2>/dev/null || printf '24')
    [[ "$lines" =~ ^[0-9]+$ ]] || lines=24
    printf '%s' "$lines"
}

ui_content_width ()
{
    local cols width
    cols=$(ui_terminal_columns)
    width=$((cols-4))
    ((width < 36)) && width=36
    printf '%s' "$width"
}

ui_rule ()
{
    local char="${1:--}" width="${2:-}"
    local rule
    [[ "$width" =~ ^[0-9]+$ ]] || width=$(ui_content_width)
    printf -v rule '%*s' "$width" ''
    rule=${rule// /$char}
    printf '%s' "$rule"
}

ui_timezone_label ()
{
    local zone offset
    zone=$(date '+%Z' 2>/dev/null || printf 'LOCAL')
    offset=$(date '+%z' 2>/dev/null || true)
    if [[ -n "$offset" ]]; then
        printf '%s (UTC%s)' "$zone" "$offset"
    else
        printf '%s' "$zone"
    fi
}

ui_timezone_line ()
{
    printf '  %sTimezone:%s %s\n' "$C_DIM" "$C_RESET" "$(ui_timezone_label)" > "$TTY_OUT"
}

ui_table_page_size ()
{
    local reserved="${1:-16}" max_rows="${2:-15}" lines rows
    lines=$(ui_terminal_lines)
    rows=$((lines-reserved))
    ((rows < 6)) && rows=6
    ((rows > max_rows)) && rows=$max_rows
    printf '%s' "$rows"
}

ui_panel_title ()
{
    local title="$1" state="${2:-}" color="${3:-}" width
    width=$(ui_content_width)
    [[ -n "$color" ]] || color=$(semantic_state_color "${state:-READY}")
    printf '\n  %s%s%s%s' "$C_BOLD" "$C_CYAN" "$title" "$C_RESET" > "$TTY_OUT"
    if [[ -n "$state" ]]; then
        printf '  %s[%s%s%s]%s' "$C_DIM" "$color" "$state" "$C_DIM" "$C_RESET" > "$TTY_OUT"
    fi
    printf '\n  %s%s%s\n' "$C_DIM" "$(ui_rule $'\u2500' "$width")" "$C_RESET" > "$TTY_OUT"
}

ui_menu_role_color ()
{
    case "${1:-neutral}" in
        positive) printf '%s' "$C_GREEN" ;;
        caution) printf '%s' "$C_YELLOW" ;;
        destructive) printf '%s' "$C_RED" ;;
        navigation) printf '%s' "$C_MAGENTA" ;;
        back) printf '%s' "$C_DIM" ;;
        *) printf '%s' "$C_CYAN" ;;
    esac
}

ui_menu_item ()
{
    local key="$1" label="$2" role="${3:-neutral}" color
    color=$(ui_menu_role_color "$role")
    printf '  %s%5s%s  %s\n' "$color" "[$key]" "$C_RESET" "$label" > "$TTY_OUT"
}

ui_status_menu_item ()
{
    local key="$1" label="$2"
    printf '  %s%5s%s  ' "$C_CYAN" "[$key]" "$C_RESET" > "$TTY_OUT"
    semantic_colorize_line "$label" > "$TTY_OUT"
    printf '\n' > "$TTY_OUT"
}

ui_navigation_footer ()
{
    local include_main="${1:-no}"
    # Navigation is intentionally separated from operational actions. Numbers
    # select/execute; letters navigate or manipulate the current view.
    printf '\n' > "$TTY_OUT"
    section_title 'Navigation'
    [[ "$include_main" == yes ]] && ui_menu_item M 'Main Menu' navigation
    ui_menu_item G 'Navigate' navigation
    ui_menu_item B 'Back' back
    ui_menu_item Q 'Exit' destructive
}

ui_view_controls ()
{
    local mode="${1:-basic}"
    printf '\n  %s%-11s%s ' "$C_DIM" 'VIEW' "$C_RESET" > "$TTY_OUT"
    printf '%s[N]%s Next  %s[P]%s Previous' "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" > "$TTY_OUT"
    case "$mode" in
        search|filter) printf '  %s[S]%s Search' "$C_CYAN" "$C_RESET" > "$TTY_OUT" ;;
    esac
    [[ "$mode" == filter ]] && printf '  %s[F]%s Filter' "$C_CYAN" "$C_RESET" > "$TTY_OUT"
    printf '  %s[R]%s Refresh\n' "$C_CYAN" "$C_RESET" > "$TTY_OUT"
}

ui_navigation_controls ()
{
    local include_main="${1:-no}"
    printf '  %s%-11s%s ' "$C_BOLD$C_MAGENTA" 'NAVIGATION' "$C_RESET" > "$TTY_OUT"
    [[ "$include_main" == yes ]] && printf '%s[M]%s Main Menu  ' "$C_MAGENTA" "$C_RESET" > "$TTY_OUT"
    printf '%s[G]%s Navigate  %s[B]%s Back  %s[Q]%s Exit\n' \
        "$C_MAGENTA" "$C_RESET" "$C_DIM" "$C_RESET" "$C_RED" "$C_RESET" > "$TTY_OUT"
}

ui_kv_table_begin ()
{
    local left="${1:-FIELD}" right="${2:-VALUE}" cols label_width value_width
    cols=$(ui_content_width)
    label_width=28
    ((cols < 84)) && label_width=22
    value_width=$((cols-label_width-3))
    ((value_width < 24)) && value_width=24
    UI_KV_TABLE_LABEL_WIDTH=$label_width
    UI_KV_TABLE_VALUE_WIDTH=$value_width
    printf '  %s%-*s | %-*s%s\n' "$C_DIM" "$label_width" "$left" "$value_width" "$right" "$C_RESET" > "$TTY_OUT"
    printf '  %s%s%s\n' "$C_DIM" "$(ui_rule $'─')" "$C_RESET" > "$TTY_OUT"
}

ui_kv_table_row ()
{
    local label="$1" value="${2:--}" kind="${3:-info}" line first=yes rendered
    local label_width="${UI_KV_TABLE_LABEL_WIDTH:-28}" value_width="${UI_KV_TABLE_VALUE_WIDTH:-48}"
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$kind" in
            muted) rendered="${C_DIM}${line}${C_RESET}" ;;
            identity|plain|accent|info|count) rendered="$line" ;;
            *) rendered=$(semantic_colorize_line "$line") ;;
        esac
        if [[ "$first" == yes ]]; then
            printf '  %s%-*s%s | %s\n' "$C_DIM" "$label_width" "$label" "$C_RESET" "$rendered" > "$TTY_OUT"
            first=no
        else
            printf '  %-*s | %s\n' "$label_width" '' "$rendered" > "$TTY_OUT"
        fi
    done < <(printf '%s\n' "$value" | fold -s -w "$value_width")
}

ui_jump_main_menu ()
{
    local command="$CLI_COMMAND"
    [[ -x "$command" ]] || command="$0"
    exec env DFR_INTERNAL_NO_MAIN_LOCK=1 "$command" menu
}

ui_global_navigation ()
{
    local choice
    while hub_configured; do
        clear_screen
        dfr_ui_header 'NAVIGATE'
        section_title 'Go to'
        ui_menu_item 1 'Operations Center' neutral
        ui_menu_item 2 'Connections' neutral
        ui_menu_item 3 'Server Operations' neutral
        ui_menu_item 5 'Client Software' neutral
        ui_menu_item 6 'Backups' neutral
        ui_menu_item 7 'Server Logs' neutral

        printf '\n' > "$TTY_OUT"
        section_title 'Navigation'
        ui_menu_item M 'Main Menu' navigation
        ui_menu_item B 'Back' back
        ui_menu_item Q 'Exit' destructive
        choice=$(prompt '  Select destination: ') || return 0
        case "$choice" in
            1) operations_center_workspace; ui_jump_main_menu ;;
            2) client_connections_workspace; ui_jump_main_menu ;;
            3) server_operations_workspace; ui_jump_main_menu ;;
            5) ingress_release_workspace; ui_jump_main_menu ;;
            6) backup_workspace; ui_jump_main_menu ;;
            7) hub_history_screen; pause_screen; ui_jump_main_menu ;;
            m|M|00) ui_jump_main_menu ;;
            b|B|0) return 0 ;;
            q|Q|99) exit 0 ;;
            *) warn 'Invalid selection.'; sleep 0.35 ;;
        esac
    done
}

ui_page_size ()
{
    ui_table_page_size 16 15
}

ui_terminal_columns ()
{
    local cols
    cols=$(tput cols 2>/dev/null || printf '80')
    [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
    printf '%s' "$cols"
}

ui_connection_page_size ()
{
    # Connection rows are always single-line. Terminal awareness changes
    # column widths/optional columns, never the row structure.
    ui_page_size
}

ui_attention_page_size ()
{
    ui_table_page_size 18 15
}

ui_activity_page_size ()
{
    ui_table_page_size 17 15
}

fleet_summary_line ()
{
    local snapshot="$1"
    python3 - "$snapshot" <<'PY_FLEET_SUMMARY'
import json,sys
try: d=json.load(open(sys.argv[1], encoding='utf-8')); s=d.get('summary') or {}
except Exception: s={}
print(f"{int(s.get('total',0))}\t{int(s.get('operational',0))}\t{int(s.get('ready',0))}\t{int(s.get('stopped',0))}\t{int(s.get('degraded',0))}\t{int(s.get('failed',0))}\t{int(s.get('online',0))}\t{int(s.get('stale',0))}\t{int(s.get('offline',0))}\t{int(s.get('never_seen',0))}\t{int(s.get('attention',0))}\t{int(s.get('critical',0))}\t{int(s.get('warning',0))}\t{int(s.get('advisory',0))}\t{int(s.get('active_work',0))}")
PY_FLEET_SUMMARY
}

fleet_ops_client_summary_line ()
{
    local snapshot="$1"
    python3 - "$snapshot" <<'PY_FLEET_OPS_CLIENTS'
import json,sys
try:
    d=json.load(open(sys.argv[1], encoding='utf-8')); s=d.get('summary') or {}
except Exception:
    s={}
print(f"{int(s.get('attention_clients',0))}\t{int(s.get('attention',0))}\t{int(s.get('active_work_clients',0))}\t{int(s.get('active_work',0))}")
PY_FLEET_OPS_CLIENTS
}



fleet_row_status_color ()
{
    status_color_for "${1:-UNKNOWN}"
}

fleet_presence_color ()
{
    semantic_state_color "${1:-UNKNOWN}"
}

fleet_filter_prompt ()
{
    local choice
    section_title 'Filter'
    ui_status_menu_item 1 'All connections'
    ui_status_menu_item 2 'Attention only'
    ui_status_menu_item 3 'Online'
    ui_status_menu_item 4 'Offline / stale'
    ui_status_menu_item 5 'Operational'
    ui_status_menu_item 6 'Stopped / degraded / failed'
    ui_menu_item B 'Back' back
    choice=$(prompt '  Filter: ')
    case "$choice" in
        1) printf 'all' ;;
        2) printf 'attention' ;;
        3) printf 'online' ;;
        4) printf 'offline' ;;
        5) printf 'operational' ;;
        6) printf 'issues' ;;
        b|B|0) return 1 ;;
        *) return 1 ;;
    esac
}

select_client_interactive ()
{
    local initial_filter="${1:-all}"
    local snapshot page=1 page_size filter="$initial_filter" search='' choice selected meta total_pages total_rows cols
    local row index name uuid status presence last_seen port peer software status_color presence_color
    cols=$(ui_terminal_columns)
    page_size=$(ui_connection_page_size)

    snapshot=$(fleet_snapshot_file 2>/dev/null || true)
    [[ -n "$snapshot" ]] || { warn 'Fleet snapshot is unavailable.'; return 1; }

    while true; do
        clear_screen
        dfr_ui_header 'CONNECTIONS'

        meta=$(python3 - "$snapshot" "$filter" "$search" "$page" "$page_size" <<'PY_FLEET_META'
import json,re,sys
D=json.load(open(sys.argv[1], encoding='utf-8')); mode=sys.argv[2]; search=sys.argv[3].strip().lower(); page=max(1,int(sys.argv[4])); size=max(1,int(sys.argv[5]))
attention={x.get('connection_name') for x in D.get('attention',[])}
def keep(x):
    if search and search not in str(x.get('name','')).lower() and search not in str(x.get('connection_uuid','')).lower() and search not in str(x.get('uuid_short','')).lower(): return False
    if mode=='attention' and x.get('name') not in attention: return False
    if mode=='online' and x.get('presence')!='ONLINE': return False
    if mode=='offline' and x.get('presence') not in ('STALE','OFFLINE'): return False
    if mode=='operational' and x.get('runtime_status')!='OPERATIONAL': return False
    if mode=='issues' and x.get('runtime_status') not in ('STOPPED','DEGRADED','FAILED','MISSING'): return False
    return True
rows=[x for x in D.get('connections',[]) if keep(x)]
pages=max(1,(len(rows)+size-1)//size); page=min(page,pages)
print(f'{page}\t{pages}\t{len(rows)}')
PY_FLEET_META
)
        IFS=$'\t' read -r page total_pages total_rows <<<"$meta"

        fleet_print_compact_summary "$snapshot"

        # One row format everywhere. Wider terminals reveal more context;
        # narrower terminals preserve the same columns/order with tighter widths.
        local name_w uuid_w status_w presence_w seen_w port_w peer_w show_peer
        if ((cols >= 120)); then
            name_w=20; uuid_w=12; status_w=12; presence_w=11; seen_w=10; port_w=6; peer_w=22; show_peer=yes
        elif ((cols >= 96)); then
            name_w=18; uuid_w=12; status_w=11; presence_w=10; seen_w=9; port_w=5; peer_w=15; show_peer=yes
        elif ((cols >= 76)); then
            name_w=16; uuid_w=12; status_w=11; presence_w=9; seen_w=8; port_w=5; peer_w=0; show_peer=no
        else
            name_w=12; uuid_w=10; status_w=9; presence_w=8; seen_w=7; port_w=5; peer_w=0; show_peer=no
        fi

        if [[ "$show_peer" == yes ]]; then
            printf '\n  %s%-3s %-*s %-*s %-*s %-*s %-*s %-*s %s%s\n' \
                "$C_DIM" '#' "$name_w" 'NAME' "$uuid_w" 'UUID' "$status_w" 'STATUS' \
                "$presence_w" 'PRESENCE' "$seen_w" 'LAST SEEN' "$port_w" 'PORT' 'REMOTE PEER' "$C_RESET" > "$TTY_OUT"
        else
            printf '\n  %s%-3s %-*s %-*s %-*s %-*s %-*s %-*s%s\n' \
                "$C_DIM" '#' "$name_w" 'NAME' "$uuid_w" 'UUID' "$status_w" 'STATUS' \
                "$presence_w" 'PRESENCE' "$seen_w" 'LAST SEEN' "$port_w" 'PORT' "$C_RESET" > "$TTY_OUT"
        fi

        while IFS=$'\t' read -r index name uuid status presence last_seen port peer software; do
            [[ -n "$name" ]] || continue
            status_color=$(fleet_row_status_color "$status")
            presence_color=$(fleet_presence_color "$presence")
            if [[ "$show_peer" == yes ]]; then
                printf '  %s[%s]%s %-*s %-*s %s%-*s%s %s%-*s%s %-*s %-*s %s\n' \
                    "$C_CYAN" "$index" "$C_RESET" \
                    "$name_w" "$(fit_text "$name" "$name_w")" "$uuid_w" "$(fit_text "$uuid" "$uuid_w")" \
                    "$status_color" "$status_w" "$(fit_text "$status" "$status_w")" "$C_RESET" \
                    "$presence_color" "$presence_w" "$(fit_text "$presence" "$presence_w")" "$C_RESET" \
                    "$seen_w" "$(fit_text "$(fleet_age_text "$last_seen")" "$seen_w")" \
                    "$port_w" "$port" "$(fit_text "$peer" "$peer_w")" > "$TTY_OUT"
            else
                printf '  %s[%s]%s %-*s %-*s %s%-*s%s %s%-*s%s %-*s %-*s\n' \
                    "$C_CYAN" "$index" "$C_RESET" \
                    "$name_w" "$(fit_text "$name" "$name_w")" "$uuid_w" "$(fit_text "$uuid" "$uuid_w")" \
                    "$status_color" "$status_w" "$(fit_text "$status" "$status_w")" "$C_RESET" \
                    "$presence_color" "$presence_w" "$(fit_text "$presence" "$presence_w")" "$C_RESET" \
                    "$seen_w" "$(fit_text "$(fleet_age_text "$last_seen")" "$seen_w")" \
                    "$port_w" "$port" > "$TTY_OUT"
            fi
        done < <(python3 - "$snapshot" "$filter" "$search" "$page" "$page_size" <<'PY_FLEET_ROWS'
import json,sys
D=json.load(open(sys.argv[1], encoding='utf-8')); mode=sys.argv[2]; search=sys.argv[3].strip().lower(); page=max(1,int(sys.argv[4])); size=max(1,int(sys.argv[5]))
attention={x.get('connection_name') for x in D.get('attention',[])}
def keep(x):
    if search and search not in str(x.get('name','')).lower() and search not in str(x.get('connection_uuid','')).lower() and search not in str(x.get('uuid_short','')).lower(): return False
    if mode=='attention' and x.get('name') not in attention: return False
    if mode=='online' and x.get('presence')!='ONLINE': return False
    if mode=='offline' and x.get('presence') not in ('STALE','OFFLINE'): return False
    if mode=='operational' and x.get('runtime_status')!='OPERATIONAL': return False
    if mode=='issues' and x.get('runtime_status') not in ('STOPPED','DEGRADED','FAILED','MISSING'): return False
    return True
rows=[x for x in D.get('connections',[]) if keep(x)]
start=(page-1)*size
for i,x in enumerate(rows[start:start+size],1):
    vals=(i,x.get('name','-'),x.get('uuid_short','-'),x.get('runtime_status','UNKNOWN'),x.get('presence','UNKNOWN'),x.get('last_seen_at',0),x.get('udp_port',0),x.get('remote_peer','-'),x.get('software_state','UNKNOWN'))
    print('\t'.join(str(v).replace('\t',' ').replace('\n',' ') for v in vals))
PY_FLEET_ROWS
)

        printf '\n  %sPage %s/%s · %s matching · filter %s%s' "$C_DIM" "$page" "$total_pages" "$total_rows" "${filter^^}" "$C_RESET" > "$TTY_OUT"
        [[ -n "$search" ]] && printf ' · search "%s"' "$search" > "$TTY_OUT"
        printf '\n' > "$TTY_OUT"
        ui_view_controls filter
        ui_navigation_controls
        printf '\n' > "$TTY_OUT"

        choice=$(prompt '  Select connection or action: ')
        case "$choice" in
            n|N|16) if ((page < total_pages)); then page=$((page+1)); fi ;;
            p|P|17) if ((page > 1)); then page=$((page-1)); fi ;;
            s|S|18) search=$(prompt '  Search name or UUID (empty clears): '); page=1 ;;
            f|F|19) filter=$(fleet_filter_prompt) || true; page=1 ;;
            r|R|20) snapshot=$(fleet_snapshot_file 2>/dev/null || true); page=1 ;;
            g|G|90) ui_global_navigation ;;
            b|B|0) return 1 ;;
            q|Q|99) exit 0 ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]]; then
                    selected=$(python3 - "$snapshot" "$filter" "$search" "$page" "$page_size" "$choice" <<'PY_FLEET_SELECT'
import json,sys
D=json.load(open(sys.argv[1], encoding='utf-8')); mode=sys.argv[2]; search=sys.argv[3].strip().lower(); page=max(1,int(sys.argv[4])); size=max(1,int(sys.argv[5])); pick=int(sys.argv[6])
attention={x.get('connection_name') for x in D.get('attention',[])}
def keep(x):
    if search and search not in str(x.get('name','')).lower() and search not in str(x.get('connection_uuid','')).lower() and search not in str(x.get('uuid_short','')).lower(): return False
    if mode=='attention' and x.get('name') not in attention: return False
    if mode=='online' and x.get('presence')!='ONLINE': return False
    if mode=='offline' and x.get('presence') not in ('STALE','OFFLINE'): return False
    if mode=='operational' and x.get('runtime_status')!='OPERATIONAL': return False
    if mode=='issues' and x.get('runtime_status') not in ('STOPPED','DEGRADED','FAILED','MISSING'): return False
    return True
rows=[x for x in D.get('connections',[]) if keep(x)]
start=(page-1)*size; page_rows=rows[start:start+size]
if 1 <= pick <= len(page_rows): print(page_rows[pick-1].get('name',''))
PY_FLEET_SELECT
)
                    [[ -n "$selected" ]] && { printf '%s' "$selected"; return 0; }
                fi
                warn 'Invalid selection.'; sleep 0.35 ;;
        esac
    done
}

service_row ()
{
    local unit="$1" label="${2:-$1}"
    local load active sub enabled result badge display display_color enabled_text result_text
    load=$(systemctl show "$unit" -p LoadState --value 2>/dev/null || true)
    active=$(systemctl show "$unit" -p ActiveState --value 2>/dev/null || true)
    sub=$(systemctl show "$unit" -p SubState --value 2>/dev/null || true)
    enabled=$(systemctl is-enabled "$unit" 2>/dev/null || true)
    result=$(systemctl show "$unit" -p Result --value 2>/dev/null || true)
    if [[ "$load" == 'not-found' || -z "$load" ]]; then
        badge='X'; display='NOT FOUND'
    elif [[ "$active" == 'active' ]]; then
        badge='●'
        case "$sub" in running) display='RUNNING' ;; exited) display='READY' ;; waiting) display='WAITING' ;; *) display="${sub^^}" ;; esac
    elif [[ "$active" == 'failed' ]]; then
        badge='X'; display='FAILED'
    elif [[ "$active" == 'activating' ]]; then
        badge='●'; display='ACTIVATING'
    elif [[ "$active" == 'deactivating' ]]; then
        badge='○'; display='DEACTIVATING'
    else
        badge='○'; display="${active^^}"
    fi
    display_color=$(semantic_state_color "$display")
    enabled_text="${enabled:-unknown}"; result_text="${result:-n/a}"
    printf '  %-31s %s%s %-12s%s  ' "$label" "$display_color" "$badge" "$display" "$C_RESET" > "$TTY_OUT"
    semantic_colorize_line "$enabled_text" > "$TTY_OUT"
    printf '  ' > "$TTY_OUT"
    semantic_colorize_line "$result_text" > "$TTY_OUT"
    printf '\n' > "$TTY_OUT"
}


# Dragon Fruit Relay current persistent registry, management, subscription and recovery layer.
validate_server_endpoint ()
{
    local value
    value=$(normalize_server_endpoint "${1:-}")
    validate_ipv4 "$value" && return 0
    [[ ${#value} -le 253 && "$value" == *.* ]] || return 1
    [[ "$value" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]]
}

normalize_server_endpoint ()
{
    local value="${1,,}"
    printf '%s' "${value%.}"
}

resolve_endpoint_ipv4s ()
{
    local fqdn="$1"
    getent ahostsv4 "$fqdn" 2>/dev/null | awk '$2=="STREAM" {print $1}' | sort -Vu
}

prompt_egress_endpoint ()
{
    local detected_public="$1" answer value resolved count
    printf '\n  Detected public IPv4: %s\n\n' "$detected_public" > "$TTY_OUT"
    answer=$(prompt '  Use a domain name for the Server endpoint? [y/N]: ')
    case "${answer,,}" in
        y|yes)
            while true; do
                value=$(prompt '  Server endpoint domain: ')
                value=$(normalize_server_endpoint "$value")
                if validate_ipv4 "$value" || ! validate_server_endpoint "$value"; then
                    warn 'Enter a normal DNS hostname such as relay.example.com.'
                    continue
                fi
                resolved=$(resolve_endpoint_ipv4s "$value" || true)
                count=$(grep -c . <<<"$resolved" || true)
                if [[ "$count" -ne 1 ]]; then
                    warn "${value} must resolve to exactly one public IPv4 address; found ${count}."
                    continue
                fi
                if [[ "$resolved" != "$detected_public" ]]; then
                    warn "DNS resolves ${value} to ${resolved}, but this Server is ${detected_public}."
                    continue
                fi
                print_check pass 'Server endpoint' "$value" accent
                printf '%s' "$value"
                return 0
            done
            ;;
        *)
            print_check pass 'Server endpoint' "$detected_public" accent
            printf '%s' "$detected_public"
            ;;
    esac
}


# DFR_REGISTRY_RUNTIME_API_SELF_HEAL
registry_runtime_api_ok_current ()
{
    local info

    [[ -x "$REGISTRY_HELPER" ]] || return 1

    # Schema 1 physically removes retired database layout. The helper still
    # is generated for the exact current schema, so currentness is
    # established by positive runtime capabilities and current schema markers.
    grep -Fq "SCHEMA = ${REGISTRY_SCHEMA_CURRENT}" "$REGISTRY_HELPER" 2>/dev/null || return 1
    grep -Fq 'config_pending' "$REGISTRY_HELPER" 2>/dev/null || return 1
    grep -Fq 'ingress_sha256' "$REGISTRY_HELPER" 2>/dev/null || return 1
    grep -Fq 'desired_ingress_source' "$REGISTRY_HELPER" 2>/dev/null || return 1
    grep -Fq 'server_endpoint_fallbacks' "$REGISTRY_HELPER" 2>/dev/null || return 1
    grep -Fq 'maintain_auto_updates' "$REGISTRY_HELPER" 2>/dev/null || return 1
    grep -Fq 'software_state_for' "$REGISTRY_HELPER" 2>/dev/null || return 1
    grep -Fq 'registry-monitoring-v1' "$REGISTRY_HELPER" 2>/dev/null || return 1
    grep -Fq 'software-auto-convergence-v1' "$REGISTRY_HELPER" 2>/dev/null || return 1
    grep -Fq 'software-current-sha-v1' "$REGISTRY_HELPER" 2>/dev/null || return 1
    grep -Fq 'server-endpoint-retarget-v1' "$REGISTRY_HELPER" 2>/dev/null || return 1
    grep -Fq 'fleet-snapshot-v1' "$REGISTRY_HELPER" 2>/dev/null || return 1
    grep -Fq 'presence-observability-v1' "$REGISTRY_HELPER" 2>/dev/null || return 1

    info=$("$REGISTRY_HELPER" runtime-info 2>/dev/null) || return 1

    python3 - "$info" "$APP_VERSION" "$REGISTRY_SCHEMA_CURRENT" "$REGISTRY_RUNTIME_API_REQUIRED" <<'PY_REGISTRY_RUNTIME_CHECK'
import json
import sys

try:
    data=json.loads(sys.argv[1])
    expected_version=sys.argv[2]
    expected_schema=int(sys.argv[3])
    expected_api=int(sys.argv[4])

    required={
        "release-info",
        "release-delete",
        "release-publish",
        "release-status",
        "management-show",
        "config-stage",
        "config-transaction-v3",
        "management-observability-v1",
        "release-purge",
        "subscription-reset-v1",
        "management-effective-health-v1",
        "release-sha-update-v1",
        "server-endpoint-sync-v2",
        "server-endpoint-auto-orchestration-v1",
        "server-endpoint-retarget-v1",
        "server-client-ui-v1",
        "server-client-ui-v2",
        "fleet-snapshot-v1",
        "presence-observability-v1",
        "registry-monitoring-v1",
        "registry-live-daemon-v1",
        "software-auto-convergence-v1",
        "software-current-sha-v1",
    }

    capabilities=set(data.get("capabilities") or [])

    ok=(
        data.get("app_version") == expected_version
        and int(data.get("schema",0)) == expected_schema
        and int(data.get("runtime_api",0)) == expected_api
        and required.issubset(capabilities)
    )
except Exception:
    ok=False

raise SystemExit(0 if ok else 1)
PY_REGISTRY_RUNTIME_CHECK
}

ensure_release_registry_api_current ()
{
    registry_runtime_api_ok_current && return 0

    warn 'Registry control-plane helper is older than this engine; regenerating it now.'

    ensure_registry_current

    registry_runtime_api_ok_current ||
        die 'Registry control-plane API repair failed. Release management was not opened.'

    return 0
}

write_registry_runtime_files ()
{
    ensure_hub_layout
    install -d -m 0700 "$REGISTRY_DIR" "$REGISTRY_BACKUP_DIR"

    cat > "$REGISTRY_HELPER" <<'PY_DFR_REGISTRY'
#!/usr/bin/env python3
import argparse, base64, datetime as dt, hashlib, hmac, ipaddress, json, os, pathlib, re, secrets, shlex, shutil, sqlite3, subprocess, sys, tarfile, tempfile, time, uuid

APP_VERSION = "v2.1.0"
SCHEMA = 1
RUNTIME_API = 1
ENROLLMENT_TOKEN_VERSION = 1
ROOT = pathlib.Path(os.environ.get("DFR_STATE_ROOT", "/var/lib/dragon-fruit-relay"))
DB_DIR = ROOT / "database"
DB = pathlib.Path(os.environ.get("DFR_REGISTRY_DB", str(DB_DIR / "registry.sqlite3")))
BACKUPS = pathlib.Path(os.environ.get("DFR_BACKUP_DIR", str(ROOT / "backups")))
CONFIG_ROOT = pathlib.Path(os.environ.get("DFR_CONFIG_ROOT", "/etc/dragon-fruit-relay"))
UPDATE_SIGNING_KEY = CONFIG_ROOT / "secrets" / "ingress-update-ed25519.key"
UPDATE_PUBLIC_KEY = CONFIG_ROOT / "secrets" / "ingress-update-ed25519.pub"
RELEASE_ROOT = ROOT / "releases" / "ingress"
NFT = os.environ.get("DFR_NFT", "nft")
TC = os.environ.get("DFR_TC", "tc")
SUB_TABLE = "dragon_fruit_relay_subscriptions"
GLOBAL_SPEED_TABLE = "dragon_fruit_relay_global_speed"
ENDPOINT_SYNC_CAPABILITY = "server-endpoint-sync-v2"
DAEMON_RUNTIME_ID = "dfr-schema1-monitoring-live-v1"
DAEMON_RUNTIME_STATE = pathlib.Path(os.environ.get(
    "DFR_REGISTRY_RUNTIME_STATE",
    "/run/dragon-fruit-relay/registry-runtime.json",
))

def now(): return int(time.time())
def utc_iso(ts=None):
    ts = now() if ts is None else int(ts)
    return dt.datetime.fromtimestamp(ts, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def conn():
    DB.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    c = sqlite3.connect(DB, timeout=5)
    try: os.chmod(DB, 0o600)
    except OSError: pass
    c.row_factory = sqlite3.Row
    c.execute("PRAGMA journal_mode=WAL")
    c.execute("PRAGMA synchronous=FULL")
    c.execute("PRAGMA foreign_keys=ON")
    c.execute("PRAGMA busy_timeout=5000")
    return c

def _table_exists(c,name):
    return c.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
        (name,),
    ).fetchone() is not None


def _columns(c,name):
    if not _table_exists(c,name):
        return []
    return [str(r[1]) for r in c.execute(f"PRAGMA table_info({name})")]


HUB_COLUMNS=(
    'id','endpoint','created_at','updated_at','endpoint_changed_at','endpoint_completed_at',
)
SERVER_POLICY_COLUMNS=('id','max_upload_mbps','max_download_mbps','updated_at')
CONNECTION_COLUMNS=(
    'name','profile_index','created_at','udp_port','tunnel_cidr','xfrm_if','xfrm_id','xfrm_mtu',
    'ingress_xfrm_cidr','egress_xfrm_cidr','ingress_xfrm_ip','egress_xfrm_ip',
    'ingress_id','egress_id','psk','dns_primary','dns_secondary','updated_at',
    'connection_uuid','control_key','desired_ingress_version','desired_ingress_source',
    'update_policy','pending_action',
)
INGRESS_STATE_COLUMNS=(
    'connection_name','ingress_version','ingress_sha256','health','update_status','last_error',
    'last_seen_at','last_nonce','pending_control_key','enrollment_token_hash','bootstrap_psk_state',
    'update_target','update_error','update_started_at','update_finished_at',
    'action_name','action_status','action_message','action_started_at','action_finished_at',
    'client_endpoint','endpoint_error','endpoint_updated_at','client_capabilities_json','update_sha256',
)
SCHEMA_TABLE_COLUMNS={
    'meta':('key','value'),
    'hub':HUB_COLUMNS,
    'server_policy':SERVER_POLICY_COLUMNS,
    'server_endpoint_fallbacks':('endpoint','added_at','updated_at'),
    'connections':CONNECTION_COLUMNS,
    'subscriptions':('connection_name','starts_at','expires_at','quota_bytes','max_upload_mbps','max_download_mbps','manual_suspended','period_started_at','updated_at'),
    'usage':('connection_name','period_upload_bytes','period_download_bytes','quota_used_bytes','lifetime_upload_bytes','lifetime_download_bytes','last_sync_at'),
    'audit':('id','occurred_at','connection_name','action','detail'),
    'ingress_state':INGRESS_STATE_COLUMNS,
    'control_nonces':('connection_name','nonce','seen_at'),
    'enrollment_tokens':('id','connection_name','token_hash','token_version','issued_at','expires_at','consumed_at','revoked_at'),
    'config_pending':('connection_name','transaction_id','state','previous_json','candidate_json','created_at','updated_at','error','kind','prepared_at','egress_apply_at','apply_at','rollback_at'),
    'software_releases':('version','sha256','payload_path','signature_path','manifest_json','status','created_at'),
    'software_release_usage':('version','connection_name','first_seen_at','last_seen_at'),
}


def _application_tables(c):
    return {str(r[0]) for r in c.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
    )}


def _ensure_schema_indexes(c):
    c.execute('CREATE UNIQUE INDEX IF NOT EXISTS idx_connections_uuid ON connections(connection_uuid)')
    c.execute('CREATE INDEX IF NOT EXISTS idx_control_nonces_seen ON control_nonces(seen_at)')
    c.execute('CREATE INDEX IF NOT EXISTS idx_audit_connection_action_time ON audit(connection_name,action,occurred_at DESC)')
    c.execute('CREATE INDEX IF NOT EXISTS idx_audit_time ON audit(occurred_at DESC)')


def _verify_schema(c):
    actual=_application_tables(c)
    expected=set(SCHEMA_TABLE_COLUMNS)
    if actual != expected:
        raise RuntimeError(f'DFR registry table set mismatch: missing={sorted(expected-actual)} extra={sorted(actual-expected)}')
    for table,columns in SCHEMA_TABLE_COLUMNS.items():
        got=tuple(_columns(c,table))
        if got != tuple(columns):
            raise RuntimeError(f'DFR registry column mismatch for {table}: expected={columns} actual={got}')
    meta=[(str(r[0]),str(r[1])) for r in c.execute('SELECT key,value FROM meta ORDER BY key')]
    expected_meta=[('product','dragon-fruit-relay'),('product_lineage','standalone-dfr'),('registry_schema',str(SCHEMA))]
    if meta != expected_meta:
        raise RuntimeError(f'DFR registry metadata mismatch: {meta}')
    fk=c.execute('PRAGMA foreign_key_check').fetchall()
    if fk:
        raise RuntimeError(f'DFR registry foreign-key check failed: {fk[:5]}')


def _create_schema(c):
    c.execute('CREATE TABLE meta(key TEXT PRIMARY KEY,value TEXT NOT NULL)')
    c.execute('''CREATE TABLE hub(
      id INTEGER PRIMARY KEY CHECK(id=1), endpoint TEXT NOT NULL,
      created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
      endpoint_changed_at INTEGER, endpoint_completed_at INTEGER
    )''')
    c.execute('''CREATE TABLE server_policy(
      id INTEGER PRIMARY KEY CHECK(id=1), max_upload_mbps INTEGER,
      max_download_mbps INTEGER, updated_at INTEGER NOT NULL
    )''')
    c.execute('''CREATE TABLE server_endpoint_fallbacks(
      endpoint TEXT PRIMARY KEY, added_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
    )''')
    c.execute('''CREATE TABLE connections(
      name TEXT PRIMARY KEY, profile_index INTEGER NOT NULL UNIQUE, created_at INTEGER NOT NULL,
      udp_port INTEGER NOT NULL UNIQUE, tunnel_cidr TEXT NOT NULL UNIQUE,
      xfrm_if TEXT NOT NULL UNIQUE, xfrm_id INTEGER NOT NULL UNIQUE, xfrm_mtu INTEGER NOT NULL,
      ingress_xfrm_cidr TEXT NOT NULL, egress_xfrm_cidr TEXT NOT NULL,
      ingress_xfrm_ip TEXT NOT NULL, egress_xfrm_ip TEXT NOT NULL,
      ingress_id TEXT NOT NULL, egress_id TEXT NOT NULL, psk TEXT NOT NULL,
      dns_primary TEXT NOT NULL, dns_secondary TEXT NOT NULL, updated_at INTEGER NOT NULL,
      connection_uuid TEXT, control_key TEXT, desired_ingress_version TEXT,
      desired_ingress_source TEXT CHECK(desired_ingress_source IN ('auto','manual') OR desired_ingress_source IS NULL),
      update_policy TEXT NOT NULL DEFAULT 'auto' CHECK(update_policy IN ('manual','auto','pinned')),
      pending_action TEXT
    )''')
    c.execute('''CREATE TABLE subscriptions(
      connection_name TEXT PRIMARY KEY REFERENCES connections(name) ON DELETE CASCADE,
      starts_at INTEGER, expires_at INTEGER, quota_bytes INTEGER,
      max_upload_mbps INTEGER, max_download_mbps INTEGER,
      manual_suspended INTEGER NOT NULL DEFAULT 0 CHECK(manual_suspended IN (0,1)),
      period_started_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
    )''')
    c.execute('''CREATE TABLE usage(
      connection_name TEXT PRIMARY KEY REFERENCES connections(name) ON DELETE CASCADE,
      period_upload_bytes INTEGER NOT NULL DEFAULT 0,
      period_download_bytes INTEGER NOT NULL DEFAULT 0,
      quota_used_bytes INTEGER NOT NULL DEFAULT 0,
      lifetime_upload_bytes INTEGER NOT NULL DEFAULT 0,
      lifetime_download_bytes INTEGER NOT NULL DEFAULT 0,
      last_sync_at INTEGER NOT NULL DEFAULT 0
    )''')
    c.execute('''CREATE TABLE audit(
      id INTEGER PRIMARY KEY AUTOINCREMENT, occurred_at INTEGER NOT NULL,
      connection_name TEXT, action TEXT NOT NULL, detail TEXT NOT NULL
    )''')
    c.execute('''CREATE TABLE ingress_state(
      connection_name TEXT PRIMARY KEY REFERENCES connections(name) ON DELETE CASCADE,
      ingress_version TEXT, ingress_sha256 TEXT, health TEXT, update_status TEXT, last_error TEXT,
      last_seen_at INTEGER NOT NULL DEFAULT 0, last_nonce TEXT,
      pending_control_key TEXT, enrollment_token_hash TEXT,
      bootstrap_psk_state TEXT NOT NULL DEFAULT 'unenrolled',
      update_target TEXT, update_error TEXT, update_started_at INTEGER, update_finished_at INTEGER,
      action_name TEXT, action_status TEXT, action_message TEXT,
      action_started_at INTEGER, action_finished_at INTEGER,
      client_endpoint TEXT, endpoint_error TEXT, endpoint_updated_at INTEGER,
      client_capabilities_json TEXT, update_sha256 TEXT
    )''')
    c.execute('''CREATE TABLE control_nonces(
      connection_name TEXT NOT NULL REFERENCES connections(name) ON DELETE CASCADE,
      nonce TEXT NOT NULL, seen_at INTEGER NOT NULL,
      PRIMARY KEY(connection_name,nonce)
    )''')
    c.execute('''CREATE TABLE enrollment_tokens(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      connection_name TEXT NOT NULL REFERENCES connections(name) ON DELETE CASCADE,
      token_hash TEXT NOT NULL UNIQUE, token_version INTEGER NOT NULL,
      issued_at INTEGER NOT NULL, expires_at INTEGER NOT NULL,
      consumed_at INTEGER, revoked_at INTEGER
    )''')
    c.execute('''CREATE TABLE config_pending(
      connection_name TEXT PRIMARY KEY REFERENCES connections(name) ON DELETE CASCADE,
      transaction_id TEXT NOT NULL UNIQUE,
      state TEXT NOT NULL CHECK(state IN ('PENDING','PREPARED','APPLYING','COMMITTED','FAILED')),
      previous_json TEXT NOT NULL, candidate_json TEXT NOT NULL,
      created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, error TEXT,
      kind TEXT NOT NULL DEFAULT 'manual',
      prepared_at INTEGER, egress_apply_at INTEGER, apply_at INTEGER, rollback_at INTEGER
    )''')
    c.execute('''CREATE TABLE software_releases(
      version TEXT PRIMARY KEY, sha256 TEXT NOT NULL, payload_path TEXT NOT NULL,
      signature_path TEXT NOT NULL, manifest_json TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'staged' CHECK(status IN ('staged','canary','stable','revoked')),
      created_at INTEGER NOT NULL
    )''')
    c.execute('''CREATE TABLE software_release_usage(
      version TEXT NOT NULL REFERENCES software_releases(version) ON DELETE CASCADE,
      connection_name TEXT NOT NULL REFERENCES connections(name) ON DELETE CASCADE,
      first_seen_at INTEGER NOT NULL, last_seen_at INTEGER NOT NULL,
      PRIMARY KEY(version,connection_name)
    )''')
    c.execute("INSERT INTO meta(key,value) VALUES('product','dragon-fruit-relay')")
    c.execute("INSERT INTO meta(key,value) VALUES('product_lineage','standalone-dfr')")
    c.execute("INSERT INTO meta(key,value) VALUES('registry_schema',?)",(str(SCHEMA),))
    c.execute('INSERT INTO server_policy(id,updated_at) VALUES(1,?)',(now(),))
    _ensure_schema_indexes(c)


def init_schema(c):
    tables=_application_tables(c)
    if not tables:
        _create_schema(c)
        c.commit()
        _verify_schema(c)
        return
    # DFR v2.1.0 starts a new product/schema lineage. A non-current database is
    # not silently interpreted or converted by the runtime.
    _verify_schema(c)
    _ensure_schema_indexes(c)
    c.commit()
def audit(c, action, detail, name=None):
    c.execute("INSERT INTO audit(occurred_at,connection_name,action,detail) VALUES(?,?,?,?)", (now(), name, action, detail))

def parse_date(v, end=False):
    if v is None: return None
    v = str(v).strip().lower()
    if v in ("", "none", "unlimited", "never", "off"): return None
    if re.fullmatch(r"\d+", v): return int(v)
    try:
        d = dt.datetime.strptime(v, "%Y-%m-%d").replace(tzinfo=dt.timezone.utc)
        if end: d += dt.timedelta(days=1); d -= dt.timedelta(seconds=1)
        return int(d.timestamp())
    except ValueError: raise SystemExit(f"invalid date: {v}; use YYYY-MM-DD")

def parse_size(v):
    if v is None: return None
    s=str(v).strip().lower().replace(" ","")
    if s in ("", "none", "unlimited", "off", "0"): return None
    m=re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)(b|kb|mb|gb|tb|pb)?", s)
    if not m: raise SystemExit(f"invalid quota: {v}; examples: 500GB, 2TB, unlimited")
    n=float(m.group(1)); unit=m.group(2) or "b"
    mul={"b":1,"kb":1000,"mb":1000**2,"gb":1000**3,"tb":1000**4,"pb":1000**5}[unit]
    return int(n*mul)

def parse_mbps(v):
    if v is None: return None
    s=str(v).strip().lower().replace("mbps","").strip()
    if s in ("", "none", "unlimited", "off", "0"): return None
    if not re.fullmatch(r"[0-9]+", s) or int(s) < 1 or int(s) > 1000000: raise SystemExit(f"invalid Mbps value: {v}")
    return int(s)

def fmt_bytes(n):
    if n is None: return "Unlimited"
    n=int(n)
    for unit,m in (("PB",1000**5),("TB",1000**4),("GB",1000**3),("MB",1000**2),("KB",1000)):
        if n >= m: return f"{n/m:.2f} {unit}"
    return f"{n} B"

def fmt_bytes_precise(n):
    """Higher-resolution human display for remaining quota.

    Quota arithmetic always uses integer bytes. This formatter only avoids
    hiding small consumption when a large allowance would otherwise round
    remaining capacity back to the same 2-decimal TB/PB value.
    """
    if n is None: return "Unlimited"
    n=int(n)
    for unit,m,places in (("PB",1000**5,4),("TB",1000**4,4),("GB",1000**3,2),("MB",1000**2,2),("KB",1000,2)):
        if n >= m: return f"{n/m:.{places}f} {unit}"
    return f"{n} B"

def fmt_percent(part,total):
    if total is None: return "Unlimited"
    total=int(total)
    if total <= 0: return "0.00%"
    pct=max(0.0,min(100.0,(int(part)/total)*100.0))
    if 0.0 < pct < 0.01: return "<0.01%"
    if 99.99 < pct < 100.0: return ">99.99%"
    return f"{pct:.2f}%"

def state(row, u, t=None):
    t=now() if t is None else int(t)
    if row["manual_suspended"]: return "SUSPENDED"
    if row["starts_at"] is not None and t < row["starts_at"]: return "SCHEDULED"
    if row["expires_at"] is not None and t >= row["expires_at"]: return "EXPIRED"
    directional=int(u["period_upload_bytes"])+int(u["period_download_bytes"])
    used=max(directional,int(u["quota_used_bytes"] or 0))
    if row["quota_bytes"] is not None and used >= int(row["quota_bytes"]): return "QUOTA EXHAUSTED"
    return "ACTIVE"

def get(c,name):
    r=c.execute("SELECT c.*,s.starts_at,s.expires_at,s.quota_bytes,s.max_upload_mbps,s.max_download_mbps,s.manual_suspended,s.period_started_at,u.period_upload_bytes,u.period_download_bytes,u.quota_used_bytes,u.lifetime_upload_bytes,u.lifetime_download_bytes,u.last_sync_at FROM connections c JOIN subscriptions s ON s.connection_name=c.name JOIN usage u ON u.connection_name=c.name WHERE c.name=?",(name,)).fetchone()
    if not r: raise SystemExit(f"unknown connection: {name}")
    return r

def ensure_connection_defaults(c,name,created):
    c.execute("INSERT OR IGNORE INTO subscriptions(connection_name,period_started_at,updated_at) VALUES(?,?,?)",(name,created,now()))
    c.execute("INSERT OR IGNORE INTO usage(connection_name,last_sync_at) VALUES(?,?)",(name,now()))

def cmd_init(a):
    with conn() as c:
        init_schema(c)

        if not a.endpoint:
            c.commit()
            return

        a.endpoint=validate_server_endpoint(a.endpoint)

        old=c.execute(
            "SELECT endpoint FROM hub WHERE id=1"
        ).fetchone()

        if (
            old
            and old[0] != a.endpoint
            and not a.force
        ):
            raise SystemExit(
                f"registry already belongs to {old[0]}"
            )

        # No actual change = no UPDATE and no audit event.
        if old and old[0] == a.endpoint:
            c.commit()
            return

        t=now()

        if old is None:

            c.execute(
                """
                INSERT INTO hub(
                    id,
                    endpoint,
                    created_at,
                    updated_at
                )
                VALUES(1,?,?,?)
                """,
                (
                    a.endpoint,
                    t,
                    t,
                ),
            )

            audit(
                c,
                "server-endpoint",
                f"set {a.endpoint}",
            )

        else:

            previous=old[0]

            c.execute(
                """
                UPDATE hub
                SET endpoint=?,
                    updated_at=?
                WHERE id=1
                """,
                (
                    a.endpoint,
                    t,
                ),
            )

            audit(
                c,
                "server-endpoint",
                f"{previous} -> {a.endpoint}",
            )

        c.commit()

def cmd_server_endpoint(a):
    with conn() as c:
        init_schema(c); r=c.execute("SELECT endpoint FROM hub WHERE id=1").fetchone()
        if not r: raise SystemExit("server endpoint is not initialized")
        print(r[0])


def validate_server_endpoint(value):
    value=str(value or '').strip().lower().rstrip('.')
    if not value:
        raise SystemExit('server endpoint is required')
    try:
        addr=ipaddress.ip_address(value)
        if addr.version != 4:
            raise SystemExit('server endpoint IP must be IPv4')
        return str(addr)
    except ValueError:
        pass
    if len(value) > 253 or '.' not in value:
        raise SystemExit('server endpoint must be an IPv4 address or normal FQDN')
    if not re.fullmatch(r'[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?',value):
        raise SystemExit('server endpoint contains invalid characters')
    for label in value.split('.'):
        if not label or len(label)>63 or label.startswith('-') or label.endswith('-'):
            raise SystemExit('server endpoint contains an invalid DNS label')
    return value



def endpoint_fallbacks(c):
    return [
        str(r['endpoint'] or '').strip().lower().rstrip('.')
        for r in c.execute(
            "SELECT endpoint FROM server_endpoint_fallbacks ORDER BY added_at,endpoint"
        )
        if str(r['endpoint'] or '').strip()
    ]


def latest_endpoint_fallback(c):
    row=c.execute(
        "SELECT endpoint FROM server_endpoint_fallbacks ORDER BY updated_at DESC,added_at DESC,endpoint DESC LIMIT 1"
    ).fetchone()
    return None if not row else str(row['endpoint'] or '').strip().lower().rstrip('.') or None


def cmd_server_endpoint_set(a):
    domain=validate_server_endpoint(a.endpoint)
    with conn() as c:
        init_schema(c)
        row=c.execute(
            "SELECT endpoint FROM hub WHERE id=1"
        ).fetchone()
        if not row:
            raise SystemExit('server endpoint is not initialized')
        previous=str(row['endpoint'] or '').strip().lower().rstrip('.')
        if previous == domain:
            print(domain)
            return

        t=now()

        # Latest-target-wins semantics:
        # - the old active endpoint becomes a retained fallback;
        # - selecting a retained fallback as the new active endpoint removes it
        #   from the fallback set;
        # - Client software/runtime queues are not cancelled or restarted;
        # - CONTROL/1 advertises only the newest active target on every poll.
        c.execute(
            """
            INSERT INTO server_endpoint_fallbacks(endpoint,added_at,updated_at)
            VALUES(?,?,?)
            ON CONFLICT(endpoint) DO UPDATE SET updated_at=excluded.updated_at
            """,
            (previous,t,t),
        )
        c.execute(
            "DELETE FROM server_endpoint_fallbacks WHERE LOWER(RTRIM(endpoint,'.'))=?",
            (domain,),
        )
        c.execute(
            """
            UPDATE hub
            SET endpoint=?,endpoint_changed_at=?,endpoint_completed_at=NULL,updated_at=?
            WHERE id=1
            """,
            (domain,t,t),
        )

        # Unused enrollment tokens contain the endpoint present when issued.
        # Revoke only unused tokens; enrolled identities, PSKs, tunnels,
        # subscriptions and in-flight software updates remain untouched.
        c.execute(
            'UPDATE enrollment_tokens SET revoked_at=? '
            'WHERE consumed_at IS NULL AND revoked_at IS NULL',
            (t,),
        )
        c.execute('UPDATE ingress_state SET endpoint_error=NULL')
        queued=queue_endpoint_clients(c)
        fallbacks=endpoint_fallbacks(c)
        audit(
            c,
            'server-endpoint',
            f"{previous} -> {domain}; latest target superseded prior target; "
            f"fallbacks={','.join(fallbacks) or '-'}; "
            f"software_updates={queued['queued_updates']}; runtime_refreshes={queued['queued_refreshes']}",
        )
        maybe_complete_endpoint_transition(c,t)
        c.commit()
        print(domain)


def cmd_upsert(a):
    with conn() as c:
        init_schema(c)

        t=now()
        created=a.created_at or t

        existing=c.execute(
            """
            SELECT *
            FROM connections
            WHERE name=?
            """,
            (a.name,),
        ).fetchone()

        new_values={
            "profile_index": a.profile_index,
            "udp_port": a.udp_port,
            "tunnel_cidr": a.tunnel_cidr,
            "xfrm_if": a.xfrm_if,
            "xfrm_id": a.xfrm_id,
            "xfrm_mtu": a.xfrm_mtu,
            "ingress_xfrm_cidr": a.ingress_xfrm_cidr,
            "egress_xfrm_cidr": a.egress_xfrm_cidr,
            "ingress_xfrm_ip": a.ingress_xfrm_ip,
            "egress_xfrm_ip": a.egress_xfrm_ip,
            "ingress_id": a.ingress_id,
            "egress_id": a.egress_id,
            "psk": a.psk,
            "dns_primary": a.dns_primary,
            "dns_secondary": a.dns_secondary,
        }

        labels={
            "profile_index": "profile index",
            "udp_port": "UDP port",
            "tunnel_cidr": "tunnel",
            "xfrm_if": "XFRM interface",
            "xfrm_id": "XFRM ID",
            "xfrm_mtu": "XFRM MTU",
            "ingress_xfrm_cidr": "ingress tunnel address",
            "egress_xfrm_cidr": "egress tunnel address",
            "ingress_xfrm_ip": "ingress tunnel IP",
            "egress_xfrm_ip": "egress tunnel IP",
            "ingress_id": "ingress identity",
            "egress_id": "egress identity",
            "psk": "PSK",
            "dns_primary": "primary DNS",
            "dns_secondary": "secondary DNS",
        }

        changed=[]

        if existing is not None:

            for key,value in new_values.items():

                if existing[key] != value:
                    changed.append(labels[key])

            # Re-applying an identical current connection is not history.
            if not changed:
                ensure_connection_defaults(
                    c,
                    a.name,
                    existing["created_at"],
                )

                c.commit()
                return

        c.execute(
            """
            INSERT INTO connections(
                name,
                profile_index,
                created_at,
                udp_port,
                tunnel_cidr,
                xfrm_if,
                xfrm_id,
                xfrm_mtu,
                ingress_xfrm_cidr,
                egress_xfrm_cidr,
                ingress_xfrm_ip,
                egress_xfrm_ip,
                ingress_id,
                egress_id,
                psk,
                dns_primary,
                dns_secondary,
                updated_at
            )
            VALUES(
                ?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?
            )

            ON CONFLICT(name)
            DO UPDATE SET
                profile_index=excluded.profile_index,
                udp_port=excluded.udp_port,
                tunnel_cidr=excluded.tunnel_cidr,
                xfrm_if=excluded.xfrm_if,
                xfrm_id=excluded.xfrm_id,
                xfrm_mtu=excluded.xfrm_mtu,
                ingress_xfrm_cidr=excluded.ingress_xfrm_cidr,
                egress_xfrm_cidr=excluded.egress_xfrm_cidr,
                ingress_xfrm_ip=excluded.ingress_xfrm_ip,
                egress_xfrm_ip=excluded.egress_xfrm_ip,
                ingress_id=excluded.ingress_id,
                egress_id=excluded.egress_id,
                psk=excluded.psk,
                dns_primary=excluded.dns_primary,
                dns_secondary=excluded.dns_secondary,
                updated_at=excluded.updated_at
            """,
            (
                a.name,
                a.profile_index,
                created,
                a.udp_port,
                a.tunnel_cidr,
                a.xfrm_if,
                a.xfrm_id,
                a.xfrm_mtu,
                a.ingress_xfrm_cidr,
                a.egress_xfrm_cidr,
                a.ingress_xfrm_ip,
                a.egress_xfrm_ip,
                a.ingress_id,
                a.egress_id,
                a.psk,
                a.dns_primary,
                a.dns_secondary,
                t,
            ),
        )

        ensure_connection_defaults(
            c,
            a.name,
            created,
        )

        management=c.execute(
            "SELECT connection_uuid,control_key FROM connections WHERE name=?",
            (a.name,),
        ).fetchone()
        if not management["connection_uuid"] or not management["control_key"]:
            c.execute(
                "UPDATE connections SET connection_uuid=COALESCE(connection_uuid,?), control_key=COALESCE(control_key,?) WHERE name=?",
                (str(uuid.uuid4()),secrets.token_hex(32),a.name),
            )
        c.execute("INSERT OR IGNORE INTO ingress_state(connection_name) VALUES(?)",(a.name,))

        # Standalone DFR defaults every newly created connection to AUTO and
        # immediately binds it to the current STABLE Client release. Do this
        # inside the creation transaction so enrollment never starts life as
        # MANUAL merely because the daemon has not reached its next cycle.
        maintain_auto_updates(c)

        if existing is None:

            audit(
                c,
                "connection-created",
                (
                    f"UDP {a.udp_port}; "
                    f"tunnel {a.tunnel_cidr}; "
                    f"XFRM {a.xfrm_if}/{a.xfrm_id}"
                ),
                a.name,
            )

        else:

            # Never put PSK values in audit history.
            audit(
                c,
                "connection-updated",
                "changed: " + ", ".join(changed),
                a.name,
            )

        c.commit()

def cmd_remove(a):
    with conn() as c:
        init_schema(c)
        # DFR_DB_RESOURCE_CONSISTENCY: deletion is final.
        # No tombstone and no connection-scoped SQL history are retained.
        c.execute("DELETE FROM config_pending WHERE connection_name=?", (a.name,))
        c.execute("DELETE FROM enrollment_tokens WHERE connection_name=?", (a.name,))
        c.execute("DELETE FROM ingress_state WHERE connection_name=?", (a.name,))
        c.execute("DELETE FROM audit WHERE connection_name=?", (a.name,))
        c.execute("DELETE FROM subscriptions WHERE connection_name=?", (a.name,))
        c.execute("DELETE FROM usage WHERE connection_name=?", (a.name,))
        c.execute("DELETE FROM connections WHERE name=?", (a.name,))
        c.commit()

def cmd_list(a):
    with conn() as c:
        init_schema(c)
        for r in c.execute("SELECT name FROM connections ORDER BY profile_index"): print(r[0])

def format_record(r):
    directional=int(r["period_upload_bytes"])+int(r["period_download_bytes"])
    used=max(directional,int(r["quota_used_bytes"] or 0)); quota=r["quota_bytes"]
    remain=None if quota is None else max(0,int(quota)-used)
    d=dict(r); d.update({"state":state(r,r),"used_bytes":used,"remaining_bytes":remain})
    return d

def cmd_show(a):
    with conn() as c:
        init_schema(c); r=get(c,a.name); d=format_record(r)
        if a.json: print(json.dumps(d,sort_keys=True)); return
        print(f"STATE\t{d['state']}")
        print(f"STARTS\t{utc_iso(r['starts_at']) if r['starts_at'] else 'Immediate'}")
        print(f"EXPIRES\t{utc_iso(r['expires_at']) if r['expires_at'] else 'Never'}")
        print(f"QUOTA\t{fmt_bytes(r['quota_bytes'])}")
        print(f"UPLOAD\t{fmt_bytes(r['period_upload_bytes'])}")
        print(f"DOWNLOAD\t{fmt_bytes(r['period_download_bytes'])}")
        print(f"USED\t{fmt_bytes(d['used_bytes'])}")
        print(f"REMAINING\t{fmt_bytes_precise(d['remaining_bytes'])}")
        if r['quota_bytes'] is None:
            print("USED_PERCENT\tUnlimited")
            print("REMAINING_PERCENT\tUnlimited")
        else:
            print(f"USED_PERCENT\t{fmt_percent(d['used_bytes'],r['quota_bytes'])}")
            print(f"REMAINING_PERCENT\t{fmt_percent(d['remaining_bytes'],r['quota_bytes'])}")
        print(f"UPLOAD_Mbps\t{r['max_upload_mbps'] if r['max_upload_mbps'] else 'Unlimited'}")
        print(f"DOWNLOAD_Mbps\t{r['max_download_mbps'] if r['max_download_mbps'] else 'Unlimited'}")
        print(f"LIFETIME\t{fmt_bytes(int(r['lifetime_upload_bytes'])+int(r['lifetime_download_bytes']))}")

def cmd_set(a):
    changed=False

    with conn() as c:
        init_schema(c)
        r=get(c,a.name)

        fields=[]
        vals=[]
        changes=[]

        start_changed=False
        quota_changed=False
        quota_value=None

        options=(
            (
                a.start,
                "starts_at",
                parse_date,
                False,
            ),
            (
                a.expires,
                "expires_at",
                parse_date,
                True,
            ),
            (
                a.quota,
                "quota_bytes",
                parse_size,
                False,
            ),
            (
                a.upload_mbps,
                "max_upload_mbps",
                parse_mbps,
                False,
            ),
            (
                a.download_mbps,
                "max_download_mbps",
                parse_mbps,
                False,
            ),
        )

        for opt,col,parser,end in options:

            if opt is None:
                continue

            if parser == parse_date:
                nv=parser(opt,end)
            else:
                nv=parser(opt)

            # Same value = no database write and no history event.
            if r[col] == nv:
                continue

            fields.append(f"{col}=?")
            vals.append(nv)

            changes.append(
                f"{col}:{r[col]}->{nv}"
            )

            changed=True

            if col == "starts_at":
                start_changed=True

            if col == "quota_bytes":
                quota_changed=True
                quota_value=nv

        if not changed:
            return

        if start_changed:

            start_value=parse_date(
                a.start,
                False,
            )

            fields.append(
                "period_started_at=?"
            )

            vals.append(
                start_value
                if start_value is not None
                else now()
            )

        fields.append("updated_at=?")
        vals.append(now())

        vals.append(a.name)

        c.execute(
            f"UPDATE subscriptions "
            f"SET {','.join(fields)} "
            "WHERE connection_name=?",
            vals,
        )

        if (
            quota_changed
            and quota_value is not None
        ):
            c.execute(
                """
                UPDATE usage
                SET quota_used_bytes=MAX(
                    quota_used_bytes,
                    period_upload_bytes+
                    period_download_bytes
                )
                WHERE connection_name=?
                """,
                (a.name,),
            )

        audit(
            c,
            "subscription-change",
            "; ".join(changes),
            a.name,
        )

        c.commit()

    apply_runtime(best_effort=True)

def cmd_suspend(a):
    with conn() as c:
        init_schema(c)

        r=get(c,a.name)

        desired=1 if a.suspend else 0

        if int(r["manual_suspended"] or 0) == desired:
            return

        c.execute(
            """
            UPDATE subscriptions
            SET
                manual_suspended=?,
                updated_at=?
            WHERE connection_name=?
            """,
            (
                desired,
                now(),
                a.name,
            ),
        )

        audit(
            c,
            "suspend"
            if a.suspend
            else "resume",
            "manual subscription control",
            a.name,
        )

        c.commit()

    apply_runtime(best_effort=True)

def _reset_kernel_current_usage(c, name):
    # Reset nftables counters/quota for exactly one connection BEFORE the
    # database counters are zeroed.  The registry daemon then sees kernel
    # counters lower than the database baseline and does not mistake
    # pre-reset usage for fresh traffic during the short transition.
    if shutil.which(NFT) is None:
        raise SystemExit("nft is required")
    run_nft_script(
        build_sub_rules(c, reset_connection=name),
        best_effort=False,
    )


def cmd_reset_current(a):
    # Capture all traffic observed up to the reset into lifetime accounting.
    sync_kernel()

    with conn() as c:
        init_schema(c)
        r=get(c,a.name)

        previous=max(
            int(r["period_upload_bytes"])+int(r["period_download_bytes"]),
            int(r["quota_used_bytes"] or 0),
        )

        _reset_kernel_current_usage(c,a.name)

        t=now()
        c.execute(
            """
            UPDATE usage
            SET period_upload_bytes=0,
                period_download_bytes=0,
                quota_used_bytes=0,
                last_sync_at=?
            WHERE connection_name=?
            """,
            (t,a.name),
        )
        audit(
            c,
            "traffic-reset",
            f"current traffic reset from {fmt_bytes(previous)}; lifetime preserved",
            a.name,
        )
        c.commit()

    apply_runtime(best_effort=True)


def cmd_reset_lifetime(a):
    # First capture unsynced live traffic, then zero only the lifetime totals.
    # Current-period usage/quota enforcement remains untouched.
    sync_kernel()

    with conn() as c:
        init_schema(c)
        r=get(c,a.name)
        previous=int(r["lifetime_upload_bytes"])+int(r["lifetime_download_bytes"])
        t=now()
        c.execute(
            """
            UPDATE usage
            SET lifetime_upload_bytes=0,
                lifetime_download_bytes=0,
                last_sync_at=?
            WHERE connection_name=?
            """,
            (t,a.name),
        )
        audit(
            c,
            "lifetime-reset",
            f"lifetime traffic reset from {fmt_bytes(previous)}; current usage preserved",
            a.name,
        )
        c.commit()


def cmd_renew(a):
    # A renewal is intentionally simple: preserve lifetime accounting, reset
    # current-period accounting, and update the active period in place.  There
    # is no closed-period archive and no historical period row.
    sync_kernel()

    with conn() as c:
        init_schema(c)
        r=get(c,a.name)
        t=now()

        start=parse_date(a.start,False) if a.start is not None else t

        if a.expires is not None:
            expires=parse_date(a.expires,True)
        elif (
            r["expires_at"] is not None
            and r["period_started_at"] is not None
            and int(r["expires_at"]) > int(r["period_started_at"])
        ):
            expires=start + (int(r["expires_at"]) - int(r["period_started_at"]))
        else:
            expires=r["expires_at"]

        quota=parse_size(a.quota) if a.quota is not None else r["quota_bytes"]
        previous=max(
            int(r["period_upload_bytes"])+int(r["period_download_bytes"]),
            int(r["quota_used_bytes"] or 0),
        )

        _reset_kernel_current_usage(c,a.name)

        c.execute(
            """
            UPDATE subscriptions
            SET starts_at=?,
                expires_at=?,
                quota_bytes=?,
                period_started_at=?,
                manual_suspended=0,
                updated_at=?
            WHERE connection_name=?
            """,
            (start,expires,quota,start,t,a.name),
        )
        c.execute(
            """
            UPDATE usage
            SET period_upload_bytes=0,
                period_download_bytes=0,
                quota_used_bytes=0,
                last_sync_at=?
            WHERE connection_name=?
            """,
            (t,a.name),
        )
        audit(
            c,
            "renew",
            (
                f"new period starts={start} expires={expires} quota={quota}; "
                f"current traffic reset from {fmt_bytes(previous)}; lifetime preserved"
            ),
            a.name,
        )
        c.commit()

    apply_runtime(best_effort=True)

def cmd_audit(a):
    with conn() as c:
        init_schema(c)
        q="SELECT occurred_at,connection_name,action,detail FROM audit"
        params=[]
        if a.scope == 'subscription':
            if not a.name: raise SystemExit('subscription audit requires a connection name')
            q += " WHERE connection_name=? AND action IN ('subscription-change','renew','traffic-reset','lifetime-reset','suspend','resume')"
            params.append(a.name)
        elif a.scope == 'connection':
            if not a.name: raise SystemExit('connection audit requires a connection name')
            q += " WHERE connection_name=? AND action LIKE 'connection-%'"
            params.append(a.name)
        elif a.scope == 'hub':
            q += " WHERE connection_name IS NULL"
        elif a.name:
            q += " WHERE connection_name=?"
            params.append(a.name)
        q += ' ORDER BY id DESC LIMIT ? OFFSET ?'
        params.extend((max(1,a.limit),max(0,a.offset)))
        for r in c.execute(q,params):
            print(f"{utc_iso(r[0])}\t{r[1] or '-'}\t{r[2]}\t{r[3]}")


def cmd_export(a):
    with conn() as c:
        init_schema(c); r=get(c,a.name)
        vals={
          "PROFILE_NAME":r["name"],"PROFILE_INDEX":r["profile_index"],"PROFILE_CREATED_EPOCH":r["created_at"],"PORT_MODE":"custom","IKE_PORT":r["udp_port"],"NATT_PORT":r["udp_port"],"TUNNEL_CIDR":r["tunnel_cidr"],"XFRM_IF":r["xfrm_if"],"XFRM_ID":r["xfrm_id"],"XFRM_MTU":r["xfrm_mtu"],"INGRESS_XFRM_CIDR":r["ingress_xfrm_cidr"],"EGRESS_XFRM_CIDR":r["egress_xfrm_cidr"],"INGRESS_XFRM_IP":r["ingress_xfrm_ip"],"EGRESS_XFRM_IP":r["egress_xfrm_ip"],"INGRESS_ID":r["ingress_id"],"EGRESS_ID":r["egress_id"],"PSK":r["psk"],"DNS_PRIMARY":r["dns_primary"],"DNS_SECONDARY":r["dns_secondary"],"CONNECTION_UUID":r["connection_uuid"],"CONTROL_KEY":r["control_key"],"DESIRED_INGRESS_VERSION":r["desired_ingress_version"] or "","UPDATE_POLICY":r["update_policy"]}
        import shlex
        for k,v in vals.items(): print(f"{k}={shlex.quote(str(v))}")






















def cmd_server_speed(a):
    with conn() as c:
        init_schema(c)
        r=c.execute('SELECT * FROM server_policy WHERE id=1').fetchone()
        if a.show:
            print('UPLOAD_Mbps\t'+(str(r['max_upload_mbps']) if r['max_upload_mbps'] else 'Unlimited'))
            print('DOWNLOAD_Mbps\t'+(str(r['max_download_mbps']) if r['max_download_mbps'] else 'Unlimited'))
            return
        old_up=r['max_upload_mbps']; old_down=r['max_download_mbps']
        up=old_up; down=old_down
        if a.disable: up=down=None
        if a.upload_mbps is not None: up=parse_mbps(a.upload_mbps)
        if a.download_mbps is not None: down=parse_mbps(a.download_mbps)
        if up != old_up or down != old_down:
            c.execute('UPDATE server_policy SET max_upload_mbps=?,max_download_mbps=?,updated_at=? WHERE id=1',(up,down,now()))
            def txt(v): return 'Unlimited' if v is None else f'{v} Mbps'
            audit(c,'server-speed',f"upload {txt(old_up)} -> {txt(up)}; download {txt(old_down)} -> {txt(down)}")
            c.commit()
    apply_global_speed(best_effort=True)

MANAGEMENT_HEALTH_STALE_SECONDS=30
MANAGEMENT_HEALTH_OFFLINE_SECONDS=60

def effective_ingress_health(reported,last_seen,at=None):
    try:
        seen=int(last_seen or 0)
    except (TypeError,ValueError):
        seen=0
    if seen <= 0:
        return reported
    current=int(time.time() if at is None else at)
    age=max(0,current-seen)
    if age >= MANAGEMENT_HEALTH_OFFLINE_SECONDS:
        return "OFFLINE"
    if age >= MANAGEMENT_HEALTH_STALE_SECONDS:
        return "STALE"
    return reported or "UNKNOWN"

def refresh_ingress_health(c,at=None):
    current=int(time.time() if at is None else at)
    offline_before=current-MANAGEMENT_HEALTH_OFFLINE_SECONDS
    stale_before=current-MANAGEMENT_HEALTH_STALE_SECONDS

    # Record transitions only once. The authoritative heartbeat stays in
    # ingress_state.last_seen_at; audit stores human-meaningful history without
    # changing schema 1.
    offline_rows=list(c.execute("""
        SELECT connection_name,last_seen_at
        FROM ingress_state
        WHERE last_seen_at > 0
          AND last_seen_at <= ?
          AND COALESCE(health,'') != 'OFFLINE'
    """,(offline_before,)))
    for row in offline_rows:
        name=row['connection_name']
        seen=int(row['last_seen_at'])
        # If the daemon was stopped across both thresholds, preserve the
        # meaningful 30-second disconnect transition before OFFLINE.
        disconnected_at=seen+MANAGEMENT_HEALTH_STALE_SECONDS
        existing=c.execute(
            "SELECT 1 FROM audit WHERE connection_name=? AND action='connection-presence-disconnected' AND occurred_at>=? LIMIT 1",
            (name,disconnected_at),
        ).fetchone()
        if not existing:
            c.execute(
                "INSERT INTO audit(occurred_at,connection_name,action,detail) VALUES(?,?,?,?)",
                (disconnected_at,name,'connection-presence-disconnected','No authenticated CONTROL contact for 30 seconds'),
            )
        occurred=seen+MANAGEMENT_HEALTH_OFFLINE_SECONDS
        c.execute(
            "INSERT INTO audit(occurred_at,connection_name,action,detail) VALUES(?,?,?,?)",
            (occurred,name,'connection-presence-offline','No authenticated CONTROL contact for 60 seconds'),
        )

    stale_rows=list(c.execute("""
        SELECT connection_name,last_seen_at
        FROM ingress_state
        WHERE last_seen_at > ?
          AND last_seen_at <= ?
          AND COALESCE(health,'') NOT IN ('STALE','OFFLINE')
    """,(offline_before,stale_before)))
    for row in stale_rows:
        occurred=int(row['last_seen_at'])+MANAGEMENT_HEALTH_STALE_SECONDS
        c.execute(
            "INSERT INTO audit(occurred_at,connection_name,action,detail) VALUES(?,?,?,?)",
            (occurred,row['connection_name'],'connection-presence-disconnected','No authenticated CONTROL contact for 30 seconds'),
        )

    c.execute("""
        UPDATE ingress_state
        SET health='OFFLINE'
        WHERE last_seen_at > 0
          AND last_seen_at <= ?
          AND COALESCE(health,'') != 'OFFLINE'
    """,(offline_before,))
    c.execute("""
        UPDATE ingress_state
        SET health='STALE'
        WHERE last_seen_at > ?
          AND last_seen_at <= ?
          AND COALESCE(health,'') NOT IN ('STALE','OFFLINE')
    """,(offline_before,stale_before))

def parse_client_capabilities(value):
    if not value:
        return set()
    try:
        data=json.loads(value) if isinstance(value,str) else value
    except Exception:
        return set()
    if not isinstance(data,list):
        return set()
    return {str(item) for item in data if isinstance(item,str)}


def release_capabilities(row):
    if not row:
        return set()
    try:
        manifest=json.loads(row['manifest_json'])
    except Exception:
        return set()
    values=manifest.get('capabilities') or []
    return {str(item) for item in values if isinstance(item,str)} if isinstance(values,list) else set()


def latest_stable_release(c):
    return c.execute(
        "SELECT version,sha256,manifest_json,created_at FROM software_releases "
        "WHERE status='stable' ORDER BY created_at DESC,version DESC LIMIT 1"
    ).fetchone()


def _exact_release_match(data,release):
    if not release:
        return False
    version=str(data.get('ingress_version') or '').strip()
    digest=str(data.get('ingress_sha256') or '').strip().lower()
    return bool(
        version == str(release['version']) and
        re.fullmatch(r'[0-9a-f]{64}',digest) and
        hmac.compare_digest(digest,str(release['sha256'] or '').lower())
    )


def software_state_for(c,data,stable=None):
    stable=latest_stable_release(c) if stable is None else stable
    desired=str(data.get('desired_ingress_version') or '').strip()
    desired_source=str(data.get('desired_ingress_source') or '').strip().lower()
    policy=str(data.get('update_policy') or 'manual').strip().lower()
    desired_release=None
    if desired:
        desired_release=c.execute(
            "SELECT version,sha256,status,manifest_json,created_at FROM software_releases WHERE version=?",
            (desired,),
        ).fetchone()
        if desired_release and desired_release['status'] == 'revoked':
            desired_release=None

    raw=str(data.get('update_status') or '').strip().upper()
    target=str(data.get('update_target') or '').strip()
    target_sha=str(data.get('update_sha256') or '').strip().lower()
    exact_latest=_exact_release_match(data,stable)
    exact_desired=_exact_release_match(data,desired_release)
    active={'QUEUED','DOWNLOADING','VERIFYING','APPLYING'}
    failed={'FAILED','ROLLED_BACK','CANCELLED'}

    if desired_release and not exact_desired:
        desired_sha=str(desired_release['sha256'] or '').lower()
        exact_target=(target == desired and target_sha == desired_sha)
        if raw in active and exact_target:
            state='INSTALLING' if raw == 'APPLYING' else raw
        elif raw in failed and exact_target:
            state='ROLLED BACK' if raw == 'ROLLED_BACK' else raw
        else:
            state='QUEUED'
    elif exact_latest:
        state='LATEST'
    elif desired_release and exact_desired:
        same_stable=bool(
            stable and str(stable['version']) == desired and
            str(stable['sha256']) == str(desired_release['sha256'])
        )
        state='LATEST' if same_stable else 'CURRENT'
    elif stable and policy == 'auto':
        # Only AUTO follows STABLE as desired state. MANUAL and PINNED may
        # intentionally run any installed build, so a STABLE mismatch alone is
        # not an outstanding update request for those policies.
        state='UPDATE REQUIRED'
    elif data.get('ingress_version'):
        state='CURRENT'
    else:
        state='UNKNOWN'

    return {
        'software_state':state,
        'software_latest':exact_latest,
        'stable_ingress_version':None if not stable else stable['version'],
        'stable_ingress_sha256':None if not stable else stable['sha256'],
        'desired_ingress_source':desired_source or None,
    }


def _queue_release_for_connection(c,name,release,source,force=False):
    row=c.execute('''
        SELECT c.name,c.desired_ingress_version,c.desired_ingress_source,c.update_policy,
               s.ingress_version,s.ingress_sha256,s.update_status,s.update_target,s.update_sha256,s.update_error
        FROM connections c LEFT JOIN ingress_state s ON s.connection_name=c.name
        WHERE c.name=?
    ''',(name,)).fetchone()
    if not row or not release:
        return 'missing'
    data=dict(row)
    if _exact_release_match(data,release):
        if data.get('desired_ingress_version') == release['version']:
            c.execute(
                'UPDATE connections SET desired_ingress_version=NULL,desired_ingress_source=NULL,updated_at=? WHERE name=?',
                (now(),name),
            )
        return 'current'

    target=str(data.get('update_target') or '')
    target_sha=str(data.get('update_sha256') or '').lower()
    raw=str(data.get('update_status') or '').upper()
    same=(
        str(data.get('desired_ingress_version') or '') == str(release['version']) and
        target == str(release['version']) and
        target_sha == str(release['sha256']).lower()
    )
    if same and raw in ('QUEUED','DOWNLOADING','VERIFYING','APPLYING') and not force:
        return 'active'
    if same and raw in ('FAILED','ROLLED_BACK','CANCELLED') and not force:
        return 'failed'

    t=now()
    c.execute(
        'UPDATE connections SET desired_ingress_version=?,desired_ingress_source=?,updated_at=? WHERE name=?',
        (release['version'],source,t,name),
    )
    c.execute('INSERT OR IGNORE INTO ingress_state(connection_name) VALUES(?)',(name,))
    c.execute('''
        UPDATE ingress_state
        SET update_target=?,update_sha256=?,update_status='QUEUED',
            update_error=NULL,last_error=NULL,update_started_at=NULL,update_finished_at=NULL
        WHERE connection_name=?
    ''',(release['version'],release['sha256'],name))
    return 'queued'


def maintain_auto_updates(c,retry_failed=False):
    stable=latest_stable_release(c)
    result={'queued':0,'active':0,'failed':0,'current':0,'manual':0,'no_stable':0}
    if not stable:
        result['no_stable']=1
        return result

    rows=c.execute('''
        SELECT c.name,c.desired_ingress_version,c.desired_ingress_source,c.update_policy,
               s.ingress_version,s.ingress_sha256,s.update_status,s.update_target,s.update_sha256,s.update_error
        FROM connections c LEFT JOIN ingress_state s ON s.connection_name=c.name
        WHERE c.update_policy='auto'
        ORDER BY c.profile_index
    ''').fetchall()

    for row in rows:
        data=dict(row)
        if _exact_release_match(data,stable):
            if data.get('desired_ingress_source') == 'auto' and data.get('desired_ingress_version'):
                c.execute(
                    'UPDATE connections SET desired_ingress_version=NULL,desired_ingress_source=NULL,updated_at=? WHERE name=?',
                    (now(),row['name']),
                )
            result['current']+=1
            continue

        if data.get('desired_ingress_version') and data.get('desired_ingress_source') == 'manual':
            result['manual']+=1
            continue

        status=_queue_release_for_connection(
            c,row['name'],stable,'auto',force=bool(retry_failed)
        )
        if status == 'queued':
            result['queued']+=1
        elif status in result:
            result[status]+=1
    return result


def endpoint_release_status(c):
    selected=None
    for row in c.execute(
        "SELECT version,sha256,manifest_json,created_at FROM software_releases "
        "WHERE status='stable' ORDER BY created_at DESC"
    ):
        if ENDPOINT_SYNC_CAPABILITY in release_capabilities(row):
            selected=row
            break
    if selected:
        return {
            'ready':True,
            'state':'READY',
            'version':selected['version'],
            'sha256':selected['sha256'],
            'detail':f"{selected['version']} STABLE",
        }
    any_stable=c.execute(
        "SELECT version FROM software_releases WHERE status='stable' ORDER BY created_at DESC LIMIT 1"
    ).fetchone()
    if any_stable:
        return {
            'ready':False,
            'state':'INCOMPATIBLE',
            'version':any_stable['version'],
            'sha256':None,
            'detail':'Publish and promote the current endpoint-capable Client release',
        }
    return {
        'ready':False,
        'state':'MISSING',
        'version':None,
        'sha256':None,
        'detail':'No endpoint-capable STABLE Client release is published',
    }


def client_is_enrolled(data):
    try:
        if int(data.get('last_seen_at') or 0) > 0:
            return True
    except (TypeError,ValueError):
        pass
    return str(data.get('bootstrap_psk_state') or 'unenrolled') != 'unenrolled'


def endpoint_state_for(c,data,at=None,release=None,context=None):
    if context is None:
        hub=c.execute(
            "SELECT endpoint FROM hub WHERE id=1"
        ).fetchone()
        desired='' if not hub else str(hub['endpoint'] or '').strip().lower().rstrip('.')
        fallbacks=endpoint_fallbacks(c)
    else:
        desired=str(context.get('desired') or '').strip().lower().rstrip('.')
        fallbacks=list(context.get('fallbacks') or [])
        if release is None:
            release=context.get('release')
    fallback=fallbacks[-1] if fallbacks else ''
    transition_active=bool(fallbacks)
    reported=str(data.get('client_endpoint') or '').strip().lower().rstrip('.')
    error=str(data.get('endpoint_error') or '').strip()
    capabilities=parse_client_capabilities(data.get('client_capabilities_json'))
    reported_capable=ENDPOINT_SYNC_CAPABILITY in capabilities
    enrolled=client_is_enrolled(data)
    try:
        last_seen=int(data.get('last_seen_at') or 0)
    except (TypeError,ValueError):
        last_seen=0
    health=effective_ingress_health(data.get('health'),last_seen,at)
    unavailable=health in ('OFFLINE','STALE') or (enrolled and last_seen <= 0)
    release=endpoint_release_status(c) if release is None else release
    wanted=str(data.get('desired_ingress_version') or '').strip()
    policy=str(data.get('update_policy') or 'manual').strip().upper()
    version=str(data.get('ingress_version') or '').strip()
    sha=str(data.get('ingress_sha256') or '').strip().lower()
    update_status=str(data.get('update_status') or '').strip().upper()
    update_target=str(data.get('update_target') or '').strip()
    update_sha=str(data.get('update_sha256') or '').strip().lower()
    update_error=str(data.get('update_error') or '').strip()

    # Endpoint capability describes the Client installed now. A current
    # capability report or an exact installed (version,SHA256) match is proof.
    installed_release=None
    if version and re.fullmatch(r'[0-9a-f]{64}',sha):
        installed_release=c.execute(
            "SELECT version,sha256,manifest_json FROM software_releases WHERE version=? AND sha256=?",
            (version,sha),
        ).fetchone()
    exact_capable_build=bool(
        installed_release and ENDPOINT_SYNC_CAPABILITY in release_capabilities(installed_release)
    )
    capable=reported_capable or exact_capable_build
    update_failed=update_status in ('FAILED','ROLLED_BACK','CANCELLED') and not capable
    update_in_progress=bool(
        update_status in ('QUEUED','DOWNLOADING','VERIFYING','APPLYING') or
        (wanted and not capable and not update_failed)
    )

    # Stable operation and migration use the same endpoint truth: if the Client
    # reports the active Server endpoint it is synchronized. A retained fallback
    # tells us a migration transaction is open; it does not enable/disable the
    # endpoint capability itself.
    if desired and reported == desired:
        state='SYNCED'
        detail='Current endpoint confirmed'
    elif not enrolled:
        state='NOT ENROLLED'
        detail='Client has not completed managed endpoint enrollment'
    elif error:
        state='FAILED'
        detail=error
    elif update_failed:
        state='FAILED'
        detail=f'Client software update {update_status.lower().replace("_"," ")}; retry before endpoint activation'
    elif unavailable:
        state='DEFERRED'
        availability='not reporting' if last_seen <= 0 else health.lower()
        if capable:
            detail=f'Client is {availability}; endpoint synchronization resumes after reconnecting'
        elif update_in_progress or wanted:
            target=wanted or update_target or release.get('version') or 'compatible software'
            detail=f'Client is {availability}; {target} and endpoint synchronization resume after reconnecting'
        elif release['ready'] and policy == 'AUTO':
            detail=f'Client is {availability}; software update and endpoint synchronization are queued automatically'
        elif release['ready']:
            detail=f'Client is {availability}; install {release["version"]} manually after reconnecting'
        else:
            detail=f"Client is {availability}; {release['detail']}"
    elif capable:
        state='PENDING'
        if not reported_capable:
            detail='Endpoint-capable build is installed; managed runtime refresh is queued'
        elif transition_active:
            detail='Endpoint migration is queued for the next CONTROL/1 cycle'
        else:
            detail='Client endpoint differs from the active Server endpoint; synchronization is queued for the next CONTROL/1 cycle'
    elif update_in_progress:
        state='UPDATING'
        target=wanted or update_target or release.get('version') or 'compatible software'
        detail=f'Installing {target}; endpoint synchronization follows automatically'
    else:
        state='UPDATE REQUIRED'
        if release['ready'] and policy == 'AUTO':
            detail=f"{release['version']} will be queued automatically before endpoint synchronization"
        elif release['ready']:
            detail=f"Update policy is {policy}; install {release['version']} before endpoint synchronization"
        else:
            detail=release['detail']

    source='reported' if reported_capable else ('installed-sha' if exact_capable_build else 'none')
    return {
        'server_endpoint':desired or None,
        'previous_server_endpoint':fallback or None,
        'fallback_server_endpoints':fallbacks,
        'client_endpoint':reported or None,
        'endpoint_state':state,
        'endpoint_detail':detail,
        'endpoint_capable':capable,
        'endpoint_reported_capable':reported_capable,
        'endpoint_exact_capable_build':exact_capable_build,
        'endpoint_capability_source':source,
        'client_capabilities':sorted(capabilities),
        'endpoint_enrolled':enrolled,
        'endpoint_transition_active':transition_active,
    }

def endpoint_rows(c,at=None):
    release=endpoint_release_status(c)
    hub=c.execute("SELECT endpoint FROM hub WHERE id=1").fetchone()
    context={
        'desired':'' if not hub else str(hub['endpoint'] or '').strip().lower().rstrip('.'),
        'fallbacks':endpoint_fallbacks(c),
        'release':release,
    }
    rows=[]
    for row in c.execute("""
        SELECT c.*,
               s.ingress_version,s.ingress_sha256,s.health,s.update_status,s.last_seen_at,
               s.bootstrap_psk_state,s.update_target,s.update_sha256,s.update_error,
               s.update_started_at,s.update_finished_at,
               s.client_endpoint,s.endpoint_error,s.endpoint_updated_at,
               s.client_capabilities_json
        FROM connections c
        LEFT JOIN ingress_state s ON s.connection_name=c.name
       
        ORDER BY c.profile_index
    """):
        data=dict(row)
        data.update(endpoint_state_for(c,data,at,release=release,context=context))
        rows.append(data)
    return rows


def maybe_complete_endpoint_transition(c,at=None):
    hub=c.execute("""
        SELECT endpoint,endpoint_completed_at
        FROM hub WHERE id=1
    """).fetchone()
    fallbacks=endpoint_fallbacks(c)
    if not hub or not fallbacks:
        return False
    rows=endpoint_rows(c,at)
    enrolled=[row for row in rows if row['endpoint_enrolled']]
    complete=all(row['endpoint_state']=='SYNCED' for row in enrolled)
    if complete and not hub['endpoint_completed_at']:
        completed=int(time.time() if at is None else at)
        c.execute(
            'UPDATE hub SET endpoint_completed_at=?,updated_at=? WHERE id=1',
            (completed,completed),
        )
        audit(
            c,
            'server-endpoint-synced',
            f"all enrolled Clients synchronized to {hub['endpoint']}; "
            f"retained previous endpoint safe to retire: {','.join(fallbacks)}",
        )
        return True
    if not complete and hub['endpoint_completed_at']:
        c.execute('UPDATE hub SET endpoint_completed_at=NULL WHERE id=1')
    return complete

def endpoint_transition_status(c,at=None):
    # Pure read: do not advance endpoint state from a status/fleet/UI request.
    # The registry daemon and explicit reconcile command own queueing and
    # convergence; retained previous endpoints are retired only explicitly.
    hub=c.execute("""
        SELECT endpoint,endpoint_changed_at,endpoint_completed_at
        FROM hub WHERE id=1
    """).fetchone()
    if not hub:
        raise SystemExit('server endpoint is not initialized')
    fallbacks=endpoint_fallbacks(c)
    previous=latest_endpoint_fallback(c)
    clients=endpoint_rows(c,at)
    migration_active=bool(fallbacks)
    counts={key:0 for key in ('SYNCED','PENDING','UPDATING','UPDATE REQUIRED','DEFERRED','FAILED','NOT ENROLLED')}
    for item in clients:
        counts[item['endpoint_state']]=counts.get(item['endpoint_state'],0)+1
    enrolled=[item for item in clients if item['endpoint_enrolled']]
    synced_enrolled=sum(1 for item in enrolled if item['endpoint_state']=='SYNCED')
    blocking=sum(1 for item in enrolled if item['endpoint_state']!='SYNCED')
    release=endpoint_release_status(c)
    try:
        endpoint_mode='IP' if ipaddress.ip_address(str(hub['endpoint'])).version == 4 else 'FQDN'
    except ValueError:
        endpoint_mode='FQDN'
    if migration_active:
        migration_state='ACTIVE' if blocking else 'READY TO FINISH'
    else:
        migration_state='IDLE'
    synchronization_state='READY' if not enrolled else ('SYNCED' if not blocking else 'ATTENTION')
    return {
        'endpoint_mode':endpoint_mode,
        'migration_active':migration_active,
        'migration_state':migration_state,
        'synchronization_state':synchronization_state,
        'server_endpoint':hub['endpoint'],
        'previous_server_endpoint':previous,
        'fallback_server_endpoints':fallbacks,
        'fallback_count':len(fallbacks),
        'changed_at':hub['endpoint_changed_at'],
        'completed_at':hub['endpoint_completed_at'],
        'transition_active':bool(migration_active and blocking),
        'safe_to_retire_previous':bool(migration_active and not blocking),
        'safe_to_retire_fallbacks':bool(migration_active and not blocking),
        'total_clients':len(clients),
        'enrolled_clients':len(enrolled),
        'synced_clients':synced_enrolled,
        'blocking_clients':blocking,
        'counts':counts,
        'client_release':release,
        'clients':[
            {
                'name':item['name'],
                'state':item['endpoint_state'],
                'reported_endpoint':item['client_endpoint'],
                'current_endpoint':item['client_endpoint'],
                'detail':item['endpoint_detail'],
                'last_seen_at':item.get('last_seen_at') or 0,
                'health':effective_ingress_health(item.get('health'),item.get('last_seen_at'),at),
                'software':item.get('ingress_version'),
                'update_policy':item.get('update_policy'),
                'enrolled':item['endpoint_enrolled'],
            }
            for item in clients
        ],
    }

def queue_endpoint_clients(c,retry_failed=False):
    hub=c.execute('SELECT endpoint FROM hub WHERE id=1').fetchone()
    if not hub or not str(hub['endpoint'] or '').strip():
        return {
            'queued_updates':0,'queued_refreshes':0,'already_queued':0,
            'manual_clients':0,'release_missing_clients':0,'failed_clients':0,
        }

    release=endpoint_release_status(c)
    stable=None
    if release['ready']:
        stable=c.execute(
            "SELECT version,sha256,manifest_json FROM software_releases "
            "WHERE version=? AND sha256=? AND status='stable'",
            (release['version'],release['sha256']),
        ).fetchone()

    queued_updates=0
    queued_refreshes=0
    already_queued=0
    waiting_manual=0
    release_missing=0
    failed_clients=0
    t=now()

    for row in endpoint_rows(c):
        if row['endpoint_state'] in ('SYNCED','NOT ENROLLED'):
            continue

        name=row['name']
        pending=str(row.get('pending_action') or '')

        if row.get('endpoint_capable'):
            # A Client that has reported endpoint-sync capability normally needs
            # no separate reconcile action: it consumes server_endpoint on every
            # CONTROL poll. An explicit Server retry is different. Queue one
            # reconcile signal for every capable unsynchronized Client so local
            # endpoint backoff can be bypassed and the runtime can self-heal.
            need_refresh=(not row.get('endpoint_reported_capable')) or bool(retry_failed)
            if need_refresh:
                if pending == 'reconcile':
                    already_queued+=1
                elif not pending:
                    c.execute(
                        "UPDATE connections SET pending_action='reconcile',updated_at=? WHERE name=?",
                        (t,name),
                    )
                    c.execute('INSERT OR IGNORE INTO ingress_state(connection_name) VALUES(?)',(name,))
                    message=(
                        'retrying endpoint activation and managed Client runtime'
                        if retry_failed else
                        'refreshing managed Client runtime for endpoint migration'
                    )
                    c.execute("""
                        UPDATE ingress_state
                        SET action_name='reconcile',action_status='QUEUED',
                            action_message=?,action_started_at=NULL,action_finished_at=NULL
                        WHERE connection_name=?
                    """,(message,name))
                    queued_refreshes+=1
                else:
                    # Never overwrite an unrelated explicit managed action. The
                    # endpoint stays pending until that action completes.
                    already_queued+=1
            continue

        if not stable:
            release_missing+=1
            continue

        policy=str(row.get('update_policy') or 'manual').lower()
        desired=str(row.get('desired_ingress_version') or '')
        desired_source=str(row.get('desired_ingress_source') or '').lower()
        # Endpoint orchestration must never replace an explicit software
        # deployment. The software state machine owns that intent; endpoint
        # activation resumes after the requested exact build is resolved.
        if desired and desired_source == 'manual':
            waiting_manual+=1
            continue
        if policy != 'auto':
            waiting_manual+=1
            continue

        update_status=str(row.get('update_status') or '').upper()
        update_target=str(row.get('update_target') or '')
        update_sha=str(row.get('update_sha256') or '').lower()
        same_target=(
            desired == stable['version'] and
            update_target == stable['version'] and
            update_sha == stable['sha256']
        )

        if same_target and update_status in ('QUEUED','DOWNLOADING','VERIFYING','APPLYING'):
            already_queued+=1
            continue

        if same_target and update_status in ('FAILED','ROLLED_BACK','CANCELLED') and not retry_failed:
            failed_clients+=1
            continue

        c.execute('INSERT OR IGNORE INTO ingress_state(connection_name) VALUES(?)',(name,))
        c.execute(
            "UPDATE connections SET desired_ingress_version=?,desired_ingress_source='auto',updated_at=? WHERE name=?",
            (stable['version'],t,name),
        )
        c.execute("""
            UPDATE ingress_state
            SET update_target=?,update_sha256=?,update_status='QUEUED',
                update_error=NULL,last_error=NULL,
                update_started_at=NULL,update_finished_at=NULL
            WHERE connection_name=?
        """,(stable['version'],stable['sha256'],name))
        queued_updates+=1

    return {
        'queued_updates':queued_updates,
        'queued_refreshes':queued_refreshes,
        'already_queued':already_queued,
        'manual_clients':waiting_manual,
        'release_missing_clients':release_missing,
        'failed_clients':failed_clients,
    }


def maintain_endpoint_transition(c,at=None,retry_failed=False):
    hub=c.execute('SELECT endpoint FROM hub WHERE id=1').fetchone()
    if not hub or not str(hub['endpoint'] or '').strip():
        return {
            'queued_updates':0,'queued_refreshes':0,'already_queued':0,
            'manual_clients':0,'release_missing_clients':0,'failed_clients':0,
        }
    queued=queue_endpoint_clients(c,retry_failed=retry_failed)
    maybe_complete_endpoint_transition(c,at)
    return queued


def cmd_server_endpoint_status(a):
    # Status queries are intentionally read-only. Endpoint queueing, recovery
    # and automatic finalization belong to the registry daemon or the explicit
    # server-endpoint-reconcile command, never to an interactive UI render path.
    with conn() as c:
        init_schema(c)
        status=endpoint_transition_status(c)
        if getattr(a,'json',False):
            print(json.dumps(status,sort_keys=True))
        else:
            print(json.dumps(status,sort_keys=True,indent=2))


def cmd_server_endpoint_reconcile(a):
    with conn() as c:
        init_schema(c)
        hub=c.execute('SELECT endpoint FROM hub WHERE id=1').fetchone()
        desired='' if not hub else str(hub['endpoint'] or '').strip().lower().rstrip('.')
        cleared=0
        if desired:
            cur=c.execute(
                """
                UPDATE ingress_state
                SET endpoint_error=NULL
                WHERE endpoint_error IS NOT NULL
                  AND LOWER(RTRIM(COALESCE(client_endpoint,''),'.')) != ?
                """,
                (desired,),
            )
            cleared=int(cur.rowcount or 0)
        queued=maintain_endpoint_transition(c,retry_failed=True)
        status=endpoint_transition_status(c)
        audit(
            c,
            'server-endpoint-reconcile',
            f"retry requested; errors_cleared={cleared}; "
            f"software_updates={queued['queued_updates']}; "
            f"runtime_refreshes={queued['queued_refreshes']}; "
            f"manual_clients={queued['manual_clients']}",
        )
        c.commit()
        print(json.dumps({'errors_cleared':cleared,'queue':queued,'status':status},sort_keys=True))


def cmd_server_endpoint_retire_previous(a):
    with conn() as c:
        init_schema(c)
        status=endpoint_transition_status(c)
        fallbacks=list(status.get('fallback_server_endpoints') or [])
        if not fallbacks:
            print('-')
            return
        if not status.get('safe_to_retire_fallbacks'):
            raise SystemExit('retained previous endpoints cannot be retired until every enrolled Client is synchronized to the active endpoint')
        current=status.get('server_endpoint')
        t=now()
        c.execute('DELETE FROM server_endpoint_fallbacks')
        c.execute(
            "UPDATE hub SET endpoint_completed_at=COALESCE(endpoint_completed_at,?),updated_at=? WHERE id=1",
            (t,t),
        )
        audit(
            c,
            'server-endpoint-retired',
            f"retained previous endpoint acknowledged: {','.join(fallbacks)}; {current} remains authoritative",
        )
        c.commit()
        print(','.join(fallbacks))

def management_row(c,name=None,connection_uuid=None):
    state_cols=(
        "s.ingress_version,s.ingress_sha256,s.health,s.update_status,s.last_error,"
        "s.last_seen_at,s.bootstrap_psk_state,s.update_target,s.update_sha256,s.update_error,"
        "s.update_started_at,s.update_finished_at,s.action_name,s.action_status,"
        "s.action_message,s.action_started_at,s.action_finished_at,"
        "s.client_endpoint,s.endpoint_error,s.endpoint_updated_at,s.client_capabilities_json"
    )
    if name:
        r=c.execute(f"SELECT c.*,{state_cols} FROM connections c LEFT JOIN ingress_state s ON s.connection_name=c.name WHERE c.name=?",(name,)).fetchone()
    else:
        r=c.execute(f"SELECT c.*,{state_cols} FROM connections c LEFT JOIN ingress_state s ON s.connection_name=c.name WHERE c.connection_uuid=?",(connection_uuid,)).fetchone()
    if not r: raise SystemExit("unknown managed connection")
    return r


def cmd_management_show(a):
    with conn() as c:
        init_schema(c); r=management_row(c,name=a.name); d=dict(r)
        d["health"]=effective_ingress_health(d.get("health"),d.get("last_seen_at"))
        desired=d.get("desired_ingress_version")
        desired_rel=c.execute("SELECT sha256 FROM software_releases WHERE version=?",(desired,)).fetchone() if desired else None
        d["desired_ingress_sha256"]=None if not desired_rel else desired_rel[0]
        d.update(software_state_for(c,d))
        pending=c.execute("SELECT transaction_id,state,candidate_json,error FROM config_pending WHERE connection_name=?",(a.name,)).fetchone()
        d["pending_transaction"]=dict(pending) if pending else None
        d.update(endpoint_state_for(c,d))
        if a.json:
            print(json.dumps(d,sort_keys=True)); return
        for k in (
            "connection_uuid",
            "ingress_version","ingress_sha256","desired_ingress_version","desired_ingress_sha256","desired_ingress_source","stable_ingress_version","stable_ingress_sha256","software_state","update_policy","health","update_status",
            "update_target","update_sha256","update_error","update_started_at","update_finished_at","last_seen_at",
            "bootstrap_psk_state","pending_action","action_name","action_status","action_message",
            "action_started_at","action_finished_at","server_endpoint","previous_server_endpoint","fallback_server_endpoints",
            "client_endpoint","endpoint_state","endpoint_detail","endpoint_capable","client_capabilities",
            "endpoint_error","endpoint_updated_at","last_error",
        ):
            value=d.get(k)
            if k == 'update_status':
                value={
                    'APPLYING':'INSTALLING',
                    'ROLLED_BACK':'ROLLED BACK',
                }.get(str(value or ''),value)
            if isinstance(value,(list,dict)):
                value=json.dumps(value,sort_keys=True,separators=(',',':'))
            print(f"{k.upper()}	{value if value not in (None,'') else '-'}")


def cmd_management_set(a):
    with conn() as c:
        init_schema(c); r=management_row(c,name=a.name); fields=[]; vals=[]; changes=[]; t=now()
        if a.desired_version is not None:
            desired=a.desired_version or None
            desired_sha=None
            if desired:
                rel=c.execute("SELECT status,sha256 FROM software_releases WHERE version=?",(desired,)).fetchone()
                if not rel or rel[0] == "revoked":
                    raise SystemExit("desired Client release is not active")
                desired_sha=rel[1]
            desired_source=(a.desired_source or 'manual') if desired else None
            # An explicit operator deployment is authoritative until the operator
            # deliberately resumes AUTO. Without this hold, a CANARY or rollback
            # build installed on an AUTO Client is immediately replaced by the
            # current STABLE release on the next registry reconciliation cycle.
            if desired and desired_source == 'manual' and a.update_policy is None and r['update_policy'] != 'manual':
                fields.append('update_policy=?'); vals.append('manual')
                changes.append('update policy -> manual (explicit release hold)')
            if desired != r["desired_ingress_version"] or desired_source != r["desired_ingress_source"]:
                fields.append("desired_ingress_version=?"); vals.append(desired)
                fields.append("desired_ingress_source=?"); vals.append(desired_source)
                changes.append(f"desired Client version -> {desired or 'none'}")
            elif desired:
                changes.append(f"desired Client version {desired} requeued")
            if desired:
                c.execute("""
                    UPDATE ingress_state
                    SET update_target=?,update_sha256=?,update_status='QUEUED',update_error=NULL,last_error=NULL,
                        update_started_at=NULL,update_finished_at=NULL
                    WHERE connection_name=?
                """,(desired,desired_sha,a.name))
            else:
                c.execute("""
                    UPDATE ingress_state
                    SET update_target=NULL,update_sha256=NULL,
                        update_status=CASE WHEN update_status IN ('QUEUED','DOWNLOADING','VERIFYING','APPLYING') THEN 'CANCELLED' ELSE update_status END,
                        update_finished_at=CASE WHEN update_status IN ('QUEUED','DOWNLOADING','VERIFYING','APPLYING') THEN ? ELSE update_finished_at END
                    WHERE connection_name=?
                """,(t,a.name))
        if a.update_policy is not None and a.update_policy != r["update_policy"]:
            fields.append("update_policy=?"); vals.append(a.update_policy); changes.append(f"update policy -> {a.update_policy}")
        if a.pending_action is not None:
            value=None if a.pending_action in ("","none") else a.pending_action
            if value != (r["pending_action"] or None):
                fields.append("pending_action=?"); vals.append(value); changes.append(f"pending action -> {value or 'none'}")
            elif value:
                changes.append(f"pending action {value} requeued")
            if value:
                c.execute("""
                    UPDATE ingress_state
                    SET action_name=?,action_status='QUEUED',action_message=NULL,
                        action_started_at=NULL,action_finished_at=NULL,last_error=NULL
                    WHERE connection_name=?
                """,(value,a.name))
            else:
                c.execute("""
                    UPDATE ingress_state
                    SET action_status=CASE WHEN action_status IN ('QUEUED','RUNNING') THEN 'CANCELLED' ELSE action_status END,
                        action_finished_at=CASE WHEN action_status IN ('QUEUED','RUNNING') THEN ? ELSE action_finished_at END
                    WHERE connection_name=?
                """,(t,a.name))
        if fields:
            fields.append("updated_at=?"); vals.append(t); vals.append(a.name)
            c.execute(f"UPDATE connections SET {','.join(fields)} WHERE name=?",vals)
        if changes:
            audit(c,"connection-management", "; ".join(changes),a.name)
        c.commit()


def cmd_management_credentials(a):
    with conn() as c:
        init_schema(c); r=management_row(c,name=a.name)
        print(f"CONNECTION_UUID\t{r['connection_uuid']}")
        print(f"CONTROL_KEY\t{r['control_key']}")

def cmd_token_record(a):
    if int(a.token_version) != ENROLLMENT_TOKEN_VERSION:
        raise SystemExit(f"unsupported enrollment token version: {a.token_version}")
    with conn() as c:
        init_schema(c); management_row(c,name=a.name)
        c.execute("UPDATE enrollment_tokens SET revoked_at=? WHERE connection_name=? AND consumed_at IS NULL AND revoked_at IS NULL",(now(),a.name))
        c.execute("INSERT INTO enrollment_tokens(connection_name,token_hash,token_version,issued_at,expires_at) VALUES(?,?,?,?,?)",(a.name,a.token_hash,a.token_version,now(),a.expires_at))
        token_id=c.execute("SELECT last_insert_rowid()").fetchone()[0]
        audit(c,"connection-enrollment-issued",f"token #{token_id} expires={a.expires_at}",a.name); c.commit(); print(token_id)

def cmd_token_consume(a):
    with conn() as c:
        init_schema(c)
        r=c.execute("SELECT * FROM enrollment_tokens WHERE token_hash=?",(a.token_hash,)).fetchone()
        if not r: raise SystemExit("unknown enrollment token")
        if r["revoked_at"] is not None: raise SystemExit("enrollment token revoked")
        if r["consumed_at"] is not None: raise SystemExit("enrollment token already consumed")
        if int(r["expires_at"]) < now(): raise SystemExit("enrollment token expired")
        c.execute("UPDATE enrollment_tokens SET consumed_at=? WHERE id=?",(now(),r["id"]))
        audit(c,"connection-enrolled",f"enrollment token #{r['id']} consumed",r["connection_name"]); c.commit(); print(r["connection_name"])

def _config_snapshot(r):
    # PSK is part of the temporary snapshot so credential rotation has the same
    # deterministic rollback semantics as transport changes. It is never
    # written to audit detail or management UI output.
    keys=("udp_port","xfrm_mtu","dns_primary","dns_secondary","psk")
    return {k:r[k] for k in keys}


def _config_changed(previous,candidate):
    labels={
        "udp_port":"UDP port",
        "xfrm_mtu":"XFRM MTU",
        "dns_primary":"primary DNS",
        "dns_secondary":"secondary DNS",
        "psk":"credentials",
    }
    return [labels.get(k,k) for k in candidate if candidate[k] != previous[k]]


def _config_pending(c,name):
    return c.execute("SELECT * FROM config_pending WHERE connection_name=?",(name,)).fetchone()


def cmd_config_stage(a):
    with conn() as c:
        init_schema(c); r=management_row(c,name=a.name)
        previous=_config_snapshot(r); candidate=dict(previous)
        if a.udp_port is not None:
            if not (20000 <= a.udp_port <= 59999): raise SystemExit("UDP port must be 20000-59999")
            owner=c.execute("SELECT name FROM connections WHERE udp_port=? AND name<>?",(a.udp_port,a.name)).fetchone()
            if owner: raise SystemExit(f"UDP port already assigned to {owner[0]}")
            candidate["udp_port"]=a.udp_port
        if a.xfrm_mtu is not None:
            if not (1200 <= a.xfrm_mtu <= 9000): raise SystemExit("XFRM MTU must be 1200-9000")
            candidate["xfrm_mtu"]=a.xfrm_mtu
        for field,value in (("dns_primary",a.dns_primary),("dns_secondary",a.dns_secondary)):
            if value is not None:
                ipaddress.ip_address(value); candidate[field]=value
        if a.rotate_psk:
            candidate["psk"]=secrets.token_hex(32)
        if candidate == previous: raise SystemExit("no configuration change requested")
        active=_config_pending(c,a.name)
        if active and active['state'] == 'COMMITTED':
            # COMMITTED is terminal success. Older v2.1.0 builds could leave
            # this temporary row behind if the coordinator exited after the
            # Client acknowledgement. The authoritative connection values are
            # already committed, so pruning it is safe and prevents a false
            # perpetual VERIFYING state from blocking the next edit.
            c.execute("DELETE FROM config_pending WHERE connection_name=? AND transaction_id=?",(a.name,active['transaction_id']))
            active=None
        if active:
            raise SystemExit(f"a configuration change is already {str(active['state']).lower()}; finish or recover it first")
        txid=str(uuid.uuid4()); t=now()
        c.execute("""
            INSERT INTO config_pending(
              connection_name,transaction_id,state,previous_json,candidate_json,
              created_at,updated_at,kind
            ) VALUES(?,?,?,?,?,?,?,?)
        """,(a.name,txid,"PENDING",json.dumps(previous,sort_keys=True),json.dumps(candidate,sort_keys=True),t,t,"manual"))
        changed=_config_changed(previous,candidate)
        audit(c,"connection-config-staged",f"changed: {', '.join(changed)}",a.name)
        c.commit(); print(txid)


def cmd_config_cancel(a):
    with conn() as c:
        init_schema(c); management_row(c,name=a.name)
        tx=_config_pending(c,a.name)
        if not tx: return
        if tx["state"] != "PENDING":
            raise SystemExit(f"configuration change is {str(tx['state']).lower()}; it is already coordinated and will commit or roll back")
        reason=a.reason or "cancelled"
        if (tx["kind"] or "manual") == "bootstrap-psk":
            c.execute("UPDATE ingress_state SET bootstrap_psk_state='rotation-deferred' WHERE connection_name=? AND bootstrap_psk_state='psk-rotation-pending'",(a.name,))
        audit(c,"connection-config-rollback",f"cancelled before apply: {reason}",a.name)
        c.execute("DELETE FROM config_pending WHERE connection_name=?",(a.name,))
        c.commit()


def cmd_config_commit(a):
    with conn() as c:
        init_schema(c); management_row(c,name=a.name)
        tx=c.execute("SELECT * FROM config_pending WHERE connection_name=? AND transaction_id=?",(a.name,a.transaction_id)).fetchone()
        if not tx: raise SystemExit("unknown configuration transaction")
        if tx["state"] not in ("APPLYING","COMMITTED"):
            raise SystemExit(f"configuration change is {tx['state']}; Server runtime is not ready to commit")
        # COMMITTED is terminal success, not a durable active state. Older
        # builds used a second finalize step; current DFR removes the temporary
        # row in the same transaction that makes the candidate authoritative.
        if tx["state"] == "COMMITTED":
            c.execute("DELETE FROM config_pending WHERE connection_name=? AND transaction_id=?",(a.name,a.transaction_id))
            c.commit(); return
        candidate=json.loads(tx["candidate_json"]); previous=json.loads(tx["previous_json"]); t=now()
        c.execute("UPDATE connections SET udp_port=?,xfrm_mtu=?,dns_primary=?,dns_secondary=?,psk=?,pending_action=NULL,updated_at=? WHERE name=?",(candidate["udp_port"],candidate["xfrm_mtu"],candidate["dns_primary"],candidate["dns_secondary"],candidate["psk"],t,a.name))
        c.execute("UPDATE enrollment_tokens SET revoked_at=? WHERE connection_name=? AND consumed_at IS NULL AND revoked_at IS NULL",(t,a.name))
        (CONFIG_ROOT/'clients'/a.name/'pairing-token.txt').unlink(missing_ok=True)
        if candidate.get("psk") != previous.get("psk"):
            c.execute("UPDATE ingress_state SET bootstrap_psk_state='rotated' WHERE connection_name=?",(a.name,))
        c.execute("DELETE FROM config_pending WHERE connection_name=? AND transaction_id=?",(a.name,a.transaction_id))
        audit(c,"connection-config-committed","configuration applied and verified by Client; transaction finalized",a.name)
        c.commit()


def cmd_config_finalize(a):
    with conn() as c:
        init_schema(c)
        tx=c.execute("SELECT state FROM config_pending WHERE connection_name=? AND transaction_id=?",(a.name,a.transaction_id)).fetchone()
        if not tx: return
        if tx["state"] not in ("COMMITTED","FAILED"):
            raise SystemExit("configuration transaction is still active")
        c.execute("DELETE FROM config_pending WHERE connection_name=? AND transaction_id=?",(a.name,a.transaction_id))
        c.commit()


def cmd_config_active(a):
    with conn() as c:
        init_schema(c)
        for r in c.execute("SELECT connection_name,transaction_id,state FROM config_pending ORDER BY connection_name"):
            print(f"{r['connection_name']}\t{r['transaction_id']}\t{r['state']}")


def cmd_config_recover(a):
    with conn() as c:
        init_schema(c)
        tx=c.execute("SELECT * FROM config_pending WHERE connection_name=? AND transaction_id=?",(a.name,a.transaction_id)).fetchone()
        if not tx: return
        reason=a.reason or "previous active configuration restored"
        if (tx['kind'] or 'manual') == 'bootstrap-psk':
            c.execute("UPDATE ingress_state SET bootstrap_psk_state='rotation-failed' WHERE connection_name=? AND bootstrap_psk_state='psk-rotation-pending'",(a.name,))
        audit(c,'connection-config-rollback',reason,a.name)
        c.execute("DELETE FROM config_pending WHERE connection_name=? AND transaction_id=?",(a.name,a.transaction_id))
        c.execute("UPDATE connections SET pending_action=NULL,updated_at=? WHERE name=?",(now(),a.name))
        c.commit()


def cmd_config_transaction(a):
    with conn() as c:
        init_schema(c)
        tx=c.execute("SELECT * FROM config_pending WHERE connection_name=? AND transaction_id=?",(a.name,a.transaction_id)).fetchone()
        if not tx: raise SystemExit("unknown configuration transaction")
        print(json.dumps(dict(tx),sort_keys=True))


def cmd_config_mark(a):
    with conn() as c:
        init_schema(c)
        tx=c.execute("SELECT * FROM config_pending WHERE connection_name=? AND transaction_id=?",(a.name,a.transaction_id)).fetchone()
        if not tx: raise SystemExit("unknown configuration transaction")
        current=tx['state']
        allowed={
            'PENDING':{'PENDING','PREPARED','FAILED'},
            'PREPARED':{'PREPARED','APPLYING','FAILED'},
            'APPLYING':{'APPLYING','COMMITTED','FAILED'},
            'FAILED':{'FAILED'},
            'COMMITTED':{'COMMITTED'},
        }
        if a.state not in allowed.get(current,{current}):
            raise SystemExit(f"invalid configuration transition {current} -> {a.state}")
        fields=["state=?","updated_at=?"]; vals=[a.state,now()]
        if a.prepared_at is not None: fields.append("prepared_at=?"); vals.append(a.prepared_at)
        if getattr(a,'egress_apply_at',None) is not None: fields.append("egress_apply_at=?"); vals.append(a.egress_apply_at)
        if a.apply_at is not None: fields.append("apply_at=?"); vals.append(a.apply_at)
        if a.rollback_at is not None: fields.append("rollback_at=?"); vals.append(a.rollback_at)
        if a.error is not None: fields.append("error=?"); vals.append(a.error)
        vals.extend((a.name,a.transaction_id))
        c.execute(f"UPDATE config_pending SET {','.join(fields)} WHERE connection_name=? AND transaction_id=?",vals)
        c.commit()


def cmd_runtime_info(a):
    print(json.dumps({
        "app_version": APP_VERSION,
        "schema": SCHEMA,
        "runtime_api": RUNTIME_API,
        "capabilities": [
            "release-info",
            "release-delete",
            "release-publish",
            "release-status",
            "management-show",
            "config-stage",
            "config-transaction-v3",
            "management-observability-v1",
            "release-purge",
            "subscription-reset-v1",
            "management-effective-health-v1",
            "release-sha-update-v1",
            "server-endpoint-sync-v2",
            "server-endpoint-auto-orchestration-v1",
            "server-endpoint-retarget-v1",
            "server-client-ui-v1",
            "server-client-ui-v2",
            "fleet-snapshot-v1",
            "presence-observability-v1",
            "registry-monitoring-v1",
            "registry-live-daemon-v1",
            "software-auto-convergence-v1",
            "software-current-sha-v1",
        ],
    }, sort_keys=True))

def cmd_release_publish(a):
    payload=pathlib.Path(a.payload); sig=pathlib.Path(a.signature)
    if not payload.is_file() or not sig.is_file(): raise SystemExit("release payload/signature missing")
    digest=hashlib.sha256(payload.read_bytes()).hexdigest()
    if a.sha256 and a.sha256 != digest: raise SystemExit("release checksum mismatch")
    manifest=json.loads(a.manifest_json)
    if manifest.get("format") != "dragon-fruit-relay-ingress-release" or int(manifest.get("format_version",0)) != 1: raise SystemExit("unsupported Client release manifest")
    if manifest.get("version") != a.version: raise SystemExit("release manifest version mismatch")
    if manifest.get("role") != "ingress": raise SystemExit("release role must be ingress")
    if int(manifest.get("minimum_control_protocol",0)) > 1: raise SystemExit("release requires a newer CONTROL protocol")
    if int(manifest.get("enrollment_token_version",0)) != ENROLLMENT_TOKEN_VERSION: raise SystemExit("release enrollment-token contract mismatch")
    if int(manifest.get("config_schema",0)) != 1: raise SystemExit("release Client configuration schema mismatch")
    if manifest.get("sha256") != digest: raise SystemExit("release manifest checksum mismatch")
    capabilities=manifest.get("capabilities") or []
    if not isinstance(capabilities,list) or any(not isinstance(item,str) for item in capabilities):
        raise SystemExit("release capabilities must be a list of strings")
    with conn() as c:
        init_schema(c)
        existing=c.execute("SELECT sha256,status FROM software_releases WHERE version=?",(a.version,)).fetchone()
        if existing and existing[0] != digest:
            if not getattr(a,'replace',False):
                raise SystemExit("published version has a different digest; use an explicit replacement publish")
            old_digest,old_status=existing[0],existing[1]
            t=now()
            c.execute("""
                UPDATE software_releases
                SET sha256=?,payload_path=?,signature_path=?,manifest_json=?,status='staged',created_at=?
                WHERE version=?
            """,(digest,str(payload),str(sig),json.dumps(manifest,sort_keys=True),t,a.version))
            c.execute("UPDATE connections SET desired_ingress_version=NULL,desired_ingress_source=NULL,updated_at=? WHERE desired_ingress_version=?",(t,a.version))
            c.execute("""
                UPDATE ingress_state
                SET update_target=NULL,update_sha256=NULL,
                    update_status=CASE WHEN update_status IN ('QUEUED','DOWNLOADING','VERIFYING','APPLYING') THEN 'CANCELLED' ELSE update_status END,
                    update_finished_at=CASE WHEN update_status IN ('QUEUED','DOWNLOADING','VERIFYING','APPLYING') THEN ? ELSE update_finished_at END
                WHERE update_target=?
            """,(t,a.version))
            c.execute("DELETE FROM software_release_usage WHERE version=?",(a.version,))
            audit(c,"ingress-release-replaced",f"{a.version} sha256={old_digest} -> {digest}; previous_status={old_status}; replacement staged")
            c.commit()
            return
        if existing:
            if existing[1] == "revoked" and a.status != "revoked":
                raise SystemExit("revoked release is terminal while retained; delete it only if unused, then republish, or use a newer APP_VERSION")
            if existing[1] != a.status:
                c.execute("UPDATE software_releases SET status=? WHERE version=?",(a.status,a.version))
                audit(c,"ingress-release-status",f"{a.version} -> {a.status}")
        else:
            c.execute("INSERT INTO software_releases(version,sha256,payload_path,signature_path,manifest_json,status,created_at) VALUES(?,?,?,?,?,?,?)",(a.version,digest,str(payload),str(sig),json.dumps(manifest,sort_keys=True),a.status,now()))
            audit(c,"ingress-release-published",f"{a.version} status={a.status} sha256={digest}")
        c.commit()
def cmd_release_list(a):
    with conn() as c:
        init_schema(c)
        for r in c.execute("SELECT version,status,sha256,created_at,payload_path FROM software_releases ORDER BY created_at DESC"):
            print("\t".join(map(str,r)))

def cmd_release_status(a):
    with conn() as c:
        init_schema(c)
        row=c.execute("SELECT status FROM software_releases WHERE version=?",(a.version,)).fetchone()
        if not row: raise SystemExit("unknown release")
        current=row[0]
        if current == "revoked" and a.status != "revoked":
            raise SystemExit("revoked releases cannot be reactivated; delete it only if unused, or publish a newer version")

        changed=current != a.status
        if changed:
            c.execute("UPDATE software_releases SET status=? WHERE version=?",(a.status,a.version))
            if a.status == "revoked":
                c.execute("UPDATE connections SET desired_ingress_version=NULL,desired_ingress_source=NULL WHERE desired_ingress_version=?",(a.version,))
            audit(c,"ingress-release-status",f"{a.version}: {current} -> {a.status}")

        if a.status == 'stable':
            maintain_auto_updates(c)
            maintain_endpoint_transition(c)

        c.commit()


def cmd_release_info(a):
    with conn() as c:
        init_schema(c)
        r=c.execute("SELECT version,status,sha256,created_at,payload_path FROM software_releases WHERE version=?",(a.version,)).fetchone()
        if not r: raise SystemExit("unknown release")
        desired=c.execute("SELECT COUNT(*) FROM connections WHERE desired_ingress_version=?",(a.version,)).fetchone()[0]
        applied=c.execute("SELECT COUNT(*) FROM ingress_state WHERE ingress_version=? AND ingress_sha256=?",(a.version,r["sha256"])).fetchone()[0]
        ever_applied=c.execute("SELECT COUNT(*) FROM software_release_usage WHERE version=?",(a.version,)).fetchone()[0]
        print(json.dumps({
            "version":r["version"],"status":r["status"],"sha256":r["sha256"],
            "created_at":r["created_at"],"payload_path":r["payload_path"],
            "desired_clients":int(desired),"applied_clients":int(applied),"ever_applied_clients":int(ever_applied),
            "deletable": bool(r["status"]=="revoked" and desired==0 and applied==0),
        },sort_keys=True))

def cmd_release_delete(a):
    with conn() as c:
        init_schema(c)
        r=c.execute("SELECT version,status,sha256,payload_path FROM software_releases WHERE version=?",(a.version,)).fetchone()
        if not r: raise SystemExit("unknown release")
        if r["status"] != "revoked": raise SystemExit("only REVOKED releases can be deleted")
        desired=c.execute("SELECT COUNT(*) FROM connections WHERE desired_ingress_version=?",(a.version,)).fetchone()[0]
        applied=c.execute("SELECT COUNT(*) FROM ingress_state WHERE ingress_version=? AND ingress_sha256=?",(a.version,r["sha256"])).fetchone()[0]
        ever_applied=c.execute("SELECT COUNT(*) FROM software_release_usage WHERE version=?",(a.version,)).fetchone()[0]
        if desired or applied:
            raise SystemExit(f"release cannot be deleted safely while referenced: desired={desired} currently_applied={applied}")
        if ever_applied:
            raise SystemExit(f"release has historical usage on {ever_applied} Client records; use release-purge --force-history for permanent deletion")
        digest=r["sha256"]
        payload=pathlib.Path(r["payload_path"])
        c.execute("DELETE FROM software_releases WHERE version=?",(a.version,))
        audit(c,"ingress-release-deleted",f"{a.version} sha256={digest}; unused revoked release removed")
        c.commit()
    release_dir=payload.parent
    try:
        root=RELEASE_ROOT.resolve()
        resolved=release_dir.resolve()
        if resolved.parent == root:
            shutil.rmtree(resolved,ignore_errors=False)
    except FileNotFoundError:
        pass
    except Exception as exc:
        print(f"warning: release registry entry deleted but payload directory cleanup failed: {exc}",file=sys.stderr)
    print(str(release_dir))

def _payload_declared_version(path):
    try:
        for line in pathlib.Path(path).read_text(errors="replace").splitlines():
            if line.startswith('readonly APP_VERSION="'):
                return line.split('"',2)[1]
    except OSError:
        return ""
    return ""


def cmd_release_purge(a):
    payload_path=""
    with conn() as c:
        init_schema(c)
        r=c.execute("SELECT version,status,payload_path,sha256 FROM software_releases WHERE version=?",(a.version,)).fetchone()
        if not r: raise SystemExit("unknown release")
        if r["status"] != "revoked":
            raise SystemExit("only REVOKED releases can be permanently deleted")
        desired=c.execute("SELECT COUNT(*) FROM connections WHERE desired_ingress_version=?",(a.version,)).fetchone()[0]
        applied=c.execute("SELECT COUNT(*) FROM ingress_state WHERE ingress_version=? AND ingress_sha256=?",(a.version,r["sha256"])).fetchone()[0]
        ever=c.execute("SELECT COUNT(*) FROM software_release_usage WHERE version=?",(a.version,)).fetchone()[0]
        if desired or applied:
            raise SystemExit(f"release cannot be permanently deleted while referenced: desired={desired} currently_applied={applied}")
        if ever and not a.force_history:
            raise SystemExit(f"release has historical usage on {ever} Client records; repeat with --force-history to erase that release history")
        payload_path=r["payload_path"] or ""
        digest=r["sha256"] or ""
        c.execute("DELETE FROM software_releases WHERE version=?",(a.version,))
        c.execute("DELETE FROM software_release_usage WHERE version=?",(a.version,))
        audit(c,"ingress-release-purged",f"{a.version} sha256={digest}; historical_usage_rows={ever}; permanent operator deletion")
        c.commit()
    if payload_path:
        release_dir=pathlib.Path(payload_path).parent
        try:
            root=RELEASE_ROOT.resolve()
            resolved=release_dir.resolve()
            if resolved.parent == root:
                shutil.rmtree(resolved,ignore_errors=False)
        except FileNotFoundError:
            pass
        except Exception as exc:
            print(f"warning: release metadata purged but payload directory cleanup failed: {exc}",file=sys.stderr)
    print(json.dumps({"version":a.version,"purged":True,"payload_path":payload_path},sort_keys=True))


def nft_json():
    try: return json.loads(subprocess.check_output([NFT,"-j","list","table","inet",SUB_TABLE],stderr=subprocess.DEVNULL,text=True))
    except Exception: return None

def extract_named_counters(doc,table=SUB_TABLE):
    out={}
    if not doc: return out
    for item in doc.get("nftables",[]):
        c=item.get("counter")
        if c and c.get("table")==table and "name" in c: out[c["name"]]=int(c.get("bytes",0))
    return out

def extract_named_quotas(doc):
    out={}
    if not doc: return out
    for item in doc.get("nftables",[]):
        q=item.get("quota")
        if not q or q.get("table")!=SUB_TABLE or "name" not in q: continue
        used=q.get("used",q.get("consumed",0))
        if isinstance(used,dict): used=used.get("bytes",used.get("value",0))
        try: out[q["name"]]=int(used or 0)
        except (TypeError,ValueError): pass
    return out

def counter_names(idx): return f"dfr_u_{idx:04d}", f"dfr_d_{idx:04d}", f"dfr_q_{idx:04d}"



def sync_kernel():
    doc=nft_json(); counters=extract_named_counters(doc); quotas=extract_named_quotas(doc)
    if not counters: return False
    with conn() as c:
        init_schema(c); changed=False; t=now()
        for r in c.execute("SELECT c.name,c.profile_index,s.quota_bytes,u.* FROM connections c JOIN subscriptions s ON s.connection_name=c.name JOIN usage u ON u.connection_name=c.name"):
            un,dn,qn=counter_names(r["profile_index"])
            up=counters.get(un); down=counters.get(dn)
            if up is None or down is None: continue
            old_up=int(r["period_upload_bytes"]); old_down=int(r["period_download_bytes"]); old_quota_used=int(r["quota_used_bytes"] or 0)
            if up < old_up or down < old_down: continue
            dup=up-old_up; ddn=down-old_down; directional=up+down
            if r["quota_bytes"] is None:
                quota_used=directional
            else:
                raw=quotas.get(qn)
                observed=directional if raw is None else min(int(raw),int(r["quota_bytes"]))
                quota_used=max(old_quota_used,directional,observed)
            if dup or ddn or quota_used!=old_quota_used:
                c.execute("UPDATE usage SET period_upload_bytes=?,period_download_bytes=?,quota_used_bytes=?,lifetime_upload_bytes=lifetime_upload_bytes+?,lifetime_download_bytes=lifetime_download_bytes+?,last_sync_at=? WHERE connection_name=?",(up,down,quota_used,dup,ddn,t,r["name"])); changed=True
            else: c.execute("UPDATE usage SET last_sync_at=? WHERE connection_name=?",(t,r["name"],))
        c.commit()
    return changed

def nft_quote(s): return '"'+s.replace('\\','\\\\').replace('"','\\"')+'"'

def build_sub_rules(c, reset_connection=None):
    lines=[f"table inet {SUB_TABLE} {{"]
    rows=list(c.execute("SELECT c.name,c.profile_index,c.xfrm_if,c.ingress_xfrm_ip,s.*,u.* FROM connections c JOIN subscriptions s ON s.connection_name=c.name JOIN usage u ON u.connection_name=c.name ORDER BY c.profile_index"))
    for r in rows:
        un,dn,qn=counter_names(r["profile_index"])
        reset=(r["name"] == reset_connection)
        up=0 if reset else int(r["period_upload_bytes"])
        down=0 if reset else int(r["period_download_bytes"])
        quota_used=0 if reset else int(r["quota_used_bytes"] or 0)
        lines.append(f" counter {un} {{ packets 0 bytes {up} }}")
        lines.append(f" counter {dn} {{ packets 0 bytes {down} }}")
        if r["quota_bytes"] is not None:
            used=max(up+down,quota_used); lines.append(f" quota {qn} {{ until {int(r['quota_bytes'])} bytes used {used} bytes }}")
    lines.append(" chain forward { type filter hook forward priority -50; policy accept;")
    for r in rows:
        un,dn,qn=counter_names(r["profile_index"])
        reset=(r["name"] == reset_connection)
        current_usage={
            "period_upload_bytes": 0 if reset else int(r["period_upload_bytes"]),
            "period_download_bytes": 0 if reset else int(r["period_download_bytes"]),
            "quota_used_bytes": 0 if reset else int(r["quota_used_bytes"] or 0),
        }
        st=state(r,current_usage); x=nft_quote(r["xfrm_if"]); ip=r["ingress_xfrm_ip"]
        if st != "ACTIVE":
            lines.append(f"  iifname {x} ip saddr {ip} drop")
            lines.append(f"  oifname {x} ip daddr {ip} drop")
        elif r["quota_bytes"] is None:
            lines.append(f"  iifname {x} ip saddr {ip} counter name {nft_quote(un)} accept")
            lines.append(f"  oifname {x} ip daddr {ip} counter name {nft_quote(dn)} accept")
        else:
            lines.append(f"  iifname {x} ip saddr {ip} quota name {nft_quote(qn)} counter name {nft_quote(un)} accept")
            lines.append(f"  iifname {x} ip saddr {ip} drop")
            lines.append(f"  oifname {x} ip daddr {ip} quota name {nft_quote(qn)} counter name {nft_quote(dn)} accept")
            lines.append(f"  oifname {x} ip daddr {ip} drop")
    lines.append(" }"); lines.append("}"); return "\n".join(lines)+"\n"

def run_nft_script(script,best_effort=False):
    p=subprocess.run([NFT,"-f","-"],input=f"delete table inet {SUB_TABLE}\n"+script,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    if p.returncode!=0:
        # deleting absent table causes failure before create; retry create only
        p=subprocess.run([NFT,"-f","-"],input=script,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    if p.returncode!=0 and not best_effort: raise SystemExit(p.stderr.strip() or "nft apply failed")
    return p.returncode==0

def apply_tc(c,best_effort=False):
    if shutil.which(TC) is None: return False
    ok=True
    for r in c.execute("SELECT c.xfrm_if,s.max_upload_mbps,s.max_download_mbps FROM connections c JOIN subscriptions s ON s.connection_name=c.name"):
        dev=r["xfrm_if"]
        # only touch dedicated DFR-owned xfrm interfaces; stopped profiles
        # intentionally have no interface, so there is nothing to shape yet.
        if not re.fullmatch(r"dfr[0-9]{4}",dev): continue
        if not pathlib.Path("/sys/class/net", dev).exists(): continue
        subprocess.run([TC,"qdisc","del","dev",dev,"root"],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        subprocess.run([TC,"qdisc","del","dev",dev,"ingress"],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        if r["max_download_mbps"]:
            rc=subprocess.run([TC,"qdisc","replace","dev",dev,"root","tbf","rate",f"{r['max_download_mbps']}mbit","burst","256kbit","latency","50ms"],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode; ok &= rc==0
        if r["max_upload_mbps"]:
            subprocess.run([TC,"qdisc","add","dev",dev,"ingress"],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            rc=subprocess.run([TC,"filter","add","dev",dev,"parent","ffff:","protocol","ip","prio","1","u32","match","u32","0","0","police","rate",f"{r['max_upload_mbps']}mbit","burst","256k","drop","flowid",":1"],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode; ok &= rc==0
    if not ok and not best_effort: raise SystemExit("tc speed policy apply failed")
    return ok






def apply_global_speed(best_effort=False):
    if shutil.which(NFT) is None:
        return False
    with conn() as c:
        init_schema(c)
        policy=c.execute('SELECT * FROM server_policy WHERE id=1').fetchone()
        ifaces=[str(r[0]) for r in c.execute('SELECT xfrm_if FROM connections ORDER BY profile_index') if r[0]]
    subprocess.run([NFT,'delete','table','inet',GLOBAL_SPEED_TABLE],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    if not ifaces or (not policy['max_upload_mbps'] and not policy['max_download_mbps']):
        return True
    set_expr='{ '+', '.join(nft_quote(x) for x in ifaces)+' }'
    lines=[f'table inet {GLOBAL_SPEED_TABLE} {{',' chain input { type filter hook input priority -40; policy accept;']
    if policy['max_upload_mbps']:
        lines.append(f"  iifname {set_expr} limit rate over {int(policy['max_upload_mbps'])*125} kbytes/second burst 256 kbytes drop")
    lines += [' }',' chain output { type filter hook output priority -40; policy accept;']
    if policy['max_download_mbps']:
        lines.append(f"  oifname {set_expr} limit rate over {int(policy['max_download_mbps'])*125} kbytes/second burst 256 kbytes drop")
    lines += [' }','}']
    p=subprocess.run([NFT,'-f','-'],input='\n'.join(lines)+'\n',text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    if p.returncode and not best_effort:
        raise SystemExit(p.stderr.strip() or 'global Server speed policy apply failed')
    return p.returncode==0

def apply_runtime(best_effort=False):
    if shutil.which(NFT) is None:
        if best_effort: return False
        raise SystemExit('nft is required')
    sync_kernel()
    with conn() as c:
        init_schema(c)
        script=build_sub_rules(c)
        nft_ok=run_nft_script(script,best_effort=best_effort)
        tc_ok=apply_tc(c,best_effort=best_effort)
    global_ok=apply_global_speed(best_effort=best_effort)
    return bool(nft_ok and tc_ok and global_ok)



def _natural_key(value):
    return [int(part) if part.isdigit() else part.lower() for part in re.split(r'(\d+)',str(value or ''))]


def _short_uuid_map(rows):
    normalized={}
    for row in rows:
        raw=str(row.get('connection_uuid') or '').replace('-','').lower()
        normalized[row['name']]=raw
    result={}
    for name,raw in normalized.items():
        if not raw:
            result[name]='-'
            continue
        length=12
        while length < len(raw):
            prefix=raw[:length]
            if sum(1 for other in normalized.values() if other and other.startswith(prefix)) == 1:
                break
            length += 1
        result[name]=raw[:length]
    return result


def _read_peer_cache(name):
    # Runtime truth comes from systemd and authenticated CONTROL presence.
    # Remote peer details are intentionally diagnostic-only and are not persisted
    # as a separate product subsystem.
    return {'runtime_status':'UNKNOWN','remote_peer':'-','runtime_updated_at':0}



def _presence_state(last_seen,current):
    try: seen=int(last_seen or 0)
    except (TypeError,ValueError): seen=0
    if seen <= 0: return 'NEVER SEEN'
    age=max(0,current-seen)
    if age >= MANAGEMENT_HEALTH_OFFLINE_SECONDS: return 'OFFLINE'
    if age >= MANAGEMENT_HEALTH_STALE_SECONDS: return 'STALE'
    return 'ONLINE'


def _severity_rank(value):
    return {'CRITICAL':0,'WARNING':1,'ADVISORY':2}.get(value,9)


def _systemd_client_states(rows):
    """Return current local service state for every connection in one bounded call."""
    names=[str(r.get('name') or '') for r in rows if str(r.get('name') or '')]
    if not names:
        return {}
    units=[f"dragon-fruit-relay-client@{name}.service" for name in names]
    out={name:{'load':'unknown','active':'unknown','sub':'unknown','result':'unknown','enabled':'unknown'} for name in names}
    try:
        p=subprocess.run(
            ['systemctl','show',*units,'-p','Id','-p','LoadState','-p','ActiveState','-p','SubState','-p','Result','-p','UnitFileState','--no-pager'],
            stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,timeout=2,
        )
        block={}
        def consume(b):
            unit=str(b.get('Id') or '')
            if '@' not in unit or not unit.endswith('.service'):
                return
            name=unit.split('@',1)[1][:-8]
            if name in out:
                out[name]={
                    'load':str(b.get('LoadState') or 'unknown').lower(),
                    'active':str(b.get('ActiveState') or 'unknown').lower(),
                    'sub':str(b.get('SubState') or 'unknown').lower(),
                    'result':str(b.get('Result') or 'unknown').lower(),
                    'enabled':str(b.get('UnitFileState') or 'unknown').lower(),
                }
        for line in p.stdout.splitlines()+['']:
            if not line.strip():
                if block: consume(block); block={}
                continue
            if '=' in line:
                k,v=line.split('=',1); block[k]=v
    except Exception:
        pass
    return out


def _canonical_runtime(presence,service,cache,last_seen,current):
    """One runtime contract for every monitoring surface.

    Monitoring deliberately ignores stale diagnostic caches.
    Current systemd state and the current authenticated CONTROL heartbeat are
    the only runtime authorities.  Diagnostics may inspect IKE/CHILD/XFRM live,
    but cached diagnostic observations must never overwrite current presence.
    """
    load=str((service or {}).get('load') or 'unknown').lower()
    active=str((service or {}).get('active') or 'unknown').lower()
    result=str((service or {}).get('result') or 'unknown').lower()
    if load == 'not-found':
        return 'MISSING'
    if active == 'failed' or result == 'failed':
        return 'FAILED'
    if active not in ('active','activating','reloading') and active != 'unknown':
        return 'STOPPED'

    # Authenticated CONTROL is direct proof that the managed connection is
    # usable.  The same snapshot clock defines ONLINE/STALE/OFFLINE everywhere.
    if presence == 'ONLINE':
        return 'OPERATIONAL'
    if presence == 'STALE':
        return 'DEGRADED'
    if presence in ('OFFLINE','NEVER SEEN'):
        return 'READY' if active in ('active','activating','reloading') else 'UNKNOWN'
    return 'UNKNOWN'






def cmd_fleet_snapshot(a):
    current=now()
    with conn() as c:
        init_schema(c)
        # Fleet rendering is deliberately read-only. Presence is derived from
        # last_seen_at; the registry daemon owns persistent health transitions.
        stable=latest_stable_release(c)
        endpoint_release=endpoint_release_status(c)
        endpoint_hub=c.execute("SELECT endpoint FROM hub WHERE id=1").fetchone()
        endpoint_context={
            'desired':'' if not endpoint_hub else str(endpoint_hub['endpoint'] or '').strip().lower().rstrip('.'),
            'fallbacks':endpoint_fallbacks(c),
            'release':endpoint_release,
        }
        rows=[dict(r) for r in c.execute("""
            SELECT
              c.*,
              s.starts_at,s.expires_at,s.quota_bytes,s.max_upload_mbps,s.max_download_mbps,
              s.manual_suspended,s.period_started_at,
              u.period_upload_bytes,u.period_download_bytes,u.quota_used_bytes,
              u.lifetime_upload_bytes,u.lifetime_download_bytes,u.last_sync_at,
              i.ingress_version,i.ingress_sha256,i.health,i.update_status,i.last_error,
              i.last_seen_at,i.bootstrap_psk_state,i.update_target,i.update_sha256,i.update_error,
              i.update_started_at,i.update_finished_at,i.action_name,i.action_status,i.action_message,
              i.action_started_at,i.action_finished_at,i.client_endpoint,i.endpoint_error,
              i.endpoint_updated_at,i.client_capabilities_json
            FROM connections c
            LEFT JOIN subscriptions s ON s.connection_name=c.name
            LEFT JOIN usage u ON u.connection_name=c.name
            LEFT JOIN ingress_state i ON i.connection_name=c.name
        """)]

        latest_events={}
        for ev in c.execute("""
            SELECT connection_name,action,MAX(occurred_at) AS occurred_at
            FROM audit
            WHERE connection_name IS NOT NULL
              AND action IN (
                'connection-presence-connected',
                'connection-presence-disconnected',
                'connection-presence-offline'
              )
            GROUP BY connection_name,action
        """):
            latest_events.setdefault(ev['connection_name'],{})[ev['action']]=int(ev['occurred_at'] or 0)

        pending_tx={r['connection_name']:dict(r) for r in c.execute(
            "SELECT connection_name,transaction_id,state,updated_at,error,kind FROM config_pending"
        )}
        recent_activity=[dict(r) for r in c.execute(
            "SELECT occurred_at,connection_name,action,detail FROM audit ORDER BY id DESC LIMIT 80"
        )]

        service_states=_systemd_client_states(rows)
        short_map=_short_uuid_map(rows)
        items=[]
        attention=[]
        active_work=[]
        summary={
            'total':0,'operational':0,'ready':0,'stopped':0,'degraded':0,'failed':0,'unknown':0,
            'online':0,'stale':0,'offline':0,'never_seen':0,
            'attention':0,'critical':0,'warning':0,'advisory':0,'active_work':0,
        }

        for raw in rows:
            name=raw['name']
            cache=_read_peer_cache(name)
            presence=_presence_state(raw.get('last_seen_at'),current)
            runtime_status=_canonical_runtime(
                presence,service_states.get(name),cache,raw.get('last_seen_at'),current
            )
            software=software_state_for(c,raw,stable)
            endpoint=endpoint_state_for(c,raw,current,context=endpoint_context)
            sub_state=state(raw,raw,current) if raw.get('connection_name') is not None or raw.get('name') else 'UNKNOWN'
            used=int(raw.get('quota_used_bytes') or 0)
            directional=int(raw.get('period_upload_bytes') or 0)+int(raw.get('period_download_bytes') or 0)
            used=max(used,directional)
            quota=raw.get('quota_bytes')
            remaining=None if quota is None else max(0,int(quota)-used)
            ev=latest_events.get(name,{})
            tx=pending_tx.get(name)

            item={
                'name':name,
                'connection_uuid':raw.get('connection_uuid') or '',
                'uuid_short':short_map.get(name,'-'),
                'created_at':int(raw.get('created_at') or 0),
                'udp_port':int(raw.get('udp_port') or 0),
                'tunnel_cidr':raw.get('tunnel_cidr') or '-',
                'xfrm_if':raw.get('xfrm_if') or '-',
                'xfrm_id':int(raw.get('xfrm_id') or 0),
                'runtime_status':runtime_status,
                'runtime_updated_at':current,
                'runtime_cache_updated_at':int(cache.get('runtime_updated_at') or 0),
                'service_state':str((service_states.get(name) or {}).get('active') or 'unknown').upper(),
                'service_substate':str((service_states.get(name) or {}).get('sub') or 'unknown').upper(),
                'service_enabled':str((service_states.get(name) or {}).get('enabled') or 'unknown').upper(),
                'remote_peer':cache.get('remote_peer') or '-',
                'presence':presence,
                'last_seen_at':int(raw.get('last_seen_at') or 0),
                'last_connected_at':int(ev.get('connection-presence-connected') or 0),
                'last_disconnected_at':int(ev.get('connection-presence-disconnected') or 0),
                'last_offline_at':int(ev.get('connection-presence-offline') or 0),
                'health':effective_ingress_health(raw.get('health'),raw.get('last_seen_at'),current) or 'UNKNOWN',
                'ingress_version':raw.get('ingress_version') or '-',
                'software_state':software.get('software_state') or 'UNKNOWN',
                'stable_ingress_version':software.get('stable_ingress_version') or '-',
                'desired_ingress_version':raw.get('desired_ingress_version') or '-',
                'update_policy':raw.get('update_policy') or 'manual',
                'update_status':raw.get('update_status') or '-',
                'update_target':raw.get('update_target') or '-',
                'update_error':raw.get('update_error') or '-',
                'pending_action':raw.get('pending_action') or '-',
                'action_name':raw.get('action_name') or '-',
                'action_status':raw.get('action_status') or '-',
                'action_message':raw.get('action_message') or '-',
                'endpoint_state':endpoint.get('endpoint_state') or 'UNKNOWN',
                'endpoint_detail':endpoint.get('endpoint_detail') or '-',
                'client_endpoint':endpoint.get('client_endpoint') or raw.get('client_endpoint') or '-',
                'server_endpoint':endpoint.get('server_endpoint') or '-',
                'subscription_state':sub_state,
                'quota_bytes':quota,
                'used_bytes':used,
                'remaining_bytes':remaining,
                'last_error':raw.get('last_error') or '-',
                'config_transaction':tx,
            }
            items.append(item)
            summary['total'] += 1
            key=runtime_status.lower()
            if key in summary: summary[key] += 1
            else: summary['unknown'] += 1
            pkey=presence.lower().replace(' ','_')
            if pkey in summary: summary[pkey] += 1

            def add_attention(severity,area,headline,detail,recommended):
                attention.append({
                    'severity':severity,'area':area,'connection_name':name,
                    'connection_uuid':item['connection_uuid'],'uuid_short':item['uuid_short'],
                    'headline':headline,'detail':detail,'recommended_action':recommended,
                    'age_from':item['last_seen_at'] or item['created_at'],
                })

            def add_work(area,headline,detail):
                active_work.append({
                    'area':area,'connection_name':name,'uuid_short':item['uuid_short'],
                    'headline':headline,'detail':detail,
                })

            # Alert precedence is deliberate: emit the most actionable root
            # condition and suppress derivative symptoms from the same failure.
            # A stopped/failed local Server runtime naturally makes CONTROL go
            # offline; conversely an offline Client commonly makes an otherwise
            # healthy listener look READY/DEGRADED. Do not alert on both.
            if runtime_status in ('FAILED','MISSING'):
                add_attention('CRITICAL','RUNTIME',runtime_status,
                              f'Local connection runtime is {runtime_status.lower()}; Client presence is {presence}.',
                              'Open Connection Diagnostics and repair the local runtime.')
            elif runtime_status == 'STOPPED':
                # STOPPED can be an intentional operator state. Keep it visible
                # in Operations without turning a deliberate stop into an alert.
                add_work('RUNTIME','Connection stopped',
                         'The local connection service is stopped; Client contact is not expected until it is started.')
            elif presence == 'OFFLINE':
                age=max(0,current-int(item['last_seen_at'] or current))
                add_attention('WARNING','PRESENCE','Client offline',
                              f'No authenticated CONTROL contact for {age} seconds.',
                              'Check the Client, tunnel and upstream network path.')
            elif presence == 'STALE':
                # The 30-second boundary is a debounce/watch state, not yet an
                # administrator action condition. Escalate only at OFFLINE.
                add_work('PRESENCE','Client contact delayed',
                         'Authenticated CONTROL contact is older than 30 seconds; waiting for recovery before alerting.')
            elif presence == 'NEVER SEEN':
                age=max(0,current-int(item['created_at'] or current))
                if age >= 600:
                    add_attention('ADVISORY','PRESENCE','Client not enrolled',
                                  'No authenticated CONTROL contact has ever been received.',
                                  'Install the Client with a fresh enrollment token.')
                else:
                    add_work('PRESENCE','Awaiting first Client contact','New connection is waiting for enrollment.')
            elif runtime_status == 'DEGRADED':
                add_attention('WARNING','RUNTIME','Degraded runtime',
                              'The Client is reachable but the local connection runtime is not fully healthy.',
                              'Open Connection Diagnostics and inspect tunnel, XFRM and service state.')

            if item['presence'] == 'ONLINE' and item['health'] == 'UNHEALTHY' and runtime_status not in ('FAILED','MISSING','DEGRADED'):
                add_attention('WARNING','RUNTIME','Client health check failed',
                              'Authenticated CONTROL is online, but the Client managed health check is failing.',
                              'Open Connection Diagnostics and inspect the Client runtime and datapath.')

            software_failed = item['software_state'] in ('FAILED','ROLLED BACK') or str(item['update_status']).upper() in ('FAILED','ROLLED_BACK')
            if software_failed:
                add_attention('WARNING','SOFTWARE','Client software deployment failed',
                              item['update_error'] if item['update_error'] != '-' else item['software_state'],
                              'Open Software & CONTROL and review the deployment result.')
            elif str(item['update_status']).upper() in ('QUEUED','DOWNLOADING','VERIFYING','APPLYING'):
                add_work('SOFTWARE',f"Software {str(item['update_status']).upper()}",
                         f"Target {item['update_target']}")
            elif item['software_state'] == 'UPDATE REQUIRED' and item['update_policy'] == 'auto':
                add_work('SOFTWARE','Automatic software convergence pending',
                         f"Stable target {item['stable_ingress_version']}")

            endpoint_failed = item['endpoint_state'] == 'FAILED'
            if endpoint_failed:
                add_attention('WARNING','ENDPOINT','Endpoint synchronization failed',
                              item['endpoint_detail'],
                              'Open Software & CONTROL and review endpoint synchronization.')
            elif item['endpoint_state'] in ('PENDING','UPDATING','UPDATE REQUIRED','DEFERRED'):
                add_work('ENDPOINT',f"Endpoint {item['endpoint_state']}",item['endpoint_detail'])

            config_failed = False
            if tx:
                txstate=str(tx.get('state') or '').upper()
                if txstate == 'FAILED':
                    config_failed = True
                    add_attention('WARNING','CONFIGURATION','Configuration transaction failed',
                                  tx.get('error') or 'Rollback/recovery is required.',
                                  'Open Software & CONTROL and inspect the transaction.')
                else:
                    add_work('CONFIGURATION',f'Configuration {txstate}',f"Transaction {tx.get('transaction_id','-')}")

            action_failed = str(item['action_status']).upper() == 'FAILED'
            if action_failed:
                add_attention('WARNING','CONTROL','Managed action failed',
                              item['action_message'] if item['action_message'] != '-' else item['last_error'],
                              'Open Connection Diagnostics and review the failed managed action.')
            elif item['pending_action'] != '-' or str(item['action_status']).upper() in ('QUEUED','RUNNING'):
                add_work('CONTROL',f"Managed action {item['action_name'] if item['action_name'] != '-' else item['pending_action']}",
                         str(item['action_status']))

            if item['subscription_state'] in ('EXPIRED','QUOTA EXHAUSTED'):
                add_attention('ADVISORY','SUBSCRIPTION',item['subscription_state'].title(),
                              'The subscription policy is not currently allowing normal traffic.',
                              'Open Subscription & traffic to review the policy.')
            elif item['subscription_state'] == 'SUSPENDED':
                add_work('SUBSCRIPTION','Subscription suspended',
                         'Traffic is suspended by policy; this is treated as an intentional administrative state.')

            if item['presence'] == 'ONLINE' and item['last_error'] != '-' and not (software_failed or endpoint_failed or config_failed or action_failed):
                add_attention('WARNING','CONTROL','Client management error',
                              item['last_error'],
                              'Open Connection Diagnostics and inspect CONTROL and recent Client logs.')


        items.sort(key=lambda x: (_natural_key(x['name']),x['connection_uuid']))
        attention.sort(key=lambda x: (_severity_rank(x['severity']),_natural_key(x['connection_name']),x['area']))
        active_work.sort(key=lambda x: (_natural_key(x['connection_name']),x['area']))
        summary['attention']=len(attention)
        summary['attention_clients']=len({x['connection_name'] for x in attention})
        summary['critical']=sum(1 for x in attention if x['severity']=='CRITICAL')
        summary['warning']=sum(1 for x in attention if x['severity']=='WARNING')
        summary['advisory']=sum(1 for x in attention if x['severity']=='ADVISORY')
        summary['active_work']=len(active_work)
        summary['active_work_clients']=len({x['connection_name'] for x in active_work})

        release_counts={str(r['status']):int(r['n']) for r in c.execute(
            "SELECT status,COUNT(*) AS n FROM software_releases GROUP BY status"
        )}
        canary_row=c.execute(
            "SELECT version FROM software_releases WHERE status='canary' "
            "ORDER BY created_at DESC,version DESC LIMIT 1"
        ).fetchone()
        endpoint_status=endpoint_transition_status(c)
        payload={
            'generated_at':current,
            'summary':summary,
            'connections':items,
            'attention':attention,
            'active_work':active_work,
            'recent_activity':recent_activity,
            'server':{
                'stable_release':None if not stable else str(stable['version']),
                'canary_release':None if not canary_row else str(canary_row['version']),
                'release_counts':release_counts,
                'endpoint_transition':endpoint_status,
            },
        }
        if a.json:
            print(json.dumps(payload,sort_keys=True,separators=(',',':')))
            return
        for item in items:
            print('\t'.join(str(item.get(k,'-')) for k in (
                'name','uuid_short','runtime_status','presence','last_seen_at','udp_port','remote_peer','software_state'
            )))



def cmd_sync(a): sync_kernel()
def cmd_apply(a): apply_runtime(best_effort=False)

def write_daemon_runtime_state():
    DAEMON_RUNTIME_STATE.parent.mkdir(parents=True,exist_ok=True,mode=0o755)
    payload={
        'runtime_id':DAEMON_RUNTIME_ID,
        'app_version':APP_VERSION,
        'schema':SCHEMA,
        'runtime_api':RUNTIME_API,
        'pid':os.getpid(),
        'heartbeat_at':now(),
    }
    tmp=DAEMON_RUNTIME_STATE.with_name(f'{DAEMON_RUNTIME_STATE.name}.tmp.{os.getpid()}')
    tmp.write_text(json.dumps(payload,sort_keys=True)+'\n',encoding='utf-8')
    os.chmod(tmp,0o644)
    os.replace(tmp,DAEMON_RUNTIME_STATE)





def cmd_daemon(a):
    last_hash=None; last_apply=0.0
    while True:
        try:
            sync_kernel()
            with conn() as c:
                init_schema(c)
                refresh_ingress_health(c)
                maintain_auto_updates(c)
                maintain_endpoint_transition(c)
                c.commit()
                write_daemon_runtime_state()
                data=[dict(r) for r in c.execute(
                    'SELECT c.name,c.profile_index,c.xfrm_if,c.ingress_xfrm_ip,s.*,u.period_upload_bytes,u.period_download_bytes '
                    'FROM connections c JOIN subscriptions s ON s.connection_name=c.name '
                    'JOIN usage u ON u.connection_name=c.name ORDER BY c.profile_index')]
                policy=dict(c.execute('SELECT * FROM server_policy WHERE id=1').fetchone())
            digest=hashlib.sha256(json.dumps([data,policy],sort_keys=True,default=str).encode()).hexdigest()
            if digest != last_hash or time.time()-last_apply >= 60:
                if apply_runtime(best_effort=True):
                    last_hash=digest; last_apply=time.time()
        except Exception as exc:
            print(f'registry daemon: {exc}',file=sys.stderr)
        time.sleep(max(0.2,a.interval))


def db_snapshot(dest):
    dest=pathlib.Path(dest); dest.parent.mkdir(parents=True,exist_ok=True)
    with conn() as src:
        init_schema(src); sync_kernel(); dst=sqlite3.connect(dest); src.backup(dst); dst.close()
    os.chmod(dest,0o600)

def sha256(path):
    h=hashlib.sha256()
    with open(path,"rb") as f:
        for b in iter(lambda:f.read(1024*1024),b""): h.update(b)
    return h.hexdigest()

def _safe_backup_members(tf):
    members=tf.getmembers()
    for m in members:
        pp=pathlib.PurePosixPath(m.name)
        if pp.is_absolute() or '..' in pp.parts:
            raise ValueError('unsafe backup member path')
        if not (m.isfile() or m.isdir()):
            raise ValueError('backup may contain only regular files/directories')
    return members


def _extract_backup(tf,destination):
    members=_safe_backup_members(tf)
    if hasattr(tarfile,'data_filter'):
        tf.extractall(destination,members=members,filter='data')
    else:
        tf.extractall(destination,members=members)
    return members

def _verify_signing_pair(root):
    key=root/'secrets'/'ingress-update-ed25519.key'
    pub=root/'secrets'/'ingress-update-ed25519.pub'
    if not key.is_file() or not pub.is_file():
        raise ValueError('managed backup is missing update-signing keypair')
    derived=root/'secrets'/'derived.pub'
    cp=subprocess.run(['openssl','pkey','-in',str(key),'-pubout','-out',str(derived)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    if cp.returncode != 0 or derived.read_bytes()!=pub.read_bytes():
        raise ValueError('update-signing keypair verification failed')
    derived.unlink(missing_ok=True)


def cmd_backup_create(a):
    apply_runtime(best_effort=True); BACKUPS.mkdir(parents=True,exist_ok=True,mode=0o700)
    output=pathlib.Path(a.output) if a.output else BACKUPS/f"dragon-fruit-relay-{time.strftime('%Y%m%dT%H%M%SZ',time.gmtime())}.dfrbak"
    if not UPDATE_SIGNING_KEY.is_file() or not UPDATE_PUBLIC_KEY.is_file():
        raise SystemExit('managed backup requires the Client update-signing keypair')
    with tempfile.TemporaryDirectory(prefix='dfr-backup-') as td:
        td=pathlib.Path(td); snap=td/'registry.sqlite3'; db_snapshot(snap)
        with sqlite3.connect(snap) as c:
            c.execute('PRAGMA wal_checkpoint(TRUNCATE)'); c.execute('PRAGMA journal_mode=DELETE')
            row=c.execute('SELECT endpoint FROM hub WHERE id=1').fetchone(); endpoint=row[0] if row else ''
        for sidecar in (snap.with_name(snap.name+'-wal'),snap.with_name(snap.name+'-shm')): sidecar.unlink(missing_ok=True)
        secret_dir=td/'secrets'; secret_dir.mkdir(mode=0o700)
        shutil.copy2(UPDATE_SIGNING_KEY,secret_dir/'ingress-update-ed25519.key'); shutil.copy2(UPDATE_PUBLIC_KEY,secret_dir/'ingress-update-ed25519.pub')
        os.chmod(secret_dir/'ingress-update-ed25519.key',0o600); os.chmod(secret_dir/'ingress-update-ed25519.pub',0o644)
        _verify_signing_pair(td)
        if RELEASE_ROOT.is_dir(): shutil.copytree(RELEASE_ROOT,td/'releases'/'ingress',dirs_exist_ok=True)
        files={}
        for f in sorted(x for x in td.rglob('*') if x.is_file()):
            rel=f.relative_to(td).as_posix()
            if rel=='manifest.json' or rel.endswith('registry.sqlite3-wal') or rel.endswith('registry.sqlite3-shm'): continue
            files[rel]=sha256(f)
        manifest={'format':'dragon-fruit-relay-backup','format_version':1,'app_version':APP_VERSION,'registry_schema':SCHEMA,'created_at':utc_iso(),'endpoint':endpoint,'files':files}
        (td/'manifest.json').write_text(json.dumps(manifest,indent=2,sort_keys=True)+'\n')
        with tarfile.open(output,'w:gz') as tf:
            tf.add(td/'manifest.json',arcname='manifest.json')
            for rel in sorted(files): tf.add(td/rel,arcname=rel)
    os.chmod(output,0o600); print(output)



def verify_backup(path):
    path=pathlib.Path(path)
    with tempfile.TemporaryDirectory(prefix='dfr-verify-') as td:
        td=pathlib.Path(td)
        try:
            with tarfile.open(path,'r:gz') as tf:
                members=_extract_backup(tf,td)
            manifest=json.loads((td/'manifest.json').read_text())
            if manifest.get('format')!='dragon-fruit-relay-backup' or int(manifest.get('format_version',0))!=1:
                raise ValueError('unsupported DFR backup format')
            if int(manifest.get('registry_schema',0))!=SCHEMA:
                raise ValueError('backup registry schema is not current')
            expected=set((manifest.get('files') or {}).keys())
            actual={m.name for m in members if m.isfile() and m.name!='manifest.json'}
            required={'registry.sqlite3','secrets/ingress-update-ed25519.key','secrets/ingress-update-ed25519.pub'}
            if expected != actual or not required <= expected: raise ValueError('backup manifest/file set mismatch')
            for rel,digest in manifest['files'].items():
                if sha256(td/rel)!=digest: raise ValueError(f'checksum mismatch: {rel}')
            _verify_signing_pair(td)
            c=sqlite3.connect(td/'registry.sqlite3'); c.row_factory=sqlite3.Row
            try:
                if c.execute('PRAGMA integrity_check').fetchone()[0] != 'ok': raise ValueError('registry integrity check failed')
                _verify_schema(c)
            finally: c.close()
            return manifest,None,None
        except Exception as exc:
            raise SystemExit(f'invalid backup: {exc}')



def cmd_backup_verify(a):
    m,_,_=verify_backup(a.file)
    print(f"OK\t{m['endpoint']}\t{m['created_at']}\tregistry-schema={m['registry_schema']}\tformat={m['format_version']}")



def cmd_backup_list(a):
    BACKUPS.mkdir(parents=True,exist_ok=True,mode=0o700)
    for p in sorted(BACKUPS.rglob("*.dfrbak"),key=lambda p:p.stat().st_mtime)[::-1]: print(p)


def cmd_backup_restore(a):
    path=pathlib.Path(a.file); verify_backup(path)
    with tempfile.TemporaryDirectory(prefix='dfr-restore-') as td:
        td=pathlib.Path(td)
        with tarfile.open(path,'r:gz') as tf:
            _extract_backup(tf,td)
        manifest=json.loads((td/'manifest.json').read_text()); snap=td/'registry.sqlite3'
        DB.parent.mkdir(parents=True,exist_ok=True,mode=0o700); tmp=DB.with_suffix('.restore.tmp')
        shutil.copy2(snap,tmp); os.chmod(tmp,0o600)
        for sidecar in (DB.with_name(DB.name+'-wal'),DB.with_name(DB.name+'-shm')): sidecar.unlink(missing_ok=True)
        os.replace(tmp,DB)
        for sidecar in (DB.with_name(DB.name+'-wal'),DB.with_name(DB.name+'-shm')): sidecar.unlink(missing_ok=True)
        with conn() as restored: init_schema(restored)
        secret_dir=CONFIG_ROOT/'secrets'; secret_dir.mkdir(parents=True,exist_ok=True,mode=0o700)
        for name,mode in (('ingress-update-ed25519.key',0o600),('ingress-update-ed25519.pub',0o644)):
            src=td/'secrets'/name; dest=secret_dir/name; staged=dest.with_name(dest.name+'.restore.tmp')
            shutil.copy2(src,staged); os.chmod(staged,mode); os.replace(staged,dest)
        if RELEASE_ROOT.exists(): shutil.rmtree(RELEASE_ROOT)
        source=td/'releases'/'ingress'
        if source.is_dir(): shutil.copytree(source,RELEASE_ROOT)
        else: RELEASE_ROOT.mkdir(parents=True,exist_ok=True,mode=0o700)
    print(manifest.get('endpoint',''))


def cmd_schema_contract(a):
    print(json.dumps({
        'product':'dragon-fruit-relay','product_lineage':'standalone-dfr','registry_schema':SCHEMA,
        'tables':{k:list(v) for k,v in sorted(SCHEMA_TABLE_COLUMNS.items())},
    },sort_keys=True,separators=(',',':')))

def build_parser():
    p=argparse.ArgumentParser(); sp=p.add_subparsers(dest="cmd",required=True)
    q=sp.add_parser("init"); q.add_argument("--endpoint"); q.add_argument("--force",action="store_true"); q.set_defaults(func=cmd_init)
    q=sp.add_parser("server-endpoint"); q.set_defaults(func=cmd_server_endpoint)
    q=sp.add_parser("server-endpoint-set"); q.add_argument("endpoint"); q.set_defaults(func=cmd_server_endpoint_set)
    q=sp.add_parser("server-endpoint-status"); q.add_argument("--json",action="store_true"); q.set_defaults(func=cmd_server_endpoint_status)
    q=sp.add_parser("server-endpoint-reconcile"); q.set_defaults(func=cmd_server_endpoint_reconcile)
    q=sp.add_parser("server-endpoint-retire-previous"); q.set_defaults(func=cmd_server_endpoint_retire_previous)
    q=sp.add_parser("upsert-connection");
    for x,t,req in (("name",str,True),("profile-index",int,True),("udp-port",int,True),("tunnel-cidr",str,True),("xfrm-if",str,True),("xfrm-id",int,True),("xfrm-mtu",int,True),("ingress-xfrm-cidr",str,True),("egress-xfrm-cidr",str,True),("ingress-xfrm-ip",str,True),("egress-xfrm-ip",str,True),("ingress-id",str,True),("egress-id",str,True),("psk",str,True),("dns-primary",str,True),("dns-secondary",str,True)): q.add_argument("--"+x,type=t,required=req,dest=x.replace("-","_"))
    q.add_argument("--created-at",type=int); q.set_defaults(func=cmd_upsert)
    q=sp.add_parser("remove-connection"); q.add_argument("name"); q.set_defaults(func=cmd_remove)
    q=sp.add_parser("list-names"); q.set_defaults(func=cmd_list)
    q=sp.add_parser("show"); q.add_argument("name"); q.add_argument("--json",action="store_true"); q.set_defaults(func=cmd_show)
    q=sp.add_parser("set"); q.add_argument("name"); q.add_argument("--start"); q.add_argument("--expires"); q.add_argument("--quota"); q.add_argument("--upload-mbps"); q.add_argument("--download-mbps"); q.set_defaults(func=cmd_set)
    q=sp.add_parser("suspend"); q.add_argument("name"); q.set_defaults(func=cmd_suspend,suspend=True)
    q=sp.add_parser("resume"); q.add_argument("name"); q.set_defaults(func=cmd_suspend,suspend=False)
    q=sp.add_parser("renew"); q.add_argument("name"); q.add_argument("--start"); q.add_argument("--expires"); q.add_argument("--quota"); q.set_defaults(func=cmd_renew)
    q=sp.add_parser("reset-current"); q.add_argument("name"); q.set_defaults(func=cmd_reset_current)
    q=sp.add_parser("reset-lifetime"); q.add_argument("name"); q.set_defaults(func=cmd_reset_lifetime)
    q=sp.add_parser("audit"); q.add_argument("name",nargs="?"); q.add_argument("--scope",choices=("all","subscription","connection","hub"),default="all"); q.add_argument("--limit",type=int,default=50); q.add_argument("--offset",type=int,default=0); q.set_defaults(func=cmd_audit)
    q=sp.add_parser("export-shell"); q.add_argument("name"); q.set_defaults(func=cmd_export)
    q=sp.add_parser("server-speed"); q.add_argument("--show",action="store_true"); q.add_argument("--upload-mbps"); q.add_argument("--download-mbps"); q.add_argument("--disable",action="store_true"); q.set_defaults(func=cmd_server_speed)
    q=sp.add_parser("schema-contract"); q.set_defaults(func=cmd_schema_contract)
    q=sp.add_parser("management-show"); q.add_argument("name"); q.add_argument("--json",action="store_true"); q.set_defaults(func=cmd_management_show)
    q=sp.add_parser("management-set"); q.add_argument("name"); q.add_argument("--desired-version"); q.add_argument("--desired-source",choices=("manual","auto")); q.add_argument("--update-policy",choices=("manual","auto","pinned")); q.add_argument("--pending-action"); q.set_defaults(func=cmd_management_set)
    q=sp.add_parser("management-credentials"); q.add_argument("name"); q.set_defaults(func=cmd_management_credentials)
    q=sp.add_parser("token-record"); q.add_argument("name"); q.add_argument("--token-hash",required=True); q.add_argument("--token-version",type=int,required=True); q.add_argument("--expires-at",type=int,required=True); q.set_defaults(func=cmd_token_record)
    q=sp.add_parser("token-consume"); q.add_argument("--token-hash",required=True); q.set_defaults(func=cmd_token_consume)
    q=sp.add_parser("config-stage"); q.add_argument("name"); q.add_argument("--udp-port",type=int); q.add_argument("--xfrm-mtu",type=int); q.add_argument("--dns-primary"); q.add_argument("--dns-secondary"); q.add_argument("--rotate-psk",action="store_true"); q.set_defaults(func=cmd_config_stage)
    q=sp.add_parser("config-cancel"); q.add_argument("name"); q.add_argument("--reason"); q.set_defaults(func=cmd_config_cancel)
    q=sp.add_parser("config-active"); q.set_defaults(func=cmd_config_active)
    q=sp.add_parser("config-finalize"); q.add_argument("name"); q.add_argument("transaction_id"); q.set_defaults(func=cmd_config_finalize)
    q=sp.add_parser("config-recover"); q.add_argument("name"); q.add_argument("transaction_id"); q.add_argument("--reason"); q.set_defaults(func=cmd_config_recover)
    q=sp.add_parser("config-commit"); q.add_argument("name"); q.add_argument("transaction_id"); q.set_defaults(func=cmd_config_commit)
    q=sp.add_parser("config-transaction"); q.add_argument("name"); q.add_argument("transaction_id"); q.set_defaults(func=cmd_config_transaction)
    q=sp.add_parser("config-mark"); q.add_argument("name"); q.add_argument("transaction_id"); q.add_argument("state",choices=("PENDING","PREPARED","APPLYING","COMMITTED","FAILED")); q.add_argument("--prepared-at",type=int); q.add_argument("--egress-apply-at",type=int); q.add_argument("--apply-at",type=int); q.add_argument("--rollback-at",type=int); q.add_argument("--error"); q.set_defaults(func=cmd_config_mark)
    q=sp.add_parser("runtime-info"); q.set_defaults(func=cmd_runtime_info)
    q=sp.add_parser("fleet-snapshot"); q.add_argument("--json",action="store_true"); q.set_defaults(func=cmd_fleet_snapshot)
    q=sp.add_parser("release-publish"); q.add_argument("version"); q.add_argument("--payload",required=True); q.add_argument("--signature",required=True); q.add_argument("--sha256"); q.add_argument("--manifest-json",required=True); q.add_argument("--status",choices=("staged","canary","stable","revoked"),default="staged"); q.add_argument("--replace",action="store_true"); q.set_defaults(func=cmd_release_publish)
    q=sp.add_parser("release-list"); q.set_defaults(func=cmd_release_list)
    q=sp.add_parser("release-info"); q.add_argument("version"); q.set_defaults(func=cmd_release_info)
    q=sp.add_parser("release-status"); q.add_argument("version"); q.add_argument("status",choices=("staged","canary","stable","revoked")); q.set_defaults(func=cmd_release_status)
    q=sp.add_parser("release-delete"); q.add_argument("version"); q.set_defaults(func=cmd_release_delete)
    q=sp.add_parser("release-purge"); q.add_argument("version"); q.add_argument("--force-history",action="store_true"); q.set_defaults(func=cmd_release_purge)
    q=sp.add_parser("sync-kernel"); q.set_defaults(func=cmd_sync)
    q=sp.add_parser("apply"); q.set_defaults(func=cmd_apply)
    q=sp.add_parser("daemon"); q.add_argument("--interval",type=float,default=1.0); q.set_defaults(func=cmd_daemon)
    q=sp.add_parser("backup-create"); q.add_argument("--output"); q.set_defaults(func=cmd_backup_create)
    q=sp.add_parser("backup-list"); q.set_defaults(func=cmd_backup_list)
    q=sp.add_parser("backup-verify"); q.add_argument("file"); q.set_defaults(func=cmd_backup_verify)
    q=sp.add_parser("backup-restore"); q.add_argument("file"); q.set_defaults(func=cmd_backup_restore)
    return p


def main():
    try:
        a=build_parser().parse_args(); a.func(a)
    except sqlite3.IntegrityError as exc:
        raise SystemExit(f"registry resource conflict: {exc}")
if __name__=="__main__": main()
PY_DFR_REGISTRY
    chmod 0750 "$REGISTRY_HELPER"

    cat > "$REGISTRY_UNIT_FILE" <<EOF_REGISTRY_UNIT
# Managed by Dragon Fruit Relay ${APP_VERSION}.
[Unit]
Description=Dragon Fruit Relay persistent registry, quota and speed controller
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
UMask=0077
ExecStart=${REGISTRY_HELPER} daemon --interval 1
Restart=always
RestartSec=2s
Nice=5

[Install]
WantedBy=multi-user.target
EOF_REGISTRY_UNIT
    chmod 0644 "$REGISTRY_UNIT_FILE"
    link_managed_unit "$REGISTRY_UNIT"
    systemctl daemon-reload >/dev/null 2>&1 || true
}


registry_upsert_new_connection ()
{
    local name="$1"
    registry_command upsert-connection \
        --name "$name" \
        --profile-index "$PROFILE_INDEX" \
        --created-at "${PROFILE_CREATED_EPOCH:-$(date +%s)}" \
        --udp-port "$NATT_PORT" \
        --tunnel-cidr "$TUNNEL_CIDR" \
        --xfrm-if "$XFRM_IF" \
        --xfrm-id "$XFRM_ID" \
        --xfrm-mtu "$XFRM_MTU" \
        --ingress-xfrm-cidr "$INGRESS_XFRM_CIDR" \
        --egress-xfrm-cidr "$EGRESS_XFRM_CIDR" \
        --ingress-xfrm-ip "$INGRESS_XFRM_IP" \
        --egress-xfrm-ip "$EGRESS_XFRM_IP" \
        --ingress-id "$INGRESS_ID" \
        --egress-id "$EGRESS_ID" \
        --psk "$PSK" \
        --dns-primary "$DNS_PRIMARY" \
        --dns-secondary "$DNS_SECONDARY"
}



ensure_update_signing_key ()
{
    ensure_hub_layout
    install -d -m 0700 "$SECRETS_DIR" "$RELEASE_DIR"

    if [[ ! -s "$UPDATE_SIGNING_KEY" || ! -s "$UPDATE_PUBLIC_KEY" ]]; then
        command -v openssl >/dev/null 2>&1 || die 'openssl is required for signed Client updates.'
        rm -f -- "$UPDATE_SIGNING_KEY" "$UPDATE_PUBLIC_KEY" "$UPDATE_PUBLIC_KEY_B64_FILE"
        openssl genpkey -algorithm ED25519 -out "$UPDATE_SIGNING_KEY" >/dev/null 2>&1 || \
            die 'Could not generate Client update signing key.'
        openssl pkey -in "$UPDATE_SIGNING_KEY" -pubout -out "$UPDATE_PUBLIC_KEY" >/dev/null 2>&1 || \
            die 'Could not derive Client update public key.'
        chmod 0600 "$UPDATE_SIGNING_KEY"
        chmod 0644 "$UPDATE_PUBLIC_KEY"
    fi

    base64 -w0 "$UPDATE_PUBLIC_KEY" > "$UPDATE_PUBLIC_KEY_B64_FILE"
    chmod 0644 "$UPDATE_PUBLIC_KEY_B64_FILE"
}

validate_ingress_release_payload ()
{
    local source="$1" tmp marker end out
    [[ -f "$source" ]] || return 1
    bash -n "$source" || return 1

    grep -q 'readonly CONTROL_PROTOCOL_VERSION="1"' "$source" || {
        warn 'Client release does not declare CONTROL protocol 1.'
        return 1
    }
    grep -q 'readonly PROFILE_TOKEN_VERSION="1"' "$source" || {
        warn 'Client release does not declare managed enrollment token v8.'
        return 1
    }
    grep -q 'DFR_INGRESS_MANAGEMENT_FOUNDATION' "$source" || {
        warn 'Client release is missing the current managed-control foundation.'
        return 1
    }

    tmp=$(mktemp -d /tmp/dfr-ingress-release-preflight.XXXXXX)
    trap 'rm -rf -- "$tmp"' RETURN

    # Generated Python must compile before the release is even eligible to be
    # signed.  bash -n cannot see syntax errors inside a generated heredoc.
    awk '/^    cat > "\$CONTROL_AGENT" <<'\''PY_DFR_CONTROL_AGENT'\''$/{p=1;next} /^PY_DFR_CONTROL_AGENT$/{if(p)exit} p{print}' "$source" > "$tmp/control-agent.py"
    [[ -s "$tmp/control-agent.py" ]] || return 1
    python3 -m py_compile "$tmp/control-agent.py" || return 1

    # Validate the safety-critical generated shell helpers independently.
    while IFS='|' read -r marker end out; do
        awk -v marker="$marker" -v end="$end" '
            index($0, "cat > \"$" marker "\"") && index($0, end) {p=1; next}
            $0==end {if(p) exit}
            p {print}
        ' "$source" > "$tmp/$out"
        [[ -s "$tmp/$out" ]] || return 1
        bash -n "$tmp/$out" || return 1
    done <<'EOF_DFR_RELEASE_HELPERS'
CONTROL_TX_HELPER|EOF_DFR_CONFIG_TX|config-transaction.sh
CONTROL_TX_WATCHDOG|EOF_DFR_CONFIG_WATCHDOG|config-watchdog.sh
CONTROL_BOOT_RECOVERY|EOF_DFR_CONFIG_BOOT_RECOVERY|config-boot-recovery.sh
UPDATE_HELPER|EOF_DFR_MANAGED_UPDATE|managed-update.sh
UPDATE_ROLLBACK_HELPER|EOF_DFR_UPDATE_ROLLBACK|update-rollback.sh
UPDATE_WATCHDOG|EOF_DFR_UPDATE_WATCHDOG|update-watchdog.sh
USER_CONTROL|EOF_DFR_USER_CONTROL|user-control.sh
EOF_DFR_RELEASE_HELPERS

    rm -rf -- "$tmp"
    trap - RETURN
    return 0
}

extract_bundled_ingress_release ()
{
    local output="$1" actual declared
    [[ -n "$output" ]] || return 64
    cat <<'DFR_BUNDLED_INGRESS_HEX' | tr -d '\n' | python3 -c 'import binascii,sys; sys.stdout.buffer.write(binascii.unhexlify(sys.stdin.read().encode()))' | gzip -d > "$output"
1f8b08000000000002ffecbddb761b39b228f8aeaf80d372a5683ba98bedba48a6bb6989b239964835495595c7e5e24e9129298fa9249b49ca564b3c6b9ecefb
ac997fd9effb53f6974c44e092001299a4ecaa3e3d6bb57bef123313080402814020101178f860739e4e37cfe264334aaed959985eae3d6407d3f0629cb0c3e9
3c9eb14e340a6f5833b9984669ca0276321d0fe783593c4e827476338ad841741687099b8ee7b3280008d19035df35ae77369b276934607192cec2d1289a02e0
eec9c1afc1513c8892340a9ac32899c5e77134dd656f4e8e8267d5ad603c0d46e18ccaee8f2737d3f8e272c636f62b6c676be77b561fc5d3e81f217b73199e9f
87d3786d2d8d662c6844f3319bc493e83c8c476bf3ab30fdc4b67ef8610d8074e60983c6d904a09e8fa7576c70190d3ea5ec2c82a7880da651388b930b361a5f
a44fd910c00f66e3691cc1c3780a85c3e4023f9fc7a328ad02bcde659cb2ab793a63d3e82a8c01f88ccd2e23361b4fd8f89c7ea683693c99b174cce6c9641a5f
43d50b20c93c8da629d41a44f175c44280751da7f119d02f9a4ea12d2453140e114ac826d1f42a4e53a431102986ea5740fcf02262e7d3f115142022b131940b
7124aa6b51381dddf409d44685ddae31f8179fb30f1f5830633bece3c73d442ea1f7f80f304b66e7ccff6debd9b30fdb7bcfb6af3e343a9d76e723bdd8ba628f
d2df129f79eb8f3df6eabb1daa178dd22807405473953f8fd7166b12b32ff14c21a6210b35b63dfe124ac0d3edce6eb0bdf0b026e0bfb1c11aa7cd03f6a0c6b6
58a5a275e2e0b0d33f6d9d749a3f378f1a6f1a07fde3f641a37613a56b0a4d779164bc0688c1c00fc7c9e8c65d686d0d0937659bd16cb0394e8369348a80b181
8cecee8e653d62de7e9824e3198b392fdf1007886101be496f6050af7673709089707ca10890609e203621f042d543a64d2fa3d18818153832c5f7b5eefef6d6
4fdb6be9783e1d443638a214200cc46b1eec060b0fc9e50d695a7ae6d0eba89f26e97c32194f67c05e7994d76f4f3a8d5eef7dbf553f6eec061cf43cf9948c3f
278b45d5252304b8544a04a42ff408a89d91bb7e7242106b5e1e806716fbb9d1e936dbad9a77bd53ddae6e79e6989d74da07a7fbbd7ef3a0e60d0954708ea090
280628bdf051b3d5a8bf81c6412425c370344ea260783e25aabf8d4693cd6b98a4309f5808c201210404e22a9ac1f8cc4236185f5d41c594c17f6098c6f3d190
7d1e4f3fb1e83a4ac4dc0450c338bc48c6e92c1ef0b1dc1c8c9319480b98b29f2f2300cd893c443e40ee39010edfae32906fa36c4e872380a41a0460f0711afd
7d0e320a04002037927496d02ea149906ca3f1e7eada00d90c18627b37b88a9239f044cc3940f4f02eb8bc0b02406e7287ffa9b05db6b747051e57d41ce76cf5
800543b6399d279ba221f1372f546c0eb3ba897323849503e45f9cc077fed9c94aa2a3a9ec5bd5538d003bc99f80719486031c3d9887e3241e2051f2d066d328
aab2fa64328212b472011303d773512d46730622958d10391ca26ac640fbedd661f34dffa0d9a97934f34ad94d943e04695203fa6795178e7a55608c73adf251
f3356fc7ac08cbb356e8b4d5ecb94a09526925bbefbbfbbda382b283d9482bda6974db4730e35c85611cc623e01b1d72631fa443d7093a825575966a858febad
3a4ad64ea37e709ca30a7f5b053687f54dc7bed9eaf6ea474780d37efbe4fd0ac44c2ff571386a42bd63681b04042939a331b0c7668aba4ee9089e76b1c982ea
4b6bf7daef1a2d35fc1a9d169b93308645f322988d3f454975f6654672c7c1af8216b0cadf805255658d7070c992f00a5e0d4631ac34ec3244ae85da71328c26
5182cb0f1b86d1d53879ca7e6eee3741ff187c8a664fd9e9c109f07f98a4289a9fb25f0f3bc75009b487f3105612e47c8e4ed683b7ed6eaf5fc2c628666cc605
72355a6e7ee018ebfcf0f6f475ff75b3e52a7c393f0b4c6eeffe526f2113f316fa9d76bb27a661fa394c8089cb87a3dbebb45b6f10880bc26c3a4e2e104e75b8
6456f3ba34f57a8de393a37a8fe822e7a28b1f03def3bf5641f3bb069dd7986d478d7ab7d1efeebf6d1cd7fbfba79d0e80af79db79415256040959f61d963d1c
c095ca70be556baeab08aedbfde3faaf35efd98ee3f349bbd3eb1f37a1f2ce16fc2b2c81005efc04ff8a4a1c363b5dc0f2f98bad2d171ac8c2b0ecf75f030501
517753bdd356ab7104f0da4758a60aff07ffdbdcfe9ee6dcf17c866a9510fa38097003c0cec723583c61ad9a5ec142721427f32f5cf5e7eb1df0fc35aa79e324
adea1c06bc205687eb10e4447c56ce4bafebfbef4e4f24f7abea8b4dd878c06e231c99a2b379d8e8f6d444cc2a2f36414cc4e7114cc6597aad93008a80bced73
c84a1265ed4cc2c127902f01f5de9ec9cd935efdf551a3dbef9cb67a4d1870dea2dd36ac9b48c1b40a7ac12cbe8aaad7cf0d20dfaf08e57b1bccf7f9f5ab1c06
5fca1400931647ed37fad08c2fca87068b4b8289aa80a4dcc056a1be5178ff9d284dda112c109f5ccb12be27aeeb92d2391d92fcbde05a1ec36585b314e3e2a8
0be20859ed3cbe988b32a03f7d9ec6b319e8987c8b3aba0170b3318b41791928cd47dbbeee39f573a1ee88ad2becc2616118c5ff88865583e620e00e3475c7d4
fa1ca259d04097c9e2afcd5c9a34eeb44f1577e685f14f3f05cbb5250d5a1b0457a779d028445b072fe47175b8045636759cedaca2d0090ed6bbc9d975d52ef2
fa5283521829c56eb11a1ca5ded99074bd4f6a7a76e583b7fb27fb07a64ac015e1cbc16430cc4990d61b80daedeb7ab3b9cac7dc98e4a82359aadb3eedec1382
79688b22eeb28148099bd720564161bfde6ab79afbf5231d0b0df4ca681cd73bef1a9d42285587e650825dc68b4b6894f17b017e8a97570514c8cd589e494964
b44f1a9d7a0fd4873e8a6b98df7d507fdbad832e68042f1c72a3a4fcb65efee4f4f55173bfdf3ce91fb5db28f773c57155cf781d54345c7c481701f5c0f50574
909d17fa9753543e3a8d435969cbfd11ea3d333f1e340eeba7473da970ec370f3a52e1409d63f39961b81085850a033ace4ee1d7c39a373c9f6e993a9051e4b8
770a4d3ddf72b570d0ea02ca4de03dd8396d57e97f05c53815a9e08f55fa9fa3a0e40cb7b9c5c1b0b262a3b45e5454adf98e2b835c0d74f5b055eff59614d93f
edf6dac76525a1e7adc67ecfc1803a116c386e2d375fcaa9e9d69b1d20a643df460d617e868bf459340d607b46e638d0d1e6299b4cc7b3f1603c021575cafe3e
1fcf426eb4e0e527a42570754e9b66a7afbbfb1dd0e77086815edc6befb78fdc1abe2498598528f6eca71f7f0226757c592face51520019c70d26ea1d67ed0a9
bf69b782c3ce69b317c06ea8fe3ed04b6e82d42ec37e51d482a68c1b2aaf4ea8a2bafb75d826513d274494840e7dd9eae021f4f12da98fdc9463360d5c7f0e0c
7f598a0236899bb68c15b7b8a1e0b0a3a6215fc68f713d3b6c9fc2ecc5ea68066bb7608138dadc469d11da185cd23e875a9a5d4ec7f38b4b32c345c9607a3341
cb2f190426e1ecb2ca580fbfd08c045093f9d9284e2fa3940da314344b612223931f13f39dc136229941d1d1287dcaae41991c42116e509b46dc181ccf4c5b1a
e2b7223baad28a139f796be6cb7557592fdf601163a065763a1e396a007d71afac8da4281b50a75d6d343a3f37712175d902f4ba0e8b80848182a8b30204dceb
4c8b7150fa5d66a020154c2fb3286abeb432957056edd45bddfa3ef171a6f399c4271ac2c626208b5448a788a903166cadeaa25a011ce75c54a8fcda7fdb383a
e14a973e7c56d3eeaabfd47bfb6f0fda6f5c9561004667b07d0e3e87b3c1e5d0d80f4a10af41c10449b08ffad57b1790b3f118077530be8ea637cb002ce32ac2
4ac02ae12b27ccd28176d6d007fef4e40087a36866cd27240b9c15dee00a28aad860686cf1d4355f1374b09f9bedd36e71d5c934ba8ec77347abc2f8953195b3
dd3c4f89620e7e1256da8077345f05887884860a575d5e47b153beb29309ad5a2e26b4db2ee31e0b9c837b0aa039f9a6a0ac8363843effaef13e672217eb8a44
2d1aeebc78b1fd5315d6a29c819eb3a9491fe8419097e854be7b7ad086b546eec2e7c371344d9d66df4c995d5bc30350d4f53687d135f0c7104dd3f80e74c5ec
e5780eab417cce6e59f4251ab0672fe9c36c76c39ebf923ff7d882edf0a704564bede0cc68e27cb8f9cc53afb356e0fd732f3bd916ed7cb7052d7cb74d27ace2
a49005d7ec1c2d4e2c6b0c1afe6edb3eb8eef013b6a13c62d4cea47705848df92c1e0523348356aa9e3a64769e987bac5663c9d83c131496333c3f0caed8d60f
5b5b505dd8d53ccd4501c6902b37bd46a70582bfd50605a7d9c265e0dd6eb0c50fb4b7d977df31b2fd75df8a2deb87ad8f74dc0d4d7beb5b5efe4012dd439e64
3e0bbc5b41c28206fbe1050bc6848eb0e2790c3d600af1a86d93770c6fc85bff6b76208940fbd3416dfd2f46bb41d6eec686288398fef0a252c1aee883514fc6
80f7d465b453e7c13840e10899fa864de7490203a59d8a0aef09d18eb7a69d94cec6f3c1a5203c7594de0e2eafc643f6bd1a12fe053949b98d3c37099aad29a8
c8377ab5755f388bf8f9ef07f2ebb3edfc67d0611b2d5560275fe07de3e8a8fd8b2af12c5fe2f5d169437d7f9eff7e4cea5b5d1579912fb2ffbe9e21f17dfefb
2f6f9bbdac8d1f1c38b48f54371dbd3c681ecbafd84535797374f43c4132fac189433f0519e83775d8f38afa4965a847f48be3ce2b2296f40b11f2f818afd139
3c88d83e4eff71d217b23f651b15b676cb38e3808e09b28d6dbf90e7f083d9489c32a2a81c8743f6ea95ce3f4ad20ce388f9f2f87f180fe9fc5f54c1fd833ce1
9c27f12cadfadcf30084c574d6ff723ebdea93f70b7c97a0849b0dca76104711fb1ccf2e113584651e692a600ae12811673db601b808f9d9741ee91821920a23
07185f33dc8b77fe52ccb33a1263244e3f039fa301eece40f74771a0f0701f16c4096dc5aa3e7a51a991967b366d848bb880eacd807e93597f06b2261a4109f8
435ab30e800ec5f9f9b2707be3f68a344cd964104e18fcff6c3e8dfa13e001f97b167d9931a0c1d9789e0cfb781a15cdd2da16a06dbdd913abc83908ea3a4707
6d22cd770d964417e359cc7bbc414aabcb8eb380352dfc125fcdaf2ad56ad5e3f010afdafac6d52704c836675713a712f029aafe4affaa58a1b227d72b6da19d
0d26c339c078c5ccb5d65a85389164efcfe311b0ea9ee564e3ad7393915c4afdc13c9d8daf7cb7938d09abe691e7cffa4903f41c652ca54df87c3861b80d67eb
ca2ce5654d1b0e7df782bb910196963af264cb3757d1da3b8fb3df52b804411a5f24e1a8066bee31906163a3602cd913f6bc52493d45f5e01496f218aaa031bc
7988abb289bfc782cff01287cfcb8d11fb4ee7cddafa830cb574144513b6bd97777ad46bf862daca4e715d83ffce2604305a514f8b99d663e26801eaa0a7548c
a7d44130b88c47203e693e521f2a4a4ac19c03fd23432488f67417d044a30de0eed0943ea17b99552847324336e2bfcf21691d46ad1dbd5aae862e039036722c
9304fd2de560b96054322039d9b1be117efe8433721221db5a1c5bf5988f7e325f36d6b79e32ec9747052bec3679f264c11aad03764bfeac2c79b2b5f0d9cb97
2fb55e21aa9ed6ba2da6eed538cc9f6f6a5cc85ddb0b174522c74752785751a9f6289538d7a497ae4d419c3c56bfb479abb724211808aa920b6b4d35a7c8f48a
05e772908530b6c06633c77382828505089e4d8f519cce025c6d4a58062601ac7cc0647f678d2e1e0035bb6f1b0782d050d743755c96905e67fa777b57311f0c
702125aaa334dc7fdb3c3a60dd7a4a7ea3518a3e0d683a1dcaa59d2b6d40af846d9924d9d8102b26c8fced9de788b9f6e2f933be57f81c424ddf5ef750b00c71
98aba46e5021cf2e843ef1500ad50e0979fd96ff58c81531bd1c7feec382d7c7c238a8c36806bf526b3ceec336a2b7dba849a0796a3ae46a14d958fa5ca88d40
9358bbd5f4082c51438770608be83cfe02bf77386f5d7d1ac653164ca03d65b0f18cdd4ddeeb857f97e3eafdbe7ecba12eb81b57e3d766b7874ab7bb32925d0e
998622ecb340af1cd6bc64ec096756fe9b6b99fc83e4ba4c071d842827b17f9ebd31b7984b357083b633c5720a529c06c287360860071f657035f302222f912b
8623505e0648f54c41121bcb6cee9a14957399931be92b3a25a674d150d9f07ea977fb6850feb9e100c9bbf715101b2d3c027662c93b5a021398192d65f38954
98f1e024cdd8b898d31ddb86ec289fea0ac0d2090c395df3aff18acab83c6a56286c38b91496cf7c815c2a32eed432a361461bb1d1b089e3a05c41bb85ae185f
89288626a1b944e1fa55508649fa8d102ea37034bba47ddd1f08491c05b9e090ad5373ea29682cefe053022e4953584c0697c5000df72be13c3efc9ae2d5e1f2
0ad2bd8b3f06aabe72f22a267036b732de5525f29bdc707a11f1e5694f7b9d86d7281b4d9f44721a5dbfe555169e5243a4c7665f0484d00a4b856c1d030af361
a751ef53bc423fbdb91ac5c927d24aa055cfb1332455f490f9bfcd7cdaa14aa4452bcc5fdf41632a7f44f1677898926ebc7e6bbc5b5461876c298357d705c572
00cd7a520114e8176f444d65495798e4df2504725355b62fbf1a10351d231b4b3e94a2a4d4355c5d143bad28838e3a5970a43de7365d5a8b0ef6d9808fe8f49f
41d0f7d203d06a420df82a1ca82f89b0eca55132fb6da6346f0188163f570f9de17fe1d93da1f0a0c0790c1b87e915ce34980ba3f95592daca20bce6eb03fec0
ade2643ea3df867e023496a8fcb8e5f3d02532a760498fd5fe27fbfdc356f0d3c727eb22788fa0fdb865a907beac2190c3f909fdea7f8e87a0373b3063f445c7
cfd1a5ca1e2f065f37b054f01c4318373638d497ecd9f742bda742cfbe7720459f2456d3f928ca217319e2a61303bdf0288483e26194f08835329a70600ea248
2ced9e57748c409c1002fea3c71a6accf7f7e87d6dfd16ff6c6eb2cd75446ab1677505bf524f86e7d33eb4046bd8309adafd99c53380c53bc43d3665afa8d04a
98fabf258c3d4a1fa5dccd88919b112337237a8d1feff81ffc1fe75c6e29f7e8171ad2f1971686c83f90c19eff3c681ee7de4908d409e32b4e0771a467aaa636
1202ec861cee75ffb7f9ce8badad8ce29562c040dcb534825566160f84020a7c37ce11993e655ca3ac483888f4f7f7df179cb7791821bd532184f8afddc258ca
3be5c2593fbae3aafa5dfde77af30855ec3ba169dff9e247201cf9fd3b6d1b7ea736dc771854d3eddd75dfb7f6e169bf7d7c02a011d0db46fda8f7f6fd9d38c3
07c078ca0c6500600b94452a7bd4e835eebaa7fbfba039dec1a0350f9b04856c6c581660b73bf0834c33d4f409d210e0fd5c3f6a1edcc1601ff12ac7c7cd5e8f
5706406fb00bf2589b61b8da7bffeea40eadb4dfddd53bc7f0999a6d1c601f700b443841c1fdb7d8ef4a811d858f371df77832f812ff510b77f5d35e9bfe730c
44d8bf03517a0a343e694277a03d7263c53f885caf0e38f6ee404bae77dedf1d378e5f373a77fb6f1bfbef100f3a74573f3282e3abe3e69b0eff888e1eadfd26
bd85cf1d7a4923cabfe32e08d078d368e1801314586780b277e4f783f314fade7a87b4e27fb3d1ae1ffcdcecb601b5a32610164a9cb6e42f608d839376b3d563
029576cbbff3b922cae420fa7707ed5f5a47edfa0162426fdf137a3060f403c6f1a4dec97ed168cbf230b6f56ef918f0e9ae0d0179e0dd1d3400a5032277fbe4
04fe1e34bb193f754fbb27803db251fdb40b7f7ea9378954f816fffeedb4718ae560240e4e915b0f1a1a417fa977884d7cc1dcec9766ef2d136fbb40043e5cc0
0d7f3b05421fd01bc2477b75daca665ba7d1eb10350e1a87b0b743e2365b180f457b29180560e91612f8cec708b676072876f49e357edd3f3a3d20f87c52517c
92780270f21119dec611386ebf4113118fc9013c3edff9c8b5014e376023ff8e43a5e09d3bd9f0fbf2f1e0e79ec688b40f0f49e01c4277b1bd66b78b7da5e403
778d5f4f9a7cd07f6e2307bec6037be2514d889cb69418e9c040c16e12b0ee12c3f2bf19c366b39d37076f5aed1e234f4bf8fdb7d376af0e847b0be3de535fb3
a6705cd4ec278c8981a958c08194f71ffa62741ef88e4bd2664b0859bfd58079c0ba203b44f352268a472e051093772d6c1b08df7b7fd73c0084602f8d00e0bf
ec7d03068840c93ee0c43bed08308cb7c66032747a5de3d52fedce3bfe826b9d5dd12eccbf76471065b3eedf0577fe92ced282a775f67179713ad9561528fc7b
a12d7ab4dcc5ff88fa69747185bea9d6cac7639fe2e442ac7ea05ccc2713504306613224ef55617becf3d7225148788ef93628529651131ac833dad0c9ea35df
e76fe2e1975ab0cd7f8fa204cf37875fb266f09d06e41fd1740cc8cf931926a8501a9b42976b6d5b1b1f3eeca6937010ed7efc78b75e41f50df447ad3226c020
3de9123600eaec4703839b90e15891987a89aa9b2c21577eda35db3ddbd3bbb6a7f52ddba68d7552c609fbcd184db7e861054290b9a40ecbcd3f66cf3fbbd19c
e06439e9ca72739ed96bbe0dd5b17431536ada35ac29c6f2538cd9538ce9538c65b39699b38d9932c0d5b090084c171d4c936bcc16832ca7b7317b6967c612c3
8c1584e596710b2b4de560facaca74b1cd340dd338bdd15402a65402a63401263501ab510db2b67832b548337d9166da4fa55030a976b04c91624a91b29a93ca
1793ba04536a03cb3a2c29c4a41ecb84a66b4193b324c35b8c90766aa5b457a6b4572615badc00d072c9c472c9c432cad44ac9a42ac1a472c1941661d355a89b
4c683f8c6b3f4c28458ceb484c68525cc1928bba98711644b1c4335ae219df1b30be379033846f42f8f464a87530a53033ae3033ae3033ae225b2d702d9a712d
9a71f5594c132636124c69f64c6c0f98505d995262995aeb2df8723a32b14d616a73c0e46684a9cd08139b11469b11e12a7bc094c2cda4c2cd94c2cdf86c645c
3767a4e832a96c4b81c9a4b6c3f8f456ca0493ca04536a1cd3d43866aa714c53e398502a1829150c950a9bed33fd87695a0f4d5a465b2646921d079eb5df31a5
17321270a43a309253c662a596455ab5c84fe6319e448be5c67bac6c3cdcd9ca5224b2651d163cfafbe891517d6154c0556efdf6a15e6f6179cb686b3916552f
cc725c87a0e593f408f8657cdfd840cde015dbe2d620515ca0b80bdf82eddded85a3ca131305f69201121c510e8a37a7417a6254b0a13e643d4c8826b359c5a0
f24ce6c96036e747c9e8d3154e673c4519cf1ac213a2a1d73de6f8b080a1f132a57421e9263f0b4ad17e8aa94be8f02e48c6c3e829a3e3f2a81a7d09af2623f4
bfbf7a6a013a1f8ffbbc0aa565db4ca7d79bf2f092922ec5c965348d675ac01c296969d5661dd28638813dee4f2c1f40bdfa500ffecfade0a77e7577f3afc147
a15b3979494222fa0a40e2f7bde0508633a952c1f06d21f7f29fea2dbca1c1066657ef109e31f2af942e5631b2a4996c6868733ae76b7add3afc47d3ecd6f30a
ab2311d3709c446b859d9218d9f640a594427bc0779ff674901a083533ccfa99cebabbb52b0b2fb2b36ee2505db555857665f732f6277e41cf1297f50cb944a7
9d976d51481c65fa37c924d0c1d5a02354b9cb592b13457a1f72be817a0562b18ddfef3efc2ed8ec636503442c6ceb2afaeee08950218ede57fea2bf5e2ff228
24439fd54fdde2f7af69f9cbac2b391b606694735803bfc1d8e730f169c645c3a4c84d79c25a57601eabe4289cf163813144ed7c1d53319b23f83f71ae319e92
551a27846e3cd67c93e4aed8355d9e98d38526bb73cf3d8a9328bfe14e67d95e5beecacfe369ead8aca25048f9247aecb33be63fb6f7ab0200e199ce1e3de2a5
16e67c24e8fa54d44e89b0bc06adc86ce0ad8b5f7ae239c439196b544b25220f39ba1a81ee874c19224412710294ceafaec2e94dff2cba8893a2a3936d2f33f0
f363a0af3d3f912ca49f8d888883158f39340754718850988a149bfcc0dbfc681887bc42b1cc41d2818880ee3a99c92165f92f65bd2d3e84f9effff7ff5af504
461ba62966669bf6afc3d13c3731e8a57672f7294e8662c4c2f96c8c877730f0053386575ebfa5bf9b9bc0479bfff59f8b3d39dbe8b55732b7feeb3f57985a58
6891fb0c288a9f0fb39f8f1e7d78902d328f17de0216f57c8d475ae5878ff52a58e31e93f8bffe539bc562ed4202e656acabf92c1a561c52510db29ce7fa905a
b2361c60ae2437147954b80218d210f2e25e2ef20a82d3d207bdd78bd498bff5da77bd65afb3a0817bf67b8fcef82d354b9643edccee11df28cc6eee26235833
ee3052a35250ddaefab8b292f4d5ab594b1e97c67b961806a6b5a4b05c81a88027b9dbc1af7ac147b242019bde83458bd873396bf209eb66a85578b2acbe8319
25230a3951c8854a8e642ca8bd5a95ff6ce49ccc47856cce5b81eb3870e35461f91a6b1f2ae8827cfcd996dfa3f02c1af1d55689f21d53943f53a29c7b7c5015
e1534275c46fd29b2c95a8689dded3a1d47676747f921f76f83e492fb1fd63b660f495370afd08b472c136774dd1d17ac9b67fe400f5da3ac0dc0aa42d39cdc3
6e8d221531b0837a089c2275017cce9d4548feb3a79563bb62784f048fd1a7c3602ead67eab170d1decbab76398734ad41688e1a33daf0fdbc9a6169e6457a81
a4861411266a9992e26801651c0cd3cb0d3b8c822b003028e7e3110c40ca23a1b461842d2ce770cc0e0dec3dca798a6819a493688e99021786f89a8cd3184d32
95155c1a06300de2715259e5a4770853713a1fb841db27a349781d5f846ed84a51d5caa39767658523c87217014d4010f962cc0e6a89874fd10d170e524eec80
4237e6ae4dcf749266c789d206e118159050f0e055f2ae432f843f9388ca117bbd0febd0fe47cb3f49cc0287be9a91b17f3e1ecf74af2ca38f6f98dfe245235f
a37dbee06be6bf0652fb44f0fce7bf31bff1259ef9fa6093f3127934cb3054c065da1f86e9e5d918b366e63c72b370118dc603b403c257416790200bb11ddad3
dd9c36321f7d19f750d9335212880d05ae69dcf6e8176c5d78a02e9b8469aa8b1a5e7f59fc8f6c4da2cd1b04ac97b486913a7a6bdc6d2bcbd09f6f78db6c5807
c62387960213807670a406f170da27d36e7e5cf09be6273db9995d8e93672cc06ec2278fbd7ce99fbcf7d7e22b8a158d27e1704849a7c48bf4265d5b9b4d6f76
a97a12cd28c57e2d2b588d277df17a030a57c3e9c5f587ed8f684a9ec68359ad87b15f6bd197413499b19f51e835e8ae893065f07237ebffc6b947c74bbbb7f0
7e21a6d7348c41f275c9a11cb97463bb424911448b557947c0831a7b8ee668f99e1be9d01a0b5f9e6de9cd88567a3c7453f688ee1139c3fcc3ac7972fd9c6d3e
db92dfca50e154af310c7ddb908dd3cb8d4a658d37285f63d8575f2126bf9e7bb754fec3d6c7c5e66d0e7f248455707b494109ce7cde86e793f76bc42fa3284c
fae15998e09a35ec8bd4207d6e7e87193f9b4f32a1c36f1d404f6d3d264168d82a2acb8af3177765b02000a6d50ea456099f58bdb88cde29ada0858a9417b422
53b4c2d4f52ce396e7fc2472ec78e58de8713aaeb430182a69267cd849b50864e1d54c21c8f1a7c870bba7064a6166e393e22539ae2c0c05b585ccb91a5f477d
6415bd5dc18a649d498df688d1e613a3b4c836c1534ba84c11a9caacd0062d0a26f2157afac8cc146656093c50c2cb3e3095c35924b01ab2343c8f4637559fe3
fa90d565b86576bf086694619cbdaf80543283cb65781dc9505d7173074f3fc53ab024022202623c932e48c36814d10917e6bcc073380c2b43e078bb055e3704
f3627a8305c4dc52e92010cbaa6e8d3bcfc77de4169b2947a32f92858ba552a7b45e4a86cda4b9128589434a784687acadd3a531740e00945083e728ee9b3932
6089e34903c83aaad7c4e428869f3408141ed3b026dd9bf84bc3b5c98ad533be1407b399009c817c4545ccf03db39416d8647f58399aef3e15ede8bafbd4d563
eaee53cf1549f7b5f579fc5c997c7510339f3051eec8aced2c450011cb78eeadac08d15adf40c140d14b3c448a57b1625d28aa3def0f21a36e28115696bcd9db
7c2c0e2279e0531028c0f60695ac6572ed059cedc8417ec66de0982be2c255e0e4cc3fee19c8e5c0e9d3528bae72a7d7764930003b159d7664ded64ebfae300c
2b9bc35aa270e7001882426f45a37c3e505dc69e699ce9b958f3b1126eab9425e65dfb5a419bd5c168b0592056afa22a428f9bf6d301ac394622a02c63987e50
cf935ffd1ff4e7ad69bf3080927096d6117d271d4ac9bdb766e68b83b9d790b9df646223c5018ea325b4dbec805ac337ca967be4beca6d647ff2f01ab4ecf693
dd00eff08986226ff5c232d694372c0f98acc6bb30daa08046c97032864a790c327bae9959a4d89e756f02f4e40541f9d637d4e5417dd8accb44c6957bb5c882
5705edd28628df28a537e74960b19fcecf440cfc5a80487ebf2db5b40e66b74858c8b369c50350da78064c64af193a34a59721a965d1087dc0e145742d66d943
50da46239e76238d875926e4abf15028594534f73be351e467ccab76d7560f4a61682375bfb1c9c8a1261c65fae0ea91bce20bb6f4e34ffabcd6b25df1a2ceac
4026ad570a30d7cd1f0fb86477944261f280afa1aeaf3999af324e5eb1adef9f3fd7502d41c2b4c5888de74acd892b2cb31c6f9caa925467d1209cc3067efd36
0f6d216fc5c3bbfc2ee6a3704a570d55971a6e00cb07cc18361ab4bed8fe0e2d1431f30805e3ba3af4f2a5df681ff6c5a78356d7a7db91c416e8ecc69190b2ea
beb20c1839cd2fe1fc24404e11804f73897bee55d79231719b9e9fc0c4664d1bd7f331c9694ee0a1a4f06ccc6041ba8ef24dcfd1c2eec254e487adaaf45d6bcb
770b22c3986106db3226d2d0955e4feeb51c1c8dafed8bd62c038718f70d9e596c2ecc97fc065013e65e762459b030b28ac2769a3355532e2e750f2b7f378cce
c3f968260eb5c88aaaef8be6e7989ec7fff07e33f9e86b1f401c7dce1c5cf9bbde31e6b1ddca7014b0b394b1481305f266b32540663678907ebb74e642d9a650
89a5d20ed70ee3d48963c35e8a42cd16691d268ee269fd96ff78b4eeff361527c8d6a7a74f17ba2efa0ff4f9a40f0ec190eb273fc9b2a6b6ce805443c2c30afc
60557fc341a0997c8d8c01515fdec2c5ed20fdb31bcaaec2c39e72e92bcea4739028c3ede578f6a4e7b308428ae6de2b3bc9334eed08717e82054806f5df98ed
869d49342c06f4c43f9b9bbf799b0b5dd871f8a27d917d8be06a85e0cb87ad8f353f38d0326b492aa0068a7ba133ee9444e1e81ffefa71b12c939d3a4573020a
ba566e319152ea90ebfc82985eb63b5ba8e1c19d529fb263458ee38bf81c1da433df384c9109126a92464399fa521e97f2a2b60154ac0713463b324ce205d3f6
5a2bbe7ca9569529fd93ac370469be8466b222ef69599bdf313dbf22e7a88d0dd15120fb0b3c7836b7cd0f783ac2007313e7720a3ab6d0220de10ae907cb738b
e4923ff2a3603e24eb19d24f189e962bdee1bf38ca22b7e312548c4678c577cda3a3e5156191c7b1595a8e9fe860c6d84fd114cf1c640e5e60d7098d183727c2
ea363ed7ee0315c348e9e240457e018c01b3789856591de88617179015934ca0227f382cc1b429e4979f936d2c8966c41cd9fde48eac70628ee024a5130ab4f1
e627097e5153445be7f0bd2b938539b842ff80d9fa9c4b156894402a082667696cb8bb6738bb0e01d701aad924d2fb7802fa39bcd1f115adc0be20927391cada
d20333f4f8ad4eadb6cd6ed19cb811d7b6f7e297b5d6e15efce44985dce7d7e35acdbb8e43af227343ae6fc44fb661a2609eefc5c277a0940de29f8914d45905
291a3c589eae9f3be49e44543b23e4780663264ef80c6926cb7b2c1d004bb18bd1f82c1c9575219d8ce2d9c6faf3a7e1536fd3ab082f0a16e239968e26dd7133
28c0f34c78f18828e1e9480b6c458f6815e9cb236fb7b84b95b5960ea05e3f9c5ea4b50dece0390bd22e9d504da6e32f37cc7fec6362576e7f08e4f9cb337877
157ea167dcf62fb9ff4c9e5cabf8167223111108b2fd27804090f1882825a558341861eacaa0cec667687ee25752d636c477640924008804ff72369ba4bb9b9b
e124aec693f8fca63a9e5ef8d97b32aac6936a7815fe639c849f538ce8d1be23b1ab3190f232fc0714b33e9e738dba7a1541417fcfb6a966e12beb1b98ae3f98
33acdae7d4144f69f6f8b6d73bc1cb867e7d2f9fbad963fde8287bc0132655add5ce3e2463f11e49896a852229d72dbc7578b665318862bcf5c057de73be238d
adbc2f89f39f1e8fe3d69ef4a1f9a017ff888b13ec328b0be02d0ab86cb1fcba958bd8862e3e30206137f323414c5fd6e662cf0c09a21a325289bb1fba4295ce
b817a6169cb4968f62e28d6b134e5fc6b3be69dee767e4e12742be2408d0ee2e22b653ec93cedd7fa8ee324f0e636d2bde9edbfbc369a1ad21bf15241197a502
36e8421e7635b6be65bc4de7671b9b9a0fe7e387d5c79b4f99e73da50a39ffcf0d02f3e07fb2cddff55a7ca76e39836e5660a1ff32cbb7e7a8aabf296cff826a
3fc5efcc598073508d71f18edf9f32849e3e657a279f6c9ad5f88206f5b6f758cc5ed684a066b4b2ddbafcb13708ea87f8239d5ee8b7a256001ae8f308cca898
f9c967bf28b5332d8e1bbcd25fd816db05dd5194f10b522f2203c5e145324e67f120edd3d5d4c6eaa459c5e591b7b4c98b196064d8f265ee04d0c5c911a52bef
48e046ef3ec57130bf13a14bb17eb300aa917172c12f742363572aaafe8f31f06538220f81b9eb6416b39d27783942f06c8b5d81209ba14f13ae7cc124bc00ac
60b187457e3a0b40a575efb01a31f3f989c41db58de990dede81309e8cd37074278cb49fa29b3b3cfa869df2553cbb9b27eadabb3bb19e62980de6334641f0e3
96f314a28c1ef29e27d9b35589b2cc13c35dc4f6087197d21d4cdc255c3e2b056332915d5a7578be8698fbf3e914a9a9ae1b4aaec5cdd7be26dc367ffbd06d74
31dfda6f1f376fcfe6e7e79852dd5b30f99bff0131c7808d297bfaad90d5dea3148406ffbef0ad8b3d5cdcc5fcdf3e6cf004423841ee44c395df3eea0cf3fd56
e1b1953e49f1feb5eb38fa6c28dfe7c58e4cd67aa383c28dc928beb89c2d5b7196ce7b7e9049f9014ebbfa2d23baf4b0c6e92df10d136771a2927940279c60d1
9b98e282e36bee1e324f9d108f3059357970f87bced477e8c04a03d6fcb90192f0a8dd31b3e9d17bde8992332f77181dad670244a751ef6222bfd51cacf78c8c
8f53951c1d6f2a01bd24d49fa548809f988b1e53a9939b0fc6a73827033af4f08b1c24854b1c5f970912dff45532eea03131a73c94da0bdd92518641f9a537f7
6c48a4f00fcf816bc2f44fcad19f0dc14d94ee153bec5252fd4d95c11f93de68cd6f664df986363b2169d994679178fb483000f53af805b4c9fc016569c67737
5ec25714af8af02d8878623241ab4c5906dd9cb3b009d1d7d649df0e535b7524756194cf0e6b349e23736bac5d429bc2961f6d5194273ef5f528a55571b11daa
f11cc4ed1d9005349a737214e3fa84539beec3f5f357f428a6a20be9ca835344eff9c1d5c978140f6e9858db31af95c892037a2850072d67e25a97ecf288d4df
5b02559ed3c9c3db0cee1ef728941f447c37682cd74039c790e7618b65e06a9cc4b3b106d92f6139e3c683fc3d052b283be80c84b6aafe1c3842b368fd54a5ff
e53d03b2f95790f4223fb1ecb1f0049af27a640911d8954e00d83af7c7a3207e6b339a23819bf973c32ffb3bc6a1414288633d6ea8a31bbc44ccc15e0ebcb9f6
c094305ed8d3d3366f8b7152e7fd53e4c0aba83ffeb432016db66302066d67b26be7d1e963ddb85f5ebd39acf3fc0a5f47cde2f6fddc29b038639fa7d27136bb
404d55c763f73f8bcef79c0f9a5abff27074643fc2c96474434131be0a59b92781f93d334e889e1132538e7b658f7522f494a20b31121ee28337817b79322bd5
09a312e5ce6a35e2f22d4e9f5ce0fa71da0fa7781fce2ade9e2b13d716835258e00e869adb231b085bdf3090c1777d7e5ab4123e15efab062a87ddb231ca37bc
8727f030d698ed69c8fb8297cb52b8de1ec3e8d52bd8a40d98bc621a8a4443bc5a3e08312ae0e20f1c51de3f2eff792ffd93694c1e81e839426bb2296228ec52
5b029681ebd261960ba092518520edfb0772b682743e9af94a07b1359557591a2487ab9cb5f3280955f68d4c899b59ae3ebf605b039b2c75679cc06623ad5465
b8a086a36b4365302275cb9482ae6ee5b77832f9216ef484161a6344059d7ae01c021465dc05c20f7068a0483a475ce551a39029d57cba7619456a443b1a88ba
fa56a4c3685c5bd4bd7c179d094cb5fea2c0984dc3f373984bd43b3c6e51e7a3e148d000559e244c322b5336564b3b2cb12eea6bb960b17b92e1fe542a2e4fb3
3513bb23c48edd1307ba2220b874ebee920ad99cb3cd2de8f3f88d4651e1db8f4651caa8889954dd76d1aebc1b177b2d228f5449be5dc6fc00f7dca63b202cd9
66df7f83538a9cad7c433f47115fde26a6c2bab72a48dd2ce954235686948fd0b3573bdd3a9653669513ba5b55d234d682c80499c9c3d03c3bab6b9ce8ffc09d
23f4eb8ed54ead742d513ebec470da5e544f42b0f35cf9046b6e91b3af700fbe1f53b9afabe5b7d52ecdd520b07e94ee4a67f8bcfb7bb9c37b768ded7271529a
c4e19b3191f7deae80882ed31c6a4943b4a83412bb3152490c1f54cd511356c6c1ac1f4fd01d41dcd5cc1fd250337c65c5d6371cce0fd925baf9636aed105541
f1561f6a584836ae40378ae5261777045192ced30a91fd8060f2259fa3c49a2726f1b566bf7dd08b9b5ca683912dd99f27ca8ab2cb37ec01b9f8c1788c3fcd27
4cdda42e5dae429849917f2fab73ce29cd6532fd33cca61490a698a880552c1b4c9e632cae51000bb8e66b39471a34dd4ca3b5ba92e2b14c3592cc936ff52bf8
8623f7e7308ecd3ca5a6616eedcbf7c94f3fc59309ac28dc4289e65b74ddcfaeb6f55752d3e45196965646d3cb4aceac04aff2b4fa86d32cda03a5fb9de24b61
3694de6d3cc987cfd3778a050e1dce1443e79de614174be0f9c2b2d5aca86adf3d55b282067a50b8c42f4f3fa9bc24a7e8846d9bb19f995b3079c5715711d167
95a0dd5fb3920ef19c91b0a71663e2ab24257649d4c9fc9351383b1f4faf7c1e04d74046e3317007d1591c260b71a730bf78d10da389e4058d59d37a111ae1bd
1bb480c739d5a221e6161269bd9c900e047dc4181018f13b0788a74673826993b712b0b562f5ebe7044b0ddb6e709a4d544ce29680667a06ccf709542272f7da
90e457753c33ec91b7af2583e399debcd28e112ff0b4c63aafec06c7b00fe64d1b04b274c66377da02ce0494f740cd456c3775c16824d3f1684466063ce500a9
95a6beed4725780e7a4b8f620cbc1572e3c813163c9ac06838ca8380be3921a631d806c54b35cf938bfbe5074bdc0666026d89d42a99e0e1f6aa708629d4f088
496453c81a13cde839410dd9a851852f43a871639af408101fa8c85186177283aadfe07af3dbf999d0de53b4e8c366759c44dca1933a2b7b68094cb1e3fab69d
2d9e57e0e1d27768e62a70f511ed208ad216963a37980f4af6027962156e218d5d8a209518ba71822934f6d69c6bee8f6a9723278a9229525bdee01346460f8b
b3a24ad15aeff6a59097b9a62567d4160deb2360fc34202f4e83800e159f6b9c0a775f9d68e5557b476d5c7de5b60433188de629c52aafb25370803ba2bee2b0
cbc05769065507330e401497b144d90491f7e03eea66ce888a017a3a294b8f53e9784e3b4c0d486b1221a086ea826c2ecf9e352da6bc11be422099887aa9d1d2
40b833e58e58056f8be805f31c39df480b0deea1083df73bf384756778c5c2263f3941d9823684348a086af425442e821e09c366d55fc6d836d3f2d939cd51da
c1277c38f8b6d85fe90c766db91d7f1513fe32d3fd6a567babe74dc517523461cc9cec3dbde2c12857e10c1ac55c6e9dd3a346df4016c6c242df338e87dd7627
fd18039b20a9259312519bc24d29d760a5c012e580187d9990024439f5305f132e4af6816ce189f6120268945624d0dead4204f3f0653532644d1411c209b598
14c659f4d710a377da6a358efaddf66907f36ed1ed238e19b19c1c7c72c973ffa5d430dbad141a28f3401531c46b13d9523a6891a3fd2c4e347b766d6438308b
029603667e5ba3457665e0c9b228f4e0c71879a47c33bcc7bac66d2460949a8da353167017059754bfcdeaef06435d736757524d2f3a1ee4cbc4783a54e65fe5
87fafbc6984cb3e91d5d994302b7e2bb12ec1864c450443fddfc7d93b1cd7c7295bcaa6cc3f30da3444e17158786dfa48a72b6e5472c8787cd7db7369a3f232b
f13b2d389cf9df7720934388fbb2e91eafab68979a294ff741f48bb527b733a3f0a5333d19fd959df4b2eaa84ce50d3e9a9f9d42377392bc0fb20de5fe37b80c
791e18df76b75c82b00b84a103fa8ea4a7626bf16c4b6d2d9aca0a449121d194a27e3668db2cdea8ed45a665141da4b87d4377d037f4d97d7d431dba4444ca26
b96ec6a37876b3cc3b74090997c393e64801d72bd52f25f70f31c7cec8dc52f25b40709f90db490ae3de27b1e80d2ee3d190ff8c13fe1784acb60649175fb10a
714ebcda2e9c390e2375d68601c0c9cbae539124579744b91e871427dad31278b27fa500a1d0ea1075a3cd27b9e8e532f3e354f8810cdb30fb57b465a3094f40
7cc8d862658f7a3d1bba865d3612a5f8d1066e750c33a85f8da3225fa2b0d3b39b09d4a4106971a18191a1626064bd425b846c400e7e790b5037d784aa5959ea
bee3549ee75398f20c24cb7810f3204e12a149448bbd2640b9766004978bec47eb8f656b5fe299887f4cd2fedfe7d1f4a68f0a725f689eb9086bfe1ecde7fcd2
22527c785a92e118b7d32289b77635209a772925ca9e91a26543864eff80c72717144c7e865343b600dadb5ff1ee196c81acb8bc018fd5d913ac5b7b067fa771
94d6b6d9130a7c72c7971f8ad87711f4eee735587e31a04a0c938fe234634b454991d6a528696d1a5fc03606534b59b97b6215482f452e8b877d7e5135fce037
0cf06c394cee04faf13053b7853d17332980eeb641d9146e9f2f2a5642051eed2892f4c0a8bcae77dff63b8de37a6fff2d46d57bc5b94808feabc24c24db2202
9d90173b8a611198c274984a1741729160c4fc3b04d3cb35262944f7fde14ea4817a74f5717c0ea4d1e5edc687dfb5a74af5f1e66fdb9b931cf86c43639dcf88
763c172d5550812a4437ae7cc1110883f37a70a85fd6a70613bd2a6515e951198ddcc0b2d4180e20db5b0fd7f380d228e356290a35bec18a322122d76ef04ad8
6e03fd3b011ee78f4a45632fd122e840d1dfe15983e5896c463ad373954b5d39a9e55fb6f89e7b08e2a72c8a9dbf4bd8667a936e0e4620d4369368b6096cfdd8
7e87ed3cb6d31851123a04e215263012c788b758eae1c3c77a02237b366d40bb7236dd617b7c34d4c4ca03b72ff1e0c0b41c45b0e543c114fccc82b94db9a21c
d72e795198dc897fb5c9923b6acca3be82e0d28f8e96f614b331adc417159b0ef3c4685fd5f957a484765dd41f4489fb643f77d143e42f97f9a7541a93ac9aca
0972154e307202736569406d740b1ad7f28af07679de89ac004f3af115f4e7998f3a98a05d5c073c2a4aeacec449f4424fbae84adda50f9820d0b62b8dc61fdc
1510ea250beaf2a042a19f75572101e5899f6126aa09a6024e6655dba3c4e8b73bddc6c686cc7f5fabb12d562196741c3edbac277153735772183da06fc52ac9
fcc5596b900e99ff1474e7c0d2cd14740b60b1c4580a52dbc408184b0ec2b921ce38ac0772c7c37938e2771a0b300bb6f1190743bb6b401c5cd355029565fabd
19a965b7430afe1e8ff8452b392e90687ca355d177c553521715a156ea641bbe4f73fe08d84705077a898685f1e7048300a8c3e28285abf190225256ec68415b
7c23233d43ccad8cc600d47e3fbdb9a2a9e65034c42543f055cb906eaa0a866a8725f584eeb268a1f62aeedac2c21e971f4612f78a3adb637b7b2c7bdcc64779
19154fabaaa6070502890ea96dd743743ee8777b9de67e4f1c01d4bbdde69bd671a3d513254e2971ea7f6046c060fe1f4f617a0bebcf79348d30322164d7e134
26fb78cc0f3b534c19f71f44afff10507846297ef232bb0c67b8c584051083c070eb34816d0f7eba0c279308de0ae6e685c82bc3bae749a4c9175b4639a1c5fd
4ff25c8212e9e3f651cf958abb95d356b387b45c6c22f7c1be2d4b25c793ed5349f7764da5141e5256e11f5ebc401ed632b32350def6a2fa394c66d2f0364a40
709c271af825f514727c3853cccf2c7c2f946b3b2eb9a933437aa6733b9cb88d7b73b284ba9de86c1e8f86b8504a192c9c32a4b91bc5823ae31e46e731208856
826a55bae7703c25db8dc21bd88673ad6a1acfb20f3819ae229da2fd341a9d03f2931bad38a60719275c12535fb56f99355e16cb95e097d648aa695f141df9f9
4eaea6fc8e960b4e63711ba0f9590b4b28043107daf5d1072c4db5323c3baf0c3210d747ec06c97861dd196f02e3e4c319a1c152f7f4bc488bd3febf3233a0f0
3df7ad500a7ce1b6a71977a9961eac2038015932950921b7b38c90fe9eb6535c682c6bb2829110c59e4adba6a42b98705b94c0e3b5bc57414e662fbbeca4a4f2
b61ee3515c6e0b1be936f63b8d5e77693175b1033ca0bbcce989c2e7f47577bfd33c4107ccbe56ce79b9880e46dd2782a148f57daa2ffb7b7280050ba0655fdf
345b6fac3a279dc6cfcdf629ef913644c2375adea294f93b2ebbcb4da64349409b1bcc52a522a837688a3381ab4feafa37ddb056716754b76e4a5bbfc59a0b86
21a81855cb1345a0d89225f88d755ef1665aa151648b45e3a6b77f391ea7b8c481fa41ebdd4cc64e6a97b3553d5d9358e3281b94bbe056684a2ea41948d5ed15
b40a377ac037a7cd3e8ef6cf0d5b142cbbfbcf3fe41e403ec12f5092a8ff1f088d8f8f52965d704ef7681ad1838fddf7a423cf3812fdd00ac4c401d0ccf8e2b7
da3dc627f569078f5130d5c754a65ed7d2aa539a03714e27fd989c19d35d995d7347d1ea881556a98b299aaee526f69e31f8c61131894ccd5dcdec6ab7d73e39
691c8883645947e6f5a796f20e5af4b8588e9ae3ec79456cb4046ef7c0c5b1d554e797ae5cd025981cd69b478a2cd95e1390115e124ba852703cfe27b81f9a78
1bb1d5c8b6f811dded36b9f3a099a626df09ebb0b93847d0f6d273e025143631cd8ec131b98f1c74715ebb9cdcdf96b3052fd193330eb36488df7ac4ffd7e674
5909b623f873856a3c965d7e70c579e7482e82d87572cf54303b570c6ff6d0cd3b77976016d38ee9b7a10428fbe4982e43da7d77b4fd833f36c545718f34071c
74a3c3886ed521470e0819f97d19a625e923aa65b9826c5cda278d0e05fbd461674d3e09c604298a41cfa1a4a15ef58a4294cef15a1a3c2b965a76788e2e1eca
e1496cae5274c5e51b69652ab95718b5f4e6d713b219860271bba550c6e52d3c43f342cbf2bb7aa0a80884501754d2459be282147250243e44446c0fb02aeb65
a9a7549228421e5329ce18a627a58cef205447386b5dd1cc622758bc91722139e55b4f99359ef3576e9f5982a0b3d5dcfe6c59d3bc4220d9e73e2d7ffd2e8c23
54b20573e65928dc884981b61abf1a31fa5d8bf29253f39781ba842cef474f47986c35d330e1ecb33c1f93cd4bfc122447e44fd656648b5f17e3bad84af69a87
0449d1ab47ff700a0aa12be8dea774d1d1f9391ebde91353bf0708b866d83f9f4691f05a9fb97753f43a3b2fd8d8e0b7b2747adcc5b47fdc6cedf1422fb597f5
5fc5cb274fc4d1aa7d5d86d6284c055c69d5fd252551dadc014114735c915166ead7b35d6b9d979739386e0527daea7da71735f26e867dea21ef3cbd7ca9bfad
ff1aec88f74f6acf8a08a06e9150dda71ae2ba25c767d1fe13d0089617da8142a584fc2d91ffef674d5b8d58e0be81e06b6b97f3b37e76f794ebce29d7e55258
970c7faecd6ab375d8fee3f7aa2296663a26f9bcc26615d130f7aaaf8f4e1b2b6f56e5422003f3aee3d94d7f16a5df9a2da6d13a087aed00537af760f7511056
274c6651320c66e300fe301d0f4678d82ec1cc9d4756dc5da5a2d8b30c0ecb3649dfb8df7df015bbd23f7c6756e6ea2bf2e672776533b2eb6a9ed2f191e6b6ac
aecf563a38e78601ec8e61357304506d972767c9546515cd67b8fe1a2e6fda5ec6daf12d75f4d5d2b512dc423fdf5ce6cad59cff96c287b55a4b125bd48a3c1b
96591297e4662da250b6fddbaed2ff96fbbaab3850ae4b70ec88a7813704948c4899ca21b406d1beb870664507f9d236c9ce85cdc1da417ab74462b5b6ef43c9
af4ce7e2cce362c7d17091edcc912282e579928dc5faad82b3c097249e1785393b3c065b08505dadd89425cdf95c35c62c465176a326681cd104e42b85606a39
58b41c1a29a5cf90a7bedf96d464c5642672cdd4cad0edd77694eed2acc17a885821f1552b3af165b81a329ba62058b98dc450ac9823446605bd3f36dc8a9ef2
d9a0a1a382993500269134283964574d32b934357561c7fca2942c240e339edee38240da4df8cac2b7236837b91cc3e634b412b12ec3bc60dd21f842e0ccb235
887b34b356bd97ad42ca29daed86ed30b81921a7cb4350b4e0d3318f7d060a6e220e560a60bea2c2804b37e7d542525686af32e5086549d2c796b45fb7567d1d
1db598d5a59434a357dd7dcd4256bf8e9af76be3cfa5a814a2b77ab201ba5ecd254b97d2df26bd4a5f505949bef23c08eaf26f2db05c02ca915c86f7f3858f9c
83bc7b49d115dab486a0b4c5fb8ac295b3d7aa81444fbe9c6d7cb52ca9665ed1937ab79b4f8fda51d7488a5ca34ac5124235408e0d805785744de783012cebd1
70b5b4a8f74f122750d5f39f4a9c9e8a552200edf82bd05b350daa9ebccb9dd4c144178fdb10dd47c3ec564e6d0b8a88611a5dee9ae9c02b7f185c9636573744
68bbedec60573f22d6b6ba2374a9a44b1345a62a91d68bbf5edf402b5299234470454a1fe8873b0c6f4754bfe9c25282c96d8cc1ec66020a380b9455a1f757f6
6882fd36b36b71677ae88b0ae0d8869f8339bc1cfae8ed79be13987e7a9a08e378f3444853ed3927c8e609bad291f7867008e0ce1907fd7a4f157ac860af3a1a
714921ae8aab75f7b7b77ecaee7353624f34957d207aa273193682e254b7690adf429ee90b146755eda4d338a9c3d857143b75f761db7e4ab18f7b190bd64f4e
8edec37ccdcac937b9624d1ddacf8d4ef3108bb1fdf6f171b36794e647c45961fe6c1479ac21f6beb5af7d952e8fca498a5b6a716b29c3740b3de45cde0c22b6
e94ce548ed4fa373807ca9db7ed78c5b69c7e4fbaef4589569554b2c25d2b01b70e9aa75ffb455ff19fa8bd65d1f36e0d3783c945ff4787ccd6ecca3e21d8558
0a1b78576d79cf3d7dcaf2338b92be699845728467b0b8cf53b2c5a3028b8aed283e8f2867d57c426713783134fd984ffad430bd113fc9b689ae39139040a9ee
bf39a1500531ed9b07d86bf10e84279ea8a35490a52e43ed897c6b4c7479b69c3edd9d0d05c5a39429b222cca149e672221fd784f4a4d1ab515e3b1ecbc413db
e18140340c22e22a318be4105369dca2345a0727ed66abb71bd87b96dd609e7c4a80200b51577145ad2817ef9e5ee656fdde641b22a32edab89ea07a1ff47edb
6c744f2a9b0b8196c9661838276683fda9b2a60e8874561cc04e06861d46d33ef8cef8012d8c7a1d9d5550de9cbeee0b9973da7ad76affd25a78d9d58b737e6b
b60100130a86b3fed9cd8c52aa1084d32ec8c2d7ef7b8d2ede52aa01507c5806052df68398441c41c398c426aa1712e469eba809d2a771a083968cbd0a7e47cd
c306deb8ebc4914f8c95ba7972d4aebb3b2aa7d52a600e80ca8580e4b4ac89c2c7f55f65bbc7af4f4c62ec6973572faf1ac8d53043dd645b64e350a5843d4921
023269145fc5e87e8f4ba98ea0fcbd60c76793d4829ee1e684afa16eb560762a7bb25be1d2aa80e274156ec6e09d5e17166ba235f39b5757d130c6dc1e19dd85
cc5b015ae3d79326a85919b85684d9b53250f9e5026a6af36e8139298178297689c4353dabb9b2c8a64dd6597d8de1e0a0ef0bba8fe756e0ae0dafb1da78fffd
bffe6f6c8ff89c1affeffff5ff304e59f54aad13ebb7f2a7064f5ba2bcacb21c1682c89b10af94faa2eb5cd3ccab75ffb4d369b47a5cf4146a5cbadbac7c0095
04af7854dfded6775e7c2f9f4839fb3a8dcc8998362bb5f50fa31134cc76035c0f71365a2b62564e208d7add9ebe4a6a90a81f4601be706645a873b66aa891f6
36e795bcd8544a03bffab688d04249c72554fee644170fc78d6eb7fea6f175945d012f5549d70ca0a68617278da12a64059c5ab3a946d4b2cc5cfa602a2d03a5
61f6dacb9ec5686a6f60e484c03655136d0177eda65415a5d37111aa634973491c4142ef4e4e24eb88aee158ff03530e647492ceb5967e08a0b54242e4e8e4d3
16fcb5823cc3c74a295797895a77793af3e1eeab8caa3c2f2fd7d5040a5a6df1c6567640a4d25f276c99cad0c37a5cad136094e6559e3eb8278e1e018061fbdb
0dfe22a4a97e82866f97a435ee6ad29e3c076ce95fd69d1392ea584d93efc25aee465f24d7c2230a4dc69755e9a24426cc94102f2b2e230e05a30ac77bc5b365
bdd9d7b95e7aec67f343af2a19d9e45ac9cb36e0a330d53640bea35e1eb22e458be09e52992cb5b09fabc7e16a1b558d5be13f73db4432b81cc783480b49cf8e
4ca4879b11479ccba55e9c4ffd8e355a20468f30d00fd3b1b5df355abe96cc28bf75e05d2d4ad5aa6545e67221cda041ebd8bb3ee864576cdb28dbe5a6a1ef98
4c3de3b3249a03338edcb577646db6c93a7c4fce7a94dc047d88e49dd2bacc988cd3184f5cdcf09ea1ad937b3266957822f356f4996998522bb08b0ec99735e7
a962e70d2aa2532bbc8e2fc435d7884aa29e413b1ccfa2a9968f0a071f960110795793191af7b827290b13c6f303ee32bf928be4d36c3c1c8461e4c17fdb1556
b0379ca7d2e7854df05c553ce95618fcb753917e7a02405fc6df48b654577fb374144513b6557d61037956914ea47ddb49679cac50ffe2ee4dd68f8bd1f82c1c
69d4b44b9fddbdbedb32e2668dcf7fbffbdbdd4f3f5578caa2dcd7c71561ad6f263cbb73ca5d7ac9a75961f8cc40916c52d2654b9ff37954ff99b3be55ffb9f9
06f41bbf8841df8cd96c5c3c77d5843da06c3778942c17f36513f720cb25b9a4f0b36ce1e88ecf679fd189fb3b2634bf25759f1bf2e53b396fed3adf306fdded
1e2b6faf6378070daa0aeef2af99ff9a326de3b98fbbc8dfa02b5ff0ae4d4c5b8b5766ea62ac583c68496ebf5d400cc5309be2219b9e4bc48402a3e511a5952e
2f0c1c0af58ae2e8b9539eb99ab9ba3b2e9601ff3a222247ad7f9e843868d6dfb4dadd5e73bf9b570732bc96a903fa5c2f9425e202b7950548839f6135d0c54f
77a3ec4578d7c3d2855e38b88148906aef32412293fff28b13ca8bbfd0ee05a426e4bd6ba5b5be47fd836e07391a5fa479f5c228fc03ca033a54e844c3907238
677446ff75677b7f8602c2324e60d771f4f9ebe58cceea78748ad0ee2d5d1ccebd2b817866b6cf8f9c97ca1ac7fd1ce5755e9875e8aecaf21adf9b3546c01be5
157ea888c0176d8a7227b9f27aff7f55a2286c90bb22ffb32524ec984ef3a2317fe4b8563403db72b799feef57b3b8d491a58a30d6f65385b252de53d191f754
2c93c8283067e3c91299470292ae0ed73775a5ddfaa15c032cea6497bcdc0b3af823a281b179fa3691bc187b97712a8c6c4bbaf213f34f139940e2801cefd921
3adeb30e7718d6d5bc3f4f51ed605768e7bc848e6f14b068b93afb95ba6a6e2bcb65c7bfb29e7a3fc10ceb050f2213de72cbf7b52f2a14b0a956a3c282dfd306
1aa6465f5e3eb31cf80f2babca3f566434aaf0e435acd02ad78b550ba4ff5cf2380f7dbb9e14169ede752a46e8cd529f8bbdd5d3e6649e4350b2d5f358108c93
ec5ebf6f5b0871a5dbfaa72c74943c48467da3e7467671229f1aba0d5cb3c2e35451d0b560ea8ad3cd4d136a59ec7ad537ca02b6ea59468aaf024d040c6110a6
75f75a95c15298683a6c5ad6a496e1609566c7e7e718c65665a740a6fc254ae3e98aed8a2c1aab3489d37682b94b0a81092fa765b0389df8e4be1791ec5c2bee
965a63d077c8543130f0cf74a492261e2fc59ebb3951b490723fca03945c2f40677e8dc0fcc54e0f969ac79317c324d8a6d3f335235251e41936bc0560f6933d
5f7c73872a9e33cd8720e779691c461b0d19199629618703aee5cf9583bce08031bb7870cdf0dc5780f75f37de345b1a4c74ba4dd8ab1adbde32ff558c36bd47
d59d7376f2da7bca924dbba8e9025b00b29283d673405b0eaac21c88bdb1412d8153c9f11e87736cc029035271dde8cb81bccb805810cafe29104346f579d585
5fcacaca4fe9df2cfd352cfdfc0f65e9e7ff66e96f6369d8d292152b972c753acb7899cdc6a017e2f30ee76d8d2bf0ca870945c9c303d6a1b2052c32632f310a
81dd2a3cb7aa5b5b8f1e79fc1606b650a5bfd436269bb3cae36dbdf708e20b7b8910bed472ef5f2145f18ba3ce2bd0f640b7a4cad5ad6de590ecbdc44744203f
48581840f17aafd84f3f55d146222bbea2e77c4d7d0ce1eb53f665d910d0e1b345ff68321e5c6a0320e34c2829aa2e5a1e602a7e2c6cce7998f0ea3de6ebdf2a
162f3c79846cc02b9731846b30c7348a780d07b580ce6f4f80df1e9db147ef7d3b376e51333631322fd68c16c2e3fef4757fbfbeff169465f8cf719d5e9c74da
bdf63e6c12a4279878a99c8099f269b54029374066baf1d1e3df4edbbd3af7c864b6afa705c7f4df64a6032c7378b05af54d6f54e6f0f2644e4f4e0b8c8c4168
9cb4f7dfd21b008beefffc8d5a1ac839ccc86a4934cda53d5e5bc5b34b797539006a8bd1ad3d741421068be0b62bd97256c51e5c59cd6acf2ee62d85aab9884b
88b7b9d7a5400ce27228b9a5d6a4a59e5d66d936f93e9b44c71ef1cebdbdc3d1ff6213afd33804be7febb9720a2bff519118e9795a58db711d8ccaabe3d834e4
49b256e8979ea3c5760105f8a46dfcfab67edaede9b128f481a90f66940b2540b953913277ddd32ede0a0cbfb84cd0e070d9b5ed1504b518512056648bd13b1e
45380cd3cbb371381dda423f197f66e105a61c00b6c03bdb8d880e332a83fd7d0eeb6c3e9ca334ec430bf5d01ee729345af3033fabd857efd6b474242b051de4
fd074dd738835aae5a9a831fe5faf057d154e5fa0424c430535ca59e3c4a2b7b484f0ca724da0679f1c830de716303a98e6a4505177bacb2950550d2b71a7b21
2323b3e1a9f9c24f185d0ff9e9f790fd0fcc5c02adf9d9853e0ac64f5b0e209e03c8fa2dd458a480cad873c0c94b5d141120c378f86ff7eb5b4923bd0e0125b7
70f4bce3d58c5a7b8af07f44acc91fe6c9ff0779f1d3145b259443d31a1c612adf1c59f28744957c5310cf9f14c0f38704efe8a26df57019779d252133225c26
ab9b0f69a1d01813b8feac07afa8f09825f0f2e89a6f7230cb31a4a01e0d9e6d5f58092d11b9530246a51d2b9b2086f244b67fbb3894092e667cf7e6e6d00218
39eedb5ab8ef52d3c2dcf86251b64d263548c340a48ad73176c5bdf557876de15ddc4076575c9ec48bdc8839fbaa8dd95e7ef1b706544afa650bbc8850e602df
1d1ad0a51b95ad92251ee5877249a22da47cf096f8d20b8509bdf9c582e0ae714ab3c15713c75dea40b0bbafcd0ecfe074221b27bca41cdf87671f02c748d8d8
a4dc4d1fe5b5b797fbdc91a38465ac0031231942195c0a95e058adda0255b158c48cb3b1c0d447a3315ee241e34c2b69395d7970999f973d256396d531449eb3
c691586b7cba9e87ff262b84b870c4506ee990c5bea2c57d418ad8a1cce88cdfbd477af9d26fb40ffbae8ffedac3079bf374ba7916279b5172cdce6073b04657
f634a2f9984de24984391cd6e65761fa896dfdf0c3da1a3f26aa514ad67c1a40c72b8aae5ae37ae241b353dbbc0ea79ba3f8cc555ba703af525bbf5555179b59
7a86b59376a7d73f681cd64f8f7ab5673ffdf8d3ce9adc91d7b6d7a07727ed56b751f30e3af537ed5670d8396df6824ee3a8fe3ed049b1495b70aa86567369aa
e0bd94db5371236db15d627b4dd924444dc24f2cee9acd005eee06eb3aeeb2d5c4690dc0b410898a13520141b92fcd43cd7820d02dcdc49fdf388b5a6b32f79c
761beeb3943803f3ce73697c394ec595498c62cee9b2240c889f8d076334d53ee38f223efeb990105fa2017bf6f295478dcf0613203e42c21b8c44d05486876e
4e5e36868fd2df7e4b04ed6af400ff876b97c448fc4674a0efdf3d2bbaae913298befcee99e1e4a56caaa9804a17259b71c6fcd66590b1b087af6d0b1de50cc0
7eca8ee77dd6cfe5ebf78817e8afe042f15bb18171dd57451fa8f3788a194f6ee5803d7ab48eee3e8f176b84127d166626391d2c0e599343a4655391fb207fcb
573b19fccdb723be5ad5fd35b1b3c08f6a8f800fa4ebe38f4c6fd7aa656a371459bb0abff4e713e33bbe4278c64bb169e45825f41764a77b00d5e09923f3b8f6
d8ba22910a7d8a6e6a186e9c00fd6a8ff91180b8dc96de3e7c5c5be87620286fa53fa1b1aa68ec2e8ea934730ded382b2ac38ab300df535624fd5da5b2fd6245
8d8dab9ca68d55c4c0b98ae91bbe8adc28ba0a9adbba4a36dc4ea84a3dad70567015b2f4cc8ac62baee2e6f6ab92f190abb0b5fdaa30c16445658d6d5725e33f
37c9347b7745b1a573b05a0715e255fb2319e7f8a5ac78ffb39cbe7c1dd0e414cff968880263f6526968c0b0698b6f76b69e150c8e77394326bf249043545704
ae61c41cbf0f9c6e18e4eceaf13b9949cdcd54595d59954aa5ae00a948c7a1674edac27364d13d92a716225ccb33f452ba4f13c75efe426c0a9ab2cec657c461
cd79b397d258bcb5d915321ed761165578aaaeaf7b42a5536989ac738adaa3bfa3dbe676ae907de4200a6a8b87ab8ae21f555cb258ae34c929558c738fab1097
557a41e4815cc94c5ea9a2c65e482fabc92c555853dcf5a2badc5265f5dd935ed8945daab8b98932a02bf995c14e2347414b86a9d2d6be48af62ca315523db11
d8152c59a66a08b6769637e4995183d8df414e4da669f4e4133357dcb060abe299d51bb635ec95b70eaceead0d2eafc643b6f53dcd0a7a73758d79e583403ccb
c9e2ad15ed51c4168703e297f839f739b9a39dd24c0bd6d987cae5b04d6ab4963c63875e0ce38b8834dedb67f41c0e66f37024134a15a646e309cb80b677c2fe
6d9e8c6969e05482073221a9275a02b40c0ce23b4727934d61705e0f0e3fde7eff7cb1ae32c9ed1f35fb8840bd7550902a5824bbc09eac6fa497e1ce8bef61d3
6a573593dda1df857f4bfcc0d6b717be99d8aea077bc1181fc2dc7fee9537506ca3fd38b423c752e3caa63ee7c3f5726978e31e773449c0ecac7df4e71c5cb43
10d68452802b01b30095a6c11379eced447818668f92a8beff2e2bcb5f327c6914c6ec2f77be9f15140c5794098f9f290a8e2d4a872726903a31b42edd5ecda7
da3eddfdc372b97d5b06b77fa704fa774aa07fa704ca52023912efc8fb7bb31c2c26ea05d6751179efdb2b5796ed45bf0bdeea8c6484822c297924b831d984b2
c78f925705216cff7b45b6e4afc828e3488db43c9d8c56a93c53d27d33cc1c69e7e754309762a620b90c77c957025f9df8b865fe83b27b7cce799001cf1ea3af
96b62385d1909ca2727fc3cfd11ed4b4309dbc1bd6dd9db6f63e1060300204a7e4e969f3c0709c02c509d4a7e0e3edb3ef17ebeebad4cebbc67ba31e54120a57
be4e9623a74f1972fa6febddb705b50bc925bda9ca49254b67842d18ca7c425bf2f4b4077b86518f7d0c78990e51b14be507694a3556d07ba50fd56f0e292111
b79dea78d4fc134c298dda0c6a9bc69756bbd55027c741aadd59cdd3a9c2b02990596f2c88fa870ce0122eac9573a1635c4d02d63c517933df829571cd4acd6f
c1714cace2d3529ef5280b74a53db935546ec1bea44e794a2e3d175b69b2dc2579ceccfb4738b8d5b3e996e56473a41cdb58396a309b85e85876e0ebaec707cd
2e7f595942236c568daeaf9d5e642b4d71c6342d90aa79e03b855e324ea26504e6ec216e62a575429f6e651d1069cc682ef1cc706a5295673033236f33b7cb5c
e43d79a3c4d13d02d1eca4ddb9707d77a87e269b8420284f6b66dfec4524bc0c93e1088fb1ad44fb5a88395136a5ab66616402f29404d46878c2514a5703e0c7
24226744ce03c0a174cbac267aabce18efacc97632baa1bb1fb22a6a84f9cda09cf503c1fa8a43a8f5294648e3d515b4608c6e96b5764af7de27d167de3f4ab0
36c360f714f51a6dc06663811006550a6f64758fa7406595c65c89d85083a4bb460885b3688497cd618ba1b84b8892c8716192a1946fcdd80dc789db79f68f4a
0c9fcf0bcf236a4bb2c2df2b0ff99e80a72dd27698b09948bc20d9f8d7adfc5f91a0bc600913f9b2cc55656942d0134e25ddfcfded6b8d75d95479d2cf2cb70f
e5cde40fa57936559a50234b28f91499c7c8e51d211eb4895422cabf7ea5e7a999b016672a8faefdceb3bfe58a6e4859b7d9c9c873e54eda902d1dab89794e08
4c96d2e8d59b475ddf42439fefee345bdf704d44766f67fc49d9c1f460755f5efb2d3fd67b3dc01a96733fbb4739ff49de369cfbe2baed53aab94b6edd0405e7
1e776e6afdd1e16d66757d6baf77cf9b46ed9bd2013d7e7131483391e2e71c17849faaf43fd7055beaee49eb7e6a93e29d46fde0bd81aceb026b6cde1a0fada2
14ae5078da8fd37e38bd72dfa7ad5d395ea5d208d81ecdce3152af402e6a49bdbe215372d91292cf9e5c260c50a46ff25b5511b2e28bb23aab8a3cc244793395
8a3f918d8d4ee6f4f12d43a32306941fe7e9835b5e6b80b9c86ee4b0d1b19b3e828622cc939d80220bf202802443c75dd764abeccbd5fd356c91fbddf66967bf
f161eb23591e757b1a9a83b41ae2b65cb2c11aaf733b5352aaf7c3046f0b93e7d9d9a5ea575cd1e628ca8b33e95e48913e868b75ba524c5df63ae4d91bac9bdb
acb3f2172fe8e0309e92c9cb3c7692375b1b8400c023890a3dec69f180f402a41bb64e7e6ff29cd1e8fcce2b561220aa1715d79ee9cdb9a05b676526f4dcdd9f
aa0904276c087a0b8ed151479f2facd6b428e325843dedc2a4715197289cb0203d4fecae386a2dbb4e4c5c32145d8162039382fc1eb2eacafbc1620685b0314e
a0224938a2827e72ac3e3949f2d5e4b82f29e89636d8987a4dde623474cc995d6692c1d3a7bfbc7e7610e7b394c84bd8fa9370f00980a6b58d41180ca2e90cb6
6e03bcbc0ba7e0088dc8499ac2aee16676394e9ee10567f115d48f27b42ceec00fbcc61a8acb1fc1042de5e98c76a183c9707e35d16ee40ef03fb81a0f2e4378
17f0e51916ad2405f1394230f43798f0a4fcc37145c39ae7e50a471ad6a3f84c830edb8c69184c467358b45206df4433c67b1da2a45506b0c2aee2142f4336de
89df6b8549da60b2479370aa6539735c31cf81b02bd03145fc9f487b869d3d88ce62bcf03ba21c75e3298c5ab52a8c0de164165c44cad0feea15dd2cf9a68fab
a9475eb66b05f7a0ba9a140ddca8b764e0e0125734883b6bd167ee01759be3980f7ffdb8f00c6756bc0f1310a5004aee198c0914a874ce2b581cc5d8f47f52db
c8ea54f618b70d81e215a3dd42161366e3aca43895b147ce8626342df2aec21f1b1bebb70fed4ad8af5a0d2326854dc8a37c7a6a78600390469bd38c8ac331b0
3fae6f3027ae415dc86e38142037d20a4ed45c438f3fcad3bb1cb5739cfe2f48edfccda16d81b5ec0cbf1e83ff5e58e997f6a4ab2cf23e66b74767f07856f5f2
c3949f491d8bc2b8c00a3909e036c902758380617ced4e2325553d9861d27f9c8c20078dd7cd7aab7fd869b77ae86e9d808a95e5f534e6a25a09f020f5d6d58a
778f89eae8919f497e548f84590ded8f9a9057a7af21a20a220d34bec94d91ba477ef57a366ef2aecf96d5ec0af673b568ca933f9a0a962627585a99d6780d64
76fe4b6a91c6baad355fb26e73bf2e89c2ea4bb606dd2b2714a95aa584c2123cfee04fa2cb326d0211501a8450c5d57b4ab374a49e0aae7ad74a908b545ecbe4
1f9deaa5d0228bf45e40cded5565ea70f685b102b1730d75dd0ee0fffe90c91393b31b475ad2dfaabe136d17225766374beed705acf8d69976cefdf1e704ad40
3757d46f59dded4056dc4aa1a717710dacfe73e293d9585e3c012252320d0a9e0bae51d0066897ae2e4b3e2d2cf83a69ed4b9449eb34e61121e89a18991a9517
2642777cc8de61a648dca09d8b0cc6b049e5c3c4ab77a13a72352e8314c69541ad82184b5988e11423010d815499585afd9449e5b03e99d4a757b8280a633525
ad24ad14db16bbe62151e5294c2e012e6472b8280d6ebe7da0e898154497b1cfe3f90875ec4f91003786b6a69fe3340ae4a6931d1c7698e1e7022043d2d363fc
0cd04517aaff32a2779988d1e5254a1a5bd4e8df95c4315e96099ef282a513c160a86c268821c68eea0b8931b335016321f01572c680b044dcec168b9715267c
418fe5dc2fe8ae3ee5bf7ab17dfefc9b17dbbd3583830db201d51f3819427770915cce454f113562ae6ba31cb9988fc229099102f20c60ef09e24f5fb1f21c7d
cff6f9195fca454c7ef2595868725645d73ad50ef955d8e3b63dbd51f9562a22579f60feb26062ce64bb82521cb4e52957c65c26742c3c5771bd4369343a2fd5
3657352e26b68146ba99db2fad37e4ab252dff9dfe7efbe4bd4b1a19c6a0adbc31c886e0d284e414a3bc4ef00f07518de81cf64b791ae05b1ec7aa4f37930dbc
f5d356b387fea19beb589e7222bceff61ac707da4b6c9407816b4b34ee1d22875d970ac25e6a02db295189f2f68fe274a6dec7a9f48d40556d7a233ff007fe65
cfc8c547ecd16cbde934badd7ef7977a6bbf772486d44173f2fc63de715eb009175998c57201838220526637307b0ae0e76c83db96edb70cc7fd7aabdd6aeed7
8f749b7549a1a2be380583a50b189dca6cd58e9e650daed0b90786202b1a84b25e7d75970c6997d9ed3589f7f53d432fec27d15e76b6c999508b0dc710770156
e582eb638c53fbb42733422d524fe98d418070029aed413216a9fd838074c8d251c79d794543854f81dafa5f325403816a66d517015619eaf686dfd1cf6c167e
5b3f010efad424a9817a36af57433dc3c68d3aa5e6d2a50888dc2d9c47ba04c177dc5af640e8560d54ae3e7cd84d27a0e0ec7efcf858df5891b6bdeb8b435e1d
05fb92778d6e828b94a4fa7626e1c4bb276f64685854fef3c7b6687ced31b6c7598eb54e3d6f95b157e3af77f89fca0099a8f27b207af20abaeef2f539e48a21
0e2ec827b428c6dc512bc47c2df00a47441e1bba28e5333f0009eb142681e9bc550604065c1309e81ac9f84fb407ae08c3858864d8fba1a20ffb1f834bc69df7
264b36d4aba262ae1c2e0b873c27f31dec612e6b9a372767126e491d8d2ffa949b23af4a45d7d14853e1d2cbf87cb697c5a71d1c76faa7ad934ef3679835e8c5
7bdc3e6890c90c3a6786a7d9f2977d78947e6492323cc03568a6159a99d82cfe786c4f4c3df4743a1f4505784fa6d1b9ae79c2847cceb03c3f2630f55b95ed9a
57bac5bf8b5d8ff9ebdbd8137c643c269367b2e6d99e118df81c1d0cd18a1fe2695b0e8d5938bd887415586e0d8febade661a3db13567133b5ec5e9682fb90f9
bfcd7ccabe2d41f11f1ecb02176e0d7e49c36b4c06b8635bf636e803768843c016e364187dd9e0cf4f794de66d7a154a795061e7e37932ac6d2b480b3dfb02bb
a548fd0754887ff1733d2342c1ce89cbb03c7bc1e069d411b784f1835d6db3974511cf539efd664dd7e184f3c439bf922b9cf13c333cbfc8825f1b2cc4f4fa2d
ffb1c07daa68676142eb465855f2db820ea6b8475c5a650d71a12e5d0f3a9f70efe24fd1046d520c3779fbef4e4f28d6ad2aa1228d7828e83c2572c823a5581d
6d6864194e3e5d047f9fa3974bf00bb04acd87b593a32cb2d45aac9b5972e4266ffc8929d0eb3e6f51bb09496b0c9971c69e97ce535c3d4fc83dbc81874068b5
91f95daad52a77ebd8871e1f93af401fc33e7a2e6966a491e9b397a24093028a785661c4140f0751d1ee8b4d52e9d9849a12924fe8c41c267ad0d4ac1dc180ed
203177583677741ad28914b63d1ec5831b2e54aec219ec2ed312b922ae0fa250cd1d8f85c3e194b2aa027332f202a0bc4cdf227de095d686fc49efb3d6c42f9e
9f5f344b7f75f9a08b31535408a0e86757b3d3432314d7079c101b31bcdede633126ac6d1dc28f274f2a16702976d6636c5d3685368c8df58df8c9360919813f
f240fea5b7f96cc703adca4473dbd98a68c61b8dc79f30210902e46f383928f96fd604bdace89d34c12ef2d2534302a39d444d21240d0096982419b0c18bfd05
54c75d14ad426012e391db4476dfb65034440ebafce50de8b2ce257816ced0476b9888c49179131c666f7e1ec0e16bc7eee859861628a5f993076fbfd36ef75c
9b6accbc629fc34b6b37022b30738be9ea384ae395acbb05b2528545f2991144ae0839cfa9573c651c617d673c6d3eaee88641de04cfcab38aa95ae883687a24
255fb7cb23ac05b955de725cb238294fe5fac959eb238505b7160f730495888993f23c0ed24d901b88812b88696f144e0edf02e7f1888b157483e5b0802f04e6
aefde471bdf3aed171308723d118e26ab09836b81b67f057187c893a95dc158424dcc431145a732acebc15856c7b5f56e57e885c2396ac27e317336693e1c362
960a587b4ed48c031c89dc579cdce4d0151ddc9541dc1632c01cf6c5797461cb8bad9feef03f8390fe8c07e9847e84fc391cf0afd3d1dd647ef629bab903fde1
1a34fabb691ade458321fc77f26990fe48ffddde718f87e42bbdbf0f00a3247b89de7743d0b72ed9360b789a14f4649f5969542495aa0e82bbfaf7b8b2ac9431
618d08715e4feaf059524239c740d779b9213ae19c31469faec22f56fff4fc846b4b5a77882dba1e352fb5f655841fba29a27850f2694d3fd39f9ebb4dae947d
4b8f33b085c856e1c2b14bea618174d8930eb9df3fdf2a2ea5d62e6b0504798f7cc838ab32c9aa8cb32aff3360825519675526589501ab32625546acca38ab9a
b92a81356ace7e6dae9ba8786b7f969459b2c4fd318b5ad619662c697fc6e2a5b5b5faeae5e2397297a2268d4b3b754f334b99b2cd1be22d5d74606f3ff92650
25a9d23f7d8a69bb7afb7c37c0802cf3e35938bc403f91d178bab7a627b412460efd4a507484336523d5aef9ed7796d58ee0d570cb05acd86879853743a25ba2
13e4834288ef1b4747ed5f8a41e246db09f2d742909dc641313c746874c28b0be1edbfaf97f4f9b1135a5008ed97b74d3ded8ffb2ecc2c2c96b147291aaf1ea5
ec51b0f363ca78d69211eecebc756acdd80dc350f324e8b9505b99f434c634939a0ec3e31cf57c52f83fbed7a6aed3193ef263e1b65b5fc06400cf1d0543da69
aa24a0a2da57f3593474e322f6fdf740e5316ee740da60781f912cfe87b0e19523a2644ed1cddbae1b4bf9cce7d16b72fedb162831d74d7342666680ed7cf465
026288d2903ef78418e048099100029c9a90e18a9970cebc04d561923396ce51832773a4863d570a13dd75563198a2e19e2bb145560b6770612d7ec42f4e0e2d
818951cc442ded5d98a49fa3a9dc753e64af31977538998c30e8825c472ea32925ccef1dc34851643ac571e1b2f7143e0f46f321ae48f8cccf5905249ec87a76
830e723cdd148b6732521ec688a900d25484f10367cdcf31e1dd34c2a6e9545d00e3b795931f3157acbcdc4dd09ed88ae09109cf1d042a06de5a8c21fe881dc6
456a3da7fe88eb84cc39857472cc773ac936363a9c78ba3dac205fcd6fc9875fea9dd647d6cc9cb18176e8b230188dd368b807ab59784d2b3b1e5247c9bc5a78
3bbd71ff995851c530aedff21f98ed7aea2f1c7de3dfb9699773497f189d87f3d14adc228af2bb0e8b98a88cbc746eb0cb322a23fb12cc7f3ac107780502f9db
13cd3931fe24aa8b02bb81ec2d8f745243104fae9ff779bede9c90d3d20b481fcc6c10f6ec6b6ef7b4f4edfce27a4d0316b9bb37ac81279732d9863e2415e324
553ab112b62a09b0c35664f65d14731c8bb9bdab2914434defe609b4256c8aa8491234a9a3492511ff95c67ee44dc1fcb3a63d6a3e692ae99df4fe1fcf079798
49b8beffaefe46a410b4dc0ce4c9f1df1bccfb3d0b1aa97905f5721ea7f993053d60a584c6b509d006540491be5845d0bc2ac3d8e9e2a9c10ccfbe0a6476b889
c3228644ba3be7c7a284e642b0d0c4ad79c91856f204d790213d88f3cc92d878119817c8c65544bc61bfc73be544133751ea022b5abd3f5c856e06586713e6ff
0eca56fbe8e7c641ff977ab7cf7390d77c3785cbfc7655fa5307387940cb3bb9ca083aa189d44d0a9ce8db3278c2dd701a913fc1f07230190ccd348b3a33c830
eae09af1a2b9839efc41970c8214aa98c852bc7e0b5b7b7eedc7423bba4d84432815954697aceefa062852a04a48b1a8697825a1cb85804d44a537cdf68b54f6
ceaee688b5d24fd7b831a80fa2508b612c146c2253a6746045a2e48769619d6be7ebba3b23437011a1da46652fdfbcc81a695d25e2d77ccd46ac17d41729b1ad
5252274e9821a51c7cceee988b5fe1f5e33e39a8367e6d767bfa0ba3aef64ed4cc9b388d7b311ca98bf95ed3341ba924c2b51af3b944f56552b4fb497b4e6b2b
dc31277585c1d239909a3fdcfaed430e0f63fcf8c59a3429a75774c5149a1c157fcd2ec399cb7109b67e1771429abceac25f7c968c6d4fcd55c212b39ec8d8c4
c91c3654223231c3d53947cc0587cf110c1ed71cb69268f6793cfd44a7c3b94872143b322d111925f933b29d231349fc2972bd4ec2d9aca07820923839bef22f
54c8dd9a5600854771096cbf1c0695280002dd06a56bb8ecb31002eeee1b5378087b32d21379483d277cffeca62f890b2c89fe083cbf03bcc013c96575a011ad
82790aa6ad1d30d81cba1ec86f5fe9042cef2c874e34c0642bc8e182dc249af1369717c19d8f21b3bf1a6565a45279a67a1ef201ca3cd20e3df685517540b160
688815670856b6097b81a62e49cf2c3d68826cba8e45862ce999d9c5f7b395243325cb3ea823a1dc4ab2fcec79b999bd7069d60571e9c15e79dca575d0a76f55
dca93efed8c3bf42bdcf8da22108652626cca0625d9927d6f0b18cd6198f86fd2fe7d3ab7e4c7e2ceae2b47571155b5fbc59f0a2d25de5b6039be4461f535965
c9bc05936cd3f7d32350eb5bddfe49a7795ceff03cc1931de313f722561f9fa98fbdd356ab21230414f84c3f1769ccc959fef36a89a3b2b4b4e8c3dcf1b41730
5f7f6e622442d9cde959e3205627cbda949b0347b16192967db6137995e2a49c5b419c5d61f41692245baa34b7e5523872b22057d05491c945735344de5b7fd4
7c4de76702db80f39de4f8e2efcbeea6178b01b973a1eb132ee9c8e7dbd94291fbb653f2ed9975259d62e1dc1d4680b6f0f842532f3b1fcdd34bee2f6456731c
ef99c9d056d0444af84a0bfb5d8903569f1238c95782296849916267e8ff444aaa26273ca338174746f897e708530e1eabc657292b276d717883b1ee147bad50
2aba558ec4972d8699778d30e4ac5001c44beb0d56eb7371f93535db3f373a9de6c17d2abfef2a34c510a1b9a5c053ac88a1f9fa4cbe67dce6413e398e5c0cb9
22ae13f0ecce45dcad75fa327fb4f2a416c3e400f7ffb1f76eeb6d5cd7bae03d9ea20c53294026c0832427218d64d12464719b22b97870e296157c2051141181
008c02243114faebfbbee8cb7e837e85beef47d94fd2e334cfb30a80247bedb5f772be88a8aa793e8c39e638fcc35f6c931bf728f73742170668d860e143d142
dfb532a0146dda103be4b28d71d67e7982374d39115beea6d8d5dfada3b165d30e2b857738b684c405dff509d91242e7a4708ec916933bc30488c44a8be11c76
3526a1dbb53fc5e5a9be146c892c83fed530cf550ecec086d81d75990ce6bc241594f5be3fbdbe5d944e5abaa1e5759f92bed95b2207ffdd281210aa326c4950
11d92e1432c62462dec5644a28918198cd0de9f5b63feec89d5fc44388dbee3aa35adb4bedcec03359909287162039bce9f76638fd2c96d6c8e4112982188b98
dca4e01ba26d0b17c2e221f28d2213dc66ea9ee37647bcc04abe48431719f5b3c15ab06e48351da1fa51c13c296701126e04019b14a2eeb0d3bd82eca3215162
7694becae0e20cab1fd28f8da79bf2f63953cd99582dc07ef234da3d8d85b6b0b0747715b8dc00d180892b076eb65dad7cca28111af97e0020afb4b6f610b1d2
0c45177ce7a42efc35414fb7003d5c48839a70662d7a04807c072b94c1d3a3235c7893618a4aacaa829fc566e1b263a38177e3a146fe7293c6391b8fac577f93
038743e812bc57c7784249df4842186b8979659d29ce6bef20897ed38748f0d53940aa7ac7d29a400d64bf27fb94050d4d9a641e5b6de6258b5700f1c9f18631
77fbb9ac653d8646d7e37ac085eb4e3683c6d74f0e68ea68ed858b2c6704c30c859237686c40cb2d41807b4838cc32ed3327b6731d2bf6932a6499200b04a877
d7bdbe45d3970811439820ee4c41b00521c333b2b300be00a1f84d88456215089d1f7fdd40cf9108c1779cc5e77b4747e8aa54c53802141069155c6f14949f1e
ededb7131302232dc292170cdb6b0b043965a179ba0846feb70e64b20ab83c6e23a3e7499db8f0c6aedf69920791296114ee584478934defd30218bce898a10b
16f6a997e04e1f0806942992e75a6344358bf037cf46bc12105aef864ac1501274c0905150be4e004fdd2962dc4c73361255c49a6380a8680e69008eecacc5c8
615f32249917b7230db4894972dacd65dfea781ed0d62de97b3fcf672c0ef3c72616882221faa372ea814304e61b3abc87f71a8059882ba65327eb2fc342230f
6f472a4b895870122820addb47b24682094612e9c683404cdae3261628596f07c914978a545495d04c778d5ba9381d910eb906ab6d92c35907db0a9dee386b58
755d4c772d27745c31fe7ce1e0f4d9de8249fb75b08ab57bfaf56d17a8a9d734156f6b9946514a45ba5a6b0f1ce1aa8c5c1490277b2459bc8be0b0065dbe843a
a9ea3f81107173db2c3cb00892bcfffbe1c5b2640921e0a756dc8bcb83d344950fdf3aa7276717c2932b2eadaae2b9d810e3e1a9494eb3e9da83eae63cadc658
2b7dccc03a7f930dd1622eeb48a9fa64a404759b158b5e3080a3d40a46a648fad00c9725f363ea5cab123baa96aa868d8e3103d4f95ea47fcdeaae11c6abe5e8
adfab040beeb37933d2698daaedee16fdff5473387742a4c6325e377ee48a8f2e8b96ca27e67d81e11742c7373f005b4e1e8ea692c1f58263f1776a7222b8778
38ea7f4f4dc5cd8c98f3c87e9701de535cbc64e515d11de4233dc258eded289f2a2611ca613e898cf1f0c778643008fb7076e93b36b1998a83543678c4c29127
021ba32d349a0bece42cebb9b85d9bf6c8519668848da60a9d5bb668a243e3e64c46a329dd5260ad4e611aef3c9fedb58736051c5bab41918d597d9e34b25f93
4dc7056836e4f35a69d62738405870d331d820e9c308452a04e91cc35a24ea76736fd9c4122c39dd595461e2aced9566c1443ca8a890ada4da23a84bc763e9c2
6d2a6e7620681a701acd6f916f9f9235340e1b16a7f82ebb47bd64034e6b4f9e62d7a4c0d6ef66b092ae78876ad3cefed4eb9707142fcada5dade8f7bfa0c65f
d91f18606acba7dfb20b1b93df770e6b98b47a3750d75b658361040346298df0356e6dd5a82cc7f5b19111d4edd3f05c388a7e81be4d642c1c8b071f300985ac
312c0b5a048b44bdc927c87a0b6ac21d8f8effe9a36eea91d2e27afef86c6bf92275937e9342dd7e16978ea095b1d2350451d58120223761e248acb7dfac3d58
d7fe8d8de6c62fbf34e7352bc5c735a82d264cffec4ab53ce193aa95354a321b45ecdd00ea0bb156362bca0189e469187300a81b8b87c8702943c40f732f8848
fef03cd2064cfa6837902599f2d6277815cf9e6d8de05d94459b9ddcb1865117036583a0256fae41d9cadeefaa84c0ab0f91f517e1cfac6d23ec95740e959e0e
980c7cd54832c98320c9cc43e098103346b80dd536c7e5cfd6bf49434a2ce694fc386a9fc138395507b56583665ef9eccf5d97b032686c2aac2a7670a1955f1c
ad543a5047a757d8395d534ed839cb699fecf342981d2dbd2c325b57fb21661c5c66a3298bfbbfcc349734d39455976a0ff6952d3525e1d2c69a655e0562ac29
45b2bd66a08461f2d7d7e1233cebcd854410c9deeee75a6c16477609d3ba91279cee2d61e25928e6d767477433395ff481f3c932fc4fd01b5b7661f15deccdac
6c61448a3624b40b977526ee2d84386bb5aa918d5615c433a0e3f3028f82baa55e2a2f52f6da4a65b21951e645823663c60e04257ace05f6415c7eb7b07c98f1
c9f4d38a175a0d79d9a44aae212546a1f6c242bc63a5230f4d788c3987642a768ca85a4e0c55c739d6de055675c5f8cd041ed5ff100904b2da61a208895cb9c4
094423a5e1376b2501d7f136bb579858fd0f7387c45779a52182c3e26525907aeca8b3b0067b1bac5c89f2da59aa16bd3356ae461d3c326c0c058e8e4211b97b
818d405500b78b4c0296b352b57c795a4b3441f6ed72753bfe656137962bc46faef2645aa6b5b84b900e7c5673c91c6fd9b6d2de142d4de74602f192182fd89e
daf4d6de62ca90e8734c70777f631b5c6117499c78ae754f28e5337730924f2bb3f4c048c0301c25da7d364275c67715a3caddc54601911aca6d1ebdc424be9d
8d9db6289d3e5b83299da3d7aa427ea3747515711ca599d06d7781b581e99d63e04aa6686c57cb16b411f3734f9bbf1b317391cda057c32e6a22c6b02bfbdaf6
45d646d79240b315815a25cece14a44fab60e5eac01d4dba3c31b2d4122bf2afc2fd847504e513eaa76e7cb304ee9d77f56c5a84576b01c51aec8987ed923811
31632acbea189964735727ec7a93d303a0bca59b1ab4b6849a1597bd5c61f61098b0decb8f0263ba423dc9bb7e37c927d76251cd00ca0afb7d9869300ec11429
42e2508389c98c8235d03aa321191697fa534b8f73b5e5dfc9699f3ec005a9d66f6dedf6bf6b1d3fdf2558ccfe4d6dad0f2c3124abd6f5f94e509482273c3748
e043dd42e8e732a542b2554a85915ba65448b64aa97c902c51ae02e35cba640193a7303eefb4d0dfd862f8deb9381cc2cb73d66f5a555a326b0ff0af9f5a0895
9ffea32c2e1404c15f3f170e4e240f2ecab507f857a577410c04e0dd6c038610ed0f110c26b617ae9cd31dcd91c6b2010945567914686f82282e70d3a7b9514e
8e539fdde66d4f78ab46c016dd8a5056c5bfdd984c3b1200b7e07db357d83a331a1e22ce4ab4c142e879c294e2930882a206c0183ec6dd9a18041ef4f1a2b66a
b790a2790b91c70df0af60fd3edf21bc5f34b386c48c33fe4db24912cb525129b760d899a848e84eedc69cd37488cc385d3f1c8fd28906560757efe796e52a2a
61958e97b470e96e1ccd64be6b0bd267c32181640bfb2305a856dbbc1bddaa3be32c9b74948d04b68f013c3ce38924b0e1522a406d40c7960704d68325539474
b37f889517e3039fe33746b5320e8adb608362e446435d3754cbae5ab181f1b6983fce37fd613fbfcd7aebc9d56c5a503eb01c03ad7fcc953524f021b91941a3
0a41b3b24ede753cfabda005f835a64da2ec8e75968fe4832f79f3bdeff7a6b7ccc0e32fd85fb37e4770243bf4aaee0175215e1aff8fb11ff63bdf9f1cb1336b
e725dc6e8f2ff648e48d7514828879186c6e798243862da1ddb696fe32db7eb6b9895fa949d57a71c1d47792ae90558dd77323035150614874d6b61c4745e2bd
45a891cfae940c009721a2e3300420dc5ac7c8acca5f863f53493b886524e9e9b7ded430c0d655f2d6bab737c6c91124389fb2b71e83ff1442246be14771697b
9464c9f2a09fa5859dcfae962cc9484ca2b829aaccc2fc3c6aa58d39e38958d8142523c08167693ed0950691df94ac70fea53f06ecb701415453dc4a8f4f2e92
e72797c70769c506cb74841029ff4e0b4bfceffff7ff95fa4a13187d52984c98d6d64d956770db3e3cfe21259dde873e61f7998f64dc869fde77fb5337e3dff6
0e2f54c6c7e63d2c78a8ec1ffff0b03fe35de11b65badce03cdf3b3c6a2f1e19b238291f1dab5092dbed51474a0aee65cb15fd7fda451fb4c3c2ad2b52341302
7751bd3880b674d8a102b876152a22236e3071a8ae49b2aab3533a02acf620cf9611f2ae4d435aa41bc1c79dc670a33b0f8868e3c9564ea4147e6e6de35fc255
33b88076231d704bd5ae52725d88f468f7a394cca72b146a75bca4ccc07097c8ff140a7997a9684ed6017a74f8134b5f2fcf2dae8edeee9f1c9d9c15cf9c9553
f198f40ab6e0f9c9b1665eb17e31ceecdc40176eb5dda41278197782e50cf425982385d90296f3f4ac7dba77d60ecc125ab6a52bec91d05941d953aad464f59f
eef2965aca73cb2d61efe202da87ee025aa75fec3240b67e9431d5ead5454df5f45eca105585503686a972cb3044d54d1968b36cdbe26af2f00608626de31faf
7ed97cfa47f8ff76f2fa9b8ff6c3dac67a52ada20d04dc6d953c5fc50ef2ed3d4b631a044d0e9aa63d7c7ec756f976c83a2c0eb3b064e5ec0de94ec34c9aef2a
112bf2a51501dc385d04c351e87eb1ea1a5ddc37f48b90f5685cef146e36899c3790ddc8372c996d4f6c16d3c428909d3363a9da8e51cffffffdbf2294b4659d
2983f33a5a47d7c9e27432e226b83252b21aefb2774981abc80b6b036aff13659f8b9743651eb86e05195b571a53ba358906d4b6bf0debc19e8a4439d54e8484
b84ad2d83e5a313e3f6b90c58dbe4a8a4b863813f25c90934e795dc60303aafa498c76e9f26579928895031a45f6a753a58b40fbefc0fba5d4c1e64cacc0afbb
e3293975199286448c151cfaae77cdf6b657ba62edc0597872d976fde9be32e522d376192777ada0853d6b7e33639def588aeba3e67676d5b1dcd1fef087b8d7
9aefb1c6377654e3882ba8ed6367a9a6f510f34b1ce3c0dd0d2938cb428623182f45ae2d138872d762ce0b7dde755d5dd920190523ca24d9958d4847335648d3
5e8c465d74a3de3262bdb9c29baf961bae32b481c151cb2a7349677c9c50029071b26ed4fd86442a4b79577c325db486d3eb46995bb4f48a17fd6abd59da29da
985b7c3aa6cfef06c2b30c78d0e740ae686c80edfc8b81fa7c1eb0ccca38362b2a4569bf9e003d02aefb0ed7973a9323cbd1f5e3cc2dcddf55e6b9cd0b8408ba
1384f3b1f1b809fdee977c1ef77b311e6a5710540a321642a8d876afb6357be809fd3ba09730b843e6536013f9e9c5c9f94527f2adc76874700938d74e4c36c5
d56e450b296e6ce2b4c816e5d49582c0527490a015aa815db521578dd131f951282ed45d37c9da036522b933cb6895a571f78682240aae011faa34ae4d8a9826
d1809658d97523c327caebdba92979f569c990458f146299847d12c8886c121f431c90d03ff9d4f3fd522ce270440a5a617891d1d05e516cfe6f24fc9e885579
533d6cadaf8b8c42bfa21f8f9ae675cccf0a117f6c7b7e7292fa9a7dab92062c81ed674f186e4832a086a7f9d8739d3023ae5221ae57b7f12f84f6aac98fc6eb
87cdf56fb7e6ea7dfdafb55f9a8b13d5091a0c07e56b64353bfb47279707cf8fe05eaed5191dedfdf1d376e56b4877c16c69825e9e7ae8c80959507818380131
35de60f859f4e31ccd7a3783ee244b7328603cbb1a904b1d5c9b72144d1f1c9f37938317fba784a6964d948314bcc7827bc01c5c650c7f00d9afee71c2058981
bcc9722c096e588d6bf8b74fc16d46a3299c07ddb102586f565028a19acba8f4fdbcf36630baea0e8a279e2421ccedde4f6f47c32749c3ccc377dfa5a73f7770
d8f4581d9ea695fe1d9919f7c752b57a019daa54a693fb1da5806b9934cdfeb8233f515adcec4edebc7bb5f5ba5ec93e5c6318d79fb0c636aa6a38f7a4dbcf81
87a5616a6318c7ad3a30d0fe4b4abac92adae63bc402858d066bec29ed3678674680a2ae6d55ea95b0472409d233d8719463e2a2e88c1e5e270ce2036b3321a1
518baa0b9a8a790044531c892350fc589a6fa05336959223d840a1e29bd29542d114128aa24ad8f94e7ad787b7cd4df8df16fca5ffc582531acb19e88952dffb
83601244ecf255a8061dd7fe5b54c971c0d92bb7f4eabf91e095da37afea6eec25df60ded636fc9df4b3bcb5957c93dfe29a75cefdc02581cc2a36046310c84d
f4efda865855cc533446c0521b3fcdeac558fd25fdf91fb1fd9617102d647439273382eba48986233a304928af22a24e99aae42bbb55e44055bee0adf2839cf1
1029d145af21873d3fb6882adcdaf12efa4bc98ef195e4f370fb28cf1e3e476c553c2ae14a695075cd291ed7c6c3d1c9fede1110305597197cb5f154e9d5d891
eb02b1b4acd4f685fffdc20bff6c0c8331ede4b7195c35e0e4eabf19deb17da293cfad4e7548bfa8ba189cc6605e316a283c59c0d020aa80faa6f91ab2b8d539
f0a13f3667391b1622614335742682a1d670a4c12eec02ede790390ad7849dbeca06206204a95cd33d5b0b740fb633ed342894d2bc1ac289f84bd3ee666b09dc
1d9d898eaed86468bc55d305720b767b25c88f2ef2d7b28bda2dea93d6f4838920ef9badd8a5cffdbb8b2c80e908616d14cf66c7ac6946065dbc63540b683878
0c5573fc95a40440bcd07062ac5d316faae635f87b736dadeac6f5bc4b36bfa5008bce66428d20a6e7c4abec40b522fcc1af7cce560e28873659c671b8ee93c1
9c3732d562506cbb6fbcd4df200c58238ea30f47c2643408e73fbf1f5edf4e46c3febf18bcc05ec91223da5d20357df8f6e6f5ddc4cce1da83d7f679395f154e
9ef428f1a75facdcf5b4dfbdd3835098d09b8d4ac9e0f934229c16bcda96c91c646fedebbd23fafb2c59b0dd760d1a893ff4357ed11fcfebcd6a7022cb4dad7d
7c767274f412516e1958e7a7c3f3c3ef8fda9dc3e3d3cb8b8a0ba5e2836416a0b3e9f716309bf0ecac0216a93efb273f61684db9ee759842749435912cbb4ea0
635556fbc107c7d0c5ab8fdc888c98e1aba45435ede0c244540e069eaa991c8f029cca1008ca20ef7c82aebb0884eeb048f195a4ac1bd7e61cbe36ee6c84604f
5000cfaef4b0c67feb851851bdd935ea97cea770fbeb0e90aa478433efb6e1a6b2192fe39c01e25807d710e1393308df24ca394819831469a28c64c85225eea3
6c1525ef5ab7c69d11f59a0886348a41b1aaa800bcaeb852f6da0871832cd1143b5528f03a41ca55952322756e53b54e2f1bc35ece807ec0d166db2ae2668be9
42a552a36e482bcb21cc45d0ce6cb0b9362f8f17b32b4296c3ae6b243ead955ed7146add6076b16d29e96b12e81234df558fa122b0086ccebed71620ef258aee
7809764b55a382c007cb5072a97e1a943c0b5e6fc388806e06a3f7cd5422cb2f097fb7eb63df3990772419de2b9c040dc0a334a551f438018d7343399394b203
63a87f7b9f8411d3cf6fa0e3efbbf72aeeabca5f12f3abbeab3b656570ba064491383d154691cdfb9136aa1c389eecc5db728b711b428d376da147c5db72f66a
ac3994ce81628216c97dd766419d26a155b8722d46f4a544f1caada064b7913284e190c987580be553e9a8499ae8b8fdb077d1fedbdecfad48916ee378be4ddb
e498a53134c1d7ed6bea8397d74417b91dbdefe88fa2e8928990f6146f6103bda6777120a50ad3da5a14f559163b0a775542a3a90e4363e288d9e8b0ad58456e
92cecb9383760b63ee7607319a7214340085237609496dac904deb56d062b7213adaa815e3345276521b8e267704328dd48a7b2f932d02ef7aea4d435dec015c
585cba4ed9c9841d0afb8ef0d338f8c5a302e48d21ff2d28ffb5da4d1ffd5481b9e958be40757b85e3c7643c8275a595c8e2f2e343991bbf937c1738eb31d9ba
c11d85de90bec9aa4df9afe4d0738206a107c4cdc05e3fa917b701edea618a4728fa87738db4467633824804ecee9ebfda7c0d4c78240e81fabea5bfbb5108d4
f7edd773232752d746589d511c4d58a19e3c69758196a267556be3ab7deac9271cc43c2b6216d5922c706099975efab9cf96e1a1eeb2638d08fd3d39bbe035c7
81da761385fda973a81790fa182e02ee47fd06cb3affd15473fe23bc9139d93f3c38d35fac7790822d100ff45779d65f9e7b5f9eab2f2f2f2edd4ff082bbad42
abd05ba7eae00b14d62e4adc0ed33af9898c47ca8589754bb512b6fd742aa73502e69529c7fadcb6bebaa13bf8bb8dc2ce29ece01d268d4163a7413bbffcfe7c
ffecf014ef42ee0c075fa0586575e224b45f421a054327afd9fac7a07e772e2fad5e79efed2ace4e2e4ef6217f508d7cb0d2fed8fe394806ef701cfd8bf88bbd
f317664ccd577c5f1573f97c36d10651cae2c4b8b741666725f7c709e17991f7083a0056d7b4796d24fe9f607b1aab0085ae00bc3cda1bdcb37557eed8c38d06
bd0de5bc2e9c3f7967e33785968fc1dbe1e098e4d3a6130e0d89169d17bbd66f2070a173b64fa662e6bc86a899c23c584e4dc234855234cc0870154f81f96954
a53b3a0a04b288cae193dd2a1f0c0c05296eecfa8da961a47221ac084b05c9dfdcaab0eb638cc7ee59693493e7fd0f94805cf52518170d6a6a64a87a7e51d9df
bb99902eeae1e97ccd8153cd6e66b960fb5ec3cc62a40f6362a9e69fa0b254788a9bc931fcb763f5b52957905040615d8ce05a8537af9ff68e0e0f80f73888cb
07f62d6878986bc7387d55386aeff42b419b3e53a26a9cae34b2c85640aa5eabe9a70e799bd4ab4b02efcb70a23df4e141b2a60e9bf27e5ff046130a907a1bbf
ace132cb722aa756d82f73aa94e547061545178af115ba8ecd5f736838bed19caccb8f5662c28c3d60cdef2dc35165425d200d52964cc6d2fa6f137200a35de3
9a700bbbb96e1b10f4c4d3d5b36d5582a2f75098130b43a2cab8625f419ee7c428dd80ee90dd1323b6c0d6e74fc6c250a5f213b065a396bbea0faa05d2053f9f
fa6cd9769a244aa2ac4b55b8d771381eed791282d80762b170f4cfc4048b6b37c8806436cf5695b96e51cf045bf84ac566b0cc7c85167c6a6b7111340e6d5ad8
b84eb692c6df9227ea25ed74dce21111fd838d92beffe2f0e82039df9393cf3837a37d19904ddacf483f9050ce86404baf6fc94b1b65c0cb367c2e3a8e21dc61
ff6526956cef6458b8612b9608c32b1c832a92f514489915aabd0fb9726319f0922b338c5e6334441b438d626a89e7d9e54a44642c373fe458678a03da70245d
187126a7291fea29566c83884b152af70886a3693cabac1ad4ea93b634f090c9d4e24279e3a7d762c0811c39ad125c381a8848df4f51beadb4547c42b360fa5a
4984f184c06d4119d0903a0d24860ffa08220d0a5fd5a3ca12d42f9be38a4ef758aaf47268784420cbc3d1b07185f8dce82c5af94dd513cafcb23c0ec57fcef3
7f435307e85dfb1c452187e72f80c7b19ca3563aff63477169f7cf6c390a016edbb1b08c795cec101f4d7adceb85a7b87778470ba4756718db943c6a236bb19c
3751142325f3268bd0544b86f42cd86698dddeaa766e8feb38469402db6f4ce911bdea5bad84d66f68a5537c3866b67396ac5443800998648645a1e5a9c2e560
dfea66c41bdbaec725834e3dc219f6e5b0cd762d3a7cdd1db289061abbf5f85e035701d484eaf0dbe7ec310ce7df59868a8764dff7118b3005364b26ed3819a3
bac6a080f4baf9edd5a83be150253b1183032e1d55d4e7ed8bcbd3cee5a160562aa3a171779667368d32da5b8dc2dbc1ab26b9404765d601ba8d12e12b55f66e
6c91a8480d9adfde2d608be8ee3ccca6ee0e177d85decabb05e3676ede1677ae6477494d470624cd637f389e4db5bea8ee213ad95a06383c224e8aaeaa213579
929ad68b38b108fd2aa2a75458d1c995c4f9b26482446b7d32bb1b18a8d114f6df66c4ed2017d34310bc411ec152c2bb17c52191c8edb32961f510dc7136cdc5
1c61139d6a87c19727fc05a8956e86af687503e4405b520f774b37c01909b29f644c173b05c271f50798f3c933470f1aadfc945a9a64ef70fd5c67e96e087ab0
89a007580f9d4bd2b52417d7657f34aa913a4b8a43dd280ac8717c6087f5b0486f146325f270b6d66aff1cc18c7607e4b8358b395b351a791f3a96a48d27c95d
7f08d41c563efaba35c65d324f1a01e59ac621b7da7d6ae4473a893fee5d5ebcf8c8e293eee0637edb452b99b7d9fd473ce13f22dd8349b8eb4f3fc2d0f4807a
7c547dfac80cf547e2fc3fc2f682658f4ea16f3e5a3c7d6a4ddcb79b46ece4abbeb8e7d582a3821c5f1fe56794c8baa62677b0e311a27c27062b1441a4d88dd8
ea7246d58030b5051daba25bf40914d01a2b1c44b4acd9272eafc3a0261fada3cac489520077667127aaf2925312f326e911ececc13dcc2c10f5942f5ba4d8de
383dff118f1f5c7a423171f5f5462487a279898260ba5d3a3e4161ece9c93910cffd1727e7ede38f64aec14b23b9be1de56812b06cf397ee022e34ddd8ee1bd4
3721173cb91f4f476f26ddf12d9040d58adcc198f7add98329524b92af9b2c85b097aabc5aad534b774cf8173896c6a3612f708036817870eeec79ebdfdc6413
bba7d1de467a2c47b67baffea8002c51748946fcee065db5ebab765f0e31db7bc91615fbdd2cecaa8e65e0d366d8b39b1c7bc47d0dfce76610e760d59e5018a5
2c87e206d9cd54b9404d08f200e51aa1289c7c0029f8f478706fe3c19655cd07ff3efd56e3c612c353c503ac27b6c0d40a22565f4f48bb89826de04606837546
19508fecee47ba6fb408064618e97851cb0ac75e8fbf3fce7f59629857df336474807ee639c22f72902e879e6eb8bb491d0549f76af42ebaaa96ea61f12a5b6a
392ddd57b45fd17c875a5b59a05028ebc7a27564e1fca4682bd1edb1fc47d8325bde9be423eea4c239d4bb95d6cda2562c1cd1a5761a0cc98c9df6998542aa99
8b2a29d8663b6b0f3aba65d926b34ff055bec5defbefec67f59b318e59b6dc215c01b8487d9876e0b636ceb3026041bc472d0351e0e00d4ef02b8a8fef46404f
47432012641653115692bf9622e2e14dbe4d0dbb3ccfaecf54810b11f2748d2b94fe52b7b2b478eddac769facc1c72c390add35557636184c459b4ef6ed034fd
b8f97173967f1c6e743f1e6fec7d845d8291feee3f1eca8f3002d0ae3bd58feb7116407b7b71cd4122c722bf249890710a0b6cd09db5d4cf3b5db4d1fe320b49
02d07d361624c97a04fa32e2dc55b81b743c045d24dd6109a25532c17cf7a7a349e70acee04e76738306b3d65d96edf35fb4f78e2e5e309a06b2fd872879dd6f
a313b53744e932a3639b54714b7bad4db159a7e64fa6fc171763c5891ed7e822c8c69be4052bcaa4f584c831214599d1e1b0e9b6f6fda7182c12498c478532e5
4d150ace3977c4dc5e5b1b89461a493777a7e1542d95910c0debe050aa9e749f89af0555e3bb93b8e02270e32d049a08832f9132c66bbe8289eaf595c914e52e
eac427347aeeb6f9dbbc08ea42afc478cbc90545169c8403594f80f1b825a0078e1280af2884a96850ba836692ec0d951d4843f607308d52105ce04713e5bd4f
9b9ae74ac525253f1f760abbc2480649973d430cf99582702d36644bd1a9dd34ab4c75fd4f7924a209090c48ab513600d1a57751b4d23ccfb606f5ec33d61be3
77d46ab21193ef60e5211b66117fd62d79c8b132dc0b8163d9b59236f56f7256eaf271d67ea3f3321e84ce1064b81c3d38279012bb48c7ab0c8ca19fbe6af18d
ca7d05a72753f7e2a2b08f7661fcec15a75f7281bab4792c40a3c23889115423b1673d00adb4b4527afeaa65a58f3f335e420a78bcae60d3be352b6c90c1257b
cb923cf0a9b066d6e537c956bdee1de30c615ed4f4b507aa7ba7d11f722fe62807b8ede2fd38c9e13ceacd062440ff40961dbc87a4bf53adb2d0b6d3bb984869
202800f97472af6b359ade661807cc06452ff6372f0793d70600848783d4052fb0d842c2f14396cec0bb857a774f807b8e259080c607444fcb51e31f422fc125
2d719d68d20b3d9cc34b1734f94d966c25a39be459ca20ef43b861cdaea72e4224ad554289443db86b6ba0a2ea70429f8f2aaa735bd549a3e60315913589bee9
419d3cdb6473436541c3ec38bef29df811f53d22814eeddb23bf4b976ef113d5e223024d1fe22a7f339af69187f1d4c46241649b03858daec83150ce37dabea4
8516344bf7e1a9eac34f1c30281b92c85274e38948d8fa03b85ea45fd6c886c4bc798287f8d5c00b20b08c8d8db7b4439d5cdbe94aea354e09348d05a6ee50e9
803d5303b6a7dc764b8dcc6406c9d66381958fbb0cd491118ba540f11c51a287ca131ddea1991a2ae8acfb92688896008e42220637857f8eaeac8018554dd1d0
6748679dc3a5c08dee84c6440f141b908211af3d6095f358a42739f0997f20342b3e5aa2918e57bb6d84d1ff8a65edbf26e93ffed60572d3fbfebe753703b6a8
3103822025ada505fdb155530542b5856d0e6a0bdb5d2ca7d92db9cef8010a8b6f0565a5ac7ac3d80dd9f6a0c04fe7dbe55c74979fcbaec3be9809d61755341b
a3f1324f58715cb3dd023efdfce7f38bf6cb83cec969fb8cf56278413fb9bc105399f34f62e3938811bb2e02f65c298bfddf4657163b5d5a54213f0dcc618d63
40406d644126bf50409cd40b028d0b51f2875f73b0be0cd30d20e3afe2b0719a798d544ebc6c5941a5fd21c65d2afaaa95989809fe173b9ec2ca0d110e7b7721
8b6dc25edb3175fc715522852be0c2ee34d78c663418aeef61e1d29ce7feca573bf259ee63a1c676e392211825d6805ea196025f65b4d5e7b672da2dd23518d0
e551ae48a9c50539c1844246317e20a60bd06a5373249a63d28e16a50f478f7795fc265ad4e71e095171c8aad4fe3309d5172252210d703620ed638f78156c4d
2a86b73ca25d32121bef6e7a4bf777be16abf17b6a8f1f237ca8d40b87cf3f7a9f7de933733ba7d01bdf23c7b181ebb0817037cb9e9024daba8b83be3aa725cb
5c7b09e1109264cec41a2d3e27a32b709563dded79443cb6fde5cfd505c2252211eaee4ad2ce32514e7c8f5b4761bae25118568f8db21bbcd4e9c4d21a1fe657
d91a13d20414cd572d25ba66e374e814d7943613c1e0c75a08851f2f656894812f7add6997c422ab9df69f7c3646c72626ce5db2d7e2bba87b8ff45cc31f9339
3c1a16f8433022a3cb5c91782c04175d24546e3c5c1eee47af7ddef1ce732ea73b590a0c06a3f7225057cbe9373875ddc372343622b4e2908c3a58c3458650b5
3064837be62328184470671d8edeff35399c6aa9b98a88c680bcac902208de668a7243731bdedc0dc1e05dc6e54ba2e297733cab35624538fd15aa5e050cff53
3b1491952d04f32f671715e1bc882e10da80a3f1d85a13e2a724cb8256a794e1accc371c35ebe44758e08fab2e57f110312a170c320d42bed0aaff74327aa38c
b21f570becf34985feeae4c7d78f94092d1a6ffe70d66e1f3b769c58448880c4f6169e7737eeb141ff7a1a317bbeeef72656102f1b691a3f29a0e9fd17edfd1f
8be1a5ff998f861a6a7a76359e8cae03f069e63e3ddc6969a18d3b4d7638d0d8d60529744cdb5bc9abd71688b59492e107acbf89a425af99ea9beccbc831866b
afaafd71753da936fe49ff3ec57fa508fc894c6715eaa6107154735d9b5e10438dfa4655e38e15016492f4112e1c3e932219fa58a3723bc8c943c9af5ed7777c
4111e6e09437dd3ba077d53a9ec855587cd3ea4e20f60970755985c6a68d05e379537dc04a5ea534cbe9ebf9863c237c48ffc3201bc2bbaa1eeae75d588675bf
993c654d8ccd8aa76a4d0aaf479bc893d4ec8e11800cea3787d3831e98b47f33ecde65e97a92fe35adcf77920729725ed568e36dfa031b79471c36721bb99ccc
af3e63c6d9a15ecd37fce548d1f0034f93a205c0d6a2ca61de9afe1ec56c6183bb96d886d1bcf6f269b56ef364e4006fa586529dcc2d8401207f0a6f0504b3af
c762c9a560555334df0540ef854d587a6d583288a46577d85f6af6d06148f87089d9457dd34a6eaa0446f140195fa5f01b177465c1a2e4897444230b561e4ebf
2a0857404ebe9735b894d574f975692e916ffd3a068abfa922f5314563e07bc2bd27025b218c4de0c204cd8f9afb6e3c343a483e8ebe5a26d6d352018d6c64a3
0820a3035cc9f8f21cd6c80056da70470e3f27f81ee4c55a120d894b92a065141bccf89932dc61fe579f9333952d110f49c78082bd91b1f92adac5eeaaf83176
b81837928cce094c0639dd4335b1e8d8cb746eaa2fd177ccaf50698c1865e28b98783bbb51f05a2768171fe088d63a1951206ad245efdae1cf74b97a4dc55a69
0ffe68d27f83ea256e7a7ce46554d42daa8b405aa4a065bc656c4d5543cce24ad30b995d21fd745f6e7676578df5e33294e1d8acc3599d47266e9d2d2c0626da
611837061ad325afb549a6fdb9ad7077b879340ceffbdbcc5ef9cca492348f13dbe1cba3628bad6a6110f38a8b9517b0808431ae18407ed54dae92eba40707c3
74d2e50f1831a8a943063909c465022344688f36949f3fd05772edfbc31fc4e3cf7bbc721fafddc79e720bb4f5f1563347d7d34cbced904ed3239bc87609861b
ffb9a6c8bc55250a70857c94c312f33d6cad3fd130376e8df85fadb6b5f935674afe22463ce6cd77ad64fbd933468b73f392058c1dfc47028076901b0a274485
80517342987412b907aa259c25f306aab5bddd3b2ff7fe1e6b4351101ff9db69bc7eacc2f19876cef006334144e2b256a2c71deb7cefba1fe0c7936a41952249
8d0d6fadc6025ee81f94267148e0197a0785022f86c317415528952db0a699ed116c58187179a7028cc259ccc8097b9059488585d01f8b8111fcda75b9429592
56dd52a05349cc5e389ad7c63c63b37f313c30607cab1667e0d13ebbc03f37e97f2b9513db85ecef688d65e8fe5a498324506296258dae230e2e964c3932c0b8
e1c97681e189278bf0b82cadc8bcf08c4d144aac320e6956230e872c6c2cca6aec80a90834621b5b9e4a4a2ca817691ca8d5388fbb726cbda28bb27933eae6d6
a0b4aa72356bbce718cca141266f06aa0c2dc0d0c28b94893a2707936033da78bef75df19153d027571939c9c0961d2100b806075223465e934ddfc15a75d86d
aaa01d14b45267b25b1964f9bc06daa68742e3743000c5635d11b71e10618e90776360f42de85403a03fde121f75fcbd8dbf9ff2ef27f8fb99012d9008b3a46d
6a6d125a2a9b2d8ad1bdefa62cd5eb010db102758a05fb485929729c4b17f186dbb363cbe3a5580d8f6ec9cea5f59e9a090936758708f5780b49da789bfe7d52
c01c60f2d8c1a5e321daf761a18e08084bbdff987048f29da4f12ec143914b4bd7b6bed96cb53e240f1c3b766b9eb48f0f92070c389e7c45efe669cc5c6989e1
61505a6e0355171b9d70841c526293498ea762d65330163ce3fa50a07e4f4575ece48bbaddff9a343f610db8b0bf7635ca919682f22c5e10346794316f209f5e
d4c8982e3f8d2b4a4b1b3eedbea1d8ed5267c2315e79866c0d5f616b71cff5bc50a7c1a57f9921b44a587eff4803320becef1cce95fd8b236038cf7ec4a8bdb0
35a2dff7f78e4f8e0fe118e12447e5493ea94bea12a6c26f8a5e03d9eb7c8c0443698bbad324a81cc66149fa4106dc483f545615f0a7a43f78813d3b39fe013f
75185b49e5b23e9cfcd43e3b3b3cb0befd7c6e57a00c7470d62331721b8fad60ca8bd392262bca8be1e46037ab85b48e4f02e019f02a48d49e64519c6949b539
972198e2d67ade785c60acb9c412c0fbb5b153c8efefa86dd4aecfa783302e1bd9f47a83ed729b78c7607b106714822405cc34755b47365580c20562bc65684b
50b104e045b3fe1cd9c6a965c2a16c8b17139d5a4dec4ed8d59bae86c400c5b4667fdb3b3bfef27a33e6b7f6140adf128a336c87ab3afbb97d7474f2b7a57567
45489c56a7c54b413169b0a9e0181275365098bfc4cc6dbefb2e6d9f3cef30e6745af9faab8d593ed9b8ea0f37b2e1bbe4aa9bdf56bed6085a57f711395d33d9
270b9b9c0ddbf1e46b40be10e4170330258d7636c3fbc238c34984b22970188faa04836f9def6f6dfe79abc2413a791545027787af6891552accf62c8b0e6dcd
b28030094a73afb088ba3166d2c7310e68ca10c9528c0fcc915ddf025bdf46b04de414e2561cc4840fbd918336ff61dbd28ac0c86fd9e2d7ecc398b1c06eb30f
14818157dde687471f0c0cdf41d8ecf6af49b57fd301debfa6b08f0fe61f513e66ca9bd76baf5eedd069b5f3faf5c7b57a75954e16d9abcc503fda150415179a
1901828bbbabb7979a61b894da933bbd1f6774fb48b863a6f715742963be505d646f06b3fcd65f1ef9f5088ae0c02a985e25b62ae2cb278318bab92b7ae19168
43177a379da94702ce2f48361b57cc66ac146fdcdee8fdf0cb6cdd630ac3a18dbbd042012154ba82804ef3075d846f18a45a94336863d4edddf5877d0c268492
dec17d826d42df3784cbe9becd72654bb44181e358d183e83977e311524d288e44d5ef46fd5e9ebc456cb9c1c6309bd2b0f432d40f181cd33c51989eb0689455
135971fc7374f57bd1958239c37ec77c3e2bb47037c309bdbd1bf5923f3edb8c51e3d83cbb045cb9686c2c3056c1e5815563fa85cba0f2ea72d89fbeae1c58ce
3211858cbb9b2be84d92b744c3da180df1bc156bdeca1ebafe147cfb9eb460add000a7527975cebf5e572e6023b780dd01f23badb43f64d7647bdc5a7b90019a
ab41938fa371f00d47af72463c163507559d145bf382ad82a8c4f3ecbab5f5ccbc1a8df1cd9f2a3f02a7f272d4cb5aca68a4f24ad05f5f578add682a7ac8adb9
defcf6e9d355664e641eb0d61c03ea45e6498649e8f5bb6f8623a0c0d71d96fc944aa3154c09266c5138d51f78104d317963ad8682f7e49b473f3fba7bd46b3c
7af1e8e5a3f37a73fa612acdbd7bdbeb4fd02c9a059fa409a30f52adcd0e459696a94b5a025c528802f74336a498f7c05b2a3e8adbd538cceb11d43899b16c92
48a477cec739f74e4f3bc0e89e1f9e1c1702cea52de006f9e2027c61cb6ad28c74248deeae856d32659a32ca717632608176a3f878ba60be625cb26b43524374
b8b3f60130a3ed83ba571db2538d7692e61bffc0b82fcdc78825d77aa592bfde483dc5fb82aacfdb673f1deeb713d2629efb95b936ef8bcce262b887e3e4b087
ffa2e3a80093783825e3e47c76a57f23fd790efcac7e7196e508e2199ad9d95cbcf6724e45f99216b8f52cec906facb8bab9636892f91b0f42e0eae7f512882f
dc1080ee35c6b8f8733c757faf09b2cda2e3eb4fcb1892f3bddc5f7fdafe73d0c7a09addbca09a68d1744a1d1e5fb4cf9eefc10a778b2e67ec8b969bc335ae96
2f5fb5b2e23ed15e4df68e0f92d393a3c3fd9fc3ae11e3cb9a79b18f36740341766f1b50d7f0fa6306ffef66dd5e3d0142f2cb56e2d0915837a86011e4aed06c
942b1d1eff1036d408a4cb463c90df527498788e627a20f2e08830d881145fa55b2223f1faa50f0057d6b274b1cf0fcfda7fdb3b3a4a3630f2573068ae509866
57ae713161f0c77ffcf2f8e33ff64f5ebe3cbcf8f88fc669ba74dff6110dffbf9d5c9e1def1d798d588c773b5b785a1848dcede416caf3007187c916b0c62b8c
9ae0f6c36c00dfe1b55779076c31b71dc70b224c13e2ad99f3500c37f16e1c8adbf9a055ab073ecf42914ba614cb3551790c57e6465c31b67351a90db34eced2
92eb1e1ff22986bc0ed9a858ac5e8bfb4789513339c79b11863a9f763f10ee406e6906e11b1c1709df0380d8f15da9af6c0e06705930ad0866e6f4ece4e072ff
0223a83dfaf597a17a3c3a3c6eeffdd0a677c2a49cefbf68bfdca3374ad2f8fdcf8a1fa3d7b899552926b01ebe2068ffe7671d535bd57b23155aa6595c5f67ff
f2ecaccda1036dfecf22185e9086a08b12e115db61072dc5671d5c955aada31ad293131051bf7113d988ea5e504b3bd2a183301e8989e8d976043df043c5c9ac
3891e2e49d1b130e5fc643bb71ebd3fb2c173ed4092f67c55dd161e4e05db4a8b0b961ac3ca771ea05561c06cfb3abc6e770c5ea888c58888ec6880f26fca274
8f633652602915a4117e9b988c41e17640462c43055934bf0fcc6f0cb1a83ae284bcb2580623ce72c4497ebd9e94cad4e1ac50dba044d71c89d3e1bde455e7c5
560caf5e4158485a3db1977e9c473fe1a2d6b5bf6c8b654edace935d398fbe890c19de6fad409198d90d0ba9dee898b9fe0bb31c53dfda2ab096f2c3e1a266c3
2f6aa7c1016ee7614bed48b74473fdc0b0ce4bb70f9130b0aacd0e63058f5ea9ce3ba7336199911d7bfea34301300ca5aa18e3a05a5b1ea3515ae7bb7d3f0ece
78e7f22c31c8b4b90bf0ca77d9ae0e679f67831b38c7c7f7e1e90eb7c4503123d6ab1806ae331cbd17b318a096cac06505cd0d54d0a092b4001847110eb3a39f
3bdb9b4fe372e0df4742fa75c8fea2b7b0d67ac2fc8d189a7b8a6646c98fe82f7b359ade0a73319af4b31c1b9675278c8384f2cad91066fe1d0c29723062882d
6c4aae1d57c993947c77a5a4fb6440f13c2bcac419ae7d8dbb64f38fcfb68afab542d20da5adac4cefd050edee2dc2542d4cbdd1b4c6a6f977faaf5e994ebae3
2445c372d4584381d53469fffdf042f187a852491789705327ada091ab7a89c713c06805199549643513791ce745fc25557443a7d8d19865f19268674ba173e5
3b5b56ba2a993730889b43bd4a9278e1717520169b9659b158e28598384eb0dd7920cd94de29312cbe5e3c51d63c557866fca55d190cf176bf4a4961198cecbb
40595fa0ab5fa9e6d7af2b01a97064d4ae42c21099e5b50f967c4c291fb03aca82b57d8a128222671679b0c002c765eb5e76ce386c50de5a2ce42b53522c2123
5c4d5ba14734aa91585eb9e00ce96a4a067b8256d03158d93c04345a81c33c07227c7dabd659087f66f0c7d0cd24df49231963425b145df549e4cdf99a8f37f8
87003442c336a265158b488d04c12f09f987bffca5b4341f934c49a1f5b95e6c3b12db59b606df36b55d14fe7439830f09be3abbd29ba9c33ee95c4a9cb7b02a
d3dc058376931fe002fe62f65bf0140a06b4030cc1103a8911d304c645038ac2883c7801bc5cc450e5ada3e7c3bd8e57fdb00598a3e2ccb177c9468bd39a71cd
f9a5597f7832775d75bc1510054d56aa3741559ca8a88d1cded04650edb5d2d480eeeb1cfd61b2d5dc84ff6dc15ffa1f41ca58b54aeeb59ab30f2ca4ed5eff4d
f24be0d6da781a7b79e5c821c204d57f5b7b506d9b4713f8031926d98bbcfb8642246c47bf20cfd8da8a7d02623c99463e3827aaf3156da3d320fd861817ffd2
8cff5ddbf0609b1d6a137c99bb410fbc26a0236fd2f869a65f5ad8d1b42c602a99a05e274d36c551935c8dc04d4bc0c719c6cc6a64bf265b0a08d8c3b5318bac
d4c37aee0059dba80ca6118cccf062bff3c3d1c9f77b47c5e80c8cbfa0dcc6fb63df535c7eda200cda29daf7090f5c9ab7627ece9474936dac9ba212469afd94
6c51e05d3fefb0e58ff84057c8095af7c50896a3907951f46a7f6c0decb409aaa686ce0bcae05abceb5488c910a35886e8983bb39e21771bac4885bddcd1d956
7b3aad90e7151ab80efa5789ccf5293c3af38eb38d2fddd965e7ba56a25f6ebfae54902d436c85711319e50e2221d4eacd7c3ce84fe953ad5e415a46381ce4aa
003f094980dde4c90c9471301446028c29f17a64a08467fd6dadeac9636d5f7f285df9ea07c9926fd823b06e616f70132e9472019752b4306c439dec15d1ec8f
f271bae52ac4bb270d0b76008efa9b9bfe875ab5a94ec526de74ea98a8c9cc000d5cf59761b5f94ff88e9193ea5018bee054c448d63647df6e6ef20b8ceed4bd
ce6a63b50bd41c9b05161ccfc8cdaa8f83d11bd2e94c17e8cbfde5b58f61b26e06dd49460c3e792d87b0e0ce49222a175995ce216bf3563ee780db6de956562f
19809040db57c42aaffe261669421afc4988f3a14bf7336dabee2895b7948baeed57b3fe00e39219bb6d7605136f7d057884ae302301be7a4ff0d4224ad0884c
7fda4490ac77141886b4f5c7c0561c9f745eee1d1ea39cfa4738d489d124266923477e336c78a298df06d57d8d287bd873dfaf1e85066c8fb7da509840c42ad0
56261744b641df5567a406921bb24525360796060a66c8f0f4adc0ba695e55c27e7579bbc05f38d81d38e198114441f00a75c3b22275336b00b9c86f5d2550ca
52eb336c0beeb169da0ad6d3503867796b20fd3e1b451d9aa4b848ed69387aeb70f9935050128968f43b8a570aea463905763c7dd44d8b8a2c6e034a203fab68
dddadfa38ee5c615e51491fac82df11db2cc18febce5e93de04b8efbbb67be597a03c3b4ae6d91178b910cd2ea5fdbc6b75274f2a07e75d449bd65f1e46525e8
264019fa77b414729e248a53732b83b2fc9c7f058e7427d9aa4bf6349412ce2b82899975109a921006f46ed034e3598854ba0c2a5f0840e2cc0b39b3067bd1bb
dcaed806db926e51fd8e086779ba1dec738635217ea6b7ebe35caab30cb90d8585bca0730ae3fd33bb47be3d30c64282ad710da7dcb15829da8c784cda529f86
b03ca5483372344263961f6171369f0d75d331445f9f815b7558904a1cd7118d901b24976f0c4763b82f8c1156172553dc314919eba008c654129edda2ce3973
a76b9786a22dd2f52db0332a4c4f51290cecbafd9f7a9ed8f5ce9a2d6b0b586167f4886d47231a444cbe160ddaff4c0b40068f0275954cfcee179bf55d99728c
01238e5011996c8922c796e82eafca8920c72a958ec470fc2cad0ec7bd5517867719a3a14671de3878154f4fa96ec7f18460c5ceea76eb852a1ddf63e4d9b3b8
96c71ab84a6cb43e6906c89adc93c74b104d16c87fc2149ccd8665032eb17da87ed44e61ff27af2b0bc3789e0cc5841cc6e8e9b31c9eb16af3eedbcdbcb2777d
3d9b74afef691cf30a26682db706a36a3227204e2536422baac9a28b7fd5d95a41bf16a9ef13738bff7ca043129eefb31c86a50ccff4e4b37c0f51b9db47ed5b
c630cf7d32a5cdb341c6e8718a55fdbdfc86b160cd56b389413103bd9390afb638aa0a6d9e572aabdc9d81c85384ed4258f7de2813f01074a8ad56163b22289b
f0e7bfa28cd8b1f99b6f908280656d56bd325caa54175f49fb24e779ffcd90c39c1a6f5731bab78cbd42581aaee97048e06d2e4e0a8ca19db902b32ae89c148b
305c33297995521845bcc48d6095e30262584d5b3805e7c95db36281dff4101709b16762d66831efcd0579addbe78ab95debb6b2dce4b0c03eca051e0b615618
c2bde1bd8a57cf7b09e15d8ce5159544fed7bebbfee1295c4d6d7f7dbb1d72774a040d38f09a9e5c87d05cb156630bc53a096f5ba6210c34861b69972ce5044c
0266976ec9224db4576c0f5e8d46ce34a39376e13443118e5861e3c976552161798d5c50a435fbba50fdeed38af596450cbdaea46018d49f041c11f9d2990006
92415c76ddcf6920ed40c840cb087a10f61750cf319efd3728b89c32c5157831646a5bab43ec45a4944a0a82e69105a57a229f68314676b2b0a0f21d5aaf30f1
b23acac1f910e7d950b8c70e11e3ab544396df74d2bdb98165ac97f07b642749f16521b4d123dc71b87d73a199fe702caefb54a457cea6716bf40b0dab0d876f
71c5e75ae855527558b053f9225003c55c3042ed97e12ef82491b0b688966be190717057224fbf237ac0ff6a67d132c8071e5b59b82496bfbb7a02cedf0207c1
b0a86a4d719dff8117d4e86dd419dc284e823bca9f699af809b807fe64ad70f1f1ad31f5adc735da377e766af128f7a7b3f6dec1cbb65a1feedb4a64d63d3037
6d685e692dff1f8c300103ec84c6426b0f9643dabce278f25198f1bbee8e248cbab4cd2bede1643418201c78633a7a9b0d0de8c1da83f26963472b5dcbb9258b
02ca309a8eae47831daec575a612bf2dab81ec63e1e6320d74bcbd4cae0a01c40c473d0e241693411c8a0c4282905338755fcf7e07e9aeb20a303287a7efcc8d
6834a1430a6d3b5181c3798dc93b318f22eabbee4ed0724cb3c815759c8f81c825e82b8dd05ed714394ebab3b1c541baed3193185508cb050b9559d666a57229
e6f691ee5d1e6233f78f0ed98e00c3c0af1bc5f97a321b2317b72e68edeb90188dd81190891978352c1a0b436c58810c5841efb25e7fca640eb8bd1efb6c7a4b
dcd9a89be1c6205c358e2a89f663d9a493cfee880709a1daf1be602183eb7010bda4ba91dfe71bd703b84022bccfc6da03259e6f900537818b540bb0d66e9274
36d4d8f341c43ed718574c293f74aeee098a4cfd80377c19a277f253f06d250db090481b9668e986ca12420a92bc60536118af5ef274b9924d77566bb5645adc
eed54b9f2e5b3ac518e1f8128d77c970767773375d84bf6bcd91646800716bf533bc6e2e980d2b8105f6382d2b71baa8c4a957a25a7edaa1eeefc9a33cd9c07f
d4b2fb985c042f53a7f5f45b8fa1dd0afaadbee0868cc4500c76a340b339b070bb8b0d3b926255e5ee4af07865709b215e5e62b0e4c22a9745b6b30bff7454bb
d2a62c03021241ea0d0471e8a1fa68e3b148e3ecd084c09e36bedc7f286781b305b93be60670dfb1077383cc30e1c08373057fa10a66d2ef6579f30b37c1c29a
72ac7722518274c49f9856826590265e108a2da68a9110c3b2d9102f72061220f1b00012876b4a42d0810401079c9815093be32796277ea205a3da24d3752648
5c7b4dbb69cad33cb93c382587f144b99127da873cb13cbf13250696459c2887efc45b4e892bb2b56dabacfa03dfe9c4779c4e3cafe9c475994e8c0374a2bd9f
13ebf69a38b7d1c4f6c94b02af64ab65d64d32f16fc44978cd4dc2bb6b82d8591eec40627901273e479a78200849148c20090005121b4d80ba502c2b605b4391
1744bc8f1988d6ac58b2e126105e1fdc82307d1fbc051d4fae912fcc96aa5e18bed1f596533b8b0479c8afc2b13eec750770ab8cb1ae68af0c57a0a6dd7c6757
992615a06e588dba1ce6b3b1842588b64ddd79823aeefa790e646dbeab8f87c23b91d354dcdfaa854ad1693548a9287434165250482e55a714188f985335f72c
241f5497226b52aaa42708701cfd3e572a344c17cba667c64c39ead2a48b3674d1bf27053518b80b2c523dec34f860985777c5dd497da1c1e28f369196de9823
e44e6e746e6d0641036a53546fa7b1f6a03fe083a282d0a939b62016e6c786d9b0205ab89d87c7e1bbbdbfeb01aa5a03048d48b8c1d027bc285d65d3f7199c8e
66ea5499733a31fdf77b7f8735b0ab29772bc0ff08e14aaafe5d9afb7dd07ebe777974d109bee11838f02655eb46ede6b55fcfbda5e98c5e0419652bf9f6d9b3
27cf62cbc8b9e2b2f38e35b54533e400ad9415af450761c9b4fa228dfdaa1554602d47478c81b366d790ebb9861bfaaf33c52f304df08e01451ed878de5fee01
ed14aa604443522d41b039f5786713d723bad2bdc6f36ee3a6f1fae1c9b73ac85771b5b75d945eab31b3230c63c17ea5ea00742a84da5e3f7cfb74f5ca54ffde
66f7d18ad4e9ea9c035149503552b52f51e2a5815108a13128739640ed14ec9cc4684e2322b827dc8aee6c4ac102cbd230424aa451284f526808112a876cbba6
829d41f72a332604eab6823407ae7e3521a3403a926f9034362e36dae7a775bcc83804516feecbf38b93971dfd694e3740539b152e14eb4cbc76a0cd18fc37ee
4e7238a7f82ad0a1ab80e78340ef38621a0df6f5146566d05584dbe8f5448948cf30f1ec7d2431d229b575317b44375b2a9062614df09e98ea9b565aaf584e89
9499461f1898ade6637bf42fac594ebad7e8f327aa1c4c0bed53a24e6e7dae802ab8ddadb50729fe6b2a1a5905fd457e6d6c3436be897fe86cfcb23117993154
bf4681eee4eb3c79943cadd7d1a16cb3aec6a795a6c9ee6eb26dbd68b5e8d513fb15bd795c573dcce27da14da776dcf7d0806f9f5e9e1d25836cf8667adba432
b2bc7b2d577269bc35033c07d25c8a24c40dc009b9a2e270522c854ddd1af5a23609a3e8354a465d02efb1b419c7c2e68aece7feb007f7787861a8566736ebf7
e4d5142aedc012c347c5c2e0ef596fdc2174622c2a7f8b7f44bb4a61c2e191c42277d319fe260da4b811c8a3f11d80178e4fbc2a56d5ae9e81b0cfc86713794c
52e988fbe6fb5b64df30ea24cea78a3ba9f7c5ae1db9844311ae3dd0df476be92f93746e41fae5786842ce2accb6e300f7535d0fa60e5408b37e5c7707d6fe76
58f706d9fe78590f06dcfebc5f7706dffae4b4ea45dd4c8a9dfdb46e26c87e7f5ea7c9b25f5dd49d89b33fbdac9b492c6ac1419d077edd0cbc35d9ee4cb38393
29ffdfc3bcc1427056815fc05e5d2d0afb6dbbae174851abd3b46eedfb6af11ec3da391ad03011bfc1e4a69f0d3036d203cc0c309e76d98608e0754d8232f0a6
b7c25cf23a222abbe512d82c6c81728996ddae2f68fef5c4bbf5d88fe65aa2ee53a389e693dcdbcf906bf50b77784a67512353f967f84f57d12e1b42454255a5
5484cd31787b6209866ca9fa4a38326b9b2de0c696aa2964c74a2e90ea6775b53abc1b65e9642932b0fa0d4dad156191f42d4daf91a46daefac145ad11bda499
61073224c3cd334b381ddf3e5ddfdafe933bea877ac9648dfcb63b118e67a995aaa8172cd2edcdcde4cf9bf08f5f2e29205180e7953861bb018e70998e2d531f
9e473cd02d4a4731a6ed1cb963a3e3e6d1dfcaae8701290cef6faa0f91bba1ee4cd1cdd0a6abc525bbd742ab50b65d0a9b489742b7ecb22d6485cb5e742f644a
ef9ab392104e887dd997c69ba95542598306fd9b8c7ca7efb26917bd48bccb70ad96e8b80b791d630e4b2549bdee72ca511e9213f78caa38e9923736a72011ba
d2ac3b8c5ca34b1af4bc55abefc2a08d897a36a6fc32f92ef9ae86a777871fb5091dbeabd677392a347d7bf56fafe778ee3cb35abb14cd1115bd0073396d5301
36f96f6f57471a351c70ef66f268f3692f0d4e8fba4a8dfc724d510c11ae77bedf3bc77b9993a5cef71516083b30c4dea1b72b69442c6e210b69b2ab93fcfdf0
c2c27348532fefe16967efa273787e7ed9563ca7d4af45770a8856e5b484519a04ab6fb6082ef888509a4c1ed51b1bb116aea53c8f9baf45b6c4691472ad8aa2
dad3b915bead89afea75ae388186c0b528a955670827ab5bb7f57a1eadc64db56da5f2016775a2270545d9699eba8361a1c6c6bc0544cedc40eb4cb35e825a0a
7267e5996da056ff8030290c6a6bf440e0843efe73c81ded9a942e2a748990c7cf8350ad2e17a452c4a4a621c50fdac0099d23c09e1bdc4407b09d5a9a1e9b5d
787a0823cfdf14e9561f7d80ecfb2cd7f98c9a8880af7dd187966a7c4c8081d87ef66d3ebb93a0bbe903254dd6b6e629052d54866a4cbc3b99044d536e3bc672
cd15d34844e57cd81d93e99f0035897055e75614f77864a9571463dacfad2c78d4589a5a2e709075271d18fe2c1bc29df66602073a62d1f5320cfa880e5f1796
ca0c0ac865ad4cfbd381a6f3b6c5525af18328529c6b940b4bab02ec750c17368402ef7723f9ce3597e3418aa1b468388d65b9500232c8852ca62fba8ff6c19c
55e9ae16e925c969379fb28d17dcbe1a748ad3ad8e4f35340f1812541b8d8035f2eeb1cbb18882888f3a34380bd29887e0f9c70547deb2d086e030fd4b92c221
67122e2994db8d57f820612ead6aaebbc3eb6c40c13d8723a9143debf1a608b34c4b499b4d08a001051cac251139a4a9b0ce663f61852a82b920d0b8e5dff477
4b8b35fc5c78828b7cda7da5fa2dc14d83f1bdca0668908b967b76f04233bdcd042dffcec457c62cedd8b8580df3d806d536775d1397e91ef892d0528d59891c
0c794ae7bcb1526a4c794aa59f8214cf9d14cf178f97c20652fbd838b4dd75a7d722cb17885ead06fec4310c10dfa9a9c15bab53ed588676717a1bffdd29dc1b
acb697ac1d4d4550e53ccff8cb1f6cc4f5b7469b1e170db7f0cdab8d76f9a83abe096c6c60bfb15aed7922e8b4d63b2b7544c5473922efad5cae02b055a4132c
1e21e70a48a6fb9f3a46eaf8b5c0bfa777e3988d3b1fef0d3e5c15e8f76e723dc68b56a3e19b4201df2345033fa2ec7309a15ebf67d39931dcf3a71d323ee9b0
7b26f5cb2bceb773215e66c9bcbe418d350d4e7c8f550a74ad70828955e141962e326eb7a3b7a2cbaeadde52b41df21b89510576571d7fcbcecc0d3d63ce48f1
c6565edb66ad76ae67133a68606d7f65ad7928180f86466304a772d1098af6dfc08abecd34621982798c262c8fcddef547b35c8191b1da5ac73960d47477ed59
363fd8c179132b22a8f8b5351895bb776cdd579c2608b5c0f0eab411ac95ef0d863279655bf742b40c9b3760c95ab4703b06a68ee794da66525aa682f6f528c1
160dbf0e49db4c774b99d9e4f0201a0aa78ca5ddb775ef29b0b83f1fefb70f0cf1b1e0a18d6b900a094e2363dcd70b834af9410e687ad5496605bd8f267ef64c
e0598c6712464536d1fc3a27b0aecf0e0fdaa68c4f342842d91c462de8fa42e15229eca75b09a59e0c5a5a64d56abc88cc80593d575e74ec4f643e2cf63a03e6
168653590d60ef5b0254f8b5c0230a7f78faa2fdb27db6a7ac1e6d23c436dffae0dac1fe9937fd0f99ee4b2fc39b65578b6c9b9249b9da7038ee61928d6f81e0
4c8014907982b25dcc476880ded4cdeb40511dd3481515859c0411a875c82ad0f160f606257b066b98c33c3706fdabfe187dcd1f6827520e0b3c4d52a960d02e
54b164b06146c336745084d4372d31b0cb73d842def4040e6bc5731b5d027ac59b0540deabeafdf2002d5fd67db06237a2b8977ef39d2955e4d72637dde1083d
9d061400a774b85ccac056bec6fcd5afc3144cd35e32c07182634a36b855628f4b2853d1b8af3730deefa1150be1accc6102b55340e08322a746bf4c17e5bcdc
2172515ee51eabd2858eb3fa8b78ce5a6706e35fa901ffd267c5189dd9ac235b556795f73ff75100ab71ffe2c83f07f8ed621af075724616c74a7eb7a1f0f446
938a1130286aca4b87564e8741440d99d4c0e6c9b6859c881b0bbd5790403fea0eef2d6f3a44ded0df7c64f1b99f500e28cb666d6ec1415f77c71e79be1b5df5
df662e31be81e62377ca47929bbe37ee757ad4a516a2d059d5a3576687040a70f4e46edfbc630293223676fed63d267ad47273719f5742587e812259a5c07659
79043107fcbb57a2dcd6c3d0016465d852a067fe579ec9294ed526857ed8dcd80c12c9542d48455e52b05fa90bca53aa201523ac97242380c04ef75a66941e83
44d783519e2d4a840b402711e4c14a3c828239d4819d98a0b7dd8382236ec0545983dbef35b60ae71e3e6e17cd23179c30e6fef98fa2fcd17c846c6ffb7875a8
a44715169c7cfe91ea9194f0cbfedef1c9f1e1fede918957629306600781a2abf86b70724936be9b9a80280fda2dcb4dc1e1b64c009f0554ec97661a1461191a
ee2673dfbdd35ccf9c5c7694093897fa37b00a3a5a55ec258ec40e52e0daefc85ceb01cd7d2f4f19f280ee496b0f7609a84dc1ab6fc55bcfd3acb5562360e2e7
49facb3445b755c63b68f9bd4c192158b0c1b5a687f11be7297b571f3e6f9f5f84c3e26279fb31eea91d550630ce723c8760461a64b4d195a011910128b8bc55
d76abdfe44ccb69c1ed4abe166250995aea7688aac3046d64f02b6adbc11cb0325c1d04bdeb74376b54f6e306fd757c781cf15f773d4d527e3ee3d5d0e94ed32
6bfc94c98429d7c8b2fff7e41fbd9b89c4f1793aafaf7955ec72c9682db0b5f9352ea3f3179db3f6cbbd8bfd17a876aed777954da065a7b1ab2d02211f7ffe66
eb4f9b9b624c20cd14076b6612c45d892558959f5a5b95e396eb4b34af1cc21b6acebc72d90a1c0ae695fd9663f03fafbc68794e43f3ca69cb39b5cf5b4cd22a
17f0c3520ecc2b2f5b42e95f5e5cce2b072db69c17b1ef7c9d1fb564775ef9f756c4c705d3390e2a953dec038d0850cf16b9e4e24031297507a1eeda737bca2c
1944dba4f9fd26ebb6d26f36d2246d7452a3ea6a89ddb98ecf8a36e1ae993407874035925aaab1c5b95bba328d390eabad05dd41c994d87edd12af019783213e
a0097d599f2c063acb88a94701dd9221beb5f57b0cce71d958a62aa1c893c80a83638525a53227f5d98d6fae33b9970e3fb1034de97f0c629fed1ad05d495331
ac07a7ee40bbfac03377aef0c8c86e6e905bb52f714057256c6547592e19a11d90d6cf095c2032d89bfe10ae0fff321de9e27d5daadb45febc7f73af3f225a16
f48c020eb1f4d60ed79e27ef33c236c4a594f5d693abd994043c185303c5940cec0c175de9061a7ca115a0d29c2ad0735c78429b610816ca9aa52b3e9a3b5ea4
1b574076df5a72e8f3f6d94f87c89f14ca65a5622d6a5d725d0b6a7b572997bfbc973cf9c92f06fb110b9304867298fd162db0a47c8e74df5889f0c0e06ab9be
a5dde0db87e03bf1e2e90e7b742186c76d610ced585d9812cf739d4e8571c266c8b5fe140fb93076d7fa3ff3d1707d92ade7b783ecc33a86722a0cf754217cbe
20c8d3aed53e2cad890436afb9e9b65fd7ed684ff50ab91760ac3f9df955aaecd9522c141d07bcefca900cbeab204bdb9b6897fb5d8bc5acf0f7191a94ef84f1
c352658ca86efda92e83ec7b212b948c7fd0d2b7ac0065f40b05a026410c8a6ba965af95aea78e65565adf898742339d8362a057e8600164d9bc6f02fb594be1
351499d675932759f3067625e9386b9354cccef71acfc9f23c5d870cf5b23ee8f2d1d13e95385d798b975faacc11d21d6c0b0e567d9dbf686623fca4d80bfe02
63a93e589c46ba63cda63d5eafadb49a0d09529bf154e9b1f53bd0d975a024b8b25ab844ed85067bf1920098d8d90c096d97a1de14457009140f4453cdec3a07
30ebeb0f709cdde5358925f6eb0c2ee5bd166d9d263dd4acd861d09416cc135a90c1feac4d6ed2da5fefeaff788077597edd1d6735a8a03e6f351faf093f2393
0b199b1c32bb869d884de44daa5c30dce643893b09f99648916a509af9ec0a72d1a7d603371cd6097e5ee730845b14238c07900290e1ada2468ff8eb9bb4a922
3341b2348843462d8543c68b3bc66f74e031288d628ff984c9369fb3a31d5824d1bd5198684b9e84b89f3764821b8d5f67fd78e45f0795cfbf83949515899710
0458590d30da0d0ec861a3f2ee0d305add7c9960507ef52591a182b425acd1f622d668a5615b226e8d5f1c297e3aa8c8ea18206d05541b60d4da88d97e4161b4
9b481aa38f55cb90a300cb296de8a57748db47f356d5fa301af458b24a3f72821299ccc6382cade148b1acc5b7e5d0937d388afab27b5a6e42178f69ba63170c
2524b218075b70af3b5de428af24e7aab3217a82f4bec55651f4aa98010a2c674cbb8a074ad55d603b270db04db35417f57c102c266b50cf18735c825990fc01
883f51af66897ad551acaec35f298ee5b68ccf844522ac0d9b3ee60877cd47392909edf82dac3f46b44318eab75936cea538324f9d4d61f8d06411dd042930cf
06baa04f32e644601742a347702b4a904550f18fe024e84e7aa3f7c3a67db58c9b63045b9bee630c1d886419565324acd4572b524e4fcac595203aa8ae24426d
5313db4647768a0561d2cbc5bee446daee8464354b82960b6c539697464e26aff1a537c4521d64612c6915e9e64f76a01b0eacc0916e500913aa8dcaea427220
8487224d03957fe2383897dea523211857ebf65223198c87278e54a17b74e85d2bc3964dbf958d92100c9f702b5329be61d9e458114595a21a13548616552679
99b51453c0558daaa2d4efbfb6b049fe5f9be533378b0eb6ea0b214670ae75349cadb8ab102b52c6c2288aba908b816e7e9544a4566a353bd22b4b2dbd8465a5
b340628d9481fad2fb68f5fbc317dc37cb6e183541defc920fae999ac52bd0f1e952d1988b44b5b1b3ee7ff1ddbbf2f87df696d77b9e81a93b8c782dae61fef6
7fafda6bfb8f71d9ae0b99ecf3845dc9d28028c4fcb15e1ae37d528a167994bd1cf560a5ab2a0afdcef80a24c632a96795aded742b2bd1a7188c75b98170800c
b6b9b3b53dffefffc7ff6335a1b438964b0b641694a8c0ca4354ae797589922886584ab17f2374c9c8fc29ba5a5c8ded865ff726f17c74337d8f91dd7939a5d6
f03626681c777ab077d1d6cac0f30b788ae8b8193854125322f5a0acecd5b7177bdbcfbe554fedb3b39333f570d6fef7cbf6f90579885a459db96f9e1f1e930c
c57ab577a1dbb108fdd341008df6ad644ece6995e35c44f660d651817b105bd11a889dc6e5f18fc7277f3b9e57ad4f322ce43a6a65a0d1c19796fe5f3903c6b2
329d8fb856b2e183b59bdccc91d5acf75430f40e581d47128b9042a4354aef8e40f3ff162909ca49bf79f473e3d15de3512f79f462e7d1cb9d47e7c9a3ff2df5
57aeab5f0e0aaabac619d1b942a41ccc8c0daba20ca03f8c515cbfdfd602fbdc8e5b457d66cfad921676fd3986eebb5daaeffed2a2fd58b0b058177ad4cda7ec
ce65b58eb255c3f8d0855b08bda0734579b40f07a16400ff06c45bdc930b88d6cb984cace86031bbd6d5884b363940ebd5684dd45da56dd40d0da8a4a6edb4e3
d9b0c9b8a6607d8534738fcf1ac2b796df4c3fe5e165fbfc1ce1b2e5d1219226fd99fbc62692f2ea5389e4125d2b99ef133d645894d5573ca987d97c2972fb60
8f8b454ec365ec8e5929853ccbf2d9604a7c869369a9656c750b9772e08d54bc92ed45639f123cb0b2d21ab4c116ac9b8b84b6dd27ceea52758703bc984098e0
2c9a4a58e481cdd05cb3128c5bd4e99225820e895a29338577634f9db7cf14fba77d3d503f657f88c72c8b441a838e4227091116e8452f69cceaf3a491fd9a6c
8a1449228b62baafe9c3967172c590145a458bbd6a28ca814262b814a418a05462486fa3e76afbf887c3e3768b9a461cfb468e2d0cf52d95ec0309a1d930e1a2
7d76bc77d4393ee9bcdc3b3c463dca8fadad8a20186e69fc42890f839078144d836bab2634e20df9da988c4653856327b4b020037d74d2f7fadd37c311c51d29
c864a570720e466f8ab2e02727ed1486ae202d7e72d2eaab704106fdddebf7685cd8ebd1d8ab014d7f0a8bc78f5e7aba151666a0af4e0ee62a1ba593e1a47172
1beca9f21282744e298febb29e67162efcc2358db9090731b6092361d19dcd5b2977719cf5461858ba17eefef3cb8313606b958b07d62baf9671f36803937c2f
f765ec2005b3825d3c7a9bb1fb396aca06ca83ef6a02ef27047d8c228f6e32eee6f9fbd1a487452188a3245018b9d907b8aa0dee49d903155d31b63fc63f4445
d5b4d11f26d0dbd1fbc6a09fb38e69388292ba93abfe748208722a440f05b447a948afd7c723065a0b3cfe0ce72f6f56f68e8e12f87fab8673584f8e4f4ef7ce
cfff76804895f618cf2bfe005953f2f4e9a63fa2ecced3c7b14f1ad737c180bb9c2b691d4d1cac58a43e9e448e7ee80337bba78225145cfd50f03cb21d6b2af3
213815c4284b0cc09cb4da6ab7835ec09df3f61107368fa63d6b930f13bd04ee0223b18b21165bc7aa27e012d04a4b3fdec1ce91df6889a57e8f72f56b92a95f
e25fa11fd186453f901a533fcdaec693119eaefacdbdfe89e285128b315662242d7aaca52b06d94ceb72c04101e9e2332ead5cfc1dc6f4e8b47d46190a2ac3cc
ccc137c8278d5d53d28a7034cb15a06c6194d443dcab105e60516765e43714949850e2acb7fdecd9d69f9be3d915f45bad07e0ac4c81efba3002fdab58a14254
21a77463d98c5c7b4e43ad16285d1f5a89dd860d04a54488a386460ea519aa68e80718b083b3bd1f4e8e1bcfcf2e0f2f1a67eda3bd9f1b9a9b8394b8a4050b1d
523ff9f39ffefca4f272efefb0dacf4f4f8ecfb1ca3f75363737f1ff15b441054a71d6fee1f0fce2ec67150804af2f8767ed0348bba5d35c1ea3f4aab3777ae8
7e676164677fef74effbc3a3c38bc3f639bc7f950a0e394282e2810bcbb5f16e2b5d0fbad8c8ef87d78d77dbe9eb4aa5d2cb6e14407a6d74f54f310113c92ad9
3df66677e31cbfa101c0648a786879eb6232cbe0195d29d1f52f6fd5d275ac6a07adf9b85427aad28e6d09c6dba7494862daea8caa2583b0335655b4914faea5
ae918658688819d8353af1998ddc84ab45cd30e7292d696469b1658d6b1e0ae06dbbbb86e3df221087774963133f77e01fb4f3e316d6c51e8f49e8788ae41568
ea7836e5fe5bae73c0e85bef9457c03b68dec35c4beed1ca0ec5f6d7e3663eed4149cd7c3ce84f6b57e92f9ba9350c304c5708db0d4931cb8e23d840f33d36db
83c2f1b32ea4058ddf72a520d00434c16c32e2728dae1e792bed03ef39c9d2fa6b28828a2a4a602f06284b66361bbee90fb38e48d1d4044e27f7a6a5d85d8cc3
837da0ddca14cfb696557589155d5ae78e602e6751c888e0fb26a99472e4326a299644d68f9640bc554dbd9c5607b8041aacb40a63b55d7fb5f55ae2b7215792
b4e90f86223577dcae18ef4b19a9205ea7ee5030885e742424a39c694d49198e0985d2abd5ebcddbec43afff0658c85a7d41e3549b5463ee80e44dfadd410d78
507723a7bf0cd3e63f61f39bed51f3dcc826984bec7295987e1d51c1ebebc5293df4c5c5197063c324de8d17271d225ccce264a3258a323c3d7b74756e8528a4
75e41de18f9b5911443322ecc8c3c91fe656729ea37a933d746a8af829b7150b44528c68772a1a735fef3e6074b3494d5bcb0eb2a12446bde5b74f89bf1dded7
ae6f897cc2964a37b7b69f3c7df6ed1ffff4e7eed5355498d28e8304caa677015535e20885896723db0e617f6af11e34ddb2bae50314c9b7658eecec5c369023
3fdc57af85f6cd86e880fcbcabc4473679c0221cda17ec741b97d3dfdf4845bb637450f2d225df2496d5b2a14bdc940b5bf98852adc252b1358e1d331561922f
d980e9ddd80c9d31449617e4eaf84d923695b40989361b244b66db28d9ec66a8bc8ef9e0858c7b2e76ca90653d616365f541992bd32739e1bce52a8a1b60d606
fdeb60d1ca00d02b9f0a85848f90a25bc2da37afbe7d2a670c655fd76808746cc6295d42e8d0d79fb392b9430977889c1a68a3120bc1774ea880438e6956b789
f810c009debdedf527357e501c0ff12c9dd15babd53cb3567633bbd64b7f86a3b3cb67000edc82d95cc0f88c6039e639d1ef316e5f647f6008fa43fa457f903e
42a9757c311cc13a4a2d6687b9939655c141fba7e3cba32327091ce08549f48eb94633795c2038f748ce36cd7462c76743342baf095fe78eec674d39b9af49a8
6b8b86f9fbc04c91da0b22c0a98de0abf2823d1e0d61f2c5a0a3b5b52d1be2fae60dcc83c3e886fb00171d6c039cda26ae3838df6b90f1954d2dd0f5c7da01b5
1fb37beaeb7af213ee16fa5d5f6a3bb0c0c60ab9600700431e9447c95ffd74d8e29ae25b5c538e4968ead6b78a0bfc15b9595db9e1127612755b32cb23e00c76
12d567db8cc05e74166f80f022d31a3e37f19f9a7db80b5fb0c34db6de8f301f4c9ad54239b577b4d3359dde568a3863406de5833f8adbc79cc37ac5403bc0e0
bc4aefbad72972d428af680eb3f73562d51da66cdde303436e4f514d15c707638909b015ffa9c9d3def30e308f17ebeaebf9c9fe8f086ed4de7b492b055fef58
1a8eebb74db8fcc812aec9dfba9b002844afc68bd3432485894a946bb84e2e732c39da4106f273532369bb58331f65df9ceb7ed97986113e0750b6e1c5f451a7
b92d9389031e5de167c524d150a28c10f92922aac977897d3377cffceb5be0ed710b60f593ecfa5d0de33f7c1bc01d30ce2fa40d2f1a57c013b9c02bd4866f5a
9cc13e44f143f94e4623aefbc4d0ba49968f47c33c4b1d3e91fbf59796d331ea753016cb9ea3aa22a246590f25bdffca802bbbeb4ff58d30c703c8728bc4f2cd
6d764837d1579bafd5bdb2ee7050985d98f7b76939a3ca6cbc4aceaab3f5c4692c516b418d4ceba626934d532ae2a7b5680796a049c3548512d0cf95074bc3d9
02b1250746192b754475802a10968c74683c1ad78864f0edc589231e1011b309f2b159fd8ba9890c381546654cd01e8712d8ed5ad735d757ee37220e61cfe5a4
55f360dd02ac8970af510eca4cc87ae25021774d5983cf1de028f5f58dabc36b4b878f5b272fbdb76e623a9b1e239591140dea01964240bdf0aca609b36e2c91
ab9e2ac311a090389e580c369e54e28205cc5c367c875596a838e1338b125082a544b89681e69765ed2cd3d6d6d36736bba7840da800b878f1731af27f2de0ff
184220bd3c56c934df8536befdbbf1403c2a77ac35248ba55cc644b90aefa5814449446c54046b98a67cf71cc0eae98f31bb7509fd3a2659728471b67c29228b
0baffd524d90eaeb846c3c0458016d81f07a304564f7fbe46a041cc1f7b0ef9545d4a35fd9078b943491b22c3fde667240f4988368a35944823abae42a83b124
f48611bb6af5a7c90818e8486916ef3d12c38ed124874d83e1b7f22cb300f1c81d184bcb67d7b7c092444aab8e47f9545405bf281cf62a490530f01bfba55d1e
3623685f7a0cf51455d7d26a9dc6823f0107211fe07d387774608f7af76a3a5e6def34441ee8ffe72cbba239e5cb1b9608db7036bd69fc09181539ffd2d9b08f
3f3aec229dd6a3a509f77fc96979aa88f02e5139541b240ae51a4b7508970422b2f1c2e1052d977698aefe07ef8616991a644ca8943a05f42baecaee0265009e
a16c68cc6d68f190d87bac9afe52ad864d06da4208052ab57d077b0e9bef78347d8ed21eaf465f286c08bb80c91822b64e9c97ac3ed255b72c5aa5df7e92c8a1
c8a79dc40c46bc40e4cf16c64d6cb225bca18b00a0b329c99676b1b74101f08c65f1507dae0550bea84a0455545a7d4519158f118f6c971ca61d71544cccaed3
e009bfe95eaa2feec75978abde097d38acf3c8b664aeb93275fbbcb2b493a85224807251f5da0bc3298dfe5db7e2d1aeb36918fd7abc2e8179e84998dcacd722
11ea3abbd698c71b316d55cf88c036e5076933e2cab6825bb502446574753c658571cea67c4a47c6c0bea55ad200db700e2ed0dcb9e0b3a869208142ff846952
0d604ecb4bb9ee4ae753c7221c2ba2512a2c46d21594421678d4da09aba3ea7a01f225264dd2faab9d679b9bafc3ccb6c9298a1862d53b69d66916fa37663a85
158a76501baf16956da5d025cbba2829d7328125190a6553eb87f3456bb3f3158ca62ad1168c38bd554c16ae9e57d1217aed8a8f0b121148eb7b55beea73b474
6b908acab69358253ba4bc707f0b7db749061b5e2c24199e19826b3becd10da74824f1ebb2c1923b609080dd5734633542b1126d88f4ad801458e6ccb820b0b9
c1c7223ae11a1dcbd6944e2eb53923f6e0c1068aa5596e730696e54565afb83943fbf4e5366724df7abce81537676c88820d144db4cce60c07a9a8ec653667f9
4ef2772845061041440d58944997a4fb0b24faa25468159e881612707c9f28eb1b7ea9124a175c23250781d3dd5bca0c507930ed04c618eb61623e234d5a65ad
60256569012451a209eb9be3510949f8d93f8b603bfb4b4f3232da6c3c63d131afea542d8fd5193fda25278b0aa319f9d42faa91176ca78b0d16a633de61b52e
eb9152d49e5d548cbd719d72640121f1c40238b298bde589bafa7db0961dcd54245f7ca624a310da784e45938b2b0d062e5e7f74e0a494e8c0458a291cb86bf2
97d511c56d5d8e83321b7443ef4fb572dc0d2beaa0e8d2913ae166dfbdeac36db99fe1e047ccf43ce24bd4c7be56d2866ff23a61dae408d624814dc9420aa659
0dd662a69c8e2e1121e9ab7b74d172d10e4b8eddb7ec562c69ae84254aadec208a62ae9a65b3dae9f7dcbe78043eb472cd53784f1a6db7148f59537d9d0d3b56
c2daf483eae007c2c9a7823ebc4addc2948a36c291b9368ab83cce2e8f8f0f8f7fc09fd7a3d1a4471eff3e281f2326a17e5601e9a686613397fdc8d43c78f421
6c804f09ec16059b7db536cee5a2dfeb4f426bda82b9c191d5b9969572f0ea10a10955e74da78933103b534d76a3303389793f3335ac33d2e5fec9cb97871740
9c68064f1065ae8390ec693d6aec52565eab95a4cff70ea184d4ce4b7bc5914285611564083b1376c483d91195ca7a61526fa1eed07047922bca16345b933509
e16bcad3fce6e05eab76d60ba21cd463a36420e6cc1c1a1850d420a66e3a5b7aa4d45eb81b7502d8889e1c497f72a4490e8f5871f0f26955986eb89390aabb49
7a7ad63edd3bc3f5e026b838db3b3e9783e8f0203adee9dee9e9d1cfcc75d3cd0a7ac0d07b5dc481f512e362c395e6a6d7504fb12c4a74915a8d9bdbca18853e
d24aeeba1f6a5bdb9beb0505278de0ee977c933c59cad2487b26acf31810ed8cf4b7ee7e711b201ff52cd63f575d757a78dab674558815eada6b2bf595fcb587
6d494a12516be115a7801418ca62a8c152e7c8f9e5fe7ebb7dc024c9a3cca3bb3b540aa1d1adbed67bb6535fe4e470da103b3be2ad9a47c98164e4a02a2ef921
a56c8d6de361424545ab9464af1a4f3637775ed35bb74a9b5a09895afea01622ad0529d1b1ecdfc426562c2b6ace51b16e4f767da77c2a0a29fd02ca6e28b9b4
7afe2539053d24e1649bea14d728f85ac0a623ad1e6430e212f9e7438d5122356f459b0adf8825b8e5a464db03484c208b130bd277fa3d57854f1e9a4bf1228e
190ae48a39a128ce16dba10034f786ca17522066ec5537bded0a48698281b7b389adbdb413f615e2255a0c64cd24399ce646a283edc56a29780c9a558c600577
a93654da5c417337dea365496ff486861e3d3477a5c4bbeee42daa6d052215a92b6a68fb140c1d7b7b9531c6fe7dd66b6a45903da87838c37acec9a7951c269b
6f06a3ab5afa188e7c5419b506ddbbab5e3719ef24b849bba4609f76ee3876f60dbc5483c9a2aacdfaab1d54a9ee440e5fe406bcba23ccddb204d93082b26cf4
66f58e6a5a355ec5a433b3edcf8bf843c30ef0e94eec34fd3ca497b2715805ad9bf355cb2ce91d0fa2440b572363e12c8bd4b75dd05fc3f56b6170450f6dfb3f
b12e29372e11db12635aa28e6f09169dae1368bab4c83ebd5d878ca2937c097b9390c50c383c8bb17b78fc98e5ca8a957349b4e29d52da8549c8f3cadee243cc
484a155dc2e955548911bef894d78ba260c15bb75d5d587de5751e5fa0aafe4387c7b0fcecc9a84c6e20919347425e941d3dbacd73771686d9fb8e5077a9a99c
c07ba694921dbef3af026a6f6f233fb13d0931566bd17a49f482b1987fe73668b86daff3fab090ae572227081d95124d457c346bf2577903e950886c1e48df5e
a54ac8fbda1708073e153a8ba421e3b8d751270b8c00de4557c6d27274aa929254c4339a7ac9a7dea5af2b5e5c349e2a3874ee80e9a7f94c23f8e9ca7b580a4c
d9647d5a8b95a285e0649a8c256e955b2fda980d52816e9e310674ab527550f996d2da4d0514518c4795d03d2d6f8a5f7da1f968ff26d2ff3be051ef6677dae4
d072d8fbf39f6128feb2682454f582d20dec066e28605c94e38031992d6e45603cbfea7ca85658901b5410bb9ec1ee5f6a30845ee5d7b7c03aad5c77349e0f97
e5d7ce86b3689bebfa72ca9e8b5adf4a9eafac2d223a0dbaca98cf6e9f244d7db93e9091673ebbf31b6cb4d664843326af7920746fc8fd6969311c47096b2581
129cca81df376ad1371e6409cc616c5287483014fe8a85e84131722243983ea540c89d5a9d72dcaed434bab2254e8882a53f2ac192d3a598b84a25a8d7234d76
ead49f3ec5ad6b36a59f0d3e5a02272f76fcc203c5f271c24f93ee7bdf13cce912258296e16ff9ee76a1fefbbb8a952d7f73a2393e5f8e257a6c645fa51a1b40
8d03cf36f4afa45fc5fdf9fc9e9049ae1cb5411f94efaab806d9e6cfb29c5777aeff74c77ad59a62affad02b06ad19289b394b4b07e6468f8ce27d804f1974f1
c07ae082600caa70edb63171e7c69b21d13bdf8532e0e112ce4c26b1c328195a73e88a2f7a598e71ed348766e4185e362d9850822be5dcdd9cf08bb4e9864592
924be50f4556090a169c5b55a0e85ca541bac056d82ed74661b1e3664c8c7296bd81f3850424a8527a0375a579a215a7ec8031e8e6d306a12c681dacb250ef8d
d09e5c8505ff3a1943d9b05eba0358ad39f44b055ea4a07ca3c9db66c2d146f0724ab12d5130734e33c6fe8f18ce088a94e2bab0e15072a13038c5325db14984
e9cc8e665dd3b606357f90996835aab401eea47b05c88d2dc7eaeffa6fc43e85b7315e1cf4ddcc11dee969a1343b7ee4ef16bf97b81ad6fd7539411b946b7d72
6f522cef80191795a1117d58d7dc7299996d2313b79b29b22051ad734aa016fdfb65fb921b7170f2b7e3a3933dd53ed8fb87cf7f9687251bf875b227f4d55e35
18af6684048682572a090dcb08344650b2f76ed4c73bc474726f560fe4ce08340dd6648383ba197e7a8471a529434210ebb0d6ae908289ac6e747343280ff8c9
8e8a230e160c54ce8d22d2ceabd75acd7aa7e0b2cfc718d8276ac1576270648b95686a0edae7083ac4376b45010974cd4926e27bcb318746b5d39db6c480c333
5abb482dc7cdaf9363bccd0d9ca1c2bdc2e188825152a32753a7fa6d95676613266a8887c1a07fdd9faa913abf1f5edf4e4643746afc7596cda016b4714722c6
5ba1a5c5da76a1430c9944d40641e680de5cdda31f00ad94ee54378f10fa877ae21ac6c08e26df78b2a86675785184078bdb284dc649caa15b98563c718a572c
365b4f87ea84abeb6b5809be4bbedddc890b38ccc671ec404a59d6cf7260cbb369c343ae42633e5e86af7db4179f5b7375807136f4fce2e0e4f2c24d15d116da
1ac3ad3f6dae4714de0b783e57f355d3f84ffec91cb16f6d3c43b5973b2521a3a40a47c2a02d9994d1226250222fe4b41039225daa44ae9545e8f0199fc551a8
881452fc5711aea290f3d3bdb088b3d231f528bcb04b945101f3a06a42b650909a5c7e50ea777affa98c4d785eb34b31ed94a5f04c6c6de8a4069f8a4d9c2b51
21a6338c6e3fdcf5fb901ad3021b5621d1447e47cd8d25ee54fabef5421b8fb8ce31b0a5d38a436b845cee5b533497efd682f7029af895430c8bcefb2275b0c9
e9d86c7d9a0d965358a1fdd5bcfe7bd250d3a6ff3082f92c2098b22dac722f3871fbc398590c6f9bf8e3b3afc8c029bfa8bd820bfbd6f6537d6bc7ade4925846
8e30f1a0b0793d74dc4b4b4c3aca8d359cf9768c24c48f1529924e546aa6619b522e320f93462852e8adbcc2f491555a98366afb5198dab20529e878a9bdd867
9d8b7ce0996915a6905153a817c1b1b71c3158ca2ea460e23c733265d9cca29c92295876aa8a4d362ae5f3a3fa52895a05065fe7229e7309b558273b54fa7d77
388d0a47e448e9f86e0b8ef5864a24989c8b4be1846e21706be85fc7d868051c41df250f90c75957e9368c10c577a5b03fa32b8249a23c286c410e0f42d911f4
7572da1f0e61a0240c0159798cee80b7b9460504d4fb26434c232aae6bdd5cf435b0071b61249708bcae49a7e1101c53c929b1f8de80e219293d2ebd10df65d3
ae7873d903a85471b6ec80fb2a63c22e5a9cd7555f14f0895ad3e66472346db2a250d15b18175e82c25b8d59a02f515758255494b8c2dd77b0354982a32fd562
e4730d8d1b8cde303da10941a594389e08075922e0b0ed991c279ae2652a7b5a2f6d2da950b1347478180ee88b60e1a439bce933987b4d86715d9a599778bb84
a6ae2553b0dc6055134bac24abd311c5e4656808f422cf33a81397a6d27ab2e42b9ff60783e42a33720f0140a11144bb09baff0e307e9a2a9bc70f96fdcd4d46
7b8df55e7a1d2bfad1d29b1197b1b3f35ad6343be2eb9a650de1c8929839942856a8480e2d64a645ee48ee1a5c22a35a13269fb71ecda9e3ac11dd3eb58c5102
a67dbf4d49cb310f85b71181efa4d083033c6a2bcb8c811e749c8eca129d7766695126dbb4cad81c3a76f7ae7e48b79fa35847b6154eb8c808773e6584e2cb69
8945b1ec8258229f6f5daa649eaec8d396785a02cfbacfb2ba8b4dcb4f17ac35e346cc5a61c61328bd0ed523b2a158135cc1ed82768417b1c2dacd47a6ed2ddb
038a0fb075b8051bbf49ae676e501d95c5bb36b2d29638f1434d0e337782170a36b4464b54ffec60d313e22a129bf77003220a9b60687324a1a4042c1d585b04
fee587551b0114d83195b7cd984bfe064d5b7c7b764220388a5ed31ed388ffa89bf2933f7faa6871110b121337c59d626d1bfcd5ef61b27a6fb3c118351271b1
a36f03587e7cdbc74191419fbbd6f451a26656dfe0963f540b453e71bbfb129eda0288a30b52f48ae1242ab968681328559ec328bb25945025ebc61d8ca83f89
aec4d5d4acb9cf3452c4834e37df78709b5528981572bcf1605aedad957ae53fdfd42fb33317ee01c522fe76cca4a5e7c2584dc638f13eb9edbecbac79776288
24624ee972fdb6d20c15fc4d3c00e95a31ccde0feeadc2e87342c8c3acd59bb2ae9e4828d10f84b1b5cad3b27ead43c7258845dff42708023aa29851b3b1be2e
8972bb52087cb6c84afe55d4983de5a8c3bd06e42103220e84ce3fafd105e37a9ac6ede06f2005c6446f45ac5f2d343c154facf13022b5e9b8dfabd5e7056542
9150125f5a5bdb7951aa05a183a83ab6c958e722af6352c2887dff1246602b804b0622e4cdf5024250ec6beec0b47d61adcd676fea22cf31e540b2b33aa553fa
a3d5ae8e25644e15382fb4e821a920ae91da02ec14e46094699217985c28dc7d96a7111c36c7d645b3f3681f80bcfc5c975e133303576a859646937b65175c47
f0e745d197bcdb59ac58e6e53bdd71df2d3212aca95c1ae5f91cb36d8289ee86c1898740826740d666392376bedb6e6e3537c53ab9b1b5218d6940a58d2d6334
2db652dab29902e5a195d510a10f528fc7b406780967be556c8d6ce1a89dc575c1720d8ff4d658c1f868c5e6582fad322ce807bf6d659e87c6f3cc6f85efc5c3
2817500d2c1b6c0556486e72965b8c7a6f1cc882c6386293a5e88735c1a18229ae645a1187e013b00822780441573d5402e5f1083ffec94c239968b1463871a6
3aac6f5ec24aaeb27ec235c4ee6045eb1945f36a29174e8b226c1825759269afbae4210d46d35ba0119092f9efdc39b539bddef9182be6f7ffdfddb57ea78d24
fbeffa2b7a15124c26f8157b66d72cb34b6ce2f199c49e057b76733c5e1d6284cd09060641122f70fff65b8fee56b7d412c27676eeb9fe90d852bfd45d5d8f5f
575755564d83cddfff8f319b67a2ad1078f4b413b1c20a04495ae82b3295c8d3339c900f6184a73a62d443089c8f208ce6b4b28d9c5e865106b59aee0e2b7d77
2b3ee164af5695bd95c54664343724673a50b33b5d783345b1a37bd57da1a8e80f6714d603c3425c0f66b489bedc86a4a91bed69a756edce3a92c199e92c44e1
f5640f6e8a33741b0739238d4879313ae99b1742218622b70c38704b23585b6ae2c547d8fa9f2231820e9570ec265a1b0d23beca4cb603d0ce66da4fd67d7619
670eb75d5519f92be2aeaab14058307db0e5f25e4da1b9eb7bb03a3f28c3673dbf52cad5c6c074e53724025ea673a0e337e7f8492542e9e2957667723c192b1a
aca9cdcee4e63325b2d8e5481af2d1e5ce15f199aa4a6929b9a33d3186f8d61577af92f380820c4ba912af6dbf3a76ac35deef5d390628f65400c75c299bbe63
cbbf148fed40ff27b979d1280a06bbe29bbdb483af11780119ce8033ec7519a3e0164d9cbedc64934f52b4d271ab3ae68b1b4467f611e56036f9acbe2eabaca9
cfd04a7f2a0dfb1e9edbf4ffd3b18d71935264e0615c21b408d47d647502cc3784f36e0713091865dc978279ed761f44809c77c8357ab682bceca72b6d4ae3aa
5ec16b79f9be802bf76f51f7402b44729e83a2d3499052146cf45c377de5980ec41c9a5d9277d420ace3ac3344909ace1d6026b05c01f9c704012d4a10206b09
02b92c6c66b5099b697eede34d3c643c15cf95e6da9d1a5b4734a2f4d82a2d3867cb8397a9dcd87885cca3acb2cd703612e3fe38443dd99bdd75a24f62fb871f
3ceff252949e896af83bb08eab2bcc084e59e1bfdff3ece81475cc46eba9c051f0d7aeef1991a1e0c16bdf3b6c80aa826b0b7feef93291747d75166999b3babe
66ae6a18c0d979bd408a6647eee9c8a379ae17869dbc7f36ce0f7f3a3a3bae174872ad8350a89028dee14f8dd3e326bb43a26d8c13f2692be792399fbd6d6231
0f760acce81c3f77b9559adb2bb3f43d12f858020a2eb7e24025be071ae3af2767176dfdd28adce1d3fafb25bb415fd4ff47fc1bfd581ad5b79d6aaf7a357ffd
fdb204e4c1a51511c4e5aebe8bdf1a44912ab0b1218cd740daaa2981b11e25f62aaa5d51bd03eadcdf177aa6bcf06b782dfefc23ec8578227daf87efc49f551e
7aa90c49a3912d337a46d42b23d8c34cec1e5461d66cf352262c611bb6fefc77cc4fe597a8b69f2a94d81baa74621e53d5f4f65115f454a68a9a7b4b9536a736
558178a12e4a9f9a2ec49cf7c86c748394e1ef9e47152ebe248e33a7695862a6067e4c178ec5f6f7dbdbaeb7779f45b59778017fd25fbeb7f43c921ba23a8687
4086be279bfb819aa327403cd404b3025fbc7821ff563cc537f9d38e773d16d58e51de2f295ad7adf360e3c7069108654a796a8706847bfb6e61807b5a15aca6
3660d59a4410037f1206042f24a4ee97acae7ca1c178f86d38aa92392124580fff8bdff4f2f925c57c7cc76e4dec39e38b6ba82a59b1cdea206e67030e77dd99
b03f597fd80d11a948871a506c4ca8919b0eaa3c8f0ceb40a7b203a607a06ce4aef88d9666ec18bdf48a8d1b103f6e75c3cf5bc319b082dd1f5fece09a4f273a
ff092d7eafef79a02dd68d8947e6a2d9c98f149fbc52412a8a06e8390684bea15ec36c7fa9546c7a50568dc7eb87d233c79f1d9a63e1e60bedce4e1105e3ef8c
e9d6b50a325c175621bd70361c86aecbd505e7fb01c34dc44932c9267705ccc11810df1f4101c9f53b81edec3d133fe37aabeb8f660a380a208b21004d6383f0
6cc4aa0732f15407c188efb7e52549684fef822ed8dd74a35c88b73066bcd43f1df19681ad7417827261dfcc549e9afce55f40c06d7aec4b735013dd918285d6
982b697a2467c820b1e41a69f3c238988219e0030c98459964c1da4a64656fd01e0293c314d9bca5e24bf3bcb976bd2ec54dd6e42d4f0ce46ca3c71025a6e499
0a754e2f9c2c3dd3e9792e7bff25ba2e40d3df849e252da714f94ced3f160369fd5fbd7b8015e052f56de57ed752255fafa3db4be5f4816a7a5addb5f4db87e8
af791a6a6a7b4a0cb12e1115d452265ab3418d04b6832a53da409cb53a6c8a72b4f56ffeee8dcd9795d2d66f3b5be3725c0d971fd55c23f3178d4c36e4a3f918
6316402df62b93447904c6967eaabdfc5fda7a732fad7c1bdff79b3c127c80e2bd9626edd2a29f8c8b3954ea6c753a5f95ced8f36e86f106ecc5a0d53c3cfbb5
d9fae06219568187a0078f32c01f68f417e73c64537469b9cfce2df3611bf584c654dc8d22f4f1b123a646b7a4227fc4b4c29f29102a5e66c10064480203acd2
9d4d48b7901eb2af504be0d80cca9708dd674dfc33cad00a94aaad68891441680ec1f3feb5ccb049f72342ba0641383946491dc00e8f882f31cb3a79dbe6935d
6450514f3330b67f57b3a6a8e7e44bd77824a3ec604a662a0da785d2981752f55ab06a5a117264d4648df98ba8d544085341bc45fc55fc75a30756875e99ea1d
d920d35bb10bbf77beeadf296360ccef45757a3f0e05fcaff6ebf3f3bf8be763dcadbb06875950a058988821fc7a3d83dfbab09d615fed562b4c1543e89bc799
a00b3053eba539bf7a6e889aa5a7d60f3e0c0a25811465beaac7096b55631b776ad3c70561aff356586e62185dcd46374b25831d6416896de08731edf0261ce2
0daeb0aa6e483a78b5fc0c0f0fb322f4f2546bb7f5d298244d746a3690a8781ee4a95ef8c7d0a4e54a011d636c49a22d98d8a867adb39189739e8888bb424615
04897008beb382257c709d4db702e22edd1cfb4285cd8eaf48b2d8897a0650938672d4eb5a0ce2a847bc02ba5e8dc339eb7dece549135b22594eee9624523e57
5ce27108f6eb04827ddafc6720a505a9b4e78dd671f33c8e1a865aad7cc6376258b56595d27c1eab89ea665f29d1d5e1bb932212e9e414a80708a7b58ed48319
c0ad06d3fccb87fa16c6becec18db13451281eafe48a663e038e2c8858d78c8162035d36de9a3ab852a6728171e938aa185731343d512946d3d50952b371f40e
96376803d59d1eb5eb7bfbdb8f43dab56278717a72eef2824d0c6953cae9b8a272b67bdf68ffdc3caa93a68184ae92451aaf83e38b46ebc8937b3bd08927941f
1fd2b846b3d195d080cfed6e40974f40000c405e4f076236a4bd52d5ecdd507ff12bf3e116bbad6e27bc830981a9c09b93abea65cf89c41e961ea84863913b01
a2f9af93f3c71d0e90bf84a2e7a0d70f07ddc4210106902716e1b6f1e0c32cbf4f25b77c905b254e3e2c05174a2edf34f46e49231beed8720c21f1071c599015
17076d92f79132cdbef8a65c69c33107c291bf54ada1ce373259593d4e9a66572636aa8790b4b4794ed5f8fc128cdf770a774d4d5ab66b6f9485bc52b0d0b6b2
94f70b433adb3e0a3428f959ae21a92f360694107ff8f3b262149ccb5f69814c19e93e5f327d74561d33d9773c636bd7926399d5a44c4bd492122dabd21ac748
16e1e82af18ae77c7a2b5149ad48aca3645101fe145af664af46523edd2daeb1b9ae726d57d62c97cd5a7ab11ddf9ae8ec1b9eb029953b567a14eb9abb0e10ca
f1e54d799d0b9d70a4bf54b92615fe9a587aa882b1c16436bd46bb120fe5f8b1d1fd70daf96a9c74587d51dcd48461e08ef8ba71f96fffeabb8aaf6d056b709a
ed56589ba376093b4bed9ebc49f2d31fa363bc9638c8eb417538524108cc3b63a5b9ddcfd24f7d27de7fc06fa53b1118213bf9119d2f9f44794e14254a3b1816
2cfe18ac6c7f905255d7fc1ebee92bbf86eee355e51db825587321635ee46d2538576afc69dca3fd65e6496fea40968f7bb51ae9679ece4291633c8c9bdc8128
26b257e50efeb6dcf25f921d2acd5050bdb121ad5afbd234257dd94f99a46e8b54f29b9ec56bb86de0f59dcfc0e941bb97370e50bb0fd2baa1c913ccf1a80640
d175d40a9c1abfdd56fc39aa2db402825c2b20258ad48179cf9cf6ad12b5e74bd0d77922aa8fad15a20944bb210c65437c27321472f4eb587dc02e75eaf8803d
6eba8a18c8373f514f7da17966eb6272f987e83a0c4ac6f9797c849947c6f109a1811dfdb0bf9d6013b037d85c27b888425a6b869d7ca38548fc9c0882571fa6
596d9298e060b31873b17228ba6246c7e9f7566fa9635dadeba9735d9c6b82c04824e809c6f517682ee868055850322cc9ea62a42bf23866aaca1b1289fe340a
07bd4d7146a161643dbad1ceaeef9ca38aa2c84c4702cbc6a6ec330d070fcd28acfa9a2793f716f2de9b09f0de4d9ce9d8a65ad33a335623cbbe22d2d267b165
de3f2ae5e2ceee7654c05f80c8518384c6ddcf9cf1e82ecde2eabb64161aa90dd462104baf0e235c652f1cd803de7fc080e33b09eb0e3711ae6d8d81eeedaf3f
4ece684e3932d61d2957e5fc1a85061b859e7599ff617a168ddf54b0520102123a8dac90566624aa413a8d6e2043497bf1c22c94a7fce4b942b0dd60f8eee6e0
0e0ef483ac94f5e193b4bf855a4fdf5c4f8e5aa0b2a4888d521c9d2056c9b64a76cc82f84d257bf1d36c35ed45147f954fc2f3cb03fc176c2cd78900eba97340
c189220fc082d9a82e007a1af8658c7f16a9a7a61831a5683494c84c1c294f0b2437602f2f2cf1fa2cd97d218d35498279c626136f701995afde3edcd9fecbb6
27a3e7690350eda3f90ec110b035aa553a41b03684d472e7260641e54103912af7c201b3a883bd5a0dad631e9d3ed143d2521f5bdf268d66dce16c8dac6ef92b
15e783d5c8b9af1a5b47893e580b64d75dacd6ad0f0aa0f0b1fec61a7b698ed3f2fcf9c1cb654d2a18f2d9b397074bcb44492ae72e8325ad89a56ac142733f99
eaa1ebb556d5122ff1e48a9ef89ec13bbba06cb0e9c0f8b4267b0b905e4bf7584d0c85f4128b0dafa54bac33804c3d43770ffb2389cdda3e2f162098e3fa9201
06ceede7b140f0bdd598e0dc7aacbde2733141e67cce824e4070ee7899d593031a9ca75e1d54114b73379085f27905b0b96fe0a69310694e91e8f4e94bbc7bc8
b9a8b2c56d77beb50ee91e244f19a452bdbb40767568bacad94e1aa4967c4ca8776ed73b6b4badf2c0fb4dfb1548ed4c4a49ed7167204269e4d9829cb568b491
977c973c355319fe78af257f4d2b68591c2783863c03cd50c18a675138093ae4524c31202215d395f9e371abd96e4bb5ee3d7c3729bca0bab59a476787b0d7fe
254b9365cee9659489dd55808de88618e285e3210da37e37b4a207df622adbd1f5a68e250b9b9462097f0e07a3f19dbebecd7e57b0f611259e19a2bd2deb5296
afe815acdb2ca2dc2cd09b6c0e4526a5568a66a052772271d9e6f3da2b34e3f1d870068b02cf199cd6e148a4411fe77edc743ad8617c959343e43aef9ab87d0d
8708f33d6872ea4efcc77b7144bb48bcc55d245aa47c78971730e62bef28e4d07f98e7255d4c030a715a48f4ada37be55e03afb2d687e114efe02338827eea12
c788a0d8f026fad219aae36ae1505dbef62677fa38fb9f1dbcdfe96c0e36b89a44effc7e1cd6813ca3dbd1d46bc274b6d144aa93b7527c997129f87eaa7701cd
1374e91d4f46b331ff2ae3eb53cd76785d0766eb9d42ebf59d6d2f6b42ddfed127ef9badccb5a0b7df782550cd98c0fce0274daee4c1bf3d3cd85127ef4e9aa7
f01167c306f9efe047ef47f027761d3fdad98ebcc63570a1cef5bd2c82058cc995b381873f27ac0e5ed1c285dd37f7751a4ba4d6cc3d1babbd46f3483ce5f343
ece1a9a61891b4c96436e65b1bd6ad24e914052df43ab3c1f44802afd7fd10487624b7022970d59e9e8137e460595f41f8aebdf2f85d60cd927bb9eee043fa55
e4c78e25cb98e95c033b6be192e59e72cde47650509ab2856f669d49f741abe5e667ce1db07a35dc10c4525aca6bae8a731acd735c36ca2c3ee8bbaf7267dcf0
c8f4e34eb9d365a32b6925d33a6adedbcb14666eb65a8c4bac20469e268ccfa1cc283abe490fc55f5990c6b6ba9873b0d9d53246afaeda210e635509b091d4a8
84c581ed3b6cabdb700f59a408b268bb59df94d3a21d2c65893e58ac35c681e03462aa42ed6c28eb1615f7afe90d603953ed504968732caa6f7fe7044256f920
ce1af5e1f410c6fcee2d9076e35d39ddb0e5febd460fade62f67ad737ed8383c0f7eddcd6f1ce7211c46986dd8311da96930020ec64e51f344a041f42160d0ee
3e8c5cfe66b6d26ef4c73afb9a3e7ad6dcc4f59878d2649c433b59168867846bb54ee830ce8b40d28e3d9b4938e8ac22d202a51323297f9569406c1cb5f2fed4
38e2e30a136c7910de809971077f5220578568ea804d5bb2210d6c821af74926d31c865f346a0e2396e781822ff2b03110bbaca811bd0b31fe2cc59ba2b9ebd2
c9247f91e80cf0aa834ec82a65625f396d6f1afe7efcc48ae8e43081e52a481334c8b288674384054c0bd88849950d28ebd30e052c3bbb8b93f23986ec00961d
66b5a3a6656267e3d095a40b5eea60665d42b52c759d05b88a67fab06432a6980c5dcbec1cccc6514df6c72b8c912b0744081d7c2ed377a93ca91dba2886312b
29a5c940255835b5dbd8cadc5221f6318e5a627b22b28abd1a9e0da9ad9a07819a8c9ccc7e69b404d708231b0c0b291276e6c7d821569ac5a2fa19ece8eec8d5
cd5c849dc9e09e73ea618424284689b62837719782a0459d9e0efc8923909983f02ed866b9a6d9524dc643a43608a7be807554bc12f9118ece3705127dcfb0f3
b97fc31642e26bae6f4768d312274d204ef47998be3600c53634b651b7370966fd008f3961a4e543b4d9cec5429c367e3d39a69b0a7ac7841ceb69da9f42d3e5
e311d048fc16da80959d05c0c0efc48e28b73919c80b71144ed92fae3d83d99ddc978107cda693cec05d75178457bf73331c45d3fe75b4a2f06b51d641f8942f
ca0b95c37645dd3d516e6a82143cdc741505a5227c8ad6c7f9f987e0ecc2084b92989553bd381953f31ee69849e33d3c830e750577f937a2fc0698739958b4bb
c83fe04bbef6a7658c3008db8076b171090669a25eda184f4677e3a92803e709c975084bf787d4f581285752c2d88408a991947fea4e45a47798cc0223b7644d
8c3b5046525dd20775d7d540375efe24ff523faf5df5a4485da7ff3d573b319b5aabadbbc5fbc5c7c59bc576250ea79628f2fbe21f8bbffc25099f1a9c1e0878
28ca274312c1e87dc3c4855c8341d2edcdd7fb4e975cc24e939c0249e4dbf188f7cdd30b83c8d384c0fbdd56961c5be64c73c73f9e9bbc1bdd384a25067c381a
0ef9493993b5901227b640ca5e73e9b2188fa2beb535ad3afb5867342e23ba9bcd0dbe17e55648c7cec620f2bfea8735f99c10cfa346f70ea3954f715d502318
7d0a296a3bc69cc3665e71704199050a345e79482bc5e001cbb43404f53ce263a8c3e0e8e43d59d9881336d1b7c4c55b9f9cf9b670fac83d6bc5a41debc6c2d5
2cfa81fc971294ffbfe1be03d8398f60ba13b54fe23614c7db4f36b0effef0d1b840ddefdd9dd3965a5dfb872794179345cb3d16761fcc98fb9bc531861d77ab
830e7193238d9e5ede18b4c3db03cf3d560a20057ac7b9451f2a918e4e1ac7a767edf393c376d9c8e9c3238c071748c964ecb3a9c55f4c141955726c17c55769
7e18bc397b77b4c45fde1366d258b69a8da3ead9e9bb0f66f7588038db5256037eb72c6dc0902733f8e452f9b7d9eefef676b96215e4a2871f1aa7cbcb9dabf8
95103fb10fa439707c7ddc6a36a1ecae55b639ec56a7a36a38a4f30412129ffbd37b8137fda3442fafad9ae71c9d2b82e932c28ef77afdeb44b53dab5a6b349b
b25b70571c9db681eaa7b7c98ef6ad1a6d1df4414536c7484399532c6d9193b3d3c7ccab6aedf2d81a8be2f3ba1c3679f9c62af346e9defcf06879f90f7bca81
fd7b69922920030c7e2b3ef7c32f280b8af37f73c321ca842d14e6fd6a639844121091146be2b5dd3f47f458c9facd2a13269cfc3afb761d249428bf86c5236f
06a38f9d410e97fce63afb4e2e037d26aa4ff98367b199e75512c47ef23ee39fd918e400268b0d0783a0036ce46688823171ef97820cd3b55fbe8fbceb23e838
0b392c817589094a3ac1f47e4fa2ddbf3785afee26fbaa46f28e38baccf445152f322f54e1cd970bf91bee4b1965e577d44e692c7e65a19b63ec4cf9959b9ae9
f348bb564153beae2c7efcd1ac4b57c0f9470bcca121f7e049bf3b0332e53c05f17ca9c03ef26c94ee92c154d033e37a1907c7b2f4474c1e73037ba37a8c453f
b4cf9bef8fb0b0cb99f3a53a02b690b5c7b548e0606e7b5c8d6ae9931c3ca20e0833ec75503e2cd42a8bcd547d4d0f861ac231cf030e321458c7e96680813f89
42cb9074b1a79d7e3a323416c331425a631c799ddb716d45f64bc7004b741171b3ecceb824b164f93dcc5bedefb1b42f6581e57f39efbe31083398ec201a76c6
78769c80e0c931b771f833484bc6b7e561a702e0d3f54b1b779f301ebdd89ade8d5dd4206b54d979ee5ff453a9c98b7ad56a46877e29d913ec6b85b1cb589460
8b738ea4c1bd61863aa69db31573e4aa38d5f868d2bfa164c634b2bf81a937629057854e4a8d406db53b9c281aba63906a2515c25b88d828c01ee8bac3a0f311
460be201f5616b552368776cae55d610e54a49eae974bbd0962c17650c39f7831435aa5baad6cd568337d55497d7837e20d1f4da83c26aa8f89fe5f45abe8af7
97cec78ecbf78ab549ca99a013782948ff0b668191191160cf2d3318315a2d89ed92b25760e2ff64867036f68761b6583a0b187583fecded340bb888019a6c08
8ccb2886d3034d12b44719b90fd4ce1d466956c14cbba28c8920f5882c7bbf73d3e90f57c25f2d867eca99201a1508395d02da0516477cdbe2d55a0174ed15de
da6ed8c5c6b3405d7f1eb19aae0028d0e257035005c19be20a3bede0d8cc958ca256437ddc4931294d17d5ee02d22e5d6fcfc00d72c585392c0921c457611eaf
f09a9801ec52bddbd008978ee1ca21f7a20d32a1ec5d60b903079c282ee5f6bef2bc5f267d429b1309f7302505c1e02b7fcec69c7649b56030116cc013125b5b
c8fb88593feddbd117d586c4839001712dcf620c0bfc3d673446514f10c2b6807ff23f83ba9f84d7d83dae144c360f804e2c234f06bb5968c06da10e5c13edd0
33daba0a99a39bc61cb75130deb6f207216da39e4e5bd31f2088c1b81b0f8539b0ab0d09782b5e6fa85ae415b2a5224852830c9ee5ff4808588028ea83420033
f44a9d1972d299d947edfd2797d01389e3a5dce9d762499e496ed97e9dbac9347298d92443f07105a547f6a7b778df0758346cdab84d7159ad7295f3b39f9ba7
0bf95715674ca0bcbaf244c19f5658956df2f57f9537d858071c05c9205e533c2578d201708bc6de34fa6657f80e39b6c46290d68b2ea117a4054a5c069f36ec
b2b703ca29f9ad32c5f150d0303c41405a8161cf70bdf2a138e91c54a02565c12b9760651aac9e3c2a8573c7ea4c6a0671aab478cdfb71ca6353afa6eb78e216
ef2f107542cb32608c28c0b36451cf7b4b0b624d3e481a90acc4cc15d7c2ab168b6bfa9885142805682e255d5022e1350bc3e9ac3fb4d540cc9ceb80a849c356
b5c864951e3f58b9c629ae3275cc9a840428dc58bcab031a3079bb2561f3183351042eb40960a224dd3ea868e890667d3deb2aea7c0e9dd3e83122b59b6507e2
824949268e967de32891a79adae973f41cfc1ab4ab0e30cc0e3c977e5156c45eaef557ddb6757b11dfd54b73faff79a9fcdba4bcb43e945e141b0f089ae97d62
20316a53d68dd9fe9efda4b12cf5883adf38c6a55bca155066b3d2f9b8205d3196a45c313a04255430b5ea8438c169e33d99b9461c02c378446dab7a0b447c1b
0ec60bfcc73cf801f96217d57a96ba214d50f4e92fad935f81f2d109f3fdd951d370be4c5e304b7f067e6de2b08954a95acd568572ce21a16852df5975e80855
94a69379ce08659085bade1373aed50c2d075623adede49f4152fdd138f39cb15673e82e39278b549e044dde911f94b2948cd54e2eb8ee491da2d811a5bce26e
f8b2f989437f6539974b73f9ebb21c33103cd9db8ca9754791a07a62835854894e0303682700413a05bbe3aea6b8bc89175095dbd9c7c040d9801d115f6b2883
1736b8f19a92a16254b70ea64a0c37c585ccd5ad4a4ba5654237e936b3f6adde0baea825158710880346d794ce1798814e0c33287d91ba6883f1cd6b8ec1402e
d4ae96c1b6ac722ad2aa4a45baaa0fc55765d44d43829ca04043644c35a52fbb681132d4efd0f453c385512413a20a42f8dd93918cc9bd6ac4869f39d2bee59f
ae7cf4c92c70f667a62e7a82b991e91f38bb919e189d10c99c162a23070e7b72d8a5784c393363a798284c2c2ac28bce4c2187efeac3082ab0aafdbc994ebd75
dc1330bb47f6549527d955e409ab3ad7ed6a7b4d9de03bda25f6b656b35de95216705dc7a122376d08a9b5dacf718d48f581d2ad50e3667b5224269a4241b8d6
381de7c0a946b5882cd432495a7978e15aaad1b86033a371662b2c610bb5c345b36952cae1426d597cc8040c02d94af0116630087b20e7a6b5f44d1bbe281c1f
b45be647b713dd7e1ce1e58ad4182df95f68a4fa92547c112187c8539ac25a2464583299fdb056e9b6b9cc7239869e1dea588704da8d4302b12da00f42586187
22afb1482ddb9e302d2787d144cf09e834715cdd90ed1b4051d3dc2363a32c313c197cda6d0daab157d6ebdb9660b23b329c2e387a8a4e2d2fed79056a43258a
773a906108d26b8526ac05f4a6155137d1d03c9f8e1c588ea5d5e134af43575c6621f1279b441e39903f9cdcbe1529152793d80848928854f2adc0e35aa98671
4af090cf4d1533e287813a224a5133fb7bd04a0649f93432a6d2587fc3125b30a77f0202cc1619125e7c1222671b082fe2c1478eefd7d0720be85e791f91b351
61b1562848f4958e232bb3030510b83bc8725f5bd96c1a5358f10509edab5027310af1e825ced3d618c878325699afc5659cfd3c41ff59ba9ec63d1eddc37f5f
e54aa0318ffe82a2aa18634f4fb0244ebd5962624fc11d67c340df6fb67ac043874a2e729ee3d99400cf734fb96d1d449f4be4f71d9f7fa3076af8793c4ce1f5
f907e476af2f53c02cebc5d6addba5c73960ca40af12702b6134acd3338480df34da3f05186cab714a6e097ff3cba2d96a792a56f57f503e53a1f6d945ebb079
b97d45c29a5266265e2c65c4d8edc4a569603c18242114ed661bb166e14b9cba5e9a1b10f4122f868775451163cc2356d2387869fe52c1e0966b136e22e8f3ef
1c82f57f01f0790386d91c0400
DFR_BUNDLED_INGRESS_HEX
    actual=$(sha256sum "$output" | awk '{print $1}')
    [[ "$actual" == "$BUNDLED_INGRESS_SHA256" ]] || { rm -f -- "$output"; error "Bundled Client checksum mismatch: expected $BUNDLED_INGRESS_SHA256, found $actual."; return 1; }
    declared=$(sed -nE 's/^readonly APP_VERSION="([^"]+)".*/\1/p' "$output" | head -n 1)
    [[ "$declared" == "$BUNDLED_INGRESS_VERSION" ]] || { rm -f -- "$output"; error "Bundled Client version mismatch: expected $BUNDLED_INGRESS_VERSION, found ${declared:-unknown}."; return 1; }
    chmod 0755 "$output"
    return 0
}

publish_bundled_ingress_release ()
{
    local existing status digest tmp
    existing=$(registry_command release-list 2>/dev/null | awk -F '\t' -v v="$BUNDLED_INGRESS_VERSION" '$1==v {print $2 "\t" $3; exit}')
    if [[ -n "$existing" ]]; then
        status=${existing%%$'\t'*}
        digest=${existing#*$'\t'}
        if [[ "$digest" == "$BUNDLED_INGRESS_SHA256" ]]; then
            print_check info 'Bundled release' "$BUNDLED_INGRESS_VERSION is already published as ${status^^}"
            if [[ "$status" == stable ]]; then
                if registry_command server-endpoint-reconcile >/dev/null 2>&1; then
                    print_check pass 'Endpoint migration' 'Pending AUTO Client work synchronized.'
                fi
            fi
            return 0
        fi
        warn "Published ${BUNDLED_INGRESS_VERSION} has a different SHA256; replacing it with the bundled build."
        print_check info 'Safety' 'The replacement is reset to STAGED and existing queued targets for that version are cleared.'
    fi

    tmp=$(mktemp /tmp/dragon-fruit-relay-ingress-bundled.XXXXXX.sh)
    if ! extract_bundled_ingress_release "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    if [[ -n "$existing" && "$digest" != "$BUNDLED_INGRESS_SHA256" ]]; then
        publish_ingress_release "$tmp" staged replace
    else
        publish_ingress_release "$tmp" staged
    fi
    rm -f -- "$tmp"
    print_check info 'Safety' 'Bundled release remains STAGED until you deliberately mark it CANARY or STABLE.'
}

ensure_bundled_ingress_stable_release ()
{
    local existing status digest tmp replace_mode=no verified
    existing=$(registry_command release-list 2>/dev/null | awk -F '\t' -v v="$BUNDLED_INGRESS_VERSION" '$1==v {print $2 "\t" $3; exit}')
    if [[ -n "$existing" ]]; then
        status=${existing%%$'\t'*}
        digest=${existing#*$'\t'}
        if [[ "$status" == revoked ]]; then
            # REVOKED is an explicit operator safety decision. Preserve it even
            # if a later package carries a corrected payload with the same
            # semantic version; the administrator must choose a newer release
            # or explicitly replace the revoked record.
            print_check warn 'Default Client release' "$BUNDLED_INGRESS_VERSION is REVOKED; automatic reactivation was not attempted."
            return 0
        fi
        if [[ "$digest" == "$BUNDLED_INGRESS_SHA256" ]]; then
            if [[ "$status" != stable ]]; then
                registry_command release-status "$BUNDLED_INGRESS_VERSION" stable >/dev/null || return 1
            fi
            verified=$(registry_command release-list 2>/dev/null | awk -F '\t' -v v="$BUNDLED_INGRESS_VERSION" '$1==v {print $2 "\t" $3; exit}')
            [[ "$verified" == $'stable\t'"$BUNDLED_INGRESS_SHA256" ]] || return 1
            print_check pass 'Default Client release' "$BUNDLED_INGRESS_VERSION is published as STABLE; new Clients use AUTO/LATEST."
            registry_command server-endpoint-reconcile >/dev/null 2>&1 || true
            return 0
        fi
        replace_mode=replace
        print_check info 'Default Client release' "Refreshing bundled $BUNDLED_INGRESS_VERSION payload for this DFR build."
    fi

    tmp=$(mktemp /tmp/dragon-fruit-relay-ingress-default.XXXXXX.sh)
    extract_bundled_ingress_release "$tmp" || { rm -f -- "$tmp"; return 1; }
    if [[ "$replace_mode" == replace ]]; then
        publish_ingress_release "$tmp" staged replace || { rm -f -- "$tmp"; return 1; }
        registry_command release-status "$BUNDLED_INGRESS_VERSION" stable >/dev/null || { rm -f -- "$tmp"; return 1; }
    else
        publish_ingress_release "$tmp" stable || { rm -f -- "$tmp"; return 1; }
    fi
    rm -f -- "$tmp"

    # Never let Bash conditional-errexit semantics turn a partial publishing
    # failure into a successful Server initialization. Verify the persisted
    # release identity after every publish/promote path.
    verified=$(registry_command release-list 2>/dev/null | awk -F '\t' -v v="$BUNDLED_INGRESS_VERSION" '$1==v {print $2 "\t" $3; exit}')
    [[ "$verified" == $'stable\t'"$BUNDLED_INGRESS_SHA256" ]] || {
        error "Default Client release verification failed for $BUNDLED_INGRESS_VERSION."
        return 1
    }
    print_check pass 'Default Client release' "$BUNDLED_INGRESS_VERSION is STABLE; new Clients default to AUTO/LATEST."
}

publish_ingress_release ()
{
    local source="$1" requested_status="${2:-staged}" replace_mode="${3:-no}"
    local version release_dir payload manifest signature digest canonical
    local -a publish_extra=()
    [[ "$replace_mode" == replace ]] && publish_extra+=(--replace)

    [[ -f "$source" ]] || die "Client release file does not exist: ${source}"
    validate_ingress_release_payload "$source" || die 'Client release failed managed-release preflight validation.'

    version=$(sed -nE 's/^readonly APP_VERSION="([^"]+)"/\1/p' "$source" | head -n1)
    [[ "$version" =~ ^v[0-9]+\.[0-9]+(\.[0-9]+)?([.-][A-Za-z0-9._-]+)?$ ]] || \
        die 'Could not determine a valid APP_VERSION from the Client release.'

    case "$requested_status" in staged|canary|stable|revoked) ;; *) die 'Release status must be staged, canary, stable or revoked.' ;; esac

    ensure_update_signing_key
    release_dir="${RELEASE_DIR}/${version}"
    install -d -m 0700 "$release_dir"
    payload="${release_dir}/dragon-fruit-relay-ingress.sh"
    manifest="${release_dir}/release.json"
    signature="${release_dir}/release.sig"

    install -m 0755 "$source" "$payload"
    digest=$(sha256sum "$payload" | awk '{print $1}')

    canonical=$(python3 - "$version" "$digest" <<'PY_RELEASE_MANIFEST'
import json,sys,time
version,digest=sys.argv[1:3]
print(json.dumps({
    'format':'dragon-fruit-relay-ingress-release',
    'format_version':1,
    'version':version,
    'sha256':digest,
    'role':'ingress',
    'minimum_control_protocol':1,
    'config_schema':1,
    'enrollment_token_version':1,
    'apply_mode':'safe-rollback',
    'reconcile_required':True,
    'capabilities':['release-sha-report-v1','server-endpoint-sync-v2'],
    'created_at':int(time.time()),
},sort_keys=True,separators=(',',':')))
PY_RELEASE_MANIFEST
)
    printf '%s' "$canonical" > "$manifest"
    chmod 0644 "$manifest"

    openssl pkeyutl -sign -rawin -inkey "$UPDATE_SIGNING_KEY" \
        -in "$manifest" -out "$signature" >/dev/null 2>&1 || die 'Could not sign Client release.'
    chmod 0644 "$signature"

    registry_command release-publish "$version" \
        --payload "$payload" \
        --signature "$signature" \
        --sha256 "$digest" \
        --manifest-json "$canonical" \
        --status "$requested_status" \
        "${publish_extra[@]}"

    success "Client release ${version} published as ${requested_status}."
}

write_control_plane_files ()
{
    ensure_hub_layout
    ensure_update_signing_key

    cat > "$CONTROL_TX_HELPER" <<'EOF_DFR_CONTROL_TX'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ENGINE=/usr/local/sbin/dragon-fruit-relay
REGISTRY=/etc/dragon-fruit-relay/hub-bin/registry
[[ $# -eq 4 ]] || exit 64
name="$1"; transaction_id="$2"; egress_apply_at="$3"; rollback_at="$4"
[[ "$name" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || exit 64
[[ "$transaction_id" =~ ^[0-9A-Fa-f-]{36}$ ]] || exit 64
[[ "$egress_apply_at" =~ ^[0-9]+$ && "$rollback_at" =~ ^[0-9]+$ ]] || exit 64
LOCK="/run/lock/dragon-fruit-relay-config-transaction-${name}.lock"
mkdir -p /run/lock
exec 9>"$LOCK"; flock 9

state_now() {
    "$REGISTRY" config-transaction "$name" "$transaction_id" 2>/dev/null |
      python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])' 2>/dev/null || true
}


state=$(state_now); [[ "$state" == PREPARED ]] || exit 0
now=$(date +%s); (( egress_apply_at > now )) && sleep "$((egress_apply_at-now))"
state=$(state_now); [[ "$state" == PREPARED ]] || exit 0

if ! DFR_INTERNAL_NO_MAIN_LOCK=1 "$ENGINE" _config-apply-runtime "$name" "$transaction_id"; then
    DFR_INTERNAL_NO_MAIN_LOCK=1 "$ENGINE" _config-rollback-runtime "$name" "$transaction_id" >/dev/null 2>&1 || true
    "$REGISTRY" config-mark "$name" "$transaction_id" FAILED --error 'Server runtime apply failed' >/dev/null 2>&1 || true
    "$REGISTRY" config-recover "$name" "$transaction_id" --reason 'Server runtime apply failed; previous active configuration restored' >/dev/null 2>&1 || true
    exit 1
fi

if ! DFR_INTERNAL_NO_MAIN_LOCK=1 "$ENGINE" _config-verify-runtime "$name" "$transaction_id"; then
    DFR_INTERNAL_NO_MAIN_LOCK=1 "$ENGINE" _config-rollback-runtime "$name" "$transaction_id" >/dev/null 2>&1 || true
    "$REGISTRY" config-mark "$name" "$transaction_id" FAILED --error 'Server listener verification failed' >/dev/null 2>&1 || true
    "$REGISTRY" config-recover "$name" "$transaction_id" --reason 'Server listener verification failed; previous active configuration restored' >/dev/null 2>&1 || true
    exit 1
fi

if ! "$REGISTRY" config-mark "$name" "$transaction_id" APPLYING >/dev/null 2>&1; then
    DFR_INTERNAL_NO_MAIN_LOCK=1 "$ENGINE" _config-rollback-runtime "$name" "$transaction_id" >/dev/null 2>&1 || true
    "$REGISTRY" config-recover "$name" "$transaction_id" --reason 'could not enter APPLYING state; previous active configuration restored' >/dev/null 2>&1 || true
    exit 1
fi

while :; do
    state=$(state_now)
    if [[ "$state" == COMMITTED ]]; then
        "$REGISTRY" config-finalize "$name" "$transaction_id" >/dev/null 2>&1 || true
        exit 0
    fi
    # A missing row means another authoritative actor already finalized or
    # recovered the transaction. Never roll back a transaction that has been
    # resolved elsewhere.
    [[ -z "$state" ]] && exit 0
    [[ "$state" == FAILED ]] && break
    now=$(date +%s); (( now >= rollback_at )) && break
    sleep 1
done

DFR_INTERNAL_NO_MAIN_LOCK=1 "$ENGINE" _config-rollback-runtime "$name" "$transaction_id" >/dev/null 2>&1 || true
"$REGISTRY" config-recover "$name" "$transaction_id" --reason 'automatic rollback: Client commit was not confirmed before the 60-second deadline' >/dev/null 2>&1 || true
exit 0
EOF_DFR_CONTROL_TX
    chmod 0750 "$CONTROL_TX_HELPER"

    cat > "$CONTROL_RESPONDER" <<'PY_DFR_CONTROL'
#!/usr/bin/env python3
import base64, hashlib, hmac, json, os, re, secrets, selectors, shlex, signal, socket, sqlite3, subprocess, time,threading
from pathlib import Path

DB=Path('/var/lib/dragon-fruit-relay/database/registry.sqlite3')
UPDATE_PUBLIC_KEY=Path('/etc/dragon-fruit-relay/secrets/ingress-update-ed25519.pub')
PORTS=[__DFR_CONTROL_PORTS__]
MANAGEMENT_PORTS={'subscription':__DFR_TARGET_SUBSCRIPTION_PORT__,'control':__DFR_TARGET_CONTROL_PORT__}
PROTOCOL='DRAGON-FRUIT-RELAY-CONTROL/1'
SERVER_VERSION='v2.1.0'
REGISTRY_SCHEMA=1
RUNTIME_API=1
CONTROL_RUNTIME_ID='software-convergence-v1'
TX_HELPER='/etc/dragon-fruit-relay/hub-bin/config-transaction'
RUNNING=True


def db():
    c=sqlite3.connect(str(DB),timeout=5)
    c.row_factory=sqlite3.Row
    c.execute('PRAGMA busy_timeout=5000')
    c.execute('PRAGMA foreign_keys=ON')
    return c


def compact(obj):
    return json.dumps(obj,sort_keys=True,separators=(',',':'))


# DFR_CONTROL_REPORT_TEXT_NORMALIZE
def clean_report_text(value, limit):
    v=str(value or '')[:limit]
    for _ in range(3):
        if '\\' not in v:
            break
        try:
            nv=' '.join(shlex.split(v,posix=True))
        except ValueError:
            break
        if not nv or nv == v:
            break
        v=nv
    return v


def req_material(req):
    # Bind the enrollment identity into every authenticated CONTROL request.
    # The hash is not a secret, but prevents a control key from being replayed
    # against a different enrollment state.
    return '\n'.join((
        str(req.get('protocol','')),str(req.get('connection_uuid','')),
        str(req.get('timestamp','')),str(req.get('nonce','')),
        str(req.get('op','')),str(req.get('enrollment_token_hash','') or ''),
        compact(req.get('payload') or {}),
    )).encode()


def sign_response(key_hex, body):
    body=dict(body)
    body['mac']=hmac.new(bytes.fromhex(key_hex),compact(body).encode(),hashlib.sha256).hexdigest()
    return body


def connection_by_uuid(c,cu):
    return c.execute('SELECT * FROM connections WHERE connection_uuid=?',(cu,)).fetchone()


def active_tx(c,name):
    return c.execute("SELECT * FROM config_pending WHERE connection_name=?",(name,)).fetchone()


def launch_config_transaction(name,transaction_id,egress_apply_at,rollback_at):
    # start_new_session detaches a process from the responder's terminal, but
    # not from the responder's systemd cgroup. A CONTROL restart could therefore
    # kill the old coordinator and strand a COMMITTED transaction. Run each
    # transaction in its own transient systemd unit instead.
    unit='dragon-fruit-relay-config-' + re.sub(r'[^0-9A-Fa-f]','',str(transaction_id))[:16].lower()
    cp=subprocess.run([
        'systemd-run','--unit',unit,'--collect','--no-block','--quiet','--',
        TX_HELPER,str(name),str(transaction_id),str(int(egress_apply_at)),str(int(rollback_at)),
    ],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,text=True,timeout=15)
    if cp.returncode != 0:
        raise RuntimeError((cp.stderr or '').strip()[-300:] or 'could not start configuration transaction coordinator')


def release_for(c,version):
    if not version: return None
    return c.execute("SELECT * FROM software_releases WHERE version=?",(version,)).fetchone()


def verify_request(c,req,local_ip,peer_ip):
    if req.get('protocol') != PROTOCOL: raise ValueError('protocol mismatch')
    cu=str(req.get('connection_uuid',''))
    r=connection_by_uuid(c,cu)
    if not r: raise ValueError('unknown connection UUID')
    if local_ip != r['egress_xfrm_ip'] or peer_ip != r['ingress_xfrm_ip']:
        raise ValueError('request arrived on the wrong XFRM path')
    ts=int(req.get('timestamp',0))
    if abs(int(time.time())-ts) > 120: raise ValueError('request timestamp outside allowed window')
    nonce=str(req.get('nonce',''))
    if len(nonce) < 16 or len(nonce) > 128: raise ValueError('invalid nonce')

    c.execute('INSERT OR IGNORE INTO ingress_state(connection_name) VALUES(?)',(r['name'],))
    s=c.execute('SELECT * FROM ingress_state WHERE connection_name=?',(r['name'],)).fetchone()

    # During one-time enrollment-key promotion, accept either the currently
    # committed control key or the pending replacement.  Once a request proves
    # possession of the pending key it is promoted atomically and the bootstrap
    # token's old control key stops authenticating future requests.
    candidates=[('current',str(r['control_key']))]
    if s['pending_control_key']:
        candidates.append(('pending',str(s['pending_control_key'])))
    supplied=str(req.get('mac',''))
    authenticated=None
    auth_key=None
    material=req_material(req)
    for kind,key_hex in candidates:
        try:
            expected=hmac.new(bytes.fromhex(key_hex),material,hashlib.sha256).hexdigest()
        except ValueError:
            continue
        if hmac.compare_digest(expected,supplied):
            authenticated=kind; auth_key=key_hex; break
    if authenticated is None: raise ValueError('request authentication failed')

    cutoff=int(time.time())-300
    c.execute('DELETE FROM control_nonces WHERE seen_at<?',(cutoff,))
    if c.execute('SELECT 1 FROM control_nonces WHERE connection_name=? AND nonce=?',(r['name'],nonce)).fetchone():
        raise ValueError('replayed nonce')
    c.execute('INSERT INTO control_nonces(connection_name,nonce,seen_at) VALUES(?,?,?)',(r['name'],nonce,int(time.time())))

    token_hash=str(req.get('enrollment_token_hash','') or '')
    stored_hash=str(s['enrollment_token_hash'] or '')
    enrolling=False

    if token_hash != stored_hash:
        # A different token hash is accepted only when it is a currently valid,
        # unconsumed token explicitly issued for this connection.  This allows
        # intentional re-enrollment without disrupting the already-running node.
        tok=c.execute('SELECT * FROM enrollment_tokens WHERE connection_name=? AND token_hash=?',(r['name'],token_hash)).fetchone()
        if not tok: raise ValueError('valid enrollment token required')
        if tok['revoked_at'] is not None or tok['consumed_at'] is not None or int(tok['expires_at']) < int(time.time()):
            raise ValueError('enrollment token expired, consumed or revoked')
        c.execute('UPDATE enrollment_tokens SET consumed_at=? WHERE id=?',(int(time.time()),tok['id']))
        c.execute('UPDATE ingress_state SET enrollment_token_hash=? WHERE connection_name=?',(token_hash,r['name']))
        Path('/etc/dragon-fruit-relay/clients',r['name'],'pairing-token.txt').unlink(missing_ok=True)
        c.execute('INSERT INTO audit(occurred_at,connection_name,action,detail) VALUES(?,?,?,?)',(int(time.time()),r['name'],'connection-enrolled',f"enrollment token #{tok['id']} consumed"))
        enrolling=True
    elif not stored_hash:
        raise ValueError('enrollment token identity missing')

    # If this is first/re-enrollment, mint a control key that never appeared in
    # the enrollment token.  The response is still signed with auth_key, so the
    # ingress can safely learn the replacement before switching to it.
    if enrolling:
        pending=secrets.token_hex(32)
        c.execute("UPDATE ingress_state SET pending_control_key=?,bootstrap_psk_state='awaiting-control-promotion' WHERE connection_name=?",(pending,r['name']))
        s=c.execute('SELECT * FROM ingress_state WHERE connection_name=?',(r['name'],)).fetchone()

    if authenticated=='pending':
        # Proving the pending key completes phase 2.  The token's control key is
        # invalid from this transaction onward.
        promoted=str(s['pending_control_key'] or '')
        if not promoted or not hmac.compare_digest(promoted,auth_key):
            raise ValueError('pending control-key state changed')
        c.execute('UPDATE connections SET control_key=?,updated_at=? WHERE name=?',(promoted,int(time.time()),r['name']))
        c.execute("UPDATE ingress_state SET pending_control_key=NULL,bootstrap_psk_state='control-promoted' WHERE connection_name=?",(r['name'],))
        c.execute('INSERT INTO audit(occurred_at,connection_name,action,detail) VALUES(?,?,?,?)',(int(time.time()),r['name'],'connection-control-key-rotated','post-enrollment control key promoted'))
        r=connection_by_uuid(c,cu)

    contact_now=int(time.time())
    previous_seen=int(s['last_seen_at'] or 0)
    previous_health=str(s['health'] or '').upper()
    gap=max(0,contact_now-previous_seen) if previous_seen else 0
    if previous_seen <= 0:
        c.execute(
            'INSERT INTO audit(occurred_at,connection_name,action,detail) VALUES(?,?,?,?)',
            (contact_now,r['name'],'connection-presence-connected','First authenticated CONTROL contact'),
        )
    elif previous_health in ('STALE','OFFLINE') or gap >= 30:
        c.execute(
            'INSERT INTO audit(occurred_at,connection_name,action,detail) VALUES(?,?,?,?)',
            (contact_now,r['name'],'connection-presence-connected',f'Authenticated CONTROL contact restored after {gap}s'),
        )

    c.execute('''
        UPDATE ingress_state
        SET last_seen_at=?,last_nonce=?,
            health=CASE
                WHEN UPPER(COALESCE(health,'')) IN ('STALE','OFFLINE') THEN 'UNKNOWN'
                ELSE health
            END
        WHERE connection_name=?
    ''',(contact_now,nonce,r['name']))
    return r,auth_key

def response_payload(c,r):
    tx=active_tx(c,r['name'])
    state=c.execute('SELECT * FROM ingress_state WHERE connection_name=?',(r['name'],)).fetchone()

    # Keep failed software intent durable in the registry without commanding an
    # automatic retry on every CONTROL poll. An explicit Deploy/retry resets
    # the state to QUEUED, at which point the exact desired release is exposed
    # failure reports that predate digest persistence; this can only suppress a
    # retry, never declare a build current.
    desired_version=r['desired_ingress_version']
    desired_source=r['desired_ingress_source']
    hold_failed=False
    if desired_version and state:
        failed_state=str(state['update_status'] or '').upper() in ('FAILED','ROLLED_BACK','CANCELLED')
        failed_target=str(state['update_target'] or '') == str(desired_version)
        hold_failed=bool(failed_state and failed_target)
    advertised_version=None if hold_failed else desired_version
    advertised_source=None if hold_failed else desired_source
    release=release_for(c,advertised_version)
    hub=c.execute('SELECT endpoint FROM hub WHERE id=1').fetchone()
    return {
        'server_version':SERVER_VERSION,
        'registry_schema':REGISTRY_SCHEMA,
        'runtime_api':RUNTIME_API,
        'control_runtime_id':CONTROL_RUNTIME_ID,
        'connection_name':r['name'],
        'server_endpoint':None if not hub else hub[0],
        'management_ports':dict(MANAGEMENT_PORTS),
        'desired_ingress_version':advertised_version,
        'desired_ingress_source':advertised_source,
        'update_policy':r['update_policy'],
        'pending_action':r['pending_action'],
        'update_status':None if not state else state['update_status'],
        'update_target':None if not state else state['update_target'],
        'action_status':None if not state else state['action_status'],
        'next_control_key':None if not state else state['pending_control_key'],
        'bootstrap_psk_state':None if not state else state['bootstrap_psk_state'],
        'update_public_key_b64':base64.b64encode(UPDATE_PUBLIC_KEY.read_bytes()).decode() if UPDATE_PUBLIC_KEY.is_file() else None,
        'transaction': None if not tx else {
            'transaction_id':tx['transaction_id'],
            'state':tx['state'],
            'kind':tx['kind'] or 'manual',
            'candidate':json.loads(tx['candidate_json']),
            'egress_apply_at':tx['egress_apply_at'],
            'apply_at':tx['apply_at'],
            'rollback_at':tx['rollback_at'],
        },
        'release': None if not release or release['status']=='revoked' else {
            'version':release['version'],'status':release['status'],'sha256':release['sha256'],
            'manifest':json.loads(release['manifest_json']),
        },
    }


def ensure_bootstrap_psk_rotation(c,r):
    state=c.execute('SELECT * FROM ingress_state WHERE connection_name=?',(r['name'],)).fetchone()
    if not state or state['pending_control_key']:
        return
    if state['bootstrap_psk_state'] != 'control-promoted':
        return
    if active_tx(c,r['name']):
        return
    previous={k:r[k] for k in ('udp_port','xfrm_mtu','dns_primary','dns_secondary','psk')}
    candidate=dict(previous); candidate['psk']=secrets.token_hex(32)
    txid=str(__import__('uuid').uuid4())
    t=int(time.time())
    c.execute("""
        INSERT INTO config_pending(
          connection_name,transaction_id,state,previous_json,candidate_json,
          created_at,updated_at,kind
        ) VALUES(?,?,?,?,?,?,?,?)
    """,(r['name'],txid,'PENDING',json.dumps(previous,sort_keys=True),json.dumps(candidate,sort_keys=True),t,t,'bootstrap-psk'))
    c.execute("UPDATE ingress_state SET bootstrap_psk_state='psk-rotation-pending' WHERE connection_name=?",(r['name'],))
    c.execute('INSERT INTO audit(occurred_at,connection_name,action,detail) VALUES(?,?,?,?)',(t,r['name'],'connection-bootstrap-credential-rotation','transactional credential rotation staged after enrollment'))


def handle(req,local_ip,peer_ip):
    with db() as c:
        c.execute('BEGIN IMMEDIATE')
        r,auth_key=verify_request(c,req,local_ip,peer_ip)
        # Once the post-enrollment control key has been proven, immediately
        # stage rotation of the bootstrap IKE credential.  This makes a copied
        # enrollment token lose both of its long-lived secrets automatically.
        ensure_bootstrap_psk_rotation(c,r)
        r=connection_by_uuid(c,r['connection_uuid'])
        op=req.get('op'); payload=req.get('payload') or {}
        out={}

        if op=='poll':
            out=response_payload(c,r)

        elif op=='prepare-config':
            txid=str(payload.get('transaction_id',''))
            tx=c.execute("SELECT * FROM config_pending WHERE connection_name=? AND transaction_id=?",(r['name'],txid)).fetchone()
            if not tx or tx['state'] not in ('PENDING','PREPARED'): raise ValueError('configuration transaction is not pending')
            if tx['state']=='PENDING':
                prepared=int(time.time())
                # Egress switches first, ingress follows four seconds later.  Once
                # ingress applies, both sides have a full 60-second confirmation
                # window before the previous active configuration is restored.
                egress_apply_at=prepared+3
                apply_at=prepared+7
                rollback_at=apply_at+60
                c.execute("UPDATE config_pending SET state='PREPARED',prepared_at=?,egress_apply_at=?,apply_at=?,rollback_at=?,updated_at=? WHERE connection_name=? AND transaction_id=?",(prepared,egress_apply_at,apply_at,rollback_at,prepared,r['name'],txid))
                c.execute('INSERT INTO audit(occurred_at,connection_name,action,detail) VALUES(?,?,?,?)',(prepared,r['name'],'connection-config-prepared','coordinated apply scheduled; 60-second rollback window'))
                c.commit()
                try:
                    launch_config_transaction(r['name'],txid,egress_apply_at,rollback_at)
                except Exception as exc:
                    # No Server runtime apply has started yet. Remove the
                    # prepared transaction rather than handing the Client a
                    # schedule whose coordinator does not exist.
                    with db() as c2:
                        c2.execute('BEGIN IMMEDIATE')
                        current=c2.execute("SELECT state FROM config_pending WHERE connection_name=? AND transaction_id=?",(r['name'],txid)).fetchone()
                        if current and current['state']=='PREPARED':
                            t=int(time.time())
                            c2.execute("DELETE FROM config_pending WHERE connection_name=? AND transaction_id=?",(r['name'],txid))
                            c2.execute("UPDATE ingress_state SET action_name='configuration',action_status='FAILED',action_message=?,action_finished_at=?,last_error=? WHERE connection_name=?",(str(exc)[:500],t,str(exc)[:500],r['name']))
                            c2.execute('INSERT INTO audit(occurred_at,connection_name,action,detail) VALUES(?,?,?,?)',(t,r['name'],'connection-config-rollback','configuration coordinator could not be started'))
                            c2.commit()
                    raise ValueError(f'configuration coordinator could not be started: {exc}')
                with db() as c2:
                    r2=connection_by_uuid(c2,r['connection_uuid']); out=response_payload(c2,r2)
                return auth_key,out
            out=response_payload(c,r)

        elif op=='report':
            version=str(payload.get('ingress_version','') or '')[:64]
            ingress_sha256=clean_report_text(payload.get('ingress_sha256',''),128).lower()
            if ingress_sha256 and not re.fullmatch(r'[0-9a-f]{64}',ingress_sha256): ingress_sha256=''
            health=clean_report_text(payload.get('health','UNKNOWN') or 'UNKNOWN',32)
            update_status=clean_report_text(payload.get('update_status',''),64)
            update_target=clean_report_text(payload.get('update_target',''),64)
            update_sha256=clean_report_text(payload.get('update_sha256',''),128).lower()
            if update_sha256 and not re.fullmatch(r'[0-9a-f]{64}',update_sha256): update_sha256=''
            update_error=clean_report_text(payload.get('update_error',''),512)
            update_started_at=int(payload.get('update_started_at',0) or 0) or None
            update_finished_at=int(payload.get('update_finished_at',0) or 0) or None

            action_name=clean_report_text(payload.get('action_name',''),64)
            action_status=clean_report_text(payload.get('action_status',''),64)
            action_message=clean_report_text(payload.get('action_message',''),512)
            action_started_at=int(payload.get('action_started_at',0) or 0) or None
            action_finished_at=int(payload.get('action_finished_at',0) or 0) or None
            client_endpoint=str(payload.get('client_endpoint','') or '').strip().lower().rstrip('.')[:253]
            endpoint_error=clean_report_text(payload.get('endpoint_error',''),500)
            raw_capabilities=payload.get('client_capabilities') or []
            if not isinstance(raw_capabilities,list): raw_capabilities=[]
            client_capabilities=sorted({str(item)[:96] for item in raw_capabilities if isinstance(item,str) and item})
            client_capabilities_json=json.dumps(client_capabilities,separators=(',',':'))
            error=clean_report_text(payload.get('error','') or update_error or (action_message if action_status=='FAILED' else ''),512)
            report_now=int(time.time())
            c.execute('''
                UPDATE ingress_state SET
                  ingress_version=?,ingress_sha256=?,health=?,update_status=?,last_error=?,last_seen_at=?,
                  update_target=?,update_sha256=?,update_error=?,update_started_at=?,update_finished_at=?,
                  action_name=?,action_status=?,action_message=?,action_started_at=?,action_finished_at=?,
                  client_endpoint=?,endpoint_error=?,endpoint_updated_at=?,client_capabilities_json=?
                WHERE connection_name=?
            ''',(
                version,ingress_sha256 or None,health,update_status,error or None,report_now,
                update_target or None,update_sha256 or None,update_error or None,update_started_at,update_finished_at,
                action_name or None,action_status or None,action_message or None,action_started_at,action_finished_at,
                client_endpoint or None,endpoint_error or None,report_now if client_endpoint else None,client_capabilities_json,
                r['name'],
            ))
            if version and ingress_sha256:
                active_rel=c.execute("SELECT sha256 FROM software_releases WHERE version=?",(version,)).fetchone()
                if active_rel and active_rel[0] == ingress_sha256:
                    c.execute('''
                        INSERT INTO software_release_usage(version,connection_name,first_seen_at,last_seen_at)
                        VALUES(?,?,?,?)
                        ON CONFLICT(version,connection_name)
                        DO UPDATE SET last_seen_at=excluded.last_seen_at
                    ''',(version,r['name'],report_now,report_now))
            completed_action=payload.get('action_complete')
            failed_action=payload.get('action_failed')
            if completed_action and r['pending_action']==completed_action:
                c.execute('UPDATE connections SET pending_action=NULL WHERE name=?',(r['name'],))
                c.execute("UPDATE ingress_state SET action_name=?,action_status='SUCCEEDED',action_finished_at=COALESCE(action_finished_at,?) WHERE connection_name=?",(completed_action,report_now,r['name']))
            elif failed_action and r['pending_action']==failed_action:
                c.execute('UPDATE connections SET pending_action=NULL WHERE name=?',(r['name'],))
                c.execute("UPDATE ingress_state SET action_name=?,action_status='FAILED',action_finished_at=COALESCE(action_finished_at,?),last_error=COALESCE(?,last_error) WHERE connection_name=?",(failed_action,report_now,action_message or error or None,r['name']))
            # Current installed identity is authoritative. Historical successful
            # update state is never accepted as proof of what is installed now.
            # A desired release remains requested until the Client reports the
            # exact installed (version, SHA256) for that release.
            desired_version=str(r['desired_ingress_version'] or '')
            desired_rel=release_for(c,desired_version) if desired_version else None
            desired_sha='' if not desired_rel else str(desired_rel['sha256'] or '').lower()
            exact_desired=bool(
                desired_version and desired_rel and version == desired_version and
                ingress_sha256 and desired_sha and
                hmac.compare_digest(ingress_sha256,desired_sha)
            )
            if exact_desired:
                c.execute(
                    'UPDATE connections SET desired_ingress_version=NULL,desired_ingress_source=NULL,updated_at=? WHERE name=?',
                    (report_now,r['name']),
                )
                c.execute(
                    "UPDATE ingress_state SET update_target=?,update_sha256=?,update_status='CURRENT', "
                    "update_error=NULL,last_error=NULL,update_finished_at=COALESCE(update_finished_at,?) "
                    "WHERE connection_name=?",
                    (desired_version,desired_sha,report_now,r['name']),
                )
            elif desired_version and desired_rel:
                # Do not let stale local CURRENT/COMMITTED evidence erase or
                # visually satisfy an outstanding deployment request. If the
                # Client is not actively processing the exact desired payload,
                # retain the desired command and expose it as QUEUED.
                exact_target=bool(
                    update_target == desired_version and update_sha256 and
                    hmac.compare_digest(update_sha256,desired_sha)
                )
                active_states={'QUEUED','DOWNLOADING','VERIFYING','APPLYING'}
                failure_states={'FAILED','ROLLED_BACK','CANCELLED'}
                if not (exact_target and update_status in active_states | failure_states):
                    c.execute(
                        "UPDATE ingress_state SET update_target=?,update_sha256=?,update_status='QUEUED', "
                        "update_error=NULL,last_error=NULL,update_started_at=NULL,update_finished_at=NULL "
                        "WHERE connection_name=?",
                        (desired_version,desired_sha,r['name']),
                    )
                # Failed deployments intentionally remain desired. A manual
                # retry or the AUTO reconciler may requeue them explicitly.
            config_result=payload.get('config_result')
            config_txid=str(payload.get('config_transaction_id','') or '')
            if config_result=='success' and config_txid:
                tx=c.execute("SELECT * FROM config_pending WHERE connection_name=? AND transaction_id=?",(r['name'],config_txid)).fetchone()
                if tx and tx['state']=='APPLYING':
                    candidate=json.loads(tx['candidate_json']); previous=json.loads(tx['previous_json']); now=int(time.time())
                    c.execute('UPDATE connections SET udp_port=?,xfrm_mtu=?,dns_primary=?,dns_secondary=?,psk=?,pending_action=NULL,updated_at=? WHERE name=?',(candidate['udp_port'],candidate['xfrm_mtu'],candidate['dns_primary'],candidate['dns_secondary'],candidate['psk'],now,r['name']))
                    c.execute('UPDATE enrollment_tokens SET revoked_at=? WHERE connection_name=? AND consumed_at IS NULL AND revoked_at IS NULL',(now,r['name']))
                    Path('/etc/dragon-fruit-relay/clients',r['name'],'pairing-token.txt').unlink(missing_ok=True)
                    if candidate.get('psk') != previous.get('psk'):
                        c.execute("UPDATE ingress_state SET bootstrap_psk_state='rotated' WHERE connection_name=?",(r['name'],))
                    # Client has applied and validated the candidate and the
                    # authoritative connection row is now updated. The temporary
                    # transaction has no remaining purpose; delete it atomically
                    # so COMMITTED can never become a permanent pseudo-active
                    # VERIFYING state. The coordinator treats disappearance as
                    # an already-resolved transaction.
                    c.execute("DELETE FROM config_pending WHERE connection_name=? AND transaction_id=?",(r['name'],config_txid))
                    c.execute("UPDATE ingress_state SET action_name='configuration',action_status='SUCCEEDED',action_message='configuration committed and verified',action_finished_at=?,last_error=NULL WHERE connection_name=?",(now,r['name']))
                    c.execute('INSERT INTO audit(occurred_at,connection_name,action,detail) VALUES(?,?,?,?)',(now,r['name'],'connection-config-committed','configuration applied and verified by Client; transaction finalized'))
            elif config_result=='failed' and config_txid:
                tx=c.execute("SELECT * FROM config_pending WHERE connection_name=? AND transaction_id=?",(r['name'],config_txid)).fetchone()
                if tx:
                    c.execute("UPDATE config_pending SET state='FAILED',updated_at=?,error=? WHERE connection_name=? AND transaction_id=?",(int(time.time()),error or 'Client apply failed',r['name'],config_txid))
                    c.execute("UPDATE ingress_state SET action_name='configuration',action_status='FAILED',action_message=?,action_finished_at=?,last_error=? WHERE connection_name=?",(error or 'Client apply failed',int(time.time()),error or 'Client apply failed',r['name']))
                    if (tx['kind'] or 'manual') == 'bootstrap-psk':
                        c.execute("UPDATE ingress_state SET bootstrap_psk_state='rotation-failed' WHERE connection_name=? AND bootstrap_psk_state='psk-rotation-pending'",(r['name'],))
            r=connection_by_uuid(c,r['connection_uuid'])
            out=response_payload(c,r)

        elif op=='release':
            version=str(payload.get('version',''))
            rel=release_for(c,version)
            if not rel or rel['status']=='revoked': raise ValueError('release unavailable')
            data=Path(rel['payload_path']).read_bytes(); sig=Path(rel['signature_path']).read_bytes()
            if hashlib.sha256(data).hexdigest()!=rel['sha256']: raise ValueError('stored release checksum mismatch')
            out={'version':version,'sha256':rel['sha256'],'manifest':json.loads(rel['manifest_json']),'payload_b64':base64.b64encode(data).decode(),'signature_b64':base64.b64encode(sig).decode()}

        else:
            raise ValueError('unsupported operation')

        c.commit()
        return auth_key,out


def send(conn,obj):
    conn.sendall((compact(obj)+'\n').encode())


def serve_client(conn,addr):
    conn.settimeout(8)
    local_ip=conn.getsockname()[0]; peer_ip=addr[0]
    try:
        data=b''
        while b'\n' not in data and len(data)<2_000_000:
            chunk=conn.recv(65536)
            if not chunk: break
            data+=chunk
        req=json.loads(data.split(b'\n',1)[0].decode())
        key,out=handle(req,local_ip,peer_ip)
        body={'protocol':PROTOCOL,'timestamp':int(time.time()),'nonce':req.get('nonce'),'ok':True,'payload':out}
        send(conn,sign_response(key,body))
    except Exception as exc:
        try: send(conn,{'protocol':PROTOCOL,'timestamp':int(time.time()),'ok':False,'error':str(exc)[:300]})
        except Exception: pass
    finally:
        conn.close()


def desired_addresses():
    if not DB.exists(): return []
    try:
        with db() as c:
            return [r[0] for r in c.execute('SELECT egress_xfrm_ip FROM connections ORDER BY profile_index')]
    except Exception: return []


def main():
    global RUNNING
    signal.signal(signal.SIGTERM,lambda *_: globals().__setitem__('RUNNING',False))
    listeners={}
    while RUNNING:
        wanted={(ip,port) for ip in desired_addresses() for port in PORTS}
        for key in list(listeners):
            if key not in wanted:
                listeners.pop(key).close()
        for ip,port in sorted(wanted):
            key=(ip,port)
            if key in listeners: continue
            try:
                s=socket.socket(socket.AF_INET,socket.SOCK_STREAM); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind((ip,port)); s.listen(16); s.settimeout(1); listeners[key]=s
            except OSError: pass
        if not listeners:
            time.sleep(2); continue
        for s in list(listeners.values()):
            try:
                conn,addr=s.accept()
            except socket.timeout: continue
            except OSError: continue
            threading.Thread(
                target=serve_client,
                args=(conn,addr),
                daemon=True,
                name=f"dfr-control-{addr[0]}",
            ).start()
    for s in listeners.values(): s.close()

if __name__=='__main__': main()
PY_DFR_CONTROL
    sed -i -e "s/__DFR_CONTROL_PORTS__/${CONTROL_PORT}/" -e "s/__DFR_TARGET_SUBSCRIPTION_PORT__/${SUBSCRIPTION_PORT}/" -e "s/__DFR_TARGET_CONTROL_PORT__/${CONTROL_PORT}/" "$CONTROL_RESPONDER"
    chmod 0750 "$CONTROL_RESPONDER"
    python3 -m py_compile "$CONTROL_RESPONDER"
    rm -rf "${HUB_BIN_DIR}/__pycache__" 2>/dev/null || true

    cat > "$CONTROL_UNIT_FILE" <<EOF_DFR_CONTROL_UNIT
# Managed by Dragon Fruit Relay ${APP_VERSION}.
[Unit]
Description=Dragon Fruit Relay ingress CONTROL/1 responder
After=network-online.target dragon-fruit-relay-registry.service
Wants=network-online.target

[Service]
Type=simple
UMask=0077
ExecStart=${CONTROL_RESPONDER}
Restart=always
RestartSec=2s
NoNewPrivileges=yes
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=${STATE_DIR} ${CONFIG_DIR}

[Install]
WantedBy=multi-user.target
EOF_DFR_CONTROL_UNIT
    chmod 0644 "$CONTROL_UNIT_FILE"
    link_managed_unit "$CONTROL_UNIT"
}

control_plane_runtime_current ()
{
    [[ -x "$CONTROL_RESPONDER" ]] || return 1
    grep -Fq "CONTROL_RUNTIME_ID='software-convergence-v1'" "$CONTROL_RESPONDER" 2>/dev/null || return 1
    grep -Fq "'subscription':${SUBSCRIPTION_PORT}" "$CONTROL_RESPONDER" 2>/dev/null || return 1
    grep -Fq "'control':${CONTROL_PORT}" "$CONTROL_RESPONDER" 2>/dev/null
}

activate_control_plane_current ()
{
    local elapsed=0 state=''

    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable "$CONTROL_UNIT" >>"$LOG_FILE" 2>&1 || true

    # Replacing the Python file does not update an already-running responder.
    # A real restart is required so CONTROL/1 immediately serves the current
    # endpoint payload and accepts the current Client capability report.
    if ! systemctl restart "$CONTROL_UNIT" >>"$LOG_FILE" 2>&1; then
        warn 'Client CONTROL/1 responder could not be restarted.'
        return 1
    fi

    while (( elapsed < 10 )); do
        state=$(systemctl is-active "$CONTROL_UNIT" 2>/dev/null || true)
        [[ "$state" == active ]] && return 0
        sleep 1
        elapsed=$((elapsed + 1))
    done

    warn "Client CONTROL/1 responder is ${state:-inactive} after restart."
    return 1
}

start_control_plane_current ()
{
    write_control_plane_files
    activate_control_plane_current || \
        warn 'Client CONTROL/1 responder requires attention.'
}

ensure_control_plane_current ()
{
    hub_configured || return 0
    ensure_update_signing_key

    if [[ ! -x "$CONTROL_RESPONDER" || \
          ! -x "$CONTROL_TX_HELPER" || \
          ! -f "$CONTROL_UNIT_FILE" ]] || \
       ! control_plane_runtime_current; then
        start_control_plane_current
        return 0
    fi

    systemctl is-enabled --quiet "$CONTROL_UNIT" 2>/dev/null || \
        systemctl enable "$CONTROL_UNIT" >/dev/null 2>&1 || true
    systemctl is-active --quiet "$CONTROL_UNIT" 2>/dev/null || \
        systemctl start "$CONTROL_UNIT" >/dev/null 2>&1 || true
}

recover_interrupted_config_change ()
{
    local name transaction_id state

    while IFS=$'\t' read -r name transaction_id state; do
        [[ -n "$name" && "$transaction_id" =~ ^[0-9A-Fa-f-]{36}$ ]] || continue

        if [[ "$state" == COMMITTED ]]; then
            # Both peers already verified the candidate. Only the temporary
            # transaction row survived the interruption; the active config is
            # already authoritative, so finalize instead of rolling it back.
            registry_command config-finalize "$name" "$transaction_id" >/dev/null || true
        else
            warn "Recovering interrupted configuration change for '${name}' (${state})."
            if profile_exists "$name"; then
                if ! dfr_rollback_config_transaction_runtime "$name" "$transaction_id"; then
                    warn "Could not fully restore runtime for '${name}' yet; active registry state remains authoritative."
                fi
            fi
            registry_command config-recover "$name" "$transaction_id" \
                --reason 'Server startup restored the previous active configuration after an interrupted transaction' >/dev/null || true
        fi

    done < <(registry_command config-active 2>/dev/null || true)
}

quiesce_registry_control_plane ()
{
    local unit

    # Registry/runtime refresh must not race with long-running management
    # processes querying or writing authoritative state. Client tunnel
    # services are intentionally not touched.
    for unit in "$CONTROL_UNIT" "$SUBSCRIPTION_UNIT" "$REGISTRY_UNIT"; do
        if systemctl is-active --quiet "$unit" 2>/dev/null; then
            systemctl stop "$unit" >>"$LOG_FILE" 2>&1 ||
                die "Could not stop ${unit} before registry schema/runtime refresh."
        fi
    done

    for unit in "$CONTROL_UNIT" "$SUBSCRIPTION_UNIT" "$REGISTRY_UNIT"; do
        if systemctl is-active --quiet "$unit" 2>/dev/null; then
            die "${unit} is still active; registry schema sanitation was not started."
        fi
    done
}

registry_daemon_runtime_current ()
{
    local main_pid
    main_pid=$(systemctl show -p MainPID --value "$REGISTRY_UNIT" 2>/dev/null || true)
    [[ "$main_pid" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ -r "$REGISTRY_RUNTIME_STATE" ]] || return 1

    python3 - "$REGISTRY_RUNTIME_STATE" "$main_pid" "$APP_VERSION" "$REGISTRY_SCHEMA_CURRENT" "$REGISTRY_RUNTIME_API_REQUIRED" "$REGISTRY_RUNTIME_ID_REQUIRED" <<'PY_REGISTRY_LIVE_CHECK'
import json,pathlib,sys,time
try:
    state=json.loads(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8'))
    expected_pid=int(sys.argv[2])
    expected_version=sys.argv[3]
    expected_schema=int(sys.argv[4])
    expected_api=int(sys.argv[5])
    expected_runtime_id=sys.argv[6]
    heartbeat=int(state.get('heartbeat_at',0) or 0)
    ok=(
        state.get('runtime_id') == expected_runtime_id
        and state.get('app_version') == expected_version
        and int(state.get('schema',0)) == expected_schema
        and int(state.get('runtime_api',0)) == expected_api
        and int(state.get('pid',0)) == expected_pid
        and heartbeat > 0
        and abs(int(time.time())-heartbeat) <= 15
    )
except Exception:
    ok=False
raise SystemExit(0 if ok else 1)
PY_REGISTRY_LIVE_CHECK
}

activate_registry_current ()
{
    local elapsed=0 state=''

    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable "$REGISTRY_UNIT" >>"$LOG_FILE" 2>&1 || true
    rm -f -- "$REGISTRY_RUNTIME_STATE" 2>/dev/null || true

    # Always restart after the full registry refresh. The helper may have been
    # comparison cannot prove that the already-running Python process is current.
    if ! systemctl restart "$REGISTRY_UNIT" >>"$LOG_FILE" 2>&1; then
        warn 'Persistent registry service could not be restarted after runtime refresh.'
        return 1
    fi

    while (( elapsed < 15 )); do
        state=$(systemctl is-active "$REGISTRY_UNIT" 2>/dev/null || true)
        if [[ "$state" == active ]] && registry_daemon_runtime_current; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    warn "Persistent registry live runtime is ${state:-inactive} or did not publish the current ${APP_VERSION} runtime heartbeat."
    return 1
}

repair_partial_v210_registry_if_safe ()
{
    [[ -f "$REGISTRY_DB" ]] || return 0
    load_host_config
    [[ "${PRODUCT_ID:-}" == "$DFR_PRODUCT_ID" && "${PRODUCT_LINEAGE:-}" == "$DFR_PRODUCT_LINEAGE" ]] || return 0
    local verdict backup_dir
    verdict=$(python3 - "$REGISTRY_DB" <<'PY_PARTIAL_REGISTRY'
import sqlite3,sys
p=sys.argv[1]
expected={'meta','hub','server_policy','server_endpoint_fallbacks','connections','subscriptions','usage','audit','ingress_state','control_nonces','enrollment_tokens','config_pending','software_releases','software_release_usage'}
try:
    c=sqlite3.connect(p)
    tables={r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")}
    meta={}
    if 'meta' in tables:
        try: meta={str(k):str(v) for k,v in c.execute('SELECT key,value FROM meta')}
        except sqlite3.Error: meta={}
    current=(tables==expected and meta.get('product')=='dragon-fruit-relay' and meta.get('product_lineage')=='standalone-dfr' and meta.get('registry_schema')=='1')
    if current:
        print('CURRENT'); raise SystemExit
    count=0
    if 'connections' in tables:
        try: count=int(c.execute('SELECT COUNT(*) FROM connections').fetchone()[0])
        except sqlite3.Error: count=1
    print('REBUILD' if count==0 else 'UNSAFE')
except Exception:
    print('UNSAFE')
PY_PARTIAL_REGISTRY
)
    case "$verdict" in
        CURRENT) return 0 ;;
        REBUILD)
            backup_dir="${STATE_DIR}/failed-registry-$(date +%Y%m%d-%H%M%S)"
            install -d -m 0700 "$backup_dir"
            for f in "$REGISTRY_DB" "${REGISTRY_DB}-wal" "${REGISTRY_DB}-shm"; do [[ -e "$f" ]] && mv -f -- "$f" "$backup_dir/"; done
            warn "Recovered an incomplete standalone DFR v2.1.0 registry with zero connections. The invalid database was preserved at ${backup_dir}."
            return 0
            ;;
        *) die 'The standalone DFR registry is not the current schema and contains connection state. Refusing destructive automatic recovery.' ;;
    esac
}

ensure_registry_current ()
{
    hub_configured || return 0
    load_host_config
    command -v nft >/dev/null 2>&1 || {
        info 'Installing nftables for persistent quota and speed enforcement...'
        export DEBIAN_FRONTEND=noninteractive
        apt-get update >>"$LOG_FILE" 2>&1
        apt-get install -y nftables >>"$LOG_FILE" 2>&1 || die 'Could not install nftables.'
    }
    write_registry_runtime_files
    write_subscription_responder
    quiesce_registry_control_plane
    repair_partial_v210_registry_if_safe
    registry_command init --endpoint "$SERVER_ENDPOINT"
    recover_interrupted_config_change
    local registry_name
    while IFS= read -r registry_name; do
        [[ -n "$registry_name" ]] || continue
        profile_exists "$registry_name" || registry_materialize_connection "$registry_name"
    done < <(registry_command list-names)
    activate_registry_current || die "Persistent registry live runtime did not converge to the current ${APP_VERSION} implementation."
    registry_command apply >/dev/null 2>&1 || true
    start_subscription_responder
    start_control_plane_current
    dfr_backup_automation_ensure
}

registry_final_sync ()
{
    [[ -x "$REGISTRY_HELPER" && -f "$REGISTRY_DB" ]] || return 0
    registry_command sync-kernel >/dev/null 2>&1 || true
}


# DFR_AUDIT_SCOPE_SEPARATION


# DFR_MEANINGFUL_SUBSCRIPTION_HISTORY
subscription_history_value ()
{
    local field="$1"
    local value="$2"

    case "$field" in

        starts_at)

            if [[ "$value" == None || -z "$value" ]]; then
                printf 'Immediate'
            else
                date \
                    -d "@${value}" \
                    '+%Y-%m-%d %H:%M:%S %Z' \
                    2>/dev/null ||
                printf '%s' "$value"
            fi
            ;;

        expires_at)

            if [[ "$value" == None || -z "$value" ]]; then
                printf 'Never'
            else
                date \
                    -d "@${value}" \
                    '+%Y-%m-%d %H:%M:%S %Z' \
                    2>/dev/null ||
                printf '%s' "$value"
            fi
            ;;

        quota_bytes)

            if [[ "$value" == None || -z "$value" ]]; then
                printf 'Unlimited'
            else
                format_bytes_short "$value"
            fi
            ;;

        max_upload_mbps|max_download_mbps)

            if [[ "$value" == None || -z "$value" ]]; then
                printf 'Unlimited'
            else
                printf '%s Mbps' "$value"
            fi
            ;;

        *)
            printf '%s' "$value"
            ;;

    esac
}


subscription_history_change_text ()
{
    local detail="$1"

    local item
    local field
    local rest
    local old
    local new
    local label

    local output=''

    local -a items=()


    IFS=';' read -r -a items <<< "$detail"


    for item in "${items[@]}"; do

        item="${item# }"
        item="${item% }"

        [[ "$item" == *:*'->'* ]] || continue


        field="${item%%:*}"
        rest="${item#*:}"

        old="${rest%%->*}"
        new="${rest#*->}"


        case "$field" in

            starts_at)
                label='Start'
                ;;

            expires_at)
                label='Expiration'
                ;;

            quota_bytes)
                label='Allowance'
                ;;

            max_upload_mbps)
                label='Upload speed'
                ;;

            max_download_mbps)
                label='Download speed'
                ;;

            *)
                label="$field"
                ;;

        esac


        old="$(
            subscription_history_value \
                "$field" \
                "$old"
        )"

        new="$(
            subscription_history_value \
                "$field" \
                "$new"
        )"


        [[ -z "$output" ]] ||
            output+='; '


        output+="${label}: ${old} -> ${new}"

    done


    printf '%s' "${output:-$detail}"
}




audit_log_screen ()
{
    local scope="$1" name="${2:-}" title="${3:-LOGS}" page=1 size choice offset output rows timestamp connection action detail local_time event color
    local cols connection_width event_width detail_width idx query_name
    size=$(ui_activity_page_size)
    while true; do
        offset=$(((page-1)*size))
        if [[ -n "$name" ]]; then output=$(registry_command audit "$name" --scope "$scope" --limit "$size" --offset "$offset" 2>/dev/null || true); else output=$(registry_command audit --scope "$scope" --limit "$size" --offset "$offset" 2>/dev/null || true); fi
        rows=$(grep -c . <<<"$output" || true)
        clear_screen
        dfr_ui_header "$title"
        section_title "${name:+${name} | }Logs"
        ui_timezone_line
        IFS=$'\t' read -r connection_width event_width detail_width < <(activity_table_widths "$output")
        printf '\n  %s%-4s %-14s %-*s %-*s | %s%s\n' "$C_DIM" '#' 'TIME' "$connection_width" 'SOURCE' "$event_width" 'EVENT' 'DETAIL' "$C_RESET" > "$TTY_OUT"
        printf '  %s%s%s\n' "$C_DIM" "$(ui_rule $'\u2500')" "$C_RESET" > "$TTY_OUT"
        if [[ -z "$output" ]]; then
            ((page == 1)) && printf '  %sNo matching log records.%s\n' "$C_DIM" "$C_RESET" > "$TTY_OUT" || printf '  %sNo more log records.%s\n' "$C_DIM" "$C_RESET" > "$TTY_OUT"
        else
            idx=0
            while IFS=$'\t' read -r timestamp connection action detail; do
                [[ -n "$timestamp" ]] || continue
                idx=$((idx+1)); [[ "$connection" == '-' || -z "$connection" ]] && connection='SERVER'
                local_time=$(date -d "$timestamp" '+%m-%d %H:%M:%S' 2>/dev/null || printf '%s' "$timestamp")
                case "$action" in
                    subscription-change) detail=$(subscription_history_change_text "$detail") ;;
                    renew) detail='New subscription period started' ;;
                    traffic-reset) detail='Current traffic usage reset; lifetime usage preserved' ;;
                    lifetime-reset) detail='Lifetime traffic reset; current-period usage preserved' ;;
                    suspend) detail='Subscriber traffic suspended' ;;
                    resume) detail='Subscriber traffic resumed' ;;
                esac
                event=$(activity_event_label_for "$action"); color=$(activity_event_color_for "$action")
                activity_print_full_row "$idx" "$local_time" "$connection" "$event" "$detail" "$color" "$connection_width" "$event_width" "$detail_width"
            done <<<"$output"
        fi
        printf '\n  %sPage %s | %s records shown%s\n' "$C_DIM" "$page" "$rows" "$C_RESET" > "$TTY_OUT"
        ui_view_controls basic
        ui_navigation_controls
        printf '\n' > "$TTY_OUT"
        choice=$(prompt '  Select an action: ') || return 0
        case "$choice" in
            n|N|16) ((rows == size)) && page=$((page+1)) ;;
            p|P|17) ((page > 1)) && page=$((page-1)) ;;
            r|R|18) ;;
            g|G|90) ui_global_navigation ;;
            b|B|0) return 0 ;;
            q|Q|99) exit 0 ;;
            *) warn 'Invalid selection.'; sleep 0.35 ;;
        esac
    done
}

subscription_history_screen ()
{
    audit_log_screen subscription "$1" 'SUBSCRIPTION LOGS'
}


connection_history_screen ()
{
    audit_log_screen connection "$1" 'CONNECTION LOGS'
}

hub_history_screen ()
{
    audit_log_screen hub '' 'SERVER LOGS'
}

subscription_menu ()
{
    local name="$1" choice value start expires quota
    while profile_exists "$name"; do
        clear_screen
        dfr_ui_header 'SUBSCRIPTION & TRAFFIC'
        show_client_header "$name"
        subscription_print_summary "$name"
        section_title 'Subscription Actions'
        ui_menu_item 1 'Set Start Date' neutral
        ui_menu_item 2 'Set Expiration Date' neutral
        ui_menu_item 3 'Set Traffic Allowance' neutral
        ui_menu_item 4 'Set Upload Limit' neutral
        ui_menu_item 5 'Set Download Limit' neutral
        ui_menu_item 6 'Renew Subscription Period' positive
        ui_menu_item 7 'Reset Current Usage' caution
        ui_menu_item 8 'Reset Lifetime Usage' destructive
        ui_menu_item 9 'Suspend Subscriber Traffic' caution
        ui_menu_item 10 'Resume Subscriber Traffic' positive
        ui_menu_item 11 'Subscription Logs' neutral
        ui_navigation_footer
        choice=$(prompt '  Select an option: ')
        case "$choice" in
            1) value=$(prompt '  Start date YYYY-MM-DD (or immediate): '); registry_command set "$name" --start "$value" || warn 'Start date was not changed.'; pause_screen ;;
            2) value=$(prompt '  Expiration YYYY-MM-DD (or never): '); registry_command set "$name" --expires "$value" || warn 'Expiration was not changed.'; pause_screen ;;
            3) value=$(prompt '  Traffic allowance (examples 500GB, 2TB, unlimited): '); registry_command set "$name" --quota "$value" || warn 'Traffic allowance was not changed.'; pause_screen ;;
            4) value=$(prompt '  Upload speed in Mbps (or unlimited): '); registry_command set "$name" --upload-mbps "$value" || warn 'Upload speed was not changed.'; pause_screen ;;
            5) value=$(prompt '  Download speed in Mbps (or unlimited): '); registry_command set "$name" --download-mbps "$value" || warn 'Download speed was not changed.'; pause_screen ;;
            6)
                start=$(prompt '  New period start YYYY-MM-DD (blank = now): ')
                expires=$(prompt '  New expiration YYYY-MM-DD (blank = keep current): ')
                quota=$(prompt '  New quota (blank = keep current): ')
                local -a args=(renew "$name")
                [[ -n "$start" ]] && args+=(--start "$start")
                [[ -n "$expires" ]] && args+=(--expires "$expires")
                [[ -n "$quota" ]] && args+=(--quota "$quota")
                if confirm 'Start the new period and reset current traffic usage to zero? Lifetime traffic will be preserved.' no; then
                    registry_command "${args[@]}" && success 'New traffic period started; current usage reset and lifetime preserved.' || warn 'Renewal failed.'
                fi
                pause_screen
                ;;
            7)
                if confirm "Reset current traffic usage to zero for '${name}'? Lifetime traffic will be preserved." no; then
                    registry_command reset-current "$name" && success 'Current traffic usage reset to zero; lifetime traffic preserved.' || warn 'Traffic reset failed.'
                fi
                pause_screen
                ;;
            8)
                warn 'This permanently resets the lifetime traffic counter. Current-period usage is not changed.'
                if confirm "Reset lifetime traffic to zero for '${name}'?" no; then
                    registry_command reset-lifetime "$name" && success 'Lifetime traffic reset to zero; current-period usage preserved.' || warn 'Lifetime reset failed.'
                fi
                pause_screen
                ;;
            9) if confirm "Suspend forwarded subscriber traffic for '${name}'?" no; then registry_command suspend "$name" || warn 'Subscriber traffic could not be suspended.'; fi; pause_screen ;;
            10) if registry_command resume "$name"; then success 'Subscriber traffic resumed.'; else warn 'Subscriber traffic could not be resumed.'; fi; pause_screen ;;
            11)
                subscription_history_screen "$name"
                pause_screen
                ;;
            g|G|90) ui_global_navigation ;;
            b|B|0) return 0 ;;
            q|Q|99) exit 0 ;;
            *) warn 'Invalid selection.'; sleep 0.35 ;;
        esac
    done
}





registry_materialize_connection ()
{
    local name="$1"
    load_host_config
    eval "$(registry_command export-shell "$name")"
    write_client_profile "$name"
    load_client_profile "$name"
    write_client_strongswan "$name"
    write_client_swanctl "$name"
}

registry_materialize_all_connections ()
{
    local name port_conflicts=''
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        eval "$(registry_command export-shell "$name")"
        if ss -H -lun 2>/dev/null | grep -Eq "[:.]${NATT_PORT}[[:space:]]"; then
            port_conflicts+="${name}: UDP ${NATT_PORT}\n"
        fi
        if ip link show dev "$XFRM_IF" >/dev/null 2>&1; then
            die "Restore requires ${XFRM_IF} for ${name}, but that interface already exists."
        fi
    done < <(registry_command list-names)
    [[ -z "$port_conflicts" ]] || die "Restore cannot preserve required connection ports because they are already in use:\n${port_conflicts}"

    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        registry_materialize_connection "$name"
    done < <(registry_command list-names)
}

restore_egress_backup ()
{
    local file="$1" detected_public detected_gateway name dns_now
    [[ -f "$file" ]] || die "Backup file not found: $file"
    hub_configured && die 'Disaster restore requires an unconfigured Server.'
    local restore_copy
    restore_copy=$(mktemp /tmp/dragon-fruit-relay-restore.XXXXXX.dfrbak)
    cp -a -- "$file" "$restore_copy"
    chmod 0600 "$restore_copy"
    file="$restore_copy"

    clean_abandoned_install_before_setup
    backup_egress_paths
    backup_original "$CLIENT_UNIT_TEMPLATE"
    backup_original "$REGISTRY_UNIT_FILE"
    install_dependencies

    WAN_IF=$(detect_default_interface)
    [[ -n "$WAN_IF" ]] || die 'No IPv4 default route was detected.'
    LOCAL_IP=$(detect_local_ipv4 "$WAN_IF")
    [[ -n "$LOCAL_IP" ]] || die "No global IPv4 address was detected on ${WAN_IF}."
    detected_gateway=$(detect_default_gateway || true)
    detected_public=$(detect_public_ipv4 || true)
    [[ -n "$detected_public" ]] || die 'Could not establish this replacement server public IPv4.'
    PUBLIC_IP="$detected_public"
    show_detected_network "$detected_gateway"

    ensure_hub_layout
    write_registry_runtime_files
    registry_command backup-verify "$file" >"$TTY_OUT"
    SERVER_ENDPOINT=$(registry_command backup-restore "$file")
    validate_server_endpoint "$SERVER_ENDPOINT" || die 'The backup contains an invalid Server endpoint.'

    write_hub_host_config
    write_hub_readme
    install_self_copy
    write_hub_helpers
    write_hub_sysctl
    systemctl disable --now strongswan.service >/dev/null 2>&1 || true

    registry_materialize_all_connections

    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        start_hub_client "$name" || die "Restored connection '${name}' could not start on this server."
    done < <(registry_command list-names)

    systemctl enable --now "$REGISTRY_UNIT" >>"$LOG_FILE" 2>&1 || warn 'Registry service could not start.'
    registry_command apply >/dev/null 2>&1 || warn 'Subscription/speed policy requires attention; use Repair after restore.'
    start_subscription_responder
    start_control_plane_current
    dfr_backup_automation_ensure

    dns_now=$(resolve_endpoint_ipv4s "$SERVER_ENDPOINT" || true)
    success 'Portable Server restore completed.'
    print_check info 'Server endpoint' "$SERVER_ENDPOINT" accent
    print_check info 'This server IPv4' "$PUBLIC_IP" accent
    if validate_ipv4 "$SERVER_ENDPOINT"; then
        print_check pass 'Endpoint' 'Backup uses the public IPv4 directly.'
    elif [[ "$dns_now" == "$PUBLIC_IP" ]]; then
        print_check pass 'DNS cutover' 'DNS already points to this Server.'
    else
        print_check warn 'DNS cutover required' "${SERVER_ENDPOINT} currently resolves to ${dns_now:-nothing}; change it to ${PUBLIC_IP}."
    fi
    pause_screen
    hub_interactive_menu
}

setup_egress_hub ()
{
    clear_screen
    dfr_ui_header 'SERVER INSTALLATION'
    ui_summary_begin 'Installation plan' 'READY'
    ui_summary_row 'Role' 'Egress Hub (Server)'
    ui_summary_row 'Product' 'Standalone Dragon Fruit Relay v2.1.0'
    ui_summary_row 'Topology' 'Multi-Client managed Internet egress'
    ui_summary_row 'Endpoint' 'Public IPv4 by default · optional FQDN'
    hub_configured && { warn 'This machine is already configured as a Dragon Fruit Relay Server.'; return 0; }
    [[ -f "$CONFIG_FILE" && ! -f "$HOST_CONFIG_FILE" ]] && die 'A Client is configured on this machine. Remove the Client configuration before initializing a Server.'
    clean_abandoned_install_before_setup
    backup_egress_paths
    backup_original "$CLIENT_UNIT_TEMPLATE"
    backup_original "$REGISTRY_UNIT_FILE"
    install_dependencies
    WAN_IF=$(detect_default_interface); [[ -n "$WAN_IF" ]] || die 'No IPv4 default route was detected.'
    LOCAL_IP=$(detect_local_ipv4 "$WAN_IF"); [[ -n "$LOCAL_IP" ]] || die "No global IPv4 address was detected on ${WAN_IF}."
    local detected_public detected_gateway
    detected_gateway=$(detect_default_gateway || true); detected_public=$(detect_public_ipv4 || true)
    [[ -n "$detected_public" ]] || die 'A stable public IPv4 could not be established for this Server.'
    PUBLIC_IP="$detected_public"
    show_detected_network "$detected_gateway"
    section_title 'Server endpoint'
    SERVER_ENDPOINT=$(prompt_egress_endpoint "$PUBLIC_IP")
    section_title 'Applying Server configuration'
    print_check info 'Configuration transaction' 'Preparing registry, CONTROL, subscription and host runtime...'
    backup_egress_runtime_sysctls
    if ! ( ensure_hub_layout && write_hub_host_config && write_hub_readme && install_self_copy && write_hub_helpers && registry_command init --endpoint "$SERVER_ENDPOINT" && ensure_bundled_ingress_stable_release && start_subscription_responder && { systemctl disable --now strongswan.service >/dev/null 2>&1 || true; } && write_hub_sysctl ); then
        error 'Server initialization failed; rolling back the partial installation.'; rollback_hub_initialization; return 1
    fi
    systemctl enable --now "$REGISTRY_UNIT" >>"$LOG_FILE" 2>&1 || warn 'Persistent registry service could not be started yet.'
    start_control_plane_current || true
    dfr_backup_automation_ensure
    clear_screen
    dfr_ui_header 'SERVER INSTALLATION'
    ui_summary_begin 'Installation complete' 'READY'
    ui_summary_row 'Role' 'Egress Hub (Server)'
    ui_summary_row 'Server endpoint' "$SERVER_ENDPOINT" accent
    ui_summary_row 'Public IPv4' "$PUBLIC_IP" accent
    ui_summary_row 'Registry schema' 'DFR schema 1'
    ui_summary_row 'Management plane' 'CONTROL/1 + subscription responder'
    ui_summary_row 'Client software' "${BUNDLED_INGRESS_VERSION} STABLE · new Clients AUTO/LATEST" state
    ui_summary_row 'Connections' '0 · ready for enrollment'
    section_title 'Next action'
    printf '  Create the first Client connection now, or continue to the Server dashboard.\n\n' > "$TTY_OUT"
    if confirm 'Create the first Client connection now' yes; then add_client_interactive || true; fi
    DFR_SETUP_UI_ACTIVE=no
    pause_screen
    hub_interactive_menu
}

show_client_header ()
{
    local name="$1" snapshot uuid status presence peer transport endpoint tunnel='-'
    snapshot=$(fleet_snapshot_file 2>/dev/null || true)
    readarray -t _client_header < <(python3 - "$snapshot" "$name" <<'PY_CLIENT_HEADER'
import json,sys
try:d=json.load(open(sys.argv[1],encoding='utf-8')) if sys.argv[1] else {}
except Exception:d={}
x=next((r for r in d.get('connections',[]) if r.get('name')==sys.argv[2]),{})
for v in (x.get('uuid_short') or '-',x.get('runtime_status') or 'UNKNOWN',x.get('presence') or 'UNKNOWN',x.get('remote_peer') or '-',x.get('udp_port') or 0,x.get('endpoint_state') or 'UNKNOWN'): print(v)
PY_CLIENT_HEADER
)
    uuid=${_client_header[0]:--}; status=${_client_header[1]:-UNKNOWN}; presence=${_client_header[2]:-UNKNOWN}; peer=${_client_header[3]:--}
    transport="UDP ${_client_header[4]:-0}"; endpoint=${_client_header[5]:-UNKNOWN}
    if load_client_profile "$name" 2>/dev/null; then tunnel="${EGRESS_XFRM_IP} -> ${INGRESS_XFRM_IP}"; fi
    ui_summary_begin 'Connection context'
    ui_summary_row 'Connection' "$name" identity
    [[ "$uuid" == - ]] || ui_summary_row 'Connection ID' "$uuid" identity
    ui_summary_row 'Runtime' "$status" state
    ui_summary_row 'Presence' "$presence" state
    ui_summary_row 'Transport' "$transport" plain
    ui_summary_row 'Remote peer' "$peer" "$([[ "$peer" == - ]] && printf muted || printf identity)"
    ui_summary_row 'Tunnel' "$tunnel" "$([[ "$tunnel" == - ]] && printf muted || printf identity)"
    ui_summary_row 'Endpoint' "$endpoint" accent
}




show_detected_network () 
{ 
    local gateway="${1:-}";
    section_title 'Detected network';
    print_check pass 'Internet interface' "$WAN_IF" identity;
    print_check info 'Interface address' "$LOCAL_IP (automatic; no input required)";
    [[ -n "$gateway" ]] && print_check info 'Default gateway' "$gateway (detected automatically)";
    [[ -n "${PUBLIC_IP:-}" ]] && print_check info 'Observed public IPv4' "$PUBLIC_IP" accent;
    return 0
}


snapshot_traffic_text () 
{ 
    printf 'RX %s/%s pkts | TX %s/%s pkts' "$(format_bytes_short "$SNAP_RX_BYTES")" "$SNAP_RX_PACKETS" "$(format_bytes_short "$SNAP_TX_BYTES")" "$SNAP_TX_PACKETS"
}

start_all_clients () 
{ 
    local name failures=0;
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue;
        start_hub_client "$name" || failures=$((failures + 1));
    done < <(profile_names);
    ((failures == 0)) || return 1
}

client_management_listeners_ready ()
{
    local name="$1" listeners
    load_host_config
    load_client_profile "$name"
    listeners=$(ss -H -ltn 2>/dev/null || true)
    grep -Fq "${EGRESS_XFRM_IP}:${SUBSCRIPTION_PORT}" <<<"$listeners" || return 1
    grep -Fq "${EGRESS_XFRM_IP}:${CONTROL_PORT}" <<<"$listeners"
}

wait_client_management_listeners ()
{
    local name="$1" elapsed=0
    while (( elapsed < 10 )); do
        client_management_listeners_ready "$name" && return 0
        sleep 1
        elapsed=$((elapsed+1))
    done
    return 1
}

refresh_client_management_plane ()
{
    local name unit active=0 ready=0 stopped=0 failed=0

    # Rebuild both responders from the current standalone DFR implementation.
    # Endpoint delivery is Client-pull over CONTROL/1, so a registry requeue is
    # meaningless unless the tunnel-scoped management listeners are reachable.
    write_subscription_responder || {
        print_check fail 'Subscription responder' 'Could not refresh the management responder.'
        return 1
    }
    write_control_plane_files || {
        print_check fail 'CONTROL/1 responder' 'Could not refresh the management responder.'
        return 1
    }
    systemctl daemon-reload >/dev/null 2>&1 || true

    if systemctl restart "$SUBSCRIPTION_UNIT" >>"$LOG_FILE" 2>&1; then
        print_check pass 'Subscription responder' 'Runtime refreshed.'
    else
        print_check fail 'Subscription responder' 'Service restart failed.'
        failed=$((failed+1))
    fi
    if activate_control_plane_current; then
        print_check pass 'CONTROL/1 responder' 'Runtime refreshed.'
    else
        print_check fail 'CONTROL/1 responder' 'Service restart failed.'
        failed=$((failed+1))
    fi

    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        unit=$(profile_service "$name")
        if ! systemctl is-active --quiet "$unit"; then
            stopped=$((stopped+1))
            continue
        fi
        active=$((active+1))
        if ! apply_client_network_rules "$name"; then
            print_check fail "${name} management path" 'Tunnel firewall rules could not be restored.'
            failed=$((failed+1))
            continue
        fi
        if wait_client_management_listeners "$name"; then
            ready=$((ready+1))
        else
            print_check fail "${name} management path" 'CONTROL/subscription listeners are not bound to the Server XFRM address.'
            failed=$((failed+1))
        fi
    done < <(profile_names)

    print_check info 'Active Client runtimes' "$active"
    print_check pass 'Management paths ready' "$ready/${active}"
    (( stopped == 0 )) || print_check warn 'Stopped Clients' "$stopped · left stopped; endpoint work remains deferred"
    if (( failed > 0 )); then
        print_check fail 'Management-plane verification' "$failed problem(s) require attention before every Client can synchronize."
        return 1
    fi
    print_check pass 'Management-plane verification' 'Every active Client has reachable CONTROL/subscription listeners.'
    return 0
}

start_hub_client ()
{
    local name="$1" unit
    profile_exists "$name" || die "Client profile '${name}' does not exist."
    write_hub_helpers
    unit=$(profile_service "$name")
    systemctl daemon-reload
    if ! systemctl enable --now "$unit" >> "$LOG_FILE" 2>&1; then
        error "Client '${name}' failed to start."
        systemctl status "$unit" --no-pager -l 2>&1 | tail -n 80 > "$TTY_OUT" || true
        journalctl -u "$unit" -n 100 --no-pager -l 2>&1 > "$TTY_OUT" || true
        return 1
    fi
    profile_listener_ok "$name" || { error "Client '${name}' started but its configured UDP listener is missing."; return 1; }
    apply_client_network_rules "$name" || { error "Client '${name}' started, but its forwarding/NAT/management firewall rules could not be installed."; return 1; }
    start_subscription_responder || true
    ensure_control_plane_current || true
    if ! wait_client_management_listeners "$name"; then
        error "Client '${name}' tunnel is up, but its CONTROL/subscription listeners did not bind to the Server XFRM address."
        systemctl status "$CONTROL_UNIT" "$SUBSCRIPTION_UNIT" --no-pager -l 2>&1 | tail -n 100 > "$TTY_OUT" || true
        return 1
    fi
    registry_command apply >/dev/null 2>&1 || warn "Subscription/speed policy could not be applied for ${name}."
    success "Client '${name}' is ready."
}




semantic_state_color ()
{
    local state="${1:--}"
    state=${state^^}
    case "$state" in
        ONLINE|OPERATIONAL|ACTIVE|AVAILABLE|ENABLED|'ENABLED-RUNTIME'|ESTABLISHED|INSTALLED|LATEST|SYNCED|COMPATIBLE|HEALTHY|CURRENT|ENROLLED|RUNNING|SCHEDULED|COMPLETE|SUCCESS|VERIFIED|CONNECTED|RESTORED|PUBLISHED|PRESENT|VALID|APPLIED|COMMITTED|CONVERGED|'ROLLBACK READY'|PASS|OK|ARMED|SUCCEEDED|LISTENING|REACHABLE)
            printf '%s' "$C_GREEN" ;;
        READY|AUTO|AUTOMATIC|MANUAL|PINNED|STABLE|STAGED|TARGET|CANARY|MEMBER|CHECKING|UPDATING|UPDATED|INSTALLING|MIGRATING|RECONCILING|STARTING|ACTIVATING|STATIC|GENERATED|INDIRECT|TRANSIENT|LINKED|'LINKED-RUNTIME'|ADVISORY|LIMITED|UNLIMITED|'ENDPOINT MIGRATION'|'CONFIG VERIFIED'|DOWNLOADING|VERIFYING|APPLYING|PREPARING|PREPARED|RELOADING|ALIAS)
            printf '%s' "$C_CYAN" ;;
        STALE|DEGRADED|STOPPED|DISCONNECTED|SUSPENDED|PAUSED|WAITING|PENDING|QUEUED|DEACTIVATING|WARNING|'HEALTHY WITH WARNINGS'|'UPDATE REQUIRED'|'UPGRADE REQUIRED'|UNAVAILABLE|RETRYING|DEFERRED|'IN PROGRESS'|ATTENTION|'TEMPORARILY EXCLUDED'|'ROLLED BACK'|'ROLLING BACK'|'PASS WITH WARNINGS'|CANCELLED|MAINTENANCE|'AUTO-RESTART'|ROLLED_BACK|TEMPORARY)
            printf '%s' "$C_YELLOW" ;;
        OFFLINE|FAILED|MISSING|ERROR|EXPIRED|REVOKED|BLOCKED|INCOMPATIBLE|UNHEALTHY|CRITICAL|MASKED|'MASKED-RUNTIME'|'ROLLBACK FAILED'|'NOT FOUND'|'QUOTA EXHAUSTED'|'NOT COMPATIBLE'|UNREACHABLE|FAIL|DOWN|'NOT-FOUND')
            printf '%s' "$C_RED" ;;
        DISABLED|INACTIVE|'NEVER SEEN'|'NOT ENROLLED'|'NOT MEMBER'|UNKNOWN|EMPTY|IDLE|NONE|'NONE YET'|NEVER|'NOT CONFIGURED'|'NO ACTIVE ALERTS'|'NO ACTIVE WORK'|'NO BACKUPS'|'NOT REPORTED'|'N/A'|-|'')
            printf '%s' "$C_DIM" ;;
        *)
            printf '%s' "$C_WHITE" ;;
    esac
}

semantic_colorize_line ()
{
    local rest="${1:-}" segment first=yes
    # Preserve the shared FIELD | VALUE and summary "a | b | c" visual grammar.
    while [[ "$rest" == *' | '* ]]; do
        segment=${rest%%' | '*}
        [[ "$first" == yes ]] || printf ' | '
        semantic_colorize_segment "$segment"
        first=no
        rest=${rest#*' | '}
    done
    [[ "$first" == yes ]] || printf ' | '
    semantic_colorize_segment "$rest"
}


status_color_for ()
{
    semantic_state_color "${1:-UNKNOWN}"
}

stop_all_clients () 
{ 
    local name;
    confirm 'Temporarily stop every Client connection? They remain enabled for the next boot.' no || return 0;
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue;
        stop_hub_client "$name" no;
    done < <(profile_names);
    success 'All client connections are stopped for the current boot.'
}

stop_hub_client () 
{ 
    local name="$1" disable="${2:-no}" unit;
    profile_exists "$name" || die "Client profile '${name}' does not exist.";
    unit=$(profile_service "$name");
    registry_final_sync;
    remove_client_network_rules "$name";
    if [[ "$disable" == yes ]]; then
        timeout 25s systemctl disable --now "$unit" > /dev/null 2>&1 || true;
    else
        timeout 25s systemctl stop "$unit" > /dev/null 2>&1 || true;
    fi;
    load_client_profile "$name";
    delete_link_bounded "$XFRM_IF" || true;
    rm -f -- "$VICI_SOCKET";
}

success () 
{ 
    log_line OK "$*";
    if [[ "${DFR_SETUP_UI_ACTIVE:-no}" == yes ]]; then
        print_check pass 'Progress' "$*"
    else
        printf '%s[OK]%s %s\n' "$C_GREEN" "$C_RESET" "$*" > "$TTY_OUT"
    fi
}

tunnel_network_conflicts () 
{ 
    local cidr="$1";
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

udp_listener_exists ()
{
    local port="$1";
    local sockets;

    sockets=$(ss -H -lunp 2> /dev/null || true);
    grep -Eq "[:.]${port}[[:space:]]" <<< "$sockets"
}

udp_port_in_use_live () 
{ 
    local port="$1";
    ss -H -lun 2> /dev/null | awk -v port=":${port}" '$5 ~ port "$" {found=1} END {exit !found}'
}




validate_ipv4 () 
{ 
    local ip="$1";
    local a b c d extra;
    IFS=. read -r a b c d extra <<< "$ip";
    [[ -z "${extra:-}" && -n "${a:-}" && -n "${b:-}" && -n "${c:-}" && -n "${d:-}" ]] || return 1;
    local octet;
    for octet in "$a" "$b" "$c" "$d";
    do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1;
        ((10#$octet >= 0 && 10#$octet <= 255)) || return 1;
    done
}

validate_profile_name () 
{ 
    local value="$1";
    ((${#value} >= 1 && ${#value} <= PROFILE_NAME_MAX)) || return 1;
    [[ "$value" =~ ^[a-z0-9][a-z0-9_-]*$ ]]
}


validate_uint_range () 
{ 
    local value="$1" min="$2" max="$3";
    [[ "$value" =~ ^[0-9]+$ ]] || return 1;
    ((value >= min && value <= max))
}


warn () 
{ 
    log_line WARN "$*";
    if [[ "${DFR_SETUP_UI_ACTIVE:-no}" == yes ]]; then
        print_check warn 'Attention' "$*"
    else
        printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" > "$TTY_OUT"
    fi
}

write_client_profile () 
{ 
    local name="$1";
    local dir created_epoch;
    dir=$(profile_dir "$name");
    install -d -m 0700 "$dir";
    created_epoch="${PROFILE_CREATED_EPOCH:-}";
    if [[ ! "$created_epoch" =~ ^[0-9]+$ ]] && [[ -f "$dir/profile.conf" ]]; then
        created_epoch=$(set +u
source "$dir/profile.conf"
printf '%s' "${PROFILE_CREATED_EPOCH:-}");
    fi;
    [[ "$created_epoch" =~ ^[0-9]+$ ]] || created_epoch=$(date +%s);
    PROFILE_CREATED_EPOCH="$created_epoch";
    VICI_SOCKET=$(profile_vici_socket "$name");
    VICI_URI=$(profile_vici_uri "$name");
    SWANCTL_CANONICAL=$(profile_swanctl_canonical "$name");
    STRONGSWAN_CANONICAL=$(profile_strongswan_canonical "$name");
    write_shell_config "$dir/profile.conf" "PRODUCT_ID=${DFR_PRODUCT_ID}" "PRODUCT_LINEAGE=${DFR_PRODUCT_LINEAGE}" "PROFILE_SCHEMA=${PROFILE_SCHEMA_CURRENT}" "MANAGED_BY_VERSION=${APP_VERSION}" "PROFILE_NAME=${name}" "PROFILE_INDEX=${PROFILE_INDEX}" "PROFILE_CREATED_EPOCH=${PROFILE_CREATED_EPOCH}" 'ROLE=egress-client' "WAN_IF=${WAN_IF}" "LOCAL_IP=${LOCAL_IP}" "PUBLIC_IP=${PUBLIC_IP}" "SERVER_ENDPOINT=${SERVER_ENDPOINT:-}" "PORT_MODE=${PORT_MODE}" "IKE_PORT=${IKE_PORT}" "NATT_PORT=${NATT_PORT}" "TUNNEL_CIDR=${TUNNEL_CIDR}" "XFRM_IF=${XFRM_IF}" "XFRM_ID=${XFRM_ID}" "XFRM_MTU=${XFRM_MTU}" "INGRESS_XFRM_CIDR=${INGRESS_XFRM_CIDR}" "EGRESS_XFRM_CIDR=${EGRESS_XFRM_CIDR}" "INGRESS_XFRM_IP=${INGRESS_XFRM_IP}" "EGRESS_XFRM_IP=${EGRESS_XFRM_IP}" "INGRESS_ID=${INGRESS_ID}" "EGRESS_ID=${EGRESS_ID}" "DNS_PRIMARY=${DNS_PRIMARY}" "DNS_SECONDARY=${DNS_SECONDARY}" "PSK=${PSK}" "VICI_SOCKET=${VICI_SOCKET}" "VICI_URI=${VICI_URI}" "SWANCTL_CANONICAL=${SWANCTL_CANONICAL}" "STRONGSWAN_CANONICAL=${STRONGSWAN_CANONICAL}";
    chmod 600 "$dir/profile.conf"
}

write_client_swanctl () 
{ 
    local name="$1" source canonical canonical_dir credential_dir;
    source=$(profile_swanctl_source "$name");
    canonical=$(profile_swanctl_canonical "$name");
    canonical_dir=$(profile_swanctl_dir "$name");
    if [[ -d "$canonical_dir" && ! -e "$canonical_dir/.dragon-fruit-relay-profile" ]]; then
        if find "$canonical_dir" -mindepth 1 -maxdepth 1 -print -quit 2> /dev/null | grep -q .; then
            die "Refusing to modify unmanaged swanctl profile directory: ${canonical_dir}";
        fi;
    else
        if [[ -e "$canonical_dir" && ! -d "$canonical_dir" ]]; then
            die "Canonical swanctl profile path is not a directory: ${canonical_dir}";
        fi;
    fi;
    install -d -m 0750 "$canonical_dir";
    : > "$canonical_dir/.dragon-fruit-relay-profile";
    chmod 0640 "$canonical_dir/.dragon-fruit-relay-profile";
    for credential_dir in x509 x509ca x509ocsp x509aa x509ac x509crl pubkey private rsa ecdsa pkcs8 pkcs12;
    do
        local credential_source="$(profile_dir "$name")/$credential_dir";
        local credential_link="$canonical_dir/$credential_dir";
        install -d -m 0700 "$credential_source";
        if [[ -e "$credential_link" || -L "$credential_link" ]]; then
            if [[ -L "$credential_link" && "$(readlink -f -- "$credential_link" 2> /dev/null || true)" == "$(readlink -f -- "$credential_source")" ]]; then
                continue;
            fi;
            if [[ -d "$credential_link" ]] && ! find "$credential_link" -mindepth 1 -print -quit 2> /dev/null | grep -q .; then
                rmdir "$credential_link";
            else
                die "Refusing to replace unmanaged credential path: ${credential_link}";
            fi;
        fi;
        ln -s "$credential_source" "$credential_link";
    done;
    cat > "$source" <<EOF_SWANCTL
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

    chmod 0600 "$source";
    ensure_managed_symlink "$source" "$canonical"
}



write_egress_sysctl () 
{ 
    ensure_hub_layout;
    cat > "$SYSCTL_MANAGED_FILE" <<EOF_SYSCTL
# Managed by Dragon Fruit Relay.
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

    chmod 0644 "$SYSCTL_MANAGED_FILE";
    install_managed_link "$SYSCTL_MANAGED_FILE" "$SYSCTL_FILE";
    sysctl --system >> "$LOG_FILE" 2>&1
}

write_subscription_responder ()
{
    ensure_hub_layout

    cat > "$SUBSCRIPTION_RESPONDER" <<'PY_SUBSCRIPTION_RESPONDER'
#!/usr/bin/env python3
import selectors
import signal
import socket
import sqlite3
import time
from pathlib import Path

DB = Path('/var/lib/dragon-fruit-relay/database/registry.sqlite3')
PORTS = [__DFR_SUBSCRIPTION_PORTS__]
PROTOCOL = 'DRAGON-FRUIT-RELAY-SUBSCRIPTION/1'
RUNNING = True


def db_connect():
    connection = sqlite3.connect(str(DB), timeout=3)
    connection.row_factory = sqlite3.Row
    connection.execute('PRAGMA busy_timeout=3000')
    return connection



def desired_local_ips():
    if not DB.exists():
        return set()
    try:
        with db_connect() as connection:
            return {
                str(row['egress_xfrm_ip'])
                for row in connection.execute(
                    "SELECT egress_xfrm_ip FROM connections"
                )
                if row['egress_xfrm_ip']
            }
    except sqlite3.Error:
        return set()


def effective_state(row, now):
    if int(row['manual_suspended'] or 0):
        return 'SUSPENDED'
    if row['starts_at'] is not None and now < int(row['starts_at']):
        return 'SCHEDULED'
    if row['expires_at'] is not None and now >= int(row['expires_at']):
        return 'EXPIRED'
    directional = int(row['period_upload_bytes']) + int(row['period_download_bytes'])
    used = max(directional, int(row['quota_used_bytes'] or 0))
    if row['quota_bytes'] is not None and used >= int(row['quota_bytes']):
        return 'QUOTA_EXHAUSTED'
    return 'ACTIVE'


def lookup(profile, peer_ip, local_ip):
    with db_connect() as connection:
        return connection.execute(
            """
            SELECT c.name,c.ingress_xfrm_ip,c.egress_xfrm_ip,
                   s.starts_at,s.expires_at,s.quota_bytes,
                   s.max_upload_mbps,s.max_download_mbps,s.manual_suspended,
                   s.updated_at AS subscription_updated_at,
                   u.period_upload_bytes,u.period_download_bytes,
                   u.quota_used_bytes,u.lifetime_upload_bytes,
                   u.lifetime_download_bytes,u.last_sync_at
              FROM connections c
              JOIN subscriptions s ON s.connection_name=c.name
              JOIN usage u ON u.connection_name=c.name
             WHERE c.name=?
               AND c.ingress_xfrm_ip=?
               AND c.egress_xfrm_ip=?
            """,
            (profile, peer_ip, local_ip),
        ).fetchone()


def read_request(connection):
    connection.settimeout(2)
    data = b''
    while len(data) < 4096:
        chunk = connection.recv(1024)
        if not chunk:
            break
        data += chunk
        if b'\n\n' in data or b'\r\n\r\n' in data:
            break
    text = data.decode('utf-8', errors='replace').replace('\r', '')
    lines = text.split('\n')
    if not lines or lines[0] != PROTOCOL:
        return None
    profile = None
    for line in lines[1:]:
        if line.startswith('PROFILE='):
            profile = line.split('=', 1)[1].strip()
            break
    if not profile or len(profile) > 32:
        return None
    return profile


def send_record(connection, row):
    now = int(time.time())
    directional = int(row['period_upload_bytes']) + int(row['period_download_bytes'])
    used = max(directional, int(row['quota_used_bytes'] or 0))
    quota = row['quota_bytes']
    remaining = None if quota is None else max(0, int(quota) - used)
    lifetime = int(row['lifetime_upload_bytes']) + int(row['lifetime_download_bytes'])
    updated = max(int(row['subscription_updated_at'] or 0), int(row['last_sync_at'] or 0))

    def value(item, unlimited=False):
        if item is None:
            return 'UNLIMITED' if unlimited else '0'
        return str(int(item)) if isinstance(item, (int, float)) else str(item)

    lines = [
        PROTOCOL,
        f"PROFILE={row['name']}",
        f"STATE={effective_state(row, now)}",
        f"STARTS_AT={value(row['starts_at'])}",
        f"EXPIRES_AT={value(row['expires_at'])}",
        f"QUOTA_BYTES={value(quota, unlimited=True)}",
        f"UPLOAD_BYTES={int(row['period_upload_bytes'])}",
        f"DOWNLOAD_BYTES={int(row['period_download_bytes'])}",
        f"USED_BYTES={used}",
        f"REMAINING_BYTES={value(remaining, unlimited=True)}",
        f"LIFETIME_BYTES={lifetime}",
        f"MAX_UPLOAD_MBPS={value(row['max_upload_mbps'], unlimited=True)}",
        f"MAX_DOWNLOAD_MBPS={value(row['max_download_mbps'], unlimited=True)}",
        f"UPDATED_EPOCH={updated}",
        'END=1',
        '',
    ]
    connection.sendall(('\n'.join(lines)).encode('utf-8'))


def handle(listener):
    connection, address = listener.accept()
    try:
        peer_ip = address[0]
        local_ip = connection.getsockname()[0]
        profile = read_request(connection)
        if not profile:
            return
        # Counter state is maintained continuously by the resident registry daemon.
        # Avoid spawning a registry process for every subscription request.
        row = lookup(profile, peer_ip, local_ip)
        if row is None:
            return
        send_record(connection, row)
    except (OSError, sqlite3.Error):
        pass
    finally:
        try:
            connection.close()
        except OSError:
            pass


def stop(_signum, _frame):
    global RUNNING
    RUNNING = False


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
selector = selectors.DefaultSelector()
listeners = {}
last_reconcile = 0.0

while RUNNING:
    now_mono = time.monotonic()
    if now_mono - last_reconcile >= 2.0:
        wanted = {(ip, port) for ip in desired_local_ips() for port in PORTS}

        for key in list(listeners):
            if key not in wanted:
                sock = listeners.pop(key)
                try:
                    selector.unregister(sock)
                except Exception:
                    pass
                sock.close()

        for ip, port in sorted(wanted):
            key = (ip, port)
            if key in listeners:
                continue
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                sock.bind((ip, port))
                sock.listen(16)
                sock.setblocking(False)
            except OSError:
                sock.close()
                continue
            listeners[key] = sock
            selector.register(sock, selectors.EVENT_READ)

        last_reconcile = now_mono

    for key, _mask in selector.select(timeout=1.0):
        handle(key.fileobj)

for sock in listeners.values():
    try:
        selector.unregister(sock)
    except Exception:
        pass
    sock.close()
PY_SUBSCRIPTION_RESPONDER
    local subscription_ports="${SUBSCRIPTION_PORT}"
    sed -i "s/__DFR_SUBSCRIPTION_PORTS__/${subscription_ports}/" "$SUBSCRIPTION_RESPONDER"
    chmod 0750 "$SUBSCRIPTION_RESPONDER"
    python3 -m py_compile "$SUBSCRIPTION_RESPONDER"
    rm -rf "${HUB_BIN_DIR}/__pycache__"

    cat > "$SUBSCRIPTION_UNIT_FILE" <<EOF_SUBSCRIPTION_UNIT
# Managed by Dragon Fruit Relay ${APP_VERSION}.
[Unit]
Description=Dragon Fruit Relay subscriber status responder
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SUBSCRIPTION_RESPONDER}
Restart=always
RestartSec=2
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=full
ReadOnlyPaths=${HUB_BIN_DIR}
ReadWritePaths=${REGISTRY_DIR}

[Install]
WantedBy=multi-user.target
EOF_SUBSCRIPTION_UNIT

    chmod 0644 "$SUBSCRIPTION_UNIT_FILE"
    link_managed_unit "$SUBSCRIPTION_UNIT"
    systemctl daemon-reload

    # Enable immediately so a fresh installation survives reboot even if the
    # registry database is created a few statements later.  Start/restart only
    # when the database exists; the daemon then reconciles tunnel listeners.
    systemctl enable "$SUBSCRIPTION_UNIT" >> "$LOG_FILE" 2>&1 || true
    if [[ -f "$REGISTRY_DB" ]]; then
        systemctl restart "$SUBSCRIPTION_UNIT" >> "$LOG_FILE" 2>&1 || {
            warn 'Subscriber status responder could not be started yet.'
            return 0
        }
    fi

    return 0
}

start_subscription_responder ()
{
    [[ -x "$SUBSCRIPTION_RESPONDER" ]] || return 0
    [[ -f "$SUBSCRIPTION_UNIT_FILE" ]] || return 0
    [[ -f "$REGISTRY_DB" ]] || return 0

    systemctl daemon-reload
    systemctl enable --now "$SUBSCRIPTION_UNIT" >> "$LOG_FILE" 2>&1 || {
        warn 'Subscriber status responder could not be started yet.'
        return 0
    }
    return 0
}

write_hub_helpers () 
{ 
    ensure_hub_layout;
    cat > "$HUB_BIN_DIR/client-xfrm-up" <<'EOF_HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail
name="${1:?profile name required}"
[[ "$name" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || exit 2
# shellcheck disable=SC1090
source "/etc/dragon-fruit-relay/clients/${name}/profile.conf"
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

    cat > "$HUB_BIN_DIR/client-daemon" <<'EOF_HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail
name="${1:?profile name required}"
[[ "$name" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || exit 2
# shellcheck disable=SC1090
source "/etc/dragon-fruit-relay/clients/${name}/profile.conf"
install -d -m 0755 /run/dragon-fruit-relay
rm -f -- "$VICI_SOCKET"
daemon=$(command -v charon-systemd 2>/dev/null || true)
[[ -n "$daemon" ]] || daemon=/usr/lib/ipsec/charon-systemd
[[ -x "$daemon" ]] || { echo 'charon-systemd executable not found' >&2; exit 1; }
exec env STRONGSWAN_CONF="$STRONGSWAN_CANONICAL" "$daemon"
EOF_HELPER

    cat > "$HUB_BIN_DIR/client-load" <<'EOF_HELPER'
#!/usr/bin/env bash
# Dragon Fruit Relay client loader
set -Eeuo pipefail
name="${1:?profile name required}"
[[ "$name" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || exit 2
# shellcheck disable=SC1090
source "/etc/dragon-fruit-relay/clients/${name}/profile.conf"
for _ in $(seq 1 100); do
    [[ -S "$VICI_SOCKET" ]] && break
    sleep 0.1
done
[[ -S "$VICI_SOCKET" ]] || { echo "VICI socket did not appear: $VICI_SOCKET" >&2; exit 1; }
# Keep the original canonical symbolic links as the authoritative layout.
# Some confined swanctl builds refuse to follow a configuration link outside
# /etc/swanctl even though the invoking service runs as root.  Create a private,
# regular-file snapshot below the same canonical profile directory solely for
# the swanctl load operation.  The managed source and all canonical links stay
# unchanged and remain the source of truth.
canonical_dir=$(dirname -- "$SWANCTL_CANONICAL")
runtime_dir="${canonical_dir}/.runtime"
runtime_file="${runtime_dir}/swanctl.conf"
source_file=$(readlink -f -- "$SWANCTL_CANONICAL" 2>/dev/null || true)
[[ -n "$source_file" && -r "$source_file" ]] || {
    echo "Managed swanctl source is missing or unreadable: $SWANCTL_CANONICAL" >&2
    exit 1
}
install -d -m 0750 "$runtime_dir"
for credential_dir in x509 x509ca x509ocsp x509aa x509ac x509crl pubkey private rsa ecdsa pkcs8 pkcs12; do
    install -d -m 0700 "$runtime_dir/$credential_dir"
done
runtime_tmp="${runtime_file}.tmp.$$"
install -m 0600 "$source_file" "$runtime_tmp"
mv -f -- "$runtime_tmp" "$runtime_file"

swanctl --load-all --uri "$VICI_URI" --noprompt --file "$runtime_file"
swanctl --list-conns --uri "$VICI_URI" | grep -Eq '^[[:space:]]*dragonfruit_relay:'
EOF_HELPER

    cat > "$HUB_BIN_DIR/client-xfrm-down" <<'EOF_HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail
name="${1:?profile name required}"
[[ "$name" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || exit 2
file="/etc/dragon-fruit-relay/clients/${name}/profile.conf"
[[ -r "$file" ]] || exit 0
# shellcheck disable=SC1090
source "$file"
swanctl --terminate --uri "$VICI_URI" --ike dragonfruit_relay >/dev/null 2>&1 || true
ip link set "$XFRM_IF" down >/dev/null 2>&1 || true
rm -f -- "$VICI_SOCKET" "${VICI_SOCKET%.vici}.dck" "${VICI_SOCKET%.vici}.ctl" "${VICI_SOCKET%.vici}.wlst"
EOF_HELPER

    write_registry_runtime_files;
    write_subscription_responder;
    chmod 0750 "$HUB_BIN_DIR"/*;
    cat > "$CLIENT_UNIT_TEMPLATE" <<EOF_UNIT
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

    chmod 0644 "$CLIENT_UNIT_TEMPLATE";
    link_managed_unit 'dragon-fruit-relay-client@.service';
    systemctl daemon-reload;
}

write_hub_host_config ()
{
    ensure_hub_layout
    write_shell_config "$HOST_CONFIG_FILE" \
        "PRODUCT_ID=${DFR_PRODUCT_ID}" \
        "PRODUCT_LINEAGE=${DFR_PRODUCT_LINEAGE}" \
        "HUB_SCHEMA=${HUB_SCHEMA_CURRENT}" \
        'ROLE=egress-hub' \
        "MANAGED_BY_VERSION=${APP_VERSION}" \
        "WAN_IF=${WAN_IF}" \
        "LOCAL_IP=${LOCAL_IP}" \
        "PUBLIC_IP=${PUBLIC_IP}" \
        "SERVER_ENDPOINT=${SERVER_ENDPOINT}" \
        "SUBSCRIPTION_PORT=${SUBSCRIPTION_PORT:-$DEFAULT_SUBSCRIPTION_PORT}" \
        "CONTROL_PORT=${CONTROL_PORT:-$DEFAULT_CONTROL_PORT}"
}

write_hub_readme ()
{
    cat > "$MANAGED_README" <<EOF_HUB_README
Dragon Fruit Relay managed directory
====================================

Release:                  ${APP_VERSION}
Server schema:            ${HUB_SCHEMA_CURRENT}
Profile schema:           ${PROFILE_SCHEMA_CURRENT}
Registry schema:          ${REGISTRY_SCHEMA_CURRENT}
Enrollment-token version: ${PROFILE_TOKEN_VERSION}
Subscription protocol:    ${SUBSCRIPTION_PROTOCOL_VERSION}
CONTROL protocol:         ${CONTROL_PROTOCOL_VERSION}

This node is a Dragon Fruit Relay Egress Hub. Each directory below clients/
is an independent managed Client connection with its own PSK, UDP listener,
charon-systemd process, VICI socket, XFRM interface, XFRM ID, /30 tunnel and
firewall/NAT state.

Authoritative persistent state:
  /var/lib/dragon-fruit-relay/database/registry.sqlite3

Generated per-connection configuration:
  /etc/dragon-fruit-relay/clients/<name>/profile.conf
  /etc/dragon-fruit-relay/clients/<name>/swanctl.conf
  /etc/dragon-fruit-relay/clients/<name>/strongswan.conf
  /etc/dragon-fruit-relay/clients/<name>/pairing-token.txt

Normal Client management uses authenticated CONTROL/1 inside the encrypted
XFRM tunnel. Subscription/quota status uses the separate tunnel-scoped
SUBSCRIPTION/1 responder. Do not edit generated files while the manager is
running; use the Dragon Fruit Relay UI or CLI so registry and runtime state
remain consistent.
EOF_HUB_README
    chmod 0640 "$MANAGED_README"
}

write_hub_sysctl () 
{ 
    load_host_config;
    write_egress_sysctl
}

write_shell_config () 
{ 
    local file="$1";
    shift;
    : > "$file";
    chmod 600 "$file";
    local assignment key value;
    for assignment in "$@";
    do
        key=${assignment%%=*};
        value=${assignment#*=};
        printf '%s=%q\n' "$key" "$value" >> "$file";
    done
}

xfrm_counter_summary () 
{ 
    local iface="$1";
    if [[ ! -d "/sys/class/net/${iface}/statistics" ]]; then
        printf 'unavailable';
        return;
    fi;
    local rx_bytes tx_bytes rx_packets tx_packets;
    rx_bytes=$(cat "/sys/class/net/${iface}/statistics/rx_bytes" 2> /dev/null || echo 0);
    tx_bytes=$(cat "/sys/class/net/${iface}/statistics/tx_bytes" 2> /dev/null || echo 0);
    rx_packets=$(cat "/sys/class/net/${iface}/statistics/rx_packets" 2> /dev/null || echo 0);
    tx_packets=$(cat "/sys/class/net/${iface}/statistics/tx_packets" 2> /dev/null || echo 0);
    if command -v numfmt > /dev/null 2>&1; then
        rx_bytes=$(numfmt --to=iec "$rx_bytes" 2> /dev/null || echo "$rx_bytes");
        tx_bytes=$(numfmt --to=iec "$tx_bytes" 2> /dev/null || echo "$tx_bytes");
    fi;
    printf 'RX %s / %s packets | TX %s / %s packets' "$rx_bytes" "$rx_packets" "$tx_bytes" "$tx_packets"
}



# ---------------------------------------------------------------------------
# Pairing-token and custom-port transport overrides.
# ---------------------------------------------------------------------------









resolve_requested_transport() {
    local request="${1:-auto}" suggested owner
    case "$request" in
        auto|'')
            suggested=$(find_next_custom_port) || die 'No available custom UDP port remains in the accepted range.'
            NEW_PORT_MODE='custom'; NEW_IKE_PORT="$suggested"; NEW_NATT_PORT="$suggested"
            ;;
        standard) die 'Standard UDP 500/4500 transport has been removed. Select a custom UDP port.' ;;
        *[!0-9]*) die "Invalid port selection '${request}'. Use auto or a number from ${PROFILE_PORT_MIN}-${PROFILE_PORT_MAX}." ;;
        *)
            validate_uint_range "$request" "$PROFILE_PORT_MIN" "$PROFILE_PORT_MAX" || \
                die "Custom ports must be between ${PROFILE_PORT_MIN} and ${PROFILE_PORT_MAX}."
            if profile_uses_port "$request"; then
                owner=$(profile_using_port "$request" || true)
                die "UDP ${request} is already assigned to profile '${owner}'."
            fi
            udp_port_in_use_live "$request" && die "UDP ${request} is already in use by another local service."
            NEW_PORT_MODE='custom'; NEW_IKE_PORT="$request"; NEW_NATT_PORT="$request"
            ;;
    esac
}

choose_transport_interactive() {
    local choice suggested entered owner
    section_title 'Custom UDP transport'
    suggested=$(find_next_custom_port) || die 'No custom UDP port is available.'
    cat >"$TTY_OUT" <<EOF_CUSTOM_PORT_ONLY
  Every connection uses one custom UDP port for IKE, NAT-T and ESP-in-UDP.
  Standard UDP 500 and UDP 4500 are not used.

  ${C_GREEN}[1]${C_RESET} Use suggested port ${suggested}
  ${C_CYAN}[2]${C_RESET} Enter another custom UDP port
  ${C_DIM}[B]${C_RESET} Back
EOF_CUSTOM_PORT_ONLY
    choice=$(prompt_default 'Select an option' '1')
    case "$choice" in
        1|'') resolve_requested_transport "$suggested"; return 0 ;;
        2) ;;
        b|B|0) return 1 ;;
        *) warn 'Invalid selection.'; return 1 ;;
    esac
    while true; do
        entered=$(prompt_default "Custom UDP port (${PROFILE_PORT_MIN}-${PROFILE_PORT_MAX})" "$suggested")
        if ! validate_uint_range "$entered" "$PROFILE_PORT_MIN" "$PROFILE_PORT_MAX"; then
            warn "Custom ports must be between ${PROFILE_PORT_MIN} and ${PROFILE_PORT_MAX}."; continue
        fi
        if profile_uses_port "$entered"; then owner=$(profile_using_port "$entered" || true); warn "UDP ${entered} is already assigned to profile '${owner}'."; continue; fi
        if udp_port_in_use_live "$entered"; then warn "UDP ${entered} is already in use by another local service."; continue; fi
        resolve_requested_transport "$entered"; return 0
    done
}

write_client_strongswan() {
    local name="$1" source canonical
    source=$(profile_strongswan_source "$name")
    canonical=$(profile_strongswan_canonical "$name")
    [[ "$PORT_MODE" == custom ]] || die "Profile '${name}' uses removed standard transport. Recreate it with a custom port."
    validate_uint_range "$NATT_PORT" "$PROFILE_PORT_MIN" "$PROFILE_PORT_MAX" || die "Profile '${name}' has an invalid custom UDP port."
    cat >"$source" <<EOF_CLIENT_STRONGSWAN
# Managed by Dragon Fruit Relay ${APP_VERSION}.
# Profile: ${name}
include /etc/strongswan.d/charon/*.conf
include /etc/strongswan.d/charon-systemd*.conf

charon {
    port = 0
    port_nat_t = ${NATT_PORT}
    install_routes = no
    plugins {
        dhcp {
            load = no
        }
        vici {
            socket = ${VICI_URI}
        }
        kernel-libipsec {
            load = no
        }
        kernel-netlink {
            load = yes
            install_routes_xfrmi = no
        }
        bypass-lan {
            load = no
        }
        forecast {
            load = no
        }
        resolve {
            load = no
        }
        duplicheck {
            socket = unix:///run/dragon-fruit-relay/${name}.dck
        }
        stroke {
            socket = unix:///run/dragon-fruit-relay/${name}.ctl
        }
        whitelist {
            socket = unix:///run/dragon-fruit-relay/${name}.wlst
        }
    }
}
EOF_CLIENT_STRONGSWAN
    chmod 0600 "$source"
    ensure_managed_symlink "$source" "$canonical"
}

generate_client_token ()
{
    local name="$1" payload token token_path management connection_uuid control_key issued expires token_hash
    load_host_config; load_client_profile "$name"; ensure_control_plane_current
    [[ -n "${SERVER_ENDPOINT:-}" ]] || die 'The Server does not have an endpoint.'
    [[ "$PORT_MODE" == custom ]] || die "Profile '${name}' is not using custom transport."
    management=$(registry_command management-credentials "$name") || die "Could not load management identity for '${name}'."
    connection_uuid=$(awk -F '\t' '$1=="CONNECTION_UUID" {print $2}' <<<"$management")
    control_key=$(awk -F '\t' '$1=="CONTROL_KEY" {print $2}' <<<"$management")
    [[ "$connection_uuid" =~ ^[0-9a-fA-F-]{36}$ ]] || die 'Registry returned an invalid connection UUID.'
    [[ "$control_key" =~ ^[0-9a-f]{64}$ ]] || die 'Registry returned an invalid control key.'
    issued=$(date +%s); expires=$((issued + ENROLLMENT_TOKEN_TTL_SECONDS))
    payload=$(cat <<EOF_TOKEN
V=${PROFILE_TOKEN_VERSION}
N=${PROFILE_NAME}
I=${PROFILE_INDEX}
U=${connection_uuid}
C=${control_key}
H=${SERVER_ENDPOINT}
P=${NATT_PORT}
S=${PSK}
T=${TUNNEL_CIDR}
M=${XFRM_MTU}
D=${DNS_PRIMARY},${DNS_SECONDARY}
Q=${SUBSCRIPTION_PORT},${CONTROL_PORT}
A=${issued}
E=${expires}
EOF_TOKEN
)
    token=$(printf '%s' "$payload" | base64 -w0 | tr '+/' '-_' | tr -d '=')
    token="DFR1.${token}"
    token_hash=$(printf '%s' "$token" | sha256sum | awk '{print $1}')
    registry_command token-record "$name" --token-hash "$token_hash" --token-version "$PROFILE_TOKEN_VERSION" --expires-at "$expires" >/dev/null || die 'Could not register the enrollment token.'
    token_path=$(profile_token_file "$name"); printf '%s\n' "$token" > "$token_path"; chmod 0600 "$token_path"; printf '%s' "$token"
}



show_client_token() {
    local name="$1" token
    profile_exists "$name" || die "Client profile '${name}' does not exist."
    token=$(generate_client_token "$name")
    render_client_token "$name" "$token"
}

profile_listener_ok() {
    local name="$1"
    load_client_profile "$name"
    [[ "$PORT_MODE" == custom ]] || return 1
    udp_listener_exists "$NATT_PORT"
}







upsert_shell_assignment() {
    local file="$1" key="$2" value="$3"
    [[ -f "$file" ]] || return 1
    if grep -qE "^${key}=" "$file"; then
        sed -i -E "s|^${key}=.*|${key}=$(printf '%q' "$value")|" "$file"
    else
        printf '%s=%q\n' "$key" "$value" >>"$file"
    fi
}

normalize_egress_schema_state ()
{
    if [[ -f "$HOST_CONFIG_FILE" ]]; then load_host_config; upsert_shell_assignment "$HOST_CONFIG_FILE" MANAGED_BY_VERSION "$APP_VERSION"; fi
    local name file
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue; file=$(profile_config_file "$name"); [[ -f "$file" ]] || continue
        load_client_profile "$name"; upsert_shell_assignment "$file" MANAGED_BY_VERSION "$APP_VERSION"
    done < <(profile_names)
}


# -----------------------------------------------------------------------------







































































egress_unconfigured_residual_present ()
{
    [[ -d "$CONFIG_DIR" || -d "$STATE_DIR" ]] && return 0
    [[ -e "$CLIENT_UNIT_TEMPLATE" || -e "$CONTROL_UNIT_FILE" || -e "$SUBSCRIPTION_UNIT_FILE" || -e "$REGISTRY_UNIT_FILE" ]] && return 0
    compgen -G "$SYSTEMD_DIR/dragon-fruit-relay-*.service" >/dev/null && return 0
    compgen -G "$SYSTEMD_DIR/dragon-fruit-relay-*.timer" >/dev/null && return 0
    dragonfruit_managed_xfrm_interfaces | grep -q . && return 0
    return 1
}

egress_remove_before_configuration ()
{
    if ! egress_unconfigured_residual_present; then warn 'No configured Server or residual Dragon Fruit Relay state was found.'; return 0; fi
    confirm 'Remove residual Dragon Fruit Relay state and restore available backups?' no || return 0
    clean_abandoned_install_before_setup
    success 'Residual Dragon Fruit Relay state was removed and available original state was restored.'
}

egress_uninstall_before_configuration() {
    local package_snapshot=''
    if [[ -f "$PACKAGE_STATE_FILE" ]]; then
        package_snapshot=$(mktemp /tmp/dragon-fruit-relay-package-state.XXXXXX)
        cp -a -- "$PACKAGE_STATE_FILE" "$package_snapshot"
    fi
    confirm 'Completely uninstall Dragon Fruit Relay and restore available original state?' no || {
        [[ -n "$package_snapshot" ]] && rm -f -- "$package_snapshot"
        return 0
    }
    if egress_unconfigured_residual_present; then
        clean_abandoned_install_before_setup
    fi
    if [[ -n "$package_snapshot" ]]; then
        remove_added_packages "$package_snapshot"
        rm -f -- "$package_snapshot"
    fi
    remove_cli_command
    systemctl daemon-reload >/dev/null 2>&1 || true
    success 'Dragon Fruit Relay, residual managed state, and the management command were removed.'
}

# Canonical base helpers retained unchanged.
reload_dhcpcd_configuration() {
    command -v dhcpcd >/dev/null 2>&1 || return 0

    local interface="${1:-${WAN_IF:-}}"
    [[ -n "$interface" ]] || interface=$(detect_default_interface 2>/dev/null || true)
    [[ -n "$interface" ]] || return 0

    # dhcpcd can run as a per-interface process without dhcpcd.service.
    # Do not start a new DHCP client; only ask an existing client to reload.
    timeout 15s dhcpcd -n "$interface" >>"$LOG_FILE" 2>&1 || true
}


remove_egress_network_rules() {
    delete_iptables_rule_all filter FORWARD -i "$XFRM_IF" -o "$WAN_IF" -s "$INGRESS_XFRM_IP/32" \
        -m comment --comment dragon-fruit-relay-forward-out -j ACCEPT
    delete_iptables_rule_all filter FORWARD -i "$WAN_IF" -o "$XFRM_IF" -d "$INGRESS_XFRM_IP/32" \
        -m conntrack --ctstate ESTABLISHED,RELATED \
        -m comment --comment dragon-fruit-relay-forward-return -j ACCEPT
    delete_iptables_rule_all nat POSTROUTING -s "$INGRESS_XFRM_IP/32" -o "$WAN_IF" \
        -m comment --comment dragon-fruit-relay-nat -j MASQUERADE
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >>"$LOG_FILE" 2>&1 || true
}





egress_unconfigured_menu ()
{
    local choice file
    while ! hub_configured; do
        diagnostics_preflight
        cat > "$TTY_OUT" <<EOF_EGRESS_UNCONFIGURED

  ${C_BOLD}${C_MAGENTA}SERVER SETUP${C_RESET}
  ${C_DIM}$(ui_rule $'\u2500')${C_RESET}
     ${C_GREEN}[1]${C_RESET}  Configure this machine as a new Server
     ${C_CYAN}[2]${C_RESET}  Re-run diagnostics / preflight
     ${C_MAGENTA}[3]${C_RESET}  Restore Server from a .dfrbak backup

  ${C_BOLD}${C_RED}REMOVE${C_RESET}
  ${C_DIM}$(ui_rule $'\u2500')${C_RESET}
     ${C_YELLOW}[4]${C_RESET}  Remove residual relay state and restore previous state
     ${C_RED}[5]${C_RESET}  Completely uninstall Dragon Fruit Relay

  ${C_BOLD}${C_MAGENTA}SESSION${C_RESET}
  ${C_DIM}$(ui_rule $'\u2500')${C_RESET}
     ${C_RED}[Q]${C_RESET}  Exit

EOF_EGRESS_UNCONFIGURED
        choice=$(prompt '  Select an action: ')
        case "$choice" in
            1) setup_egress_hub; return ;;
            2) diagnostics_preflight; pause_screen ;;
            3) file=$(prompt '  Backup file: '); restore_egress_backup "$file"; return ;;
            4) egress_remove_before_configuration; pause_screen ;;
            5) egress_uninstall_before_configuration; return ;;
            q|Q|0) exit 0 ;;
            *) warn 'Invalid selection.'; sleep 0.35 ;;
        esac
    done
}


egress_usage ()
{
    cat <<'EOF_EGRESS_USAGE'
Usage: dragon-fruit-relay [command]

  menu                                  Open the Server management menu
  init|server init                      Initialize the Egress Hub
  connection add [options]              Add a custom-port Client connection
  connection list [--json]              List connections
  connection status NAME [--json]       Show one connection
  connection diagnostics NAME VIEW      Focused diagnostics
  connection test NAME                  Run peer and DNS/NAT tests
  connection start|stop|restart NAME    Operate one connection
  connection repair|token|remove NAME   Manage one connection
  connection management NAME            Show managed Client state
  connection reconcile NAME             Queue a managed Client reconcile
  connection edit NAME [options]        Stage UDP/MTU/DNS/PSK changes
  client-release list                   List published Client releases
  client-release bundled                Publish embedded matching Client as STAGED
  client-release publish FILE [STATUS]  Sign and publish a Client release
  client-release status VERSION STATUS  staged|canary|stable|revoked
  client-release deploy NAME VERSION    Queue a release for one Client
  subscription NAME                     Open subscription/traffic workspace
  backup create|list|auto               Create/list/run backup operations
  backup verify FILE                    Verify one portable .dfrbak archive
  restore FILE                          Restore an unconfigured Server
  endpoint                              Change the Server endpoint
  status|health                         Run the complete Server health check
  diagnostics|diag                      Open Server operations and diagnostics
  test                                  Run Server connectivity tests
  start|stop|repair                     Operate all connections
  token NAME                            Show an enrollment token
  upgrade                               Reconcile this standalone DFR installation to the current release
  remove                                Remove the Server and restore host state
  uninstall                             Completely uninstall the Server
  version                               Show version
EOF_EGRESS_USAGE
}

ensure_registry_current_fast ()
{
    # DFR_REGISTRY_FAST_START
    #
    # Normal interactive startup must not rebuild/restart the
    # current registry/subscription runtime on every run.
    #
    # If all authoritative/runtime components already exist,
    # the services are enabled+active, and SQLite is readable,
    # return immediately.
    #
    # Any failed check falls back to the full
    # ensure_registry_current() self-healing path.

    local registry_db
    local registry_helper
    local subscription_responder
    local control_responder
    local registry_unit
    local subscription_unit
    local control_unit
    local update_public_key

    registry_db="/var/lib/dragon-fruit-relay/database/registry.sqlite3"

    registry_helper="/etc/dragon-fruit-relay/hub-bin/registry"

    subscription_responder="/etc/dragon-fruit-relay/hub-bin/subscription-responder"
    control_responder="/etc/dragon-fruit-relay/hub-bin/control-responder"

    registry_unit="/etc/systemd/system/dragon-fruit-relay-registry.service"
    subscription_unit="/etc/systemd/system/dragon-fruit-relay-subscription.service"
    control_unit="/etc/systemd/system/dragon-fruit-relay-control.service"
    update_public_key="/etc/dragon-fruit-relay/secrets/ingress-update-ed25519.pub"


    # Required durable/runtime files.
    if [[ ! -s "$registry_db" ||
          ! -x "$registry_helper" ||
          ! -x "$subscription_responder" ||
          ! -x "$control_responder" ||
          ! -s "$update_public_key" ||
          ! -f "$registry_unit" ||
          ! -f "$subscription_unit" ||
          ! -f "$control_unit" ]]
    then
        ensure_registry_current
        return $?
    fi


    # The helper must match the command/API contract of this engine.
    # File existence + list-names is not enough: an stale helper can
    # read the same database while lacking current management commands.
    if ! registry_runtime_api_ok_current
    then
        ensure_registry_current
        registry_runtime_api_ok_current ||
            die 'Registry runtime API remains incompatible after self-healing.'
        return 0
    fi


    # Services must survive reboot as well as be running now.
    if ! systemctl is-enabled --quiet \
            dragon-fruit-relay-registry.service
    then
        ensure_registry_current
        return $?
    fi

    if ! systemctl is-enabled --quiet \
            dragon-fruit-relay-subscription.service
    then
        ensure_registry_current
        return $?
    fi

    if ! systemctl is-enabled --quiet \
            dragon-fruit-relay-control.service
    then
        ensure_registry_current
        return $?
    fi


    if ! systemctl is-active --quiet \
            dragon-fruit-relay-registry.service
    then
        ensure_registry_current
        return $?
    fi

    # A current helper file is not enough. Python services keep the code that
    # was loaded when their process started. Require a fresh heartbeat from the
    # actual MainPID so stale pre-upgrade registry daemons self-heal.
    if ! registry_daemon_runtime_current
    then
        ensure_registry_current
        registry_daemon_runtime_current ||
            die 'Registry daemon live runtime remains stale after self-healing.'
        return 0
    fi

    if ! systemctl is-active --quiet \
            dragon-fruit-relay-subscription.service
    then
        ensure_registry_current
        return $?
    fi

    if ! systemctl is-active --quiet \
            dragon-fruit-relay-control.service
    then
        ensure_registry_current
        return $?
    fi


    # Verify that the helper can actually read the current DB.
    # This is much cheaper than regenerating the managed runtime.
    if ! registry_command list-names >/dev/null 2>&1
    then
        ensure_registry_current
        return $?
    fi


    return 0
}




egress_main ()
{
    require_root_and_platform
    install_cli_command
    local command="${1:-menu}" sub="${2:-}"
    if [[ -f "$CONFIG_FILE" && ! -f "$HOST_CONFIG_FILE" ]]; then die 'A Client is configured on this machine. Use the Client engine here.'; fi
    if hub_configured && [[ "$command" != _* && "$command" != upgrade && "$command" != remove && "$command" != uninstall && "$command" != version && "$command" != help && "$command" != --help && "$command" != -h ]]; then ensure_registry_current_fast; fi
    case "$command" in
        _config-apply-runtime) [[ -n "${2:-}" && -n "${3:-}" ]] || die 'Internal config apply requires NAME TRANSACTION_ID.'; dfr_apply_config_transaction_runtime "$2" "$3" ;;
        _config-rollback-runtime) [[ -n "${2:-}" && -n "${3:-}" ]] || die 'Internal config rollback requires NAME TRANSACTION_ID.'; dfr_rollback_config_transaction_runtime "$2" "$3" ;;
        _config-verify-runtime) [[ -n "${2:-}" && -n "${3:-}" ]] || die 'Internal config verify requires NAME TRANSACTION_ID.'; dfr_verify_config_transaction_runtime "$2" "$3" ;;
        menu) if hub_configured; then hub_interactive_menu; else egress_unconfigured_menu; fi ;;
        init) hub_configured && die 'The Server is already configured.'; setup_egress_hub ;;
        server|egress) case "$sub" in init|'') hub_configured && die 'The Server is already configured.'; setup_egress_hub ;; *) die "Unknown Server action: ${sub}" ;; esac ;;
        connection|client) shift; client_cli "$@" ;;
        client-release|ingress-release)
            hub_configured || die 'This machine is not configured as a Dragon Fruit Relay Server.'
            case "$sub" in list|'') registry_command release-list ;; runtime-info) registry_command runtime-info ;; bundled) publish_bundled_ingress_release ;; publish) [[ -n "${3:-}" ]] || die 'Specify Client installer path.'; publish_ingress_release "$3" "${4:-staged}" ;; info) [[ -n "${3:-}" ]] || die 'Specify VERSION.'; registry_command release-info "$3" ;; status) [[ -n "${3:-}" && -n "${4:-}" ]] || die 'Specify VERSION STATUS.'; registry_command release-status "$3" "$4" ;; delete) [[ -n "${3:-}" ]] || die 'Specify VERSION.'; registry_command release-delete "$3" ;; deploy) [[ -n "${3:-}" && -n "${4:-}" ]] || die 'Specify CONNECTION VERSION.'; registry_command management-set "$3" --desired-version "$4" --desired-source manual ;; *) die "Unknown client-release action: ${sub}" ;; esac ;;
        subscription) hub_configured || die 'This machine is not configured as a Dragon Fruit Relay Server.'; [[ -n "$sub" ]] || die 'Specify a connection name.'; subscription_menu "$sub" ;;
        backup) hub_configured || die 'This machine is not configured as a Dragon Fruit Relay Server.'; case "$sub" in create|'') dfr_backup_create_manual ;; list) dfr_backup_list_files ;; verify) [[ -n "${3:-}" ]] || die 'Specify a backup file.'; registry_command backup-verify "${3}" ;; delete) [[ -n "${3:-}" ]] || die 'Specify a backup file.'; dfr_backup_delete_file "${3}" yes ;; auto) dfr_backup_run_auto_now ;; *) die "Unknown backup action: ${sub}" ;; esac ;;
        restore) hub_configured && die 'Restore requires an unconfigured Server.'; [[ -n "$sub" ]] || die 'Specify a .dfrbak file.'; restore_egress_backup "$sub" ;;
        endpoint) hub_configured || die 'The Server is not configured.'; change_server_endpoint ;;
        status|health) hub_configured && hub_health_overview || diagnostics_preflight ;;
        diagnostics|diag) hub_configured && hub_diagnostics_menu || diagnostics_preflight ;;
        test) hub_configured || die 'The Server is not configured.'; hub_connectivity_tests ;;
        start) hub_configured || die 'The Server is not configured.'; start_all_clients ;;
        stop) hub_configured || die 'The Server is not configured.'; stop_all_clients ;;
        repair) hub_configured || die 'The Server is not configured.'; repair_all_clients ;;
        upgrade) hub_configured || die 'The Server is not configured.'; install_self_copy; ensure_registry_current; ensure_bundled_ingress_stable_release; repair_all_clients; registry_command apply >/dev/null 2>&1 || true; normalize_egress_schema_state; success "Dragon Fruit Relay ${APP_VERSION} Server runtime is current." ;;
        token) hub_configured || die 'The Server is not configured.'; [[ -n "$sub" ]] || die 'Specify a connection name.'; show_client_token "$sub" ;;
        remove) if hub_configured; then remove_egress_hub no no; else egress_remove_before_configuration; fi ;;
        uninstall) if hub_configured; then remove_egress_hub yes no; else egress_uninstall_before_configuration; fi ;;
        version) printf '%s %s server\n' "$APP_NAME" "$APP_VERSION" ;;
        -h|--help|help) egress_usage ;;
        *) egress_usage; exit 1 ;;
    esac
}



# ============================================================================
# DFR_DB_RESOURCE_CONSISTENCY
# Hard-delete connection lifecycle + registry-aware resource allocation.
# ============================================================================


registry_hard_delete_connection ()
{
    local connection="$1"
    [[ -f "$REGISTRY_DB" ]] || return 0
    python3 - "$REGISTRY_DB" "$connection" <<'PY_HARD_DELETE'
import sqlite3,sys
p,name=sys.argv[1:3]; c=sqlite3.connect(p,timeout=5); c.execute('PRAGMA busy_timeout=5000'); c.execute('PRAGMA foreign_keys=ON')
try:
    c.execute('BEGIN IMMEDIATE')
    child=('config_pending','enrollment_tokens','control_nonces','ingress_state','subscriptions','usage','software_release_usage','audit')
    for table in child: c.execute(f'DELETE FROM {table} WHERE connection_name=?',(name,))
    c.execute('DELETE FROM connections WHERE name=?',(name,))
    residue=[]
    for table in ('connections',)+child:
        column='name' if table=='connections' else 'connection_name'
        if c.execute(f'SELECT 1 FROM {table} WHERE {column}=? LIMIT 1',(name,)).fetchone(): residue.append(table)
    if residue: raise RuntimeError('connection deletion left residual rows in: '+','.join(residue))
    c.commit()
except Exception:
    c.rollback(); raise
finally: c.close()
PY_HARD_DELETE
}

registry_active_owner ()
{
    local field="$1" value="$2" except="${3:-}"
    [[ -f "$REGISTRY_DB" ]] || return 1
    python3 - "$REGISTRY_DB" "$field" "$value" "$except" <<'PY_DFR_OWNER'
import sqlite3, sys
p,field,value,except_name=sys.argv[1:5]
allowed={'profile_index','udp_port','tunnel_cidr','xfrm_if','xfrm_id'}
if field not in allowed: raise SystemExit(2)
c=sqlite3.connect(f'file:{p}?mode=ro', uri=True, timeout=3)
c.execute('PRAGMA busy_timeout=3000')
q=f'SELECT name FROM connections WHERE {field}=?'
params=[value]
if except_name:
    q+=' AND name<>?'; params.append(except_name)
r=c.execute(q,params).fetchone(); c.close()
if r:
    print(r[0]); raise SystemExit(0)
raise SystemExit(1)
PY_DFR_OWNER
}

registry_connection_exists_any ()
{
    local connection="$1"
    [[ -f "$REGISTRY_DB" ]] || return 1
    python3 - "$REGISTRY_DB" "$connection" <<'PY_DFR_EXISTS'
import sqlite3,sys
c=sqlite3.connect(f'file:{sys.argv[1]}?mode=ro',uri=True,timeout=3)
r=c.execute('SELECT 1 FROM connections WHERE name=?',(sys.argv[2],)).fetchone(); c.close()
raise SystemExit(0 if r else 1)
PY_DFR_EXISTS
}

registry_command ()
{
    [[ -x "$REGISTRY_HELPER" ]] || die "Persistent registry helper is missing: $REGISTRY_HELPER"
    local action="${1:-}" err rc
    case "$action" in
        remove-connection) [[ -n "${2:-}" ]] || { error 'Registry deletion requires a connection name.'; return 1; }; registry_hard_delete_connection "$2" ;;
        upsert-connection)
            err=$(mktemp /tmp/dfr-registry-upsert.XXXXXX)
            if "$REGISTRY_HELPER" "$@" 2>"$err"; then rm -f "$err"; return 0; fi
            rc=$?; if grep -Eq 'UNIQUE constraint failed|registry resource conflict' "$err"; then error 'Registry rejected duplicate connection resources. Allocation was not committed.'; sed -n '1,3p' "$err" >&2; else cat "$err" >&2; fi
            rm -f "$err"; return "$rc" ;;
        *) "$REGISTRY_HELPER" "$@" ;;
    esac
}

profile_uses_port ()
{
    local wanted="$1" except="${2:-}" name owner
    while IFS= read -r name; do
        [[ -n "$name" && "$name" != "$except" ]] || continue
        if (
            set +u
            source "$(profile_config_file "$name")"
            [[ "${NATT_PORT:-}" == "$wanted" ]]
        ); then return 0; fi
    done < <(profile_names)

    owner=$(registry_active_owner udp_port "$wanted" "$except" 2>/dev/null) && [[ -n "$owner" ]] && return 0
    return 1
}

profile_using_port ()
{
    local wanted="$1" name owner
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        if (
            set +u
            source "$(profile_config_file "$name")"
            [[ "${NATT_PORT:-}" == "$wanted" ]]
        ); then printf '%s' "$name"; return 0; fi
    done < <(profile_names)

    owner=$(registry_active_owner udp_port "$wanted" '' 2>/dev/null) || return 1
    printf '%s' "$owner"
}

custom_port_available ()
{
    local port="$1" except="${2:-}"
    validate_uint_range "$port" "$PROFILE_PORT_MIN" "$PROFILE_PORT_MAX" || return 1
    ! profile_uses_port "$port" "$except" && ! udp_port_in_use_live "$port"
}

next_profile_index ()
{
    local index name used owner expected_if expected_id
    for ((index=1; index<=9999; index++)); do
        expected_if="dfr$(printf '%04d' "$index")"
        expected_id=$((PROFILE_XFRM_ID_BASE + index))
        used=no

        while IFS= read -r name; do
            [[ -n "$name" ]] || continue
            if (
                set +u
                source "$(profile_config_file "$name")"
                [[ "${PROFILE_INDEX:-}" == "$index" || "${XFRM_IF:-}" == "$expected_if" || "${XFRM_ID:-}" == "$expected_id" ]]
            ); then used=yes; break; fi
        done < <(profile_names)
        [[ "$used" == no ]] || continue

        owner=$(registry_active_owner profile_index "$index" '' 2>/dev/null) && [[ -n "$owner" ]] && continue
        owner=$(registry_active_owner xfrm_if "$expected_if" '' 2>/dev/null) && [[ -n "$owner" ]] && continue
        owner=$(registry_active_owner xfrm_id "$expected_id" '' 2>/dev/null) && [[ -n "$owner" ]] && continue
        ip link show dev "$expected_if" >/dev/null 2>&1 && continue

        printf '%s' "$index"
        return 0
    done
    return 1
}

allocate_tunnel_cidr ()
{
    local used='' name candidate
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        candidate=$(
            set +u
            source "$(profile_config_file "$name")"
            printf '%s' "${TUNNEL_CIDR:-}"
        )
        [[ -n "$candidate" ]] && used+="${candidate}"$'\n'
    done < <(profile_names)

    if [[ -f "$REGISTRY_DB" ]]; then
        used+=$(python3 - "$REGISTRY_DB" <<'PY_DFR_TUNNELS'
import sqlite3,sys
c=sqlite3.connect(f'file:{sys.argv[1]}?mode=ro',uri=True,timeout=3)
for r in c.execute('SELECT tunnel_cidr FROM connections'):
    if r[0]: print(r[0])
c.close()
PY_DFR_TUNNELS
)
        used+=$'\n'
    fi

    python3 - "$PROFILE_TUNNEL_POOL" "$used" <<'PY_DFR_ALLOC'
import ipaddress,json,subprocess,sys
pool=ipaddress.ip_network(sys.argv[1],strict=True)
used=[]
for line in sys.argv[2].splitlines():
    try: used.append(ipaddress.ip_network(line.strip(),strict=False))
    except ValueError: pass
try:
    data=json.loads(subprocess.check_output(['ip','-j','-4','address','show'],text=True))
    for link in data:
        for item in link.get('addr_info',[]):
            if item.get('family')=='inet': used.append(ipaddress.ip_network(f"{item['local']}/{item['prefixlen']}",strict=False))
except Exception: pass
try:
    data=json.loads(subprocess.check_output(['ip','-j','-4','route','show','table','all'],text=True))
    for route in data:
        dst=route.get('dst')
        if dst and dst!='default':
            try: used.append(ipaddress.ip_network(dst,strict=False))
            except ValueError: pass
except Exception: pass
for subnet in pool.subnets(new_prefix=30):
    if any(subnet.overlaps(other) for other in used): continue
    print(subnet.with_prefixlen); raise SystemExit(0)
raise SystemExit(1)
PY_DFR_ALLOC
}

ensure_tunnel_network_available ()
{
    local cidr="$1" conflicts owner
    owner=$(registry_active_owner tunnel_cidr "$cidr" '' 2>/dev/null) && {
        error "Tunnel network ${cidr} is already assigned to registry connection '${owner}'."
        die 'Choose a different tunnel /30 network.'
    }
    if conflicts=$(tunnel_network_conflicts "$cidr" 2>/dev/null); then
        error "Tunnel network ${cidr} overlaps existing network state:"
        printf '%s\n' "$conflicts" > "$TTY_OUT"
        die 'Choose a different tunnel /30 network.'
    fi
}

cleanup_orphan_hub_interfaces ()
{
    local path ifname suffix index expected_id expected_hex details name referenced owner
    for path in /sys/class/net/dfr[0-9][0-9][0-9][0-9]; do
        [[ -e "$path" ]] || continue
        ifname=${path##*/}
        referenced=no

        while IFS= read -r name; do
            [[ -n "$name" ]] || continue
            if (
                set +u
                source "$(profile_config_file "$name")"
                [[ "${XFRM_IF:-}" == "$ifname" ]]
            ); then referenced=yes; break; fi
        done < <(profile_names)

        [[ "$referenced" == no ]] || continue
        owner=$(registry_active_owner xfrm_if "$ifname" '' 2>/dev/null) && [[ -n "$owner" ]] && continue

        suffix=${ifname#dfr}
        [[ "$suffix" =~ ^[0-9]{4}$ ]] || continue
        index=$((10#$suffix))
        expected_id=$((PROFILE_XFRM_ID_BASE + index))
        expected_hex=$(printf '0x%x' "$expected_id")
        details=$(ip -d link show dev "$ifname" 2>/dev/null || true)
        [[ "$details" == *xfrm* ]] || continue
        [[ "$details" == *"if_id $expected_id"* || "$details" == *"if_id $expected_hex"* ]] || continue
        delete_link_bounded "$ifname" || true
    done
}


create_hub_client ()
{
    local name="$1" requested_port="${2:-interactive}" requested_tunnel="${3:-auto}" token
    load_host_config
    validate_profile_name "$name" || die "Invalid profile name '${name}'."
    profile_exists "$name" && die "Client profile '${name}' already exists."
    registry_connection_exists_any "$name" && die "Registry already contains connection '${name}'. Remove/repair it before creating another connection with the same name."

    prepare_new_client_resources "$name" "$requested_port" "$requested_tunnel" || return 0
    PROFILE_CREATED_EPOCH=$(date +%s)

    section_title 'New client resources'
    print_check info 'Connection name' "$name" identity
    print_check info 'Transport' "UDP ${NATT_PORT}"
    print_check info 'XFRM interface' "$XFRM_IF (ID $XFRM_ID)" identity
    print_check info 'Tunnel network' "$TUNNEL_CIDR" accent

    # Build files first, but do not start the service before SQLite accepts
    # the complete resource identity.
    if ! (
        write_client_profile "$name" &&
        load_client_profile "$name" &&
        write_client_strongswan "$name" &&
        write_client_swanctl "$name"
    ); then
        warn "Client '${name}' file creation failed; cleaning the incomplete profile."
        remove_client_files "$name" || true
        return 1
    fi

    load_client_profile "$name"
    if ! registry_upsert_new_connection "$name"; then
        warn "Client '${name}' registry reservation failed; cleaning generated files."
        remove_client_files "$name" || true
        systemctl daemon-reload >/dev/null 2>&1 || true
        return 1
    fi

    token=$(generate_client_token "$name") || {
        warn "Client '${name}' enrollment token creation failed; rolling back registry reservation."
        remove_client_files "$name" || true
        registry_command remove-connection "$name" || true
        return 1
    }

    if ! start_hub_client "$name"; then
        warn "Client '${name}' runtime start failed; rolling back files and database row."
        systemctl disable --now "$(profile_service "$name")" >/dev/null 2>&1 || true
        remove_client_network_rules "$name" || true
        delete_link_bounded "${XFRM_IF:-}" || true
        [[ -n "${VICI_SOCKET:-}" ]] && rm -f -- "$VICI_SOCKET" || true
        remove_client_files "$name" || true
        registry_command remove-connection "$name" || true
        registry_command apply >/dev/null 2>&1 || true
        systemctl daemon-reload >/dev/null 2>&1 || true
        cleanup_orphan_hub_interfaces || true
        return 1
    fi

    registry_command apply >/dev/null 2>&1 || true
    render_client_token "$name" "$token"
}

dfr_config_tx_values ()
{
    local name="$1" transaction_id="$2" which="$3" transaction
    transaction=$(registry_command config-transaction "$name" "$transaction_id") || return 1

    python3 - "$which" "$transaction" <<'PY_DFR_TX_VALUES'
import json,shlex,sys
which=sys.argv[1]
tx=json.loads(sys.argv[2])
data=json.loads(tx[f'{which}_json'])
for k in ('udp_port','xfrm_mtu','dns_primary','dns_secondary','psk'):
    print(f"{k.upper()}={shlex.quote(str(data[k]))}")
PY_DFR_TX_VALUES
}

dfr_apply_profile_values ()
{
    local name="$1" values="$2" restart_required=no mtu_changed=no old_port old_mtu old_psk
    load_client_profile "$name"
    old_port="$NATT_PORT"; old_mtu="$XFRM_MTU"; old_psk="$PSK"
    local UDP_PORT XFRM_MTU DNS_PRIMARY DNS_SECONDARY PSK
    eval "$values"
    validate_uint_range "$UDP_PORT" "$PROFILE_PORT_MIN" "$PROFILE_PORT_MAX" || return 1
    validate_uint_range "$XFRM_MTU" 1200 9000 || return 1
    validate_ipv4 "$DNS_PRIMARY" || return 1
    validate_ipv4 "$DNS_SECONDARY" || return 1
    [[ "$PSK" =~ ^[0-9a-fA-F]{64}$ ]] || return 1

    upsert_shell_assignment "$(profile_config_file "$name")" IKE_PORT "$UDP_PORT"
    upsert_shell_assignment "$(profile_config_file "$name")" NATT_PORT "$UDP_PORT"
    upsert_shell_assignment "$(profile_config_file "$name")" XFRM_MTU "$XFRM_MTU"
    upsert_shell_assignment "$(profile_config_file "$name")" DNS_PRIMARY "$DNS_PRIMARY"
    upsert_shell_assignment "$(profile_config_file "$name")" DNS_SECONDARY "$DNS_SECONDARY"
    upsert_shell_assignment "$(profile_config_file "$name")" PSK "$PSK"

    [[ "$old_port" == "$UDP_PORT" && "$old_psk" == "$PSK" ]] || restart_required=yes
    [[ "$old_mtu" == "$XFRM_MTU" ]] || mtu_changed=yes
    load_client_profile "$name"
    write_client_strongswan "$name"
    write_client_swanctl "$name"
    if [[ "$restart_required" == yes ]]; then
        systemctl restart "$(profile_service "$name")" || return 1
        apply_client_network_rules "$name" || true
    elif [[ "$mtu_changed" == yes ]]; then
        ip link set dev "$XFRM_IF" mtu "$XFRM_MTU" >/dev/null 2>&1 || true
        apply_client_network_rules "$name" || true
    fi
    return 0
}

dfr_apply_config_transaction_runtime ()
{
    local name="$1" transaction_id="$2" values
    values=$(dfr_config_tx_values "$name" "$transaction_id" candidate) || return 1
    dfr_apply_profile_values "$name" "$values"
}

dfr_rollback_config_transaction_runtime ()
{
    local name="$1" transaction_id="$2" values
    values=$(dfr_config_tx_values "$name" "$transaction_id" previous) || return 1
    dfr_apply_profile_values "$name" "$values"
}


dfr_verify_config_transaction_runtime ()
{
    local name="$1" transaction_id="$2" values expected_port expected_mtu
    values=$(dfr_config_tx_values "$name" "$transaction_id" candidate) || return 1
    eval "$values"
    expected_port="$UDP_PORT"; expected_mtu="$XFRM_MTU"
    load_client_profile "$name"
    [[ "$NATT_PORT" == "$expected_port" ]] || return 1
    [[ "$XFRM_MTU" == "$expected_mtu" ]] || return 1
    systemctl is-active --quiet "$(profile_service "$name")" || return 1
    udp_listener_exists "$expected_port" || return 1
    return 0
}

remove_hub_client ()
{
    local connection="$1" skip_confirm="${2:-no}"
    local old_if old_socket old_port old_profile_dir service listener
    profile_exists "$connection" || die "Client profile '${connection}' does not exist."
    [[ "$skip_confirm" == yes ]] || confirm "Permanently delete Server connection '${connection}'? Its tunnel, Server profile, CONTROL state, subscription/usage data and owned runtime will be removed; other connections stay online." no || return 0
    registry_final_sync
    load_client_profile "$connection"
    old_if="$XFRM_IF"; old_socket="$VICI_SOCKET"; old_port="$NATT_PORT"; old_profile_dir="$(profile_dir "$connection")"; service="$(profile_service "$connection")"
    stop_hub_client "$connection" yes || true
    systemctl disable --now "$service" >/dev/null 2>&1 || true
    remove_client_network_rules "$connection" || true
    remove_client_files "$connection"
    rm -f -- "$old_socket"
    delete_link_bounded "$old_if" || true
    systemctl daemon-reload >/dev/null 2>&1 || true
    [[ ! -e "$old_profile_dir" ]] || die "Client '${connection}' profile directory still exists after removal."
    ip link show dev "$old_if" >/dev/null 2>&1 && die "Client '${connection}' XFRM interface ${old_if} still exists after removal."
    systemctl is-active --quiet "$service" 2>/dev/null && die "Client '${connection}' service is still active after removal."
    registry_command remove-connection "$connection" || die "Registry could not permanently delete '${connection}'."
    registry_command apply >/dev/null 2>&1 || true
    cleanup_orphan_hub_interfaces || true
    registry_connection_exists_any "$connection" && die "Client '${connection}' still exists in SQLite after removal."
    listener=$(ss -H -lunp 2>/dev/null | grep -E "[:.]${old_port}[[:space:]]" || true)
    if [[ -n "$listener" ]]; then
        warn "UDP ${old_port} remains occupied by another live process after '${connection}' was removed:"
        printf '%s\n' "$listener" > "$TTY_OUT"
    else
        print_check pass 'Released UDP port' "$old_port is reusable"
    fi
    success "Client '${connection}' was permanently deleted; its database row, subscription/usage data and owned resources were released."
}


# ============================================================================
# DFR_BACKUP_RECOVERY
# In-place rollback + automatic portable backups.
# ============================================================================

readonly DFR_AUTO_BACKUP_STATE="${REGISTRY_BACKUP_DIR}/automatic-backup.conf"
readonly DFR_AUTO_BACKUP_HELPER="${HUB_BIN_DIR}/automatic-backup"
readonly DFR_AUTO_BACKUP_SERVICE="dragon-fruit-relay-backup.service"
readonly DFR_AUTO_BACKUP_TIMER="dragon-fruit-relay-backup.timer"
readonly DFR_AUTO_BACKUP_SERVICE_FILE="${UNIT_DIR}/${DFR_AUTO_BACKUP_SERVICE}"
readonly DFR_AUTO_BACKUP_TIMER_FILE="${UNIT_DIR}/${DFR_AUTO_BACKUP_TIMER}"
readonly DFR_AUTO_BACKUP_RETENTION="10"
readonly DFR_AUTO_BACKUP_LOCK="/run/lock/dragon-fruit-relay-backup.lock"

readonly DFR_BACKUP_AUTO_DIR="${REGISTRY_BACKUP_DIR}/auto"
readonly DFR_BACKUP_MANUAL_DIR="${REGISTRY_BACKUP_DIR}/manual"
readonly DFR_BACKUP_RESCUE_DIR="${REGISTRY_BACKUP_DIR}/pre-restore"
readonly DFR_RESCUE_BACKUP_RETENTION="5"

# DFR_BACKUP_DIRECTORY_LAYOUT
dfr_backup_ensure_layout ()
{
    install -d -m 0700 \
        "$REGISTRY_BACKUP_DIR" \
        "$DFR_BACKUP_AUTO_DIR" \
        "$DFR_BACKUP_MANUAL_DIR" \
        "$DFR_BACKUP_RESCUE_DIR"
}




dfr_backup_prune_rescue ()
{
    local file
    local -a old=()

    dfr_backup_ensure_layout

    mapfile -t old < <(
        find "$DFR_BACKUP_RESCUE_DIR" -maxdepth 1 -type f -name '*.dfrbak' \
            -printf '%T@ %p\n' 2>/dev/null | \
        sort -rn | \
        awk -v keep="$DFR_RESCUE_BACKUP_RETENTION" \
            'NR>keep {$1=""; sub(/^ /,""); print}'
    )

    for file in "${old[@]}"; do
        [[ -n "$file" ]] || continue
        rm -f -- "$file"
    done
}


dfr_backup_display_time ()
{
    local file="$1" epoch
    epoch=$(stat -c '%Y' "$file" 2>/dev/null || true)

    if [[ "$epoch" =~ ^[0-9]+$ ]]; then
        date -d "@$epoch" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || printf '-'
    else
        printf '-'
    fi
}


dfr_backup_category ()
{
    local file="$1"
    case "$file" in
        "$DFR_BACKUP_AUTO_DIR"/*)   printf 'AUTO' ;;
        "$DFR_BACKUP_MANUAL_DIR"/*) printf 'MANUAL' ;;
        "$DFR_BACKUP_RESCUE_DIR"/*) printf 'RESCUE' ;;
        *)                           printf 'OTHER' ;;
    esac
}


# DFR_LOCAL_BACKUP_FILENAMES
dfr_backup_create_manual ()
{
    local stamp out

    dfr_backup_ensure_layout
    registry_final_sync

    stamp=$(date +%Y-%m-%d_%H-%M-%S_%Z)
    out="${DFR_BACKUP_MANUAL_DIR}/${stamp}.dfrbak"

    registry_command backup-create --output "$out" >/dev/null || return 1
    registry_command backup-verify "$out" >/dev/null || {
        rm -f -- "$out"
        return 1
    }

    chmod 0600 "$out"
    printf '%s' "$out"
}


dfr_backup_list_files ()
{
    local file category when relative count=0

    dfr_backup_ensure_layout

    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        count=$((count + 1))
        category=$(dfr_backup_category "$file")
        when=$(dfr_backup_display_time "$file")
        relative="${file#${REGISTRY_BACKUP_DIR}/}"

        printf '  %-8s %-27s %s\n' \
            "$category" "$when" "$relative" > "$TTY_OUT"
    done < <(
        find \
            "$DFR_BACKUP_AUTO_DIR" \
            "$DFR_BACKUP_MANUAL_DIR" \
            "$DFR_BACKUP_RESCUE_DIR" \
            -maxdepth 1 -type f -name '*.dfrbak' \
            -printf '%T@ %p\n' 2>/dev/null | \
        sort -rn | cut -d' ' -f2-
    )

    if (( count == 0 )); then
        print_check info 'Backups' 'No portable backups exist yet.'
    fi
}



dfr_backup_auto_enabled ()
{
    if [[ ! -r "$DFR_AUTO_BACKUP_STATE" ]]; then
        return 0
    fi

    local enabled
    enabled=$(awk -F= '$1=="ENABLED" {print $2; exit}' "$DFR_AUTO_BACKUP_STATE" 2>/dev/null || true)
    [[ "$enabled" != 0 ]]
}


dfr_backup_write_state ()
{
    local enabled="$1"
    install -d -m 0700 "$REGISTRY_BACKUP_DIR"
    printf 'ENABLED=%s\nRETENTION=%s\n' "$enabled" "$DFR_AUTO_BACKUP_RETENTION" > "$DFR_AUTO_BACKUP_STATE"
    chmod 0600 "$DFR_AUTO_BACKUP_STATE"
}


dfr_backup_automation_write_files ()
{
    ensure_hub_layout
    dfr_backup_ensure_layout

    cat > "$DFR_AUTO_BACKUP_HELPER" <<'EOF_DFR_AUTO_BACKUP'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

REGISTRY=/etc/dragon-fruit-relay/hub-bin/registry
BACKUPS=/var/lib/dragon-fruit-relay/backups
AUTO=${BACKUPS}/auto
STATE=${BACKUPS}/automatic-backup.conf
LOCK=/run/lock/dragon-fruit-relay-backup.lock
RETENTION=10
FORCE=no

[[ "${1:-}" == --force ]] && FORCE=yes

mkdir -p "$BACKUPS" "$AUTO" /run/lock
chmod 700 "$BACKUPS" "$AUTO"

exec 9>"$LOCK"
flock -n 9 || exit 0

if [[ "$FORCE" != yes && -r "$STATE" ]]; then
    enabled=$(awk -F= '$1=="ENABLED" {print $2; exit}' "$STATE" 2>/dev/null || true)
    [[ "$enabled" != 0 ]] || exit 0
fi

[[ -x "$REGISTRY" ]] || exit 1

stamp=$(date +%Y-%m-%d_%H-%M-%S_%Z)
out="${AUTO}/${stamp}.dfrbak"
tmp="${AUTO}/.${stamp}.$$.tmp"

cleanup_tmp() {
    rm -f -- "$tmp"
}
trap cleanup_tmp EXIT

"$REGISTRY" sync-kernel >/dev/null 2>&1 || true
"$REGISTRY" backup-create --output "$tmp" >/dev/null
"$REGISTRY" backup-verify "$tmp" >/dev/null
chmod 0600 "$tmp"
mv -f -- "$tmp" "$out"
trap - EXIT

mapfile -t old < <(
    find "$AUTO" -maxdepth 1 -type f -name '*.dfrbak' \
        -printf '%T@ %p\n' 2>/dev/null | \
    sort -rn | \
    awk -v keep="$RETENTION" 'NR>keep {$1=""; sub(/^ /,""); print}'
)

for file in "${old[@]}"; do
    [[ -n "$file" ]] || continue
    rm -f -- "$file"
done
EOF_DFR_AUTO_BACKUP

    chmod 0750 "$DFR_AUTO_BACKUP_HELPER"

    cat > "$DFR_AUTO_BACKUP_SERVICE_FILE" <<EOF_DFR_BACKUP_SERVICE
[Unit]
Description=Dragon Fruit Relay automatic portable backup
After=dragon-fruit-relay-registry.service
ConditionPathExists=${REGISTRY_DB}

[Service]
Type=oneshot
ExecStart=${DFR_AUTO_BACKUP_HELPER}
EOF_DFR_BACKUP_SERVICE

    cat > "$DFR_AUTO_BACKUP_TIMER_FILE" <<'EOF_DFR_BACKUP_TIMER'
[Unit]
Description=Dragon Fruit Relay hourly portable backup

[Timer]
OnBootSec=5min
OnUnitActiveSec=1h
AccuracySec=5min
Persistent=true
Unit=dragon-fruit-relay-backup.service

[Install]
WantedBy=timers.target
EOF_DFR_BACKUP_TIMER

    chmod 0644 "$DFR_AUTO_BACKUP_SERVICE_FILE" "$DFR_AUTO_BACKUP_TIMER_FILE"
    link_managed_unit "$DFR_AUTO_BACKUP_SERVICE"
    link_managed_unit "$DFR_AUTO_BACKUP_TIMER"
}

dfr_backup_automation_ensure ()
{
    hub_configured || return 0

    dfr_backup_ensure_layout
    dfr_backup_automation_write_files

    if [[ ! -e "$DFR_AUTO_BACKUP_STATE" ]]; then
        dfr_backup_write_state 1
    fi

    systemctl daemon-reload >/dev/null 2>&1 || true

    if dfr_backup_auto_enabled; then
        systemctl enable --now "$DFR_AUTO_BACKUP_TIMER" >/dev/null 2>&1 || \
            warn 'Automatic backup timer could not be enabled.'
    else
        systemctl disable --now "$DFR_AUTO_BACKUP_TIMER" >/dev/null 2>&1 || true
    fi
}

dfr_backup_enable_auto ()
{
    dfr_backup_write_state 1
    dfr_backup_automation_write_files
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable --now "$DFR_AUTO_BACKUP_TIMER" >/dev/null 2>&1 || {
        error 'Could not enable automatic backups.'
        return 1
    }
    success 'Hourly automatic backups are enabled.'
}


dfr_backup_disable_auto ()
{
    dfr_backup_write_state 0
    systemctl disable --now "$DFR_AUTO_BACKUP_TIMER" >/dev/null 2>&1 || true
    success 'Automatic backups are disabled. Existing backups were preserved.'
}


dfr_backup_run_auto_now ()
{
    dfr_backup_ensure_layout
    dfr_backup_automation_write_files
    "$DFR_AUTO_BACKUP_HELPER" --force
    success "Automatic backup completed in ${DFR_BACKUP_AUTO_DIR}; newest ${DFR_AUTO_BACKUP_RETENTION} are retained."
}


dfr_backup_manifest_endpoint ()
{
    local file="$1"
    python3 - "$file" <<'PY_BACKUP_ENDPOINT'
import json,sys,tarfile
with tarfile.open(sys.argv[1],'r:gz') as tf:
    f=tf.extractfile('manifest.json')
    if f is None: raise SystemExit(1)
    print(json.load(f).get('endpoint',''))
PY_BACKUP_ENDPOINT
}


# DFR_INPLACE_RESTORE_EXISTING_SAFE
#
# A rollback is not a connection deletion. Existing connection profiles are
# expected. Remove only their current runtime/configuration artifacts, replace
# the authoritative registry from the selected archive, then materialize them
# again. Never call remove_hub_client() from an in-place restore.
dfr_restore_runtime_profile_cleanup ()
{
    local connection="$1"
    local service old_if old_socket old_profile_dir

    profile_exists "$connection" || return 0

    load_client_profile "$connection"

    service="$(profile_service "$connection")"
    old_if="${XFRM_IF:-}"
    old_socket="${VICI_SOCKET:-}"
    old_profile_dir="$(profile_dir "$connection")"

    # Runtime-only cleanup. Deliberately no registry remove-connection,
    remove_client_network_rules "$connection" || true

    timeout 25s systemctl disable --now "$service" \
        >/dev/null 2>&1 || true

    if [[ -n "$old_if" ]]; then
        delete_link_bounded "$old_if" || return 1
    fi

    [[ -n "$old_socket" ]] && rm -f -- "$old_socket"

    remove_client_files "$connection"

    systemctl daemon-reload >/dev/null 2>&1 || true

    [[ ! -e "$old_profile_dir" ]] || {
        error "Restore cleanup could not remove runtime profile ${old_profile_dir}."
        return 1
    }

    if [[ -n "$old_if" ]] &&
       ip link show dev "$old_if" >/dev/null 2>&1
    then
        error "Restore cleanup left XFRM interface ${old_if} behind."
        return 1
    fi

    if systemctl is-active --quiet "$service" 2>/dev/null; then
        error "Restore cleanup left ${service} active."
        return 1
    fi

    return 0
}


# timer active. It retries every 15 seconds and will reconcile automatically
# when the tunnel(s) become usable.


dfr_current_restore_apply ()
{
    local selected_backup="$1" connection
    local -a current_profiles=()
    registry_command backup-verify "$selected_backup" >/dev/null || return 1
    systemctl stop "$SUBSCRIPTION_UNIT" "$CONTROL_UNIT" "$REGISTRY_UNIT" >/dev/null 2>&1 || true
    mapfile -t current_profiles < <(profile_names)
    for connection in "${current_profiles[@]}"; do [[ -n "$connection" ]] && dfr_restore_runtime_profile_cleanup "$connection" || true; done
    registry_command backup-restore "$selected_backup" >/dev/null || return 1
    registry_materialize_all_connections || return 1
    while IFS= read -r connection; do [[ -n "$connection" ]] || continue; start_hub_client "$connection" || { error "Restored connection '${connection}' could not start."; return 1; }; done < <(registry_command list-names)
    systemctl enable --now "$REGISTRY_UNIT" >/dev/null 2>&1 || return 1
    registry_command apply >/dev/null 2>&1 || true
    start_subscription_responder || return 1
    start_control_plane_current; systemctl is-active --quiet "$CONTROL_UNIT" 2>/dev/null || return 1
    dfr_backup_automation_ensure
}


dfr_restore_current_hub ()
{
    local file="$1" current_endpoint backup_endpoint rescue restore_lock_fd

    [[ -f "$file" ]] || {
        error "Backup file not found: $file"
        return 1
    }

    registry_command backup-verify "$file" > "$TTY_OUT" || return 1

    load_host_config
    current_endpoint="${SERVER_ENDPOINT:-}"
    backup_endpoint=$(dfr_backup_manifest_endpoint "$file" || true)

    [[ -n "$current_endpoint" && "$backup_endpoint" == "$current_endpoint" ]] || {
        error "In-place restore requires the same Server endpoint. Current=${current_endpoint:-unknown}, backup=${backup_endpoint:-unknown}."
        return 1
    }

    # Do not create a rescue archive merely because the user opened the restore
    # picker. A rescue is created only after restore is explicitly confirmed.
    if ! confirm "Restore this Server from $(basename "$file")? Current connection/subscription state will be replaced." no; then
        return 0
    fi

    install -d -m 0755 /run/lock
    exec {restore_lock_fd}>"$DFR_AUTO_BACKUP_LOCK"
    flock -x "$restore_lock_fd" || {
        error 'Could not acquire the backup/restore lock.'
        return 1
    }

    dfr_backup_ensure_layout

    section_title 'Pre-restore safety snapshot'
    registry_final_sync

    rescue="${DFR_BACKUP_RESCUE_DIR}/$(date +%Y-%m-%d_%H-%M-%S_%Z).dfrbak"

    registry_command backup-create --output "$rescue" >/dev/null || {
        error 'Could not create the mandatory pre-restore rescue backup.'
        return 1
    }

    registry_command backup-verify "$rescue" >/dev/null || {
        rm -f -- "$rescue"
        error 'The pre-restore rescue backup failed verification.'
        return 1
    }

    chmod 0600 "$rescue"
    dfr_backup_prune_rescue

    print_check pass 'Rescue backup' "$rescue" identity
    print_check info 'Rescue retention' "Newest ${DFR_RESCUE_BACKUP_RETENTION} pre-restore snapshots"

    info 'Applying selected backup to the current Server...'

    if ( dfr_current_restore_apply "$file" ); then
        success 'Current Server was restored successfully.'
        print_check info 'Safety snapshot retained' "$rescue"
        return 0
    fi

    error 'Selected restore failed. Attempting automatic rollback to the pre-restore safety snapshot.'

    if ( dfr_current_restore_apply "$rescue" ); then
        warn 'The selected restore failed, but the pre-restore state was restored successfully.'
        return 1
    fi

    error "Automatic rollback also failed. Keep the rescue archive: $rescue"
    return 1
}





# ============================================================================
# CANONICAL_UNIFIED_MONITORING_AND_OPERATIONS_UI
# Canonical Server design-system implementation. All major Server workspaces use
# the same responsive monitoring-panel -> table -> actions -> navigation grammar.
# ============================================================================







# ----- Automatic configuration-convergence UI ---------------------------------------
# Safe configuration migrations finalize themselves after the fleet proves convergence.
# Operators retain cancel/rollback, but there is no redundant manual "Finalize" step.



# ----- Backup monitoring / lifecycle -------------------------------------------------



dfr_backup_delete_file ()
{
    local file="$1" assume_yes="${2:-no}" resolved
    [[ -f "$file" && "$file" == *.dfrbak ]] || { warn 'Backup file does not exist.'; return 1; }
    resolved=$(readlink -f -- "$file" 2>/dev/null || true)
    case "$resolved" in
        "$DFR_BACKUP_AUTO_DIR"/*.dfrbak|"$DFR_BACKUP_MANUAL_DIR"/*.dfrbak|"$DFR_BACKUP_RESCUE_DIR"/*.dfrbak) ;;
        *) warn 'Refusing to delete a file outside Dragon Fruit Relay backup storage.'; return 1 ;;
    esac
    if [[ "$assume_yes" != yes ]]; then confirm "Permanently delete backup '${resolved#${REGISTRY_BACKUP_DIR}/}'?" no || return 0; fi
    rm -f -- "$resolved"
    success "Backup deleted: ${resolved#${REGISTRY_BACKUP_DIR}/}"
}


dfr_backup_browser ()
{
    local page=1 size choice rows total pages i file category epoch created bytes relative cols file_w
    size=$(ui_table_page_size 17 15)
    while true; do
        mapfile -t __dfr_backups < <(dfr_backup_inventory_tsv)
        total=${#__dfr_backups[@]}; pages=$(( (total+size-1)/size )); ((pages<1)) && pages=1; ((page>pages)) && page=$pages
        clear_screen; dfr_ui_header 'SERVER OPERATIONS | BACKUPS | INVENTORY'
        ui_panel_title 'Backup Inventory' "$([[ $total -gt 0 ]] && printf AVAILABLE || printf EMPTY)"
        cols=$(ui_content_width); file_w=$((cols-62)); ((file_w<18)) && file_w=18
        printf '  %s%-4s | %-8s | %-24s | %-10s | %s%s\n' "$C_DIM" '#' 'TYPE' 'CREATED' 'SIZE' 'BACKUP' "$C_RESET" > "$TTY_OUT"
        printf '  %s%s%s\n' "$C_DIM" "$(ui_rule $'─')" "$C_RESET" > "$TTY_OUT"
        rows=0
        for ((i=(page-1)*size; i<total && i<page*size; i++)); do
            IFS=$'\t' read -r file category epoch created bytes relative <<<"${__dfr_backups[i]}"; rows=$((rows+1))
            printf '  %s[%2d]%s | %-8s | %-24s | %-10s | %s\n' "$C_CYAN" "$rows" "$C_RESET" "$(fit_text "$category" 8)" "$(fit_text "$created" 24)" "$(fit_text "$(format_bytes_short "$bytes")" 10)" "$(fit_text "$relative" "$file_w")" > "$TTY_OUT"
        done
        ((total>0)) || printf '  %sNo backups are currently stored.%s\n' "$C_DIM" "$C_RESET" > "$TTY_OUT"
        printf '\n  %sPage %d/%d | %d backups%s\n' "$C_DIM" "$page" "$pages" "$total" "$C_RESET" > "$TTY_OUT"
        ui_view_controls basic; ui_navigation_controls; printf '\n' > "$TTY_OUT"
        choice=$(prompt '  Select backup or action: ') || return 0
        case "$choice" in
            n|N) ((page<pages)) && page=$((page+1)) ;;
            p|P) ((page>1)) && page=$((page-1)) ;;
            r|R) ;;
            g|G|90) ui_global_navigation ;;
            b|B|0) return 0 ;;
            q|Q|99) exit 0 ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice>=1 && choice<=rows)); then
                    i=$(((page-1)*size+choice-1)); IFS=$'\t' read -r file _ <<<"${__dfr_backups[i]}"; dfr_backup_item_workspace "$file"
                else warn 'Invalid selection.'; sleep 0.35; fi ;;
        esac
    done
}


# ----- Client software --------------------------------------------------------------

managed_release_list_screen ()
{
    clear_screen; dfr_ui_header 'SERVER OPERATIONS | CLIENT SOFTWARE'
    client_software_overview_panel
    section_title 'Published Releases'
    local any=0 version status sha created path when cols version_w=18 status_w=10 time_w=24 sha_w
    cols=$(ui_content_width); sha_w=$((cols-version_w-status_w-time_w-9)); ((sha_w<16)) && sha_w=16; ((sha_w>32)) && sha_w=32
    printf '  %s%-*s | %-*s | %-*s | %s%s\n' "$C_DIM" "$version_w" 'VERSION' "$status_w" 'STATUS' "$time_w" 'PUBLISHED' 'SHA256' "$C_RESET" > "$TTY_OUT"
    printf '  %s%s%s\n' "$C_DIM" "$(ui_rule $'─')" "$C_RESET" > "$TTY_OUT"
    while IFS=$'\t' read -r version status sha created path; do
        [[ -n "$version" ]] || continue; any=1; when=$(date -d "@$created" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || printf '%s' "$created")
        printf '  %-*s | %s%-*s%s | %-*s | %s\n' "$version_w" "$(fit_text "$version" "$version_w")" "$(semantic_state_color "${status^^}")" "$status_w" "$(fit_text "${status^^}" "$status_w")" "$C_RESET" "$time_w" "$(fit_text "$when" "$time_w")" "$(fit_text "$sha" "$sha_w")" > "$TTY_OUT"
    done < <(registry_command release-list 2>/dev/null || true)
    ((any)) || printf '  %sNo managed Client release has been published yet.%s\n' "$C_DIM" "$C_RESET" > "$TTY_OUT"
}

ingress_release_workspace ()
{
    local choice source status version
    ensure_release_registry_api_current
    while true; do
        managed_release_list_screen
        section_title 'Publish'
        ui_menu_item 1 "Publish Bundled ${BUNDLED_INGRESS_VERSION} Client Release" positive
        ui_menu_item 2 'Import Client Installer from File' neutral
        section_title 'Release Lifecycle'
        ui_menu_item 3 'Mark Release CANARY' caution
        ui_menu_item 4 'Promote Release STABLE + Queue AUTO Clients' positive
        ui_menu_item 5 'Return Release to STAGED' neutral
        ui_menu_item 6 'Revoke Release' destructive
        ui_menu_item 7 'Release Details' neutral
        ui_menu_item 8 'Delete REVOKED Release' destructive
        ui_navigation_footer
        choice=$(prompt '  Select an option: ') || return 0
        case "$choice" in
            1) publish_bundled_ingress_release || true; pause_screen ;;
            2) source=$(prompt '  Path to Client installer: '); [[ -f "$source" ]] || { warn 'File not found.'; pause_screen; continue; }; status=$(prompt_default 'Initial status (staged/canary)' 'staged'); [[ "${status,,}" == canary ]] && status=canary || status=staged; publish_ingress_release "$source" "$status" || true; pause_screen ;;
            3|4|5|6) version=$(select_published_release active) || continue; case "$choice" in 3) if registry_command release-status "$version" canary; then success "$version marked CANARY."; else warn "$version could not be marked CANARY."; fi ;; 4) ingress_release_promote_auto "$version" || warn "$version could not be promoted to STABLE." ;; 5) if registry_command release-status "$version" staged; then success "$version marked STAGED."; else warn "$version could not be returned to STAGED."; fi ;; 6) if registry_command release-status "$version" revoked; then success "$version REVOKED. Pending deployments of this version were cleared."; else warn "$version could not be revoked."; fi ;; esac; pause_screen ;;
            7) version=$(select_published_release all) || continue; ingress_release_details "$version" || true; pause_screen ;;
            8) version=$(select_published_release revoked) || continue; ingress_release_delete_revoked "$version" || true; pause_screen ;;
            g|G|90) ui_global_navigation ;;
            b|B|0) return 0 ;;
            q|Q|99) exit 0 ;;
            *) warn 'Invalid selection.'; sleep 0.35 ;;
        esac
    done
}








# ============================================================================
# DFR_CANONICAL_HYBRID_STATUS_UI
# One status-summary grammar for all major operational workspaces. Inventories,
# logs, service lists and release lists remain tables; monitoring summaries do
# not use table headers or implementation commentary.
# ============================================================================

semantic_colorize_segment ()
{
    local remaining="${1:-}" upper candidate prefix_upper before after token color
    local best_candidate='' best_idx=-1 best_len=0 idx candidate_len
    local zero_count=no
    [[ "$remaining" =~ ^0([[:space:]]|$) ]] && zero_count=yes

    # Canonical UI rule: labels, service names, connection names, counts and
    # ordinary values remain neutral. Only semantic state tokens are colored.
    # Longest phrases are matched first when they begin at the same position,
    # and the scan continues so one value may contain several colored states.
    while [[ -n "$remaining" ]]; do
        upper=${remaining^^}
        best_candidate=''; best_idx=-1; best_len=0
        for candidate in \
            'TEMPORARILY EXCLUDED' 'HEALTHY WITH WARNINGS' 'PASS WITH WARNINGS' 'QUOTA EXHAUSTED' 'NOT COMPATIBLE' \
            'UPGRADE REQUIRED' 'UPDATE REQUIRED' 'ROLLBACK FAILED' 'ROLLBACK READY' \
            'ENDPOINT MIGRATION' 'ROLLING BACK' \
            'NOT CONFIGURED' 'NO ACTIVE ALERTS' 'NO ACTIVE WORK' 'NO BACKUPS' 'NONE YET' 'NOT REPORTED' 'NOT ENROLLED' \
            'NOT MEMBER' 'NEVER SEEN' 'NOT FOUND' 'MASKED-RUNTIME' 'ENABLED-RUNTIME' 'LINKED-RUNTIME' 'IN PROGRESS' 'ROLLED BACK' 'CONFIG VERIFIED' \
            RECONCILING DISCONNECTED INCOMPATIBLE OPERATIONAL ESTABLISHED DOWNLOADING VERIFYING PREPARING PREPARED \
            COMPATIBLE UNAVAILABLE SCHEDULED DEACTIVATING ACTIVATING RELOADING APPLYING INSTALLING MIGRATING \
            UPDATING DEGRADED SUSPENDED CONNECTED VERIFIED COMPLETE CURRENT \
            HEALTHY AVAILABLE ENABLED INSTALLED COMMITTED CONVERGED STARTING \
            REVOKED BLOCKED EXPIRED UNHEALTHY DEFERRED RETRYING ATTENTION \
            CHECKING PENDING QUEUED WAITING PAUSED STOPPED STALE OFFLINE FAILED \
            MISSING ERROR LATEST SYNCED ACTIVE ONLINE READY AUTO AUTOMATIC MANUAL PINNED TARGET \
            STABLE STAGED CANARY MEMBER SUCCESS SUCCEEDED APPLIED LIMITED UNLIMITED REACHABLE \
            ENROLLED RUNNING LISTENING RESTORED PUBLISHED PRESENT VALID UPDATED GENERATED INDIRECT TRANSIENT LINKED STATIC ALIAS ADVISORY WARNING CRITICAL MASKED DISABLED INACTIVE CANCELLED MAINTENANCE 'AUTO-RESTART' ROLLED_BACK UNKNOWN EMPTY IDLE \
            UNREACHABLE 'NOT-FOUND' DOWN ARMED PASS FAIL OK TEMPORARY NONE 'N/A' NEVER; do
            [[ "$upper" == *"$candidate"* ]] || continue
            prefix_upper=${upper%%"$candidate"*}
            idx=${#prefix_upper}
            candidate_len=${#candidate}
            before=''; after=''
            ((idx > 0)) && before=${upper:idx-1:1}
            ((idx + candidate_len < ${#upper})) && after=${upper:idx+candidate_len:1}
            # Treat identifier punctuation as part of a token. This prevents
            # names/hosts/paths such as active-node, stable.example.com,
            # foo_active, or /srv/enabled from inheriting status colors.
            [[ -n "$before" && "$before" =~ [A-Z0-9_.:/@-] ]] && continue
            [[ -n "$after" && "$after" =~ [A-Z0-9_.:/@-] ]] && continue
            if ((best_idx < 0 || idx < best_idx || (idx == best_idx && candidate_len > best_len))); then
                best_candidate="$candidate"
                best_idx=$idx
                best_len=$candidate_len
            fi
        done
        if ((best_idx < 0)); then
            printf '%s' "$remaining"
            break
        fi
        ((best_idx > 0)) && printf '%s' "${remaining:0:best_idx}"
        token=${remaining:best_idx:best_len}
        color=$(semantic_state_color "$best_candidate")
        [[ "$zero_count" == yes ]] && color="$C_DIM"
        prefix_upper=${upper:0:best_idx}
        if [[ "$prefix_upper" =~ (^|[^A-Z0-9_])(NOT|NO)([[:space:]]+CURRENTLY)?[[:space:]]+$ ]]; then
            case "$best_candidate" in
                ONLINE|OPERATIONAL|ACTIVE|AVAILABLE|ENABLED|'ENABLED-RUNTIME'|ESTABLISHED|INSTALLED|LATEST|SYNCED|COMPATIBLE|HEALTHY|CURRENT|ENROLLED|RUNNING|SCHEDULED|COMPLETE|SUCCESS|SUCCEEDED|VERIFIED|CONNECTED|APPLIED|COMMITTED|CONVERGED|'ROLLBACK READY'|PASS|OK|ARMED|LISTENING|REACHABLE|RESTORED|PRESENT|VALID|READY|STABLE|LINKED|'LINKED-RUNTIME')
                    color="$C_YELLOW" ;;
            esac
        fi
        printf '%s%s%s' "$color" "$token" "$C_RESET"
        remaining=${remaining:best_idx+best_len}
    done
}

ui_summary_begin ()
{
    local title="$1" state="${2:-}" width
    width=$(ui_content_width)
    printf '\n  %s%s%s%s' "$C_BOLD" "$C_MAGENTA" "$title" "$C_RESET" > "$TTY_OUT"
    if [[ -n "$state" ]]; then
        printf '  %s[%s%s%s]%s' "$C_DIM" "$(semantic_state_color "$state")" "$state" "$C_DIM" "$C_RESET" > "$TTY_OUT"
    fi
    printf '\n' > "$TTY_OUT"
    printf '  %s%s%s\n' "$C_DIM" "$(ui_rule $'\u2500' "$width")" "$C_RESET" > "$TTY_OUT"
}

ui_summary_render_value ()
{
    local value="${1:--}" kind="${2:-auto}" rest segment first=yes
    value=${value// | /·}
    rest="$value"
    while [[ "$rest" == *'·'* ]]; do
        segment=${rest%%'·'*}
        segment="${segment#"${segment%%[![:space:]]*}"}"
        segment="${segment%"${segment##*[![:space:]]}"}"
        [[ "$first" == yes ]] || printf ' · '
        case "$kind" in
            muted) printf '%s%s%s' "$C_DIM" "$segment" "$C_RESET" ;;
            accent) printf '%s%s%s' "$C_CYAN" "$segment" "$C_RESET" ;;
            count)
                if [[ "$segment" =~ ^0([[:space:]]|$) || "$segment" == '0B' || "$segment" == '0 B' ]]; then printf '%s%s%s' "$C_DIM" "$segment" "$C_RESET"; else printf '%s' "$segment"; fi ;;
            identity|plain|info) printf '%s' "$segment" ;;
            *) semantic_colorize_segment "$segment" ;;
        esac
        first=no
        rest=${rest#*'·'}
    done
    rest="${rest#"${rest%%[![:space:]]*}"}"
    rest="${rest%"${rest##*[![:space:]]}"}"
    [[ "$first" == yes ]] || printf ' · '
    case "$kind" in
        muted) printf '%s%s%s' "$C_DIM" "$rest" "$C_RESET" ;;
        accent) printf '%s%s%s' "$C_CYAN" "$rest" "$C_RESET" ;;
        count)
            if [[ "$rest" =~ ^0([[:space:]]|$) || "$rest" == '0B' || "$rest" == '0 B' ]]; then printf '%s%s%s' "$C_DIM" "$rest" "$C_RESET"; else printf '%s' "$rest"; fi ;;
        identity|plain|info) printf '%s' "$rest" ;;
        *) semantic_colorize_segment "$rest" ;;
    esac
}

ui_summary_row ()
{
    local label="$1" value="${2:--}" kind="${3:-auto}" width label_width value_width line first=yes
    width=$(ui_content_width)
    label_width=22
    ((width < 72)) && label_width=18
    value_width=$((width-label_width-1))
    ((value_width < 18)) && value_width=18
    value=${value// | /·}
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line//·/·}
        if [[ "$first" == yes ]]; then
            printf '  %s%-*s%s ' "$C_DIM" "$label_width" "$label" "$C_RESET" > "$TTY_OUT"
            first=no
        else
            printf '  %-*s ' "$label_width" '' > "$TTY_OUT"
        fi
        ui_summary_render_value "$line" "$kind" > "$TTY_OUT"
        printf '\n' > "$TTY_OUT"
    done < <(printf '%s\n' "$value" | fold -s -w "$value_width")
}

fleet_print_compact_summary ()
{
    local snapshot="$1" total operational ready stopped degraded failed online stale offline never_seen attention critical warning advisory work
    local attention_clients attention_issues work_clients work_items
    IFS=$'\t' read -r total operational ready stopped degraded failed online stale offline never_seen attention critical warning advisory work < <(fleet_summary_line "$snapshot")
    IFS=$'\t' read -r attention_clients attention_issues work_clients work_items < <(fleet_ops_client_summary_line "$snapshot")
    ui_summary_begin 'Fleet summary'
    ui_summary_row 'Connections' "${total} total" count
    ui_summary_row 'Presence' "${online} online·${stale} stale·${offline} offline·${never_seen} never seen"
    ui_summary_row 'Runtime' "${operational} operational·${ready} ready·${stopped} stopped·${degraded} degraded·${failed} failed"
    ui_summary_row 'Operations' "${attention_clients} alert $([[ $attention_clients -eq 1 ]] && printf client || printf clients)·${attention_issues} $([[ $attention_issues -eq 1 ]] && printf alert || printf alerts)·${work_clients} active $([[ $work_clients -eq 1 ]] && printf client || printf clients)·${work_items} work $([[ $work_items -eq 1 ]] && printf item || printf items)"
}


hub_main_dashboard ()
{
    load_host_config
    local snapshot hub_state updated_time endpoint_value network_value
    local total operational ready stopped degraded failed online stale offline never_seen attention critical warning advisory work
    local attention_clients attention_issues work_clients work_items

    snapshot=$(fleet_snapshot_file 2>/dev/null || true)
    endpoint_value="${SERVER_ENDPOINT:-${PUBLIC_IP:-Unavailable}}"
    network_value="IPv4 ${PUBLIC_IP:-Unavailable}·interface ${WAN_IF:-Unavailable}"
    updated_time=$(date '+%H:%M:%S %Z')

    if [[ -z "$snapshot" ]]; then
        ui_summary_begin 'Server Fleet' 'UNKNOWN'
        ui_summary_row 'Endpoint' "$endpoint_value" accent
        ui_summary_row 'Network' "$network_value" identity
        ui_summary_row 'Connections' 'Unavailable'
        ui_summary_row 'Presence' 'Unavailable'
        ui_summary_row 'Runtime' 'Unavailable'
        ui_summary_row 'Operations' 'Unavailable'
        ui_summary_row 'Updated' "$updated_time" muted
        section_title 'Client Alerts'
        ui_summary_row 'Status' 'Unavailable'
        return 0
    fi

    IFS=$'\t' read -r total operational ready stopped degraded failed online stale offline never_seen attention critical warning advisory work < <(fleet_summary_line "$snapshot")
    IFS=$'\t' read -r attention_clients attention_issues work_clients work_items < <(fleet_ops_client_summary_line "$snapshot")

    if ((failed > 0 || critical > 0)); then
        hub_state='DEGRADED'
    elif ((degraded > 0 || offline > 0 || warning > 0)); then
        hub_state='ATTENTION'
    elif ((total == 0)); then
        hub_state='EMPTY'
    elif ((operational > 0)); then
        hub_state='OPERATIONAL'
    else
        hub_state='READY'
    fi

    ui_summary_begin 'Server Fleet' "$hub_state"
    ui_summary_row 'Endpoint' "$endpoint_value" accent
    ui_summary_row 'Network' "$network_value" identity
    ui_summary_row 'Connections' "${total} total" count
    ui_summary_row 'Presence' "${online} online·${stale} stale·${offline} offline·${never_seen} never seen"
    ui_summary_row 'Runtime' "${operational} operational·${ready} ready·${stopped} stopped·${degraded} degraded·${failed} failed"
    ui_summary_row 'Operations' "${attention_clients} alert $([[ $attention_clients -eq 1 ]] && printf client || printf clients)·${attention_issues} $([[ $attention_issues -eq 1 ]] && printf alert || printf alerts)·${work_clients} active $([[ $work_clients -eq 1 ]] && printf client || printf clients)·${work_items} work $([[ $work_items -eq 1 ]] && printf item || printf items)"
    ui_summary_row 'Updated' "$updated_time" muted

    section_title 'Client Alerts'
    if ((attention_clients==0)); then
        ui_summary_row 'Status' 'No active alerts' muted
    else
        print_attention_client_summary_table "$snapshot" 3
        ((attention_clients<=3)) || ui_summary_row 'Additional alerts' "$((attention_clients-3)) clients" count
    fi
}

server_operations_overview ()
{
    server_fleet_monitor_panel 'Server summary' yes
}

server_configuration_workspace ()
{
    local choice selected
    while hub_configured; do
        clear_screen
        dfr_ui_header 'SERVER CONFIGURATION'
        load_host_config
        ui_summary_begin 'Configuration summary'
        ui_summary_row 'Endpoint' "${SERVER_ENDPOINT:-$PUBLIC_IP}" accent
        ui_summary_row 'Client UDP range' "${PROFILE_PORT_MIN}-${PROFILE_PORT_MAX}"
        ui_summary_row 'Management ports' "Subscription TCP ${SUBSCRIPTION_PORT} · CONTROL TCP ${CONTROL_PORT}"
        section_title 'Actions'
        ui_menu_item 1 'Server Endpoint & Client Synchronization' neutral
        ui_menu_item 2 'Runtime Ports & Listeners' neutral
        ui_menu_item 3 'Edit a Connection Configuration' neutral
        ui_navigation_footer
        choice=$(prompt '  Select an option: ') || return 0
        case "$choice" in
            1) server_endpoint_workspace ;;
            2) server_runtime_ports_screen ;;
            3) selected=$(select_client_interactive) && managed_connection_edit_menu "$selected" || true ;;
            g|G|90) ui_global_navigation ;;
            b|B|0) return 0 ;;
            q|Q|99) exit 0 ;;
            *) warn 'Invalid selection.'; sleep 0.35 ;;
        esac
    done
}

server_runtime_ports_screen ()
{
    local choice selected count
    while hub_configured; do
        load_host_config
        count=$(profile_count)
        clear_screen
        dfr_ui_header 'SERVER CONFIGURATION | RUNTIME PORTS'
        ui_summary_begin 'Runtime port summary'
        ui_summary_row 'Status' 'ACTIVE' state
        ui_summary_row 'Subscription' "TCP ${SUBSCRIPTION_PORT}"
        ui_summary_row 'CONTROL' "TCP ${CONTROL_PORT}"
        ui_summary_row 'Client UDP range' "${PROFILE_PORT_MIN}-${PROFILE_PORT_MAX}"
        ui_summary_row 'Connections' "${count} total" count

        section_title 'Actions'
        ui_menu_item 2 'Edit Connection UDP Transport' neutral
        ui_navigation_footer
        choice=$(prompt '  Select an option: ') || return 0
        case "$choice" in
            2) selected=$(select_client_interactive) && managed_connection_edit_menu "$selected" || true ;;
            g|G|90) ui_global_navigation ;;
            b|B|0) return 0 ;;
            q|Q|99) exit 0 ;;
            *) warn 'Invalid selection.'; sleep 0.35 ;;
        esac
    done
}








manage_client_menu ()
{
    local name="$1" choice snapshot presence uuid status peer
    while profile_exists "$name"; do
        clear_screen
        dfr_ui_header 'CONNECTION DOSSIER'
        snapshot=$(fleet_snapshot_file 2>/dev/null || true)
        readarray -t _mh < <(python3 - "$snapshot" "$name" <<'PY_MANAGE_HEADER'
import json,sys
try:D=json.load(open(sys.argv[1],encoding='utf-8'))
except Exception:D={}
x=next((r for r in D.get('connections',[]) if r.get('name')==sys.argv[2]),{})
for k in ('uuid_short','runtime_status','presence','remote_peer','software_state','subscription_state'): print(x.get(k,'-'))
PY_MANAGE_HEADER
)
        uuid=${_mh[0]:--}; status=${_mh[1]:-UNKNOWN}; presence=${_mh[2]:-UNKNOWN}; peer=${_mh[3]:--}
        ui_summary_begin 'Connection summary'
        ui_summary_row 'Connection' "$name" identity
        ui_summary_row 'Connection ID' "$uuid" identity
        ui_summary_row 'Runtime' "$status" state
        ui_summary_row 'Presence' "$presence" state
        ui_summary_row 'Remote peer' "$peer" "$([[ "$peer" == - ]] && printf muted || printf identity)"
        ui_summary_row 'Client software' "${_mh[4]:-UNKNOWN}" state
        ui_summary_row 'Subscription' "${_mh[5]:-UNKNOWN}" state
        section_title 'Workspace'
        ui_menu_item 1 'Complete Overview' neutral
        ui_menu_item 2 'Diagnostics & Actions' neutral
        ui_menu_item 3 'Subscription & Traffic' neutral
        ui_menu_item 4 'Software & CONTROL' neutral
        ui_menu_item 5 'Connection Logs' neutral
        section_title 'Connection Management'
        ui_menu_item 6 'Permanently Remove Connection' destructive
        ui_navigation_footer
        choice=$(prompt '  Select a view or action: ') || return 0
        case "$choice" in
            1) show_client_status "$name" no; pause_screen ;;
            2) client_diagnostics_menu "$name" ;;
            3) subscription_menu "$name" ;;
            4) managed_connection_workspace "$name" || true ;;
            5) connection_history_screen "$name" ;;
            6)
                if confirm "Permanently delete Server connection '${name}'? This removes its tunnel, Server profile, CONTROL state, subscription/usage data and owned runtime. Other connections stay online." no; then
                    remove_hub_client "$name" yes; pause_screen; return 0
                fi ;;
            g|G|90) ui_global_navigation ;;
            b|B|0) return 0 ;;
            q|Q|99) exit 0 ;;
            *) warn 'Invalid selection.'; sleep 0.35 ;;
        esac
    done
}

show_managed_ingress_status ()
{
    local name="$1" j uuid version wanted policy health update update_display update_target update_error last bootstrap action action_status action_message error tx_state config_status software_state stable_version software_text software_target
    local client_endpoint current_endpoint endpoint_error endpoint_status endpoint_detail endpoint_desired endpoint_previous
    j=$(management_json "$name") || return 1
    readarray -t _mg < <(python3 - "$j" <<'PY_MGMT_STATUS_CANON'
import json,sys,shlex
d=json.loads(sys.argv[1]); tx=d.get('pending_transaction') or {}
def clean(v):
    if v in (None, ''): return '-'
    if not isinstance(v, str): return str(v)
    for _ in range(3):
        if '\\' not in v: break
        try: nv=' '.join(shlex.split(v,posix=True))
        except ValueError: break
        if not nv or nv == v: break
        v=nv
    return v
for k in ('connection_uuid','ingress_version','desired_ingress_version','update_policy','health','update_status','update_target','update_error','last_seen_at','bootstrap_psk_state','pending_action','action_status','action_message','last_error','client_endpoint','endpoint_error','endpoint_state','endpoint_detail','server_endpoint','previous_server_endpoint','software_state','stable_ingress_version'):
 print(clean(d.get(k)))
print(clean(tx.get('state','-')))
PY_MGMT_STATUS_CANON
)
    uuid=${_mg[0]}; version=${_mg[1]}; wanted=${_mg[2]}; policy=${_mg[3]}; health=${_mg[4]}; update=${_mg[5]}; update_target=${_mg[6]}; update_error=${_mg[7]}; last=${_mg[8]}; bootstrap=${_mg[9]}; action=${_mg[10]}; action_status=${_mg[11]}; action_message=${_mg[12]}; error=${_mg[13]}; client_endpoint=${_mg[14]}; endpoint_error=${_mg[15]}; endpoint_status=${_mg[16]}; endpoint_detail=${_mg[17]}; endpoint_desired=${_mg[18]}; endpoint_previous=${_mg[19]}; software_state=${_mg[20]}; stable_version=${_mg[21]}; tx_state=${_mg[22]}
    if [[ "$tx_state" != - ]]; then
        case "$tx_state" in PENDING) config_status='QUEUED' ;; PREPARED) config_status='SCHEDULED' ;; APPLYING) config_status='APPLYING' ;; COMMITTED) config_status='SYNCED' ;; FAILED) config_status='ROLLING BACK' ;; *) config_status="$tx_state" ;; esac
    else config_status='SYNCED'; fi
    update_display=$(managed_software_state_display "$software_state")
    software_text="$version"; [[ "$software_text" == - ]] && software_text='Unknown'
    software_target="$wanted"
    if [[ "$software_target" != - ]]; then
        if [[ "$version" != "$software_target" ]]; then software_text+=" -> ${software_target}"; elif [[ "$software_state" != LATEST ]]; then software_text+='·build update'; fi
    fi
    current_endpoint="$client_endpoint"
    ui_summary_begin 'Managed client summary'
    ui_summary_row 'Connection ID' "$([[ "$uuid" == - ]] && printf 'Unavailable' || printf '%s...' "${uuid:0:12}")"
    ui_summary_row 'Last contact' "$(management_last_seen_text "$last")"
    ui_summary_row 'Client software' "$software_text" plain
    ui_summary_row 'Client health' "$health" state
    ui_summary_row 'Update policy' "${policy^^}" state
    ui_summary_row 'Update state' "$update_display" state
    ui_summary_row 'Configuration' "$config_status" state
    if [[ "$endpoint_status" == SYNCED ]]; then
        if [[ "$endpoint_previous" != - ]]; then
            ui_summary_row 'Endpoint migration' 'SYNCED' state
            ui_summary_row 'Target endpoint' "$endpoint_desired" accent
            [[ "$current_endpoint" == - ]] || ui_summary_row 'Current endpoint' "$current_endpoint" accent
        else
            ui_summary_row 'Endpoint' "$endpoint_desired" accent
            ui_summary_row 'Endpoint state' 'CURRENT' state
        fi
    else
        ui_summary_row 'Endpoint synchronization' "$endpoint_status" state
        ui_summary_row 'Target endpoint' "$endpoint_desired" accent
        [[ "$current_endpoint" == - ]] || ui_summary_row 'Current endpoint' "$current_endpoint" accent
    fi
    [[ "$endpoint_status" != FAILED || "$endpoint_detail" == - ]] || ui_summary_row 'Endpoint error' "$endpoint_detail" warn
    [[ "$bootstrap" == - ]] || ui_summary_row 'Enrollment security' "$bootstrap"
    if [[ "$action" != - ]]; then
        case "$action_status" in SUCCEEDED|FAILED|CANCELLED) ui_summary_row 'Last operation' "$action·${action_status}" ;; *) ui_summary_row 'Managed operation' "$action·${action_status/-/QUEUED}" ;; esac
    fi
    [[ "$action_message" == - ]] || ui_summary_row 'Operation result' "$action_message"
    [[ "$update_error" == - ]] || ui_summary_row 'Update error' "$update_error" warn
    [[ "$error" == - || "$error" == "$update_error" ]] || ui_summary_row 'Client report' "$error" warn
    return 0
}

subscription_print_summary ()
{
    local name="$1" title="${2:-Subscription summary}" key value state='UNKNOWN' starts='-' expires='-' quota='-' upload='-' download='-' used='-' remaining='-' used_pct='-' remaining_pct='-' upspeed='-' downspeed='-' lifetime='-'
    while IFS=$'\t' read -r key value; do
        case "$key" in
            STATE) state="$value" ;; STARTS) starts="$value" ;; EXPIRES) expires="$value" ;; QUOTA) quota="$value" ;; UPLOAD) upload="$value" ;; DOWNLOAD) download="$value" ;; USED) used="$value" ;; REMAINING) remaining="$value" ;; USED_PERCENT) used_pct="$value" ;; REMAINING_PERCENT) remaining_pct="$value" ;; UPLOAD_Mbps) upspeed="$value" ;; DOWNLOAD_Mbps) downspeed="$value" ;; LIFETIME) lifetime="$value" ;;
        esac
    done < <(registry_command show "$name")
    [[ "$upspeed" == Unlimited || "$upspeed" == - ]] || upspeed+=" Mbps"
    [[ "$downspeed" == Unlimited || "$downspeed" == - ]] || downspeed+=" Mbps"
    ui_summary_begin "$title"
    ui_summary_row 'Status' "$state" state
    ui_summary_row 'Starts' "$starts" "$([[ "$starts" == - ]] && printf muted || printf auto)"
    ui_summary_row 'Expires' "$expires" "$([[ "$expires" == - ]] && printf muted || printf auto)"
    ui_summary_row 'Upload' "$upload"
    ui_summary_row 'Download' "$download"
    if [[ "$used_pct" == Unlimited || "$used_pct" == - ]]; then
        ui_summary_row 'Used' "$used"
        ui_summary_row 'Remaining' "$remaining"
    else
        ui_summary_row 'Used' "${used}·${used_pct}"
        ui_summary_row 'Remaining' "${remaining}·${remaining_pct}"
    fi
    ui_summary_row 'Allowance' "$quota"
    ui_summary_row 'Speed' "${upspeed} upload·${downspeed} download"
    ui_summary_row 'Lifetime traffic' "$lifetime"
}

server_endpoint_sync_summary ()
{
    local j="${1:-}" current safe enrolled synced blocking release_state release_version release_detail
    local mode migration_state sync_state summary_state name health state endpoint detail health_color state_color fallback_count fallback_names
    local -a attention_rows=()
    [[ -n "$j" ]] || j=$(endpoint_transition_json)
    readarray -t _endpoint_top < <(python3 - "$j" <<'PY_ENDPOINT_TOP_CANON'
import json,sys
try:d=json.loads(sys.argv[1])
except Exception:d={}
r=d.get('client_release') or {}; fallbacks=[str(x) for x in (d.get('fallback_server_endpoints') or [])]
print(d.get('server_endpoint') or '-')
print(d.get('endpoint_mode') or '-')
print(d.get('migration_state') or 'IDLE')
print(d.get('synchronization_state') or 'READY')
print(len(fallbacks)); print('·'.join(fallbacks)); print('yes' if d.get('safe_to_retire_fallbacks') else 'no')
print(int(d.get('enrolled_clients') or 0)); print(int(d.get('synced_clients') or 0)); print(int(d.get('blocking_clients') or 0))
print(r.get('state') or 'UNKNOWN'); print(r.get('version') or '-'); print(r.get('detail') or '-')
PY_ENDPOINT_TOP_CANON
)
    current=${_endpoint_top[0]:--}; mode=${_endpoint_top[1]:--}; migration_state=${_endpoint_top[2]:-IDLE}; sync_state=${_endpoint_top[3]:-READY}
    fallback_count=${_endpoint_top[4]:-0}; fallback_names=${_endpoint_top[5]:-}; safe=${_endpoint_top[6]:-no}
    enrolled=${_endpoint_top[7]:-0}; synced=${_endpoint_top[8]:-0}; blocking=${_endpoint_top[9]:-0}
    release_state=${_endpoint_top[10]:-UNKNOWN}; release_version=${_endpoint_top[11]:--}; release_detail=${_endpoint_top[12]:--}
    SERVER_ENDPOINT_UI_FALLBACK_COUNT=$fallback_count; SERVER_ENDPOINT_UI_SAFE=$safe; SERVER_ENDPOINT_UI_MIGRATION_STATE=$migration_state
    SERVER_ENDPOINT_UI_BLOCKING=$blocking; SERVER_ENDPOINT_UI_ENROLLED=$enrolled; SERVER_ENDPOINT_UI_SYNCED=$synced

    if [[ "$migration_state" == ACTIVE ]]; then summary_state='ACTIVE'
    elif [[ "$migration_state" == 'READY TO FINISH' ]]; then summary_state='READY'
    elif (( blocking > 0 )); then summary_state='ATTENTION'
    else summary_state='READY'; fi

    ui_summary_begin 'Endpoint summary' "$summary_state"
    ui_summary_row 'Endpoint management' "$([[ "$sync_state" == ATTENTION ]] && printf 'ATTENTION' || printf 'READY')" state
    ui_summary_row 'Active endpoint' "$current" accent
    ui_summary_row 'Endpoint type' "$mode" state
    ui_summary_row 'Endpoint migration' "$migration_state" state
    if (( enrolled == 0 )); then
        ui_summary_row 'Client synchronization' 'Ready · no enrolled Clients' muted
    else
        ui_summary_row 'Client synchronization' "${synced}/${enrolled} current · ${blocking} pending" "$([[ "$blocking" == 0 ]] && printf state || printf warn)"
    fi
    if ((fallback_count>0)); then ui_summary_row 'Previous endpoints' "$fallback_names" accent; else ui_summary_row 'Previous endpoints' 'None retained' muted; fi
    ui_summary_row 'Client release' "$([[ "$release_state" == READY ]] && printf '%s stable' "$release_version" || printf '%s' "$release_state")" "$([[ "$release_state" == READY ]] && printf auto || printf state)"

    section_title 'Client synchronization'
    if (( enrolled == 0 )); then
        print_check pass 'Endpoint synchronization' 'Ready. No enrolled Clients currently require endpoint state.'
        return 0
    fi
    if [[ "$migration_state" == 'READY TO FINISH' ]]; then
        print_check pass 'Migration convergence' 'Every enrolled Client reports the active endpoint. Previous endpoint tracking is retained until Finish migration.'
    elif [[ "$migration_state" == IDLE && "$blocking" == 0 ]]; then
        print_check pass 'Endpoint synchronization' 'Every enrolled Client reports the active endpoint. Future IP/FQDN changes remain available.'
    elif [[ "$migration_state" == IDLE ]]; then
        print_check warn 'Endpoint drift' "$blocking Client(s) do not report the active endpoint; Synchronize can reconcile them without opening a new migration."
    fi

    printf '  %s%-16s %-9s %-15s %s%s\n' "$C_DIM" 'CLIENT' 'HEALTH' 'ENDPOINT STATE' 'CURRENT ENDPOINT' "$C_RESET" > "$TTY_OUT"
    printf '  %s%s%s\n' "$C_DIM" "$(ui_rule '─')" "$C_RESET" > "$TTY_OUT"
    while IFS=$'\t' read -r name health state endpoint detail; do
        [[ -n "$name" ]] || continue; health_color=$(semantic_state_color "$health"); state_color=$(endpoint_state_color "$state")
        printf '  %-16s %s%-9s%s %s%-15s%s %s%s%s\n' "$(fit_text "$name" 16)" "$health_color" "$(fit_text "$health" 9)" "$C_RESET" "$state_color" "$(fit_text "$state" 15)" "$C_RESET" "$C_CYAN" "$(fit_text "$endpoint" 26)" "$C_RESET" > "$TTY_OUT"
        case "$state" in FAILED|'UPDATE REQUIRED'|DEFERRED) attention_rows+=("$name"$'\t'"$state"$'\t'"$detail") ;; esac
    done < <(python3 - "$j" <<'PY_ENDPOINT_CLIENT_ROWS_CANON'
import json,sys
try:d=json.loads(sys.argv[1])
except Exception:d={}
for item in d.get('clients') or []:
 vals=[item.get('name') or '-',item.get('health') or '-',item.get('state') or 'UNKNOWN',item.get('current_endpoint') or item.get('reported_endpoint') or '-',str(item.get('detail') or '').replace('\t',' ').replace('\n',' ')]
 print('\t'.join(str(v) for v in vals))
PY_ENDPOINT_CLIENT_ROWS_CANON
)
    if ((${#attention_rows[@]})); then
        section_title 'Attention'; local row
        for row in "${attention_rows[@]}"; do IFS=$'\t' read -r name state detail <<< "$row"; ui_summary_row "$name" "$state · $detail"; done
    fi
}

show_client_status ()
{
    local name="$1" json="${2:-no}" j
    local uuid created last_seen last_connected last_disconnected last_offline presence software policy endpoint substate
    local attn_lines attn_severity attn_area attn_headline attn_next attn_color

    collect_client_runtime "$name"
    if [[ "$json" == yes ]]; then
        python3 - "$SNAP_NAME" "$SNAP_STATUS" "$SNAP_SERVICE" "$SNAP_ENABLED" "$SNAP_LISTENER" "$SNAP_TRANSPORT" "$SNAP_PEER" "$SNAP_AGE" "$SNAP_IKE" "$SNAP_CHILD" "$SNAP_XFRM" "$SNAP_XFRM_ID" "$SNAP_TUNNEL" "$SNAP_LOCAL_TUNNEL" "$SNAP_REMOTE_TUNNEL" "$SNAP_RX_BYTES" "$SNAP_RX_PACKETS" "$SNAP_TX_BYTES" "$SNAP_TX_PACKETS" <<'PY_STATUS_CANON'
import json,sys
print(json.dumps({"name":sys.argv[1],"status":sys.argv[2],"service":sys.argv[3],"enabled":sys.argv[4],"listener":sys.argv[5],"transport":sys.argv[6],"peer":sys.argv[7],"uptime":sys.argv[8],"ike":sys.argv[9],"child":sys.argv[10],"xfrm_interface":sys.argv[11],"xfrm_id":int(sys.argv[12]),"tunnel":sys.argv[13],"egress_xfrm_ip":sys.argv[14],"ingress_xfrm_ip":sys.argv[15],"rx_bytes":int(sys.argv[16]),"rx_packets":int(sys.argv[17]),"tx_bytes":int(sys.argv[18]),"tx_packets":int(sys.argv[19])},indent=2))
PY_STATUS_CANON
        return 0
    fi

    j=$(fleet_snapshot_file 2>/dev/null || true)
    readarray -t _ov < <(python3 - "$j" "$name" <<'PY_OVERVIEW_FIELDS_CANON'
import json,sys
try:D=json.load(open(sys.argv[1], encoding='utf-8'))
except Exception:D={}
x=next((r for r in D.get('connections',[]) if r.get('name')==sys.argv[2]),{})
for k in ('connection_uuid','created_at','presence','last_seen_at','last_connected_at','last_disconnected_at','last_offline_at','software_state','update_policy','endpoint_state','subscription_state','ingress_version','stable_ingress_version'):
 print(x.get(k,'-') if x.get(k) not in (None,'') else '-')
PY_OVERVIEW_FIELDS_CANON
)
    uuid=${_ov[0]:--}; created=${_ov[1]:-0}; presence=${_ov[2]:-UNKNOWN}; last_seen=${_ov[3]:-0}; last_connected=${_ov[4]:-0}; last_disconnected=${_ov[5]:-0}; last_offline=${_ov[6]:-0}; software=${_ov[7]:-UNKNOWN}; policy=${_ov[8]:-manual}; endpoint=${_ov[9]:-UNKNOWN}; substate=${_ov[10]:-UNKNOWN}
    local canonical_runtime
    canonical_runtime=$(python3 - "$j" "$name" <<'PY_DFR_OVERVIEW_RUNTIME'
import json,sys
try:d=json.load(open(sys.argv[1],encoding='utf-8'))
except Exception:d={}
r=next((x for x in d.get('connections',[]) if x.get('name')==sys.argv[2]),{})
print(r.get('runtime_status') or 'UNKNOWN')
PY_DFR_OVERVIEW_RUNTIME
)

    clear_screen
    dfr_ui_header 'CONNECTION OVERVIEW'
    ui_summary_begin 'Connection summary'
    ui_summary_row 'Connection' "$name" identity
    ui_summary_row 'Connection ID' "$uuid" "$([[ "$uuid" == - ]] && printf muted || printf identity)"
    ui_summary_row 'Created' "$(date -d "@$created" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || printf '%s' "$created")"

    attn_lines=$(python3 - "$j" "$name" <<'PY_CLIENT_ATTN_CANON'
import json,sys
try:D=json.load(open(sys.argv[1], encoding='utf-8'))
except Exception:D={}
rank={'CRITICAL':0,'WARNING':1,'ADVISORY':2}
rows=[x for x in (D.get('attention') or []) if x.get('connection_name')==sys.argv[2]]
rows.sort(key=lambda x:(rank.get(str(x.get('severity','')).upper(),9),str(x.get('area','')),str(x.get('headline',''))))
for x in rows:
 vals=(x.get('severity','-'),x.get('area','-'),x.get('headline','-'),x.get('recommended_action','-'))
 print('\t'.join(str(v).replace('\t',' ').replace('\n',' ') for v in vals))
PY_CLIENT_ATTN_CANON
)
    if [[ -n "$attn_lines" ]]; then
        section_title 'Current alerts'
        printf '  %s%-9s | %-14s | %s%s\n' "$C_DIM" 'LEVEL' 'AREA' 'ISSUE' "$C_RESET" > "$TTY_OUT"
        printf '  %s%s%s\n' "$C_DIM" "$(ui_rule $'\u2500')" "$C_RESET" > "$TTY_OUT"
        while IFS=$'\t' read -r attn_severity attn_area attn_headline attn_next; do
            attn_color=$(semantic_state_color "$attn_severity")
            printf '  %s%-9s%s | %-14s | %s\n' "$attn_color" "$(fit_text "$attn_severity" 9)" "$C_RESET" "$(fit_text "$attn_area" 14)" "$(fit_text "$attn_headline" 64)" > "$TTY_OUT"
        done <<<"$attn_lines"
    fi

    ui_summary_begin 'Presence summary'
    ui_summary_row 'Status' "$presence" state
    ui_summary_row 'Last seen' "$(presence_timestamp_text "$last_seen")" "$([[ "$last_seen" =~ ^[1-9][0-9]*$ ]] && printf info || printf muted)"
    [[ "$last_connected" =~ ^[1-9][0-9]*$ ]] && ui_summary_row 'Last connected' "$(presence_timestamp_text "$last_connected")"
    [[ "$last_disconnected" =~ ^[1-9][0-9]*$ ]] && ui_summary_row 'Last disconnected' "$(presence_timestamp_text "$last_disconnected")"

    ui_summary_begin 'Runtime summary'
    ui_summary_row 'Status' "$canonical_runtime" state
    ui_summary_row 'Service' "$SNAP_SERVICE·boot $SNAP_ENABLED"
    ui_summary_row 'Transport' "$SNAP_TRANSPORT"
    ui_summary_row 'Remote peer' "$SNAP_PEER" "$([[ "$SNAP_PEER" == - ]] && printf muted || printf identity)"
    ui_summary_row 'IKE / CHILD' "$SNAP_IKE·$SNAP_CHILD"
    ui_summary_row 'Session uptime' "$SNAP_AGE"
    ui_summary_row 'Tunnel' "$SNAP_TUNNEL·$SNAP_XFRM (ID $SNAP_XFRM_ID)" identity
    ui_summary_row 'Traffic' "$(snapshot_traffic_text)"

    # Complete Overview owns the full subscriber dossier. Show the
    # authoritative quota/period/traffic/speed/lifetime data before the
    # managed-services state, matching the requested detailed-view order.
    subscription_print_summary "$name" 'Subscription & Traffic'

    ui_summary_begin 'Managed services summary'
    ui_summary_row 'Client software' "${_ov[11]:--}·$software"
    ui_summary_row 'Update policy' "${policy^^}" state
    ui_summary_row 'Stable release' "${_ov[12]:--}" "$([[ "${_ov[12]:--}" == - ]] && printf muted || printf plain)"
    ui_summary_row 'Endpoint' "$endpoint" accent
    ui_summary_row 'Subscription' "$substate" state
}


# ============================================================================
# DFR_CANONICAL_UI_AUDIT_FINAL
# outside the main interactive workspaces.
# ============================================================================


render_client_token ()
{
    local name="$1" token="$2" expires_text
    profile_exists "$name" || die "Client profile '${name}' does not exist."
    load_client_profile "$name"
    expires_text=$(date -d "+${ENROLLMENT_TOKEN_TTL_SECONDS} seconds" '+%Y-%m-%d %H:%M:%S %Z')

    printf '\n' > "$TTY_OUT"
    ui_summary_begin 'Enrollment summary'
    ui_summary_row 'Connection' "$name" identity
    ui_summary_row 'Status' 'READY' state
    ui_summary_row 'Server' "${SERVER_ENDPOINT:-$PUBLIC_IP}" accent
    ui_summary_row 'Transport' "UDP ${NATT_PORT}" plain
    ui_summary_row 'Expires' "$expires_text" plain

    section_title 'Enrollment token'
    printf '%s\n' "$token" > "$TTY_OUT"

    section_title 'Client command'
    ui_summary_row 'Existing Client' 'sudo dragon-fruit-relay enroll'
    ui_summary_row 'Fresh Server' 'sudo ./dragon-fruit-relay-connect'
    printf '\n  %sToken is valid for one enrollment. Issuing a new token invalidates the previous unused token.%s\n' "$C_DIM" "$C_RESET" > "$TTY_OUT"
}

dfr_backup_item_workspace ()
{
    local file="$1" choice category created size relative
    while [[ -f "$file" ]]; do
        category=$(dfr_backup_category "$file")
        created=$(dfr_backup_display_time "$file")
        size=$(stat -c '%s' "$file" 2>/dev/null || printf 0)
        relative="${file#${REGISTRY_BACKUP_DIR}/}"
        clear_screen
        dfr_ui_header 'SERVER OPERATIONS | BACKUPS | BACKUP'
        ui_summary_begin 'Backup summary'
        ui_summary_row 'Status' 'AVAILABLE' state
        ui_summary_row 'Type' "$category"
        ui_summary_row 'Created' "$created"
        ui_summary_row 'Size' "$(format_bytes_short "$size")"
        ui_summary_row 'Backup' "$relative"
        section_title 'Actions'
        ui_menu_item 1 'Verify Integrity' positive
        ui_menu_item 2 'Restore This Server from Backup' caution
        ui_menu_item 3 'Delete Backup' destructive
        ui_navigation_footer
        choice=$(prompt '  Select an option: ') || return 0
        case "$choice" in
            1) registry_command backup-verify "$file" >"$TTY_OUT" || true; pause_screen ;;
            2) dfr_restore_current_hub "$file" || true; pause_screen ;;
            3) dfr_backup_delete_file "$file" no; pause_screen; [[ -f "$file" ]] || return 0 ;;
            g|G|90) ui_global_navigation ;;
            b|B|0) return 0 ;;
            q|Q|99) exit 0 ;;
            *) warn 'Invalid selection.'; sleep 0.35 ;;
        esac
    done
}

dfr_fresh_restore_instructions ()
{
    clear_screen
    dfr_ui_header 'SERVER OPERATIONS | BACKUPS | DISASTER RESTORE'
    ui_summary_begin 'Restore summary'
    ui_summary_row 'Status' 'READY' state
    ui_summary_row 'Command' 'dragon-fruit-relay restore /path/to/backup.dfrbak'
    ui_summary_row 'Backup types' 'Automatic·Manual·Pre-restore'
    ui_summary_row 'Restores' 'Server configuration·connections·subscriptions·managed releases'
    pause_screen
}

backup_workspace ()
{
    local choice file
    while hub_configured; do
        load_host_config
        clear_screen
        dfr_ui_header 'SERVER OPERATIONS | BACKUPS & RECOVERY'
        dfr_backup_status_rows
        section_title 'Backup Operations'
        ui_menu_item 1 'Create Manual Backup' positive
        ui_menu_item 2 'Browse / Verify / Restore / Delete Backups' neutral
        ui_menu_item 3 'Run Automatic Backup Now' positive
        section_title 'Automatic Backups'
        if dfr_backup_auto_enabled; then ui_menu_item 4 'Disable Hourly Automatic Backups' caution; else ui_menu_item 4 'Enable Hourly Automatic Backups' positive; fi
        ui_menu_item 5 'Fresh-Server Restore Instructions' neutral
        ui_navigation_footer
        choice=$(prompt '  Select an option: ') || return 0
        case "$choice" in
            1) file=$(dfr_backup_create_manual || true); [[ -n "$file" ]] && success "Manual backup created: $file" || error 'Manual backup creation failed.'; pause_screen ;;
            2) dfr_backup_browser ;;
            3) dfr_backup_run_auto_now || true; pause_screen ;;
            4) if dfr_backup_auto_enabled; then confirm 'Disable periodic automatic backups? Existing backups will be kept.' no && dfr_backup_disable_auto; else dfr_backup_enable_auto || true; fi; pause_screen ;;
            5) dfr_fresh_restore_instructions ;;
            g|G|90) ui_global_navigation ;;
            b|B|0) return 0 ;;
            q|Q|99) exit 0 ;;
            *) warn 'Invalid selection.'; sleep 0.35 ;;
        esac
    done
}




# ============================================================================
# DFR_PRODUCTION_RUNTIME_UI
# current.1 production hardening: overview renderers are read-only and bounded.
# Reuse the fleet snapshot for server metadata, batch systemd reads, and avoid
# live accounting/probe work unless the operator explicitly requests it.
# ============================================================================

fleet_server_metadata_line ()
{
    local snapshot="$1"
    python3 - "$snapshot" <<'PY_SERVER_META'
import json,sys
try:d=json.load(open(sys.argv[1],encoding='utf-8'))
except Exception:d={}
s=d.get('server') or {}; rc=s.get('release_counts') or {}; fallbacks=s.get('fallback_server_endpoints') or []
vals=[s.get('stable_release') or '-',s.get('canary_release') or '-',int(rc.get('stable',0))+int(rc.get('canary',0))+int(rc.get('staged',0))+int(rc.get('revoked',0)),int(rc.get('staged',0)),int(rc.get('revoked',0)),1 if fallbacks else 0]
print('\t'.join(map(str,vals)))
PY_SERVER_META
}

server_core_states_batch ()
{
    local -a units=("$REGISTRY_UNIT" "$CONTROL_UNIT" "$SUBSCRIPTION_UNIT")
    if declare -p DFR_AUTO_BACKUP_TIMER >/dev/null 2>&1; then
        units+=("$DFR_AUTO_BACKUP_TIMER")
    fi
    systemctl is-active "${units[@]}" 2>/dev/null || true
}

server_fleet_monitor_panel ()
{
    local title="${1:-Fleet summary}" include_infra="${2:-no}" snapshot
    local total operational ready stopped degraded failed online stale offline never_seen attention critical warning advisory work
    local attention_clients attention_issues work_clients work_items stable='-' canary='-' release_count=0 staged=0 revoked=0 endpoint_change=0
    local registry_state='inactive' control_state='inactive' subscription_state='inactive' backup_state='not configured' convergence='IDLE' panel_state
    local -a states=()
    snapshot=$(fleet_snapshot_file 2>/dev/null || true)
    if [[ -z "$snapshot" ]]; then ui_summary_begin "$title" 'UNKNOWN'; ui_summary_row 'Status' 'UNKNOWN' state; ui_summary_row 'Fleet snapshot' 'Unavailable'; return 0; fi
    IFS=$'\t' read -r total operational ready stopped degraded failed online stale offline never_seen attention critical warning advisory work < <(fleet_summary_line "$snapshot")
    IFS=$'\t' read -r attention_clients attention_issues work_clients work_items < <(fleet_ops_client_summary_line "$snapshot")
    if ((failed > 0 || critical > 0)); then panel_state='DEGRADED'; elif ((degraded > 0 || offline > 0 || warning > 0)); then panel_state='ATTENTION'; elif ((total == 0)); then panel_state='EMPTY'; elif ((operational > 0)); then panel_state='OPERATIONAL'; else panel_state='READY'; fi
    ui_summary_begin "$title" "$panel_state"
    ui_summary_row 'Connections' "${total} total" count
    ui_summary_row 'Presence' "${online} online·${stale} stale·${offline} offline·${never_seen} never seen"
    ui_summary_row 'Runtime' "${operational} operational·${ready} ready·${stopped} stopped·${degraded} degraded·${failed} failed"
    ui_summary_row 'Operations' "${attention_clients} alert clients·${attention_issues} alerts·${work_clients} active clients·${work_items} work items"
    if [[ "$include_infra" == yes ]]; then
        IFS=$'\t' read -r stable canary release_count staged revoked endpoint_change < <(fleet_server_metadata_line "$snapshot")
        mapfile -t states < <(server_core_states_batch); registry_state=${states[0]:-inactive}; control_state=${states[1]:-inactive}; subscription_state=${states[2]:-inactive}; [[ ${#states[@]} -ge 4 ]] && backup_state=${states[3]:-inactive}
        ((endpoint_change)) && convergence='ENDPOINT CHANGE'
        ui_summary_row 'Endpoint' "${SERVER_ENDPOINT:-$PUBLIC_IP}" accent
        ui_summary_row 'Core services' "Registry ${registry_state}·CONTROL ${control_state}·Subscription ${subscription_state}"
        [[ "$stable" != - ]] && ui_summary_row 'Client release' "${stable} stable" auto || ui_summary_row 'Client release' 'None' muted
        ui_summary_row 'Backups' "Automatic ${backup_state}"
        ui_summary_row 'Configuration' "$convergence" state
    fi
}

service_inventory_batch ()
{
    local -a units=("$REGISTRY_UNIT" "$CONTROL_UNIT" "$SUBSCRIPTION_UNIT")
    if declare -p DFR_AUTO_BACKUP_TIMER >/dev/null 2>&1; then units+=("$DFR_AUTO_BACKUP_TIMER"); fi
    systemctl show "${units[@]}" \
        -p Id -p LoadState -p ActiveState -p SubState -p UnitFileState -p Result \
        --no-pager 2>/dev/null | awk -F= '
        function emit(){
            if(id!="") printf "%s\t%s\t%s\t%s\t%s\t%s\n",id,load,active,substate,enabled,result
            id=load=active=substate=enabled=result=""
        }
        NF==0 { emit(); next }
        $1=="Id" { id=$2 }
        $1=="LoadState" { load=$2 }
        $1=="ActiveState" { active=$2 }
        $1=="SubState" { substate=$2 }
        $1=="UnitFileState" { enabled=$2 }
        $1=="Result" { result=$2 }
        END { emit() }
    '
}

service_row_from_state ()
{
    local label="$1" unit="$2" load="$3" active="$4" sub="$5" enabled="$6" result="$7" timer_active="${8:-}"
    local badge display display_color enabled_text result_text
    if [[ "$load" == not-found || -z "$load" ]]; then
        badge='X'; display='NOT FOUND'
    elif [[ "$active" == active ]]; then
        badge='●'; case "$sub" in running) display='RUNNING' ;; exited) display='READY' ;; waiting) display='WAITING' ;; *) display="${sub^^}" ;; esac
    elif [[ "$active" == failed ]]; then
        badge='X'; display='FAILED'
    elif [[ "$active" == activating ]]; then
        badge='●'; display='ACTIVATING'
    elif [[ "$active" == deactivating ]]; then
        badge='○'; display='DEACTIVATING'
    else
        badge='○'; display="${active^^}"
    fi
    display_color=$(semantic_state_color "$display")
    enabled_text="${enabled:-unknown}"; result_text="${result:-n/a}"
    printf '  %-31s %s%s %-12s%s  ' "$label" "$display_color" "$badge" "$display" "$C_RESET" > "$TTY_OUT"
    semantic_colorize_line "$enabled_text" > "$TTY_OUT"; printf '  ' > "$TTY_OUT"
    semantic_colorize_line "$result_text" > "$TTY_OUT"; printf '\n' > "$TTY_OUT"
}

server_runtime_services_screen ()
{
    local id load active sub enabled result
    local -A loads=() actives=() subs=() enableds=() results=()
    clear_screen; dfr_ui_header 'SERVER OPERATIONS | RUNTIME & SERVICES'; server_fleet_monitor_panel 'Runtime summary' yes
    while IFS=$'\t' read -r id load active sub enabled result; do [[ -n "$id" ]] || continue; loads["$id"]=$load; actives["$id"]=$active; subs["$id"]=$sub; enableds["$id"]=$enabled; results["$id"]=$result; done < <(service_inventory_batch)
    section_title 'Core Services'
    printf '  %s%-31s | %-12s | %-13s | %s%s\n' "$C_DIM" 'SERVICE' 'STATE' 'STARTUP' 'LAST RESULT' "$C_RESET" > "$TTY_OUT"
    printf '  %s%s%s\n' "$C_DIM" "$(ui_rule $'─')" "$C_RESET" > "$TTY_OUT"
    service_row_from_state 'Registry' "$REGISTRY_UNIT" "${loads[$REGISTRY_UNIT]:-}" "${actives[$REGISTRY_UNIT]:-}" "${subs[$REGISTRY_UNIT]:-}" "${enableds[$REGISTRY_UNIT]:-}" "${results[$REGISTRY_UNIT]:-}" inactive
    service_row_from_state 'CONTROL responder' "$CONTROL_UNIT" "${loads[$CONTROL_UNIT]:-}" "${actives[$CONTROL_UNIT]:-}" "${subs[$CONTROL_UNIT]:-}" "${enableds[$CONTROL_UNIT]:-}" "${results[$CONTROL_UNIT]:-}" inactive
    service_row_from_state 'Subscription responder' "$SUBSCRIPTION_UNIT" "${loads[$SUBSCRIPTION_UNIT]:-}" "${actives[$SUBSCRIPTION_UNIT]:-}" "${subs[$SUBSCRIPTION_UNIT]:-}" "${enableds[$SUBSCRIPTION_UNIT]:-}" "${results[$SUBSCRIPTION_UNIT]:-}" inactive
    if declare -p DFR_AUTO_BACKUP_TIMER >/dev/null 2>&1; then service_row_from_state 'Automatic backup timer' "$DFR_AUTO_BACKUP_TIMER" "${loads[$DFR_AUTO_BACKUP_TIMER]:-}" "${actives[$DFR_AUTO_BACKUP_TIMER]:-}" "${subs[$DFR_AUTO_BACKUP_TIMER]:-}" "${enableds[$DFR_AUTO_BACKUP_TIMER]:-}" "${results[$DFR_AUTO_BACKUP_TIMER]:-}" inactive; fi
    section_title 'Runtime Listeners'; ui_kv_table_begin 'LISTENER' 'CURRENT VALUE'
    ui_kv_table_row 'Subscription protocol' "TCP ${SUBSCRIPTION_PORT} (tunnel-scoped)"
    ui_kv_table_row 'CONTROL protocol' "TCP ${CONTROL_PORT} (tunnel-scoped)"
    ui_kv_table_row 'Client transport range' "UDP ${PROFILE_PORT_MIN}-${PROFILE_PORT_MAX} (per connection)"
}

client_software_overview_panel ()
{
    local snapshot stable='-' canary='-' release_count=0 staged=0 revoked=0 auto=0 manual=0 pinned=0 current=0 required=0 active=0
    snapshot=$(fleet_snapshot_file 2>/dev/null || true)
    if [[ -n "$snapshot" ]]; then
        IFS=$'\t' read -r stable canary release_count staged revoked auto manual pinned current required active < <(python3 - "$snapshot" <<'PY_DFR_SOFTWARE_PANEL'
import json,sys
try:d=json.load(open(sys.argv[1],encoding='utf-8'))
except Exception:d={}
s=d.get('server') or {}; rc=s.get('release_counts') or {}
pol={'auto':0,'manual':0,'pinned':0}; current=required=active=0
for r in d.get('connections',[]):
    p=str(r.get('update_policy') or 'manual').lower(); pol[p]=pol.get(p,0)+1
    st=str(r.get('software_state') or '').upper()
    if st in ('LATEST','CURRENT'): current+=1
    if st=='UPDATE REQUIRED': required+=1
for x in d.get('active_work') or []:
    if str(x.get('area') or '').upper()=='SOFTWARE': active+=1
count=sum(int(rc.get(k,0)) for k in ('stable','canary','staged','revoked'))
print(s.get('stable_release') or '-',s.get('canary_release') or '-',count,int(rc.get('staged',0)),int(rc.get('revoked',0)),pol.get('auto',0),pol.get('manual',0),pol.get('pinned',0),current,required,active,sep='\t')
PY_DFR_SOFTWARE_PANEL
)
    fi
    ui_summary_begin 'Client software summary'
    ui_summary_row 'Releases' "${release_count} published·${staged} staged·${revoked} revoked"
    [[ "$stable" != - ]] && ui_summary_row 'Stable release' "$stable" || ui_summary_row 'Stable release' 'None' muted
    [[ "$canary" != - ]] && ui_summary_row 'Canary release' "$canary" || ui_summary_row 'Canary release' 'None' muted
    ui_summary_row 'Update policies' "${auto} automatic·${manual} manual·${pinned} pinned"
    ui_summary_row 'Clients' "${current} current·${required} update required·${active} updating"
}

dfr_backup_status_rows ()
{
    local timer auto_state total=0 auto_count=0 manual_count=0 rescue_count=0 total_bytes=0 latest_time='None yet'
    local file category epoch created size relative
    while IFS=$'\t' read -r file category epoch created size relative; do
        [[ -n "$file" ]] || continue
        total=$((total+1)); total_bytes=$((total_bytes+size))
        [[ "$latest_time" == 'None yet' ]] && latest_time="$created"
        case "$category" in AUTO) auto_count=$((auto_count+1)) ;; MANUAL) manual_count=$((manual_count+1)) ;; RESCUE) rescue_count=$((rescue_count+1)) ;; esac
    done < <(dfr_backup_inventory_tsv)
    timer=$(systemctl is-active "$DFR_AUTO_BACKUP_TIMER" 2>/dev/null || printf inactive)
    if dfr_backup_auto_enabled; then auto_state='ENABLED'; else auto_state='DISABLED'; fi
    ui_summary_begin 'Backup summary'
    ui_summary_row 'Backups' "${total} total·${auto_count} automatic·${manual_count} manual·${rescue_count} rescue"
    ui_summary_row 'Storage used' "$(format_bytes_short "$total_bytes")" count
    ui_summary_row 'Automatic backups' "${auto_state}·timer ${timer}"
    ui_summary_row 'Latest backup' "$latest_time" "$([[ "$latest_time" == 'None yet' ]] && printf muted || printf auto)"
    ui_summary_row 'Retention' "${DFR_AUTO_BACKUP_RETENTION} automatic·${DFR_RESCUE_BACKUP_RETENTION} rescue"
}


# current.1 production inventory: one read-only scan, with no migration or repair side effects.
dfr_backup_inventory_tsv ()
{
    python3 - "$REGISTRY_BACKUP_DIR" "$DFR_BACKUP_AUTO_DIR" "$DFR_BACKUP_MANUAL_DIR" "$DFR_BACKUP_RESCUE_DIR" <<'PY_DFR_BACKUP_INVENTORY'
import datetime,os,pathlib,stat,sys
root=pathlib.Path(sys.argv[1])
sources=(("AUTO",sys.argv[2]),("MANUAL",sys.argv[3]),("RESCUE",sys.argv[4]))
rows=[]
for category,directory in sources:
    try: entries=os.scandir(directory)
    except OSError: continue
    with entries:
        for entry in entries:
            if not entry.name.endswith('.dfrbak'): continue
            try: st=entry.stat(follow_symlinks=False)
            except OSError: continue
            if not stat.S_ISREG(st.st_mode): continue
            path=pathlib.Path(entry.path); epoch=int(st.st_mtime)
            created=datetime.datetime.fromtimestamp(epoch).astimezone().strftime('%Y-%m-%d %H:%M:%S %Z')
            try: relative=str(path.relative_to(root))
            except ValueError: relative=path.name
            rows.append((epoch,str(path),category,created,int(st.st_size),relative))
for epoch,path,category,created,size,relative in sorted(rows)[::-1]:
    print(path,category,epoch,created,size,relative,sep='\t')
PY_DFR_BACKUP_INVENTORY
}


# ============================================================================
# One monitoring truth model for every overview/inventory. Liveness is read
# state but is never the authority for monitoring freshness.
# ============================================================================











client_diagnostic_summary ()
{
    local name="$1" snapshot alerts
    if ! collect_client_runtime "$name"; then
        ui_summary_begin 'Diagnostic summary' 'UNKNOWN'; ui_summary_row 'Runtime' 'Unavailable'; return 0
    fi
    snapshot=$(fleet_snapshot_file 2>/dev/null || true)
    alerts=$(python3 - "$snapshot" "$name" <<'PY_DIAG'
import json,sys
try:D=json.load(open(sys.argv[1],encoding='utf-8'))
except Exception:D={}
print(sum(1 for x in D.get('attention',[]) if x.get('connection_name')==sys.argv[2]))
PY_DIAG
)
    ui_summary_begin 'Diagnostic summary' "$SNAP_STATUS"
    ui_summary_row 'Service' "$SNAP_SERVICE·boot $SNAP_ENABLED"
    ui_summary_row 'IKE / CHILD' "$SNAP_IKE·$SNAP_CHILD"
    ui_summary_row 'Tunnel' "$SNAP_TUNNEL·$SNAP_XFRM (ID $SNAP_XFRM_ID)" identity
    ui_summary_row 'Traffic' "$(snapshot_traffic_text)"
    ui_summary_row 'Active alerts' "${alerts:-0}" count
}


list_hub_clients ()
{
    local json="${1:-no}" snapshot rows=0 cols name_w runtime_w presence_w transport_w peer_w
    local name runtime presence transport peer
    load_host_config
    if [[ "$json" == yes ]]; then
        local first=yes; printf '['
        while IFS= read -r name; do [[ -n "$name" ]] || continue; collect_client_runtime "$name" || true; [[ "$first" == yes ]] || printf ','; first=no
            python3 - "$SNAP_NAME" "$SNAP_STATUS" "$SNAP_SERVICE" "$SNAP_ENABLED" "$SNAP_TRANSPORT" "$SNAP_PEER" "$SNAP_AGE" "$SNAP_XFRM" "$SNAP_XFRM_ID" "$SNAP_TUNNEL" "$SNAP_RX_BYTES" "$SNAP_RX_PACKETS" "$SNAP_TX_BYTES" "$SNAP_TX_PACKETS" <<'PY_JSON_ROW'
import json,sys
print(json.dumps({'name':sys.argv[1],'status':sys.argv[2],'service':sys.argv[3],'enabled':sys.argv[4],'transport':sys.argv[5],'peer':sys.argv[6],'uptime':sys.argv[7],'xfrm_interface':sys.argv[8],'xfrm_id':int(sys.argv[9]),'tunnel':sys.argv[10],'rx_bytes':int(sys.argv[11]),'rx_packets':int(sys.argv[12]),'tx_bytes':int(sys.argv[13]),'tx_packets':int(sys.argv[14])}),end='')
PY_JSON_ROW
        done < <(profile_names); printf ']\n'; return 0
    fi
    snapshot=$(fleet_snapshot_file 2>/dev/null || true); section_title 'Connection inventory'
    [[ -n "$snapshot" ]] || { ui_summary_row 'Connections' 'Unavailable'; return 0; }
    cols=$(ui_content_width); name_w=20; runtime_w=14; presence_w=12; transport_w=14; peer_w=22
    ((cols<96)) && { name_w=18; runtime_w=12; presence_w=10; transport_w=12; peer_w=18; }
    ((cols<76)) && { name_w=16; runtime_w=11; presence_w=10; transport_w=11; peer_w=0; }
    printf '  %s%-*s | %-*s | %-*s' "$C_DIM" "$name_w" 'CONNECTION' "$runtime_w" 'RUNTIME' "$presence_w" 'PRESENCE' > "$TTY_OUT"; ((transport_w>0)) && printf ' | %-*s' "$transport_w" 'TRANSPORT' > "$TTY_OUT"; ((peer_w>0)) && printf ' | %-*s' "$peer_w" 'REMOTE PEER' > "$TTY_OUT"; printf '%s\n' "$C_RESET" > "$TTY_OUT"
    printf '  %s%s%s\n' "$C_DIM" "$(ui_rule $'─')" "$C_RESET" > "$TTY_OUT"
    while IFS=$'\t' read -r name runtime presence transport peer; do [[ -n "$name" ]] || continue; printf '  %-*s | %s%-*s%s | %s%-*s%s' "$name_w" "$(fit_text "$name" "$name_w")" "$(semantic_state_color "$runtime")" "$runtime_w" "$(fit_text "$runtime" "$runtime_w")" "$C_RESET" "$(semantic_state_color "$presence")" "$presence_w" "$(fit_text "$presence" "$presence_w")" "$C_RESET" > "$TTY_OUT"; ((transport_w>0)) && printf ' | %-*s' "$transport_w" "$(fit_text "$transport" "$transport_w")" > "$TTY_OUT"; ((peer_w>0)) && printf ' | %-*s' "$peer_w" "$(fit_text "$peer" "$peer_w")" > "$TTY_OUT"; printf '\n' > "$TTY_OUT"; rows=$((rows+1)); done < <(python3 - "$snapshot" <<'PY_LIST_ROWS'
import json,sys
try:d=json.load(open(sys.argv[1],encoding='utf-8'))
except Exception:d={}
for r in d.get('connections',[]): print(r.get('name',''),r.get('runtime_status','UNKNOWN'),r.get('presence','UNKNOWN'),f"UDP {int(r.get('udp_port') or 0)}",r.get('remote_peer','-'),sep='\t')
PY_LIST_ROWS
)
    ((rows>0)) || ui_summary_row 'Connections' 'None' muted
    printf '\n  %s%d connections%s\n' "$C_DIM" "$rows" "$C_RESET" > "$TTY_OUT"
}

trap 'on_error "$LINENO" "$BASH_COMMAND" "$?"' ERR

if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" ]]; then
    log_line SESSION "version=${APP_VERSION} role=egress pid=$$ command=${*:-menu}"
    egress_main "$@"
fi

