#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
INGRESS="$ROOT/main-engine/dragon-fruit-relay-ingress.sh"

grep -q '^record_unit_state_initial ()' "$INGRESS"
grep -q '^backup_common_paths ()' "$INGRESS"
grep -q '^backup_ingress_paths ()' "$INGRESS"
grep -q 'backup_original /etc/resolv.conf' "$INGRESS"
grep -q 'backup_original /etc/nsswitch.conf' "$INGRESS"
grep -q 'backup_original /etc/systemd/resolved.conf' "$INGRESS"

# Exercise the exact pre-token backup transaction in an isolated mount namespace
# when the kernel/container permits user and mount namespaces.
can_use_private_mount_namespace() {
    unshare -rm bash --noprofile --norc -c '
        set -Eeuo pipefail
        probe=$(mktemp -d)
        mount -t tmpfs tmpfs "$probe"
        umount "$probe"
        rmdir "$probe"
    ' >/dev/null 2>&1
}

if [[ ${EUID:-$(id -u)} -eq 0 ]] &&
   command -v unshare >/dev/null 2>&1 &&
   can_use_private_mount_namespace; then
    unshare -rm bash --noprofile --norc -c '
        set -Eeuo pipefail
        mount -t tmpfs tmpfs /var/lib
        mount -t tmpfs tmpfs /var/log
        INGRESS_PATH="$1"
        set -- version
        source "$INGRESS_PATH"
        type -t record_unit_state_initial >/dev/null
        type -t backup_common_paths >/dev/null
        type -t backup_ingress_paths >/dev/null
        backup_ingress_paths
        test -f "$MANIFEST_FILE"
        test -f "$PACKAGE_STATE_FILE"
        grep -q "^STRONGSWAN_UNIT_EXISTED=" "$PACKAGE_STATE_FILE"
    ' _ "$INGRESS"
else
    printf '%s\n' 'Client fresh-setup transaction: namespace runtime check skipped; static backup contract verified'
fi

printf '%s\n' 'Client fresh-setup transaction: pre-token backup path OK'
