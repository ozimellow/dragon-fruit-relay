# Changelog

## 2.0.1

- Changed the project license from MIT to GNU GPL version 3 or later.
- Updated SPDX license identifiers in the installer and application scripts.
- Updated repository license documentation and badges.
- No networking or runtime behavior was changed.

## 2.0.0

First public release.

- Designed as a complementary network layer for 3x-ui-managed Xray deployments
- Multi-connection egress hub with isolated strongSwan processes
- Pairing-token ingress provisioning
- Route-based XFRM interfaces and policy routing
- Managed DNS with dhcpcd and systemd-resolved handling
- Per-connection forwarding and source NAT
- Health monitoring, recovery, repair, and rollback
- Live DNS and general traffic capture
- Safe `Ctrl+C` handling for live diagnostics
