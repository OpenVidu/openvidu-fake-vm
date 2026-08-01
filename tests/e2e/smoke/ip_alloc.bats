#!/usr/bin/env bats
# bats file_tags=e2e:smoke
#
# Auto IP allocation: starting without an IP assigns the first free address in the range,
# and a second VM gets a distinct one.

load '../test_helper'

export FAKE_VM_NO_REGISTRY=1
NAME_10="$(vm_container 172.31.99.10)"         # honours FAKE_VM_NAME_PREFIX (e.g. CI's)
NAME_11="$(vm_container 172.31.99.11)"

setup_file() {
    require_e2e
    export BATS_TEST_TIMEOUT=300
    "$FAKE_VM" start >&2        # no IP -> should get .10 (first free)
    "$FAKE_VM" start >&2        # no IP -> should get .11
}

teardown_file() {
    e2e_teardown
}

@test "two auto-assigned VMs come up on distinct IPs" {
    assert container_running "$NAME_10"
    assert container_running "$NAME_11"

    ip1="$(docker inspect -f "{{(index .NetworkSettings.Networks \"${FAKE_VM_NETWORK}\").IPAddress}}" "$NAME_10")"
    ip2="$(docker inspect -f "{{(index .NetworkSettings.Networks \"${FAKE_VM_NETWORK}\").IPAddress}}" "$NAME_11")"

    assert_equal "$ip1" "172.31.99.10"
    assert_equal "$ip2" "172.31.99.11"
    [ "$ip1" != "$ip2" ]
}
