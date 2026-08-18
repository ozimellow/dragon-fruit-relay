<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
    <img src="assets/logo.svg" alt="Dragon Fruit Relay" width="680">
  </picture>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/prerelease-v2.1.0--rc.1-F59E0B?style=flat-square" alt="v2.1.0-rc.1 prerelease">
  <a href="../../actions/workflows/validate.yml"><img src="https://img.shields.io/github/actions/workflow/status/ozimellow/dragon-fruit-relay/validate.yml?branch=main&style=flat-square&label=validation" alt="Validation"></a>
  <a href="https://www.debian.org/"><img src="https://img.shields.io/badge/platform-Debian-A81D33?style=flat-square" alt="Debian"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0--or--later-C6265A?style=flat-square" alt="GPL-3.0-or-later"></a>
</p>

# Dragon Fruit Relay

Dragon Fruit Relay is a managed **IKEv2/IPsec + Linux XFRM relay for Debian**. It provides two roles through one installer: an **Egress Hub** that manages isolated connections and an **Ingress Client** that enrolls with a one-time DFR1 token.

DFR manages the tunnel lifecycle around strongSwan, XFRM interfaces, policy routing, DNS, subscriptions, traffic accounting, speed policy, managed configuration, Client software releases, endpoint synchronization, backups, diagnostics and recovery.

> [!WARNING]
> **v2.1.0-rc.1 is a prerelease.** Use it for validation and staged deployment before the final v2.1.0 release.

## Install

Run the installer from a **root shell on Debian**.

### Latest recommended release

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ozimellow/dragon-fruit-relay/main/install.sh)
```

### Specific release

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ozimellow/dragon-fruit-relay/main/install.sh) --version v2.1.0-rc.1
```

The bootstrap downloads the matching GitHub Release, verifies its published SHA-256 checksum, extracts it to a temporary directory and launches the real installer. On a fresh host DFR asks which role to configure:

```text
DRAGON FRUIT RELAY v2.1.0  |  INSTALLER

  [1]  Egress Hub (Server)
  [2]  Ingress Client (Client)
```

Open the management interface later with:

```bash
dragon-fruit-relay
```

## What DFR provides

- One interactive installer for Egress Hub and Ingress Client roles.
- Public IPv4 or FQDN Server endpoints, including managed endpoint migration.
- One isolated PSK, custom UDP transport, XFRM interface and `/30` tunnel allocation per connection.
- Per-connection subscriptions, quotas, expiration, suspension, upload/download accounting and speed limits.
- Authenticated CONTROL/1 management over the encrypted tunnel.
- Client presence, health, configuration convergence, endpoint state and software status.
- Server-managed Client releases with **STAGED / CANARY / STABLE / REVOKED** states and **AUTO / MANUAL / PINNED** policies.
- Automatic, manual and rescue backups with verification and restore workflows.
- Fleet summaries, detailed connection dossiers, diagnostics, logs, repair and recovery tools.

## Deployment model

### Egress Hub

The Egress Hub owns connection identity, tunnel allocation, subscriptions, accounting, policy, Client presence, managed configuration, endpoint synchronization, Client software releases, backups and recovery.

A fresh v2.1.0 Egress Hub publishes its exact bundled Client as **STABLE**. New connections default to **AUTO/LATEST** while MANUAL and PINNED remain explicit operator choices.

### Ingress Client

The Ingress Client consumes a one-time DFR1 enrollment token and builds the managed strongSwan/XFRM runtime. It applies routing and DNS policy, receives managed configuration and software policy through CONTROL/1, and reports health and convergence back to the Egress Hub.

Applications can use the managed Client XFRM address as their egress path. Dragon Fruit Relay is independent of 3x-ui and can be used with 3x-ui or other applications without managing them.

## Endpoint support

The Server endpoint can be either a public IPv4 address or an FQDN. DFR supports all normal transitions:

```text
IPv4 -> IPv4
IPv4 -> FQDN
FQDN -> IPv4
FQDN -> FQDN
```

Clients synchronize authenticated endpoint changes through the management plane. Previous endpoint state is retained until the operator explicitly finishes a completed migration.

## Releases and trust

Release tags are signed by the maintainer. GitHub Actions builds and tests the release package in **Debian 12**, verifies the extracted archive, publishes `SHA256SUMS`, and creates GitHub artifact attestations for release provenance.

For checksum, signed-tag and provenance verification, see [Release Verification](docs/RELEASE-VERIFICATION.md). Maintainer steps are documented separately in [Release Process](docs/RELEASE-PROCESS.md).

## Requirements

- Debian with systemd
- Root access
- IPv4 connectivity
- A reachable Server endpoint
- One available custom UDP port per managed connection

Required runtime packages are installed by DFR when needed.

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
