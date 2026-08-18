# Changelog

## 2.1.0-rc.1 — v2.1.0 prerelease candidate

- Added tag-driven GitHub Actions release automation with exact archive re-test, `SHA256SUMS`, signed-tag enforcement, GitHub prerelease publishing, and OIDC/Sigstore artifact attestations.
- Reworked the public README and maintainer release documentation for the standalone v2.1.0 source/package layout and verified prerelease installation flow.
- Fixed registry test teardown so CI does not retain an open SQLite handle after a successful contract test.

- Fixed managed configuration transactions so successful Client verification atomically finalizes the temporary transaction instead of leaving a permanent `COMMITTED`/`VERIFYING COMMIT` work item.
- Configuration coordinators now run in independent transient systemd units so CONTROL responder restarts cannot strand an in-flight configuration change.
- Client Monitoring, detailed status, and Managed Software & CONTROL views now expose managed configuration state separately from software update and last-operation state.

- Established Dragon Fruit Relay as an independent product lineage with its own version, schema identity, installer, release metadata, and future DFR-to-DFR upgrade path.
- Added explicit standalone lineage markers to managed configs and registry metadata; unmarked pre-lineage installations are rejected rather than imported or converted.
- Preserved the mature Egress Hub and Ingress Client operational model, terminal UI, connection lifecycle, diagnostics, health, fleet views, CONTROL, presence, quota, speed, subscription, accounting, Client software delivery, signing, rollout, rollback, backup, restore, and recovery workflows.
- Added a clean fresh registry schema (`registry_schema=1`) with an exact table/column contract test.
- Added a single `install.sh` that selects Egress Hub or Ingress Client on fresh machines and preserves the installed role during later standalone DFR upgrades.
- Made the Server endpoint valid as either a public IPv4 address or an optional FQDN.
- Added DFR1 enrollment tokens using the Server endpoint, custom UDP transport, connection identity, tunnel allocation, subscription listener, and CONTROL listener.
- Made an empty Egress Hub a valid operational state for fleet/Operations Center views.
- Completed isolated Server-side connection removal and clear Client-side local removal semantics.
- Regenerated the Server's bundled Client payload from the exact v2.1.0 Ingress engine and bound it to its SHA-256.
- Added release verification for shell syntax, generated helpers, embedded Python, schema, endpoints, token contract, installer dispatch, bundled Client integrity, sanitization, manifest, and extracted archive contents.
- Retained the donor terminal UI hierarchy and keyboard positions for unrelated Server/Client workflows; removed-product slots disappear without redesigning surrounding screens.
- Hardened Server initialization, connection materialization, and Client setup transactions so a failed inner step cannot be masked by Bash conditional `errexit` behavior.
- Added safe recovery for an interrupted zero-connection v2.1.0 standalone registry while refusing destructive recovery when connection rows exist.
- Added UI-contract and fail-fast regression tests.
- Corrected endpoint lifecycle semantics: a healthy stable IP or FQDN endpoint is READY/IDLE with enrolled Clients SYNCED, not DISABLED.
- Endpoint changes now remain ACTIVE until Clients converge, then become READY TO FINISH while previous endpoint tracking is retained for explicit operator completion.
- Added endpoint-drift detection/reconciliation even when no migration is open, so Synchronize remains functional outside a transition.
- Added release-entrypoint identity checks so packaging cannot replace either Bash engine with an extracted helper.

- Fresh Egress initialization now auto-publishes the exact bundled v2.1.0 Client as STABLE; new connections default to AUTO and immediately target the stable payload rather than appearing MANUAL until an operator publishes a release.
- Server upgrades verify/refresh the bundled v2.1.0 stable payload while preserving an explicit REVOKED safety decision.
- Reworked the Client main menu into a compact Monitoring summary with detailed Status/Diagnostics/Managed Control/Enrollment workspaces behind it.
- Restored the Server Connection Overview as a complete detailed dossier, including the authoritative Subscription & Traffic section with period, quota, usage, remaining allowance, speed limits, and lifetime traffic.
- Kept the Client main menu compact while adding the subscription period to Monitoring summary; the full Client Connection, Subscription, and Managed Control dossier now lives under Status & Detailed Summary, while Diagnostics contains diagnostic state/tools only.
- Added Client Refresh and Navigate controls plus consistent Navigation sections on nested Client screens.
- Fresh Client enrollment confirmation now defaults to Yes (`[Y/n]`), so pressing Enter continues the installation after the administrator has selected the Client enrollment flow.
