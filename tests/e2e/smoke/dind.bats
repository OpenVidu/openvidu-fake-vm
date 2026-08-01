#!/usr/bin/env bats
# bats file_tags=e2e:smoke
#
# Docker-in-Docker: the image ships with the DinD daemon.json baseline but NO docker
# daemon, so we install it over SSH exactly as a user would, then run a container.

load '../test_helper'

export FAKE_VM_NO_REGISTRY=1
E2E_IP="172.31.99.13"

setup_file() {
    require_e2e
    require_internet
    export BATS_TEST_TIMEOUT=600
    "$FAKE_VM" start "$E2E_IP" >&2
}

teardown_file() {
    e2e_teardown
}

@test "nested Docker installs and runs a container" {
    run "$FAKE_VM" ssh "$E2E_IP" 'curl -fsSL https://get.docker.com | sudo sh'
    assert_success

    run "$FAKE_VM" ssh "$E2E_IP" 'sudo docker run --rm hello-world'
    assert_success
    assert_output --partial "Hello from Docker!"
}
