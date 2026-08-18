#!/usr/bin/env python3
from pathlib import Path
root=Path(__file__).resolve().parents[1]
e=(root/'main-engine/dragon-fruit-relay-egress.sh').read_text()
i=(root/'main-engine/dragon-fruit-relay-ingress.sh').read_text()
# Server initialization and profile materialization must not rely on errexit
# while nested under `if ! (...)`.
assert 'ensure_hub_layout && write_hub_host_config && write_hub_readme && install_self_copy && write_hub_helpers && registry_command init --endpoint "$SERVER_ENDPOINT" &&' in e
assert 'registry_command init --endpoint "$SERVER_ENDPOINT" &&' in e
assert "error 'Server initialization failed; rolling back the partial installation.'" in e
assert 'rm -rf "$STATE_DIR";' in e
assert 'write_client_profile "$name" &&\n        load_client_profile "$name" &&' in e
# Client setup transaction has the same explicit chaining guarantee.
assert 'write_common_xfrm_files && write_strongswan_common_files && write_swanctl_ingress && write_ingress_routing_files && write_ingress_healthcheck_files && activate_ingress' in i
# A zero-connection malformed standalone v2.1.0 registry can be safely reset,
# while populated malformed state is never discarded automatically.
assert 'repair_partial_v210_registry_if_safe' in e
assert "print('REBUILD' if count==0 else 'UNSAFE')" in e
assert 'Refusing destructive automatic recovery' in e
print('fail-fast contract: initialization/connection transactions stop on first failure and rollback safely')
