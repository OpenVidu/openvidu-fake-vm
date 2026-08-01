# shellcheck shell=bash
# Isolation profile for the e2e suite.
#
# It pins every fake-vm.sh / registry.sh / fake-web.sh env seam to a namespace that is
# completely separate from a real fake-vm stack: its own docker network, container-name
# prefix, subnet and IP range. Because the name prefix is isolated, `stop --all --prune`
# only ever touches THIS stack — never the developer's real fake-vms.
#
# Sourced by both tests/e2e/run.sh and tests/e2e/test_helper.bash. Every var uses `:=`, so
# an explicit override from the environment (e.g. the CI workflow) always wins.

: "${FAKE_VM_NETWORK:=fake-vm-e2e}"
: "${FAKE_VM_NAME_PREFIX:=fake-vm-e2e-}"
: "${FAKE_VM_SUBNET:=172.31.99.0/24}"
: "${FAKE_VM_GATEWAY:=172.31.99.1}"
: "${FAKE_VM_IP_PREFIX:=172.31.99}"     # infra at .2/.3/.4, VMs from .10
: "${FAKE_VM_IP_RANGE_START:=10}"
: "${FAKE_VM_IP_RANGE_END:=40}"
: "${FAKE_VM_REGISTRY_PORT:=5099}"      # host push port; avoids the real 5001
# Force the privileged runtime for determinism: CI runners have no sysbox, and where sysbox
# IS registered its behavior is environment-specific. The scripts under test are runtime-
# agnostic, so pinning one keeps the suite reproducible. Override to test the sysbox path.
: "${FAKE_VM_RUNTIME:=privileged}"

export FAKE_VM_NETWORK FAKE_VM_NAME_PREFIX FAKE_VM_SUBNET FAKE_VM_GATEWAY \
       FAKE_VM_IP_PREFIX FAKE_VM_IP_RANGE_START FAKE_VM_IP_RANGE_END \
       FAKE_VM_REGISTRY_PORT FAKE_VM_RUNTIME
