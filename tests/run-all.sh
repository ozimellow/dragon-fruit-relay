#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
run_test() {
    local test_name="$1"
    case "$test_name" in
        *.py)
            timeout 90s python3 "$ROOT/tests/$test_name"
            ;;
        *.sh)
            timeout 90s bash "$ROOT/tests/$test_name"
            ;;
        *)
            timeout 90s "$ROOT/tests/$test_name"
            ;;
    esac
}
# Run cryptographic release tests before the heavier registry/control integration
# group so the release runner stays deterministic in constrained containers.
run_test test-static.py
run_test test-ui-contract.py
run_test test-software-release.py
run_test test-client-release-verification.py
run_test test-auto-client-release.py
run_test test-bundled-client.py
run_test test-failfast.py
run_test test-client-local-calls.py
run_test test-client-fresh-setup.sh
run_test test-installer.sh
run_test test-registry.py
run_test test-endpoint-sync.py
run_test test-config-transaction.py
run_test test-control-contract.py
run_test test-token.py
run_test test-sanitization.py
run_test test-manifest.sh
printf '%s\n' 'ALL RELEASE TESTS PASSED'
