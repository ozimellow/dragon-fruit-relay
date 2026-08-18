<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
    <img src="assets/logo.svg" alt="Dragon Fruit Relay" width="680">
  </picture>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/prerelease-v2.1.0--rc.1-F59E0B?style=flat-square" alt="v2.1.0-rc.1 prerelease">
  <a href="../../actions/workflows/validate.yml"><img src="https://img.shields.io/github/actions/workflow/status/ozimellow/dragon-fruit-relay/validate.yml?branch=release%2Fv2.1.0-rc.1&style=flat-square&label=Debian%2012%20validation" alt="Debian 12 validation"></a>
  <a href="https://www.debian.org/"><img src="https://img.shields.io/badge/platform-Debian-A81D33?style=flat-square" alt="Debian"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0--or--later-C6265A?style=flat-square" alt="GPL-3.0-or-later"></a>
</p>

# Dragon Fruit Relay

Dragon Fruit Relay is a managed **IKEv2/IPsec + Linux XFRM relay for Debian** with two roles: an **Egress Hub Server** and an **Ingress Client**.

It manages strongSwan, XFRM interfaces, routing, DNS, subscriptions, traffic accounting, speed policy, endpoint synchronization, managed Client software, backups, diagnostics and recovery from one terminal interface.

> [!WARNING]
> **v2.1.0-rc.1 is a prerelease.** Use it for validation and staged deployment before the final v2.1.0 release.

## Install

Run from a **root shell on Debian**.

### Latest v2.1.0 prerelease branch

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ozimellow/dragon-fruit-relay/refs/heads/release/v2.1.0-rc.1/install.sh)
```

### Pinned v2.1.0-rc.1 release

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ozimellow/dragon-fruit-relay/refs/tags/v2.1.0-rc.1/install.sh)
```

The bootstrap downloads the matching GitHub Release, verifies its published SHA-256 checksum, extracts it to a temporary directory and launches the packaged installer.

On a fresh host:

```text
DRAGON FRUIT RELAY v2.1.0  |  INSTALLER

  [1]  Egress Hub (Server)
  [2]  Ingress Client (Client)
```

Open DFR later with:

```bash
dragon-fruit-relay
```

## What changed from v2.0.2 to v2.1.0

v2.1.0 is a major expansion of Dragon Fruit Relay. v2.0.2 primarily managed the encrypted host-level IKEv2/IPsec and XFRM path. v2.1.0 keeps that foundation and adds a standalone management plane around it.

### Standalone Dragon Fruit Relay lineage

v2.1.0 establishes Dragon Fruit Relay as its own **standalone DFR product line** with explicit product, schema and upgrade identity.

- Clean `registry_schema=1` Server database contract.
- Explicit standalone lineage markers in managed configuration and registry metadata.
- One installer for both Egress Hub Server and Ingress Client roles.
- Existing standalone DFR installations preserve their installed role during upgrades.
- Unmarked pre-lineage installations are rejected instead of being guessed, imported or silently converted.

### Native Server registry and fleet management

The Egress Hub now owns the authoritative state for every managed connection.

- SQLite-backed Server registry.
- Zero-connection Egress Hub is a valid initialized state.
- Per-connection identity, PSK, UDP transport, XFRM interface and `/30` tunnel allocation.
- Fleet summaries, Client presence, health and convergence state.
- Detailed Connection Overview with subscription, traffic and management state.
- Isolated Server-side removal for a single connection without disturbing unrelated Clients.

### DFR1 enrollment and CONTROL/1

v2.1.0 introduces a formal enrollment and management protocol instead of relying only on the original pairing flow.

- One-time **DFR1 enrollment tokens**.
- Tokens carry the Server endpoint, custom UDP transport, connection identity, tunnel allocation, subscription listener and CONTROL listener.
- Authenticated **CONTROL/1** management runs inside the encrypted XFRM path.
- Managed configuration transactions are verified and can roll back safely on failure.
- Configuration coordination runs independently so a CONTROL responder restart cannot strand an in-flight change.

### Subscriptions, quota, accounting and speed policy

These capabilities are now native to Dragon Fruit Relay instead of needing to live in an external application layer.

Per connection, the Server can manage:

- quota
- expiration
- suspension/resume state
- upload speed limit
- download speed limit
- current-period traffic usage
- lifetime traffic counters

The Server also supports global upload/download shaping policy.

3x-ui and Xray can still use a DFR-managed XFRM path, but Dragon Fruit Relay no longer depends on them for its own subscription, accounting or connection-management model.

### IPv4 and FQDN endpoint management

The authoritative Egress endpoint can now be either a **public IPv4 address** or an **FQDN**.

Supported transitions:

```text
IPv4 -> IPv4
IPv4 -> FQDN
FQDN -> IPv4
FQDN -> FQDN
```

Endpoint changes are synchronized through CONTROL/1. DFR retains the previous endpoint while Clients converge, reports the transition as **ACTIVE**, moves to **READY TO FINISH** after enrolled Clients confirm the new value, and removes the previous endpoint only when the operator explicitly finishes the migration.

Endpoint drift can also be detected and reconciled even when no migration is open.

### Managed Client software releases

The Egress Hub can now distribute and control signed Ingress Client releases.

Release lifecycle:

```text
STAGED -> CANARY -> STABLE
                    REVOKED
```

Per-connection software policy:

```text
AUTO
MANUAL
PINNED
```

Fresh v2.1.0 Servers verify their exact bundled Ingress Client, publish it as **STABLE**, and new connections default to **AUTO/LATEST**.

Client release verification covers checksum, Ed25519 signature, shell syntax, version and schema gates before deployment. Failed managed updates have rollback and recovery paths.

### Backups, restore and recovery

v2.1.0 adds portable, verified Server backups rather than relying only on local host rollback behavior.

- Manual, automatic and rescue backup workflows.
- Backup includes the authoritative registry, required signing material, release metadata and managed state.
- Verification checks the backup format, registry schema, file manifest, SHA-256 digests, signing keypair and SQLite integrity before restore.
- Client setup records original host state before DFR-managed changes so removal and recovery can restore DFR-owned integration points safely.

### Reliability and release hardening

v2.1.0 also adds substantial failure handling and release validation.

- Fail-fast Server initialization and Client connection transactions.
- Rollback when an inner configuration step fails.
- Safe recovery for an interrupted empty standalone registry.
- Strict refusal of destructive recovery when existing connection rows are present.
- Exact table/column schema contract tests.
- Exact bundled Client byte-for-byte and SHA-256 verification.
- Static shell, generated Bash and embedded Python checks.
- Exact extracted release ZIP is tested again before publication.
- Signed release-tag enforcement.
- Published `SHA256SUMS` and GitHub artifact attestations.
- Release-equivalent validation runs inside Debian 12.

### UI and operational improvements

The terminal interface keeps the mature DFR workflow while exposing the new management state more clearly.

- Server Connection Overview now includes the authoritative Subscription & Traffic dossier.
- Client main menu is a compact Monitoring summary.
- Full Client connection, subscription and managed CONTROL/software details live under Status & Detailed Summary.
- Diagnostics is kept focused on diagnostic state and tools.
- Refresh and Navigate controls were added to the Client interface.
- Nested screens use consistent Navigation, Back and Exit behavior.
- Fresh Client enrollment confirmation defaults to **Yes** after the administrator selects the Client enrollment flow.

For implementation-level details, see [CHANGELOG.md](CHANGELOG.md).

## Core capabilities

- Route-based IKEv2/IPsec with Linux XFRM.
- Egress Hub Server and Ingress Client roles.
- Independent managed connection runtime per Client.
- Public IPv4 or FQDN Server endpoints.
- Custom UDP transport per connection.
- Automatic IPv4 `/30` tunnel allocation.
- Managed policy routing and DNS on the Client.
- Per-connection forwarding and source NAT on the Server.
- DFR1 enrollment and authenticated CONTROL/1.
- Native subscriptions, quota, expiry and suspension.
- Current-period and lifetime traffic accounting.
- Per-connection and Server-wide speed policy.
- Client presence, health and convergence monitoring.
- Signed managed Client software with staged rollout policies.
- Verified backup, restore, repair and recovery workflows.

## Deployment model

### Egress Hub Server

The Egress Hub owns Server identity, the registry, connection allocation, enrollment, subscriptions, accounting, speed policy, Client presence, managed configuration, endpoint synchronization, Client software releases, backups and recovery.

Each connection receives its own PSK, UDP listener, XFRM identity, `/30` allocation, strongSwan runtime, VICI socket, systemd unit and policy state.

### Ingress Client

The Ingress Client consumes a one-time DFR1 enrollment token, creates the assigned strongSwan/XFRM runtime, applies routing and resolver policy, receives managed state through CONTROL/1 and reports health and convergence back to the Egress Hub.

Dragon Fruit Relay is independent of 3x-ui. Applications such as Xray may use the managed Client XFRM address as their egress path without DFR installing or managing the application itself.

## Releases and trust

`main` remains the current stable line while v2.1.0 release candidates are developed and published from the release branch.

Release tags are signed by the maintainer. GitHub Actions validates and builds DFR inside **Debian 12**, retests the exact extracted ZIP, publishes `SHA256SUMS`, and creates artifact attestations.

See [Release Verification](docs/RELEASE-VERIFICATION.md) for checksum, signed-tag and provenance verification. Maintainer release steps are in [Release Process](docs/RELEASE-PROCESS.md).

## Requirements

- Debian with systemd
- Root access
- IPv4 connectivity
- Reachable Server endpoint
- One available custom UDP port per managed connection

Required runtime packages are installed automatically when needed.

## Documentation

| Topic | Guide |
|---|---|
| Architecture | [docs/architecture.md](docs/architecture.md) |
| Database contract | [docs/DATABASE.md](docs/DATABASE.md) |
| Operations | [docs/operations.md](docs/operations.md) |
| Backup and recovery | [docs/BACKUP-RECOVERY.md](docs/BACKUP-RECOVERY.md) |
| Troubleshooting | [docs/troubleshooting.md](docs/troubleshooting.md) |
| Release verification | [docs/RELEASE-VERIFICATION.md](docs/RELEASE-VERIFICATION.md) |
| Maintainer release process | [docs/RELEASE-PROCESS.md](docs/RELEASE-PROCESS.md) |
| Full changelog | [CHANGELOG.md](CHANGELOG.md) |

## Dedication

The project name was chosen in solidarity with **Kian Pirfalak** and is dedicated to his memory.

## Security

Dragon Fruit Relay manages privileged networking, PSKs, enrollment secrets, signing material and backup data. Never publish enrollment tokens, credentials, registry databases, private keys or unredacted diagnostic captures.

See [SECURITY.md](SECURITY.md) for reporting and operational guidance.

## License

Dragon Fruit Relay is released under the [GNU General Public License v3.0 or later](LICENSE).
