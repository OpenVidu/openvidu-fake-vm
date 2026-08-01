# Test catalog

What each e2e test does and the behavior it proves. All tests drive the real scripts against
a real Docker daemon, in the isolated namespace described in [`README.md`](README.md)
(network `fake-vm-e2e`, prefix `fake-vm-e2e-`, subnet `172.31.99.0/24`). Every test file is
gated by `require_e2e` (Linux + Docker + `FAKE_VM_E2E=1`); the ones that install software or
pull images also call `require_internet` and `skip` when offline.

Two tiers:

- **smoke/** — fast (~1-2 min), no k3s. Lifecycle, SSH, IP allocation, firewall, DinD, cleanup.
- **full/** — slower (several min). k3s, registry, fake-web, certificate.

---

## smoke/

### `lifecycle.bats` — VM `172.31.99.10`, registries disabled
One VM is started once in `setup_file` and reused. Proves the core lifecycle end to end.

| Test | What it proves |
|------|----------------|
| start brought the container up and running | `docker inspect` reports the container `Running=true` after `start`. |
| ssh into the VM works as the ubuntu user | `fake-vm.sh ssh <ip> true` succeeds and `whoami` returns `ubuntu` — real SSH, real login. |
| the managed SSH-config block is isolated to the test config | The `# >>> fake-vm <ip> (managed)` block is written to the **test** SSH config and is **absent** from the real `~/.ssh/config` — proves the isolation seam. |
| list shows the VM by IP and DNS name | `fake-vm.sh list` output contains the IP and the `172-31-99-10.openvidu-local.dev` name. |
| stop removes the container, its volumes and the SSH block | After `stop <ip>`: container gone, both named volumes (`-rancher`, `-docker`) gone, and the managed SSH block removed. |

### `prune.bats` — VM `172.31.99.20`, registries disabled
| Test | What it proves |
|------|----------------|
| stop --all --prune removes the VM and the isolated network | The network exists before; after `stop --all --prune` the container is gone, the docker network is removed, and no `fake-vm-e2e-*` containers remain. This is the command that would be destructive without the `NAME_PREFIX` isolation seam, so it also proves the scoping holds. |

### `ip_alloc.bats` — two auto-assigned VMs, registries disabled
| Test | What it proves |
|------|----------------|
| two auto-assigned VMs come up on distinct IPs | Two `start` calls with no IP land on `172.31.99.10` and `172.31.99.11` (first two free in range), both running, with distinct container IPs. |

### `firewall.bats` — VM `172.31.99.12`, python listener on `:8080`
A detached `python3 -m http.server 8080` runs inside the VM; the host probes reachability with
`curl`. Proves the firewall changes **real** reachability, not just `ufw` rule text.

| Test | What it proves |
|------|----------------|
| port is reachable before any firewall (sanity) | With no firewall applied, the host can reach `:8080`. |
| default-deny (reset) blocks the port | After `firewall <ip> reset` (default-deny, only 22), the probe times out — genuinely blocked. |
| opening the port makes it reachable again | After `firewall <ip> open 8080/tcp`, the probe succeeds. |
| closing the port blocks it again | After `firewall <ip> close 8080/tcp`, the probe times out again. |
| SSH (22) stays open and cannot be closed | SSH still works under default-deny; `firewall <ip> close 22` is refused (`refusing to close SSH port`) and SSH keeps working. |

### `dind.bats` — VM `172.31.99.13`, needs internet
| Test | What it proves |
|------|----------------|
| nested Docker installs and runs a container | Installs Docker inside the VM via `get.docker.com`, then `docker run --rm hello-world` prints `Hello from Docker!` — nested Docker genuinely works. |

---

## full/

### `k3s.bats` — VM `172.31.99.14`, `--verify-keep`, needs internet
Brought up with `--verify-keep`, which installs k3s over SSH and waits until the node is Ready,
leaving it running. Proves a real Kubernetes cluster comes up and schedules work.

| Test | What it proves |
|------|----------------|
| the k3s node reports Ready | `k3s kubectl get nodes` shows the node as `Ready`. |
| k3s schedules and runs a pod to completion | A `busybox` pod is created; it reaches `Succeeded` and its logs are exactly `hi` — the cluster genuinely schedules, runs and completes a workload. |
| a NodePort service is reachable only while the firewall opens it | A real nginx Deployment is exposed via a NodePort (30080): blocked under default-deny, reachable after `firewall open 30080/tcp`, blocked again after `close`. Proves pod + Service + port-open + firewall working **together** (the NodePort is DNAT'd, so this exercises the FORWARD-gating layer, not ufw INPUT). |
| the firewall does not affect internal ClusterIP service communication | With the perimeter fully locked (default-deny), a client pod still reaches a backend via its **ClusterIP** DNS name — proving intra-cluster pod-to-pod and CoreDNS traffic (which rides the CNI, not `eth0`) is **untouched** by the firewall. The blast radius of the firewall stays at the perimeter. |

### `dind_firewall.bats` — VM `172.31.99.17`, registries disabled, needs internet
Integration of nested Docker + an exposed port + the firewall: install Docker, run `nginx:alpine`
publishing a port, and gate it.

| Test | What it proves |
|------|----------------|
| the published container port is reachable before any firewall | `curl http://<ip>:18080/` reaches the nested container. |
| default-deny blocks the container port, but its egress still works | After `firewall reset`, the published port is blocked (the DNAT'd port is genuinely gated), yet the container can still reach the internet — so inter-container/egress traffic is untouched. |
| opening the port serves the container to the host | After `firewall open 18080/tcp`, the host gets the nginx page. |
| closing the port blocks the container again | After `firewall close 18080/tcp`, the port is blocked again. |

### `registry.bats` — VM `172.31.99.15`, registries enabled, needs internet
A tiny image is built on the host, published with `registry.sh push`, and pulled from a nested
Docker inside the VM. Proves the registry-mirror wiring done at VM start.

| Test | What it proves |
|------|----------------|
| the registry mirror config was written into the VM | `/etc/docker/daemon.json` and `/etc/rancher/k3s/registries.yaml` both contain the dev-registry endpoint (`172.31.99.3:5000`). |
| a locally-pushed image pulls inside the VM under its natural name | `docker pull e2e-local/tiny:dev` (its natural name, no rewrite) succeeds inside the VM and the image runs — proving the mirror makes the dev registry the first endpoint tried. |

### `fakeweb.bats` — VM `172.31.99.16`, registries disabled
`fake-web up` + `publish` an artifact with known content; download it three ways.

| Test | What it proves |
|------|----------------|
| artifact downloads from the host over HTTP | `curl http://172.31.99.4/<path>` returns the exact published content. |
| artifact downloads over publicly-trusted HTTPS (no -k) | `curl --resolve <name>:443:<ip> https://172-31-99-4.openvidu-local.dev/<path>` (no `-k`) returns the content — the wildcard cert validates against the **system trust store**, proving it is genuinely publicly trusted. Skips if HTTPS is unavailable (cert missing/offline). |
| artifact downloads from inside a VM over HTTP | The same artifact is fetched from inside a VM — proves zero-config reachability from the VM. |

### `certs.bats` — no VM
| Test | What it proves |
|------|----------------|
| certs fetches a present, non-expired certificate | `fake-vm.sh certs` produces `fullchain.pem`/`privkey.pem`; `openssl x509 -checkend 0` confirms it is not expired; the banner mentions `openvidu-local.dev`. Skips if no cert can be obtained (offline, none cached). Its *trusted* property is exercised end-to-end by `fakeweb.bats`' no-`-k` fetch. |

---

## Harness (not tests)

- **`profile.bash`** — the isolation profile: pins every `FAKE_VM_*` seam to the `fake-vm-e2e`
  namespace and forces `FAKE_VM_RUNTIME=privileged` for determinism (override to test sysbox).
- **`test_helper.bash`** — loaded by every file: loads `bats-support`/`bats-assert`, applies the
  profile, redirects all mutable state to the suite temp dir, and provides the guards
  (`require_e2e`, `require_internet`) and helpers (`ssh_vm`, `port_reachable`, `e2e_teardown`).
- **`run.sh`** — the runner: exports the profile, refuses to adopt a leftover stack (pre-flight),
  installs an always-runs cleanup trap, and runs the tier selected by `E2E_TIER`.
