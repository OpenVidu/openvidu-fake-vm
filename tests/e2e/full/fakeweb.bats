#!/usr/bin/env bats
# bats file_tags=e2e:full
#
# fake-web serves published artifacts by IP over HTTP, over publicly-trusted HTTPS on its
# openvidu-local.dev name (no -k), and reachably from inside a VM.

load '../test_helper'

export FAKE_VM_NO_REGISTRY=1
E2E_IP="172.31.99.16"
WEB_IP="172.31.99.4"
WEB_NAME="172-31-99-4.openvidu-local.dev"
PATH_UNDER_TEST="community/test/file.txt"
PAYLOAD="hello-e2e-payload"

setup_file() {
    require_e2e
    export BATS_TEST_TIMEOUT=300
    # fake-web needs the network; a VM also lets us download from inside a VM.
    "$FAKE_VM" start "$E2E_IP" >&2
    printf '%s' "$PAYLOAD" > "${BATS_SUITE_TMPDIR}/artifact.txt"
    "$FAKE_WEB" up >&2
    "$FAKE_WEB" publish "${BATS_SUITE_TMPDIR}/artifact.txt" "$PATH_UNDER_TEST" >&2
}

teardown_file() {
    "$FAKE_WEB" down --prune >/dev/null 2>&1 || true
    e2e_teardown
}

@test "artifact downloads from the host over HTTP" {
    run curl -fsS "http://${WEB_IP}/${PATH_UNDER_TEST}"
    assert_success
    assert_output "$PAYLOAD"
}

@test "artifact downloads over publicly-trusted HTTPS (no -k)" {
    # --resolve pins name->IP; the wildcard cert's SAN is still validated against the system
    # trust store, so a clean exit proves the cert is genuinely trusted (no CA installed).
    local url="https://${WEB_NAME}/${PATH_UNDER_TEST}"
    if ! curl -fsS --resolve "${WEB_NAME}:443:${WEB_IP}" "$url" >/dev/null 2>&1; then
        skip "HTTPS not available (certificate missing or download blocked)"
    fi
    run curl -fsS --resolve "${WEB_NAME}:443:${WEB_IP}" "$url"
    assert_success
    assert_output "$PAYLOAD"
}

@test "artifact downloads from inside a VM over HTTP" {
    run "$FAKE_VM" ssh "$E2E_IP" "curl -fsS http://${WEB_IP}/${PATH_UNDER_TEST}"
    assert_success
    assert_output "$PAYLOAD"
}
