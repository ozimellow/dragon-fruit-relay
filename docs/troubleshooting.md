# Troubleshooting

## Server shows zero connections

Zero connections is valid. Operations Center, Server Operations, backups, software management, configuration, and Connections should remain available. Use Diagnostics only if the Server itself reports a service or registry fault.

## Client cannot resolve the Server endpoint

If the endpoint is an IPv4 address, verify routing to that public address. If it is an FQDN, verify it resolves to one public IPv4 address and that the address matches the intended Server. The Client uses direct public DNS during endpoint bootstrap so its normal tunneled resolver path is not required first.

## Enrollment fails

Generate a fresh DFR1 token on the Server, verify the token was copied completely, confirm it has not expired, and verify the connection has not been replaced. DFR1 is the only accepted enrollment format in v2.1.0.

## Tunnel is established but peer is unreachable

Inspect the assigned `dfrNNNN` XFRM interface, XFRM ID, /30 addresses, strongSwan CHILD SA, and the Server connection runtime. `dragon-fruit-relay diagnostics` and `dragon-fruit-relay test` provide the normal read-only checks.

## Quota/speed behavior is unexpected

Inspect the connection subscription, current-period usage, lifetime usage, suspension state, per-connection upload/download limits, and Server global shaping policy. Refresh CONTROL status on the Client after changing Server policy.

## Client update fails

Inspect release status, digest/signature verification, Client rollout policy, CONTROL reachability, update state, and rollback state from the Server connection dossier and Client update-status screen.
