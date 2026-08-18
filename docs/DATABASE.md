# Database Contract

Dragon Fruit Relay v2.1.0 uses standalone registry schema **1**. Fresh installation creates the final schema directly. Registry metadata records `product=dragon-fruit-relay` and `product_lineage=standalone-dfr`.

## Exact tables

- `meta`
- `hub`
- `server_policy`
- `server_endpoint_fallbacks`
- `connections`
- `subscriptions`
- `usage`
- `audit`
- `ingress_state`
- `control_nonces`
- `enrollment_tokens`
- `config_pending`
- `software_releases`
- `software_release_usage`

`meta` contains exactly the current product identity, standalone lineage marker, and registry schema marker. The schema-contract test fails on an unexpected application table or column.

## Responsibilities

`hub` stores the Server endpoint lifecycle. `server_policy` stores global upload/download shaping limits. `connections` stores per-connection allocation, tunnel identity, credentials, update policy, and desired software state. New connection rows default to `update_policy=auto`; if a STABLE Client release exists, creation immediately assigns that exact release as the AUTO desired target. `subscriptions` and `usage` store expiry, quota, speed limits, accounting periods, and lifetime counters. `ingress_state` stores presence, health, Client software/update state, endpoint acknowledgement, and action results. `config_pending` supports bounded configuration transactions. Release tables support signed Client software publication and rollout tracking.

## Fresh schema rule

A fresh v2.1.0 database is never built by creating historical structures and deleting them afterward. Schema 1 is the direct creation target.

## Future upgrades

Future DFR releases may introduce explicit schema migrations from earlier standalone DFR schema versions. Such migrations must be bounded, backed up, validated, and end at the exact current schema. They are DFR-to-DFR migrations only.
