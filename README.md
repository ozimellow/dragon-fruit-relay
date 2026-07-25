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

Dragon Fruit Relay manages route-based IKEv2/IPsec links between Debian hosts. It configures strongSwan, Linux XFRM interfaces, policy routing, DNS, systemd services, forwarding, NAT, diagnostics, recovery, and rollback from one interactive command.

Each connection uses one dedicated custom UDP port. Dragon Fruit Relay does not use the standard IKE ports UDP 500 or UDP 4500.

The intended deployment complements [3x-ui](https://github.com/MHSanaei/3x-ui): 3x-ui manages Xray inbounds, clients, subscriptions, limits, statistics, and application routing, while Dragon Fruit Relay provides the encrypted host-level path to an independently managed egress hub.

## Install

Open a root shell on Debian and run:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ozimellow/dragon-fruit-relay/main/install.sh)
```

Open the management interface later with:

```bash
dragon-fruit-relay
```

> Pairing tokens contain pre-shared keys. Handle them as secrets.

## Deployment model

| 3x-ui / Xray | Dragon Fruit Relay |
|---|---|
| Inbounds and client configuration | IKEv2/IPsec tunnel lifecycle |
| Subscriptions, limits, and traffic accounting | Linux XFRM interfaces and policy routing |
| Xray outbounds and routing rules | Egress forwarding, source NAT, and health checks |
| Application-level service management | Host-level network path and diagnostics |

Dragon Fruit Relay does not install, modify, or replace 3x-ui. The projects remain separate, and Dragon Fruit Relay can also carry traffic from other applications that bind to its ingress XFRM address. This project is independent and is not affiliated with, sponsored by, or endorsed by the 3x-ui or Xray projects.

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

## Quick start

1. Install and configure 3x-ui on each ingress host that will provide Xray inbounds and client management.
2. Install Dragon Fruit Relay on the egress server and initialize an **egress hub**.
3. Create an egress connection and select one dedicated custom UDP port.
4. Allow or forward the selected UDP port to the egress server when required by the network environment.
5. Copy the generated pairing token.
6. Install Dragon Fruit Relay on the ingress server, select **ingress client**, and paste the token.
7. In 3x-ui, direct the selected Xray outbound through the ingress XFRM source address shown by Dragon Fruit Relay.

UDP 500 and UDP 4500 are not used or required.

## Capabilities

- Multi-connection egress hub
- Route-based IKEv2/IPsec with Linux XFRM
- One dedicated custom UDP port per connection
- Managed `dfrNNNN` XFRM interfaces
- Independent strongSwan runtime per egress connection
- Automatic IPv4 `/30` tunnel allocation
- Policy routing and managed DNS on ingress
- Per-connection forwarding and source NAT
- Health monitoring and recovery
- Live DNS and general traffic capture
- Repair, replacement, rollback, removal, and uninstall

## Requirements

- Debian with systemd
- Root access
- IPv4 connectivity
- A reachable egress endpoint
- One available custom UDP port for each connection
- Firewall or NAT rules allowing the selected UDP port when required
- 3x-ui only when using the recommended Xray management workflow

Required Debian packages are installed automatically. 3x-ui is installed and maintained separately.

UDP 500 and UDP 4500 do not need to be opened for Dragon Fruit Relay.

## Documentation

| Topic | Guide |
|---|---|
| Installation and updates | [docs/installation.md](docs/installation.md) |
| Using Dragon Fruit Relay with 3x-ui | [docs/3x-ui.md](docs/3x-ui.md) |
| Architecture and traffic flow | [docs/architecture.md](docs/architecture.md) |
| Daily operation and diagnostics | [docs/operations.md](docs/operations.md) |
| Troubleshooting | [docs/troubleshooting.md](docs/troubleshooting.md) |
| Removal and rollback | [docs/removal.md](docs/removal.md) |

## Dedication

The project name was chosen in solidarity with Kian Pirfalak and is dedicated to his memory.

## License

Dragon Fruit Relay is released under the [GNU General Public License v3.0 or later](LICENSE).
