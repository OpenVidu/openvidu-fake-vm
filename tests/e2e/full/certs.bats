#!/usr/bin/env bats
# bats file_tags=e2e:full
#
# The HTTPS certificate for *.openvidu-local.dev is fetched, present and not expired.
# (Its "publicly trusted" property is exercised end-to-end by fakeweb.bats' no-`-k` fetch.)

load '../test_helper'

setup_file() {
    require_e2e
    export BATS_TEST_TIMEOUT=120
}

teardown_file() {
    e2e_teardown
}

@test "certs fetches a present, non-expired certificate" {
    "$FAKE_VM" certs >&2 || true                     # refresh; may fail offline
    [[ -f "${REPO_ROOT}/fullchain.pem" && -f "${REPO_ROOT}/privkey.pem" ]] \
        || skip "no certificate available (offline and none cached)"

    run openssl x509 -in "${REPO_ROOT}/fullchain.pem" -noout -checkend 0
    assert_success                                   # exit 0 => not expired

    run "$FAKE_VM" certs
    assert_success
    assert_output --partial "openvidu-local.dev"
}
