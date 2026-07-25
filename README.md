<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
    <img src="assets/logo.svg" alt="Dragon Fruit Relay" width="680">
  </picture>
</p>

<p align="center">
  <a href="CHANGELOG.md"><img src="https://img.shields.io/badge/release-2.0.2-111827?style=flat-square" alt="Release 2.0.2"></a>
  <a href="https://www.debian.org/"><img src="https://img.shields.io/badge/platform-Debian-A81D33?style=flat-square" alt="Debian"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0--or--later-C6265A?style=flat-square" alt="GPL-3.0-or-later"></a>
</p>

Dragon Fruit Relay manages route-based IKEv2/IPsec links between Debian hosts through a single interactive management interface.

It configures strongSwan, Linux XFRM interfaces, policy routing, DNS, systemd services, forwarding, source NAT, diagnostics, recovery, rollback, and removal.

As of release **v2.0.2**, every connection uses its own dedicated custom UDP port. The standard IKEv2/IPsec ports, UDP 500 and UDP 4500, are no longer supported or required.

The project is designed to complement [3x-ui](https://github.com/MHSanaei/3x-ui). While 3x-ui manages Xray inbounds, users, subscriptions, limits, statistics, and application routing, Dragon Fruit Relay provides the encrypted host-level path between the ingress server and an independently managed egress hub.

## Dedication

The project name was chosen in solidarity with **Kian Pirfalak** and is dedicated to his memory.

## Install

Open a root shell on Debian and run:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ozimellow/dragon-fruit-relay/main/install.sh)
```

Open the management interface later with:

```bash
dragon-fruit-relay
```

> Pairing tokens contain pre-shared keys and must be handled as secrets.

## Deployment model

| 3x-ui / Xray | Dragon Fruit Relay |
|---|---|
| Inbound and client configuration | IKEv2/IPsec tunnel lifecycle |
| Subscriptions, limits, and traffic accounting | Linux XFRM interfaces and policy routing |
| Xray outbounds and application routing | Egress forwarding, source NAT, and health checks |
| Application-level service management | Host-level encrypted transport and diagnostics |

Dragon Fruit Relay does not install, modify, or replace 3x-ui.

The two projects remain separate. Dragon Fruit Relay may also carry traffic from other applications that bind to the managed ingress XFRM address.

This project is independent and is not affiliated with, sponsored by, or endorsed by the 3x-ui or Xray projects.

## Topology

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/topology-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="assets/topology.svg">
    <img
      src="assets/topology.svg"
      alt="3x-ui and Xray ingress hosts connected to a Dragon Fruit Relay egress hub using IKEv2 and IPsec"
      width="920">
  </picture>
</p>

A typical deployment consists of:

- One or more ingress servers running 3x-ui or another application
- One Dragon Fruit Relay egress hub
- One isolated IKEv2/IPsec connection per ingress server
- One dedicated custom UDP port per connection
- One managed XFRM interface and IPv4 `/30` network per connection

## Quick start

1. Install and configure 3x-ui on the ingress server.
2. Install Dragon Fruit Relay on the egress server.
3. Initialize the server as an **egress hub**.
4. Create a new egress connection.
5. Assign one dedicated custom UDP port to the connection.
6. Allow or forward that UDP port to the egress server when required.
7. Copy the generated pairing token.
8. Install Dragon Fruit Relay on the ingress server.
9. Select **Ingress client** and paste the pairing token.
10. In 3x-ui, configure the selected Xray outbound to use the ingress XFRM source address shown by Dragon Fruit Relay.

Dragon Fruit Relay v2.0.2 does not use UDP 500 or UDP 4500.

## Connection model

Each connection is isolated and receives its own:

- Custom UDP transport port
- strongSwan runtime configuration
- XFRM interface
- XFRM ID
- IPv4 `/30` tunnel network
- Forwarding and source NAT rules
- Health and recovery state

Managed XFRM interfaces use deterministic names:

```text
dfr0001 — XFRM ID 1001
dfr0002 — XFRM ID 1002
dfr0003 — XFRM ID 1003
```

Tunnel networks are allocated sequentially:

```text
10.10.0.0/30
10.10.0.4/30
10.10.0.8/30
```

The first connection uses:

```text
Ingress: 10.10.0.1
Egress:  10.10.0.2
```

Legacy `xfrm*` interface configurations are not supported by v2.0.2 and must be recreated.

## Transport model

Dragon Fruit Relay v2.0.2 uses a custom-port-only transport model.

Each connection must use one dedicated UDP port. That port carries the IKEv2 negotiation and encrypted IPsec traffic for the connection.

The selected port must be:

- Available on the egress server
- Allowed by the server firewall
- Forwarded by an upstream router or NAT device when required
- Unique to that Dragon Fruit Relay connection


## Capabilities

- Multi-connection egress hub
- Route-based IKEv2/IPsec with Linux XFRM
- One dedicated custom UDP port per connection
- Managed `dfrNNNN` XFRM interfaces
- Independent strongSwan runtime per egress connection
- Automatic IPv4 `/30` tunnel allocation
- Policy routing on ingress
- Managed DNS configuration
- Per-connection forwarding and source NAT
- Health monitoring and recovery
- Live DNS traffic capture
- Live tunnel traffic capture
- Pairing-token validation
- Compatible token conversion
- Failed-connection rollback
- Orphaned interface and runtime cleanup
- Connection repair and replacement
- Selective removal and complete uninstall

## Requirements

- Debian with systemd
- Root access
- IPv4 connectivity
- A reachable egress endpoint
- One available custom UDP port for each connection
- Firewall or NAT rules allowing the selected UDP port
- 3x-ui only when using the recommended Xray management workflow

Required Debian packages are installed automatically.

3x-ui must be installed and maintained separately.


## Pairing tokens

Pairing tokens contain the information required to configure an ingress client, including pre-shared key material.

Treat pairing tokens as credentials:

- Transfer them only through trusted channels.
- Do not publish them in issues, logs, screenshots, or documentation.
- Do not reuse one token across multiple connections.
- Remove unused connections from both ingress and egress systems.

Dragon Fruit Relay v2.0.2 generates pairing-token version 6.

Compatible custom-port version 5 tokens may be converted during import. Older token formats and unsupported legacy transport configurations are rejected.

## Updating

Run the installer again:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ozimellow/dragon-fruit-relay/main/install.sh)
```

The installer updates the management script while preserving supported configurations.

Compatible v2.0.1 custom-port hub profiles may be repaired automatically.

Profiles using UDP 500, UDP 4500, or legacy `xfrm*` interface naming are not compatible with v2.0.2 and must be recreated.

## Documentation

| Topic | Guide |
|---|---|
| Installation and updates | [docs/installation.md](docs/installation.md) |
| Using Dragon Fruit Relay with 3x-ui | [docs/3x-ui.md](docs/3x-ui.md) |
| Architecture and traffic flow | [docs/architecture.md](docs/architecture.md) |
| Daily operation and diagnostics | [docs/operations.md](docs/operations.md) |
| Troubleshooting | [docs/troubleshooting.md](docs/troubleshooting.md) |
| Removal and rollback | [docs/removal.md](docs/removal.md) |

## Security

Dragon Fruit Relay manages privileged network configuration and pre-shared key material.

Before deploying it:

- Review the installation script.
- Restrict access to the egress server.
- Use a separate custom UDP port for every connection.
- Limit exposure of management interfaces.
- Protect pairing tokens and configuration backups.
- Remove connections that are no longer in use.

Security issues should be reported according to [SECURITY.md](SECURITY.md).


## License

Dragon Fruit Relay is released under the [GNU General Public License v3.0 or later](LICENSE).
