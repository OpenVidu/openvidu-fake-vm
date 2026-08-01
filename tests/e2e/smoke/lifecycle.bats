#!/usr/bin/env bats
# bats file_tags=e2e:smoke
#
# Lifecycle: start a VM, prove SSH genuinely works, that it is listed, that the SSH-config
# block lands in the ISOLATED config (never the real ~/.ssh/config), and that stop removes
# the container, its volumes and the SSH block.

load '../test_helper'

export FAKE_VM_NO_REGISTRY=1     # this file does not exercise the registries; skip the pull
E2E_IP="172.31.99.10"
E2E_NAME="$(vm_container "$E2E_IP")"           # honours FAKE_VM_NAME_PREFIX (e.g. CI's)
E2E_DNS="172-31-99-10.openvidu-local.dev"

setup_file() {
    require_e2e
    export BATS_TEST_TIMEOUT=300
    "$FAKE_VM" start "$E2E_IP" >&2
}

teardown_file() {
    e2e_teardown
}

@test "start brought the container up and running" {
    run docker inspect -f '{{.State.Running}}' "$E2E_NAME"
    assert_success
    assert_output "true"
}

@test "ssh into the VM works as the ubuntu user" {
    run "$FAKE_VM" ssh "$E2E_IP" true
    assert_success

    run "$FAKE_VM" ssh "$E2E_IP" whoami
    assert_success
    assert_output "ubuntu"
}

@test "the managed SSH-config block is isolated to the test config" {
    assert [ -f "$FAKE_VM_SSH_CONFIG" ]
    run grep -F "fake-vm ${E2E_IP} (managed)" "$FAKE_VM_SSH_CONFIG"
    assert_success

    # The developer's real ~/.ssh/config must be untouched.
    if [[ -f "${HOME}/.ssh/config" ]]; then
        run grep -F "fake-vm ${E2E_IP} (managed)" "${HOME}/.ssh/config"
        assert_failure
    fi
}

@test "list shows the VM by IP and DNS name" {
    run "$FAKE_VM" list
    assert_success
    assert_output --partial "$E2E_IP"
    assert_output --partial "$E2E_DNS"
}

# Must be last in this file: it removes the shared VM.
@test "stop removes the container, its volumes and the SSH block" {
    run "$FAKE_VM" stop "$E2E_IP"
    assert_success

    run docker inspect "$E2E_NAME"
    assert_failure                                   # container gone

    run docker volume inspect "${E2E_NAME}-rancher"
    assert_failure                                   # volumes gone
    run docker volume inspect "${E2E_NAME}-docker"
    assert_failure

    run grep -F "fake-vm ${E2E_IP} (managed)" "$FAKE_VM_SSH_CONFIG"
    assert_failure                                   # SSH block removed
}
