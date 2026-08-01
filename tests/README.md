# e2e tests

Real-Docker, end-to-end tests for `openvidu-fake-vm`. They drive the actual scripts against
a real Docker daemon and assert genuine behavior — SSH into a VM, install Docker and k3s
inside it, toggle the firewall and probe reachability, push/pull through the registry, and
download artifacts from fake-web over trusted HTTPS.

See **[TESTS.md](TESTS.md)** for a per-test description of what each scenario proves.

## Safety / isolation

The whole suite runs in a **separate namespace** from any real fake-vm you have running:
its own docker network (`fake-vm-e2e`), container-name prefix (`fake-vm-e2e-`), subnet
(`172.31.99.0/24`) and a throwaway SSH config. See [`e2e/profile.bash`](e2e/profile.bash).
Because the name prefix is isolated, even `stop --all --prune` only ever touches the test
stack — your real VMs and your `~/.ssh/config` are never affected.

These env seams are plain `${VAR:-default}` overrides in the scripts; unset, the scripts
behave exactly as before.

## Requirements

- Linux (the docker bridge must be host-reachable) and a running Docker daemon.
- Internet access for the cases that install Docker/k3s or pull images (they `skip` when offline).
- [`bats-core`](https://github.com/bats-core/bats-core) with `bats-support` + `bats-assert`.
  A system install (e.g. `pacman -S bats`, with helpers under `/usr/lib/bats`) is used if
  present; otherwise `make bootstrap` vendors them into `tests/e2e/libs/`.

## Running

```bash
make e2e-smoke        # fast tier: start/SSH, IP alloc, firewall, DinD, stop/prune (~1-2 min)
make e2e-full         # k3s (--verify-keep), registry push/pull, fake-web, certs (several min)
make e2e              # both tiers
make lint             # shellcheck the scripts + helpers

# a single file, or leave the stack up to poke at:
tests/e2e/run.sh                                   # smoke (default)
E2E_TIER=full tests/e2e/run.sh
FAKE_VM_E2E=1 bats tests/e2e/smoke/firewall.bats   # one file, still isolated
E2E_KEEP=1 tests/e2e/run.sh                        # do not tear down on exit
E2E_FORCE_CLEAN=1 tests/e2e/run.sh                 # wipe a leftover stack first
```

Layout: `smoke/` = fast tier, `full/` = slow tier; `test_helper.bash` = shared setup/guards,
`profile.bash` = the isolation profile, `run.sh` = runner (isolation + preflight + cleanup trap).
