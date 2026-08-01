#!/usr/bin/env bats
# bats file_tags=e2e:smoke
#
# `stop --all --prune` must remove every VM AND the docker network. This is exactly the
# command that would be catastrophic without the NAME_PREFIX isolation seam (it selects
# containers host-wide by name), so proving it here also proves the isolation holds.

load '../test_helper'

export FAKE_VM_NO_REGISTRY=1
E2E_IP="172.31.99.20"
E2E_NAME="fake-vm-e2e-172-31-99-20"

setup_file() {
    require_e2e
    export BATS_TEST_TIMEOUT=300
    "$FAKE_VM" start "$E2E_IP" >&2
}

teardown_file() {
    e2e_teardown
}

@test "stop --all --prune removes the VM and the isolated network" {
    run docker network inspect "$FAKE_VM_NETWORK"
    assert_success                                   # network exists before

    run "$FAKE_VM" stop --all --prune
    assert_success

    run docker inspect "$E2E_NAME"
    assert_failure                                   # container gone

    run docker network inspect "$FAKE_VM_NETWORK"
    assert_failure                                   # network removed

    # No leftover containers under the isolated prefix.
    run bash -c "docker ps -a --format '{{.Names}}' | grep -c '^${FAKE_VM_NAME_PREFIX}' || true"
    assert_output "0"
}
