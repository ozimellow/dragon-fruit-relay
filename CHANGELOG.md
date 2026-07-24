# Changelog

## 2.0.2

- Added custom-port-only transport using one dedicated UDP port per connection.
- Removed support for standard UDP 500 and UDP 4500 transport.
- Added pairing-token version 6.
- Added backward compatibility for compatible custom-port version 5 tokens.
- Removed legacy `xfrm` connection support and added guided legacy cleanup.
- Standardized new connections on managed `dfrNNNN` XFRM interfaces.
- Fixed stale XFRM interfaces remaining after failed profile creation.
- Fixed incomplete VICI socket and runtime cleanup.
- Replaced problematic swanctl credential symlinks with canonical managed files and directories.
- Added residual cleanup and complete uninstall options before configuration.
- Improved automatic repair of existing Dragon Fruit Relay 2.0.1 installations.
- Changed tunnel allocation to begin at `10.10.0.0/30`.

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
