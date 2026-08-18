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

Dragon Fruit Relay is a managed **IKEv2/IPsec + Linux XFRM relay for Debian** with two roles: an **Egress Hub** that manages isolated Client connections and an **Ingress Client** that enrolls with a one-time DFR1 token.

DFR manages strongSwan, XFRM interfaces, policy routing, DNS, subscriptions, traffic accounting, speed policy, managed configuration, endpoint synchronization, Client software releases, backups, diagnostics and recovery from one terminal interface.

> [!WARNING]
> **v2.1.0-rc.1 is a prerelease.** It is intended for validation and staged deployment before the final v2.1.0 release.

## Install

Run from a **root shell on Debian**.

### Latest v2.1.0 prerelease

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ozimellow/dragon-fruit-relay/refs/heads/release/v2.1.0-rc.1/install.sh)
```

### Specific release

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ozimellow/dragon-fruit-relay/refs/tags/v2.1.0-rc.1/install.sh)
```

The bootstrap downloads the matching GitHub Release, verifies its published SHA-256 checksum, extracts it to a temporary directory and starts the real installer. No manual ZIP download or extraction is required.

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

## Highlights

- One installer for Egress Hub and Ingress Client roles.
- Public IPv4 or FQDN Server endpoints with authenticated endpoint synchronization and migration.
- Isolated PSK, custom UDP transport, XFRM interface and `/30` tunnel allocation per connection.
- Per-connection subscriptions, quotas, expiration, suspension, traffic accounting and upload/download speed limits.
- Authenticated CONTROL/1 management over the encrypted tunnel.
- Client presence, health, managed configuration, endpoint and software convergence states.
- Server-managed Client releases with **STAGED / CANARY / STABLE / REVOKED** states and **AUTO / MANUAL / PINNED** policies.
- Fresh v2.1.0 Servers publish their exact bundled Client as **STABLE** and new connections default to **AUTO/LATEST**.
- Automatic, manual and rescue backups with verification and restore.
- Fleet summaries, detailed connection dossiers, diagnostics, logs, repair and recovery workflows.

## Deployment

### Egress Hub

The Egress Hub owns connection identity, tunnel allocation, subscriptions, accounting, policy, Client presence, managed configuration, endpoint synchronization, Client software releases, backups and recovery.

### Ingress Client

The Ingress Client consumes a one-time DFR1 enrollment token and builds the managed strongSwan/XFRM runtime. It applies routing and DNS policy, receives managed configuration and software policy through CONTROL/1, and reports health and convergence back to the Egress Hub.

Dragon Fruit Relay is independent of 3x-ui. Applications may use the managed Client XFRM address as their egress path without DFR managing the application itself.

## Endpoint support

The Server endpoint may be a public IPv4 address or an FQDN. Supported transitions include:

```text
IPv4 -> IPv4
IPv4 -> FQDN
FQDN -> IPv4
FQDN -> FQDN
```

Previous endpoint state is retained until a completed migration is explicitly finished by the operator.

## Releases and trust

`main` remains the current stable line while this release candidate is developed and published from `release/v2.1.0-rc.1`.

Release tags are signed by the maintainer. GitHub Actions validates and builds DFR inside **Debian 12**, retests the exact extracted ZIP, publishes `SHA256SUMS`, and creates GitHub artifact attestations.

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
| Architecture | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| Database contract | [docs/DATABASE.md](docs/DATABASE.md) |
| Operations | [docs/OPERATIONS.md](docs/OPERATIONS.md) |
| Backup and recovery | [docs/BACKUP-RECOVERY.md](docs/BACKUP-RECOVERY.md) |
| Troubleshooting | [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) |
| Release verification | [docs/RELEASE-VERIFICATION.md](docs/RELEASE-VERIFICATION.md) |
| Maintainer release process | [docs/RELEASE-PROCESS.md](docs/RELEASE-PROCESS.md) |

## Dedication

The project name was chosen in solidarity with **Kian Pirfalak** and is dedicated to his memory.

## Security

Dragon Fruit Relay manages privileged networking, PSKs, enrollment secrets, signing material and backup data. Never publish enrollment tokens, credentials, registry databases, private keys or unredacted diagnostic captures.

See [SECURITY.md](SECURITY.md) for reporting and operational guidance.

## License

Dragon Fruit Relay is released under the [GNU General Public License v3.0 or later](LICENSE).
