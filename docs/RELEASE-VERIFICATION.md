# Release Verification

Run all checks against the extracted release directory, not only a development tree.

```bash
./tests/run-all.sh
```

The suite verifies:

- `bash -n` on `install.sh` and both role engines;
- syntax of quoted generated Bash helpers;
- compilation of quoted embedded Python helpers;
- the exact schema-1 table and column contract;
- registry initialization with an IPv4 endpoint;
- stable IPv4 and FQDN endpoint state (`READY`/`IDLE` + Client `SYNCED`);
- endpoint drift detection/reconciliation with no migration open;
- IPv4/FQDN endpoint transitions in all four directions;
- retained previous-endpoint state, `READY TO FINISH`, and explicit migration completion;
- a valid empty-fleet snapshot;
- DFR1 Server/Client token field compatibility;
- fresh installer dispatch for both roles;
- rejection of unmarked pre-lineage installations;
- role-preserving standalone DFR upgrade dispatch;
- the embedded bundled Client digest and version;
- exact standalone product-lineage metadata in the registry;
- strict failure on unexpected registry tables;
- subscription suspension/resume plus quota and speed persistence;
- portable backup create/verify/restore round-trip;
- Ed25519 Client-release signing and STAGED/CANARY/STABLE/REVOKED lifecycle;
- Client-side checksum/signature/shell/version/schema verification, including tamper rejection;
- source sanitization for removed product-line identifiers;
- release entrypoint identity (full Bash Egress/Ingress engines, never extracted helper payloads);
- manifest consistency.

Kernel-level integration (strongSwan negotiation, XFRM creation, nftables/tc enforcement, systemd lifecycle, live CONTROL across two hosts, restore on a real host) must also be exercised on Debian release candidates before production deployment. The archive test suite intentionally avoids mutating the machine running package verification.

## UI and fail-fast regression gates

The release suite verifies that the mature Main Menu, Operations Center, Connections, Server Operations, backup/history, Client menu, and diagnostic presentation remain intact except for retired-product entries. It also verifies explicit fail-fast chaining for Server initialization, Server connection file creation, and Client runtime setup so an inner failure cannot be reported as success.

A malformed zero-connection registry from an interrupted standalone v2.1.0 setup may be preserved and rebuilt. The same recovery path must refuse automatic deletion when connection rows exist.

## Default Client software and compact Client UI

Release verification asserts that fresh Server initialization seeds the exact bundled Client as STABLE, new connection rows default to AUTO and immediately target the stable release, and explicit REVOKED state is never silently reactivated. It also asserts that the Client main menu uses the compact Monitoring summary **including the subscription period**, that Status & Detailed Summary owns the full Client Connection/Subscription/Managed Control dossier, that Diagnostics does not duplicate that dossier, and that Refresh/Navigate/Back/Exit navigation is exposed consistently. The Server Connection Overview is separately guarded as a complete detailed dossier with full Subscription & Traffic period/quota/usage/speed/lifetime rows.

## GitHub release provenance

Official GitHub releases are built by `.github/workflows/release.yml` from a signed annotated tag. Before deployment, verify all three layers:

1. The GitHub tag is shown as **Verified**, or verify it locally with `git tag -v <tag>`.
2. `sha256sum -c SHA256SUMS` verifies the downloaded ZIP digest.
3. `gh attestation verify dragon-fruit-relay-2.1.0.zip --repo ozimellow/dragon-fruit-relay --signer-workflow ozimellow/dragon-fruit-relay/.github/workflows/release.yml` verifies GitHub Actions provenance for the artifact.

After extraction, `sha256sum -c MANIFEST.sha256` verifies every file inside the release tree.
