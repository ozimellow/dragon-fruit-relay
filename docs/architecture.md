# Architecture

Dragon Fruit Relay v2.1.0 has two deliberately separate role engines.

## Egress Hub

The Egress Hub owns Server identity, the registry, connection allocation, enrollment, subscriptions, quota/speed policy, accounting, presence, software releases, backups, diagnostics, and endpoint policy. Every Client connection has its own profile, PSK, UDP listener, XFRM identity, /30 allocation, strongSwan runtime, VICI socket, systemd unit, and policy state.

The authoritative Server database is `/var/lib/dragon-fruit-relay/database/registry.sqlite3`. Generated profile files under `/etc/dragon-fruit-relay/clients/` are materialized runtime configuration, not a substitute for the registry.

## Ingress Client

The Ingress Client consumes a DFR1 enrollment token, detects its physical network, creates the assigned XFRM interface, installs strongSwan configuration, establishes the custom-UDP IKEv2 tunnel, installs policy routing and resolver state, and runs CONTROL/1 plus health/recovery logic.

The Client keeps one installed connection. Replacing it is explicit and local removal does not implicitly delete the Server's authoritative record.

## Management plane

CONTROL/1 is authenticated per connection and transported inside the encrypted XFRM path. It carries subscriptions, quota/speed policy, presence, endpoint changes, configuration transactions, health/management actions, and Client software instructions. Subscription status has its own tunnel-scoped listener so display/accounting state remains distinct from CONTROL operations.

## Endpoint model

The Server endpoint is a single generic value that may be either a public IPv4 address or an FQDN. Clients cache the current resolved public IPv4 for runtime use while retaining the authoritative endpoint value. Endpoint changes are propagated through authenticated CONTROL/1.

Endpoint capability is always available; migration is a temporary transaction, not an enable/disable mode. With no change open the endpoint workspace is `IDLE` and Clients that report the authoritative endpoint are `SYNCED`. Changing the endpoint retains the previous endpoint and opens an `ACTIVE` transition. After every enrolled Client reports the new value the transition becomes `READY TO FINISH`; previous endpoint tracking is removed only by explicit completion. A Client that later reports a different endpoint is treated as endpoint drift and can be reconciled without inventing a migration.

## Software distribution

The Server maintains signed Client releases and rollout metadata. Release states include STAGED, CANARY, STABLE, and REVOKED; Client policies include AUTO, MANUAL, and PINNED. The v2.1.0 Server also embeds the exact v2.1.0 Ingress engine as a checksum-bound bundled release.

## Backup/recovery

Server backups capture the current registry, keys, release metadata, and required managed configuration. The Client records original host state before managed changes so removal/recovery can restore DFR-owned integration points safely.
