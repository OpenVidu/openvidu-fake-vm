# openvidu-fake-vm — lint & e2e test targets.
#
#   make lint         shellcheck the scripts + test helpers
#   make e2e-smoke    real-Docker smoke tier (start/SSH/firewall/DinD/stop) — fast
#   make e2e-full     real-Docker full tier (k3s/registry/fake-web/certs) — several min
#   make e2e          both tiers
#   make test         lint + smoke tier
#   make bootstrap    vendor bats-core + helpers into tests/e2e/libs (CI / no system bats)
#
# The e2e suite runs in an isolated docker network/name-prefix and never touches a real
# fake-vm stack (see tests/e2e/profile.bash). Requires Docker + Linux; some cases need internet.

SCRIPTS      := fake-vm.sh registry.sh fake-web.sh
LINT_TARGETS := $(SCRIPTS) tests/e2e/run.sh tests/e2e/profile.bash tests/e2e/test_helper.bash

.PHONY: test lint e2e e2e-smoke e2e-full bootstrap

test: lint e2e-smoke

lint:
	shellcheck -x -S warning $(LINT_TARGETS)

e2e-smoke:
	E2E_TIER=smoke tests/e2e/run.sh

e2e-full:
	E2E_TIER=full tests/e2e/run.sh

e2e:
	E2E_TIER=all tests/e2e/run.sh

bootstrap:
	@mkdir -p tests/e2e/libs
	@[ -d tests/e2e/libs/bats-core ]    || git clone --depth 1 https://github.com/bats-core/bats-core.git    tests/e2e/libs/bats-core
	@[ -d tests/e2e/libs/bats-support ] || git clone --depth 1 https://github.com/bats-core/bats-support.git tests/e2e/libs/bats-support
	@[ -d tests/e2e/libs/bats-assert ]  || git clone --depth 1 https://github.com/bats-core/bats-assert.git  tests/e2e/libs/bats-assert
