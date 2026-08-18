# Operations

## Egress Hub workflow

Run `sudo ./install.sh`, select **1**, confirm the detected public IPv4, and optionally choose an FQDN. During initialization the Server verifies the bundled v2.1.0 Client, publishes it as STABLE, and makes AUTO/LATEST the default for newly created connections. After initialization, create a connection from the Connections workspace and copy its DFR1 enrollment token to the intended Client.

Operations Center and Server Operations remain usable with zero connections. An empty Server is a normal initialized state, not a health failure.

## Connection lifecycle

Each connection can be inspected, started, stopped, restarted, repaired, enrolled, assigned quota/expiry/speed policy, monitored for accounting/presence, assigned Client software policy, and permanently removed. Removing one Server connection targets only that connection's service, VICI/runtime, XFRM interface, firewall/NAT state, files, secrets, enrollment/subscription/accounting/CONTROL rows, and software policy.

## Quota and speed

Per-connection subscription policy includes quota, expiry, manual suspension, upload limit, and download limit. Usage tracks current-period and lifetime counters. The Server also maintains global upload/download shaping policy.

## Client software

The current bundled Client is automatically seeded as STABLE by Server initialization. Use Client Software to import additional releases, verify digest/signature, assign STAGED/CANARY/STABLE/REVOKED state, choose AUTO/MANUAL/PINNED rollout policy, inspect update status, and recover/roll back failed deployments. New connections use AUTO unless an administrator explicitly changes the policy.

## Endpoint changes

Server Settings supports IPv4 and FQDN endpoints. Existing Clients receive endpoint changes through CONTROL/1 and reconcile runtime only after validation. A public IPv4 does not require DNS. Stable operation is shown as endpoint management `READY`, migration `IDLE`, and Clients `SYNCED`. During a change, migration is `ACTIVE`; after all Clients confirm the target it becomes `READY TO FINISH` until the operator clears retained previous-endpoint tracking. Synchronize also repairs endpoint drift when no migration is open.

## Ingress Client workflow

Select **2** in `install.sh` and paste the DFR1 token. After enrollment the Client main screen presents a compact Monitoring summary for connection health, endpoint/transport, subscription, traffic, speed and managed CONTROL/software state. Use Status and the dedicated workspaces for the full detail. The main screen provides Refresh and Navigate controls, while nested screens use Navigate/Back/Exit consistently. Root-only removal removes the local connection and restores DFR-owned host changes; remove the Server record separately when desired.
