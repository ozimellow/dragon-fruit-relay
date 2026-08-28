<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
    <img src="assets/logo.svg" alt="Dragon Fruit Relay" width="680">
  </picture>
</p>

<p align="center">
  <a href="CHANGELOG.md"><img src="https://img.shields.io/badge/release-v2.1.0-16A34A?style=flat-square" alt="Release v2.1.0"></a>
  <a href="https://github.com/ozimellow/dragon-fruit-relay/actions/workflows/validate.yml"><img src="https://img.shields.io/github/actions/workflow/status/ozimellow/dragon-fruit-relay/validate.yml?branch=main&style=flat-square&label=Debian%2012%20validation" alt="Debian 12 validation"></a>
  <a href="https://www.debian.org/"><img src="https://img.shields.io/badge/platform-Debian-A81D33?style=flat-square" alt="Debian"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0--or--later-C6265A?style=flat-square" alt="GPL-3.0-or-later"></a>
</p>

# Dragon Fruit Relay

Dragon Fruit Relay (DFR) is a managed **IKEv2/IPsec + Linux XFRM relay platform for Debian**. It creates and operates encrypted, route-based network paths between an **Egress Hub Server** and one or more **Ingress Clients**, while keeping the tunnel, policy, management and recovery lifecycle under one terminal interface.

DFR manages strongSwan, XFRM interfaces, routing, DNS, connection identity, subscriptions, traffic accounting, speed policy, endpoint synchronization, Client software, backups, diagnostics and recovery. It can be used by itself or as the network path underneath applications such as Xray/3x-ui.

## Quick Start

Run from a **root shell on Debian**:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ozimellow/dragon-fruit-relay/main/install.sh)
```

To install a specific version, append its tag (for example `v2.0.2`):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ozimellow/dragon-fruit-relay/main/install.sh) v2.0.2
```

Without a tag, the installer uses the latest stable release. With a tag, it installs that exact Dragon Fruit Relay release.

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

## What Dragon Fruit Relay provides

| Area | Capability |
|---|---|
| Encrypted transport | Route-based IKEv2/IPsec with Linux XFRM |
| Connection isolation | Dedicated identity, PSK, UDP transport, XFRM interface, `/30` tunnel allocation and runtime per managed connection |
| Enrollment | One-time DFR1 enrollment tokens |
| Management | Authenticated CONTROL/1 management through the encrypted tunnel |
| Routing | Managed policy routing, forwarding, source NAT and DNS integration |
| Subscriptions | Per-connection quota, expiration and suspension policy |
| Accounting | Current-period and lifetime traffic counters |
| Speed policy | Per-connection upload/download limits and Server-wide shaping policy |
| Endpoints | Public IPv4 or FQDN Server endpoints with managed synchronization |
| Client lifecycle | Presence, health, convergence and managed configuration state |
| Software delivery | Signed Client releases with staged rollout and per-connection update policy |
| Recovery | Verified backups, restore, repair, rollback and diagnostics |
| Operations | Fleet summaries, detailed connection views and terminal management workspaces |

## Topology

DFR manages the encrypted host-level path between the Ingress and Egress systems. Applications can use the managed Ingress XFRM path without DFR taking ownership of the application itself.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/topology-dark.svg">
    <img src="assets/topology.svg" alt="Dragon Fruit Relay topology showing application traffic entering an Ingress Client and crossing the managed IKEv2/IPsec XFRM path to an Egress Hub" width="920">
  </picture>
</p>


## Roles

### Egress Hub Server

The Egress Hub is the authoritative management point for the DFR fleet. It owns Server identity, the registry, connection allocation, enrollment, subscription policy, accounting, speed policy, Client presence, managed configuration, endpoint synchronization, Client software releases, backups and recovery.

Each managed connection is isolated with its own:

- connection identity
- pre-shared key
- custom UDP transport
- XFRM interface
- IPv4 `/30` tunnel allocation
- strongSwan runtime
- VICI socket and systemd unit
- policy and accounting state

An initialized Egress Hub may have zero connections; new Clients can be created and enrolled when needed.

### Ingress Client

The Ingress Client consumes a one-time DFR1 enrollment token and builds the assigned strongSwan/XFRM runtime. It applies DFR-owned routing and resolver state, maintains the encrypted path, receives authenticated managed state through CONTROL/1 and reports health and convergence back to the Egress Hub.

A Client keeps one installed DFR connection. Local removal restores DFR-owned host integration without implicitly deleting the authoritative Server-side connection record.

## Management plane

CONTROL/1 is authenticated per connection and operates through the encrypted XFRM path. It carries managed configuration, endpoint changes, health and presence state, management actions and Client software instructions.

DFR keeps management state separate from the public application layer: there is no requirement to expose CONTROL/1 directly to the Internet.

## Endpoint management

The Egress endpoint may be either:

```text
Public IPv4
FQDN
```

DFR can synchronize endpoint changes across enrolled Clients while retaining the previous endpoint until the transition is explicitly completed.

Supported endpoint transitions include:

```text
IPv4 -> IPv4
IPv4 -> FQDN
FQDN -> IPv4
FQDN -> FQDN
```

Endpoint drift can also be detected and reconciled outside an active migration.

## Subscription, accounting and speed policy

Each managed connection can have its own:

- traffic quota
- expiration
- suspension/resume state
- upload speed limit
- download speed limit
- current-period usage
- lifetime traffic counters

The Egress Hub also maintains Server-wide traffic shaping policy.

These controls are native to DFR. External applications such as Xray/3x-ui may still maintain their own application-level users, limits and routing independently.

## Managed Client software

The Egress Hub can distribute and control signed Ingress Client releases.

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

Managed deployments verify release identity and integrity before installation and retain rollback/recovery paths for failed updates.

## Backup and recovery

DFR provides verified Server backup and restore workflows for the authoritative registry and required managed state, including signing and release metadata where required.

Client setup records the original host state for DFR-owned integration points so repair, removal and recovery can restore those changes safely.

## Quick start

1. Install DFR on the egress host and select **Egress Hub (Server)**.
2. Create a managed connection.
3. Copy the generated **DFR1 enrollment token**.
4. Install DFR on the ingress host and select **Ingress Client (Client)**.
5. Paste the token and complete enrollment.
6. Route the desired application or network traffic through the managed Ingress XFRM path.
7. Use the Egress Hub to monitor and manage the connection.

## Application integration

Dragon Fruit Relay is independent of 3x-ui and Xray.

When used with Xray/3x-ui, DFR provides the encrypted host-level network path while Xray/3x-ui remains responsible for its own inbounds, users and application routing. Other applications can use the DFR-managed path in the same way.

DFR does not install, modify or replace 3x-ui.

## Release integrity

Stable releases are published from signed tags that point to the exact validated tip of `main`.

The release pipeline:

- validates DFR inside Debian 12
- builds the release archive
- tests the staged package
- extracts the exact ZIP and tests it again
- publishes `SHA256SUMS`
- creates GitHub artifact attestations
- requires signed release tags

See [Release Verification](docs/RELEASE-VERIFICATION.md) for verification procedures.

## Requirements

- Debian with systemd
- root access
- IPv4 connectivity
- a reachable Egress Hub endpoint
- one available custom UDP port per managed connection

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
| Changelog | [CHANGELOG.md](CHANGELOG.md) |

## Dedication

The project name was chosen in solidarity with **Kian Pirfalak** and is dedicated to his memory.

## Security

Dragon Fruit Relay manages privileged networking, PSKs, enrollment secrets, signing material and backup data. Never publish enrollment tokens, credentials, registry databases, private keys or unredacted diagnostic captures.

See [SECURITY.md](SECURITY.md) for reporting and operational guidance.

## License

Dragon Fruit Relay is released under the [GNU General Public License v3.0 or later](LICENSE).
