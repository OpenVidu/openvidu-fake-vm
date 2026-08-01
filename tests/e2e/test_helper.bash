# shellcheck shell=bash
# Common setup for every e2e .bats file. Load it from a test with:  load '../test_helper'
#
# Responsibilities:
#   - load bats-support / bats-assert (vendored under tests/libs, or system-installed)
#   - apply the isolation profile (so even a bare `bats tests/e2e/...` run is safe)
#   - point the per-run state (ssh config, registry blobs, web root) at temp dirs
#   - expose helpers: guards (require_*), the script paths, ssh_vm, port_reachable, teardown

_e2e_helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- bats helper libraries ----------------------------------------------------
# Search vendored libs first (make bootstrap / CI), then common system locations.
BATS_LIB_PATH="${_e2e_helper_dir}/libs:/usr/lib/bats:/usr/local/lib/bats${BATS_LIB_PATH:+:${BATS_LIB_PATH}}"
export BATS_LIB_PATH
bats_load_library bats-support
bats_load_library bats-assert

# --- isolation profile + per-run state ----------------------------------------
# CRITICAL: sourced here too (not only in run.sh) so a direct `bats <file>` invocation is
# still fully isolated from any real fake-vm and can never edit ~/.ssh/config.
source "${_e2e_helper_dir}/profile.bash"

REPO_ROOT="$(cd "${_e2e_helper_dir}/../.." && pwd)"
FAKE_VM="${REPO_ROOT}/fake-vm.sh"
REGISTRY="${REPO_ROOT}/registry.sh"
FAKE_WEB="${REPO_ROOT}/fake-web.sh"
export REPO_ROOT FAKE_VM REGISTRY FAKE_WEB

# Redirect all mutable state into the suite temp dir so nothing touches the real repo/home.
export FAKE_VM_SSH_CONFIG="${BATS_SUITE_TMPDIR}/ssh_config"
export FAKE_VM_REGISTRY_CACHE_DIR="${BATS_SUITE_TMPDIR}/registry-cache"
export FAKE_VM_REGISTRY_DEV_DIR="${BATS_SUITE_TMPDIR}/registry-dev"
export FAKE_WEB_ROOT="${BATS_SUITE_TMPDIR}/www"
export FAKE_WEB_STATE_DIR="${BATS_SUITE_TMPDIR}/fake-web"

# --- guards -------------------------------------------------------------------

require_e2e_enabled() {
    [[ "${FAKE_VM_E2E:-}" == "1" ]] || skip "set FAKE_VM_E2E=1 to run the real-Docker e2e suite"
}

require_linux() {
    [[ "$(uname -s)" == "Linux" ]] || skip "e2e requires Linux (host-reachable docker bridge)"
}

require_docker() {
    command -v docker >/dev/null 2>&1 || skip "docker is not installed"
    docker info >/dev/null 2>&1 || skip "docker daemon is not available"
}

# One call to gate a whole file: Linux + docker + explicit opt-in.
require_e2e() { require_e2e_enabled; require_linux; require_docker; }

have_internet() { curl -fsS --max-time 8 -o /dev/null "${1:-https://get.docker.com}" 2>/dev/null; }
require_internet() { have_internet "${1:-}" || skip "no internet access (needed for this scenario)"; }

# --- vm helpers ---------------------------------------------------------------

vm_container() { echo "${FAKE_VM_NAME_PREFIX}${1//./-}"; }   # ip -> container name

# ssh_vm <ip> [cmd...] — run a command in the VM as ubuntu (config-free, checkout key).
ssh_vm() { "$FAKE_VM" ssh "$@"; }

# port_reachable <ip> <port> — 0 if an HTTP request to ip:port gets any response, non-zero
# on refusal/timeout (i.e. firewall-blocked). Used to prove real reachability changes.
port_reachable() { curl -s -o /dev/null --max-time 5 "http://$1:$2/"; }

# wait_reachable <ip> <port> [tries] — retry port_reachable while a service warms up
# (e.g. a freshly-exposed NodePort). Returns non-zero if never reachable.
wait_reachable() {
    local ip="$1" port="$2" tries="${3:-10}"
    for _ in $(seq 1 "$tries"); do
        port_reachable "$ip" "$port" && return 0
        sleep 2
    done
    return 1
}

# container_running <name>
container_running() { [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]; }

# --- teardown -----------------------------------------------------------------
# Scoped and idempotent: only touches the isolated NAME_PREFIX/NETWORK. Call from each
# file's teardown_file. E2E_KEEP=1 leaves everything up for debugging.
e2e_teardown() {
    [[ "${E2E_KEEP:-}" == "1" ]] && return 0
    "$FAKE_VM" stop --all --prune >/dev/null 2>&1 || true
    docker network rm "$FAKE_VM_NETWORK" >/dev/null 2>&1 || true
    # The registry container writes its blobs root-owned into the bind-mounted dirs, which
    # the unprivileged bats tmpdir cleanup then cannot delete. Wipe them as root first.
    if [[ -e "${FAKE_VM_REGISTRY_CACHE_DIR}" || -e "${FAKE_VM_REGISTRY_DEV_DIR}" ]]; then
        docker run --rm -v "${BATS_SUITE_TMPDIR}:/w" alpine:latest \
            rm -rf /w/registry-cache /w/registry-dev >/dev/null 2>&1 || true
    fi
}
