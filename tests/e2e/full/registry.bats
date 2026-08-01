#!/usr/bin/env bats
# bats file_tags=e2e:full
#
# The registry wiring lets a locally-built image be pulled inside the VM under its NATURAL
# name (no reference rewrite). We build a tiny image on the host, push it, then pull it from
# a nested Docker whose daemon.json was wired at VM start.

load '../test_helper'

E2E_IP="172.31.99.15"
E2E_NAME="$(vm_container "$E2E_IP")"           # honours FAKE_VM_NAME_PREFIX (e.g. CI's)
LOCAL_IMAGE="e2e-local/tiny:dev"

setup_file() {
    require_e2e
    require_internet
    export BATS_TEST_TIMEOUT=900

    # A tiny host image to publish.
    local ctx="${BATS_SUITE_TMPDIR}/tinyctx"
    mkdir -p "$ctx"
    printf 'FROM busybox:latest\nLABEL e2e=1\n' > "${ctx}/Dockerfile"
    docker build -t "$LOCAL_IMAGE" "$ctx" >&2

    # Start a VM WITH registries (so the mirror config is written), publish the image, and
    # install a nested Docker to pull with.
    "$FAKE_VM" start "$E2E_IP" >&2
    "$REGISTRY" push "$LOCAL_IMAGE" >&2
    "$FAKE_VM" ssh "$E2E_IP" 'curl -fsSL https://get.docker.com | sudo sh' >&2
}

teardown_file() {
    e2e_teardown
    # Remove both the built image and the push tag (localhost:<port>/<repo>).
    docker rmi -f "$LOCAL_IMAGE" "localhost:${FAKE_VM_REGISTRY_PORT}/${LOCAL_IMAGE}" \
        >/dev/null 2>&1 || true
}

@test "the registry mirror config was written into the VM" {
    # These are root-owned config files, so read them with sudo.
    run "$FAKE_VM" ssh "$E2E_IP" 'sudo cat /etc/docker/daemon.json'
    assert_success
    assert_output --partial "172.31.99.3:5000"        # DEV_IP mirror

    run "$FAKE_VM" ssh "$E2E_IP" 'sudo cat /etc/rancher/k3s/registries.yaml'
    assert_success
    assert_output --partial "172.31.99.3:5000"
}

@test "a locally-pushed image pulls inside the VM under its natural name" {
    run "$FAKE_VM" ssh "$E2E_IP" "sudo docker pull ${LOCAL_IMAGE}"
    assert_success

    run "$FAKE_VM" ssh "$E2E_IP" "sudo docker run --rm ${LOCAL_IMAGE} true"
    assert_success
}
