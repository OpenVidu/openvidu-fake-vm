#!/usr/bin/env bats
# bats file_tags=e2e:smoke
#
# The simulated firewall must change REAL reachability, not just ufw rule text. We bind a
# listener inside the VM (python3 is guaranteed by the image) and probe it from the host.

load '../test_helper'

export FAKE_VM_NO_REGISTRY=1
E2E_IP="172.31.99.12"
E2E_NAME="fake-vm-e2e-172-31-99-12"
PORT=8080

setup_file() {
    require_e2e
    export BATS_TEST_TIMEOUT=300
    "$FAKE_VM" start "$E2E_IP" >&2
    # Detached listener in the container — survives independently of any ssh session.
    docker exec -d "$E2E_NAME" python3 -m http.server "$PORT" >&2
    sleep 2
}

teardown_file() {
    e2e_teardown
}

@test "port is reachable before any firewall (sanity)" {
    run port_reachable "$E2E_IP" "$PORT"
    assert_success
}

@test "default-deny (reset) blocks the port" {
    run "$FAKE_VM" firewall "$E2E_IP" reset
    assert_success
    run port_reachable "$E2E_IP" "$PORT"
    assert_failure                                   # blocked
}

@test "opening the port makes it reachable again" {
    run "$FAKE_VM" firewall "$E2E_IP" open "${PORT}/tcp"
    assert_success
    run port_reachable "$E2E_IP" "$PORT"
    assert_success                                   # reachable
}

@test "closing the port blocks it again" {
    run "$FAKE_VM" firewall "$E2E_IP" close "${PORT}/tcp"
    assert_success
    run port_reachable "$E2E_IP" "$PORT"
    assert_failure                                   # blocked
}

@test "SSH (22) stays open and cannot be closed" {
    # Even under default-deny, ssh must keep working.
    run "$FAKE_VM" ssh "$E2E_IP" true
    assert_success

    run "$FAKE_VM" firewall "$E2E_IP" close 22
    assert_output --partial "refusing to close SSH port"

    run "$FAKE_VM" ssh "$E2E_IP" true
    assert_success
}
