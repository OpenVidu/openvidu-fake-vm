#!/usr/bin/env bats
# bats file_tags=e2e:full
#
# Integration: a nested Docker container that PUBLISHES a port, exercised together with the
# firewall. Proves the whole chain — create a container inside the fake-VM, expose a port,
# and have the firewall genuinely gate it (open → reachable from the host, closed/deny →
# blocked) — while the container's own outbound traffic keeps working.

load '../test_helper'

export FAKE_VM_NO_REGISTRY=1
E2E_IP="172.31.99.17"
PORT=18080

setup_file() {
    require_e2e
    require_internet
    export BATS_TEST_TIMEOUT=600
    "$FAKE_VM" start "$E2E_IP" >&2
    "$FAKE_VM" ssh "$E2E_IP" 'curl -fsSL https://get.docker.com | sudo sh' >&2
    # A nested container serving HTTP on a published port.
    "$FAKE_VM" ssh "$E2E_IP" "sudo docker run -d -p ${PORT}:80 --name web nginx:alpine" >&2
    sleep 3
}

teardown_file() {
    e2e_teardown
}

# egress_ok — the nested container can still reach the internet
egress_ok() {
    "$FAKE_VM" ssh "$E2E_IP" 'sudo docker exec web wget -q -T 8 -O /dev/null http://get.docker.com'
}

@test "the published container port is reachable before any firewall" {
    run port_reachable "$E2E_IP" "$PORT"
    assert_success
}

@test "default-deny blocks the container port, but its egress still works" {
    run "$FAKE_VM" firewall "$E2E_IP" reset
    assert_success
    run port_reachable "$E2E_IP" "$PORT"
    assert_failure                              # DNAT'd port genuinely blocked
    run egress_ok
    assert_success                              # inter-container / egress untouched
}

@test "opening the port serves the container to the host" {
    run "$FAKE_VM" firewall "$E2E_IP" open "${PORT}/tcp"
    assert_success
    run wait_reachable "$E2E_IP" "$PORT"
    assert_success
    run curl -fsS --max-time 6 "http://${E2E_IP}:${PORT}/"
    assert_success
    assert_output --partial "nginx"             # the nginx container is actually answering
}

@test "closing the port blocks the container again" {
    run "$FAKE_VM" firewall "$E2E_IP" close "${PORT}/tcp"
    assert_success
    run port_reachable "$E2E_IP" "$PORT"
    assert_failure
}
