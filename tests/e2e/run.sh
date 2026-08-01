#!/usr/bin/env bash
#
# run.sh — run the openvidu-fake-vm e2e suite against a real Docker daemon, in an isolated
# namespace that never touches a real fake-vm stack.
#
# Usage:
#   tests/e2e/run.sh                 # smoke tier (default)
#   E2E_TIER=full  tests/e2e/run.sh  # k3s + registry + fake-web + certs
#   E2E_TIER=all   tests/e2e/run.sh  # everything
#
# Env:
#   E2E_TIER=smoke|full|all   which tier to run (default: smoke)
#   E2E_KEEP=1                do not tear the stack down on exit (debug)
#   E2E_FORCE_CLEAN=1         wipe a leftover e2e stack before starting instead of aborting
#   (plus the FAKE_VM_* isolation seams from profile.bash, overridable for CI)
set -euo pipefail

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${E2E_DIR}/../.." && pwd)"

# Opt-in flag the .bats guards check, and the isolation profile.
export FAKE_VM_E2E=1
# shellcheck source=tests/e2e/profile.bash
source "${E2E_DIR}/profile.bash"

err() { echo "ERROR: $*" >&2; }
info() { echo ">>> $*"; }

# --- resolve bats -------------------------------------------------------------
BATS=""
if [[ -x "${E2E_DIR}/libs/bats-core/bin/bats" ]]; then
    BATS="${E2E_DIR}/libs/bats-core/bin/bats"
elif command -v bats >/dev/null 2>&1; then
    BATS="$(command -v bats)"
else
    err "bats not found. Install bats-core (e.g. 'pacman -S bats' / 'apt-get install bats')"
    err "or vendor it with: make bootstrap"
    exit 1
fi
export BATS_LIB_PATH="${E2E_DIR}/libs:/usr/lib/bats:/usr/local/lib/bats${BATS_LIB_PATH:+:${BATS_LIB_PATH}}"

# --- pre-flight: refuse to adopt a leftover stack -----------------------------
leftover() {
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${FAKE_VM_NAME_PREFIX}" \
        || docker network inspect "$FAKE_VM_NETWORK" >/dev/null 2>&1
}
if leftover; then
    if [[ "${E2E_FORCE_CLEAN:-}" == "1" ]]; then
        info "cleaning leftover e2e stack (${FAKE_VM_NETWORK}) ..."
        "${REPO_ROOT}/fake-vm.sh" stop --all --prune >/dev/null 2>&1 || true
        docker network rm "$FAKE_VM_NETWORK" >/dev/null 2>&1 || true
    else
        err "a leftover e2e stack exists (network ${FAKE_VM_NETWORK} or ${FAKE_VM_NAME_PREFIX}* containers)."
        err "remove it first, or re-run with E2E_FORCE_CLEAN=1."
        exit 1
    fi
fi

# --- always clean up on exit --------------------------------------------------
cleanup() {
    [[ "${E2E_KEEP:-}" == "1" ]] && { info "E2E_KEEP=1 — leaving the stack up"; return 0; }
    info "tearing down the e2e stack ..."
    "${REPO_ROOT}/fake-vm.sh" stop --all --prune >/dev/null 2>&1 || true
    docker network rm "$FAKE_VM_NETWORK" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

# --- select tier and run ------------------------------------------------------
tier="${E2E_TIER:-smoke}"
case "$tier" in
    smoke) dirs=("${E2E_DIR}/smoke") ;;
    full)  dirs=("${E2E_DIR}/full") ;;
    all)   dirs=("${E2E_DIR}/smoke" "${E2E_DIR}/full") ;;
    *)     err "unknown E2E_TIER: ${tier} (want smoke|full|all)"; exit 2 ;;
esac

info "running e2e tier '${tier}' with ${BATS} (network ${FAKE_VM_NETWORK}, subnet ${FAKE_VM_SUBNET})"
"$BATS" --print-output-on-failure --recursive "${dirs[@]}"
