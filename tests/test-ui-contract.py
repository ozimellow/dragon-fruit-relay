#!/usr/bin/env python3
from pathlib import Path
import re
root=Path(__file__).resolve().parents[1]
installer=(root/'install.sh').read_text()
e=(root/'main-engine'/'dragon-fruit-relay-egress.sh').read_text()
i=(root/'main-engine'/'dragon-fruit-relay-ingress.sh').read_text()

# Mature donor-derived runtime hierarchy remains intact.
for needle in [
    "dfr_ui_header 'MAIN MENU'",
    "ui_menu_item 1 'Operations Center' neutral",
    "ui_menu_item 2 'Connections' neutral",
    "ui_menu_item 3 'Server Operations' neutral",
    "dfr_ui_header 'OPERATIONS CENTER'",
    "dfr_ui_header 'CONNECTIONS'",
    "dfr_ui_header 'CONNECTION DOSSIER'",
    "dfr_ui_header 'SERVER OPERATIONS'",
    "ui_menu_item 5 'Client Software' neutral",
    "ui_menu_item 6 'Backups & Recovery' neutral",
    "ui_menu_item 7 'Server Logs' neutral",
    "ui_menu_item 8 'Start All Connections' positive",
    "ui_menu_item 9 'Stop All Connections Temporarily' caution",
    "ui_menu_item 10 'Repair All Connection Configurations' neutral",
    "cat > \"$TTY_OUT\" <<EOF_CLIENT_DIAG",
    "${C_CYAN}[1]${C_RESET}  IKE / CHILD SA & Traffic",
    "${C_YELLOW}[7]${C_RESET}  Recent Warnings & Errors",
    "${C_RED}[8]${C_RESET}  Raw strongSwan State",
    "${C_GREEN}[11]${C_RESET}  Start / Listen",
    "dfr_ui_header 'SERVER CONFIGURATION | RUNTIME PORTS'",
    "ui_summary_begin 'Runtime port summary'",
]:
    assert needle in e, needle
assert "ui_menu_item 4 '"+'DF'+'RMI'+"'" not in e
assert 'DF'+'RMI Path Health' not in e

for needle in [
    "dfr_ui_header 'CLIENT MENU'",
    "ui_summary_begin 'Monitoring summary'",
    "ui_summary_row 'Connection'",
    "ui_summary_row 'Subscription'",
    "ui_summary_row 'Period'",
    "ui_summary_row 'Traffic'",
    "ui_summary_row 'Managed control'",
    "ui_summary_row 'Configuration'",
    "section_title 'Operations'",
    "ui_menu_item 1 'Status & Detailed Summary' neutral",
    "ui_menu_item 2 'Diagnostics' neutral",
    "ui_menu_item 3 'Logs' neutral",
    "section_title 'Connection'",
    "ui_menu_item 4 'Start / Reconnect' positive",
    "ui_menu_item 5 'Stop' caution",
    "ui_menu_item 6 'Repair Connection' neutral",
    "ui_menu_item 7 'Enrollment & Token' neutral",
    "section_title 'System'",
    "ui_menu_item 8 'Remove Connection from This Client' caution",
    "ui_menu_item 9 'Uninstall Dragon Fruit Relay' destructive",
    "ui_menu_item R 'Refresh' neutral",
    "ui_menu_item G 'Navigate' navigation",
    "dfr_ui_header 'CLIENT | NAVIGATE'",
    "dfr_ui_header 'CLIENT | ENROLLMENT & TOKEN'",
    "dfr_ui_header 'CLIENT DIAGNOSTICS'",
    "ui_menu_item 1 'Health Summary' neutral",
    "ui_menu_item 2 'End-to-End Connectivity Test' positive",
    "ui_menu_item 7 'Export Redacted Diagnostic Report' neutral",
]:
    assert needle in i, needle

# Main Client menu must stay compact: detailed subscription/control cards belong
# to Status/Managed Status screens, not the first screen.
client_menu=i[i.index("ingress_interactive_menu ()"):i.index("ingress_user_health_text ()")]
assert "ingress_monitoring_summary" in client_menu
monitor_block=i[i.index("ingress_monitoring_summary ()"):i.index("ingress_enrollment_menu ()")]
assert 'ui_summary_row \'Period\' "$period_text" plain' in monitor_block
assert "subscription_format_date \"${SUB_STARTS_AT:-0}\" 'Immediate'" in monitor_block
assert "subscription_format_date \"${SUB_EXPIRES_AT:-0}\" 'Never'" in monitor_block
assert "ui_summary_row 'Configuration' \"$config_display\" state" in monitor_block
managed_block=i[i.index("ingress_managed_dashboard_rows ()"):i.index("ingress_enrollment_state ()")]
assert "ui_summary_row 'Configuration' \"$config_display\" state" in managed_block
assert "subscription_print_dashboard" not in client_menu
assert "ingress_main_dashboard" not in client_menu
assert "ui_menu_item 10" not in client_menu and "ui_menu_item 11" not in client_menu and "ui_menu_item 12" not in client_menu

# Client information architecture: Status owns the full operational dossier;
# Diagnostics owns diagnostic checks only and must not duplicate the dossier.
assert "dfr_ui_header 'CLIENT STATUS & DETAILS'" in i
status_block=i[i.index("ingress_detailed_status_screen ()"):i.index("ingress_diagnostic_summary ()")]
assert "ingress_main_dashboard" in status_block
diag_block=i[i.index("ingress_diagnostics_menu ()"):i.index("ingress_interactive_menu ()")]
assert "ingress_diagnostic_summary" in diag_block
assert "ingress_main_dashboard" not in diag_block
user_diag=i[i.index("ingress_user_diagnostics_menu_root ()"):i.index("# -----------------------------------------------------------------------------\n# Dragon Fruit Relay Client runtime")]
assert "ingress_diagnostic_summary" in user_diag
assert "ingress_main_dashboard" not in user_diag
assert "_user-status-root) configured_ingress || exit 1; ingress_detailed_status_screen" in i
assert "section_title 'Managed configuration'" in i
assert "APPLIED) printf 'VERIFYING COMMIT'" in i


# Complete Server connection overview must remain a true dossier: the compact
# managed-services state is followed by the full authoritative subscription
# and traffic detail rather than only a single ACTIVE/SUSPENDED flag.
server_overview=e[e.index("show_client_status ()"):e.index("# ============================================================================\n# DFR_CANONICAL_UI_AUDIT_FINAL")]
assert "ui_summary_begin 'Managed services summary'" in server_overview
assert 'ui_summary_row \'Subscription\' "$substate" state' in server_overview
assert 'subscription_print_summary "$name" \'Subscription & Traffic\'' in server_overview
subscription_block=e[e.index("subscription_print_summary ()"):e.index("server_endpoint_sync_summary ()")]
for needle in [
    "ui_summary_row 'Status'",
    "ui_summary_row 'Starts'",
    "ui_summary_row 'Expires'",
    "ui_summary_row 'Upload'",
    "ui_summary_row 'Download'",
    "ui_summary_row 'Used'",
    "ui_summary_row 'Remaining'",
    "ui_summary_row 'Allowance'",
    "ui_summary_row 'Speed'",
    "ui_summary_row 'Lifetime traffic'",
]:
    assert needle in subscription_block, needle

# The standalone role installer must use the same compact dashboard grammar as
# the mature UI, not the legacy ASCII-banner installer presentation.
for needle in [
    "ui_header 'INSTALLER'",
    "section 'System preflight'",
    "check pass 'Existing DFR state' 'none; fresh standalone installation'",
    "section 'Choose this machine role'",
    "menu_item 1 'Egress Hub (Server)'",
    "menu_item 2 'Ingress Client (Client)'",
    "ui_header 'INSTALLER | UPDATE'",
    "check pass 'Upgrade routing' 'Existing role preserved automatically'",
]:
    assert needle in installer, needle
assert '/\\      /\\' not in installer
assert 'DRAGON FRUIT   .  .' not in installer
assert 'export DFR_SETUP_UI_ACTIVE=yes' in installer

# Both engine install/setup paths use dashboard headers + summaries. They must
# not reintroduce the old repeated giant banner during enroll/replace/setup.
for needle in [
    "dfr_ui_header 'SERVER INSTALLATION'",
    "ui_summary_begin 'Installation plan' 'READY'",
    "section_title 'System preparation'",
    "section_title 'Server endpoint'",
    "section_title 'Applying Server configuration'",
    "ui_summary_begin 'Installation complete' 'READY'",
]:
    assert needle in e, needle
for needle in [
    "dfr_ui_header 'CLIENT INSTALLATION'",
    "ui_summary_begin 'Preflight'",
    "section_title 'Enrollment readiness'",
    "ui_menu_item 1 'Enroll Client from a Server DFR1 token' positive",
    "dfr_ui_header 'CLIENT INSTALLATION | PREPARE'",
    "ui_summary_begin 'Current host state'",
    "section_title 'Protected installation transaction'",
    "dfr_ui_header 'CLIENT | REPLACE CONNECTION'",
    "ui_summary_begin 'Current connection' 'ACTIVE'",
    "ui_summary_begin 'Replacement target' 'READY'",
    "ui_summary_begin 'Enrollment plan' 'VALIDATED'",
    "section_title 'Applying Client runtime'",
    "ui_summary_begin 'Installation complete' 'READY'",
]:
    assert needle in i, needle

# Fresh Client enrollment is an affirmative flow: Enter continues by default.
assert "confirm 'Continue with Client installation' yes" in i

# Legacy installer-specific copy must stay gone from the redesigned setup path.
for engine in (e,i):
    assert "print_check info 'Progress'" in engine
    assert "print_check pass 'Progress'" in engine
    assert "print_check warn 'Attention'" in engine
    assert "print_check fail 'Failure'" in engine

for bad in (
    "section_title 'Ready to configure'",
    "${C_BOLD}${C_MAGENTA}TOKEN ENROLLMENT${C_RESET}",
    "section_title 'Fresh Client installation'",
    "banner;\n    section_title 'Replace Client connection'",
):
    assert bad not in i, bad


# Endpoint management must never describe a healthy stable endpoint as disabled.
for needle in [
    "ui_summary_row 'Endpoint management'",
    'ui_summary_row \'Endpoint migration\' "$migration_state" state',
    "'Endpoint synchronization' 'Every enrolled Client reports the active endpoint. Future IP/FQDN changes remain available.'",
    "ui_menu_item 3 'Finish migration after handling previous endpoint' positive",
]:
    assert needle in e, needle
for bad in (
    "migration_state=${SERVER_ENDPOINT_UI_MIGRATION_STATE:-DISABLED}",
    "Disabled · no endpoint change is in progress",
    "Disabled until the Server endpoint is changed",
):
    assert bad not in e, bad

print('UI contract: mature donor-derived runtime hierarchy retained; endpoint management uses READY/IDLE/ACTIVE semantics; Server/Client installer flows use unified dashboard presentation')
