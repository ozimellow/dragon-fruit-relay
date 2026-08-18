#!/usr/bin/env bash
# Dragon Fruit Relay Ingress - Production-style Debian route-based IKEv2/IPsec installer
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
    DFR_UNPRIVILEGED_MODE=yes
else
    DFR_UNPRIVILEGED_MODE=no
fi
readonly DFR_UNPRIVILEGED_MODE

[[ -r /etc/os-release ]] || early_exit "Cannot identify the operating system: /etc/os-release is missing or unreadable."

# shellcheck disable=SC1091
source /etc/os-release

if [[ "${ID:-}" != "debian" ]]; then
    early_exit "Unsupported operating system: ${PRETTY_NAME:-${ID:-unknown}}. Dragon Fruit Relay supports Debian only."
fi

readonly APP_NAME="Dragon Fruit Relay"
readonly APP_VERSION="v2.1.0"
readonly DFR_PRODUCT_ID="dragon-fruit-relay"
readonly DFR_PRODUCT_LINEAGE="standalone-dfr"

# Help/version are read-only metadata commands and should work even from a
# diagnostic shell/container where systemd is not PID 1.  All operational
# commands still require a real Debian systemd host below.
case "${1:-menu}" in
    version|-h|--help|help) : ;;
    *)
        if [[ ! -d /run/systemd/system ]]; then
            early_exit "systemd is not the active init system. Dragon Fruit Relay requires systemd."
        fi
        ;;
esac

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
readonly USER_CLI_COMMAND="/usr/local/bin/dragon-fruit-relay"
readonly TOKEN_FILE="${SECRETS_DIR}/pairing-token.txt"

# Dragon Fruit Relay managed layout. Each named client has an
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
readonly DEFAULT_XFRM_IF="dfr0001"
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

# Subscriber-facing status protocol for quota and subscription state.
readonly SUBSCRIPTION_PROTOCOL_VERSION="1"
readonly DEFAULT_SUBSCRIPTION_PORT="39892"
SUBSCRIPTION_PORT="$DEFAULT_SUBSCRIPTION_PORT"
readonly SUBSCRIPTION_RESPONSE="DRAGON-FRUIT-RELAY-SUBSCRIPTION/${SUBSCRIPTION_PROTOCOL_VERSION}"
readonly SUBSCRIPTION_STATE_DIR="${STATE_DIR}/subscription"
readonly SUBSCRIPTION_CACHE="${SUBSCRIPTION_STATE_DIR}/state.conf"
readonly SUBSCRIPTION_REFRESH="${LIB_DIR}/subscription-refresh"
readonly SUBSCRIPTION_CACHE_STALE_SECONDS="180"

# DFR_INGRESS_MANAGEMENT_FOUNDATION
# CONTROL/1 is reachable only through the encrypted XFRM path.  The egress
# publishes desired state; the ingress agent pulls, validates and reports it.
readonly CONTROL_PROTOCOL_VERSION="1"
readonly DEFAULT_CONTROL_PORT="39893"
CONTROL_PORT="$DEFAULT_CONTROL_PORT"
readonly CONTROL_STATE_DIR="${STATE_DIR}/control"
readonly CONTROL_AGENT="${LIB_DIR}/control-agent"
readonly CONTROL_SERVICE="dragon-fruit-relay-control-agent.service"
readonly CONTROL_TIMER="dragon-fruit-relay-control-agent.timer"
readonly CONTROL_SERVICE_FILE="${UNIT_DIR}/${CONTROL_SERVICE}"
readonly CONTROL_TIMER_FILE="${UNIT_DIR}/${CONTROL_TIMER}"
readonly CONTROL_TRANSACTION_DIR="${CONTROL_STATE_DIR}/config-transactions"
readonly CONTROL_LOCAL_STATE="${CONTROL_STATE_DIR}/state.conf"
readonly CONTROL_TX_HELPER="${LIB_DIR}/config-transaction"
readonly CONTROL_TX_WATCHDOG="${LIB_DIR}/config-rollback-watchdog"
readonly CONTROL_BOOT_RECOVERY="${LIB_DIR}/config-boot-recovery"
readonly CONTROL_BOOT_RECOVERY_SERVICE="dragon-fruit-relay-config-recovery.service"
readonly CONTROL_BOOT_RECOVERY_SERVICE_FILE="${UNIT_DIR}/${CONTROL_BOOT_RECOVERY_SERVICE}"
readonly UPDATE_STATE_DIR="${STATE_DIR}/updates"
readonly UPDATE_STAGING_DIR="${UPDATE_STATE_DIR}/staging"
readonly UPDATE_PREVIOUS_DIR="${UPDATE_STATE_DIR}/previous"
readonly UPDATE_CURRENT_STATE="${UPDATE_STATE_DIR}/state.conf"
readonly UPDATE_HELPER="${LIB_DIR}/managed-update"
readonly UPDATE_ROLLBACK_HELPER="${LIB_DIR}/update-rollback"
readonly UPDATE_WATCHDOG="${LIB_DIR}/update-rollback-watchdog"
readonly UPDATE_ROLLBACK_SERVICE="dragon-fruit-relay-update-rollback.service"
readonly UPDATE_ROLLBACK_SERVICE_FILE="${UNIT_DIR}/${UPDATE_ROLLBACK_SERVICE}"
readonly UPDATE_PUBLIC_KEY="${SECRETS_DIR}/ingress-update-ed25519.pub"
readonly USER_CONTROL="${LIB_DIR}/user-control"
readonly USER_SUDOERS="/etc/sudoers.d/dragon-fruit-relay-ingress"


TTY_IN="/dev/stdin"
TTY_OUT="/dev/stdout"
if { exec 3</dev/tty 4>/dev/tty; } 2>/dev/null; then
    TTY_IN="/dev/fd/3"
    TTY_OUT="/dev/fd/4"
else
    exec 3<&0 4>&1
fi

command -v flock >/dev/null 2>&1 || early_exit "Required command is missing: flock (util-linux)."
if [[ "$DFR_UNPRIVILEGED_MODE" == no ]]; then
    install -d -m 0700 "$LOG_DIR"
    if [[ "${DFR_INTERNAL_NO_MAIN_LOCK:-0}" != 1 && "${BASH_SOURCE[0]:-}" == "$0" ]]; then
        set +e
        flock -n -E 75 -o "$LOCK_FILE" env DFR_INTERNAL_NO_MAIN_LOCK=1 bash "$0" "$@"
        lock_rc=$?
        set -e
        ((lock_rc == 75)) && early_exit "Another Dragon Fruit Relay operation is already running."
        exit "$lock_rc"
    fi
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
fi

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


activate_common_services () 
{ 
    timeout 15s systemctl daemon-reload >> "$LOG_FILE" 2>&1 || die 'systemd did not reload the managed units.';
    start_xfrm_checked || die 'Cannot continue without the XFRM interface.';
    systemctl enable strongswan.service >> "$LOG_FILE" 2>&1 || true;
    start_unit_checked strongswan.service 'strongSwan service' || die 'Cannot continue without strongSwan.';
    load_strongswan_checked || die 'The generated strongSwan configuration is invalid.'
}

activate_ingress () 
{ 
    activate_common_services
}

attempt_tunnel_connection () 
{ 
    local transcript status sas pcap capture_pid capture_text outbound_packets=0 inbound_packets=0;
    info "Attempting IKE negotiation (${CONNECT_TIMEOUT_SECONDS}s maximum)...";
    pcap=$(mktemp /tmp/dragon-fruit-relay-ike.XXXXXX.pcap);
    if command -v tcpdump > /dev/null 2>&1; then
        local capture_filter;
        if [[ "$PORT_MODE" == 'custom' ]]; then
            capture_filter="host $PEER_PUBLIC_IP and udp port $NATT_PORT";
        else
            capture_filter="host $PEER_PUBLIC_IP and (udp port $IKE_PORT or udp port $NATT_PORT)";
        fi;
        timeout --signal=TERM "$((CONNECT_TIMEOUT_SECONDS + 4))s" tcpdump -U -ni "$WAN_IF" "$capture_filter" -w "$pcap" > /dev/null 2>&1 & capture_pid=$!;
        sleep 1;
    else
        capture_pid='';
    fi;
    set +e;
    transcript=$(timeout --signal=TERM "${CONNECT_TIMEOUT_SECONDS}s" swanctl --initiate --child tunnel 2>&1);
    status=$?;
    set -e;
    if [[ -n "$capture_pid" ]]; then
        kill "$capture_pid" > /dev/null 2>&1 || true;
        wait "$capture_pid" 2> /dev/null || true;
        capture_text=$(tcpdump -nn -r "$pcap" 2> /dev/null || true);
        outbound_packets=$(awk -v peer="$PEER_PUBLIC_IP." 'index($0, " > " peer) {n++} END {print n+0}' <<< "$capture_text");
        inbound_packets=$(awk -v peer="$PEER_PUBLIC_IP." 'index($0, "IP " peer) {n++} END {print n+0}' <<< "$capture_text");
        { 
            printf 'IKE packet capture: outbound=%s inbound=%s\n' "$outbound_packets" "$inbound_packets";
            printf '%s\n' "$capture_text"
        } >> "$LOG_FILE";
    fi;
    rm -f "$pcap";
    printf '%s\n' "$transcript" >> "$LOG_FILE";
    sas=$(swanctl --list-sas 2> /dev/null || true);
    if grep -q ESTABLISHED <<< "$sas" && grep -q INSTALLED <<< "$sas"; then
        success 'IKE and CHILD SAs are established.';
        return 0;
    fi;
    ((status == 124 || status == 143)) && warn 'IKE negotiation timed out.' || warn "IKE negotiation failed with status ${status}.";
    show_ike_failure_details "$transcript" "$outbound_packets" "$inbound_packets";
    return 1
}

record_unit_state_initial ()
{
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
    printf '%s_UNIT_EXISTED=%s\n' "$prefix" "$existed" >> "$PACKAGE_STATE_FILE"
    printf '%s_UNIT_WAS_ACTIVE=%s\n' "$prefix" "$active" >> "$PACKAGE_STATE_FILE"
    printf '%s_UNIT_WAS_ENABLED=%s\n' "$prefix" "$enabled" >> "$PACKAGE_STATE_FILE"
}

backup_common_paths ()
{
    record_unit_state_initial strongswan.service STRONGSWAN
    backup_original "$SWANCTL_FILE"
    backup_original "$STRONGSWAN_ROUTE_FILE"
    backup_original "$STRONGSWAN_OVERRIDE_FILE"
    backup_original "$SYSTEMD_DIR/dragon-fruit-relay-xfrm.service"
}

backup_ingress_paths ()
{
    backup_common_paths
    backup_original "$INGRESS_SWANCTL_CANONICAL"
    backup_original "$SYSTEMD_DIR/dragon-fruit-relay-routing.service"
    backup_original "$SYSTEMD_DIR/dragon-fruit-relay-dns.service"
    backup_original "$SYSTEMD_DIR/dragon-fruit-relay-healthcheck.service"
    backup_original "$SYSTEMD_DIR/dragon-fruit-relay-healthcheck.timer"
    backup_original /etc/resolv.conf
    backup_original "$DHCPCD_CONFIG_FILE"
    backup_original /etc/nsswitch.conf
    backup_original /etc/systemd/resolved.conf
    backup_original /etc/systemd/resolved.conf.d
    backup_original /etc/systemd/system/systemd-resolved.service.d
    backup_original "$SYSCTL_FILE"
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

ui_terminal_columns ()
{
    local cols
    cols=$(tput cols 2>/dev/null || printf '80')
    [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
    printf '%s' "$cols"
}

ui_content_width ()
{
    local cols width
    cols=$(ui_terminal_columns); width=$((cols-4)); ((width < 36)) && width=36
    printf '%s' "$width"
}

ui_rule ()
{
    local char="${1:--}" width="${2:-}" rule
    [[ "$width" =~ ^[0-9]+$ ]] || width=$(ui_content_width)
    printf -v rule '%*s' "$width" ''; rule=${rule// /$char}; printf '%s' "$rule"
}

dfr_ui_header ()
{
    local title="${1:-CLIENT}" width
    width=$(ui_content_width)
    printf '\n  %s%sDRAGON FRUIT RELAY %s%s  %s|%s  %s%s%s\n' "$C_BOLD" "$C_CYAN" "$APP_VERSION" "$C_RESET" "$C_DIM" "$C_RESET" "$C_BOLD" "$title" "$C_RESET" > "$TTY_OUT"
    printf '  %s%s%s\n' "$C_DIM" "$(ui_rule $'\u2500' "$width")" "$C_RESET" > "$TTY_OUT"
}


semantic_state_color ()
{
    local state="${1:--}"
    state=${state^^}
    case "$state" in
        ONLINE|OPERATIONAL|ACTIVE|AVAILABLE|ENABLED|'ENABLED-RUNTIME'|ESTABLISHED|INSTALLED|LATEST|SYNCED|COMPATIBLE|HEALTHY|CURRENT|ENROLLED|RUNNING|COMPLETE|SUCCESS|VERIFIED|CONNECTED|RESTORED|PUBLISHED|PRESENT|VALID|APPLIED|COMMITTED|CONVERGED|'ROLLBACK READY'|PASS|OK|ARMED|SUCCEEDED|LISTENING|REACHABLE)
            printf '%s' "$C_GREEN" ;;
        READY|AUTO|AUTOMATIC|MANUAL|PINNED|STABLE|STAGED|TARGET|CANARY|MEMBER|CHECKING|UPDATING|UPDATED|INSTALLING|MIGRATING|RECONCILING|STARTING|ACTIVATING|STATIC|GENERATED|INDIRECT|TRANSIENT|LINKED|'LINKED-RUNTIME'|ADVISORY|LIMITED|UNLIMITED|'ENDPOINT MIGRATION'|'CONFIG VERIFIED'|DOWNLOADING|VERIFYING|APPLYING|PREPARING|PREPARED|RELOADING|ALIAS)
            printf '%s' "$C_CYAN" ;;
        STALE|DEGRADED|STOPPED|DISCONNECTED|SUSPENDED|PAUSED|WAITING|PENDING|QUEUED|SCHEDULED|DEACTIVATING|WARNING|'HEALTHY WITH WARNINGS'|'UPDATE REQUIRED'|'UPGRADE REQUIRED'|UNAVAILABLE|RETRYING|DEFERRED|'IN PROGRESS'|ATTENTION|'TEMPORARILY EXCLUDED'|'ROLLED BACK'|'ROLLING BACK'|'PASS WITH WARNINGS'|CANCELLED|MAINTENANCE|'AUTO-RESTART'|ROLLED_BACK|TEMPORARY)
            printf '%s' "$C_YELLOW" ;;
        OFFLINE|FAILED|MISSING|ERROR|EXPIRED|REVOKED|BLOCKED|INCOMPATIBLE|UNHEALTHY|CRITICAL|MASKED|'MASKED-RUNTIME'|'ROLLBACK FAILED'|'NOT FOUND'|'QUOTA EXHAUSTED'|'NOT COMPATIBLE'|UNREACHABLE|FAIL|DOWN|'NOT-FOUND')
            printf '%s' "$C_RED" ;;
        DISABLED|INACTIVE|'NEVER SEEN'|'NOT ENROLLED'|'NOT MEMBER'|UNKNOWN|EMPTY|IDLE|NONE|'NONE YET'|NEVER|'NOT CONFIGURED'|'NO ACTIVE ALERTS'|'NO ACTIVE WORK'|'NO BACKUPS'|'NOT REPORTED'|'N/A'|-|'')
            printf '%s' "$C_DIM" ;;
        *)
            printf '%s' "$C_WHITE" ;;
    esac
}

semantic_colorize_segment ()
{
    local remaining="${1:-}" upper candidate prefix_upper before after token color
    local best_candidate='' best_idx=-1 best_len=0 idx candidate_len
    local zero_count=no
    [[ "$remaining" =~ ^0([[:space:]]|$) ]] && zero_count=yes
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
                best_candidate="$candidate"; best_idx=$idx; best_len=$candidate_len
            fi
        done
        if ((best_idx < 0)); then printf '%s' "$remaining"; break; fi
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

semantic_colorize_line ()
{
    local rest="${1:-}" segment first=yes
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

ui_summary_begin ()
{
    local title="$1" state="${2:-}" width
    width=$(ui_content_width)
    printf '\n  %s%s%s%s' "$C_BOLD" "$C_MAGENTA" "$title" "$C_RESET" > "$TTY_OUT"
    if [[ -n "$state" ]]; then
        printf '  %s[%s%s%s]%s' "$C_DIM" "$(semantic_state_color "$state")" "$state" "$C_DIM" "$C_RESET" > "$TTY_OUT"
    fi
    printf '\n  %s%s%s\n' "$C_DIM" "$(ui_rule $'─' "$width")" "$C_RESET" > "$TTY_OUT"
}

ui_summary_render_value ()
{
    local value="${1:--}" kind="${2:-auto}" rest segment first=yes
    value=${value// | /·}; rest="$value"
    while [[ "$rest" == *'·'* ]]; do
        segment=${rest%%'·'*}
        segment="${segment#"${segment%%[![:space:]]*}"}"; segment="${segment%"${segment##*[![:space:]]}"}"
        [[ "$first" == yes ]] || printf ' · '
        case "$kind" in
            muted) printf '%s%s%s' "$C_DIM" "$segment" "$C_RESET" ;;
            accent) printf '%s%s%s' "$C_CYAN" "$segment" "$C_RESET" ;;
            count)
                if [[ "$segment" =~ ^0([[:space:]]|$) || "$segment" == '0B' || "$segment" == '0 B' ]]; then printf '%s%s%s' "$C_DIM" "$segment" "$C_RESET"; else printf '%s' "$segment"; fi ;;
            identity|plain|info) printf '%s' "$segment" ;;
            *) semantic_colorize_segment "$segment" ;;
        esac
        first=no; rest=${rest#*'·'}
    done
    rest="${rest#"${rest%%[![:space:]]*}"}"; rest="${rest%"${rest##*[![:space:]]}"}"
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
    width=$(ui_content_width); label_width=22; ((width < 72)) && label_width=18
    value_width=$((width-label_width-1)); ((value_width < 18)) && value_width=18
    value=${value// | /·}
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$first" == yes ]]; then
            printf '  %s%-*s%s ' "$C_DIM" "$label_width" "$label" "$C_RESET" > "$TTY_OUT"; first=no
        else
            printf '  %-*s ' "$label_width" '' > "$TTY_OUT"
        fi
        ui_summary_render_value "$line" "$kind" > "$TTY_OUT"; printf '\n' > "$TTY_OUT"
    done < <(printf '%s\n' "$value" | fold -s -w "$value_width")
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

ui_navigation_footer ()
{
    ui_menu_item G 'Navigate' navigation
    ui_menu_item B 'Back' back
    ui_menu_item Q 'Exit' destructive
}


check_service_for_dashboard () 
{ 
    local unit="$1" label="$2" critical="${3:-yes}" state;
    state=$(unit_state "$unit");
    if [[ "$state" == 'active' ]]; then
        print_check pass "$label" "$state";
        return 0;
    fi;
    if [[ "$critical" == 'yes' ]]; then
        print_check fail "$label" "${state:-unknown}";
        return 1;
    fi;
    print_check warn "$label" "${state:-unknown}";
    return 2
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

clean_abandoned_install_before_setup ()
{
    [[ ! -f "$CONFIG_FILE" ]] || return 0

    systemctl disable --now \
        dragon-fruit-relay-healthcheck.timer \
        dragon-fruit-relay-healthcheck.service \
        dragon-fruit-relay-dns.service \
        dragon-fruit-relay-routing.service \
        "$CONTROL_TIMER" \
        "$CONTROL_SERVICE" \
        dragon-fruit-relay-xfrm.service >/dev/null 2>&1 || true
    timeout 12s swanctl --terminate --ike dragonfruit_relay >/dev/null 2>&1 || true
    systemctl stop strongswan.service >/dev/null 2>&1 || true

    remove_all_dragonfruit_network_rules || true
    cleanup_dragonfruit_managed_xfrm_interfaces || die 'One or more managed XFRM interfaces could not be removed safely.'

    # A failed standalone DFR setup may already have captured host state. Restore
    # it before deleting the partial DFR tree so retrying installation is safe.
    if [[ -f "$MANIFEST_FILE" ]]; then
        restore_package_state || true
        restore_originals || true
        systemctl daemon-reload >/dev/null 2>&1 || true
        restore_unit_state strongswan.service STRONGSWAN || true
        reload_dhcpcd_configuration "${WAN_IF:-}" || true
    fi

    local stale target
    for stale in \
        "$SWANCTL_FILE" \
        "$INGRESS_SWANCTL_CANONICAL" \
        "$STRONGSWAN_ROUTE_FILE" \
        "$STRONGSWAN_OVERRIDE_FILE" \
        "$SYSCTL_FILE" \
        "$SYSTEMD_DIR/dragon-fruit-relay-xfrm.service" \
        "$SYSTEMD_DIR/dragon-fruit-relay-routing.service" \
        "$SYSTEMD_DIR/dragon-fruit-relay-dns.service" \
        "$SYSTEMD_DIR/dragon-fruit-relay-healthcheck.service" \
        "$SYSTEMD_DIR/dragon-fruit-relay-healthcheck.timer" \
        "$CONTROL_SERVICE_FILE" \
        "$CONTROL_TIMER_FILE"
    do
        if [[ -L "$stale" ]]; then
            target=$(readlink -f "$stale" 2>/dev/null || true)
            [[ "$target" == "$CONFIG_DIR"/* ]] && rm -f -- "$stale"
        fi
    done

    [[ -L /etc/resolv.conf && "$(readlink -f /etc/resolv.conf 2>/dev/null || true)" == "$RESOLVER_MANAGED_FILE" ]] && rm -f /etc/resolv.conf || true
    if [[ -e "$INGRESS_SWANCTL_MARKER" ]]; then
        rm -rf -- "$INGRESS_SWANCTL_DIR"
        rmdir "$SWANCTL_CLIENT_ROOT" 2>/dev/null || true
    fi

    rm -rf -- "$CONFIG_DIR" "$STATE_DIR"
    rm -f "$SYSTEMD_DIR"/dragon-fruit-relay-*.service "$SYSTEMD_DIR"/dragon-fruit-relay-*.timer
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed >/dev/null 2>&1 || true
}

clear_screen () 
{ 
    [[ -t 4 ]] && printf '\033[2J\033[H' > "$TTY_OUT" || true
}

config_summary ()
{
    load_config;

    if [[ "${ROLE:-}" == ingress ]]; then

        printf '    %-22s %s\n' \
            'Connection' \
            "${PROFILE_NAME:-paired-egress}" > "$TTY_OUT";

        printf '    %-22s %s%s%s\n' \
            'Server endpoint' \
            "$C_CYAN" "$PEER_PUBLIC_IP" "$C_RESET" > "$TTY_OUT";

        printf '    %-22s %s\n' \
            'Transport' \
            "$(transport_description)" > "$TTY_OUT";

        printf '    %-22s %s -> %s\n' \
            'Tunnel' \
            "$XFRM_LOCAL_IP" \
            "$XFRM_PEER_IP" > "$TTY_OUT";

        return 0;
    fi;


    # Retain a generic fallback if this shared helper is ever
    # called outside ingress mode.
    printf '    %-22s %s\n' 'Role' "${ROLE:-unknown}" > "$TTY_OUT";
    printf '    %-22s %s\n' 'Transport' "$(transport_description)" > "$TTY_OUT";

    return 0;
}

configure_dhcpcd_resolver_hook () 
{ 
    command -v dhcpcd > /dev/null 2>&1 || return 0;
    backup_original "$DHCPCD_CONFIG_FILE";
    if [[ ! -e "$DHCPCD_CONFIG_FILE" && ! -L "$DHCPCD_CONFIG_FILE" ]]; then
        install -m 0644 /dev/null "$DHCPCD_CONFIG_FILE";
    fi;
    if [[ ! -f "$DHCPCD_CONFIG_FILE" ]]; then
        error "Cannot configure dhcpcd because ${DHCPCD_CONFIG_FILE} is not a regular file.";
        return 1;
    fi;
    if ! dhcpcd_resolv_hook_disabled; then
        cat >> "$DHCPCD_CONFIG_FILE" <<'EOF_DHCPCD_DNS'

# Managed by Dragon Fruit Relay.
# Dragon Fruit Relay owns /etc/resolv.conf while ingress DNS is enabled.
nohook resolv.conf
EOF_DHCPCD_DNS

        info 'Configured dhcpcd to leave /etc/resolv.conf under Dragon Fruit Relay control.';
    fi
    reload_dhcpcd_configuration "$WAN_IF";
    return 0
}

configured_ingress () 
{ 
    [[ -f "$CONFIG_FILE" && ! -f "$HOST_CONFIG_FILE" ]] || return 1;
    ( set +u;
    source "$CONFIG_FILE";
    [[ "${ROLE:-}" == ingress ]] )
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

dhcpcd_resolv_hook_disabled () 
{ 
    [[ -r "$DHCPCD_CONFIG_FILE" ]] || return 1;
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

diagnostics_logs () 
{ 
    load_config;
    clear_screen;
    dfr_ui_header 'WARNINGS & ERRORS';
    section_title 'Recent strongSwan warnings and errors';
    journalctl -u strongswan.service --since '-30 minutes' --no-pager -o short-iso 2> /dev/null | grep -Ei 'failed|error|AUTH|proposal|shared key|retransmit|unreachable|timeout' | tail -n 80 > "$TTY_OUT" || true;
    section_title 'Recent managed-service warnings and errors';
    journalctl -u dragon-fruit-relay-xfrm.service -u dragon-fruit-relay-routing.service -u dragon-fruit-relay-dns.service -u dragon-fruit-relay-healthcheck.service --since '-30 minutes' -p warning --no-pager -o short-iso 2> /dev/null | tail -n 80 > "$TTY_OUT" || true;
    section_title 'Current command invocation';
    awk '/\[SESSION\]/{buffer=""} {buffer=buffer $0 ORS} END{printf "%s", buffer}' "$LOG_FILE" 2> /dev/null | grep -E '\[(ERROR|WARN|SESSION)\]' | tail -n 60 > "$TTY_OUT" || true
}

diagnostics_overview () 
{ 
    if [[ ! -f "$CONFIG_FILE" ]]; then
        diagnostics_preflight;
        return 0;
    fi;
    clear_screen;
    dfr_ui_header 'CLIENT STATUS';
    load_config;
    section_title 'Health summary';
    config_summary;
    evaluate_live_status;
    section_title 'Live state';
    printf '  %s%s%s%s  ' "$LIVE_COLOR" "$C_BOLD" "$LIVE_STATUS" "$C_RESET" > "$TTY_OUT";
    semantic_colorize_line "$LIVE_REASON" > "$TTY_OUT"; printf '\n' > "$TTY_OUT";
    local core_failures=0 data_failures=0 warnings=0 sas ike_ready=no;
    section_title 'Core tunnel';
    check_service_for_dashboard dragon-fruit-relay-xfrm.service 'XFRM interface service' || core_failures=$((core_failures + 1));
    check_service_for_dashboard strongswan.service 'strongSwan' || core_failures=$((core_failures + 1));
    sas=$(safe_sas);
    if grep -q ESTABLISHED <<< "$sas" && grep -q INSTALLED <<< "$sas"; then
        ike_ready=yes;
        print_check pass 'IKE / CHILD SA' 'ESTABLISHED / INSTALLED';
        if ping -I "$XFRM_IF" -c 1 -W 2 "$XFRM_PEER_IP" > /dev/null 2>&1; then
            print_check pass 'Tunnel peer' "$XFRM_PEER_IP responds";
        else
            print_check fail 'Tunnel peer' 'unreachable';
            core_failures=$((core_failures + 1));
        fi;
    else
        print_check fail 'IKE / CHILD SA' 'No encrypted session exists';
        core_failures=$((core_failures + 1));
    fi;
    if [[ "$ROLE" == ingress ]]; then
        section_title 'Client data path';
        if [[ "$ike_ready" != yes ]]; then
            print_check info 'Policy routing' 'PENDING until the tunnel establishes';
            print_check info 'Managed resolver' 'PENDING; host resolver remains available';
            print_check info 'Health monitor' 'PENDING';
        else
            if systemctl is-active --quiet dragon-fruit-relay-routing.service && route_uses_interface 9.9.9.9 "$XFRM_LOCAL_IP" "$XFRM_IF"; then
                print_check pass 'Policy routing' "active through $XFRM_IF / table $ROUTE_TABLE";
            else
                print_check fail 'Policy routing' 'service or relay-source route is inactive';
                data_failures=$((data_failures + 1));
            fi;
            if resolver_runtime_ok; then
                print_check pass 'Managed resolver runtime' "$DNS_PRIMARY -> $DNS_SECONDARY -> $DNS_FALLBACK";
            else
                print_check fail 'Managed resolver runtime' '/etc/resolv.conf is not using the generated resolver file';
                data_failures=$((data_failures + 1));
            fi;
            if systemctl is-active --quiet dragon-fruit-relay-dns.service; then
                print_check pass 'Resolver apply unit' 'active';
            else
                print_check warn 'Resolver apply unit' "$(unit_state dragon-fruit-relay-dns.service); Repair reconstructs it";
                warnings=$((warnings + 1));
            fi;
            if health_timer_is_armed dragon-fruit-relay-healthcheck.timer; then
                print_check pass 'Health monitor' "active and armed; next $(health_timer_next_elapse dragon-fruit-relay-healthcheck.timer)";
            else
                print_check warn 'Health monitor' "$(unit_state dragon-fruit-relay-healthcheck.timer); no verified next execution; automatic recovery needs re-arming";
                warnings=$((warnings + 1));
            fi;
            print_route_check 'Primary DNS path' "$DNS_PRIMARY" '' "$XFRM_IF";
            print_route_check 'Secondary DNS path' "$DNS_SECONDARY" '' "$XFRM_IF";
        fi;
    fi;
    section_title 'Result';
    if ((core_failures > 0)); then
        printf '  ' > "$TTY_OUT"; semantic_colorize_segment 'DISCONNECTED / UNHEALTHY' > "$TTY_OUT"; printf '  %d tunnel failure(s).\n' "$core_failures" > "$TTY_OUT";
    else
        if ((data_failures > 0)); then
            printf '  %s%sDEGRADED%s  Tunnel is connected; %d managed data-path issue(s) require Repair.\n' "$C_BOLD" "$C_YELLOW" "$C_RESET" "$data_failures" > "$TTY_OUT";
        else
            if ((warnings > 0)); then
                printf '  %s%sHEALTHY WITH WARNINGS%s  Tunnel and traffic path are operational; %d maintenance warning(s).\n' "$C_BOLD" "$C_YELLOW" "$C_RESET" "$warnings" > "$TTY_OUT";
            else
                printf '  %s%sHEALTHY%s  Tunnel, routing, resolver and monitor are operational.\n' "$C_BOLD" "$C_GREEN" "$C_RESET" > "$TTY_OUT";
            fi;
        fi;
    fi
}

diagnostics_ports () 
{ 
    load_config;
    clear_screen;
    dfr_ui_header 'SERVICES & TRANSPORT';
    section_title 'Services and network';
    service_row dragon-fruit-relay-xfrm.service 'XFRM interface';
    service_row strongswan.service 'strongSwan';
    if [[ "$ROLE" == ingress ]]; then
        service_row dragon-fruit-relay-routing.service 'Selective policy routing';
        service_row dragon-fruit-relay-dns.service 'Resolver apply unit';
        service_row dragon-fruit-relay-healthcheck.timer 'Health monitor';
        resolver_runtime_ok && print_check pass 'Resolver runtime' "$RESOLVER_MANAGED_FILE" || print_check fail 'Resolver runtime' '/etc/resolv.conf is not linked to the managed resolver';
    fi;
    section_title 'Transport and path';
    printf '  %-24s %s\n' 'Configured transport' "$(transport_description)" > "$TTY_OUT";
    if [[ "$ROLE" == ingress ]]; then
        if [[ "$PORT_MODE" == custom ]]; then
            printf '  %-24s %s%s:%s%s\n' 'Server endpoint' "$C_CYAN" "$PEER_PUBLIC_IP" "$NATT_PORT" "$C_RESET" > "$TTY_OUT";
        else
            printf '  %-24s %s%s:%s%s\n' 'Server endpoint' "$C_CYAN" "$PEER_PUBLIC_IP" "$IKE_PORT" "$C_RESET" > "$TTY_OUT";
        fi;
        print_route_check 'Endpoint path' "$PEER_PUBLIC_IP" '' "$WAN_IF";
        local direct_ip='' tunnel_ip='' sas;
        direct_ip=$(detect_public_ipv4 "$WAN_IF" || true);
        if [[ -n "$direct_ip" ]]; then
            printf '  %-24s %s%s%s (multi-source consensus)\n' 'Direct-path public IP' "$C_CYAN" "$direct_ip" "$C_RESET" > "$TTY_OUT";
        else
            printf '  %-24s ' 'Direct-path public IP' > "$TTY_OUT"; semantic_colorize_line 'unavailable: route-bound lookup services did not agree' > "$TTY_OUT"; printf '\n' > "$TTY_OUT";
        fi;
        sas=$(safe_sas);
        if grep -q ESTABLISHED <<< "$sas" && grep -q INSTALLED <<< "$sas"; then
            tunnel_ip=$(detect_public_ipv4 "$XFRM_LOCAL_IP" || true);
            if [[ -n "$tunnel_ip" ]]; then
                printf '  %-24s %s%s%s (multi-source consensus)\n' 'Tunnel public IP' "$C_CYAN" "$tunnel_ip" "$C_RESET" > "$TTY_OUT";
            else
                printf '  %-24s ' 'Tunnel public IP' > "$TTY_OUT"; semantic_colorize_line 'unavailable: tunnel-bound lookup services did not agree' > "$TTY_OUT"; printf '\n' > "$TTY_OUT";
            fi;
        else
            print_check info 'Tunnel public IP' 'skipped until IKE is established';
        fi;
    fi
}

diagnostics_preflight ()
{
    clear_screen
    dfr_ui_header 'CLIENT INSTALLATION'
    local iface gateway public_ip route_default state='READY'
    iface=$(detect_default_interface || true); gateway=$(detect_default_gateway || true); public_ip=$(detect_public_ipv4 || true); route_default=$(ip -4 route show default 2>/dev/null | head -n 1 || true)
    [[ -n "$iface" ]] || state='ATTENTION'
    ui_summary_begin 'Preflight' "$state"
    ui_summary_row 'Platform' "${PRETTY_NAME:-Debian} with systemd"
    ui_summary_row 'Internet interface' "${iface:-Not detected}" identity
    ui_summary_row 'Default gateway' "${gateway:-Not detected}" accent
    ui_summary_row 'Observed public IPv4' "${public_ip:-Unavailable · non-blocking}" "$([[ -n "$public_ip" ]] && printf accent || printf muted)"
    ui_summary_row 'Default route' "${route_default:-Missing}" identity
    section_title 'Managed XFRM interfaces'
    xfrm_preflight_rows
    section_title 'Enrollment readiness'
    if [[ -n "$iface" && -n "$gateway" ]]; then
        print_check pass 'Client host' 'Ready for a DFR1 enrollment token.'
    else
        print_check warn 'Client host' 'Network preflight needs attention before enrollment.'
    fi
    print_check info 'Enrollment source' 'Create a connection on the Egress Hub and paste its one-time DFR1 token.'
}

diagnostics_routing () 
{ 
    load_config;
    clear_screen;
    dfr_ui_header 'ROUTING & DNS';
    section_title 'Routing and DNS paths';
    if [[ "$ROLE" != ingress ]]; then
        print_check info 'Selective policy routing' 'Configured on the Client only.';
        printf '  %-28s %s\n' 'Default Internet path' "$(route_summary 9.9.9.9)" > "$TTY_OUT";
        return 0;
    fi;
    local sas;
    sas=$(safe_sas);
    section_title 'Always-valid paths';
    print_route_check 'Direct Internet' 9.9.9.9 '' "$WAN_IF";
    print_route_check 'IKE endpoint exclusion' "$PEER_PUBLIC_IP" '' "$WAN_IF";
    print_route_check 'Local DNS fallback' "$DNS_FALLBACK" '' "$WAN_IF";
    if ! grep -q ESTABLISHED <<< "$sas" || ! grep -q INSTALLED <<< "$sas"; then
        section_title 'Relay paths';
        print_check info 'Policy table' 'PENDING - not installed until IKE and CHILD SAs establish';
        print_check info 'Public DNS routes' 'PENDING - current resolver remains on the local path';
        print_check info 'Next action' 'Run Start / reconnect to see the exact IKE failure.';
        return 0;
    fi;
    section_title 'Active relay paths';
    print_route_check 'Relay Server' 9.9.9.9 "$XFRM_LOCAL_IP" "$XFRM_IF";
    print_route_check 'Primary DNS' "$DNS_PRIMARY" '' "$XFRM_IF";
    print_route_check 'Secondary DNS' "$DNS_SECONDARY" '' "$XFRM_IF";
    section_title 'Installed policy rules';
    policy_rule_matches "$RULE_DNS_PRIMARY" to "$DNS_PRIMARY" "$ROUTE_TABLE" && print_check pass 'Primary DNS rule' "$(managed_rule_line "$RULE_DNS_PRIMARY")" || print_check fail 'Primary DNS rule' "expected destination $DNS_PRIMARY -> table $ROUTE_TABLE";
    policy_rule_matches "$RULE_DNS_SECONDARY" to "$DNS_SECONDARY" "$ROUTE_TABLE" && print_check pass 'Secondary DNS rule' "$(managed_rule_line "$RULE_DNS_SECONDARY")" || print_check fail 'Secondary DNS rule' "expected destination $DNS_SECONDARY -> table $ROUTE_TABLE";
    policy_rule_matches "$RULE_TUNNEL_SOURCE" from "$XFRM_LOCAL_IP" "$ROUTE_TABLE" && print_check pass 'Relay source rule' "$(managed_rule_line "$RULE_TUNNEL_SOURCE")" || print_check fail 'Relay source rule' "expected source $XFRM_LOCAL_IP -> table $ROUTE_TABLE";
    local table_line;
    table_line=$(ip -4 route show table "$ROUTE_TABLE" 2> /dev/null | head -n 1 || true);
    [[ "$table_line" == default*"dev $XFRM_IF"* ]] && print_check pass "Routing table $ROUTE_TABLE" "$table_line" || print_check fail "Routing table $ROUTE_TABLE" "${table_line:-default route missing}";
    section_title 'Resolver order';
    grep -E '^(options|nameserver)' /etc/resolv.conf 2> /dev/null | sed 's/^/  /' > "$TTY_OUT" || print_check warn '/etc/resolv.conf' 'unavailable'
}

diagnostics_tunnel () 
{ 
    load_config;
    clear_screen;
    dfr_ui_header 'TUNNEL & TRAFFIC';
    section_title 'Tunnel and traffic';
    config_summary;
    section_title 'Services';
    service_row dragon-fruit-relay-xfrm.service 'XFRM interface';
    service_row strongswan.service 'strongSwan';
    section_title 'Session state';
    local sas;
    sas=$(safe_sas);
    if grep -q 'ESTABLISHED' <<< "$sas"; then
        print_check pass 'IKE session' 'ESTABLISHED';
    else
        print_check fail 'IKE session' 'not established';
    fi;
    if grep -q 'INSTALLED' <<< "$sas"; then
        print_check pass 'Encrypted channel' 'INSTALLED';
    else
        print_check fail 'Encrypted channel' 'not installed';
    fi;
    printf '  %-30s %s\n' 'Interface counters' "$(xfrm_counter_summary "$XFRM_IF")" > "$TTY_OUT";
    if ping -I "$XFRM_IF" -c 2 -W 3 "$XFRM_PEER_IP" > /dev/null 2>&1; then
        print_check pass 'Peer reachability' "$XFRM_PEER_IP responds";
    else
        print_check fail 'Peer reachability' "$XFRM_PEER_IP did not respond";
    fi;
    section_title 'Session details';
    if [[ -n "$sas" ]]; then
        local ike_line child_line in_line out_line;
        ike_line=$(grep -m1 'ESTABLISHED' <<< "$sas" || true);
        child_line=$(grep -m1 'INSTALLED' <<< "$sas" || true);
        in_line=$(grep -m1 -E '^[[:space:]]+in[[:space:]]' <<< "$sas" || true);
        out_line=$(grep -m1 -E '^[[:space:]]+out[[:space:]]' <<< "$sas" || true);
        if [[ -n "$ike_line" ]]; then printf '  %-7s ' 'IKE' > "$TTY_OUT"; semantic_colorize_line "${ike_line#  }" > "$TTY_OUT"; printf '\n' > "$TTY_OUT"; fi
        if [[ -n "$child_line" ]]; then printf '  %-7s ' 'CHILD' > "$TTY_OUT"; semantic_colorize_line "${child_line#  }" > "$TTY_OUT"; printf '\n' > "$TTY_OUT"; fi
        [[ -n "$in_line" ]] && printf '  %-7s %s\n' 'IN' "$(xargs <<< "$in_line")" > "$TTY_OUT";
        [[ -n "$out_line" ]] && printf '  %-7s %s\n' 'OUT' "$(xargs <<< "$out_line")" > "$TTY_OUT";
    else
        print_check fail 'Security associations' 'none loaded';
    fi
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
    local iface="$1" details id_token id_value suffix expected_id
    [[ "$iface" =~ ^dfr([0-9]{4})$ ]] || return 1
    suffix="${BASH_REMATCH[1]}"
    ip link show dev "$iface" >/dev/null 2>&1 || return 1
    details=$(ip -d link show dev "$iface" 2>/dev/null || true)
    grep -q 'xfrm' <<<"$details" || return 1
    id_token=$(sed -nE 's/.*if_id[[:space:]]+([^[:space:]]+).*/\1/p' <<<"$details" | head -n 1)
    [[ -n "$id_token" ]] || return 1
    if [[ "$id_token" =~ ^0x[0-9a-fA-F]+$ ]]; then id_value=$((id_token));
    elif [[ "$id_token" =~ ^[0-9]+$ ]]; then id_value=$((10#$id_token));
    else return 1; fi
    expected_id=$((PROFILE_XFRM_ID_BASE + 10#$suffix))
    [[ "$id_value" -eq "$expected_id" ]]
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
    case "$link" in "$CONFIG_DIR"/*) return 0 ;; *) return 1 ;; esac
}

enable_managed_unit_link () 
{ 
    # DFR_STRICT_LOCAL_ASSIGNMENT
    # Under `set -u`, do not reference a variable in the same `local`
    # declaration that assigns it; expansion happens before assignment.
    local unit target source;
    unit="$1";
    target="$2";
    source="${UNIT_DIR}/${unit}";
    [[ -f "$source" ]] || return 1;
    install -d -m 0755 "${SYSTEMD_DIR}/${target}.wants";
    ln -sfn "$source" "${SYSTEMD_DIR}/${target}.wants/${unit}"
}

ensure_ingress_runtime_files ()
{
    load_config
    [[ "$ROLE" == ingress ]] || return 0
    info 'Rebuilding managed Client service and resolver definitions...'
    ensure_managed_layout
    write_managed_readme
    install_self_copy
    write_common_xfrm_files
    write_strongswan_common_files
    write_swanctl_ingress
    write_ingress_routing_files
    write_ingress_dns_files no
    write_ingress_healthcheck_files
    write_ingress_user_access_files
    [[ "${MANAGED_CONTROL:-no}" == yes ]] && write_ingress_management_files
    timeout 15s systemctl daemon-reload >>"$LOG_FILE" 2>&1 || { error 'systemd did not reload the managed Client units within 15 seconds.'; return 1; }
}

ensure_managed_layout () 
{ 
    install -d -m 0751 "$CONFIG_DIR";
    install -d -m 0750 "$LIB_DIR" "$UNIT_DIR" "$SYSCTL_DIR";
    install -d -m 0751 "$RESOLVER_DIR";
    install -d -m 0700 "$SECRETS_DIR";
    install -d -m 0700 "$STATE_DIR" "$BACKUP_DIR" "$SUBSCRIPTION_STATE_DIR" \
        "$CONTROL_STATE_DIR" "$CONTROL_TRANSACTION_DIR" "$UPDATE_STATE_DIR" \
        "$UPDATE_STAGING_DIR" "$UPDATE_PREVIOUS_DIR"
}

ensure_tunnel_network_available () 
{ 
    local cidr="$1";
    local conflicts;
    if conflicts=$(tunnel_network_conflicts "$cidr" 2> /dev/null); then
        error "Tunnel network ${cidr} overlaps existing network state:";
        printf '%s\n' "$conflicts" > "$TTY_OUT";
        die "Choose a different tunnel /30 network.";
    fi
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

evaluate_live_status ()
{ 
    set_live_status 'NOT CONFIGURED' 'No relay configuration is installed.';
    [[ -f "$CONFIG_FILE" ]] || return 0;
    load_config;
    local sas degraded=0;
    systemctl is-active --quiet dragon-fruit-relay-xfrm.service || { 
        set_live_status STOPPED 'XFRM service is not active.';
        return
    };
    systemctl is-active --quiet strongswan.service || { 
        set_live_status STOPPED 'strongSwan is not active.';
        return
    };
    ip link show dev "$XFRM_IF" > /dev/null 2>&1 || { 
        set_live_status FAILED 'XFRM interface is missing.';
        return
    };
    sas=$(safe_sas);
    if ! grep -q ESTABLISHED <<< "$sas" || ! grep -q INSTALLED <<< "$sas"; then
        set_live_status DISCONNECTED 'No live IKE/CHILD session exists.';
        return;
    fi;
    ping -I "$XFRM_IF" -c 1 -W 1 "$XFRM_PEER_IP" > /dev/null 2>&1 || { 
        set_live_status DISCONNECTED 'Encrypted peer is not responding.';
        return
    };
    systemctl is-active --quiet dragon-fruit-relay-routing.service || degraded=$((degraded + 1));
    route_uses_interface 9.9.9.9 "$XFRM_LOCAL_IP" "$XFRM_IF" || degraded=$((degraded + 1));
    resolver_runtime_ok || degraded=$((degraded + 1));
    if ((degraded > 0)); then
        set_live_status DEGRADED 'Encrypted tunnel is healthy; one or more managed data-path components need Repair.';
    else
        if ! health_timer_is_armed dragon-fruit-relay-healthcheck.timer; then
            set_live_status DEGRADED 'Tunnel and DNS are healthy; automatic recovery monitor has no verified next execution.';
        else
            set_live_status OPERATIONAL "Peer $XFRM_PEER_IP, routing, resolver and recovery monitor are healthy.";
        fi;
    fi
}

finalize_ingress_after_tunnel ()
{
    start_unit_checked dragon-fruit-relay-routing.service 'Selective routing service' || return 1
    remove_systemd_resolved || true
    configure_dhcpcd_resolver_hook || warn 'Could not stop dhcpcd from managing /etc/resolv.conf. The tunnel remains active, but DHCP may replace the managed resolver.'
    write_ingress_dns_files no || warn 'Could not rebuild the static resolver definition. The tunnel remains active.'
    write_ingress_healthcheck_files || warn 'Could not rebuild the health-monitor definition. The tunnel remains active.'
    timeout 15s systemctl daemon-reload >>"$LOG_FILE" 2>&1 || warn 'systemd did not reload the resolver and monitor units within 15 seconds.'
    if start_unit_checked dragon-fruit-relay-dns.service 'Static resolver service'; then
        resolver_runtime_ok || warn 'The resolver unit ran, but /etc/resolv.conf is not using the managed resolver file.'
    else
        warn 'The encrypted tunnel remains active, but the static resolver service needs Repair.'
    fi
    start_health_monitor_best_effort || true
    return 0
}

find_free_route_table () 
{ 
    local table;
    for ((table=RT_TABLE_MIN; table<=RT_TABLE_MAX; table++))
    do
        if ! route_table_in_use "$table"; then
            printf '%s' "$table";
            return;
        fi;
    done;
    return 1
}

find_free_rule_prefs () 
{ 
    local start;
    for ((start=RULE_PREF_MIN; start<=RULE_PREF_MAX-2; start+=3))
    do
        if ! rule_pref_in_use "$start" && ! rule_pref_in_use "$((start+1))" && ! rule_pref_in_use "$((start+2))"; then
            printf '%s\n%s\n%s\n' "$start" "$((start+1))" "$((start+2))";
            return;
        fi;
    done;
    return 1
}



hub_configured () 
{ 
    [[ -f "$HOST_CONFIG_FILE" ]]
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

ingress_connectivity_tests () 
{ 
    load_config;
    clear_screen;
    dfr_ui_header 'END-TO-END TESTS';
    section_title 'Client end-to-end connectivity tests';
    local sas failures=0 warnings=0 answer tunnel_ip direct_ip;
    sas=$(safe_sas);
    if ! systemctl is-active --quiet dragon-fruit-relay-xfrm.service || ! systemctl is-active --quiet strongswan.service || ! grep -q ESTABLISHED <<< "$sas" || ! grep -q INSTALLED <<< "$sas"; then
        print_check fail 'Encrypted tunnel' 'IKE and CHILD SAs must be established before data-path tests can run.';
        return 1;
    fi;
    section_title 'Tunnel and Internet';
    if ping_from_source "$XFRM_IF" "$XFRM_PEER_IP"; then
        print_check pass 'Tunnel peer ping' "$XFRM_PEER_IP responds through $XFRM_IF";
    else
        print_check fail 'Tunnel peer ping' "$XFRM_PEER_IP is unreachable through $XFRM_IF";
        failures=$((failures + 1));
    fi;
    if ping_from_source "$XFRM_LOCAL_IP" 1.1.1.1; then
        print_check pass 'Internet ping through relay' '1.1.1.1 responds using the tunnel source address';
    else
        print_check fail 'Internet ping through relay' 'No response from 1.1.1.1 using the tunnel source address';
        failures=$((failures + 1));
    fi;
    direct_ip=$(detect_public_ipv4 "$WAN_IF" || true);
    [[ -n "$direct_ip" ]] && print_check info 'Direct-path public IPv4' "${C_CYAN}${direct_ip}${C_RESET} (multi-source consensus)" plain || print_check info 'Direct-path public IPv4' 'not reported because independent route-bound services disagreed';
    tunnel_ip=$(detect_public_ipv4 "$XFRM_LOCAL_IP" || true);
    if [[ -n "$tunnel_ip" ]]; then
        if [[ "$tunnel_ip" == "$PEER_PUBLIC_IP" ]]; then
            print_check pass 'Relay public IPv4' "${C_CYAN}${tunnel_ip}${C_RESET} matches the configured Server endpoint" plain;
        else
            print_check warn 'Relay public IPv4' "${C_CYAN}${tunnel_ip}${C_RESET} differs from configured endpoint ${C_CYAN}${PEER_PUBLIC_IP}${C_RESET}" plain;
            warnings=$((warnings + 1));
        fi;
    else
        print_check warn 'Relay public IPv4' 'lookup services did not reach consensus; ping and DNS tests remain authoritative';
        warnings=$((warnings + 1));
    fi;
    section_title 'DNS through tunnel and server NAT';
    if answer=$(dns_query_from_source "$XFRM_LOCAL_IP" "$DNS_PRIMARY"); then
        print_check pass 'Primary DNS over relay/NAT' "$DNS_PRIMARY returned $answer";
    else
        print_check fail 'Primary DNS over relay/NAT' "$DNS_PRIMARY did not answer through the tunnel source";
        failures=$((failures + 1));
    fi;
    if answer=$(dns_query_from_source "$XFRM_LOCAL_IP" "$DNS_SECONDARY"); then
        print_check pass 'Secondary DNS over relay/NAT' "$DNS_SECONDARY returned $answer";
    else
        print_check fail 'Secondary DNS over relay/NAT' "$DNS_SECONDARY did not answer through the tunnel source";
        failures=$((failures + 1));
    fi;
    if [[ -n "${DNS_FALLBACK:-}" ]]; then
        if answer=$(dns_query_from_source "$LOCAL_IP" "$DNS_FALLBACK"); then
            print_check pass 'Local fallback DNS' "$DNS_FALLBACK returned $answer on the direct path";
        else
            print_check warn 'Local fallback DNS' "$DNS_FALLBACK did not answer on the direct path";
            warnings=$((warnings + 1));
        fi;
    fi;
    section_title 'Result';
    if ((failures == 0)); then
        if ((warnings > 0)); then
            printf '  %s%sPASS WITH WARNINGS%s  Required tunnel, Internet and DNS-over-NAT tests succeeded.\n' "$C_BOLD" "$C_YELLOW" "$C_RESET" > "$TTY_OUT";
        else
            printf '  %s%sPASS%s  Tunnel, Internet, public-IP and DNS-over-NAT tests succeeded.\n' "$C_BOLD" "$C_GREEN" "$C_RESET" > "$TTY_OUT";
        fi;
        return 0;
    fi;
    printf '  %s%sFAIL%s  %d required end-to-end test(s) failed.\n' "$C_BOLD" "$C_RED" "$C_RESET" "$failures" > "$TTY_OUT";
    return 1
}

ingress_configuration_status ()
{
    local latest='' state=''
    latest=$(find "$CONTROL_TRANSACTION_DIR" -mindepth 2 -maxdepth 2 -name state.conf -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2- || true)
    if [[ -n "$latest" && -r "$latest" ]]; then
        unset STATE ERROR UPDATED_AT
        # shellcheck disable=SC1090
        source "$latest"
        state="${STATE:-}"
    fi
    case "$state" in
        PREPARED) printf 'SCHEDULED' ;;
        APPLYING) printf 'APPLYING' ;;
        APPLIED) printf 'VERIFYING COMMIT' ;;
        FAILED) printf 'FAILED' ;;
        *) printf 'SYNCED' ;;
    esac
}

ingress_monitoring_summary ()
{
    load_config
    evaluate_live_status
    subscription_refresh_best_effort

    local profile endpoint transport enrollment_state subscription_text='UNAVAILABLE' period_text='Unavailable'
    local traffic_text='Unavailable' speed_text='Unavailable' control_text operation_text=''
    local state_label used remaining lifetime upload download up_speed down_speed starts expires
    local update_state='IDLE' update_version='' update_sha='' update_error=''
    local action_name='' action_state='' update_display config_display

    profile="${PROFILE_NAME:-paired-egress}"
    endpoint="${PEER_ENDPOINT:-${PEER_PUBLIC_IP:-unknown}}"
    transport=$(transport_description); transport=${transport/ (custom IKE + NAT-T\/ESP)/}
    enrollment_state=$(ingress_enrollment_state)

    if subscription_cache_load; then
        state_label=$(subscription_state_label "${SUB_STATE:-UNKNOWN}")
        used=$(subscription_format_bytes "${SUB_USED_BYTES:-0}")
        remaining=$(subscription_format_bytes_precise "${SUB_REMAINING_BYTES:-UNLIMITED}")
        lifetime=$(subscription_format_bytes "${SUB_LIFETIME_BYTES:-0}")
        upload=$(subscription_format_bytes "${SUB_UPLOAD_BYTES:-0}")
        download=$(subscription_format_bytes "${SUB_DOWNLOAD_BYTES:-0}")
        up_speed="${SUB_MAX_UPLOAD_MBPS:-UNLIMITED}"; down_speed="${SUB_MAX_DOWNLOAD_MBPS:-UNLIMITED}"
        [[ "$up_speed" == UNLIMITED ]] && up_speed='Unlimited' || up_speed="${up_speed} Mbps"
        [[ "$down_speed" == UNLIMITED ]] && down_speed='Unlimited' || down_speed="${down_speed} Mbps"
        starts=$(subscription_format_date "${SUB_STARTS_AT:-0}" 'Immediate')
        expires=$(subscription_format_date "${SUB_EXPIRES_AT:-0}" 'Never')
        subscription_text="${state_label} · ${used} used · ${remaining} remaining"
        period_text="${starts} -> ${expires}"
        traffic_text="↑ ${upload} · ↓ ${download} · lifetime ${lifetime}"
        speed_text="↓ ${down_speed} · ↑ ${up_speed}"
    fi

    if [[ -r "$UPDATE_CURRENT_STATE" ]]; then
        unset UPDATE_STATE UPDATE_VERSION UPDATE_SHA256 UPDATE_ERROR
        # shellcheck disable=SC1090
        source "$UPDATE_CURRENT_STATE"
        update_state="${UPDATE_STATE:-IDLE}"; update_version="${UPDATE_VERSION:-}"; update_sha="${UPDATE_SHA256:-}"; update_error="${UPDATE_ERROR:-}"
    fi
    if [[ -r "${CONTROL_STATE_DIR}/operation.conf" ]]; then
        unset ACTION_NAME ACTION_STATE ACTION_MESSAGE
        # shellcheck disable=SC1090
        source "${CONTROL_STATE_DIR}/operation.conf"
        action_name="${ACTION_NAME:-}"; action_state="${ACTION_STATE:-}"
    fi
    update_display=$(managed_update_state_display "$update_state" "$update_version" "$update_sha")
    config_display=$(ingress_configuration_status)
    control_text="${update_display} · Client ${APP_VERSION}"
    [[ -z "$action_name" ]] || operation_text="${action_name} · ${action_state:-UNKNOWN}"

    ui_summary_begin 'Monitoring summary' "$LIVE_STATUS"
    ui_summary_row 'Connection' "${profile} · ${LIVE_STATUS} · ${enrollment_state}" state
    ui_summary_row 'Server' "${endpoint} · ${transport}" accent
    ui_summary_row 'Tunnel' "${XFRM_LOCAL_IP:-?} -> ${XFRM_PEER_IP:-?}" identity
    ui_summary_row 'Subscription' "$subscription_text" state
    ui_summary_row 'Period' "$period_text" plain
    ui_summary_row 'Traffic' "$traffic_text" plain
    ui_summary_row 'Speed' "$speed_text" plain
    ui_summary_row 'Managed control' "$control_text" state
    ui_summary_row 'Configuration' "$config_display" state
    [[ -z "$operation_text" ]] || ui_summary_row 'Last operation' "$operation_text" state
    [[ -z "$update_error" ]] || ui_summary_row 'Update attention' "$update_error" state
}

ingress_enrollment_menu ()
{
    local choice
    while configured_ingress; do
        clear_screen
        dfr_ui_header 'CLIENT | ENROLLMENT & TOKEN'
        ingress_enrollment_summary
        section_title 'Enrollment actions'
        ui_menu_item 1 'Enrollment Status & Security' neutral
        ui_menu_item 2 'Enroll / Refresh Token for Current Connection' positive
        ui_menu_item 3 'Replace Connection with New Enrollment Token' caution
        printf '\n' > "$TTY_OUT"
        section_title 'Navigation'; ui_navigation_footer
        choice=$(prompt '  Select an option: ') || return 0
        case "$choice" in
            1) ingress_enrollment_status_screen; pause_screen ;;
            2) managed_enroll_existing_ingress || true; sleep 0.5 ;;
            3) replace_ingress_connection || true; sleep 0.5 ;;
            g|G) ingress_global_navigation ;;
            b|B|0) return 0 ;;
            q|Q|99) exit 0 ;;
            *) warn 'Invalid selection.'; sleep 0.35 ;;
        esac
    done
}

ingress_global_navigation ()
{
    local choice
    while configured_ingress; do
        clear_screen
        dfr_ui_header 'CLIENT | NAVIGATE'
        section_title 'Go to'
        ui_menu_item 1 'Status & Detailed Summary' neutral
        ui_menu_item 2 'Diagnostics' neutral
        ui_menu_item 3 'Managed Software & CONTROL' neutral
        ui_menu_item 4 'Enrollment & Token' neutral
        printf '\n' > "$TTY_OUT"
        section_title 'Navigation'
        ui_menu_item M 'Client Menu' navigation
        ui_menu_item B 'Back' back
        ui_menu_item Q 'Exit' destructive
        choice=$(prompt '  Select destination: ') || return 0
        case "$choice" in
            1) ingress_detailed_status_screen || true; pause_screen ;;
            2) ingress_diagnostics_menu ;;
            3) managed_update_status_screen; pause_screen ;;
            4) ingress_enrollment_menu ;;
            m|M) return 0 ;;
            b|B|0) return 0 ;;
            q|Q|99) exit 0 ;;
            *) warn 'Invalid selection.'; sleep 0.35 ;;
        esac
    done
}

ingress_diagnostics_menu ()
{
    local choice
    while configured_ingress; do
        clear_screen
        dfr_ui_header 'CLIENT DIAGNOSTICS'
        ingress_diagnostic_summary
        section_title 'Diagnostics'
        ui_menu_item 1 'Health Summary' neutral
        ui_menu_item 2 'End-to-End Connectivity Test' positive
        ui_menu_item 3 'Tunnel & Traffic' neutral
        ui_menu_item 4 'Routing & DNS' neutral
        ui_menu_item 5 'Services & Transport' neutral
        ui_menu_item 6 'Recent Logs' caution
        ui_menu_item 7 'Export Redacted Diagnostic Report' neutral
        section_title 'Navigation'; ui_navigation_footer
        choice=$(prompt '  Select a diagnostic view: ') || return 0
        case "$choice" in
            1) diagnostics_overview || true; pause_screen ;;
            2) ingress_connectivity_tests || true; pause_screen ;;
            3) diagnostics_tunnel; pause_screen ;;
            4) diagnostics_routing; pause_screen ;;
            5) diagnostics_ports; pause_screen ;;
            6) diagnostics_logs; pause_screen ;;
            7) write_diagnostic_report; pause_screen ;;
            g|G) ingress_global_navigation ;;
            b|B|0) return 0 ;;
            q|Q|99) exit 0 ;;
            *) warn 'Invalid selection.'; sleep 0.35 ;;
        esac
    done
}

ingress_interactive_menu ()
{
    local choice
    while configured_ingress; do
        clear_screen
        dfr_ui_header 'CLIENT MENU'
        ingress_monitoring_summary

        section_title 'Operations'
        ui_menu_item 1 'Status & Detailed Summary' neutral
        ui_menu_item 2 'Diagnostics' neutral
        ui_menu_item 3 'Logs' neutral

        section_title 'Connection'
        ui_menu_item 4 'Start / Reconnect' positive
        ui_menu_item 5 'Stop' caution
        ui_menu_item 6 'Repair Connection' neutral
        ui_menu_item 7 'Enrollment & Token' neutral

        section_title 'System'
        ui_menu_item 8 'Remove Connection from This Client' caution
        ui_menu_item 9 'Uninstall Dragon Fruit Relay' destructive

        printf '\n' > "$TTY_OUT"
        section_title 'Navigation'
        ui_menu_item R 'Refresh' neutral
        ui_menu_item G 'Navigate' navigation
        ui_menu_item Q 'Exit' destructive
        choice=$(prompt '  Select an option: ') || exit 0
        case "$choice" in
            1) ingress_detailed_status_screen || true; pause_screen ;;
            2) ingress_diagnostics_menu ;;
            3) diagnostics_logs; pause_screen ;;
            4) start_tunnel || true; sleep 0.5 ;;
            5) stop_tunnel; sleep 0.5 ;;
            6) repair_current || true; sleep 0.5 ;;
            7) ingress_enrollment_menu ;;
            8) remove_tunnel_configuration; return ;;
            9) uninstall_routevpn; return ;;
            r|R) load_config; subscription_refresh_best_effort; [[ "${MANAGED_CONTROL:-no}" == yes ]] && "$CONTROL_AGENT" --once || true ;;
            g|G) ingress_global_navigation ;;
            q|Q|0) exit 0 ;;
            *) warn 'Invalid selection.'; sleep 0.35 ;;
        esac
    done
}

ingress_user_health_text ()
{
    case "${LIVE_STATUS:-UNKNOWN}" in

        OPERATIONAL)
            printf 'Connection is healthy.'
            ;;

        DEGRADED)
            printf 'Connection is active but needs attention. Open Diagnostics.'
            ;;

        DISCONNECTED)
            printf 'Connection is offline. Use Start / reconnect or Diagnostics.'
            ;;

        STOPPED)
            printf 'Connection is stopped.'
            ;;

        FAILED)
            printf 'Connection needs repair. Open Diagnostics.'
            ;;

        'NOT CONFIGURED')
            printf 'No client connection is configured.'
            ;;

        *)
            printf 'Connection state is unavailable.'
            ;;
    esac;

    return 0;
}

subscription_format_bytes ()
{
    local value="${1:-0}"

    if [[ "$value" == UNLIMITED || -z "$value" ]]; then
        printf 'Unlimited'
        return 0
    fi

    [[ "$value" =~ ^[0-9]+$ ]] || {
        printf 'Unavailable'
        return 0
    }

    awk -v n="$value" 'BEGIN {
        if (n >= 1000000000000000)      printf "%.2f PB", n/1000000000000000;
        else if (n >= 1000000000000)    printf "%.2f TB", n/1000000000000;
        else if (n >= 1000000000)       printf "%.2f GB", n/1000000000;
        else if (n >= 1000000)          printf "%.2f MB", n/1000000;
        else if (n >= 1000)             printf "%.2f KB", n/1000;
        else                             printf "%d B", n;
    }'
}

subscription_format_bytes_precise ()
{
    local value="${1:-0}"

    if [[ "$value" == UNLIMITED || -z "$value" ]]; then
        printf 'Unlimited'
        return 0
    fi

    [[ "$value" =~ ^[0-9]+$ ]] || {
        printf 'Unavailable'
        return 0
    }

    awk -v n="$value" 'BEGIN {
        if (n >= 1000000000000000)      printf "%.4f PB", n/1000000000000000;
        else if (n >= 1000000000000)    printf "%.4f TB", n/1000000000000;
        else if (n >= 1000000000)       printf "%.2f GB", n/1000000000;
        else if (n >= 1000000)          printf "%.2f MB", n/1000000;
        else if (n >= 1000)             printf "%.2f KB", n/1000;
        else                             printf "%d B", n;
    }'
}

subscription_format_percent ()
{
    local part="${1:-0}" total="${2:-0}"
    awk -v p="$part" -v t="$total" 'BEGIN {
        if (t <= 0) { printf "0.00%%"; exit }
        x=(p/t)*100;
        if (x < 0) x=0;
        if (x > 100) x=100;
        if (x > 0 && x < 0.01) printf "<0.01%%";
        else if (x < 100 && x > 99.99) printf ">99.99%%";
        else printf "%.2f%%", x;
    }'
}

subscription_format_date ()
{
    local epoch="${1:-0}" fallback="$2"

    if [[ ! "$epoch" =~ ^[0-9]+$ || "$epoch" -eq 0 ]]; then
        printf '%s' "$fallback"
        return 0
    fi

    date -u -d "@${epoch}" '+%d %b %Y' 2>/dev/null || printf '%s' "$fallback"
}

subscription_cache_load ()
{
    unset SUB_CACHE_SCHEMA SUB_PROTOCOL_VERSION SUB_PROFILE_NAME SUB_STATE
    unset SUB_STARTS_AT SUB_EXPIRES_AT SUB_QUOTA_BYTES SUB_UPLOAD_BYTES
    unset SUB_DOWNLOAD_BYTES SUB_USED_BYTES SUB_REMAINING_BYTES
    unset SUB_LIFETIME_BYTES SUB_MAX_UPLOAD_MBPS SUB_MAX_DOWNLOAD_MBPS
    unset SUB_UPDATED_EPOCH SUB_FETCHED_EPOCH

    [[ -r "$SUBSCRIPTION_CACHE" ]] || return 1

    # shellcheck disable=SC1090
    source "$SUBSCRIPTION_CACHE"

    [[ "${SUB_CACHE_SCHEMA:-}" == 1 ]] || return 1
    [[ "${SUB_PROTOCOL_VERSION:-}" == "$SUBSCRIPTION_PROTOCOL_VERSION" ]] || return 1
    [[ "${SUB_PROFILE_NAME:-}" == "${PROFILE_NAME:-}" ]] || return 1
    [[ "${SUB_FETCHED_EPOCH:-}" =~ ^[0-9]+$ ]] || return 1

    return 0
}

subscription_refresh_best_effort ()
{
    case "${LIVE_STATUS:-UNKNOWN}" in
        OPERATIONAL|DEGRADED)
            [[ -x "$SUBSCRIPTION_REFRESH" ]] || return 0
            timeout 4s "$SUBSCRIPTION_REFRESH" >/dev/null 2>&1 || true
            ;;
    esac

    return 0
}


subscription_state_label ()
{
    case "${1:-UNKNOWN}" in
        QUOTA_EXHAUSTED) printf 'QUOTA EXHAUSTED' ;;
        ACTIVE|SCHEDULED|SUSPENDED|EXPIRED) printf '%s' "$1" ;;
        *) printf 'UNAVAILABLE' ;;
    esac
}

subscription_print_dashboard ()
{
    local now age freshness state_label starts expires quota upload download used remaining lifetime upload_speed download_speed usage='-' remaining_usage='-'

    if ! subscription_cache_load; then
        ui_summary_begin 'Subscription' 'UNAVAILABLE'
        ui_summary_row 'Server data' 'Unavailable'
        return 0
    fi

    now=$(date +%s); age=$(( now - SUB_FETCHED_EPOCH )); ((age < 0)) && age=0
    if ((age <= 5)); then freshness='CURRENT · updated just now'
    elif ((age <= 90)); then freshness="CURRENT · updated ${age}s ago"
    elif ((age <= SUBSCRIPTION_CACHE_STALE_SECONDS)); then freshness="CURRENT · updated ${age}s ago"
    else freshness="STALE · last update ${age}s ago"; fi

    state_label=$(subscription_state_label "${SUB_STATE:-UNKNOWN}")
    starts=$(subscription_format_date "${SUB_STARTS_AT:-0}" 'Immediate')
    expires=$(subscription_format_date "${SUB_EXPIRES_AT:-0}" 'Never')
    quota=$(subscription_format_bytes "${SUB_QUOTA_BYTES:-UNLIMITED}")
    upload=$(subscription_format_bytes "${SUB_UPLOAD_BYTES:-0}")
    download=$(subscription_format_bytes "${SUB_DOWNLOAD_BYTES:-0}")
    used=$(subscription_format_bytes "${SUB_USED_BYTES:-0}")
    remaining=$(subscription_format_bytes_precise "${SUB_REMAINING_BYTES:-UNLIMITED}")
    lifetime=$(subscription_format_bytes "${SUB_LIFETIME_BYTES:-0}")
    upload_speed="${SUB_MAX_UPLOAD_MBPS:-UNLIMITED}"; download_speed="${SUB_MAX_DOWNLOAD_MBPS:-UNLIMITED}"
    [[ "$upload_speed" == UNLIMITED ]] || upload_speed="${upload_speed} Mbps"
    [[ "$download_speed" == UNLIMITED ]] || download_speed="${download_speed} Mbps"
    [[ "$upload_speed" == UNLIMITED ]] && upload_speed='Unlimited'
    [[ "$download_speed" == UNLIMITED ]] && download_speed='Unlimited'
    if [[ "${SUB_QUOTA_BYTES:-UNLIMITED}" =~ ^[0-9]+$ && "${SUB_QUOTA_BYTES}" -gt 0 && "${SUB_USED_BYTES:-0}" =~ ^[0-9]+$ && "${SUB_REMAINING_BYTES:-0}" =~ ^[0-9]+$ ]]; then
        usage=$(subscription_format_percent "$SUB_USED_BYTES" "$SUB_QUOTA_BYTES")
        remaining_usage=$(subscription_format_percent "$SUB_REMAINING_BYTES" "$SUB_QUOTA_BYTES")
    elif [[ "${SUB_QUOTA_BYTES:-}" == UNLIMITED ]]; then
        usage='Unlimited'; remaining_usage='Unlimited'
    fi

    ui_summary_begin 'Subscription' "$state_label"
    ui_summary_row 'State' "$state_label" state
    ui_summary_row 'Freshness' "$freshness"
    ui_summary_row 'Period' "$starts -> $expires"
    ui_summary_row 'Upload' "$upload"
    ui_summary_row 'Download' "$download"
    if [[ "$usage" == Unlimited || "$usage" == - ]]; then
        ui_summary_row 'Used' "$used"; ui_summary_row 'Remaining' "$remaining"
    else
        ui_summary_row 'Used' "$used · $usage"; ui_summary_row 'Remaining' "$remaining · $remaining_usage"
    fi
    ui_summary_row 'Allowance' "$quota"
    ui_summary_row 'Download speed' "$download_speed"
    ui_summary_row 'Upload speed' "$upload_speed"
    ui_summary_row 'Lifetime' "$lifetime"
}

write_subscription_client_files ()
{
    ensure_managed_layout

    cat > "$SUBSCRIPTION_REFRESH" <<'EOF_SUBSCRIPTION_REFRESH'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

CONFIG=/etc/dragon-fruit-relay/dragon-fruit-relay.conf
CACHE_DIR=/var/lib/dragon-fruit-relay/subscription
CACHE=${CACHE_DIR}/state.conf
PORT_DEFAULT=39892
PROTOCOL=1
RESPONSE="DRAGON-FRUIT-RELAY-SUBSCRIPTION/${PROTOCOL}"

[[ -r "$CONFIG" ]] || exit 1
# shellcheck disable=SC1091
source "$CONFIG"
PORT="${SUBSCRIPTION_PORT:-$PORT_DEFAULT}"

[[ -n "${PROFILE_NAME:-}" && -n "${XFRM_PEER_IP:-}" && -n "${XFRM_IF:-}" ]] || exit 1
ip link show dev "$XFRM_IF" >/dev/null 2>&1 || exit 1

response=$(timeout 3s bash -c '
    host="$1"; port="$2"; protocol="$3"; profile="$4"
    exec 3<>"/dev/tcp/${host}/${port}" || exit 1
    printf "DRAGON-FRUIT-RELAY-SUBSCRIPTION/%s\\nPROFILE=%s\\n\\n" "$protocol" "$profile" >&3
    while IFS= read -r line <&3; do
        printf "%s\\n" "$line"
        [[ "$line" == END=1 ]] && break
    done
' _ "$XFRM_PEER_IP" "$PORT" "$PROTOCOL" "$PROFILE_NAME" 2>/dev/null) || exit 1

first=${response%%$'\n'*}
[[ "$first" == "$RESPONSE" ]] || exit 1

profile='' state='' starts='0' expires='0' quota='UNLIMITED'
upload='0' download='0' used='0' remaining='UNLIMITED' lifetime='0'
max_up='UNLIMITED' max_down='UNLIMITED' updated='0' end='0'

while IFS= read -r line; do
    [[ "$line" == *=* ]] || continue
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
        PROFILE) profile="$value" ;;
        STATE) state="$value" ;;
        STARTS_AT) starts="$value" ;;
        EXPIRES_AT) expires="$value" ;;
        QUOTA_BYTES) quota="$value" ;;
        UPLOAD_BYTES) upload="$value" ;;
        DOWNLOAD_BYTES) download="$value" ;;
        USED_BYTES) used="$value" ;;
        REMAINING_BYTES) remaining="$value" ;;
        LIFETIME_BYTES) lifetime="$value" ;;
        MAX_UPLOAD_MBPS) max_up="$value" ;;
        MAX_DOWNLOAD_MBPS) max_down="$value" ;;
        UPDATED_EPOCH) updated="$value" ;;
        END) end="$value" ;;
    esac
done <<<"$response"

[[ "$profile" == "$PROFILE_NAME" ]] || exit 1
[[ "$end" == 1 ]] || exit 1
case "$state" in ACTIVE|SCHEDULED|SUSPENDED|EXPIRED|QUOTA_EXHAUSTED) ;; *) exit 1 ;; esac

for value in "$starts" "$expires" "$upload" "$download" "$used" "$lifetime" "$updated"; do
    [[ "$value" =~ ^[0-9]+$ ]] || exit 1
done
for value in "$quota" "$remaining" "$max_up" "$max_down"; do
    [[ "$value" == UNLIMITED || "$value" =~ ^[0-9]+$ ]] || exit 1
done

install -d -m 0700 "$CACHE_DIR"
tmp="${CACHE}.tmp.$$"
{
    printf 'SUB_CACHE_SCHEMA=%q\n' 1
    printf 'SUB_PROTOCOL_VERSION=%q\n' "$PROTOCOL"
    printf 'SUB_PROFILE_NAME=%q\n' "$profile"
    printf 'SUB_STATE=%q\n' "$state"
    printf 'SUB_STARTS_AT=%q\n' "$starts"
    printf 'SUB_EXPIRES_AT=%q\n' "$expires"
    printf 'SUB_QUOTA_BYTES=%q\n' "$quota"
    printf 'SUB_UPLOAD_BYTES=%q\n' "$upload"
    printf 'SUB_DOWNLOAD_BYTES=%q\n' "$download"
    printf 'SUB_USED_BYTES=%q\n' "$used"
    printf 'SUB_REMAINING_BYTES=%q\n' "$remaining"
    printf 'SUB_LIFETIME_BYTES=%q\n' "$lifetime"
    printf 'SUB_MAX_UPLOAD_MBPS=%q\n' "$max_up"
    printf 'SUB_MAX_DOWNLOAD_MBPS=%q\n' "$max_down"
    printf 'SUB_UPDATED_EPOCH=%q\n' "$updated"
    printf 'SUB_FETCHED_EPOCH=%q\n' "$(date +%s)"
} >"$tmp"
chmod 0600 "$tmp"
mv -f -- "$tmp" "$CACHE"
EOF_SUBSCRIPTION_REFRESH

    chmod 0750 "$SUBSCRIPTION_REFRESH"
    return 0
}

managed_update_state_display ()
{
    local state="${1:-}" version="${2:-}" digest="${3:-}" actual=''
    case "$state" in
        COMMITTED|CURRENT)
            if [[ -n "$version" && "$version" == "$APP_VERSION" && "$digest" =~ ^[0-9a-fA-F]{64}$ && -r "$CLI_COMMAND" ]]; then
                actual=$(sha256sum "$CLI_COMMAND" 2>/dev/null | awk '{print $1}' || true)
                if [[ -n "$actual" && "${digest,,}" == "${actual,,}" ]]; then
                    printf 'LATEST'
                else
                    printf 'UPDATE REQUIRED'
                fi
            else
                printf 'UPDATE REQUIRED'
            fi
            ;;
        APPLYING) printf 'INSTALLING' ;;
        ROLLED_BACK) printf 'ROLLED BACK' ;;
        IDLE|'') printf 'CURRENT' ;;
        *) printf '%s' "$state" ;;
    esac
}

ingress_managed_dashboard_rows ()
{
    [[ "${MANAGED_CONTROL:-no}" == yes ]] || return 0
    local update_state='IDLE' update_version='' update_sha='' update_error='' action_name='' action_state='' update_display config_display
    if [[ -r "$UPDATE_CURRENT_STATE" ]]; then
        unset UPDATE_STATE UPDATE_VERSION UPDATE_SHA256 UPDATE_ERROR
        # shellcheck disable=SC1090
        source "$UPDATE_CURRENT_STATE"
        update_state="${UPDATE_STATE:-IDLE}"; update_version="${UPDATE_VERSION:-}"; update_sha="${UPDATE_SHA256:-}"; update_error="${UPDATE_ERROR:-}"
    fi
    if [[ -r "${CONTROL_STATE_DIR}/operation.conf" ]]; then
        unset ACTION_NAME ACTION_STATE ACTION_MESSAGE
        # shellcheck disable=SC1090
        source "${CONTROL_STATE_DIR}/operation.conf"
        action_name="${ACTION_NAME:-}"; action_state="${ACTION_STATE:-}"
    fi
    update_display=$(managed_update_state_display "$update_state" "$update_version" "$update_sha")
    config_display=$(ingress_configuration_status)
    ui_summary_begin 'Managed Control' "$update_display"
    ui_summary_row 'Software' "$APP_VERSION" plain
    if [[ -n "$update_version" ]]; then ui_summary_row 'Update' "$update_display · $update_version"; else ui_summary_row 'Update' "$update_display" state; fi
    ui_summary_row 'Configuration' "$config_display" state
    [[ -z "$action_name" ]] || ui_summary_row 'Last operation' "$action_name · ${action_state:-UNKNOWN}"
    [[ -z "$update_error" ]] || ui_summary_row 'Last update error' "$update_error"
}

ingress_enrollment_state ()
{
    if [[ "${MANAGED_CONTROL:-no}" != yes ]]; then
        printf 'NOT ENROLLED'
        return 0
    fi
    if [[ "${CONTROL_PROTOCOL:-0}" != "$CONTROL_PROTOCOL_VERSION" ||
          ! "${CONNECTION_UUID:-}" =~ ^[0-9A-Fa-f-]{36}$ ||
          ! "${CONTROL_KEY:-}" =~ ^[0-9a-f]{64}$ ||
          ! "${ENROLLMENT_TOKEN_HASH:-}" =~ ^[0-9a-f]{64}$ ]]; then
        printf 'DEGRADED'
        return 0
    fi
    printf 'ENROLLED'
}

ingress_enrollment_summary ()
{
    local enrollment_state token_record trust_state protocol_display
    enrollment_state=$(ingress_enrollment_state)
    [[ -n "${ENROLLMENT_TOKEN_HASH:-}" ]] && token_record='PRESENT' || token_record='NONE'
    [[ -s "$UPDATE_PUBLIC_KEY" ]] && trust_state='PRESENT' || trust_state='NONE'
    if [[ "${CONTROL_PROTOCOL:-0}" == "$CONTROL_PROTOCOL_VERSION" ]]; then
        protocol_display="CONTROL/${CONTROL_PROTOCOL_VERSION}"
    else
        protocol_display='NOT ENROLLED'
    fi

    ui_summary_begin 'Token Enrollment' "$enrollment_state"
    ui_summary_row 'Enrollment' "$enrollment_state" state
    ui_summary_row 'Connection' "${PROFILE_NAME:-paired-egress}" identity
    ui_summary_row 'Server endpoint' "${PEER_ENDPOINT:-${PEER_PUBLIC_IP:-unknown}}" accent
    ui_summary_row 'Managed control' "$([[ "${MANAGED_CONTROL:-no}" == yes ]] && printf 'ENABLED' || printf 'DISABLED')" state
    ui_summary_row 'Control protocol' "$protocol_display" plain
    ui_summary_row 'Connection ID' "${CONNECTION_UUID:-none}" identity
    ui_summary_row 'Token verifier' "$token_record" state
    ui_summary_row 'Update trust' "$trust_state" state
}

ingress_enrollment_status_screen ()
{
    configured_ingress || die 'No client connection is configured.'
    load_config
    clear_screen
    dfr_ui_header 'CLIENT ENROLLMENT'
    ingress_enrollment_summary
    section_title 'Token handling'
    printf '  Enrollment tokens are one-time credentials and are never displayed after enrollment.\n' > "$TTY_OUT"
    printf '  Only the enrollment verifier and managed-control identity are retained locally.\n' > "$TTY_OUT"
    printf '  Use a new token for this same connection to enroll or refresh managed control.\n' > "$TTY_OUT"
    printf '  Use Replace Connection when the token belongs to a different Server connection.\n' > "$TTY_OUT"
}

ingress_main_dashboard ()
{
    load_config
    evaluate_live_status
    subscription_refresh_best_effort
    local profile health transport enrollment_state
    profile="${PROFILE_NAME:-paired-egress}"; health=$(ingress_user_health_text); transport=$(transport_description)
    enrollment_state=$(ingress_enrollment_state)
    transport=${transport/ (custom IKE + NAT-T\/ESP)/}

    ui_summary_begin 'Client Connection' "$LIVE_STATUS"
    ui_summary_row 'Profile' "$profile" identity
    ui_summary_row 'Server endpoint' "${PEER_ENDPOINT:-$PEER_PUBLIC_IP}" accent
    ui_summary_row 'Transport' "$transport" plain
    ui_summary_row 'Tunnel' "$XFRM_LOCAL_IP -> $XFRM_PEER_IP" identity
    ui_summary_row 'Status' "$LIVE_STATUS" state
    ui_summary_row 'Enrollment' "$enrollment_state" state
    ui_summary_row 'Health' "$health" auto
    subscription_print_dashboard
    ingress_managed_dashboard_rows
}

ingress_detailed_status_screen ()
{
    clear_screen
    dfr_ui_header 'CLIENT STATUS & DETAILS'
    ingress_main_dashboard
}

ingress_diagnostic_summary ()
{
    load_config
    evaluate_live_status
    local sas ike_state='DISCONNECTED' routing_state='ATTENTION' resolver_state='ATTENTION' monitor_state='ATTENTION'
    sas=$(safe_sas)
    if grep -q ESTABLISHED <<< "$sas" && grep -q INSTALLED <<< "$sas"; then
        ike_state='ESTABLISHED / INSTALLED'
    fi
    if systemctl is-active --quiet dragon-fruit-relay-routing.service && route_uses_interface 9.9.9.9 "$XFRM_LOCAL_IP" "$XFRM_IF"; then
        routing_state='READY'
    fi
    resolver_runtime_ok && resolver_state='READY'
    health_timer_is_armed dragon-fruit-relay-healthcheck.timer && monitor_state='ARMED'

    ui_summary_begin 'Diagnostic summary' "$LIVE_STATUS"
    ui_summary_row 'Connection' "${PROFILE_NAME:-paired-egress} · ${LIVE_STATUS}" state
    ui_summary_row 'IKE / CHILD' "$ike_state" state
    ui_summary_row 'Tunnel' "$XFRM_LOCAL_IP -> $XFRM_PEER_IP · $XFRM_IF" identity
    ui_summary_row 'Routing' "$routing_state" state
    ui_summary_row 'Resolver' "$resolver_state" state
    ui_summary_row 'Recovery monitor' "$monitor_state" state
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
        install -d -m 0755 "$(dirname "$USER_CLI_COMMAND")";
        ln -sfn "$CLI_COMMAND" "$USER_CLI_COMMAND";
        return 0;
    fi;
    local temporary="${CLI_COMMAND}.tmp.$$";
    install -m 0755 "$source_file" "$temporary";
    mv -f -- "$temporary" "$CLI_COMMAND";
    install -d -m 0755 "$(dirname "$USER_CLI_COMMAND")";
    ln -sfn "$CLI_COMMAND" "$USER_CLI_COMMAND";
    success "Installed management command: ${CLI_COMMAND}"
}

install_dependencies ()
{
    local required_packages=(ca-certificates curl openssl python3-minimal iproute2 iptables iptables-persistent tcpdump strongswan-swanctl charon-systemd dnsutils iputils-ping sudo)
    local optional_packages=(libstrongswan-extra-plugins libcharon-extra-plugins)
    local install_packages=() missing_packages=() package
    section_title 'System preparation'
    print_check info 'Package metadata' 'Refreshing Debian repositories...'
    apt-get update >> "$LOG_FILE" 2>&1
    print_check pass 'Package metadata' 'Repository metadata is current.'
    for package in "${required_packages[@]}"; do
        if apt-cache show "$package" >/dev/null 2>&1; then install_packages+=("$package"); record_initial_package_state "$package"; else missing_packages+=("$package"); fi
    done
    ((${#missing_packages[@]}==0)) || die "This Debian release/repository does not provide required package(s): ${missing_packages[*]}"
    for package in "${optional_packages[@]}"; do
        if apt-cache show "$package" >/dev/null 2>&1; then install_packages+=("$package"); record_initial_package_state "$package"; else print_check warn 'Optional package' "${package} is unavailable; continuing without it."; fi
    done
    print_check info 'Required packages' "Installing/verifying ${#install_packages[@]} packages..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y "${install_packages[@]}" >> "$LOG_FILE" 2>&1
    print_check pass 'Required packages' 'Installed and verified.'
}

install_ingress_canonical_copy () 
{ 
    local source="$1" destination="$2" temporary;
    [[ -f "$source" ]] || die "Cannot install missing managed source: ${source}";
    temporary="${destination}.tmp.$$";
    install -m 0600 "$source" "$temporary";
    mv -f -- "$temporary" "$destination"
}

install_ingress_canonical_link () 
{ 
    local source="$1" link="$2";
    [[ -f "$source" ]] || die "Cannot install missing managed source: ${source}";
    install -d -m 0755 "$(dirname "$link")";
    if [[ -e "$link" || -L "$link" ]]; then
        if [[ -L "$link" && "$(readlink -f -- "$link" 2> /dev/null || true)" == "$(readlink -f -- "$source")" ]]; then
            return 0;
        fi;
        if [[ -f "$link" ]] && grep -q '^# Managed by Dragon Fruit Relay\.' "$link" 2> /dev/null; then
            rm -f -- "$link";
        else
            if dragonfruit_owned_symlink "$link"; then
                rm -f -- "$link";
            else
                die "Refusing to replace unmanaged integration path: ${link}";
            fi;
        fi;
    fi;
    ln -s "$source" "$link"
}

install_ingress_strongswan_canonical_copy ()
{
    # Keep the file consumed by strongSwan inside /etc/strongswan.d as a real
    # file.  Debian's swanctl AppArmor profile validates the resolved path, so
    # a symlink from /etc/strongswan.d into /etc/dragon-fruit-relay would make
    # otherwise-readable DFR configuration inaccessible to swanctl.
    local source="$1" destination="$2" temporary;
    [[ -f "$source" ]] || die "Cannot install missing managed source: ${source}";
    install -d -m 0755 "$(dirname "$destination")";

    if [[ -e "$destination" || -L "$destination" ]]; then
        if [[ -L "$destination" ]]; then
            die "Refusing to replace strongSwan integration symlink: ${destination}";
        elif [[ -f "$destination" ]] && grep -q '^# Managed by Dragon Fruit Relay\.' "$destination" 2> /dev/null; then
            :
        else
            die "Refusing to replace unmanaged strongSwan integration path: ${destination}";
        fi;
    fi;

    temporary="${destination}.tmp.$$";
    install -m 0644 "$source" "$temporary";
    mv -f -- "$temporary" "$destination";

    [[ -f "$destination" && ! -L "$destination" ]] ||
        die "Canonical strongSwan integration is not a regular file: ${destination}";
    cmp -s -- "$source" "$destination" ||
        die "Canonical strongSwan integration differs from managed source: ${destination}";
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





link_managed_unit () 
{ 
    local unit="$1";
    install_managed_link "$UNIT_DIR/$unit" "$SYSTEMD_DIR/$unit"
}

load_strongswan_checked () 
{ 
    local load_output load_status list_output list_status retry_output retry_status;
    if [[ ! -s "$INGRESS_SWANCTL_SOURCE" ]]; then
        error "Managed strongSwan source is missing or empty: $INGRESS_SWANCTL_SOURCE";
        return 1;
    fi;
    if [[ ! -s "$INGRESS_SWANCTL_CANONICAL" || ! -r "$INGRESS_SWANCTL_CANONICAL" ]]; then
        error "Canonical strongSwan configuration is missing or unreadable: $INGRESS_SWANCTL_CANONICAL";
        return 1;
    fi;
    if ! cmp -s -- "$INGRESS_SWANCTL_SOURCE" "$INGRESS_SWANCTL_CANONICAL"; then
        error "Canonical strongSwan configuration differs from the managed source: $INGRESS_SWANCTL_CANONICAL";
        return 1;
    fi;
    set +e;
    load_output=$(timeout "${SWANCTL_OPERATION_TIMEOUT_SECONDS}s" swanctl --load-all --noprompt --file "$INGRESS_SWANCTL_CANONICAL" 2>&1);
    load_status=$?;
    set -e;
    printf '%s\n' "$load_output" >> "$LOG_FILE";
    set +e;
    list_output=$(timeout "${SWANCTL_OPERATION_TIMEOUT_SECONDS}s" swanctl --list-conns 2>&1);
    list_status=$?;
    set -e;
    printf '%s\n' "$list_output" >> "$LOG_FILE";
    if ((load_status != 0 || list_status != 0)) || ! grep -Eq '^[[:space:]]*dragonfruit_relay:' <<< "$list_output"; then
        set +e;
        retry_output=$(timeout "${SWANCTL_OPERATION_TIMEOUT_SECONDS}s" swanctl --load-conns --file "$INGRESS_SWANCTL_CANONICAL" 2>&1);
        retry_status=$?;
        list_output=$(timeout "${SWANCTL_OPERATION_TIMEOUT_SECONDS}s" swanctl --list-conns 2>&1);
        list_status=$?;
        set -e;
        printf '%s\n%s\n' "$retry_output" "$list_output" >> "$LOG_FILE";
        if ((retry_status != 0 || list_status != 0)) || ! grep -Eq '^[[:space:]]*dragonfruit_relay:' <<< "$list_output"; then
            error 'The Dragon Fruit Relay connection was not loaded within the allowed time.';
            printf '%s\n' '--- swanctl --load-all ---' > "$TTY_OUT";
            printf '%s\n' "${load_output:-no output}" > "$TTY_OUT";
            printf '%s\n' '--- swanctl --load-conns ---' > "$TTY_OUT";
            printf '%s\n' "${retry_output:-no output}" > "$TTY_OUT";
            printf '%s\n' '--- swanctl --list-conns ---' > "$TTY_OUT";
            printf '%s\n' "${list_output:-no output}" > "$TTY_OUT";
            return 1;
        fi;
    fi;
    success 'Dragon Fruit Relay strongSwan connection is loaded.'
}

log_line () 
{ 
    local level="$1";
    shift;
    [[ "$DFR_UNPRIVILEGED_MODE" == no ]] || return 0;
    printf '%s [%s] %s\n' "$(date -Is)" "$level" "$*" >> "$LOG_FILE"
}

managed_rule_line () 
{ 
    local pref="$1";
    ip -4 rule show 2> /dev/null | awk -v pref="${pref}:" '$1 == pref {print; exit}'
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

policy_rule_matches () 
{ 
    local pref="$1" selector="$2" address="$3" table="$4";
    ip -4 rule show 2> /dev/null | awk -v pref="${pref}:" -v selector="$selector" -v address="$address" -v table="$table" '
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

prepare_ingress_swanctl_layout ()
{
    local path target credential_dir unknown=''
    install -d -m 0755 /etc/swanctl
    for path in "$SWANCTL_CLIENT_ROOT" "$INGRESS_SWANCTL_DIR"; do
        if [[ -L "$path" ]]; then
            target=$(readlink -f -- "$path" 2>/dev/null || readlink -- "$path" 2>/dev/null || true)
            case "$target" in "$CONFIG_DIR"|"$CONFIG_DIR"/*) rm -f -- "$path" ;; *) die "Refusing to replace unmanaged swanctl namespace symlink: ${path} -> ${target:-unknown}" ;; esac
        elif [[ -e "$path" && ! -d "$path" ]]; then die "Required swanctl namespace path is not a directory: ${path}"; fi
    done
    install -d -m 0755 "$SWANCTL_CLIENT_ROOT"
    if [[ -d "$INGRESS_SWANCTL_DIR" && ! -e "$INGRESS_SWANCTL_MARKER" ]]; then
        while IFS= read -r path; do
            case "$(basename "$path")" in
                swanctl.conf)
                    if [[ -L "$path" ]]; then target=$(readlink -f -- "$path" 2>/dev/null || true); [[ "$target" == "$CONFIG_DIR"/* ]] || unknown="$path";
                    elif [[ -f "$path" ]] && grep -q '^# Managed by Dragon Fruit Relay\.' "$path" 2>/dev/null; then :; else unknown="$path"; fi ;;
                x509|x509ca|x509ocsp|x509aa|x509ac|x509crl|pubkey|private|rsa|ecdsa|pkcs8|pkcs12)
                    [[ -d "$path" ]] && ! find "$path" -mindepth 1 -print -quit 2>/dev/null | grep -q . || unknown="$path" ;;
                *) unknown="$path" ;;
            esac
            [[ -z "$unknown" ]] || break
        done < <(find "$INGRESS_SWANCTL_DIR" -mindepth 1 -maxdepth 1 -print 2>/dev/null)
        [[ -z "$unknown" ]] || die "Refusing to remove unmanaged swanctl Client content: ${unknown}"
        rm -rf -- "$INGRESS_SWANCTL_DIR"
    fi
    install -d -m 0750 "$INGRESS_SWANCTL_DIR"; : > "$INGRESS_SWANCTL_MARKER"; chmod 0640 "$INGRESS_SWANCTL_MARKER"
    for credential_dir in x509 x509ca x509ocsp x509aa x509ac x509crl pubkey private rsa ecdsa pkcs8 pkcs12; do
        path="$INGRESS_SWANCTL_DIR/$credential_dir"
        if [[ -L "$path" ]]; then target=$(readlink -f -- "$path" 2>/dev/null || true); case "$target" in "$CONFIG_DIR"/*) rm -f -- "$path" ;; *) die "Refusing to replace unmanaged swanctl credential link: ${path}" ;; esac
        elif [[ -e "$path" && ! -d "$path" ]]; then die "Required swanctl credential path is not a directory: ${path}"; fi
        install -d -m 0700 "$path"
    done
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

print_route_check () 
{ 
    local label="$1" target="$2" source="$3" expected="$4" detail;
    detail=$(route_summary "$target" "$source");
    if route_uses_interface "$target" "$source" "$expected"; then
        print_check pass "$label" "$detail";
    else
        print_check fail "$label" "$detail";
    fi
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
        printf '\n[WARN] Interactive input closed; leaving the menu.\n' > "$TTY_OUT"
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



prompt_ipv4_value () 
{ 
    local description="$1" default="$2";
    local value;
    while true; do
        value=$(prompt_default "$description" "$default");
        if validate_ipv4 "$value"; then
            printf '%s' "$value";
            return;
        fi;
        warn "Invalid IPv4 address: ${value}";
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

record_resolved_state () 
{ 
    mkdir -p "$STATE_DIR";
    local active="no" enabled="no";
    systemctl is-active --quiet systemd-resolved.service 2> /dev/null && active="yes";
    systemctl is-enabled --quiet systemd-resolved.service 2> /dev/null && enabled="yes";
    if ! grep -q '^RESOLVED_WAS_ACTIVE=' "$PACKAGE_STATE_FILE" 2> /dev/null; then
        printf 'RESOLVED_WAS_ACTIVE=%s\n' "$active" >> "$PACKAGE_STATE_FILE";
        printf 'RESOLVED_WAS_ENABLED=%s\n' "$enabled" >> "$PACKAGE_STATE_FILE";
    fi
}


reload_dhcpcd_configuration () 
{ 
    command -v dhcpcd > /dev/null 2>&1 || return 0;
    local interface="${1:-${WAN_IF:-}}";
    [[ -n "$interface" ]] || interface=$(detect_default_interface 2> /dev/null || true);
    [[ -n "$interface" ]] || return 0;
    timeout 15s dhcpcd -n "$interface" >> "$LOG_FILE" 2>&1 || true
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
    local comment
    for comment in dragon-fruit-relay-ike dragon-fruit-relay-natt dragon-fruit-relay-ike-custom dragon-fruit-relay-custom-ike-in dragon-fruit-relay-custom-ike-out dragon-fruit-relay-custom-natt-in dragon-fruit-relay-custom-natt-out dragon-fruit-relay-forward-out dragon-fruit-relay-forward-return dragon-fruit-relay-nat; do
        delete_iptables_rules_by_comment filter "$comment"; delete_iptables_rules_by_comment nat "$comment"
    done
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >>"$LOG_FILE" 2>&1 || true
}

remove_cli_command () 
{ 
    rm -f -- "$USER_CLI_COMMAND" "$CLI_COMMAND";
    if [[ -e "$CLI_COMMAND" || -L "$CLI_COMMAND" ]]; then
        die "Complete uninstall could not remove ${CLI_COMMAND}.";
    fi
}


remove_managed_integration_path () 
{ 
    local path="$1" target='';
    [[ -e "$path" || -L "$path" ]] || return 0;
    if [[ -L "$path" ]]; then
        target=$(readlink -f -- "$path" 2> /dev/null || true);
        if [[ "$target" == "$CONFIG_DIR"/* ]]; then
            rm -f -- "$path";
        fi;
        return 0;
    fi;
    if [[ -f "$path" ]] && grep -q '^# Managed by Dragon Fruit Relay\.' "$path" 2> /dev/null; then
        rm -f -- "$path";
    fi
}

remove_runtime_and_files ()
{
    local role="$1" old_xfrm_if="${XFRM_IF:-$DEFAULT_XFRM_IF}" old_table="${ROUTE_TABLE:-}"
    local p1="${RULE_DNS_PRIMARY:-}" p2="${RULE_DNS_SECONDARY:-}" p3="${RULE_TUNNEL_SOURCE:-}"
    systemctl disable --now dragon-fruit-relay-healthcheck.timer "$CONTROL_TIMER" "$CONTROL_SERVICE" >/dev/null 2>&1 || true
    systemctl stop dragon-fruit-relay-healthcheck.service dragon-fruit-relay-dns.service dragon-fruit-relay-routing.service >/dev/null 2>&1 || true
    swanctl --terminate --ike dragonfruit_relay >/dev/null 2>&1 || true
    if [[ "$role" == ingress ]]; then
        [[ -x "$LIB_DIR/routing-remove" ]] && "$LIB_DIR/routing-remove" >/dev/null 2>&1 || true
        delete_rule_pref_all "$p1"; delete_rule_pref_all "$p2"; delete_rule_pref_all "$p3"
        [[ "$old_table" =~ ^[0-9]+$ ]] && ip -4 route flush table "$old_table" 2>/dev/null || true
    fi
    remove_all_dragonfruit_network_rules || true
    systemctl stop strongswan.service >/dev/null 2>&1 || true
    systemctl disable --now dragon-fruit-relay-xfrm.service >/dev/null 2>&1 || true
    delete_link_bounded "$old_xfrm_if" || true
    rm -f "$SYSTEMD_DIR"/dragon-fruit-relay-*.service "$SYSTEMD_DIR"/dragon-fruit-relay-*.timer "$INGRESS_SWANCTL_CANONICAL"
    [[ -e "$INGRESS_SWANCTL_MARKER" ]] && rm -rf -- "$INGRESS_SWANCTL_DIR"
    remove_managed_integration_path "$SWANCTL_FILE"; remove_managed_integration_path "$STRONGSWAN_ROUTE_FILE"; remove_managed_integration_path "$STRONGSWAN_OVERRIDE_FILE"; remove_managed_integration_path "$SYSCTL_FILE"
    rmdir "$SWANCTL_CLIENT_ROOT" 2>/dev/null || true
    [[ -L /etc/resolv.conf && "$(readlink -f /etc/resolv.conf 2>/dev/null || true)" == "$RESOLVER_MANAGED_FILE" ]] && rm -f /etc/resolv.conf || true
    rm -rf "$CONFIG_DIR"
    systemctl daemon-reload >/dev/null 2>&1 || true; systemctl reset-failed >/dev/null 2>&1 || true
    REMOVED_XFRM_IF="$old_xfrm_if"; REMOVED_ROUTE_TABLE="$old_table"; REMOVED_RULE_DNS_PRIMARY="$p1"; REMOVED_RULE_DNS_SECONDARY="$p2"; REMOVED_RULE_TUNNEL_SOURCE="$p3"
}

remove_systemd_resolved () 
{ 
    record_resolved_state;
    record_initial_package_state systemd-resolved;
    record_initial_package_state libnss-resolve;
    backup_original /etc/resolv.conf;
    backup_original /etc/nsswitch.conf;
    backup_original /etc/systemd/resolved.conf;
    backup_original /etc/systemd/resolved.conf.d;
    backup_original /etc/systemd/system/systemd-resolved.service.d;
    timeout 15s systemctl disable --now systemd-resolved.service > /dev/null 2>&1 || true
}

remove_tunnel_configuration ()
{
    local skip_confirm="${1:-no}"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        ingress_unconfigured_residual_present || die 'Dragon Fruit Relay is not configured and no residual state was found.'
        [[ "$skip_confirm" == yes ]] || confirm 'Remove residual Dragon Fruit Relay state and restore available backups?' no || return 0
        clean_abandoned_install_before_setup
        success 'Residual relay state was removed.'
        return 0
    fi
    load_config; local old_role="$ROLE"
    [[ "$skip_confirm" == yes ]] || confirm 'Remove this Client connection locally and restore the pre-install state? The Server connection record is not deleted automatically.' no || return 0
    remove_runtime_and_files "$old_role"
    restore_pre_routevpn_state "$old_role"
    delete_link_bounded "$REMOVED_XFRM_IF" || true
    rm -rf "$CONFIG_DIR"
    systemctl daemon-reload >/dev/null 2>&1 || true
    verify_managed_runtime_absent "$REMOVED_XFRM_IF" "$REMOVED_ROUTE_TABLE" "$REMOVED_RULE_DNS_PRIMARY" "$REMOVED_RULE_DNS_SECONDARY" "$REMOVED_RULE_TUNNEL_SOURCE" || die 'Removal did not complete. The state directory was retained for diagnosis.'
    rm -rf "$STATE_DIR"
    success 'Client connection removed locally. Delete the Server connection separately if it is no longer needed.'
}

replace_ingress_connection ()
{
    configured_ingress || die 'This machine is not configured as a Client.'
    load_config
    local supplied_token="${1:-}" old_token old_fallback="$DNS_FALLBACK" new_name
    clear_screen
    dfr_ui_header 'CLIENT | REPLACE CONNECTION'
    ui_summary_begin 'Current connection' 'ACTIVE'
    ui_summary_row 'Profile' "${PROFILE_NAME:-paired-egress}" identity
    ui_summary_row 'Server endpoint' "${PEER_ENDPOINT:-$PEER_PUBLIC_IP}" accent
    ui_summary_row 'XFRM interface' "${XFRM_IF:-unknown}" identity
    section_title 'Replacement safety'
    print_check pass 'Current connection' 'Preserved until the replacement token validates.'
    print_check info 'Rollback' 'If the new setup fails, DFR attempts to restore this connection.'
    if [[ -z "$supplied_token" ]]; then
        section_title 'Replacement enrollment token'
        printf '  Paste the one-time DFR1 token issued by the replacement Server connection.\n  The token is validated before any current runtime is removed.\n\n' > "$TTY_OUT"
        supplied_token=$(prompt '  Enrollment token > ')
    fi
    [[ -n "$supplied_token" ]] || { warn 'Replacement cancelled: no token was supplied.'; return 1; }
    if ! ( parse_pairing_token "$supplied_token" ); then error 'The new enrollment token is invalid. The current connection was not changed.'; return 1; fi
    parse_pairing_token "$supplied_token"
    new_name=${TOKEN_PROFILE_NAME:-paired-egress}
    ui_summary_begin 'Replacement target' 'READY'
    ui_summary_row 'Profile' "$new_name" identity
    ui_summary_row 'Server endpoint' "${TOKEN_EGRESS_ENDPOINT:-$TOKEN_EXIT_PUBLIC_IP}" accent
    ui_summary_row 'IKE transport' "UDP ${TOKEN_IKE_PORT}"
    confirm "Replace the current Client connection with '${new_name}'" no || return 0
    old_token=$(generate_current_ingress_token)
    remove_tunnel_configuration yes
    if ( setup_ingress "$supplied_token" "$old_fallback" yes ); then success "Client connection replaced with '${new_name}'."; return 0; fi
    error 'The new Client connection failed. Attempting to restore the previous connection...'
    [[ -f "$CONFIG_FILE" || -d "$CONFIG_DIR" || -d "$STATE_DIR" ]] && clean_abandoned_install_before_setup || true
    if ( setup_ingress "$old_token" "$old_fallback" yes ); then warn 'The previous Client connection was restored successfully.'; return 1; fi
    error 'Automatic restoration also failed. The host was returned as close as possible to its original state.'
    return 1
}

require_ipv4 () 
{ 
    local description="$1";
    local value="$2";
    validate_ipv4 "$value" || die "Invalid ${description}: ${value}"
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

resolver_runtime_ok () 
{ 
    [[ -r /etc/resolv.conf ]] || return 1;
    [[ "$(readlink -f /etc/resolv.conf 2> /dev/null || true)" == "$RESOLVER_MANAGED_FILE" ]] || return 1;
    [[ "$(stat -c '%a' "$CONFIG_DIR" 2> /dev/null || true)" == 751 ]] || return 1;
    [[ "$(stat -c '%a' "$RESOLVER_DIR" 2> /dev/null || true)" == 751 ]] || return 1;
    [[ "$(stat -c '%a' "$RESOLVER_MANAGED_FILE" 2> /dev/null || true)" == 644 ]] || return 1;
    grep -Eq "^[[:space:]]*nameserver[[:space:]]+${DNS_PRIMARY//./\\.}([[:space:]]|$)" /etc/resolv.conf || return 1;
    grep -Eq "^[[:space:]]*nameserver[[:space:]]+${DNS_SECONDARY//./\\.}([[:space:]]|$)" /etc/resolv.conf || return 1
}

restore_originals ()
{
    [[ -f "$MANIFEST_FILE" ]] || return 0
    info 'Restoring files that existed before Dragon Fruit Relay was installed...'
    local state target saved
    while IFS=$'\t' read -r state target; do
        [[ -n "$target" ]] || continue
        case "$target" in "$CONFIG_DIR"|"$CONFIG_DIR"/*) continue ;; esac
        if awk -F '\t' -v target="$target" '$2 != target && index(target, $2 "/") == 1 {found=1} END {exit !found}' "$MANIFEST_FILE"; then continue; fi
        rm -rf -- "$target"
        if [[ "$state" == present ]]; then
            saved="${BACKUP_DIR}/files${target}"
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
    sysctl --system >>"$LOG_FILE" 2>&1 || true
    restore_unit_state strongswan.service STRONGSWAN
    reload_dhcpcd_configuration "${WAN_IF:-}"
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

rollback_failed_setup () 
{ 
    local role="$1";
    local old_xfrm="${XFRM_IF:-$DEFAULT_XFRM_IF}" old_table="${ROUTE_TABLE:-}";
    local p1="${RULE_DNS_PRIMARY:-}" p2="${RULE_DNS_SECONDARY:-}" p3="${RULE_TUNNEL_SOURCE:-}";
    warn 'Setup failed. Restoring the complete pre-install state...';
    remove_runtime_and_files "$role" || true;
    remove_all_dragonfruit_network_rules || true;
    restore_pre_routevpn_state "$role" || true;
    delete_link_bounded "$old_xfrm" || true;
    cleanup_dragonfruit_managed_xfrm_interfaces || true;
    systemctl daemon-reload > /dev/null 2>&1 || true;
    systemctl reset-failed > /dev/null 2>&1 || true;
    if verify_managed_runtime_absent "$old_xfrm" "$old_table" "$p1" "$p2" "$p3"; then
        rm -rf "$STATE_DIR";
        success 'Rollback complete; no partial relay installation was retained.';
    else
        error "Rollback could not verify a clean state. Diagnostic backups remain in $STATE_DIR.";
        return 1;
    fi
}

route_line () 
{ 
    local target="$1" source="${2:-}";
    if [[ -n "$source" ]]; then
        ip -4 route get "$target" from "$source" 2> /dev/null | head -n 1 || true;
    else
        ip -4 route get "$target" 2> /dev/null | head -n 1 || true;
    fi
}

route_summary () 
{ 
    local target="$1" source="${2:-}" line dev via src table output;
    line=$(route_line "$target" "$source");
    [[ -n "$line" ]] || { 
        printf 'no route';
        return
    };
    dev=$(awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' <<< "$line");
    via=$(awk '{for(i=1;i<=NF;i++) if($i=="via") {print $(i+1); exit}}' <<< "$line");
    src=$(awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' <<< "$line");
    table=$(awk '{for(i=1;i<=NF;i++) if($i=="table") {print $(i+1); exit}}' <<< "$line");
    output="${dev:-unknown interface}";
    [[ -n "$via" ]] && output+=" via ${via}";
    [[ -n "$table" ]] && output+=" | table ${table}";
    [[ -n "$src" ]] && output+=" | src ${src}";
    printf '%s' "$output"
}

route_table_in_use () 
{ 
    local table="$1";
    if ip route show table "$table" 2> /dev/null | grep -q .; then
        return 0;
    fi;
    grep -RhsE "^[[:space:]]*${table}[[:space:]]+" /etc/iproute2/rt_tables /etc/iproute2/rt_tables.d 2> /dev/null | grep -q .
}

route_uses_interface () 
{ 
    local target="$1" source="${2:-}" expected="$3" line;
    line=$(route_line "$target" "$source");
    [[ "$line" == *"dev $expected"* ]]
}

rule_pref_in_use () 
{ 
    local pref="$1";
    ip rule show | awk -F: -v p="$pref" '$1 + 0 == p {found=1} END {exit !found}'
}

run_recovery () 
{ 
    load_config;
    [[ "$ROLE" == ingress ]] || { 
        error 'Recovery is available on a Client only.';
        return 1
    };
    info 'Running bounded Client recovery...';
    resolve_peer_endpoint || warn "Server endpoint ${PEER_ENDPOINT:-unknown} is not currently resolvable.";
    if start_tunnel; then
        success 'Recovery completed and the Client connection is healthy.';
        return 0;
    fi;
    error 'Recovery finished, but the Client connection still requires diagnostics.';
    return 1
}

safe_sas () 
{ 
    swanctl --list-sas 2> /dev/null || true
}

section_title ()
{
    local title="$1" width
    width=$(ui_content_width)
    printf '\n  %s%s%s%s\n' "$C_BOLD" "$C_MAGENTA" "$title" "$C_RESET" > "$TTY_OUT"
    printf '  %s%s%s\n' "$C_DIM" "$(ui_rule $'\u2500' "$width")" "$C_RESET" > "$TTY_OUT"
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

set_live_status () 
{ 
    LIVE_STATUS="$1";
    LIVE_COLOR=$(semantic_state_color "$LIVE_STATUS");
    LIVE_REASON="${2:-}"
}

confirm_fresh_ingress_install ()
{
    clear_screen
    dfr_ui_header 'CLIENT INSTALLATION | PREPARE'
    local state='READY'
    if configured_ingress; then state='REPLACE'; elif ingress_unconfigured_residual_present; then state='ATTENTION'; fi
    ui_summary_begin 'Current host state' "$state"
    if configured_ingress; then
        local current_profile current_interface
        current_profile=$(awk -F= '$1=="PROFILE_NAME" {gsub(/^[\047\042 ]+|[\047\042 ]+$/, "", $2); print $2; exit}' "$CONFIG_FILE" 2>/dev/null || true)
        current_interface=$(awk -F= '$1=="XFRM_IF" {gsub(/^[\047\042 ]+|[\047\042 ]+$/, "", $2); print $2; exit}' "$CONFIG_FILE" 2>/dev/null || true)
        ui_summary_row 'Existing Client' "${current_profile:-configured}" identity
        ui_summary_row 'Managed interface' "${current_interface:-unknown}" identity
    elif ingress_unconfigured_residual_present; then
        ui_summary_row 'Existing DFR state' 'Residual managed files/units/interfaces detected' state
    else
        ui_summary_row 'Existing DFR state' 'None · clean installation' muted
    fi
    section_title 'Protected installation transaction'
    print_check info 'Host state' 'Preserve restorable resolver, strongSwan, systemd and sysctl state.'
    print_check info 'DFR runtime' 'Remove only verified DFR-owned Client runtime and residual XFRM state.'
    print_check info 'Enrollment' 'Validate the DFR1 token before committing the new connection.'
    print_check info 'Rollback' 'Restore captured host state if the connection cannot be committed.'
    printf '\n' > "$TTY_OUT"
    confirm 'Continue with Client installation' yes
}

reset_ingress_before_setup ()
{
    hub_configured && die 'This machine is configured as a Server. Remove the Server configuration before configuring a Client.'
    local found=no iface
    if [[ -f "$CONFIG_FILE" ]]; then
        found=yes; load_config; [[ "${ROLE:-}" == ingress ]] || die 'The existing Dragon Fruit Relay configuration is not a Client configuration.'
        info 'Removing the existing Client configuration before requesting a new enrollment token...'; remove_tunnel_configuration yes
    elif ingress_unconfigured_residual_present; then
        found=yes; info 'Removing residual Dragon Fruit Relay Client state before requesting a new enrollment token...'; clean_abandoned_install_before_setup
    fi
    systemctl disable --now dragon-fruit-relay-healthcheck.timer dragon-fruit-relay-healthcheck.service dragon-fruit-relay-dns.service dragon-fruit-relay-routing.service "$CONTROL_TIMER" "$CONTROL_SERVICE" dragon-fruit-relay-xfrm.service >/dev/null 2>&1 || true
    timeout 12s swanctl --terminate --ike dragonfruit_relay >/dev/null 2>&1 || true
    systemctl stop strongswan.service >/dev/null 2>&1 || true
    remove_all_dragonfruit_network_rules || true
    cleanup_dragonfruit_managed_xfrm_interfaces || die 'One or more managed Dragon Fruit Relay XFRM interfaces could not be removed.'
    rm -f /run/dragon-fruit-relay/*.vici /run/dragon-fruit-relay/*.pid 2>/dev/null || true; rmdir /run/dragon-fruit-relay 2>/dev/null || true
    rm -rf -- "$CONFIG_DIR" "$STATE_DIR"
    systemctl daemon-reload >/dev/null 2>&1 || true; systemctl reset-failed >/dev/null 2>&1 || true
    [[ ! -e "$CONFIG_FILE" && ! -e "$HOST_CONFIG_FILE" && ! -d "$CLIENTS_DIR" ]] || die 'The previous Dragon Fruit Relay configuration could not be removed completely.'
    while IFS= read -r iface; do [[ -n "$iface" ]] || continue; die "Managed XFRM interface ${iface} is still present after the pre-setup reset."; done < <(dragonfruit_managed_xfrm_interfaces)
    [[ "$found" == yes ]] && success 'Previous Dragon Fruit Relay Client configuration and runtime state were removed completely.' || print_check pass 'Previous Client state' 'none detected'
}

validate_server_endpoint ()
{
    local value="${1,,}"
    value="${value%.}"
    validate_ipv4 "$value" && return 0
    [[ ${#value} -le 253 && "$value" == *.* ]] || return 1
    [[ "$value" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]]
}

# DFR_CLOUDFLARE_ENDPOINT_RESOLVER_V2
#
# The DFR IKE endpoint is resolved directly against Cloudflare's
# public recursive DNS. DHCP/router/system DNS is deliberately
# bypassed for this security-critical bootstrap address.
dfr_endpoint_ipv4_is_global ()
{
    local value="${1:-}"

    python3 - "$value" <<'PY_DFR_ENDPOINT_IP'
import ipaddress
import sys

try:
    ip = ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)

raise SystemExit(
    0 if ip.version == 4 and ip.is_global else 1
)
PY_DFR_ENDPOINT_IP
}

cloudflare_resolve_peer_ipv4 ()
{
    local host="${1:-}" source_ip="${2:-}" resolver answer count
    if validate_ipv4 "$host"; then
        dfr_endpoint_ipv4_is_global "$host" || return 1
        printf '%s' "$host"
        return 0
    fi
    validate_server_endpoint "$host" || return 1
    for resolver in 1.0.0.1 1.1.1.1; do
        if [[ -n "$source_ip" ]] && validate_ipv4 "$source_ip"; then
            answer=$(timeout 6s dig -4 -b "$source_ip" "@${resolver}" "$host" A +time=2 +tries=1 +short 2>/dev/null |
                awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print}' | sort -Vu)
        else
            answer=$(timeout 6s dig -4 "@${resolver}" "$host" A +time=2 +tries=1 +short 2>/dev/null |
                awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print}' | sort -Vu)
        fi
        count=$(grep -c . <<<"$answer" || true)
        [[ "$count" -eq 1 ]] || continue
        dfr_endpoint_ipv4_is_global "$answer" || continue
        printf '%s' "$answer"
        return 0
    done
    return 1
}

resolve_peer_endpoint ()
{
    load_config
    validate_server_endpoint "${PEER_ENDPOINT:-}" || return 1
    local resolved
    resolved=$(cloudflare_resolve_peer_ipv4 "$PEER_ENDPOINT" "${LOCAL_IP:-}" || true)
    [[ -n "$resolved" ]] || return 1
    PEER_PUBLIC_IP="$resolved"
    if [[ -w "$CONFIG_FILE" ]]; then
        upsert_shell_assignment "$CONFIG_FILE" PEER_PUBLIC_IP "$PEER_PUBLIC_IP"
    fi
    return 0
}

managed_set_server_endpoint ()
{
    local new_endpoint="${1,,}" old_endpoint old_ip resolved backup force_reconnect=no
    new_endpoint="${new_endpoint%.}"
    validate_server_endpoint "$new_endpoint" || { error "Invalid Server endpoint: ${new_endpoint:-empty}"; return 1; }
    load_config
    old_endpoint="${PEER_ENDPOINT:-$PEER_PUBLIC_IP}"
    old_ip="$PEER_PUBLIC_IP"
    [[ "$old_endpoint" == "$new_endpoint" ]] && return 0
    resolved=$(cloudflare_resolve_peer_ipv4 "$new_endpoint" "${LOCAL_IP:-}" || true)
    [[ -n "$resolved" ]] || { error "Server endpoint ${new_endpoint} could not be resolved to one public IPv4 address."; return 1; }
    [[ "$resolved" == "$old_ip" ]] || force_reconnect=yes
    backup="${CONFIG_FILE}.endpoint-backup.$$"
    install -m 0600 "$CONFIG_FILE" "$backup"
    upsert_shell_assignment "$CONFIG_FILE" PEER_ENDPOINT "$new_endpoint"
    upsert_shell_assignment "$CONFIG_FILE" PEER_PUBLIC_IP "$resolved"
    if managed_reconcile "$force_reconnect"; then
        rm -f -- "$backup"
        logger -t dragon-fruit-relay-control "Server endpoint synchronized: ${old_endpoint} -> ${new_endpoint} (${resolved}); reconnect=${force_reconnect}"
        return 0
    fi
    install -m 0600 "$backup" "${CONFIG_FILE}.restore.$$"
    mv -f -- "${CONFIG_FILE}.restore.$$" "$CONFIG_FILE"
    rm -f -- "$backup"
    load_config
    managed_reconcile yes >/dev/null 2>&1 || true
    error "Could not activate Server endpoint ${new_endpoint}; restored ${old_endpoint} (${old_ip})."
    return 1
}


# DFR_ENROLLMENT_TOKEN_VISIBLE_INPUT
setup_ingress ()
{
    local supplied_token="${1:-}" supplied_fallback="${2:-}" fresh_confirmed="${3:-no}" direct_public_display control_state='ATTENTION' verify_state='ATTENTION'
    if [[ "$fresh_confirmed" != yes ]] && ! confirm_fresh_ingress_install; then warn 'Client installation cancelled. No relay state was changed.'; return 0; fi
    clear_screen
    dfr_ui_header 'CLIENT INSTALLATION'
    ui_summary_begin 'Installation transaction' 'PREPARING'
    ui_summary_row 'Role' 'Ingress Client (Client)'
    ui_summary_row 'Product' 'Standalone Dragon Fruit Relay v2.1.0'
    ui_summary_row 'Safety' 'Host-state backup + rollback enabled'
    print_check info 'Previous DFR state' 'Cleaning verified Client-owned runtime...'
    reset_ingress_before_setup
    print_check pass 'Previous DFR state' 'Clean; no previous Client configuration remains.'
    backup_ingress_paths
    install_dependencies

    local token
    section_title 'Client enrollment'
    printf '  Paste the one-time DFR1 enrollment token issued by the Egress Hub.\n  DFR validates identity, endpoint, transport and tunnel allocation before commit.\n\n' > "$TTY_OUT"
    if [[ -n "$supplied_token" ]]; then token="$supplied_token"; print_check info 'Enrollment token' 'Supplied by the validated replacement/bootstrap flow.'; else token=$(prompt '  Enrollment token > '); fi
    [[ -n "$token" ]] || die 'A DFR1 enrollment token is required.'
    parse_pairing_token "$token"

    local detected_if detected_local detected_public detected_gateway
    detected_if=$(detect_default_interface); [[ -n "$detected_if" ]] || die 'No IPv4 default route was detected.'; WAN_IF="$detected_if"
    detected_local=$(detect_local_ipv4 "$WAN_IF"); [[ -n "$detected_local" ]] || die "No global IPv4 address was detected on ${WAN_IF}."; LOCAL_IP="$detected_local"
    detected_gateway=$(detect_default_gateway); [[ -n "$detected_gateway" ]] || die 'No IPv4 default gateway was detected.'; WAN_GATEWAY="$detected_gateway"
    detected_public=$(detect_public_ipv4 || true); PUBLIC_IP="${detected_public:-}"
    show_detected_network "$WAN_GATEWAY"
    if [[ -n "$supplied_fallback" ]]; then validate_ipv4 "$supplied_fallback" || die 'The supplied local DNS fallback is not a valid IPv4 address.'; DNS_FALLBACK="$supplied_fallback"; DNS_FALLBACK_MODE=manual; print_check info 'Local DNS fallback' "$DNS_FALLBACK (preserved)";
    else DNS_FALLBACK=$(prompt_ipv4_value 'Local DNS fallback (normally the local gateway/router)' "$WAN_GATEWAY"); [[ "$DNS_FALLBACK" == "$WAN_GATEWAY" ]] && DNS_FALLBACK_MODE=auto || DNS_FALLBACK_MODE=manual; fi

    ROUTE_TABLE=$(find_free_route_table) || die 'No free policy-routing table was found.'
    local prefs; mapfile -t prefs < <(find_free_rule_prefs); ((${#prefs[@]} == 3)) || die 'No free policy-rule priorities were found.'
    RULE_DNS_PRIMARY=${prefs[0]}; RULE_DNS_SECONDARY=${prefs[1]}; RULE_TUNNEL_SOURCE=${prefs[2]}
    PEER_ENDPOINT="$TOKEN_EGRESS_ENDPOINT"; PEER_PUBLIC_IP=$(cloudflare_resolve_peer_ipv4 "$PEER_ENDPOINT" "$LOCAL_IP" || true); [[ -n "$PEER_PUBLIC_IP" ]] || die "Could not resolve Server endpoint ${PEER_ENDPOINT} to one public IPv4 address."
    PROFILE_NAME="$TOKEN_PROFILE_NAME"; PORT_MODE=custom; IKE_PORT="$TOKEN_IKE_PORT"; NATT_PORT="$TOKEN_NATT_PORT"; PSK="$TOKEN_PSK"; TUNNEL_CIDR="$TOKEN_TUNNEL_CIDR"; XFRM_ID="$TOKEN_XFRM_ID"; XFRM_IF="$TOKEN_XFRM_IF"; XFRM_MTU="$TOKEN_XFRM_MTU"
    INGRESS_XFRM_CIDR="$TOKEN_INGRESS_XFRM_CIDR"; EGRESS_XFRM_CIDR="$TOKEN_EGRESS_XFRM_CIDR"; INGRESS_XFRM_IP="$TOKEN_INGRESS_XFRM_IP"; EGRESS_XFRM_IP="$TOKEN_EGRESS_XFRM_IP"; INGRESS_ID="$TOKEN_INGRESS_ID"; EGRESS_ID="$TOKEN_EGRESS_ID"; DNS_PRIMARY="$TOKEN_DNS_PRIMARY"; DNS_SECONDARY="$TOKEN_DNS_SECONDARY"
    SUBSCRIPTION_PORT="$TOKEN_SUBSCRIPTION_PORT"; CONTROL_PORT="$TOKEN_CONTROL_PORT"; MANAGED_CONTROL=yes; CONNECTION_UUID="$TOKEN_CONNECTION_UUID"; CONTROL_PROTOCOL="$TOKEN_CONTROL_PROTOCOL"; CONTROL_KEY="$TOKEN_CONTROL_KEY"; ENROLLMENT_TOKEN_HASH="$TOKEN_ENROLLMENT_HASH"
    ensure_tunnel_network_available "$TUNNEL_CIDR"; ip link show dev "$XFRM_IF" >/dev/null 2>&1 && die "Interface ${XFRM_IF} already exists. Remove the old/partial tunnel from the Removal menu first."
    local peer_route; peer_route=$(ip -4 route get "$PEER_PUBLIC_IP" 2>/dev/null || true); [[ -n "$peer_route" ]] || die "The Server public IP ${PEER_PUBLIC_IP} is not routable from this Client."; grep -q "dev ${XFRM_IF}" <<<"$peer_route" && die 'The Server public IP resolves through the proposed XFRM interface. Fix the main route first.'
    [[ "$XFRM_IF" =~ ^dfr[0-9]{4}$ ]] || die "Refusing to create a Client interface that is not dfrNNNN: ${XFRM_IF}."

    ui_summary_begin 'Enrollment plan' 'VALIDATED'
    ui_summary_row 'Connection' "$PROFILE_NAME" identity
    ui_summary_row 'Server endpoint' "$PEER_ENDPOINT" accent
    ui_summary_row 'Resolved peer' "$PEER_PUBLIC_IP" accent
    ui_summary_row 'IKE transport' "$(transport_label)"
    ui_summary_row 'XFRM interface' "$XFRM_IF · ID $XFRM_ID" identity
    ui_summary_row 'Tunnel network' "$TUNNEL_CIDR" accent
    ui_summary_row 'Client address' "$INGRESS_XFRM_CIDR" accent
    ui_summary_row 'DNS path' "$DNS_PRIMARY · $DNS_SECONDARY · fallback $DNS_FALLBACK"

    section_title 'Applying Client runtime'
    print_check info 'Managed runtime' 'Writing XFRM, strongSwan, routing, resolver and health configuration...'
    write_ingress_config; load_config
    if ! ( write_common_xfrm_files && write_strongswan_common_files && write_swanctl_ingress && write_ingress_routing_files && write_ingress_healthcheck_files && activate_ingress ); then rollback_failed_setup ingress; return 1; fi
    print_check pass 'Managed runtime' 'Runtime files installed and services activated.'
    if ! attempt_tunnel_connection; then rollback_failed_setup ingress; return 1; fi
    ping -I "$XFRM_IF" -c 1 -W 3 "$XFRM_PEER_IP" >/dev/null 2>&1 || { error 'The CHILD SA exists, but the remote XFRM peer is unreachable.'; rollback_failed_setup ingress; return 1; }
    finalize_ingress_after_tunnel || { rollback_failed_setup ingress; return 1; }
    if ensure_ingress_management_current; then
        if "$CONTROL_AGENT" --once; then control_state='READY'; else warn 'Initial CONTROL/1 enrollment needs attention; the tunnel remains operational.'; fi
    else warn 'Managed control-plane activation needs attention; the tunnel remains operational.'; fi
    if verify_ingress_paths; then verify_state='READY'; else warn 'Post-install route verification reported a warning.'; fi
    [[ -n "${PUBLIC_IP:-}" ]] && direct_public_display="$PUBLIC_IP" || direct_public_display='Unavailable · non-blocking'

    clear_screen
    dfr_ui_header 'CLIENT INSTALLATION'
    ui_summary_begin 'Installation complete' 'READY'
    ui_summary_row 'Connection' "$PROFILE_NAME" identity
    ui_summary_row 'Server endpoint' "$PEER_ENDPOINT" accent
    ui_summary_row 'Resolved peer' "$PEER_PUBLIC_IP" accent
    ui_summary_row 'IKE / CHILD SA' 'ESTABLISHED' state
    ui_summary_row 'XFRM interface' "$XFRM_IF · $INGRESS_XFRM_CIDR" identity
    ui_summary_row 'Routing table' "$ROUTE_TABLE" count
    ui_summary_row 'DNS order' "$DNS_PRIMARY · $DNS_SECONDARY · $DNS_FALLBACK"
    ui_summary_row 'Direct public IP' "$direct_public_display" accent
    ui_summary_row 'CONTROL/1' "$control_state" state
    ui_summary_row 'Route verification' "$verify_state" state
    section_title 'Next action'
    if [[ "$control_state" == READY ]]; then
        print_check pass 'Managed enrollment' 'Server management is authenticated and active.'
    else
        print_check warn 'Managed enrollment' 'Tunnel is active; CONTROL/1 can be retried from Refresh Managed Status or Repair Connection.'
    fi
    print_check info 'Management' 'Open the Client dashboard with: dragon-fruit-relay'
    DFR_SETUP_UI_ACTIVE=no
    pause_screen
    ingress_interactive_menu
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

show_ike_failure_details () 
{ 
    local transcript="$1" outbound_packets="${2:-0}" inbound_packets="${3:-0}" recent;
    section_title 'Connection failure';
    [[ -n "$transcript" ]] && printf '%s\n' "$transcript" | tail -n 35 > "$TTY_OUT";
    section_title 'Packet evidence';
    printf '  %-30s %s\n' 'IKE packets sent' "$outbound_packets" > "$TTY_OUT";
    printf '  %-30s %s\n' 'IKE replies received' "$inbound_packets" > "$TTY_OUT";
    recent=$(journalctl -u strongswan.service --since '-3 minutes' --no-pager -o cat 2> /dev/null | grep -Ei 'IKE|CHILD|AUTH|proposal|shared key|peer|retransmit|sending|received|failed|error|no matching|unreachable' | tail -n 60 || true);
    if [[ -n "$recent" ]]; then
        printf '\n%sRecent strongSwan messages:%s\n' "$C_BOLD" "$C_RESET" > "$TTY_OUT";
        printf '%s\n' "$recent" > "$TTY_OUT";
    fi;
    if grep -Eqi 'no shared key|AUTHENTICATION_FAILED|authentication failed' <<< "$transcript $recent"; then
        print_check fail 'Likely cause' 'The token/PSK or IKE identities do not match.';
    else
        if grep -Eqi 'NO_PROPOSAL_CHOSEN|no proposal chosen' <<< "$transcript $recent"; then
            print_check fail 'Likely cause' 'The peers do not agree on cryptographic proposals.';
        else
            if grep -Eqi 'no matching peer config|no matching config' <<< "$transcript $recent"; then
                print_check fail 'Likely cause' 'The Server responder configuration is missing or identities differ.';
            else
                if grep -Eqi 'network is unreachable|no route to host|unreachable' <<< "$transcript $recent"; then
                    print_check fail 'Likely cause' 'The Server public endpoint is not routable.';
                else
                    if ((outbound_packets > 0 && inbound_packets == 0)); then
                        print_check fail 'Likely cause' "Requests left this server, but ${PEER_PUBLIC_IP} sent no reply.";
                        print_check info 'Check Server path' "Public IP, $(transport_description), cloud firewall, host firewall and router forwarding.";
                    else
                        if ((inbound_packets > 0)); then
                            print_check fail 'Likely cause' 'The Server replied; inspect the authentication/configuration messages above.';
                        else
                            if ((outbound_packets == 0)); then
                                print_check fail 'Likely cause' 'No IKE packet left the Client interface.';
                                print_check info 'Check local state' 'Loaded connection, strongSwan sockets and the endpoint route.';
                            else
                                print_check fail 'Likely cause' "No usable IKE response from ${PEER_PUBLIC_IP}:${IKE_PORT}.";
                            fi;
                        fi;
                    fi;
                fi;
            fi;
        fi;
    fi
}

health_timer_next_elapse ()
{
    local unit="${1:-dragon-fruit-relay-healthcheck.timer}"
    local realtime monotonic value

    realtime=$(systemctl show "$unit" -p NextElapseUSecRealtime --value 2>/dev/null || true)
    monotonic=$(systemctl show "$unit" -p NextElapseUSecMonotonic --value 2>/dev/null || true)

    for value in "$realtime" "$monotonic"; do
        case "$value" in
            ''|0|0us|n/a|N/A|infinity|Infinity)
                ;;
            *)
                printf '%s' "$value"
                return 0
                ;;
        esac
    done

    return 1
}

health_timer_is_armed ()
{
    local unit="${1:-dragon-fruit-relay-healthcheck.timer}"
    [[ "$(systemctl show "$unit" -p ActiveState --value 2>/dev/null || true)" == active ]] || return 1
    health_timer_next_elapse "$unit" >/dev/null
}

start_health_monitor_best_effort () 
{ 
    # DFR_HEALTH_TIMER_RESILIENCE_V2
    local unit='dragon-fruit-relay-healthcheck.timer'
    local elapsed=0 state next_rt next_mono

    info 'Re-arming Health monitor timer...'

    if ! enable_managed_unit_link "$unit" timers.target; then
        warn 'Could not create the health-monitor timer enablement link. The tunnel remains usable.'
        return 0
    fi

    timeout 10s systemctl daemon-reload >> "$LOG_FILE" 2>&1 || {
        warn 'systemd did not reload the health-monitor timer. The tunnel remains usable.'
        return 0
    }

    timeout 6s systemctl reset-failed "$unit" >> "$LOG_FILE" 2>&1 || true

    # restart, rather than start, is intentional.  An already-active but
    # incorrectly armed timer must be forced to obtain a fresh monotonic
    # next-elapse point.
    if ! timeout 8s systemctl restart --no-block "$unit" >> "$LOG_FILE" 2>&1; then
        warn 'The health-monitor timer could not be re-armed. The tunnel remains usable.'
        return 0
    fi

    while ((elapsed < 10)); do
        state=$(systemctl is-active "$unit" 2>/dev/null || true)
        next_rt=$(systemctl show "$unit" -p NextElapseUSecRealtime --value 2>/dev/null || true)
        next_mono=$(systemctl show "$unit" -p NextElapseUSecMonotonic --value 2>/dev/null || true)

        if [[ "$state" == active ]] && {
            [[ -n "$next_rt" && "$next_rt" != 0 && "$next_rt" != n/a ]] ||
            [[ -n "$next_mono" && "$next_mono" != 0 && "$next_mono" != n/a ]]
        }; then
            success 'Health monitor timer is active and armed.'
            return 0
        fi

        [[ "$state" == failed ]] && break
        sleep 1
        elapsed=$((elapsed + 1))
    done

    warn "Health monitor timer is ${state:-inactive} or has no scheduled next run. The active tunnel is preserved; run Repair to retry monitor activation."
    return 0
}

start_tunnel ()
{
    load_config
    [[ "$ROLE" == ingress ]] || { error 'This start path is only for a Client.'; return 1; }
    section_title 'Starting client connection'
    resolve_peer_endpoint || { error "Could not resolve Server endpoint ${PEER_ENDPOINT:-unknown}."; return 1; }
    load_config
    print_check info 'Stage 1 of 5' 'Reconstruct managed files and units'; ensure_ingress_runtime_files || return 1
    print_check info 'Stage 2 of 5' 'Start XFRM interface and strongSwan'; start_xfrm_checked || return 1; start_unit_checked strongswan.service 'strongSwan service' || return 1
    print_check info 'Stage 3 of 5' 'Load and negotiate IKE / CHILD SA'; load_strongswan_checked || return 1
    start_health_monitor_best_effort || true
    attempt_tunnel_connection || return 1
    print_check info 'Stage 4 of 5' 'Verify encrypted peer reachability'
    ping -I "$XFRM_IF" -c 1 -W 3 "$XFRM_PEER_IP" >/dev/null 2>&1 || { error 'IKE is established, but the remote XFRM peer is unreachable.'; return 1; }
    print_check pass 'Encrypted peer' "$XFRM_PEER_IP responds through $XFRM_IF"
    print_check info 'Stage 5 of 5' 'Activate routing, resolver and health monitor'; finalize_ingress_after_tunnel || return 1
    success 'Client connection start sequence completed.'
}

start_unit_checked () 
{ 
    local unit="$1" description="$2" elapsed=0 state job;
    info "Starting ${description}...";
    if [[ -f "${UNIT_DIR}/${unit}" ]]; then
        if [[ "$unit" == *.timer ]]; then
            enable_managed_unit_link "$unit" timers.target || true;
        else
            if grep -q '^WantedBy=multi-user.target$' "${UNIT_DIR}/${unit}" 2> /dev/null; then
                enable_managed_unit_link "$unit" multi-user.target || true;
            fi;
        fi;
    fi;
    timeout 10s systemctl enable "$unit" >> "$LOG_FILE" 2>&1 || true;
    timeout 10s systemctl reset-failed "$unit" >> "$LOG_FILE" 2>&1 || true;
    if ! timeout 10s systemctl restart --no-block "$unit" >> "$LOG_FILE" 2>&1; then
        error "${description} could not be queued for startup: ${unit}";
        return 1;
    fi;
    while ((elapsed < SYSTEMD_OPERATION_TIMEOUT_SECONDS)); do
        state=$(systemctl is-active "$unit" 2> /dev/null || true);
        job=$(systemctl show "$unit" -p Job --value 2> /dev/null || true);
        if [[ "$state" == active && ( -z "$job" || "$job" == 0 ) ]]; then
            success "${description} is active.";
            return 0;
        fi;
        if [[ "$state" == failed ]]; then
            break;
        fi;
        if [[ ( -z "$job" || "$job" == 0 ) && "$state" != activating && "$state" != deactivating ]]; then
            break;
        fi;
        sleep 1;
        elapsed=$((elapsed + 1));
    done;
    error "${description} did not become active within ${SYSTEMD_OPERATION_TIMEOUT_SECONDS}s: ${unit}";
    timeout 5s systemctl stop --no-block "$unit" > /dev/null 2>&1 || true;
    systemctl status "$unit" --no-pager -l 2>&1 | tail -n 60 > "$TTY_OUT" || true;
    journalctl -u "$unit" -n 60 --no-pager -l 2>&1 > "$TTY_OUT" || true;
    return 1
}

start_xfrm_checked () 
{ 
    local unit='dragon-fruit-relay-xfrm.service' state job elapsed=0;
    info 'Starting XFRM interface service...';
    enable_managed_unit_link "$unit" multi-user.target || true;
    timeout 8s systemctl enable "$unit" >> "$LOG_FILE" 2>&1 || true;
    state=$(systemctl is-active "$unit" 2> /dev/null || true);
    job=$(systemctl show "$unit" -p Job --value 2> /dev/null || true);
    if [[ "$state" == deactivating || "$state" == activating ]]; then
        [[ "$job" =~ ^[0-9]+$ && "$job" != 0 ]] && timeout 4s systemctl cancel "$job" >> "$LOG_FILE" 2>&1 || true;
    fi;
    timeout 5s systemctl reset-failed "$unit" >> "$LOG_FILE" 2>&1 || true;
    if ! timeout 12s "$LIB_DIR/xfrm-up" >> "$LOG_FILE" 2>&1; then
        error 'The managed XFRM interface could not be created or refreshed.';
        return 1;
    fi;
    timeout 8s systemctl start --no-block "$unit" >> "$LOG_FILE" 2>&1 || true;
    while ((elapsed < 12)); do
        state=$(systemctl is-active "$unit" 2> /dev/null || true);
        if [[ "$state" == active ]] && xfrm_runtime_ready; then
            success 'XFRM interface service is active.';
            return 0;
        fi;
        if xfrm_runtime_ready && [[ "$state" != deactivating ]]; then
            warn "XFRM interface $XFRM_IF is ready, but systemd reports '$state'. Continuing with the working data path.";
            return 0;
        fi;
        sleep 1;
        elapsed=$((elapsed + 1));
    done;
    if xfrm_runtime_ready; then
        warn "XFRM interface $XFRM_IF is ready, but the old systemd job is still clearing. Continuing without restarting the unit.";
        return 0;
    fi;
    error 'The XFRM interface did not become ready within the allowed time.';
    systemctl status "$unit" --no-pager -l 2>&1 | tail -n 60 > "$TTY_OUT" || true;
    return 1
}

stop_tunnel () 
{ 
    load_config;
    confirm 'Temporarily stop the client connection now? It remains enabled for the next boot.' no || return 0;
    timeout 12s systemctl stop dragon-fruit-relay-healthcheck.timer dragon-fruit-relay-healthcheck.service > /dev/null 2>&1 || true;
    timeout 12s systemctl stop dragon-fruit-relay-dns.service dragon-fruit-relay-routing.service > /dev/null 2>&1 || true;
    timeout 12s swanctl --terminate --ike dragonfruit_relay > /dev/null 2>&1 || true;
    timeout 12s systemctl stop strongswan.service dragon-fruit-relay-xfrm.service > /dev/null 2>&1 || true;
    success 'The client connection is stopped for the current boot.'
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


uninstall_routevpn ()
{
    if [[ ! -f "$CONFIG_FILE" ]]; then
        ingress_unconfigured_residual_present || die 'No Dragon Fruit Relay installation or residual state was found.'
        confirm 'Remove all residual Dragon Fruit Relay state and restore available backups?' no || return 0
        clean_abandoned_install_before_setup; remove_added_packages; rm -rf "$STATE_DIR" "$CONFIG_DIR"; remove_cli_command
        success 'Residual Dragon Fruit Relay state and the management command were completely removed.'; return 0
    fi
    load_config; local old_role="$ROLE"; confirm 'Completely uninstall Dragon Fruit Relay and restore original state?' no || return 0
    remove_runtime_and_files "$old_role"; restore_pre_routevpn_state "$old_role"; remove_added_packages; rm -rf "$STATE_DIR" "$CONFIG_DIR"; remove_cli_command; systemctl daemon-reload >/dev/null 2>&1 || true
    success 'Dragon Fruit Relay, its management command, and all managed state were removed; saved pre-install host state was restored where available.'
}

unit_state () 
{ 
    systemctl is-active "$1" 2> /dev/null || true
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

verify_ingress_paths () 
{ 
    load_config;
    info "Verifying Client routing paths...";
    local route_output direct_ip tunnel_ip;
    for route_output in "$(ip -4 route get "$PEER_PUBLIC_IP" 2> /dev/null || true)" "$(ip -4 route get "$DNS_PRIMARY" from "$XFRM_LOCAL_IP" 2> /dev/null || true)" "$(ip -4 route get "$DNS_SECONDARY" from "$XFRM_LOCAL_IP" 2> /dev/null || true)" "$(ip -4 route get 9.9.9.9 from "$XFRM_LOCAL_IP" 2> /dev/null || true)";
    do
        [[ -n "$route_output" ]] && printf '%s
' "$route_output" | tee -a "$LOG_FILE" > "$TTY_OUT" || true;
    done;
    if ping -I "$XFRM_IF" -c 2 -W 3 "$XFRM_PEER_IP" > /dev/null 2>&1; then
        success "The remote XFRM address responds.";
    else
        warn "The remote XFRM address did not respond to ping.";
    fi;
    direct_ip=$(detect_public_ipv4 "$WAN_IF" || true);
    tunnel_ip=$(detect_public_ipv4 "$XFRM_LOCAL_IP" || true);
    [[ -n "$direct_ip" ]] && info "Direct-path public IP consensus: ${direct_ip}" || warn 'Direct-path public IP was not reported because lookup services did not agree.';
    [[ -n "$tunnel_ip" ]] && info "Tunnel public IP consensus: ${tunnel_ip}" || warn 'Tunnel public IP was not reported because lookup services did not agree.';
    return 0
}

verify_managed_runtime_absent () 
{ 
    local xfrm_if="${1:-}" route_table="${2:-}" p1="${3:-}" p2="${4:-}" p3="${5:-}";
    local failed=0 pref path target;
    if [[ -n "$xfrm_if" ]] && ip link show dev "$xfrm_if" > /dev/null 2>&1; then
        error "Cleanup verification failed: interface $xfrm_if remains.";
        failed=1;
    fi;
    for pref in "$p1" "$p2" "$p3";
    do
        [[ "$pref" =~ ^[0-9]+$ ]] || continue;
        if ip -4 rule show | awk -F: -v x="$pref" '$1+0==x {found=1} END {exit !found}'; then
            error "Cleanup verification failed: policy rule $pref remains.";
            failed=1;
        fi;
    done;
    if [[ "$route_table" =~ ^[0-9]+$ ]] && ip -4 route show table "$route_table" 2> /dev/null | grep -q .; then
        error "Cleanup verification failed: routing table $route_table is not empty.";
        failed=1;
    fi;
    if iptables-save 2> /dev/null | grep -q 'dragon-fruit-relay-'; then
        error 'Cleanup verification failed: tagged iptables rules remain.';
        failed=1;
    fi;
    if [[ -d "$CONFIG_DIR" ]]; then
        error "Cleanup verification failed: $CONFIG_DIR remains.";
        failed=1;
    fi;
    if [[ -e "$INGRESS_SWANCTL_MARKER" || -e "$INGRESS_SWANCTL_CANONICAL" || -L "$INGRESS_SWANCTL_CANONICAL" ]]; then
        error "Cleanup verification failed: managed Client swanctl namespace remains at $INGRESS_SWANCTL_DIR.";
        failed=1;
    fi;
    for path in "$SWANCTL_FILE" "$INGRESS_SWANCTL_CANONICAL" "$STRONGSWAN_ROUTE_FILE" "$STRONGSWAN_OVERRIDE_FILE" "$SYSCTL_FILE" "$SYSTEMD_DIR"/dragon-fruit-relay-*.service "$SYSTEMD_DIR"/dragon-fruit-relay-*.timer;
    do
        [[ -L "$path" ]] || continue;
        target=$(readlink -f "$path" 2> /dev/null || true);
        if [[ "$target" == "$CONFIG_DIR"/* ]]; then
            error "Cleanup verification failed: stale managed symlink $path remains.";
            failed=1;
        fi;
    done;
    if [[ -L /etc/resolv.conf && "$(readlink -f /etc/resolv.conf 2> /dev/null || true)" == "$RESOLVER_MANAGED_FILE" ]]; then
        error 'Cleanup verification failed: /etc/resolv.conf still points to the managed resolver.';
        failed=1;
    fi;
    ((failed == 0))
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

write_common_xfrm_files () 
{ 
    ensure_managed_layout;
    cat > "$LIB_DIR/xfrm-up" <<'EOF_SCRIPT'
#!/usr/bin/env bash
# Managed by Dragon Fruit Relay. Creates the route-based XFRM interface.
set -Eeuo pipefail
# shellcheck disable=SC1091
source /etc/dragon-fruit-relay/dragon-fruit-relay.conf

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

    cat > "$LIB_DIR/xfrm-down" <<'EOF_SCRIPT'
#!/usr/bin/env bash
# Managed by Dragon Fruit Relay. Normal service stops leave the XFRM device
# present but administratively down. This makes restart/reconfigure idempotent
# and avoids kernel/netlink delete operations blocking a systemd stop job.
set -Eeuo pipefail
# shellcheck disable=SC1091
source /etc/dragon-fruit-relay/dragon-fruit-relay.conf
ip link set "$XFRM_IF" down 2>/dev/null || true
exit 0
EOF_SCRIPT

    chmod 750 "$LIB_DIR/xfrm-up" "$LIB_DIR/xfrm-down";
    cat > "$UNIT_DIR/dragon-fruit-relay-xfrm.service" <<EOF_UNIT
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

    chmod 0644 "$UNIT_DIR/dragon-fruit-relay-xfrm.service";
    link_managed_unit dragon-fruit-relay-xfrm.service
}

write_diagnostic_report () 
{ 
    load_config;
    local report="${LOG_DIR}/diagnostics-$(date +%Y%m%d-%H%M%S).txt";
    mkdir -p "$LOG_DIR";
    { 
        printf 'Dragon Fruit Relay diagnostic report\n';
        printf 'Generated: %s\n' "$(date -Is)";
        printf 'Installer version: %s\n\n' "$APP_VERSION";
        printf '%s\n' '=== SYSTEM ===';
        uname -a;
        cat /etc/os-release;
        printf '\n%s\n' '=== CONFIGURATION (PSK REDACTED) ===';
        sed -E 's/^PSK=.*/PSK=[REDACTED]/' "$CONFIG_FILE";
        printf '\n%s\n' '=== SERVICE STATES ===';
        systemctl show dragon-fruit-relay-xfrm.service strongswan.service -p Id -p LoadState -p ActiveState -p SubState -p UnitFileState -p Result 2>&1 || true;
        if [[ "$ROLE" == 'ingress' ]]; then
            systemctl show dragon-fruit-relay-routing.service dragon-fruit-relay-dns.service dragon-fruit-relay-healthcheck.timer -p Id -p LoadState -p ActiveState -p SubState -p UnitFileState -p Result 2>&1 || true;
        else
            systemctl show netfilter-persistent.service -p Id -p LoadState -p ActiveState -p SubState -p UnitFileState -p Result 2>&1 || true;
        fi;
        printf '\n%s\n' '=== STRONGSWAN SAs ===';
        swanctl --list-sas 2>&1 || true;
        printf '\n%s\n' '=== XFRM INTERFACE ===';
        ip -d link show dev "$XFRM_IF" 2>&1 || true;
        ip -4 address show dev "$XFRM_IF" 2>&1 || true;
        ip -s link show dev "$XFRM_IF" 2>&1 || true;
        printf '\n%s\n' '=== XFRM STATE AND POLICY ===';
        ip xfrm state 2>&1 | sed -E 's/(auth-trunc|enc|aead) .*/\1 [REDACTED]/' || true;
        ip xfrm policy 2>&1 || true;
        printf '\n%s\n' '=== ROUTING ===';
        ip rule show 2>&1 || true;
        ip -4 route show table main 2>&1 || true;
        [[ "$ROLE" == 'ingress' ]] && ip route show table "$ROUTE_TABLE" 2>&1 || true;
        printf '\n%s\n' '=== RESOLVER ===';
        cat /etc/resolv.conf 2>&1 || true;
        printf '\n%s\n' '=== FIREWALL / NAT ===';
        iptables-save 2>&1 | grep -E 'dragon-fruit-relay|^\*|^COMMIT|^-P' || true;
        printf '\n%s\n' '=== RECENT JOURNAL ===';
        journalctl -u strongswan.service -u dragon-fruit-relay-xfrm.service --since '-2 hours' --no-pager -n 150 2>&1 || true;
        printf '\n%s\n' '=== INSTALLER LOG ===';
        tail -n 150 "$LOG_FILE" 2>&1 || true
    } > "$report";
    chmod 600 "$report";
    success "Diagnostic report written to $report"
}

write_ingress_config ()
{
    ensure_managed_layout
    {
        cat <<'EOF_CONFIG'
# Dragon Fruit Relay Client configuration
# Managed file. Shell syntax is used because helper scripts source it directly.
EOF_CONFIG
        printf 'PRODUCT_ID=%q\nPRODUCT_LINEAGE=%q\nCONFIG_SCHEMA=%q\nMANAGED_BY_VERSION=%q\nROLE=%q\nPROFILE_NAME=%q\n' "$DFR_PRODUCT_ID" "$DFR_PRODUCT_LINEAGE" "$CONFIG_SCHEMA_CURRENT" "$APP_VERSION" 'ingress' "$PROFILE_NAME"
        printf 'WAN_IF=%q\nWAN_GATEWAY=%q\nLOCAL_IP=%q\nPUBLIC_IP=%q\nPEER_ENDPOINT=%q\nPEER_PUBLIC_IP=%q\n' "$WAN_IF" "$WAN_GATEWAY" "$LOCAL_IP" "$PUBLIC_IP" "$PEER_ENDPOINT" "$PEER_PUBLIC_IP"
        printf 'MANAGED_CONTROL=%q\nCONNECTION_UUID=%q\nCONTROL_PROTOCOL=%q\nENROLLMENT_TOKEN_HASH=%q\n' 'yes' "$CONNECTION_UUID" "$CONTROL_PROTOCOL" "$ENROLLMENT_TOKEN_HASH"
        printf 'SUBSCRIPTION_PORT=%q\nCONTROL_PORT=%q\n' "$SUBSCRIPTION_PORT" "$CONTROL_PORT"
        printf 'PORT_MODE=%q\nIKE_PORT=%q\nNATT_PORT=%q\n' 'custom' "$IKE_PORT" "$NATT_PORT"
        printf 'TUNNEL_CIDR=%q\nXFRM_IF=%q\nXFRM_ID=%q\nXFRM_MTU=%q\n' "$TUNNEL_CIDR" "$XFRM_IF" "$XFRM_ID" "$XFRM_MTU"
        printf 'XFRM_LOCAL_CIDR=%q\nXFRM_LOCAL_IP=%q\nXFRM_PEER_IP=%q\n' "$INGRESS_XFRM_CIDR" "$INGRESS_XFRM_IP" "$EGRESS_XFRM_IP"
        printf 'INGRESS_XFRM_CIDR=%q\nEGRESS_XFRM_CIDR=%q\nINGRESS_XFRM_IP=%q\nEGRESS_XFRM_IP=%q\n' "$INGRESS_XFRM_CIDR" "$EGRESS_XFRM_CIDR" "$INGRESS_XFRM_IP" "$EGRESS_XFRM_IP"
        printf 'INGRESS_ID=%q\nEGRESS_ID=%q\n' "$INGRESS_ID" "$EGRESS_ID"
        printf 'DNS_PRIMARY=%q\nDNS_SECONDARY=%q\nDNS_FALLBACK=%q\nDNS_FALLBACK_MODE=%q\n' "$DNS_PRIMARY" "$DNS_SECONDARY" "$DNS_FALLBACK" "${DNS_FALLBACK_MODE:-manual}"
        printf 'ROUTE_TABLE=%q\nRULE_DNS_PRIMARY=%q\nRULE_DNS_SECONDARY=%q\nRULE_TUNNEL_SOURCE=%q\n' "$ROUTE_TABLE" "$RULE_DNS_PRIMARY" "$RULE_DNS_SECONDARY" "$RULE_TUNNEL_SOURCE"
        printf 'PSK=%q\nCONTROL_KEY=%q\n' "$PSK" "$CONTROL_KEY"
    } > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"; write_managed_readme; install_self_copy
}

write_ingress_dns_files () 
{ 
    local apply_now="${1:-yes}";
    ensure_managed_layout;
    cat > "$LIB_DIR/dns-apply" <<'EOF_DNS_APPLY_204'
#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck disable=SC1091
source /etc/dragon-fruit-relay/dragon-fruit-relay.conf
# /etc/resolv.conf is a symlink into this tree. Keep both directories
# searchable by unprivileged package helpers without allowing directory lists.
install -d -m 0751 /etc/dragon-fruit-relay
install -d -m 0751 /etc/dragon-fruit-relay/resolver
tmp=$(mktemp /etc/dragon-fruit-relay/resolver/.resolv.conf.XXXXXX)
trap 'rm -f "$tmp"' EXIT
{
    echo '# Managed by Dragon Fruit Relay.'
    echo '# Public resolvers use the encrypted egress; local DNS is timeout fallback.'
    echo 'options timeout:1 attempts:1'
    echo "nameserver $DNS_PRIMARY"
    echo "nameserver $DNS_SECONDARY"
    [[ -n "${DNS_FALLBACK:-}" ]] && echo "nameserver $DNS_FALLBACK"
} >"$tmp"
install -m 0644 "$tmp" /etc/dragon-fruit-relay/resolver/resolv.conf
rm -f /etc/resolv.conf
ln -s /etc/dragon-fruit-relay/resolver/resolv.conf /etc/resolv.conf
[[ "$(readlink -f /etc/resolv.conf 2>/dev/null || true)" == /etc/dragon-fruit-relay/resolver/resolv.conf ]]
EOF_DNS_APPLY_204

    chmod 0750 "$LIB_DIR/dns-apply";
    cat > "$UNIT_DIR/dragon-fruit-relay-dns.service" <<EOF_DNS_UNIT_204
# Managed by Dragon Fruit Relay.
[Unit]
Description=Apply Dragon Fruit Relay static DNS configuration
Requires=dragon-fruit-relay-routing.service
After=network-online.target dragon-fruit-relay-routing.service

[Service]
Type=oneshot
ExecStart=${LIB_DIR}/dns-apply
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_DNS_UNIT_204

    chmod 0644 "$UNIT_DIR/dragon-fruit-relay-dns.service";
    link_managed_unit dragon-fruit-relay-dns.service;
    if [[ -f /etc/nsswitch.conf ]]; then
        if grep -q '^hosts:' /etc/nsswitch.conf; then
            sed -i 's/^hosts:.*/hosts: files dns/' /etc/nsswitch.conf;
        else
            printf '\nhosts: files dns\n' >> /etc/nsswitch.conf;
        fi;
    fi;
    if [[ "$apply_now" == yes ]]; then
        "$LIB_DIR/dns-apply"
    fi
    return 0
}

write_ingress_healthcheck_files () 
{ 
    ensure_managed_layout;
    write_subscription_client_files;
    cat > "$LIB_DIR/healthcheck" <<'EOF_HEALTHCHECK_204'
#!/usr/bin/env bash
set -u
# shellcheck disable=SC1091
source /etc/dragon-fruit-relay/dragon-fruit-relay.conf
endpoint_changed=no
refresh_endpoint() {
    [[ -n "${PEER_ENDPOINT:-}" ]] ||
        PEER_ENDPOINT="${PEER_PUBLIC_IP:-}"

    if [[ "$PEER_ENDPOINT" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 0
    fi

    local resolver resolved count

    resolved=''

    for resolver in 1.0.0.1 1.1.1.1; do

        resolved=$(
            timeout 6s dig \
                -4 \
                -b "$LOCAL_IP" \
                "@${resolver}" \
                "$PEER_ENDPOINT" \
                A \
                +time=2 \
                +tries=1 \
                +short \
                2>/dev/null |
            awk '
                /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
                    print
                }
            ' |
            sort -Vu
        )

        count=$(grep -c . <<<"$resolved" || true)

        [[ "$count" -eq 1 ]] || {
            resolved=''
            continue
        }

        if python3 - "$resolved" <<'PY_HC_GLOBAL'
import ipaddress
import sys

try:
    ip = ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)

raise SystemExit(
    0 if ip.version == 4 and ip.is_global else 1
)
PY_HC_GLOBAL
        then
            break
        fi

        resolved=''
    done

    [[ -n "$resolved" ]] || return 1

    if [[ "$resolved" != "${PEER_PUBLIC_IP:-}" ]]; then

        python3 - \
            /etc/dragon-fruit-relay/dragon-fruit-relay.conf \
            "$resolved" <<'PY_HC_ENDPOINT'
from pathlib import Path
import sys

p = Path(sys.argv[1])
value = sys.argv[2]

lines = p.read_text().splitlines()
out = []
found = False

for line in lines:
    if line.startswith("PEER_PUBLIC_IP="):
        out.append("PEER_PUBLIC_IP=" + value)
        found = True
    else:
        out.append(line)

if not found:
    out.append("PEER_PUBLIC_IP=" + value)

tmp = p.with_suffix(".endpoint.tmp")
tmp.write_text("\n".join(out) + "\n")
tmp.chmod(0o600)
tmp.replace(p)
PY_HC_ENDPOINT

        endpoint_changed=yes
        logger -t dragon-fruit-relay-healthcheck \
            "Cloudflare DNS moved Server endpoint $PEER_ENDPOINT to $resolved"
    fi

    return 0
}

refresh_endpoint || logger -t dragon-fruit-relay-healthcheck "Unable to resolve Server endpoint ${PEER_ENDPOINT:-unknown}"
# shellcheck disable=SC1091
source /etc/dragon-fruit-relay/dragon-fruit-relay.conf
if [[ "$endpoint_changed" == yes ]]; then
    logger -t dragon-fruit-relay-healthcheck 'Endpoint address changed; rebuilding managed runtime and reconnecting to the new peer.'
    timeout 180s env DFR_INTERNAL_NO_MAIN_LOCK=1 /usr/local/sbin/dragon-fruit-relay _managed-reconcile yes >/dev/null 2>&1 && exit 0
    logger -t dragon-fruit-relay-healthcheck 'Managed endpoint retarget failed; continuing with normal recovery.'
fi

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
    [[ "$(readlink -f /etc/resolv.conf 2>/dev/null || true)" == /etc/dragon-fruit-relay/resolver/resolv.conf ]] || return 1
    [[ "$(stat -c '%a' /etc/dragon-fruit-relay 2>/dev/null || true)" == 751 ]] || return 1
    [[ "$(stat -c '%a' /etc/dragon-fruit-relay/resolver 2>/dev/null || true)" == 751 ]] || return 1
    [[ "$(stat -c '%a' /etc/dragon-fruit-relay/resolver/resolv.conf 2>/dev/null || true)" == 644 ]] || return 1
    awk -v primary="$DNS_PRIMARY" -v secondary="$DNS_SECONDARY" '
        $1 == "nameserver" && $2 == primary { primary_found = 1 }
        $1 == "nameserver" && $2 == secondary { secondary_found = 1 }
        END { exit(primary_found && secondary_found ? 0 : 1) }
    ' /etc/resolv.conf
}
activate_data_path() {
    timeout 15s systemctl start dragon-fruit-relay-routing.service >/dev/null 2>&1 || return 1
    if resolver_runtime_ok; then
        timeout 15s systemctl start dragon-fruit-relay-dns.service >/dev/null 2>&1 || return 1
    else
        logger -t dragon-fruit-relay-healthcheck '/etc/resolv.conf was replaced; restarting the managed DNS service'
        timeout 15s systemctl restart dragon-fruit-relay-dns.service >/dev/null 2>&1 || return 1
    fi
}
if healthy; then
    activate_data_path || true
    /etc/dragon-fruit-relay/bin/subscription-refresh >/dev/null 2>&1 || true
    exit 0
fi
logger -t dragon-fruit-relay-healthcheck 'Tunnel unhealthy; initiating CHILD SA'
timeout 12s swanctl --load-all --noprompt --file /etc/swanctl/dragon-fruit-relay/ingress/swanctl.conf >/dev/null 2>&1 || true
timeout 15s swanctl --initiate --child tunnel >/dev/null 2>&1 || true
sleep 2
if healthy; then
    activate_data_path || true
    /etc/dragon-fruit-relay/bin/subscription-refresh >/dev/null 2>&1 || true
    exit 0
fi
logger -t dragon-fruit-relay-healthcheck 'Tunnel still unhealthy; restarting strongSwan'
timeout 20s systemctl restart strongswan.service >/dev/null 2>&1 || true
sleep 2
timeout 12s swanctl --load-all --noprompt --file /etc/swanctl/dragon-fruit-relay/ingress/swanctl.conf >/dev/null 2>&1 || true
timeout 15s swanctl --initiate --child tunnel >/dev/null 2>&1 || true
sleep 2
healthy && { activate_data_path || true; /etc/dragon-fruit-relay/bin/subscription-refresh >/dev/null 2>&1 || true; exit 0; }
exit 1
EOF_HEALTHCHECK_204

    chmod 0750 "$LIB_DIR/healthcheck";
    cat > "$UNIT_DIR/dragon-fruit-relay-healthcheck.service" <<EOF_HEALTH_UNIT_204
# Managed by Dragon Fruit Relay.
[Unit]
Description=Check and recover the Dragon Fruit Relay ingress tunnel
Requires=dragon-fruit-relay-xfrm.service
After=dragon-fruit-relay-xfrm.service strongswan.service

[Service]
Type=oneshot
TimeoutStartSec=55
ExecStart=${LIB_DIR}/healthcheck
EOF_HEALTH_UNIT_204

    cat > "$UNIT_DIR/dragon-fruit-relay-healthcheck.timer" <<'EOF_HEALTH_TIMER_204'
# Managed by Dragon Fruit Relay.
[Unit]
Description=Run Dragon Fruit Relay ingress health checks

[Timer]
# DFR_HEALTH_TIMER_RESILIENCE_V2
OnActiveSec=45s
OnUnitActiveSec=60s
AccuracySec=5s
Unit=dragon-fruit-relay-healthcheck.service

[Install]
WantedBy=timers.target
EOF_HEALTH_TIMER_204

    chmod 0644 "$UNIT_DIR/dragon-fruit-relay-healthcheck.service" "$UNIT_DIR/dragon-fruit-relay-healthcheck.timer";
    link_managed_unit dragon-fruit-relay-healthcheck.service;
    link_managed_unit dragon-fruit-relay-healthcheck.timer;
}

write_ingress_routing_files () 
{ 
    ensure_managed_layout;
    cat > "$LIB_DIR/routing-apply" <<'EOF_SCRIPT'
#!/usr/bin/env bash
# Managed by Dragon Fruit Relay. Applies deterministic selective routing.
set -Eeuo pipefail
# shellcheck disable=SC1091
source /etc/dragon-fruit-relay/dragon-fruit-relay.conf

fail() {
    echo "dragon-fruit-relay-routing: $*" >&2
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

    cat > "$LIB_DIR/routing-remove" <<'EOF_SCRIPT'
#!/usr/bin/env bash
# Managed by Dragon Fruit Relay. Removes only its policy rules and table.
set -Eeuo pipefail
# shellcheck disable=SC1091
source /etc/dragon-fruit-relay/dragon-fruit-relay.conf
ip -4 rule del pref "$RULE_DNS_PRIMARY" 2>/dev/null || true
ip -4 rule del pref "$RULE_DNS_SECONDARY" 2>/dev/null || true
ip -4 rule del pref "$RULE_TUNNEL_SOURCE" 2>/dev/null || true
ip -4 route flush table "$ROUTE_TABLE" 2>/dev/null || true
EOF_SCRIPT

    chmod 750 "$LIB_DIR/routing-apply" "$LIB_DIR/routing-remove";
    cat > "$UNIT_DIR/dragon-fruit-relay-routing.service" <<EOF_UNIT
# Managed by Dragon Fruit Relay.
[Unit]
Description=Dragon Fruit Relay selective policy routing
Requires=dragon-fruit-relay-xfrm.service
After=dragon-fruit-relay-xfrm.service strongswan.service

[Service]
Type=oneshot
ExecStart=${LIB_DIR}/routing-apply
ExecStop=${LIB_DIR}/routing-remove
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_UNIT

    chmod 0644 "$UNIT_DIR/dragon-fruit-relay-routing.service";
    link_managed_unit dragon-fruit-relay-routing.service
}

write_managed_readme ()
{
    cat > "$MANAGED_README" <<EOF_MANAGED_README
Dragon Fruit Relay managed Client directory
===========================================
Release:                  ${APP_VERSION}
Client config schema:     ${CONFIG_SCHEMA_CURRENT}
Enrollment-token version: ${PROFILE_TOKEN_VERSION}
Subscription protocol:    ${SUBSCRIPTION_PROTOCOL_VERSION}
CONTROL protocol:         ${CONTROL_PROTOCOL_VERSION}

This node is a Dragon Fruit Relay Ingress Client. The Server endpoint may be
an IPv4 address or DNS hostname. The encrypted XFRM tunnel carries selected
traffic plus authenticated CONTROL/1 and subscription status communication.

Use the Dragon Fruit Relay UI or CLI to repair, reconnect, update, remove, or
inspect this Client. Generated files should not be edited by hand.
EOF_MANAGED_README
    chmod 0640 "$MANAGED_README"
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

xfrm_runtime_ready () 
{ 
    local details expected_hex;
    ip link show dev "$XFRM_IF" > /dev/null 2>&1 || return 1;
    details=$(ip -d link show dev "$XFRM_IF" 2> /dev/null || true);
    grep -q 'xfrm' <<< "$details" || return 1;
    expected_hex=$(printf '0x%x' "$XFRM_ID");
    grep -Eq "if_id (${XFRM_ID}|${expected_hex})([[:space:]]|$)" <<< "$details" || return 1;
    ip -4 address show dev "$XFRM_IF" 2> /dev/null | grep -Fq "${XFRM_LOCAL_CIDR%/*}/" || return 1
}


# ---------------------------------------------------------------------------
# Pairing-token and custom-port transport overrides.
# ---------------------------------------------------------------------------
load_config() {
    [[ -f "$CONFIG_FILE" ]] || die 'Dragon Fruit Relay is not configured on this node.'
    unset PRODUCT_ID PRODUCT_LINEAGE CONFIG_SCHEMA MANAGED_BY_VERSION ROLE PROFILE_NAME WAN_IF WAN_GATEWAY LOCAL_IP PUBLIC_IP PEER_ENDPOINT PEER_PUBLIC_IP
    unset PORT_MODE UDP_PORT IKE_PORT NATT_PORT TUNNEL_CIDR XFRM_IF XFRM_ID XFRM_MTU XFRM_LOCAL_CIDR XFRM_LOCAL_IP XFRM_PEER_IP
    unset INGRESS_XFRM_CIDR EGRESS_XFRM_CIDR INGRESS_XFRM_IP EGRESS_XFRM_IP INGRESS_ID EGRESS_ID DNS_PRIMARY DNS_SECONDARY DNS_FALLBACK DNS_FALLBACK_MODE
    unset ROUTE_TABLE RULE_DNS_PRIMARY RULE_DNS_SECONDARY RULE_TUNNEL_SOURCE PSK CONNECTION_UUID CONTROL_KEY CONTROL_PROTOCOL MANAGED_CONTROL ENROLLMENT_TOKEN_HASH SUBSCRIPTION_PORT CONTROL_PORT
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    [[ "${PRODUCT_ID:-}" == "$DFR_PRODUCT_ID" && "${PRODUCT_LINEAGE:-}" == "$DFR_PRODUCT_LINEAGE" ]] || die "This Client configuration is not from the standalone Dragon Fruit Relay lineage."
    [[ "${CONFIG_SCHEMA:-}" == "$CONFIG_SCHEMA_CURRENT" ]] || die "Unsupported Client configuration schema: ${CONFIG_SCHEMA:-missing}; expected ${CONFIG_SCHEMA_CURRENT}."
    [[ "${ROLE:-}" == ingress ]] || die "Invalid Client role: ${ROLE:-missing}."
    validate_profile_name "${PROFILE_NAME:-}" || die 'Client profile name is invalid.'
    validate_server_endpoint "${PEER_ENDPOINT:-}" || die 'Configured Server endpoint is invalid.'
    PORT_MODE="${PORT_MODE:-custom}"; [[ "$PORT_MODE" == custom ]] || die 'Client transport mode is invalid.'
    NATT_PORT="${UDP_PORT:-${NATT_PORT:-${IKE_PORT:-}}}"; validate_uint_range "$NATT_PORT" "$PROFILE_PORT_MIN" "$PROFILE_PORT_MAX" || die "Configured UDP port must be between ${PROFILE_PORT_MIN} and ${PROFILE_PORT_MAX}."; IKE_PORT="$NATT_PORT"
    SUBSCRIPTION_PORT="${SUBSCRIPTION_PORT:-$DEFAULT_SUBSCRIPTION_PORT}"; CONTROL_PORT="${CONTROL_PORT:-$DEFAULT_CONTROL_PORT}"
    validate_uint_range "$SUBSCRIPTION_PORT" 1 65535 || die 'Configured subscription port is invalid.'; validate_uint_range "$CONTROL_PORT" 1 65535 || die 'Configured CONTROL port is invalid.'; [[ "$SUBSCRIPTION_PORT" != "$CONTROL_PORT" ]] || die 'Subscription and CONTROL ports must be unique.'
    [[ "${MANAGED_CONTROL:-}" == yes ]] || die 'Client configuration is missing managed CONTROL state.'
    [[ "${CONNECTION_UUID:-}" =~ ^[0-9A-Fa-f-]{36}$ ]] || die 'Client configuration has an invalid connection UUID.'
    [[ "${CONTROL_KEY:-}" =~ ^[0-9a-f]{64}$ ]] || die 'Client configuration has an invalid CONTROL key.'
    [[ "${CONTROL_PROTOCOL:-}" == "$CONTROL_PROTOCOL_VERSION" ]] || die 'Client CONTROL protocol is incompatible with this release.'
    [[ "${DNS_FALLBACK_MODE:-}" == auto || "${DNS_FALLBACK_MODE:-}" == manual ]] || die 'Client DNS fallback mode is invalid.'
}


transport_label() {
    printf 'UDP %s (custom IKE + NAT-T/ESP)' "${NATT_PORT:-$DEFAULT_CUSTOM_NATT_PORT}"
}

transport_description() { transport_label; }



parse_pairing_token() {
    local token="$1" compact encoded padding decoded key value
    compact=$(printf '%s' "$token" | tr -d '[:space:]')
    [[ "$compact" == DFR1.* ]] || die 'This release accepts only DFR1 enrollment tokens.'
    encoded=${compact#DFR1.}; encoded=${encoded//-/+}; encoded=${encoded//_/\/}
    case $((${#encoded} % 4)) in 0) padding='' ;; 2) padding='==' ;; 3) padding='=' ;; *) die 'The DFR1 enrollment token has invalid Base64URL length.' ;; esac
    decoded=$(printf '%s%s' "$encoded" "$padding" | base64 -d 2>/dev/null) || die 'The DFR1 enrollment token is not valid Base64URL.'
    local version='' profile_name='' profile_index='' connection_uuid='' control_key='' endpoint='' udp_port='' psk='' tunnel_cidr='' xfrm_mtu='' dns_primary='' dns_secondary='' subscription_port='' control_port='' issued='' expires=''
    while IFS='=' read -r key value; do
        value=${value%$'\r'}
        case "$key" in
            V) version="$value" ;; N) profile_name="$value" ;; I) profile_index="$value" ;; U) connection_uuid="$value" ;; C) control_key="$value" ;;
            H) endpoint="$value" ;; P) udp_port="$value" ;; S) psk="$value" ;; T) tunnel_cidr="$value" ;; M) xfrm_mtu="$value" ;;
            D) IFS=',' read -r dns_primary dns_secondary <<<"$value" ;; Q) IFS=',' read -r subscription_port control_port <<<"$value" ;; A) issued="$value" ;; E) expires="$value" ;;
            '') ;; *) die "The DFR1 enrollment token contains an unknown field: ${key}." ;;
        esac
    done <<<"$decoded"
    [[ "$version" == 1 ]] || die 'The enrollment token version is not supported.'
    validate_profile_name "$profile_name" || die 'Invalid or missing profile name in token.'
    validate_uint_range "$profile_index" 1 9999 || die 'Enrollment token contains an invalid profile index.'
    [[ "$connection_uuid" =~ ^[0-9A-Fa-f-]{36}$ ]] || die 'Enrollment token contains an invalid connection UUID.'
    [[ "$control_key" =~ ^[0-9a-f]{64}$ ]] || die 'Enrollment token contains an invalid CONTROL key.'
    validate_server_endpoint "$endpoint" || die 'Enrollment token contains an invalid Server endpoint.'
    validate_uint_range "$udp_port" "$PROFILE_PORT_MIN" "$PROFILE_PORT_MAX" || die "Invalid custom UDP port in token. Expected ${PROFILE_PORT_MIN}-${PROFILE_PORT_MAX}."
    [[ "$psk" =~ ^[A-Fa-f0-9]{64,128}$ ]] || die 'Invalid pre-shared key in token.'
    validate_uint_range "$xfrm_mtu" 1200 9000 || die 'Invalid XFRM MTU in token.'
    require_ipv4 'primary DNS server' "$dns_primary"; require_ipv4 'secondary DNS server' "$dns_secondary"
    validate_uint_range "$subscription_port" 1 65535 || die 'Invalid subscription port in token.'; validate_uint_range "$control_port" 1 65535 || die 'Invalid CONTROL port in token.'; [[ "$subscription_port" != "$control_port" ]] || die 'Enrollment token management ports must be unique.'
    [[ "$issued" =~ ^[0-9]+$ && "$expires" =~ ^[0-9]+$ && "$expires" -gt "$issued" ]] || die 'Enrollment token lifetime metadata is invalid.'; (( $(date +%s) <= expires )) || die 'This enrollment token has expired. Generate a new token on the Server.'
    local -a hosts=(); mapfile -t hosts < <(cidr_hosts "$tunnel_cidr"); ((${#hosts[@]} == 5)) || die 'Enrollment token contains an invalid tunnel network.'
    local xfrm_if xfrm_id; xfrm_if=$(printf 'dfr%04d' "$profile_index"); xfrm_id=$((PROFILE_XFRM_ID_BASE + profile_index))
    TOKEN_PROFILE_NAME="$profile_name"; TOKEN_EGRESS_ENDPOINT="$endpoint"; TOKEN_EXIT_PUBLIC_IP=''; TOKEN_EGRESS_IP_AT_ISSUE=''
    TOKEN_PORT_MODE='custom'; TOKEN_IKE_PORT="$udp_port"; TOKEN_NATT_PORT="$udp_port"; TOKEN_PSK="$psk"; TOKEN_TUNNEL_CIDR="${hosts[0]}"
    TOKEN_XFRM_ID="$xfrm_id"; TOKEN_XFRM_IF="$xfrm_if"; TOKEN_EGRESS_XFRM_IF="$xfrm_if"; TOKEN_XFRM_MTU="$xfrm_mtu"
    TOKEN_INGRESS_XFRM_CIDR="${hosts[1]}"; TOKEN_EGRESS_XFRM_CIDR="${hosts[2]}"; TOKEN_INGRESS_XFRM_IP="${hosts[3]}"; TOKEN_EGRESS_XFRM_IP="${hosts[4]}"
    TOKEN_INGRESS_ID="dragon-fruit-relay-ingress-${profile_name}"; TOKEN_EGRESS_ID="dragon-fruit-relay-egress-${profile_name}"; TOKEN_DNS_PRIMARY="$dns_primary"; TOKEN_DNS_SECONDARY="$dns_secondary"
    TOKEN_CONNECTION_UUID="$connection_uuid"; TOKEN_CONTROL_PROTOCOL="$CONTROL_PROTOCOL_VERSION"; TOKEN_CONTROL_KEY="$control_key"; TOKEN_SUBSCRIPTION_PORT="$subscription_port"; TOKEN_CONTROL_PORT="$control_port"
    TOKEN_ISSUED_AT="$issued"; TOKEN_EXPIRES_AT="$expires"; TOKEN_MANAGED_CONTROL=yes; TOKEN_ENROLLMENT_HASH=$(printf '%s' "$compact" | sha256sum | awk '{print $1}')
}

managed_enroll_existing_ingress ()
{
    local token="${1:-}" snapshot
    configured_ingress || die 'No Client connection is configured.'; load_config
    clear_screen; dfr_ui_header 'CLIENT ENROLLMENT'; section_title 'Enroll this Client'
    print_check info 'Connection' "$PROFILE_NAME" identity; print_check info 'Server' "$PEER_ENDPOINT" accent; print_check info 'Transport' "UDP $NATT_PORT"
    section_title 'Enrollment token'; printf '  Paste the one-time DFR1 token shown for this connection on the Server.\n\n' > "$TTY_OUT"
    [[ -n "$token" ]] || token=$(prompt '  Enrollment token > '); token=$(printf '%s' "$token" | tr -d '[:space:]'); [[ -n "$token" ]] || { warn 'Enrollment cancelled: no token was supplied.'; return 1; }
    if ! ( parse_pairing_token "$token" ); then warn 'Enrollment was not changed.'; return 1; fi; parse_pairing_token "$token"
    [[ "$TOKEN_PROFILE_NAME" == "$PROFILE_NAME" ]] || { error 'Enrollment token belongs to a different connection. Use Replace Connection.'; return 1; }
    [[ "$TOKEN_EGRESS_ENDPOINT" == "$PEER_ENDPOINT" && "$TOKEN_IKE_PORT" == "$NATT_PORT" && "$TOKEN_TUNNEL_CIDR" == "$TUNNEL_CIDR" && "$TOKEN_XFRM_ID" == "$XFRM_ID" && "$TOKEN_XFRM_IF" == "$XFRM_IF" ]] || { error 'Enrollment token runtime identity does not match this installed Client. Use Replace Connection.'; return 1; }
    [[ "$TOKEN_INGRESS_XFRM_IP" == "$INGRESS_XFRM_IP" && "$TOKEN_EGRESS_XFRM_IP" == "$EGRESS_XFRM_IP" && "$TOKEN_INGRESS_ID" == "$INGRESS_ID" && "$TOKEN_EGRESS_ID" == "$EGRESS_ID" && "$TOKEN_PSK" == "$PSK" && "$TOKEN_XFRM_MTU" == "$XFRM_MTU" ]] || { error 'Enrollment token tunnel identity does not match this installed Client.'; return 1; }
    [[ "$TOKEN_DNS_PRIMARY" == "$DNS_PRIMARY" && "$TOKEN_DNS_SECONDARY" == "$DNS_SECONDARY" && "$TOKEN_SUBSCRIPTION_PORT" == "$SUBSCRIPTION_PORT" && "$TOKEN_CONTROL_PORT" == "$CONTROL_PORT" ]] || { error 'Enrollment token management policy does not match this installed Client.'; return 1; }
    snapshot=$(mktemp /tmp/dragon-fruit-relay-enroll-config.XXXXXX); cp -a -- "$CONFIG_FILE" "$snapshot"; chmod 0600 "$snapshot"
    upsert_shell_assignment "$CONFIG_FILE" MANAGED_CONTROL yes; upsert_shell_assignment "$CONFIG_FILE" CONNECTION_UUID "$TOKEN_CONNECTION_UUID"; upsert_shell_assignment "$CONFIG_FILE" CONTROL_PROTOCOL "$TOKEN_CONTROL_PROTOCOL"; upsert_shell_assignment "$CONFIG_FILE" ENROLLMENT_TOKEN_HASH "$TOKEN_ENROLLMENT_HASH"; upsert_shell_assignment "$CONFIG_FILE" CONTROL_KEY "$TOKEN_CONTROL_KEY"; upsert_shell_assignment "$CONFIG_FILE" MANAGED_BY_VERSION "$APP_VERSION"
    if ! ensure_ingress_management_current || ! "$CONTROL_AGENT" --once; then warn 'Enrollment handshake failed; restoring previous local state.'; install -m 0600 "$snapshot" "${CONFIG_FILE}.rollback.$$"; mv -f "${CONFIG_FILE}.rollback.$$" "$CONFIG_FILE"; rm -f -- "$snapshot"; ensure_ingress_runtime_files >/dev/null 2>&1 || true; return 1; fi
    rm -f -- "$snapshot"; load_config; success 'This Client is enrolled for managed operation.'; print_check info 'Connection ID' "$CONNECTION_UUID" identity; print_check info 'Configuration' 'SYNCED'; return 0
}

write_strongswan_common_files() {
    ensure_managed_layout
    install -d -m 0700 "$INGRESS_CONFIG_DIR"
    install -d -m 0755 /etc/strongswan.d "$STRONGSWAN_OVERRIDE_DIR"
    [[ "$PORT_MODE" == custom ]] || die 'Client transport must use a custom UDP port.'
    validate_uint_range "$NATT_PORT" "$PROFILE_PORT_MIN" "$PROFILE_PORT_MAX" || die 'Invalid custom Client UDP port.'

    cat >"$INGRESS_STRONGSWAN_SOURCE" <<EOF_STRONGSWAN
# Managed by Dragon Fruit Relay.
charon {
    port = 0
    # DFR_INGRESS_EPHEMERAL_SOURCE_PORT
    # Egress owns the fixed custom destination port.
    # Ingress uses an ephemeral NAT-T source socket.
    port_nat_t = 0
    install_routes = no
    plugins {
        kernel-libipsec { load = no }
        kernel-netlink {
            load = yes
            install_routes_xfrmi = no
        }
    }
}
EOF_STRONGSWAN
    chmod 0644 "$INGRESS_STRONGSWAN_SOURCE"

    cat >"$INGRESS_OVERRIDE_SOURCE" <<'EOF_OVERRIDE'
# Managed by Dragon Fruit Relay.
[Unit]
Requires=dragon-fruit-relay-xfrm.service
After=dragon-fruit-relay-xfrm.service
EOF_OVERRIDE
    chmod 0644 "$INGRESS_OVERRIDE_SOURCE"
    install_ingress_strongswan_canonical_copy "$INGRESS_STRONGSWAN_SOURCE" "$STRONGSWAN_ROUTE_FILE"
    install_ingress_canonical_link "$INGRESS_OVERRIDE_SOURCE" "$STRONGSWAN_OVERRIDE_FILE"
    systemctl disable --now dragon-fruit-relay-firewall.service >/dev/null 2>&1 || true
    rm -f "$SYSTEMD_DIR/dragon-fruit-relay-firewall.service" \
          "$UNIT_DIR/dragon-fruit-relay-firewall.service" \
          "$LIB_DIR/firewall-apply" "$LIB_DIR/firewall-remove"
}

write_swanctl_ingress() {
    ensure_managed_layout
    install -d -m 0700 "$INGRESS_CONFIG_DIR"
    prepare_ingress_swanctl_layout
    [[ "$PORT_MODE" == custom ]] || die 'Client transport must use a custom UDP port.'
    validate_uint_range "$NATT_PORT" "$PROFILE_PORT_MIN" "$PROFILE_PORT_MAX" || die 'Invalid custom Client UDP port.'

    cat >"$INGRESS_SWANCTL_SOURCE" <<EOF_SWANCTL
# Managed by Dragon Fruit Relay.
# Role: ingress / initiator
connections {
    dragonfruit_relay {
        version = 2
        local_addrs = %any
        remote_addrs = ${PEER_PUBLIC_IP}
        remote_port = ${NATT_PORT}
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
EOF_SWANCTL
    chmod 0600 "$INGRESS_SWANCTL_SOURCE"
    install_ingress_canonical_copy "$INGRESS_SWANCTL_SOURCE" "$INGRESS_SWANCTL_CANONICAL"

    if dragonfruit_owned_symlink "$SWANCTL_FILE" ||
       { [[ -f "$SWANCTL_FILE" ]] && grep -q '^# Managed by Dragon Fruit Relay\.' "$SWANCTL_FILE" 2>/dev/null; }; then
        rm -f -- "$SWANCTL_FILE"
        if manifest_contains "$SWANCTL_FILE"; then
            local saved="${BACKUP_DIR}/files${SWANCTL_FILE}" state
            state=$(awk -F '\t' -v target="$SWANCTL_FILE" '$2 == target {print $1; exit}' "$MANIFEST_FILE" 2>/dev/null || true)
            if [[ "$state" == present && -e "$saved" ]]; then
                install -d -m 0755 "$(dirname "$SWANCTL_FILE")"
                cp -a "$saved" "$SWANCTL_FILE"
            fi
        fi
    fi
}

generate_current_ingress_token() {
    load_config
    [[ "$ROLE" == ingress ]] || return 1
    local index payload encoded issued expires
    [[ "$XFRM_IF" =~ ^dfr([0-9]{4})$ ]] || return 1; index=$((10#${BASH_REMATCH[1]})); issued=$(date +%s); expires=$((issued+1800))
    payload=$(cat <<EOF_CURRENT_TOKEN
V=1
N=${PROFILE_NAME}
I=${index}
U=${CONNECTION_UUID}
C=${CONTROL_KEY}
H=${PEER_ENDPOINT}
P=${NATT_PORT}
S=${PSK}
T=${TUNNEL_CIDR}
M=${XFRM_MTU}
D=${DNS_PRIMARY},${DNS_SECONDARY}
Q=${SUBSCRIPTION_PORT},${CONTROL_PORT}
A=${issued}
E=${expires}
EOF_CURRENT_TOKEN
)
    encoded=$(printf '%s' "$payload" | base64 -w0 | tr '+/' '-_' | tr -d '=')
    printf 'DFR1.%s' "$encoded"
}

repair_current() {
    load_config; [[ "$ROLE" == ingress ]] || die 'This script repairs Clients only.'; install_dependencies
    info 'Reapplying Dragon Fruit Relay Client configuration.'
    ensure_managed_layout; write_managed_readme; install_self_copy; write_common_xfrm_files; write_strongswan_common_files; write_ingress_config; write_swanctl_ingress; write_ingress_routing_files; write_ingress_healthcheck_files; activate_ingress
    start_health_monitor_best_effort || true
    if attempt_tunnel_connection && ping -I "$XFRM_IF" -c 1 -W 3 "$XFRM_PEER_IP" >/dev/null 2>&1; then finalize_ingress_after_tunnel; verify_ingress_paths; else warn 'Managed files were repaired, but the peer is still disconnected. DNS was not replaced.'; fi
    if ensure_ingress_management_current; then systemctl start --no-block "$CONTROL_SERVICE" >/dev/null 2>&1 || true; fi
    success 'Dragon Fruit Relay Client configuration was reapplied.'
}


# -----------------------------------------------------------------------------
# Dragon Fruit Relay managed Client control plane
# -----------------------------------------------------------------------------
# DFR_INGRESS_CONTROL_AGENT

managed_config_patch_file ()
{
    local file="$1" candidate="$2"

    python3 - "$file" "$candidate" <<'PY_DFR_CONFIG_PATCH'
import ipaddress,json,re,shlex,sys
from pathlib import Path

path=Path(sys.argv[1]); candidate=json.loads(Path(sys.argv[2]).read_text())
port=int(candidate['udp_port']); mtu=int(candidate['xfrm_mtu'])
if not 20000 <= port <= 59999: raise SystemExit('invalid UDP port')
if not 1200 <= mtu <= 9000: raise SystemExit('invalid XFRM MTU')
for key in ('dns_primary','dns_secondary'): ipaddress.ip_address(candidate[key])
psk=str(candidate.get('psk',''))
if not re.fullmatch(r'[0-9a-fA-F]{64}',psk): raise SystemExit('invalid candidate PSK')
values={
    'IKE_PORT':str(port),
    'NATT_PORT':str(port),
    'XFRM_MTU':str(mtu),
    'DNS_PRIMARY':candidate['dns_primary'],
    'DNS_SECONDARY':candidate['dns_secondary'],
    'PSK':psk,
}
text=path.read_text()
# Update only the active managed configuration values.
for key,value in values.items():
    quoted=shlex.quote(value)
    pat=re.compile(rf'(?m)^{re.escape(key)}=.*$')
    if not pat.search(text): raise SystemExit(f'missing configuration key: {key}')
    text=pat.sub(f'{key}={quoted}',text,count=1)
tmp=path.with_name(path.name+'.managed-tmp')
tmp.write_text(text); tmp.chmod(0o600); tmp.replace(path)
PY_DFR_CONFIG_PATCH
}

managed_healthcheck ()
{
    load_config
    local sas

    systemctl is-active --quiet dragon-fruit-relay-xfrm.service || return 1
    systemctl is-active --quiet strongswan.service || return 1
    ip link show dev "$XFRM_IF" >/dev/null 2>&1 || return 1

    sas=$(safe_sas)
    grep -q ESTABLISHED <<<"$sas" || return 1
    grep -q INSTALLED <<<"$sas" || return 1
    ping -I "$XFRM_IF" -c 1 -W 2 "$XFRM_PEER_IP" >/dev/null 2>&1 || return 1
    systemctl is-active --quiet dragon-fruit-relay-routing.service || return 1
    route_uses_interface 9.9.9.9 "$XFRM_LOCAL_IP" "$XFRM_IF" || return 1
    resolver_runtime_ok || return 1
    return 0
}

managed_apply_config_candidate ()
{
    local candidate="$1"
    local old_port old_psk disruptive=no attempt
    load_config
    [[ "${MANAGED_CONTROL:-no}" == yes ]] || die 'This Client is not enrolled for managed configuration.'
    [[ -f "$candidate" ]] || die 'Candidate configuration is missing.'

    old_port="$NATT_PORT"
    old_psk="$PSK"
    managed_config_patch_file "$CONFIG_FILE" "$candidate"
    load_config
    [[ "$old_port" == "$NATT_PORT" && "$old_psk" == "$PSK" ]] || disruptive=yes

    # Rebuild and reload in place. Ingress uses an ephemeral source socket, so
    # remote-port and PSK changes do not require restarting charon. This keeps
    # the outage to one CHILD/IKE rekey instead of a full service teardown.
    ensure_ingress_runtime_files || return 1
    start_xfrm_checked || return 1
    if ! systemctl is-active --quiet strongswan.service; then
        start_unit_checked strongswan.service 'strongSwan service' || return 1
    fi
    load_strongswan_checked || return 1

    if [[ "$disruptive" == no ]] && managed_healthcheck; then
        finalize_ingress_after_tunnel >/dev/null 2>&1 || true
        return 0
    fi

    timeout 8s swanctl --terminate --ike dragonfruit_relay >/dev/null 2>&1 || true
    for attempt in 1 2 3; do
        if attempt_tunnel_connection >/dev/null 2>&1 && finalize_ingress_after_tunnel >/dev/null 2>&1 && managed_healthcheck; then
            return 0
        fi
        sleep 2
    done
    return 1
}

managed_rollback_config ()
{
    local previous="$1" attempt
    [[ -f "$previous" ]] || return 1
    install -m 0600 "$previous" "${CONFIG_FILE}.rollback.$$"
    mv -f "${CONFIG_FILE}.rollback.$$" "$CONFIG_FILE"
    load_config
    ensure_ingress_runtime_files || return 1
    start_xfrm_checked || return 1
    if ! systemctl is-active --quiet strongswan.service; then
        start_unit_checked strongswan.service 'strongSwan service' || return 1
    fi
    load_strongswan_checked || return 1
    timeout 8s swanctl --terminate --ike dragonfruit_relay >/dev/null 2>&1 || true
    for attempt in 1 2 3; do
        if attempt_tunnel_connection >/dev/null 2>&1 && finalize_ingress_after_tunnel >/dev/null 2>&1 && managed_healthcheck; then
            return 0
        fi
        sleep 2
    done
    return 1
}

managed_reconcile ()
{
    local force_reconnect="${1:-no}" attempt
    load_config
    if [[ "${MANAGED_CONTROL:-no}" == yes ]] && ! ingress_management_runtime_current; then
        ensure_ingress_management_current || return 1
        load_config
    fi
    ensure_ingress_runtime_files || return 1
    start_xfrm_checked || return 1
    systemctl is-active --quiet strongswan.service || start_unit_checked strongswan.service 'strongSwan service' || return 1
    load_strongswan_checked || return 1
    if [[ "$force_reconnect" != yes ]] && managed_healthcheck; then
        subscription_refresh_best_effort || true
        return 0
    fi
    timeout 8s swanctl --terminate --ike dragonfruit_relay >/dev/null 2>&1 || true
    for attempt in 1 2 3; do
        if attempt_tunnel_connection >/dev/null 2>&1 && finalize_ingress_after_tunnel >/dev/null 2>&1 && managed_healthcheck; then
            subscription_refresh_best_effort || true
            return 0
        fi
        sleep 2
    done
    return 1
}


managed_update_status_screen ()
{
    local when
    clear_screen
    dfr_ui_header 'MANAGED CLIENT'
    load_config

    section_title 'Management state'
    print_check info 'Mode' 'MANAGED'
    print_check info 'Client version' "$APP_VERSION" identity

    if [[ "${MANAGED_CONTROL:-no}" == yes ]]; then
        print_check info 'Connection ID' "${CONNECTION_UUID:0:12}…" identity
        print_check info 'Control protocol' "CONTROL/${CONTROL_PROTOCOL}"
        print_check info 'Control timer' "$(systemctl is-active "$CONTROL_TIMER" 2>/dev/null || true)"
    fi

    section_title 'Software update'
    if [[ -r "$UPDATE_CURRENT_STATE" ]]; then
        unset UPDATE_STATE UPDATE_VERSION UPDATE_SHA256 UPDATE_ERROR UPDATE_REQUESTED_AT UPDATE_STARTED_AT UPDATE_FINISHED_AT UPDATE_AT
        # shellcheck disable=SC1090
        source "$UPDATE_CURRENT_STATE"
        print_check info 'State' "$(managed_update_state_display "${UPDATE_STATE:-UNKNOWN}" "${UPDATE_VERSION:-}" "${UPDATE_SHA256:-}")"
        [[ -n "${UPDATE_VERSION:-}" ]] && print_check info 'Target version' "$UPDATE_VERSION" identity
        if [[ "${UPDATE_STARTED_AT:-}" =~ ^[0-9]+$ ]]; then
            when=$(date -d "@${UPDATE_STARTED_AT}" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || printf '%s' "$UPDATE_STARTED_AT")
            print_check info 'Started' "$when" plain
        fi
        if [[ "${UPDATE_FINISHED_AT:-}" =~ ^[0-9]+$ ]]; then
            when=$(date -d "@${UPDATE_FINISHED_AT}" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || printf '%s' "$UPDATE_FINISHED_AT")
            print_check info 'Finished' "$when" plain
        fi
        [[ -n "${UPDATE_ERROR:-}" ]] && print_check warn 'Last error' "$UPDATE_ERROR"
    else
        print_check info 'State' 'No software operation has run yet'
    fi

    section_title 'Managed configuration'
    print_check info 'State' "$(ingress_configuration_status)"

    section_title 'Last control operation'
    if [[ -r "${CONTROL_STATE_DIR}/operation.conf" ]]; then
        unset ACTION_NAME ACTION_STATE ACTION_MESSAGE ACTION_REQUESTED_AT ACTION_STARTED_AT ACTION_FINISHED_AT ACTION_AT
        # shellcheck disable=SC1090
        source "${CONTROL_STATE_DIR}/operation.conf"
        print_check info 'Operation' "${ACTION_NAME:-none}"
        print_check info 'State' "${ACTION_STATE:-UNKNOWN}"
        [[ -n "${ACTION_MESSAGE:-}" ]] && print_check info 'Result' "$ACTION_MESSAGE"
    else
        print_check info 'Operation' 'No managed operation has run yet'
    fi

    if [[ -r "${UPDATE_STATE_DIR}/control-error.conf" ]]; then
        unset AT ERROR
        # shellcheck disable=SC1090
        source "${UPDATE_STATE_DIR}/control-error.conf"
        [[ -n "${ERROR:-}" ]] && print_check warn 'CONTROL/1 error' "$ERROR"
    fi
}

write_ingress_user_access_files ()
{
    ensure_managed_layout

    cat > "$USER_CONTROL" <<'EOF_DFR_USER_CONTROL'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || exit 1
[[ $# -eq 1 ]] || { echo 'invalid user-control request' >&2; exit 2; }
ENGINE=/usr/local/sbin/dragon-fruit-relay
export DFR_INTERNAL_NO_MAIN_LOCK=1
case "$1" in
    summary) exec "$ENGINE" _user-summary-root ;;
    status) exec "$ENGINE" _user-status-root ;;
    diagnostics) exec "$ENGINE" _user-diagnostics-root ;;
    logs) exec "$ENGINE" _user-logs-root ;;
    test) exec "$ENGINE" _user-test-root ;;
    reconnect) exec "$ENGINE" _user-reconnect-root ;;
    stop) exec "$ENGINE" _user-stop-root ;;
    repair) exec "$ENGINE" _user-repair-root ;;
    refresh) exec "$ENGINE" _user-refresh-root ;;
    update-status) exec "$ENGINE" _user-update-status-root ;;
    enrollment-status) exec "$ENGINE" _user-enrollment-status-root ;;
    *) echo 'unsupported user-control request' >&2; exit 2 ;;
esac
EOF_DFR_USER_CONTROL

    chmod 0750 "$USER_CONTROL"

    install -d -m 0755 /etc/sudoers.d
    cat > "$USER_SUDOERS" <<EOF_DFR_SUDOERS
# Managed by Dragon Fruit Relay.
# Every local user may invoke this single fixed broker without a password.
# The broker accepts exactly one verb from its built-in allow-list and no
# arbitrary command path or additional arguments.
ALL ALL=(root) NOPASSWD: ${USER_CONTROL}
EOF_DFR_SUDOERS
    chmod 0440 "$USER_SUDOERS"
    visudo -cf "$USER_SUDOERS" >/dev/null || die 'Generated Dragon Fruit Relay sudoers rule is invalid.'
}

write_ingress_management_files ()
{
    ensure_managed_layout

    cat > "$CONTROL_AGENT" <<'PY_DFR_CONTROL_AGENT'
#!/usr/bin/env python3
# DFR_CONTROL_AGENT_ENDPOINT_SYNC_SELF_HEAL
# DFR_CONTROL_AGENT_REPORT_CONTRACT_V2
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import shlex
import socket
import subprocess
import sys
import time
from pathlib import Path

CONFIG = Path('/etc/dragon-fruit-relay/dragon-fruit-relay.conf')
ENGINE = '/usr/local/sbin/dragon-fruit-relay'
TX_HELPER = '/etc/dragon-fruit-relay/bin/config-transaction'
UPDATE_HELPER = '/etc/dragon-fruit-relay/bin/managed-update'
PUBLIC_KEY = Path('/etc/dragon-fruit-relay/secrets/ingress-update-ed25519.pub')
CONTROL_DIR = Path('/var/lib/dragon-fruit-relay/control')
UPDATE_DIR = Path('/var/lib/dragon-fruit-relay/updates')
ENDPOINT_STATE = CONTROL_DIR / 'server-endpoint.conf'
PROTOCOL = 'DRAGON-FRUIT-RELAY-CONTROL/1'
PORT_DEFAULT = 39893
MAX_RESPONSE = 8_000_000
SERVER_REGISTRY_SCHEMA_REQUIRED = 1
SERVER_RUNTIME_API_REQUIRED = 1
CLIENT_CAPABILITIES = ['release-sha-report-v1', 'server-endpoint-sync-v2']


def compact(obj):
    return json.dumps(obj, sort_keys=True, separators=(',', ':'))


def load_config():
    if not CONFIG.exists():
        raise RuntimeError('configuration missing')
    cp = subprocess.run(
        ['/bin/bash', '-c', 'set -a; source "$1"; env -0', '_', str(CONFIG)],
        capture_output=True,
        check=True,
    )
    env = {}
    for item in cp.stdout.split(b'\0'):
        if b'=' in item:
            key, value = item.split(b'=', 1)
            env[key.decode(errors='ignore')] = value.decode(errors='ignore')
    return env


def engine_version():
    try:
        for line in Path(ENGINE).read_text(errors='replace').splitlines():
            if line.startswith('readonly APP_VERSION="'):
                return line.split('"', 2)[1]
    except Exception:
        pass
    return 'unknown'


def engine_sha256():
    try:
        return hashlib.sha256(Path(ENGINE).read_bytes()).hexdigest()
    except Exception:
        return ''


def material(req):
    return '\n'.join(
        (
            str(req.get('protocol', '')),
            str(req.get('connection_uuid', '')),
            str(req.get('timestamp', '')),
            str(req.get('nonce', '')),
            str(req.get('op', '')),
            str(req.get('enrollment_token_hash', '') or ''),
            compact(req.get('payload') or {}),
        )
    ).encode()


def install_control_key(value):
    value = value.lower()
    if len(value) != 64 or any(ch not in '0123456789abcdef' for ch in value):
        raise RuntimeError('CONTROL/1 supplied an invalid next control key')
    text = CONFIG.read_text().splitlines()
    out = []
    found = False
    for line in text:
        if line.startswith('CONTROL_KEY='):
            out.append('CONTROL_KEY=' + value)
            found = True
        else:
            out.append(line)
    if not found:
        out.append('CONTROL_KEY=' + value)
    tmp = CONFIG.with_name(CONFIG.name + '.control-key.tmp')
    tmp.write_text('\n'.join(out) + '\n')
    os.chmod(tmp, 0o600)
    os.replace(tmp, CONFIG)


def install_update_public_key(value):
    if not value:
        return
    try:
        data = base64.b64decode(value, validate=True)
    except Exception as exc:
        raise RuntimeError('CONTROL/1 supplied an invalid update public key encoding') from exc
    PUBLIC_KEY.parent.mkdir(parents=True, exist_ok=True)
    tmp = PUBLIC_KEY.with_name(PUBLIC_KEY.name + '.control.tmp')
    tmp.write_bytes(data)
    os.chmod(tmp, 0o600)
    cp = subprocess.run(
        ['openssl', 'pkey', '-pubin', '-in', str(tmp), '-noout'],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if cp.returncode != 0:
        tmp.unlink(missing_ok=True)
        raise RuntimeError('CONTROL/1 supplied an invalid update verification key')
    os.replace(tmp, PUBLIC_KEY)


def request(op, payload=None, timeout=12):
    cfg = load_config()
    try:
        key = bytes.fromhex(cfg['CONTROL_KEY'])
    except (KeyError, ValueError) as exc:
        raise RuntimeError('local CONTROL key is missing or invalid') from exc
    nonce = secrets.token_hex(16)
    req = {
        'protocol': PROTOCOL,
        'connection_uuid': cfg['CONNECTION_UUID'],
        'timestamp': int(time.time()),
        'nonce': nonce,
        'op': op,
        'payload': payload or {},
        'enrollment_token_hash': cfg.get('ENROLLMENT_TOKEN_HASH', ''),
    }
    req['mac'] = hmac.new(key, material(req), hashlib.sha256).hexdigest()
    data = b''
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(timeout)
        sock.bind((cfg['INGRESS_XFRM_IP'], 0))
        sock.connect((cfg['EGRESS_XFRM_IP'], int(cfg.get('CONTROL_PORT') or PORT_DEFAULT)))
        sock.sendall((compact(req) + '\n').encode())
        while b'\n' not in data and len(data) < MAX_RESPONSE:
            chunk = sock.recv(65536)
            if not chunk:
                break
            data += chunk
    if not data:
        raise RuntimeError('empty CONTROL/1 response')
    if len(data) >= MAX_RESPONSE and b'\n' not in data:
        raise RuntimeError('CONTROL/1 response exceeds size limit')
    resp = json.loads(data.split(b'\n', 1)[0].decode())
    if not resp.get('ok'):
        raise RuntimeError(str(resp.get('error', 'CONTROL/1 request failed')))
    if resp.get('protocol') != PROTOCOL or resp.get('nonce') != nonce:
        raise RuntimeError('CONTROL/1 response identity mismatch')
    supplied_mac = str(resp.pop('mac', ''))
    expected = hmac.new(key, compact(resp).encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(supplied_mac, expected):
        raise RuntimeError('CONTROL/1 response authentication failed')
    out = resp.get('payload') or {}
    install_update_public_key(str(out.get('update_public_key_b64') or ''))
    next_key = str(out.get('next_control_key') or '')
    if next_key and next_key != cfg.get('CONTROL_KEY', ''):
        install_control_key(next_key)
    return out


def health():
    cp = subprocess.run(
        ['env', 'DFR_INTERNAL_NO_MAIN_LOCK=1', ENGINE, '_managed-healthcheck'],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=45,
    )
    return 'HEALTHY' if cp.returncode == 0 else 'UNHEALTHY'


def read_simple(path):
    out = {}
    try:
        for line in Path(path).read_text().splitlines():
            if '=' in line and not line.lstrip().startswith('#'):
                key, value = line.split('=', 1)
                value = value.strip()
                # State files are written by both Bash printf %q and Python
                # shlex.quote. Decode the shell word before reporting it over
                # CONTROL/1 so operators never see transport escaping such as
                # "post-update\ runtime" in the egress UI.
                if value.startswith("$'") and value.endswith("'"):
                    body = value[2:-1]
                    try:
                        value = bytes(body, 'utf-8').decode('unicode_escape')
                    except UnicodeDecodeError:
                        value = body
                else:
                    try:
                        words = shlex.split(value, posix=True)
                        if len(words) == 1:
                            value = words[0]
                    except ValueError:
                        value = value.strip("'\"")
                out[key] = value
    except FileNotFoundError:
        pass
    return out


def write_simple(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + '.tmp')
    lines = []
    for key, value in data.items():
        lines.append(f'{key}={shlex.quote(str(value))}\n')
    tmp.write_text(''.join(lines))
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def as_int(value):
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def read_update_state():
    return read_simple(UPDATE_DIR / 'state.conf')


def write_update_state(state, version='', error='', *, sha256='', requested=False, started=False, finished=False, reset=False):
    now = int(time.time())
    previous = {} if reset else read_update_state()
    data = {
        'UPDATE_STATE': state,
        'UPDATE_VERSION': version or previous.get('UPDATE_VERSION', ''),
        'UPDATE_SHA256': sha256 or previous.get('UPDATE_SHA256', ''),
        'UPDATE_ERROR': str(error).replace('\n', ' ')[:500],
        'UPDATE_REQUESTED_AT': previous.get('UPDATE_REQUESTED_AT', now if requested else ''),
        'UPDATE_STARTED_AT': previous.get('UPDATE_STARTED_AT', now if started else ''),
        'UPDATE_FINISHED_AT': now if finished else previous.get('UPDATE_FINISHED_AT', ''),
        'UPDATE_AT': now,
    }
    if requested and not data['UPDATE_REQUESTED_AT']:
        data['UPDATE_REQUESTED_AT'] = now
    if started and not data['UPDATE_STARTED_AT']:
        data['UPDATE_STARTED_AT'] = now
    write_simple(UPDATE_DIR / 'state.conf', data)


def read_action_state():
    return read_simple(CONTROL_DIR / 'operation.conf')


def write_action_state(name, state, message='', *, requested=False, started=False, finished=False):
    now = int(time.time())
    previous = read_action_state()
    data = {
        'ACTION_NAME': name,
        'ACTION_STATE': state,
        'ACTION_MESSAGE': str(message).replace('\n', ' ')[:500],
        'ACTION_REQUESTED_AT': previous.get('ACTION_REQUESTED_AT', now if requested else ''),
        'ACTION_STARTED_AT': previous.get('ACTION_STARTED_AT', now if started else ''),
        'ACTION_FINISHED_AT': now if finished else previous.get('ACTION_FINISHED_AT', ''),
        'ACTION_AT': now,
    }
    if requested and not data['ACTION_REQUESTED_AT']:
        data['ACTION_REQUESTED_AT'] = now
    if started and not data['ACTION_STARTED_AT']:
        data['ACTION_STARTED_AT'] = now
    write_simple(CONTROL_DIR / 'operation.conf', data)


def report_payload(extra=None):
    cfg = load_config()
    update = read_update_state()
    action = read_action_state()
    endpoint_state = read_simple(ENDPOINT_STATE)
    payload = {
        'ingress_version': engine_version(),
        'ingress_sha256': engine_sha256(),
        'health': health(),
        'update_status': update.get('UPDATE_STATE', ''),
        'update_target': update.get('UPDATE_VERSION', ''),
        'update_sha256': update.get('UPDATE_SHA256', ''),
        'update_error': update.get('UPDATE_ERROR', ''),
        'update_started_at': as_int(update.get('UPDATE_STARTED_AT')),
        'update_finished_at': as_int(update.get('UPDATE_FINISHED_AT')),
        'action_name': action.get('ACTION_NAME', ''),
        'action_status': action.get('ACTION_STATE', ''),
        'action_message': action.get('ACTION_MESSAGE', ''),
        'action_started_at': as_int(action.get('ACTION_STARTED_AT')),
        'action_finished_at': as_int(action.get('ACTION_FINISHED_AT')),
        'client_endpoint': cfg.get('PEER_ENDPOINT', ''),
        'endpoint_error': endpoint_state.get('ERROR', ''),
        'client_capabilities': CLIENT_CAPABILITIES,
    }
    if extra:
        payload.update(extra)
    return payload

def report(extra=None):
    return request('report', report_payload(extra))


def report_best_effort(extra=None):
    try:
        return report(extra)
    except Exception:
        return None


def state_file(transaction_id):
    return CONTROL_DIR / 'config-transactions' / str(transaction_id) / 'state.conf'


def run_transaction(tx):
    txid = str(tx['transaction_id'])
    write_action_state('configuration', 'RUNNING', 'coordinated configuration change is applying', started=True)
    report_best_effort({'action_name': 'configuration', 'action_status': 'RUNNING', 'action_message': 'coordinated configuration change is applying'})
    tdir = CONTROL_DIR / 'config-transactions' / txid
    tdir.mkdir(parents=True, exist_ok=True)
    state_path = tdir / 'state.conf'
    local_state = read_simple(state_path)
    if local_state.get('STATE') in ('COMMITTED', 'ROLLED_BACK'):
        return
    if local_state.get('STATE') == 'FAILED':
        report(
            {
                'config_result': 'failed',
                'config_transaction_id': txid,
                'error': local_state.get('ERROR', 'local transaction previously failed'),
            }
        )
        return
    candidate = tdir / 'candidate.json'
    candidate.write_text(compact(tx['candidate']))
    os.chmod(candidate, 0o600)
    write_simple(
        state_path,
        {
            'STATE': 'PREPARED',
            'TRANSACTION_ID': txid,
            'APPLY_AT': int(tx['apply_at']),
            'ROLLBACK_AT': int(tx['rollback_at']),
            'ERROR': '',
        },
    )
    timeout = max(120, int(tx['rollback_at']) - int(time.time()) + 30)
    cp = subprocess.run(
        [TX_HELPER, txid, str(int(tx['apply_at'])), str(int(tx['rollback_at'])), str(candidate)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
        timeout=timeout,
    )
    state = read_simple(state_path)
    if cp.returncode == 0 and state.get('STATE') == 'COMMITTED':
        write_action_state('configuration', 'SUCCEEDED', 'configuration committed', finished=True)
        report_best_effort({'action_name': 'configuration', 'action_status': 'SUCCEEDED', 'action_message': 'configuration committed'})
        return
    message = state.get('ERROR') or (cp.stderr or '').strip()[-300:] or 'configuration transaction failed'
    write_action_state('configuration', 'FAILED', message, finished=True)
    if state.get('STATE') not in ('ROLLED_BACK', 'COMMITTED'):
        report_best_effort({'config_result': 'failed', 'config_transaction_id': txid, 'error': message})
    report_best_effort({'action_name': 'configuration', 'action_status': 'FAILED', 'action_message': message})


def reconcile_incomplete_local_tx(remote):
    tx = remote.get('transaction') or {}
    remote_id = str(tx.get('transaction_id') or '')
    root = CONTROL_DIR / 'config-transactions'
    if not root.exists():
        return remote

    # Any local active transaction that is no longer the egress transaction is
    # stale.  Its previous.conf remains authoritative for boot/watchdog recovery;
    # mark it rolled back so it cannot be replayed.
    for transaction_dir in sorted(root.glob('*'), key=lambda p: p.stat().st_mtime if p.exists() else 0)[::-1]:
        state_path = transaction_dir / 'state.conf'
        state = read_simple(state_path)
        local_id = state.get('TRANSACTION_ID') or transaction_dir.name
        if state.get('STATE') in ('PREPARED','APPLYING','APPLIED','FAILED') and local_id != remote_id:
            previous = transaction_dir / 'previous.conf'
            if previous.exists():
                subprocess.run(
                    ['env','DFR_INTERNAL_NO_MAIN_LOCK=1',ENGINE,'_managed-rollback-config',str(previous)],
                    stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,
                )
            write_simple(state_path,{**state,'STATE':'ROLLED_BACK','ERROR':'stale local transaction recovered'})

    if remote_id and tx.get('state') == 'APPLYING':
        state_path = state_file(remote_id)
        state = read_simple(state_path)
        if state.get('STATE') == 'APPLIED':
            refreshed = report({'config_result': 'success', 'config_transaction_id': remote_id})
            new_tx = refreshed.get('transaction') or {}
            if not new_tx or new_tx.get('transaction_id') != remote_id or new_tx.get('state') == 'COMMITTED':
                write_simple(state_path, {**state, 'STATE': 'COMMITTED', 'ERROR': ''})
            return refreshed
    return remote


def verify_release(release):
    version = str(release['version'])
    payload = base64.b64decode(release['payload_b64'], validate=True)
    signature = base64.b64decode(release['signature_b64'], validate=True)
    manifest = release['manifest']
    if manifest.get('format') != 'dragon-fruit-relay-ingress-release' or int(manifest.get('format_version', 0)) != 1:
        raise RuntimeError('unsupported release manifest')
    if manifest.get('version') != version or manifest.get('role') != 'ingress':
        raise RuntimeError('release manifest identity mismatch')
    if int(manifest.get('minimum_control_protocol', 99)) > 1:
        raise RuntimeError('release requires a newer CONTROL protocol')
    if int(manifest.get('enrollment_token_version', 0)) != 1:
        raise RuntimeError('release enrollment-token contract mismatch')
    if int(manifest.get('config_schema', 0)) != 1:
        raise RuntimeError('release Client configuration schema mismatch')
    digest = hashlib.sha256(payload).hexdigest()
    if digest != release['sha256'] or digest != manifest.get('sha256'):
        raise RuntimeError('release checksum mismatch')
    UPDATE_DIR.joinpath('staging').mkdir(parents=True, exist_ok=True)
    script = UPDATE_DIR / 'staging' / f'ingress-{version}.sh'
    manifest_file = UPDATE_DIR / 'staging' / f'ingress-{version}.manifest.json'
    signature_file = UPDATE_DIR / 'staging' / f'ingress-{version}.sig'
    script.write_bytes(payload)
    os.chmod(script, 0o700)
    manifest_file.write_text(compact(manifest))
    signature_file.write_bytes(signature)
    cp = subprocess.run(
        ['openssl', 'pkeyutl', '-verify', '-pubin', '-inkey', str(PUBLIC_KEY), '-rawin', '-in', str(manifest_file), '-sigfile', str(signature_file)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if cp.returncode != 0:
        raise RuntimeError('release signature verification failed')
    cp = subprocess.run(['bash', '-n', str(script)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if cp.returncode != 0:
        raise RuntimeError('release shell validation failed')
    found = ''
    for line in script.read_text(errors='replace').splitlines():
        if line.startswith('readonly APP_VERSION="'):
            found = line.split('"', 2)[1]
            break
    if found != version:
        raise RuntimeError(f'release payload declares {found or "no APP_VERSION"}, expected {version}')
    return script


def process_server_endpoint(remote):
    desired = str(remote.get('server_endpoint') or '').strip().lower().rstrip('.')
    if not desired:
        return remote

    cfg = load_config()
    current = str(cfg.get('PEER_ENDPOINT') or '').strip().lower().rstrip('.')
    if current == desired:
        ENDPOINT_STATE.unlink(missing_ok=True)
        return remote

    # Register this agent's capability and last-known endpoint before doing any
    # potentially slow activation work.  This prevents the Server from showing
    # a false software-update requirement while an endpoint-capable Client is
    # already attempting the migration.
    fresh = report_best_effort()
    if fresh:
        remote = fresh

    transaction = remote.get('transaction') or {}
    if transaction.get('state') in ('PENDING', 'PREPARED', 'APPLYING'):
        return remote

    update_state = read_update_state().get('UPDATE_STATE', '')
    if update_state in ('QUEUED', 'DOWNLOADING', 'VERIFYING', 'APPLYING'):
        return remote

    # A failed activation restores the previous local endpoint. Avoid retrying
    # on every ten-second CONTROL poll; retry after a bounded backoff or after
    # the operator clears the error from the Server endpoint workspace.
    previous = read_simple(ENDPOINT_STATE)
    if previous.get('DESIRED') == desired and previous.get('ERROR'):
        failed_at=as_int(previous.get('AT'))
        # Normal CONTROL polling uses a bounded backoff after a failed endpoint
        # activation. An explicit Server Synchronize queues pending_action=reconcile
        # and intentionally bypasses that backoff for an operator-requested retry.
        explicit_retry = str(remote.get('pending_action') or '') == 'reconcile'
        if not explicit_retry and failed_at and int(time.time()) - failed_at < 60:
            return remote

    try:
        cp = subprocess.run(
            ['env', 'DFR_INTERNAL_NO_MAIN_LOCK=1', ENGINE, '_managed-set-server-endpoint', desired],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=180,
        )
        if cp.returncode != 0:
            message = (cp.stdout or '').strip().replace('\n', ' ')[-500:]
            raise RuntimeError(message or f'endpoint update exited {cp.returncode}')

        applied = str(load_config().get('PEER_ENDPOINT') or '').strip().lower().rstrip('.')
        if applied != desired:
            raise RuntimeError(f'endpoint activation completed but local endpoint is {applied or "unknown"}, expected {desired}')

        ENDPOINT_STATE.unlink(missing_ok=True)
        return report_best_effort() or remote
    except Exception as exc:
        message = str(exc).replace('\n', ' ')[:500]
        write_simple(
            ENDPOINT_STATE,
            {'AT': int(time.time()), 'DESIRED': desired, 'ERROR': message},
        )
        return report_best_effort({'endpoint_error': message}) or remote


def process_reconcile(remote):
    if remote.get('pending_action') != 'reconcile':
        return remote
    write_action_state('reconcile', 'RUNNING', started=True)
    report_best_effort({'action_name': 'reconcile', 'action_status': 'RUNNING'})
    try:
        cp = subprocess.run(
            ['env', 'DFR_INTERNAL_NO_MAIN_LOCK=1', ENGINE, '_managed-reconcile'],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=150,
        )
    except subprocess.TimeoutExpired as exc:
        cp = subprocess.CompletedProcess([], 124, stdout=(exc.stdout or '') + '\nreconcile timed out')
    if cp.returncode == 0:
        write_action_state('reconcile', 'SUCCEEDED', 'runtime is reconciled', finished=True)
        return report(
            {
                'action_complete': 'reconcile',
                'action_name': 'reconcile',
                'action_status': 'SUCCEEDED',
                'action_message': 'runtime is reconciled',
            }
        )
    message = (cp.stdout or '').strip().replace('\n', ' ')[-500:] or f'reconcile failed with status {cp.returncode}'
    write_action_state('reconcile', 'FAILED', message, finished=True)
    return report(
        {
            'action_failed': 'reconcile',
            'action_name': 'reconcile',
            'action_status': 'FAILED',
            'action_message': message,
            'error': message,
        }
    )


def process_update(remote):
    wanted = str(remote.get('desired_ingress_version') or '')
    desired_source = str(remote.get('desired_ingress_source') or '')
    policy = str(remote.get('update_policy') or 'manual')
    current = engine_version()
    current_sha = engine_sha256()
    if not wanted:
        return remote
    # Pinned disables automatic convergence, not an explicit operator deploy.
    if policy == 'pinned' and desired_source != 'manual':
        return remote

    metadata = remote.get('release') or {}
    wanted_sha = str(metadata.get('sha256') or '').strip().lower()
    if metadata.get('version') != wanted or not re.fullmatch(r'[0-9a-f]{64}', wanted_sha):
        raise RuntimeError('desired release is not available from the active catalog with an exact SHA256')

    state = read_update_state()
    remote_update_status = str(remote.get('update_status') or '')

    # A managed software build is identified by (version, SHA256). This allows
    # a corrected payload to keep the same semantic version while still being
    # installable over an older payload with a different digest.
    if wanted == current and current_sha == wanted_sha:
        if (state.get('UPDATE_STATE') != 'CURRENT' or
                state.get('UPDATE_VERSION') != wanted or
                state.get('UPDATE_SHA256') != wanted_sha):
            write_update_state('CURRENT', wanted, '', sha256=wanted_sha, finished=True)
        return report_best_effort() or remote

    terminal = (
        state.get('UPDATE_VERSION') == wanted and
        state.get('UPDATE_SHA256') == wanted_sha and
        state.get('UPDATE_STATE') in ('FAILED', 'ROLLED_BACK')
    )
    if terminal and remote_update_status != 'QUEUED':
        return report_best_effort() or remote

    if (state.get('UPDATE_VERSION') != wanted or
            state.get('UPDATE_SHA256') != wanted_sha or
            state.get('UPDATE_STATE') not in ('QUEUED','DOWNLOADING','VERIFYING','APPLYING')):
        write_update_state('QUEUED', wanted, '', sha256=wanted_sha, requested=True, reset=True)
    report_best_effort()

    try:
        write_update_state('DOWNLOADING', wanted, '', sha256=wanted_sha, started=True)
        report_best_effort()
        release = request('release', {'version': wanted}, timeout=30)
        if str(release.get('sha256') or '').lower() != wanted_sha:
            raise RuntimeError('release digest changed while update was being downloaded')

        write_update_state('VERIFYING', wanted, '', sha256=wanted_sha, started=True)
        report_best_effort()
        script = verify_release(release)

        write_update_state('APPLYING', wanted, '', sha256=wanted_sha, started=True)
        report_best_effort()
        cp = subprocess.run(
            [UPDATE_HELPER, str(script), wanted, wanted_sha],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=390,
        )
        if cp.returncode != 0:
            state = read_update_state()
            message = state.get('UPDATE_ERROR') or (cp.stdout or '').strip().replace('\n', ' ')[-500:] or f'update helper exited {cp.returncode}'
            if state.get('UPDATE_STATE') != 'ROLLED_BACK':
                write_update_state('FAILED', wanted, message, sha256=wanted_sha, finished=True)
            report_best_effort({'error': message})
            return remote

        installed = engine_version()
        installed_sha = engine_sha256()
        if installed != wanted or installed_sha != wanted_sha:
            message = (
                f'update helper completed but installed build is '
                f'{installed}/{installed_sha or "unknown"}, expected {wanted}/{wanted_sha}'
            )
            write_update_state('FAILED', wanted, message, sha256=wanted_sha, finished=True)
            report_best_effort({'error': message})
            return remote

        state = read_update_state()
        if state.get('UPDATE_STATE') != 'CURRENT':
            write_update_state('CURRENT', wanted, '', sha256=wanted_sha, finished=True)

        # The release may have installed endpoint-sync support over an older
        # agent. Run the newly installed agent once after this process exits so
        # endpoint migration is the first follow-up managed action.
        try:
            subprocess.run(
                [
                    'systemd-run', '--quiet', '--collect',
                    f'--unit=dragon-fruit-relay-post-update-control-{os.getpid()}',
                    '--on-active=2s',
                    '/etc/dragon-fruit-relay/bin/control-agent', '--once',
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=10,
            )
        except Exception:
            pass
        return report_best_effort() or remote
    except Exception as exc:
        state = read_update_state()
        if state.get('UPDATE_STATE') not in ('ROLLED_BACK', 'FAILED'):
            write_update_state('FAILED', wanted, str(exc), sha256=wanted_sha, finished=True)
        report_best_effort({'error': str(exc)})
        return remote


def once():
    cfg = load_config()
    if cfg.get('MANAGED_CONTROL') != 'yes':
        return 0
    remote = request('poll', {})
    if (as_int(remote.get('registry_schema')) < SERVER_REGISTRY_SCHEMA_REQUIRED or
            as_int(remote.get('runtime_api')) < SERVER_RUNTIME_API_REQUIRED):
        raise RuntimeError(
            'Server management plane must use the v2.1.0 schema-1/runtime-API-1 contract before Client commands can run'
        )
    remote = reconcile_incomplete_local_tx(remote)
    transaction = remote.get('transaction')
    if not transaction or transaction.get('state') not in ('PENDING', 'PREPARED', 'APPLYING'):
        transaction = remote.get('transaction')
    if transaction:
        txid = str(transaction.get('transaction_id') or '')
        local_transaction = read_simple(state_file(txid)) if txid else {}
        if txid and local_transaction.get('STATE') in ('ROLLED_BACK', 'FAILED'):
            remote = report(
                {
                    'config_result': 'failed',
                    'config_transaction_id': txid,
                    'error': local_transaction.get('ERROR', 'local recovery rejected the pending transaction'),
                }
            )
            transaction = remote.get('transaction')
        if transaction and transaction.get('state') == 'PENDING':
            remote = request('prepare-config', {'transaction_id': str(transaction['transaction_id'])})
            transaction = remote.get('transaction')
        if transaction and transaction.get('state') == 'PREPARED':
            run_transaction(transaction)
            remote = request('poll', {})
    transaction = remote.get('transaction')
    if not transaction or transaction.get('state') not in ('PENDING', 'PREPARED', 'APPLYING'):
        # Software work is processed first, but the mere presence of a desired
        # release must never suppress endpoint/reconcile work. Managed Servers
        # normally advertise a desired release continuously, including when the
        # Client is already on the exact current build. Only an update that is
        # actively QUEUED/DOWNLOADING/VERIFYING/APPLYING blocks other managed
        # actions for this poll.
        remote = process_update(remote)
        update_state = str(read_update_state().get('UPDATE_STATE') or '').upper()
        if update_state not in ('QUEUED', 'DOWNLOADING', 'VERIFYING', 'APPLYING'):
            remote = process_server_endpoint(remote)
            remote = process_reconcile(remote)
    report()
    (UPDATE_DIR / 'control-error.conf').unlink(missing_ok=True)
    return 0


def main():
    try:
        if len(sys.argv) >= 2 and sys.argv[1] == '--report-config':
            txid = str(sys.argv[2])
            result = sys.argv[3]
            error = sys.argv[4] if len(sys.argv) > 4 else ''
            remote = report({'config_result': result, 'config_transaction_id': txid, 'error': error})
            tx = remote.get('transaction') or {}
            # Success is acknowledged when egress has either marked the matching
            # temporary transaction COMMITTED or removed it after finalization.
            return 0 if result != 'success' or not tx or tx.get('transaction_id') != txid or tx.get('state') == 'COMMITTED' else 2
        if len(sys.argv) >= 2 and sys.argv[1] == '--once':
            return once()
        return once()
    except Exception as exc:
        UPDATE_DIR.mkdir(parents=True, exist_ok=True)
        write_simple(
            UPDATE_DIR / 'control-error.conf',
            {'AT': int(time.time()), 'ERROR': str(exc).replace('\n', ' ')[:500]},
        )
        print(f'dragon-fruit-relay-control: {exc}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
PY_DFR_CONTROL_AGENT

    cat > "$CONTROL_TX_HELPER" <<'EOF_DFR_CONFIG_TX'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

[[ $# -eq 4 ]] || exit 64
TRANSACTION_ID="$1"
APPLY_AT="$2"
ROLLBACK_AT="$3"
CANDIDATE="$4"
ENGINE=/usr/local/sbin/dragon-fruit-relay
CONFIG=/etc/dragon-fruit-relay/dragon-fruit-relay.conf
ROOT=/var/lib/dragon-fruit-relay/control/config-transactions
AGENT=/etc/dragon-fruit-relay/bin/control-agent
WATCHDOG=/etc/dragon-fruit-relay/bin/config-rollback-watchdog
CHANGE_LOCK=/run/lock/dragon-fruit-relay-ingress-change.lock
DIR="${ROOT}/${TRANSACTION_ID}"
STATE="${DIR}/state.conf"
PREVIOUS="${DIR}/previous.conf"

[[ "$TRANSACTION_ID" =~ ^[0-9A-Fa-f-]{36}$ ]]
[[ "$APPLY_AT" =~ ^[0-9]+$ ]]
[[ "$ROLLBACK_AT" =~ ^[0-9]+$ ]]
(( ROLLBACK_AT > APPLY_AT ))

install -d -m 0755 /run/lock
exec 8>"$CHANGE_LOCK"
flock 8

write_state() {
    local state="$1" error="${2:-}"
    {
        printf 'STATE=%q\n' "$state"
        printf 'TRANSACTION_ID=%q\n' "$TRANSACTION_ID"
        printf 'APPLY_AT=%q\n' "$APPLY_AT"
        printf 'ROLLBACK_AT=%q\n' "$ROLLBACK_AT"
        printf 'ERROR=%q\n' "$error"
        printf 'UPDATED_AT=%q\n' "$(date +%s)"
    } > "${STATE}.tmp"
    chmod 0600 "${STATE}.tmp"
    mv -f "${STATE}.tmp" "$STATE"
}

mkdir -p "$DIR"
chmod 0700 "$DIR"
[[ -f "$CONFIG" && -f "$CANDIDATE" ]] || exit 1
cp -a "$CONFIG" "$PREVIOUS"
chmod 0600 "$PREVIOUS"
write_state PREPARED
watchdog_unit="dragon-fruit-relay-config-watchdog-${TRANSACTION_ID}-$(date +%s)"
if ! systemd-run --unit="$watchdog_unit" --collect --no-block --quiet -- \
        "$WATCHDOG" "$TRANSACTION_ID" "$ROLLBACK_AT" "$PREVIOUS"; then
    message='could not arm the independent configuration rollback watchdog'
    write_state FAILED "$message"
    "$AGENT" --report-config "$TRANSACTION_ID" failed "$message" >/dev/null 2>&1 || true
    exit 1
fi

now=$(date +%s)
(( APPLY_AT > now )) && sleep "$((APPLY_AT-now))"
write_state APPLYING

if ! env DFR_INTERNAL_NO_MAIN_LOCK=1 "$ENGINE" _managed-apply-config "$CANDIDATE"; then
    message='local apply or tunnel validation failed'
    write_state FAILED "$message"
    env DFR_INTERNAL_NO_MAIN_LOCK=1 "$ENGINE" _managed-rollback-config "$PREVIOUS" >/dev/null 2>&1 || true
    write_state ROLLED_BACK "$message"
    "$AGENT" --report-config "$TRANSACTION_ID" failed "$message" >/dev/null 2>&1 || true
    exit 1
fi

write_state APPLIED

# Keep retrying authenticated commit acknowledgement until the shared 60-second
# rollback deadline.  Failure to confirm means the previous active config wins.
while :; do
    if "$AGENT" --report-config "$TRANSACTION_ID" success >/dev/null 2>&1; then
        write_state COMMITTED
        exit 0
    fi
    now=$(date +%s)
    (( now >= ROLLBACK_AT )) && break
    sleep 2
done

message='Server commit was not confirmed before the 60-second rollback deadline'
env DFR_INTERNAL_NO_MAIN_LOCK=1 "$ENGINE" _managed-rollback-config "$PREVIOUS" >/dev/null 2>&1 || true
write_state ROLLED_BACK "$message"
"$AGENT" --report-config "$TRANSACTION_ID" failed "$message" >/dev/null 2>&1 || true
exit 1
EOF_DFR_CONFIG_TX

    cat > "$CONTROL_TX_WATCHDOG" <<'EOF_DFR_CONFIG_WATCHDOG'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
TRANSACTION_ID="$1"
ROLLBACK_AT="$2"
PREVIOUS="$3"
ENGINE=/usr/local/sbin/dragon-fruit-relay
STATE="/var/lib/dragon-fruit-relay/control/config-transactions/${TRANSACTION_ID}/state.conf"

[[ "$TRANSACTION_ID" =~ ^[0-9A-Fa-f-]{36}$ ]]
[[ "$ROLLBACK_AT" =~ ^[0-9]+$ ]]

while :; do
    current=''
    [[ -r "$STATE" ]] && current=$(sed -nE 's/^STATE=(.*)$/\1/p' "$STATE" | tr -d "'\"")
    [[ "$current" == COMMITTED || "$current" == ROLLED_BACK ]] && exit 0
    now=$(date +%s)
    (( now >= ROLLBACK_AT )) && break
    sleep 2
done

env DFR_INTERNAL_NO_MAIN_LOCK=1 "$ENGINE" _managed-rollback-config "$PREVIOUS" >/dev/null 2>&1 || true
{
    printf 'STATE=ROLLED_BACK\n'
    printf 'TRANSACTION_ID=%q\n' "$TRANSACTION_ID"
    printf 'ROLLBACK_AT=%q\n' "$ROLLBACK_AT"
    printf 'ERROR=%q\n' 'Server commit was not confirmed before the 60-second rollback deadline'
} > "${STATE}.tmp"
chmod 0600 "${STATE}.tmp"
mv -f "${STATE}.tmp" "$STATE"
EOF_DFR_CONFIG_WATCHDOG

    cat > "$CONTROL_BOOT_RECOVERY" <<'EOF_DFR_CONFIG_BOOT_RECOVERY'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT=/var/lib/dragon-fruit-relay/control/config-transactions
CONFIG=/etc/dragon-fruit-relay/dragon-fruit-relay.conf
ENGINE=/usr/local/sbin/dragon-fruit-relay

[[ -d "$ROOT" ]] || exit 0

# At most one transaction should be live.  If power was lost during a change,
# restore the newest transaction's previous active configuration before tunnel
# services are allowed to proceed.
latest=''
while IFS= read -r sf; do
    state=$(sed -nE 's/^STATE=(.*)$/\1/p' "$sf" | tr -d "'\"")
    case "$state" in PREPARED|APPLYING|APPLIED|FAILED) latest="$sf"; break ;; esac
done < <(find "$ROOT" -mindepth 2 -maxdepth 2 -name state.conf -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)

[[ -n "$latest" ]] || exit 0
dir=${latest%/state.conf}
previous="$dir/previous.conf"
[[ -f "$previous" ]] || exit 1
install -m 0600 "$previous" "${CONFIG}.boot-rollback.$$"
mv -f "${CONFIG}.boot-rollback.$$" "$CONFIG"

env DFR_INTERNAL_NO_MAIN_LOCK=1 "$ENGINE" _managed-regenerate-runtime >/dev/null 2>&1 || exit 1

for sf in "$ROOT"/*/state.conf; do
    [[ -f "$sf" ]] || continue
    state=$(sed -nE 's/^STATE=(.*)$/\1/p' "$sf" | tr -d "'\"")
    case "$state" in PREPARED|APPLYING|APPLIED|FAILED)
        txid=$(basename "${sf%/state.conf}")
        {
            printf 'STATE=ROLLED_BACK\n'
            printf 'TRANSACTION_ID=%q\n' "$txid"
            printf 'ERROR=%q\n' 'boot recovery restored the previous active configuration'
        } > "${sf}.tmp"
        chmod 0600 "${sf}.tmp"; mv -f "${sf}.tmp" "$sf"
        ;;
    esac
done
EOF_DFR_CONFIG_BOOT_RECOVERY

    cat > "$UPDATE_HELPER" <<'EOF_DFR_MANAGED_UPDATE'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

[[ $# -eq 3 ]] || exit 64
NEW_ENGINE="$1"
TARGET_VERSION="$2"
TARGET_SHA256="$3"
[[ "$TARGET_SHA256" =~ ^[0-9a-f]{64}$ ]] || exit 64
CLI=/usr/local/sbin/dragon-fruit-relay
INSTALLER=/etc/dragon-fruit-relay/dragon-fruit-relay.sh
ROOT_COPY=/root/dragon-fruit-relay-ingress.sh
STATE_DIR=/var/lib/dragon-fruit-relay/updates
PREVIOUS="${STATE_DIR}/previous"
STATE="${STATE_DIR}/state.conf"
ROLLBACK=/etc/dragon-fruit-relay/bin/update-rollback
WATCHDOG=/etc/dragon-fruit-relay/bin/update-rollback-watchdog
UPDATE_DEADLINE_SECONDS=450
CHANGE_LOCK=/run/lock/dragon-fruit-relay-ingress-change.lock
ROLLBACK_UNIT=dragon-fruit-relay-update-rollback.service
ROLLBACK_RUNTIME_MASKED=0

# DFR_UPDATE_RUNTIME_MASK_GUARD
restore_rollback_runtime_mask() {
    if (( ROLLBACK_RUNTIME_MASKED )); then
        systemctl unmask --runtime "$ROLLBACK_UNIT" >/dev/null 2>&1 || true
        systemctl daemon-reload >/dev/null 2>&1 || true
        ROLLBACK_RUNTIME_MASKED=0
    fi
}
trap restore_rollback_runtime_mask EXIT

install -d -m 0755 /run/lock
exec 8>"$CHANGE_LOCK"
flock 8

read_previous_field() {
    local key="$1"
    [[ -r "$STATE" ]] || return 0
    sed -nE "s/^${key}=(.*)$/\\1/p" "$STATE" | head -n1 | tr -d "'\""
}

write_state() {
    local state="$1" error="${2:-}" now requested started
    now=$(date +%s)
    requested=$(read_previous_field UPDATE_REQUESTED_AT || true)
    started=$(read_previous_field UPDATE_STARTED_AT || true)
    [[ "$requested" =~ ^[0-9]+$ ]] || requested="$now"
    case "$state" in
        APPLYING|VERIFYING|CURRENT|COMMITTED|FAILED|ROLLED_BACK)
            [[ "$started" =~ ^[0-9]+$ ]] || started="$now"
            ;;
        *) started="${started:-}" ;;
    esac
    {
        printf 'UPDATE_STATE=%q\n' "$state"
        printf 'UPDATE_VERSION=%q\n' "$TARGET_VERSION"
        printf 'UPDATE_SHA256=%q\n' "$TARGET_SHA256"
        printf 'UPDATE_ERROR=%q\n' "$error"
        printf 'UPDATE_REQUESTED_AT=%q\n' "$requested"
        printf 'UPDATE_STARTED_AT=%q\n' "$started"
        case "$state" in
            CURRENT|COMMITTED|FAILED|ROLLED_BACK) printf 'UPDATE_FINISHED_AT=%q\n' "$now" ;;
            *) printf 'UPDATE_FINISHED_AT=%q\n' '' ;;
        esac
        printf 'UPDATE_AT=%q\n' "$now"
    } > "${STATE}.tmp"
    chmod 0600 "${STATE}.tmp"
    mv -f "${STATE}.tmp" "$STATE"
}

[[ -f "$NEW_ENGINE" ]] || { write_state FAILED 'downloaded engine is missing'; exit 1; }
bash -n "$NEW_ENGINE" || { write_state FAILED 'downloaded engine failed shell syntax validation'; exit 1; }
found=$(sed -nE 's/^readonly APP_VERSION="([^"]+)"/\1/p' "$NEW_ENGINE" | head -n1)
[[ "$found" == "$TARGET_VERSION" ]] || { write_state FAILED "downloaded engine declares ${found:-no version}, expected ${TARGET_VERSION}"; exit 1; }
found_sha=$(sha256sum "$NEW_ENGINE" | awk '{print $1}')
[[ "$found_sha" == "$TARGET_SHA256" ]] || { write_state FAILED "downloaded engine digest ${found_sha:-unknown} does not match target ${TARGET_SHA256}"; exit 1; }

mkdir -p "$PREVIOUS"
chmod 0700 "$STATE_DIR" "$PREVIOUS"
write_state STAGING
rm -rf "${PREVIOUS:?}/"*
for f in "$CLI" "$INSTALLER" "$ROOT_COPY"; do
    [[ -f "$f" ]] || continue
    case "$f" in
        "$CLI") saved=usr_local_sbin_dragon-fruit-relay ;;
        "$INSTALLER") saved=etc_dragon-fruit-relay_dragon-fruit-relay.sh ;;
        "$ROOT_COPY") saved=root_dragon-fruit-relay-ingress.sh ;;
    esac
    cp -a "$f" "$PREVIOUS/$saved"
done

write_state APPLYING
watchdog_deadline=$(( $(date +%s) + UPDATE_DEADLINE_SECONDS ))
watchdog_unit="dragon-fruit-relay-update-watchdog-$(date +%s)-$$"
if ! systemd-run --unit="$watchdog_unit" --collect --no-block --quiet -- \
        "$WATCHDOG" "$watchdog_deadline"; then
    write_state FAILED 'could not arm the independent software rollback watchdog'
    exit 1
fi
for f in "$CLI" "$INSTALLER"; do
    install -m 0750 "$NEW_ENGINE" "${f}.tmp.$$"
    bash -n "${f}.tmp.$$"
    mv -f "${f}.tmp.$$" "$f"
done
if [[ -f "$ROOT_COPY" ]]; then
    install -m 0750 "$NEW_ENGINE" "${ROOT_COPY}.tmp.$$"
    mv -f "${ROOT_COPY}.tmp.$$" "$ROOT_COPY"
fi

write_state VERIFYING
# Keep the boot-only rollback unit masked while the target engine regenerates
# and validates itself. Older target code must not be able to self-rollback
# during an intentional managed update/downgrade.
if systemctl mask --runtime "$ROLLBACK_UNIT" >/dev/null 2>&1; then
    ROLLBACK_RUNTIME_MASKED=1
fi
message=''
if ! timeout 120s env DFR_INTERNAL_NO_MAIN_LOCK=1 "$CLI" _managed-post-update >/dev/null 2>&1; then
    message='post-update runtime refresh failed; previous engine restored'
elif ! timeout 150s env DFR_INTERNAL_NO_MAIN_LOCK=1 "$CLI" _managed-reconcile >/dev/null 2>&1; then
    message='post-update reconcile failed; previous engine restored'
elif ! timeout 45s env DFR_INTERNAL_NO_MAIN_LOCK=1 "$CLI" _managed-healthcheck >/dev/null 2>&1; then
    message='post-update health check failed; previous engine restored'
else
    installed=$(sed -nE 's/^readonly APP_VERSION="([^"]+)"/\1/p' "$CLI" | head -n1)
    installed_sha=$(sha256sum "$CLI" | awk '{print $1}')
    if [[ "$installed" == "$TARGET_VERSION" && "$installed_sha" == "$TARGET_SHA256" ]]; then
        write_state CURRENT
        restore_rollback_runtime_mask
        systemctl start "$ROLLBACK_UNIT" >/dev/null 2>&1 || true
        exit 0
    fi
    message="post-update build mismatch (${installed:-unknown}/${installed_sha:-unknown}); previous engine restored"
fi

write_state FAILED "$message"
"$ROLLBACK" --now "$message" >/dev/null 2>&1 || true
exit 1
EOF_DFR_MANAGED_UPDATE

    cat > "$UPDATE_ROLLBACK_HELPER" <<'EOF_DFR_UPDATE_ROLLBACK'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
STATE=/var/lib/dragon-fruit-relay/updates/state.conf
PREVIOUS=/var/lib/dragon-fruit-relay/updates/previous
reason="${2:-automatic rollback restored the previous Client engine}"

[[ -r "$STATE" ]] || exit 0
# shellcheck disable=SC1090
source "$STATE"
if [[ "${1:-}" == --boot ]]; then
    case "${UPDATE_STATE:-}" in STAGING|APPLYING|VERIFYING|FAILED) ;; *) exit 0 ;; esac
fi

restored=0
for pair in \
    "usr_local_sbin_dragon-fruit-relay:/usr/local/sbin/dragon-fruit-relay" \
    "etc_dragon-fruit-relay_dragon-fruit-relay.sh:/etc/dragon-fruit-relay/dragon-fruit-relay.sh" \
    "root_dragon-fruit-relay-ingress.sh:/root/dragon-fruit-relay-ingress.sh"; do
    saved=${pair%%:*}; target=${pair#*:}
    [[ -f "$PREVIOUS/$saved" ]] || continue
    install -m 0750 "$PREVIOUS/$saved" "${target}.tmp.$$"
    bash -n "${target}.tmp.$$"
    mv -f "${target}.tmp.$$" "$target"
    restored=1
done

if (( restored )); then
    timeout 120s env DFR_INTERNAL_NO_MAIN_LOCK=1 /usr/local/sbin/dragon-fruit-relay _managed-post-update >/dev/null 2>&1 || true
    timeout 150s env DFR_INTERNAL_NO_MAIN_LOCK=1 /usr/local/sbin/dragon-fruit-relay _managed-reconcile >/dev/null 2>&1 || true
fi
now=$(date +%s)
{
    printf 'UPDATE_STATE=ROLLED_BACK\n'
    printf 'UPDATE_VERSION=%q\n' "${UPDATE_VERSION:-unknown}"
    printf 'UPDATE_SHA256=%q\n' "${UPDATE_SHA256:-}"
    printf 'UPDATE_ERROR=%q\n' "$reason"
    printf 'UPDATE_REQUESTED_AT=%q\n' "${UPDATE_REQUESTED_AT:-}"
    printf 'UPDATE_STARTED_AT=%q\n' "${UPDATE_STARTED_AT:-$now}"
    printf 'UPDATE_FINISHED_AT=%q\n' "$now"
    printf 'UPDATE_AT=%q\n' "$now"
} > "${STATE}.tmp"
chmod 0600 "${STATE}.tmp"
mv -f "${STATE}.tmp" "$STATE"
EOF_DFR_UPDATE_ROLLBACK

    cat > "$UPDATE_WATCHDOG" <<'EOF_DFR_UPDATE_WATCHDOG'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

DEADLINE="$1"
ROLLBACK=/etc/dragon-fruit-relay/bin/update-rollback
STATE=/var/lib/dragon-fruit-relay/updates/state.conf

[[ "$DEADLINE" =~ ^[0-9]+$ ]] || exit 64

while :; do
    current=''
    if [[ -r "$STATE" ]]; then
        current=$(sed -nE 's/^UPDATE_STATE=(.*)$/\1/p' "$STATE" | tr -d "'\\\"")
    fi
    case "$current" in
        CURRENT|COMMITTED|ROLLED_BACK) exit 0 ;;
    esac
    now=$(date +%s)
    (( now >= DEADLINE )) && break
    sleep 3
done

"$ROLLBACK" --now >/dev/null 2>&1 || true
EOF_DFR_UPDATE_WATCHDOG

    write_ingress_user_access_files

    # DFR_INGRESS_MANAGEMENT_UNIT_HEREDOC_FIX
    # Keep every generated systemd definition inside an explicit heredoc.
    # A prior development build lost these opening heredoc lines, causing unit
    # contents such as [Service] to execute as shell commands during enrollment.
    cat > "$CONTROL_SERVICE_FILE" <<EOF_DFR_CONTROL_SERVICE
# Managed by Dragon Fruit Relay.
[Unit]
Description=Dragon Fruit Relay managed Client control poll
After=network-online.target strongswan.service dragon-fruit-relay-xfrm.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${CONTROL_AGENT} --once
User=root
Group=root
TimeoutStartSec=600
Nice=10
EOF_DFR_CONTROL_SERVICE

    cat > "$CONTROL_TIMER_FILE" <<EOF_DFR_CONTROL_TIMER
# Managed by Dragon Fruit Relay.
[Unit]
Description=Dragon Fruit Relay managed Client control timer

[Timer]
# DFR_CONTROL_TIMER_RESILIENCE
OnActiveSec=5s
OnUnitActiveSec=10s
AccuracySec=5s
Unit=${CONTROL_SERVICE}

[Install]
WantedBy=timers.target
EOF_DFR_CONTROL_TIMER

    cat > "$CONTROL_BOOT_RECOVERY_SERVICE_FILE" <<EOF_DFR_CONFIG_BOOT_RECOVERY_UNIT
# Managed by Dragon Fruit Relay.
[Unit]
Description=Dragon Fruit Relay interrupted configuration recovery
DefaultDependencies=no
After=local-fs.target
Before=dragon-fruit-relay-xfrm.service strongswan.service network-online.target

[Service]
Type=oneshot
ExecStart=${CONTROL_BOOT_RECOVERY}

[Install]
WantedBy=multi-user.target
EOF_DFR_CONFIG_BOOT_RECOVERY_UNIT

    cat > "$UPDATE_ROLLBACK_SERVICE_FILE" <<EOF_DFR_UPDATE_ROLLBACK_UNIT
# Managed by Dragon Fruit Relay.
[Unit]
Description=Dragon Fruit Relay Client update rollback guard
DefaultDependencies=no
After=local-fs.target
Before=network-online.target ${CONTROL_SERVICE}

[Service]
Type=oneshot
ExecStart=${UPDATE_ROLLBACK_HELPER} --boot

[Install]
WantedBy=multi-user.target
EOF_DFR_UPDATE_ROLLBACK_UNIT

    chmod 0750 "$CONTROL_AGENT" "$CONTROL_TX_HELPER" "$CONTROL_TX_WATCHDOG" "$CONTROL_BOOT_RECOVERY" "$UPDATE_HELPER" "$UPDATE_ROLLBACK_HELPER" "$UPDATE_WATCHDOG"
    chmod 0644 "$CONTROL_SERVICE_FILE" "$CONTROL_TIMER_FILE" "$CONTROL_BOOT_RECOVERY_SERVICE_FILE" "$UPDATE_ROLLBACK_SERVICE_FILE"

    link_managed_unit "$CONTROL_SERVICE"
    link_managed_unit "$CONTROL_TIMER"
    link_managed_unit "$CONTROL_BOOT_RECOVERY_SERVICE"
    link_managed_unit "$UPDATE_ROLLBACK_SERVICE"
    enable_managed_unit_link "$CONTROL_TIMER" timers.target || true
    enable_managed_unit_link "$CONTROL_BOOT_RECOVERY_SERVICE" multi-user.target || true
    enable_managed_unit_link "$UPDATE_ROLLBACK_SERVICE" multi-user.target || true

    return 0
}

ingress_management_runtime_current ()
{
    [[ -x "$CONTROL_AGENT" ]] || return 1
    grep -Fq 'DFR_CONTROL_AGENT_ENDPOINT_SYNC_SELF_HEAL' "$CONTROL_AGENT" 2>/dev/null || return 1
    grep -Fq 'DFR_CONTROL_AGENT_REPORT_CONTRACT_V2' "$CONTROL_AGENT" 2>/dev/null
}

ensure_ingress_management_current ()
{
    load_config
    [[ "${MANAGED_CONTROL:-no}" == yes ]] || return 0
    write_ingress_management_files
    systemctl daemon-reload >/dev/null 2>&1 || return 1
    systemctl enable "$CONTROL_TIMER" "$UPDATE_ROLLBACK_SERVICE" >/dev/null 2>&1 || true

    # The rollback unit is a BOOT recovery guard, not an update-time service.
    # Starting it while the updater is legitimately in STAGING/APPLYING/
    # VERIFYING makes the new engine roll itself back during validation.
    # Leave the enabled boot guard alone while an update is active.
    local active_update_state=''
    if [[ -r "$UPDATE_CURRENT_STATE" ]]; then
        unset UPDATE_STATE
        # shellcheck disable=SC1090
        source "$UPDATE_CURRENT_STATE"
        active_update_state="${UPDATE_STATE:-}"
    fi
    case "$active_update_state" in
        STAGING|APPLYING|VERIFYING) ;;
        *) systemctl start "$UPDATE_ROLLBACK_SERVICE" >/dev/null 2>&1 || true ;;
    esac

    # Re-arm an already-active timer too; start alone can leave a stale timer
    # armed incorrectly after interrupted enrollment/update work.
    systemctl restart --no-block "$CONTROL_TIMER" >/dev/null 2>&1 || true
    return 0
}

user_control_call ()
{
    local verb="$1"
    command -v sudo >/dev/null 2>&1 || { early_error 'sudo is required for safe Client user operations.'; return 1; }
    sudo -n "$USER_CONTROL" "$verb"
}

ingress_user_navigation ()
{
    local choice
    while :; do
        clear_screen
        dfr_ui_header 'CLIENT | NAVIGATE'
        section_title 'Go to'
        ui_menu_item 1 'Status & Detailed Summary' neutral
        ui_menu_item 2 'Diagnostics' neutral
        ui_menu_item 3 'Managed Software & CONTROL' neutral
        ui_menu_item 4 'Enrollment Status' neutral
        printf '\n' > "$TTY_OUT"
        section_title 'Navigation'
        ui_menu_item M 'Client Menu' navigation
        ui_menu_item B 'Back' back
        ui_menu_item Q 'Exit' destructive
        choice=$(prompt '  Select destination: ') || return 0
        case "$choice" in
            1) user_control_call status || true; pause_screen ;;
            2) user_control_call diagnostics || true ;;
            3) user_control_call update-status || true; pause_screen ;;
            4) user_control_call enrollment-status || true; pause_screen ;;
            m|M|b|B|0) return 0 ;;
            q|Q|99) exit 0 ;;
            *) warn 'Invalid selection.'; sleep 0.35 ;;
        esac
    done
}

ingress_user_menu ()
{
    local choice
    while :; do
        clear_screen
        dfr_ui_header 'CLIENT MENU'
        user_control_call summary || true

        section_title 'Operations'
        ui_menu_item 1 'Status & Detailed Summary' neutral
        ui_menu_item 2 'Diagnostics' neutral
        ui_menu_item 3 'Logs' neutral
        section_title 'Connection'
        ui_menu_item 4 'Start / Reconnect' positive
        ui_menu_item 5 'Stop' caution
        ui_menu_item 6 'Repair Connection' neutral
        ui_menu_item 7 'Enrollment Status' neutral
        printf '\n  %sAdministrative token replacement, removal and uninstall require: sudo dragon-fruit-relay%s\n' "$C_DIM" "$C_RESET" > "$TTY_OUT"
        printf '\n' > "$TTY_OUT"
        section_title 'Navigation'
        ui_menu_item R 'Refresh' neutral
        ui_menu_item G 'Navigate' navigation
        ui_menu_item Q 'Exit' destructive
        choice=$(prompt '  Select an option: ') || return 0
        case "$choice" in
            1) user_control_call status || true; pause_screen ;;
            2) user_control_call diagnostics || true ;;
            3) user_control_call logs || true; pause_screen ;;
            4) user_control_call reconnect || true; sleep 0.5 ;;
            5) user_control_call stop || true; sleep 0.5 ;;
            6) user_control_call repair || true; sleep 0.5 ;;
            7) user_control_call enrollment-status || true; pause_screen ;;
            r|R) user_control_call refresh || true ;;
            g|G) ingress_user_navigation ;;
            q|Q|0) return 0 ;;
            *) warn 'Invalid selection.'; sleep 0.35 ;;
        esac
    done
}

ingress_user_diagnostics_menu_root ()
{
    local choice
    while configured_ingress; do
        clear_screen
        dfr_ui_header 'CLIENT DIAGNOSTICS'
        ingress_diagnostic_summary
        cat > "$TTY_OUT" <<EOF_DFR_USER_DIAG

  ${C_BOLD}${C_MAGENTA}READ-ONLY DIAGNOSTICS${C_RESET}
  ${C_DIM}$(ui_rule $'\u2500')${C_RESET}
    ${C_CYAN}[1]${C_RESET}  Health summary
    ${C_GREEN}[2]${C_RESET}  End-to-end connectivity tests
    ${C_CYAN}[3]${C_RESET}  Tunnel session and traffic
    ${C_CYAN}[4]${C_RESET}  Routing and DNS paths
    ${C_CYAN}[5]${C_RESET}  Services and transport

  ${C_BOLD}${C_MAGENTA}NAVIGATION${C_RESET}
  ${C_DIM}$(ui_rule $'\u2500')${C_RESET}
    ${C_MAGENTA}[G]${C_RESET}  Navigate
    ${C_DIM}[B]${C_RESET}  Back
    ${C_RED}[Q]${C_RESET}  Exit
EOF_DFR_USER_DIAG
        choice=$(prompt '  Select a diagnostic view: ')
        case "$choice" in
            1) diagnostics_overview || true; pause_screen ;;
            2) ingress_connectivity_tests || true; pause_screen ;;
            3) diagnostics_tunnel; pause_screen ;;
            4) diagnostics_routing; pause_screen ;;
            5) diagnostics_ports; pause_screen ;;
            g|G) ingress_global_navigation ;;
            b|B|0) return 0 ;;
            q|Q|99) exit 0 ;;
            *) warn 'Invalid selection.'; sleep 1 ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# Dragon Fruit Relay Client runtime
# -----------------------------------------------------------------------------










upsert_shell_assignment() {
    local file="$1" key="$2" value="$3"
    [[ -f "$file" ]] || return 1
    if grep -qE "^${key}=" "$file"; then
        sed -i -E "s|^${key}=.*|${key}=$(printf '%q' "$value")|" "$file"
    else
        printf '%s=%q\n' "$key" "$value" >>"$file"
    fi
}






ingress_unconfigured_residual_present() {
    [[ -d "$CONFIG_DIR" || -d "$STATE_DIR" ]] && return 0
    compgen -G "$SYSTEMD_DIR/dragon-fruit-relay-*.service" >/dev/null && return 0
    compgen -G "$SYSTEMD_DIR/dragon-fruit-relay-*.timer" >/dev/null && return 0
    dragonfruit_managed_xfrm_interfaces | grep -q . && return 0
    return 1
}

ingress_remove_before_configuration() {
    if ! ingress_unconfigured_residual_present; then
        warn 'No configured Client connection or residual Dragon Fruit Relay state was found.'
        return 0
    fi
    remove_tunnel_configuration
}

ingress_uninstall_before_configuration() {
    local package_snapshot=''
    if [[ -f "$PACKAGE_STATE_FILE" ]]; then package_snapshot=$(mktemp /tmp/dragon-fruit-relay-package-state.XXXXXX); cp -a -- "$PACKAGE_STATE_FILE" "$package_snapshot"; fi
    confirm 'Completely uninstall Dragon Fruit Relay and restore available original state?' no || { [[ -n "$package_snapshot" ]] && rm -f -- "$package_snapshot"; return 0; }
    ingress_unconfigured_residual_present && clean_abandoned_install_before_setup
    if [[ -n "$package_snapshot" ]]; then remove_added_packages "$package_snapshot"; rm -f -- "$package_snapshot"; fi
    rm -rf "$STATE_DIR" "$CONFIG_DIR"; remove_cli_command; systemctl daemon-reload >/dev/null 2>&1 || true
    success 'Dragon Fruit Relay, residual managed state, and the management command were removed.'
}

ingress_unconfigured_menu() {
    local choice
    while [[ ! -f "$CONFIG_FILE" ]]; do
        diagnostics_preflight
        section_title 'Enrollment'
        ui_menu_item 1 'Enroll Client from a Server DFR1 token' positive
        ui_menu_item 2 'Run preflight diagnostics again' neutral
        section_title 'Removal'
        ui_menu_item 3 'Remove existing or residual DFR state' caution
        ui_menu_item 4 'Completely uninstall Dragon Fruit Relay' destructive
        printf '\n  %s[Q]%s  Exit\n' "$C_RED" "$C_RESET" > "$TTY_OUT"
        choice=$(prompt '  Select an option: ')
        case "$choice" in
            1) setup_ingress; return ;; 2) diagnostics_preflight; pause_screen ;; 3) ingress_remove_before_configuration; pause_screen ;; 4) ingress_uninstall_before_configuration; return ;; q|Q|0) exit 0 ;; *) warn 'Invalid selection.'; sleep 1 ;;
        esac
    done
}



ingress_usage() {
    cat <<'EOF_INGRESS_USAGE'
Usage: dragon-fruit-relay [command]

Primary Client commands:
  menu                                  Open the Client management menu
  status|health                         Show Client status and health
  diagnostics|diag                      Open diagnostics
  logs|log                              Show recent warnings and errors
  start|reconnect|restart               Start or reconnect the tunnel
  stop                                  Stop the tunnel temporarily
  repair|reconfigure                    Repair managed connection files/services
  refresh                               Refresh monitoring, CONTROL and subscription status
  update-status                         Show managed software/configuration status
  enrollment-status                     Show token enrollment state without secrets
  enroll [--token TOKEN|--token-file FILE]
                                        Re-enroll the installed connection with DFR1
  replace [--token TOKEN|--token-file FILE]
                                        Replace the Client connection using a new DFR1 token
  upgrade                               Refresh this standalone DFR installation in place
  test                                  Run end-to-end connectivity tests
  recover                               Run Client recovery
  remove                                Remove the local Client connection
  uninstall                             Completely uninstall and restore saved host state
  version                               Show version

Fresh installation aliases:
  connect|init|client|ingress [--token TOKEN|--token-file FILE]
EOF_INGRESS_USAGE
}

open_ingress_main_menu() {
    if configured_ingress; then ingress_interactive_menu; else ingress_unconfigured_menu; fi
}

read_enrollment_token_file ()
{
    local file="$1" token
    [[ -n "$file" ]] || die 'The --token-file option requires a file path.'
    [[ -f "$file" && -r "$file" ]] || die "Enrollment token file is not readable: ${file}"
    IFS= read -r token < "$file" || true
    token=${token%$'\r'}
    [[ -n "$token" ]] || die "Enrollment token file is empty: ${file}"
    printf '%s' "$token"
}

ingress_main() {
    local command="${1:-menu}" token=''
    case "$command" in version) printf '%s %s client\n' "$APP_NAME" "$APP_VERSION"; return 0 ;; -h|--help|help) ingress_usage; return 0 ;; esac
    if [[ "$DFR_UNPRIVILEGED_MODE" == yes ]]; then
        case "$command" in menu) ingress_user_menu ;; status|health) user_control_call status ;; diagnostics|diag) user_control_call diagnostics ;; logs|log) user_control_call logs ;; test) user_control_call test ;; start|recover|reconnect|restart) user_control_call reconnect ;; stop) user_control_call stop ;; repair|reconfigure) user_control_call repair ;; refresh) user_control_call refresh ;; update-status) user_control_call update-status ;; enrollment-status) user_control_call enrollment-status ;; *) early_error "Administrative command '${command}' requires root."; return 1 ;; esac; return
    fi
    require_root_and_platform; install_cli_command
    hub_configured && die 'A Server is configured on this machine. Use the Server installer here.'
    case "$command" in
        _managed-healthcheck) configured_ingress || exit 1; managed_healthcheck ;;
        _managed-reconcile) configured_ingress || exit 1; managed_reconcile "${2:-no}" ;;
        _managed-set-server-endpoint) configured_ingress || exit 1; [[ -n "${2:-}" ]] || die 'Internal endpoint update requires an endpoint.'; managed_set_server_endpoint "$2" ;;
        _managed-regenerate-runtime) configured_ingress || exit 1; load_config; ensure_ingress_runtime_files ;;
        _managed-apply-config) configured_ingress || exit 1; [[ -n "${2:-}" ]] || die 'Internal config apply requires CANDIDATE.'; managed_apply_config_candidate "$2" ;;
        _managed-rollback-config) configured_ingress || exit 1; managed_rollback_config "${2:-}" ;;
        _managed-post-update) configured_ingress || exit 1; ensure_ingress_runtime_files; ensure_ingress_management_current ;;
        _user-summary-root) configured_ingress || exit 1; ingress_monitoring_summary ;;
        _user-status-root) configured_ingress || exit 1; ingress_detailed_status_screen ;;
        _user-diagnostics-root) configured_ingress || exit 1; ingress_user_diagnostics_menu_root ;;
        _user-logs-root) configured_ingress || exit 1; diagnostics_logs ;;
        _user-test-root) configured_ingress || exit 1; ingress_connectivity_tests ;;
        _user-reconnect-root) configured_ingress || exit 1; start_tunnel ;;
        _user-stop-root) configured_ingress || exit 1; stop_tunnel ;;
        _user-repair-root) configured_ingress || exit 1; repair_current ;;
        _user-refresh-root) configured_ingress || exit 1; load_config; subscription_refresh_best_effort; "$CONTROL_AGENT" --once || true; ingress_main_dashboard ;;
        _user-update-status-root) configured_ingress || exit 1; managed_update_status_screen ;;
        _user-enrollment-status-root) configured_ingress || exit 1; ingress_enrollment_status_screen ;;
        menu) open_ingress_main_menu ;;
        connect|init|client|ingress)
            if [[ "${2:-}" == --token ]]; then token="${3:-}"; [[ -n "$token" ]] || die 'The --token option requires a token.'; setup_ingress "$token";
            elif [[ "${2:-}" == --token-file ]]; then token=$(read_enrollment_token_file "${3:-}"); setup_ingress "$token";
            elif [[ -n "${2:-}" ]]; then die "Unknown Client install option: ${2}"; else open_ingress_main_menu; fi ;;
        enrollment-status) configured_ingress || die 'No Client connection is configured.'; ingress_enrollment_status_screen ;;
        enroll|replace)
            configured_ingress || die 'No Client connection is configured.'
            if [[ "${2:-}" == --token ]]; then token="${3:-}"; [[ -n "$token" ]] || die 'The --token option requires a token.'; elif [[ "${2:-}" == --token-file ]]; then token=$(read_enrollment_token_file "${3:-}"); elif [[ -n "${2:-}" ]]; then die "Unknown ${command} option: ${2}"; fi
            [[ "$command" == enroll ]] && managed_enroll_existing_ingress "$token" || replace_ingress_connection "$token" ;;
        reconfigure|repair) configured_ingress || die 'No Client connection is configured.'; repair_current ;;
        upgrade) configured_ingress || die 'No Client connection is configured.'; install_self_copy; load_config; ensure_ingress_runtime_files; ensure_ingress_management_current; repair_current ;;
        status) configured_ingress && ingress_detailed_status_screen || diagnostics_preflight ;;
        health) configured_ingress && diagnostics_overview || diagnostics_preflight ;;
        diagnostics|diag) configured_ingress && ingress_diagnostics_menu || diagnostics_preflight ;;
        logs|log) configured_ingress || die 'No Client connection is configured.'; diagnostics_logs ;;
        test) configured_ingress || die 'No Client connection is configured.'; ingress_connectivity_tests ;;
        start|reconnect|restart) configured_ingress || die 'No Client connection is configured.'; start_tunnel ;;
        refresh) configured_ingress || die 'No Client connection is configured.'; load_config; subscription_refresh_best_effort; "$CONTROL_AGENT" --once || true; ingress_main_dashboard ;;
        update-status) configured_ingress || die 'No Client connection is configured.'; managed_update_status_screen ;;
        stop) configured_ingress || die 'No Client connection is configured.'; stop_tunnel ;;
        recover) configured_ingress || die 'No Client connection is configured.'; run_recovery ;;
        remove) if configured_ingress; then remove_tunnel_configuration; else ingress_remove_before_configuration; fi ;;
        uninstall) if configured_ingress; then uninstall_routevpn; else ingress_uninstall_before_configuration; fi ;;
        *) ingress_usage; exit 1 ;;
    esac
}

trap 'on_error "$LINENO" "$BASH_COMMAND" "$?"' ERR

if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" ]]; then
    log_line SESSION "version=${APP_VERSION} role=ingress pid=$$ command=${*:-menu}"
    ingress_main "$@"
fi

