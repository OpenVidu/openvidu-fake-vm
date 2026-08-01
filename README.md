# openvidu-fake-vm — locally-simulated remote VMs

Spin up throwaway "remote machines" for testing and development: a Docker container that
behaves like a real remote host — **Ubuntu 24.04 with systemd as PID 1**.

Features that simulate a typical remote machine:

- **[SSH connection](#ssh-access-and-keys)** as the `ubuntu` user with passwordless
  `sudo` — key-only, just like a real Ubuntu cloud image, and with nothing for you to
  set up.
- **[DNS name and a valid certificate](#dns--tls)**, so a web server you run on the VM is
  reachable over **HTTPS that every client already trusts** — no `-k`, no CA to install,
  no `/etc/hosts` entry. Each VM is identified by its internal IP, publishes no host
  port, and answers on `<ip-with-dashes>.openvidu-local.dev` (e.g.
  `172-30-0-10.openvidu-local.dev`).
- **[Docker and k3s install with their standard commands](#usage)**, over SSH, exactly as
  on a real VM — the machine starts out blank, with nothing pre-installed.
- **[Virtual firewall](#firewall)** to control which ports are reachable from outside.
- **[Shared Docker registry cache](#container-registries-transparent-cache--local-images)**,
  so images are downloaded from the Internet once instead of on every install.
- **[Virtual web server](#local-web-server-for-unreleased-artifacts)**, reachable only
  from the machines, to serve artifacts that are not published anywhere yet.

Nothing needs installing: clone the repo and run the scripts. The only
requirement on the host is **Docker** (plus `curl` or `wget` for the HTTPS
certificate — without them the scripts degrade to HTTP-only).

> [!IMPORTANT]
> **Only tested on Linux**, with Docker Engine on a Linux host. The whole design assumes
> the docker bridge lives in the host's own network stack — that is what lets you `ssh`
> straight to a VM's IP. On macOS and Windows, Docker runs inside a VM and that assumption
> no longer holds, so parts of this break. See
> [Running it on macOS or Windows](#running-it-on-macos-or-windows).

```bash
git clone https://github.com/OpenVidu/openvidu-fake-vm.git
cd openvidu-fake-vm
./fake-vm.sh start
```

Everything is driven by a single script, `fake-vm.sh`, with subcommands:

```bash
./fake-vm.sh help                      # full usage
./fake-vm.sh start   [IP] [options]    # create + start a VM
./fake-vm.sh stop    <IP> | --all      # stop + remove a VM (and its SSH creds)
./fake-vm.sh firewall <IP> <action>    # manage the simulated firewall
./fake-vm.sh ssh     <IP> [cmd...]     # ssh in (as ubuntu)
./fake-vm.sh certs   [IP]              # HTTPS certificate paths, ready to copy-paste
./fake-vm.sh list                      # list running fake-vms
```

## Usage

```bash
# start a VM (auto-assigns a free IP in 172.30.0.0/16)
./fake-vm.sh start

# ...or pick the IP explicitly
./fake-vm.sh start 172.30.0.10

# start and prove k3s works on it (installs k3s over SSH, waits until the node
# is Ready, then uninstalls it so the VM is left blank)
./fake-vm.sh start 172.30.0.10 --verify        # --verify-keep keeps k3s running

# start with a firewall: default-deny incoming, only these ports reachable
./fake-vm.sh start 172.30.0.10 --open 80,443,6443/tcp
# ...or default-allow with specific ports blocked
./fake-vm.sh start 172.30.0.10 --close 8080,9000/tcp

# connect (credentials are added to your ~/.ssh/config automatically; user=ubuntu)
ssh fake-vm-172-30-0-10                 # or: ssh 172-30-0-10.openvidu-local.dev
./fake-vm.sh ssh 172.30.0.10            # convenience wrapper (no config needed)

# install k3s / Docker yourself, exactly like on a real remote VM (needs sudo)
./fake-vm.sh ssh 172.30.0.10 'curl -sfL https://get.k3s.io | sudo sh -'
./fake-vm.sh ssh 172.30.0.10 'curl -fsSL https://get.docker.com | sudo sh'

# stop one VM (removes the container, its volumes, and the SSH credentials)
./fake-vm.sh stop 172.30.0.10

# stop every fake-vm (and, with --prune, the docker network too)
./fake-vm.sh stop --all
./fake-vm.sh stop --all --prune
```

## Firewall

Set the initial policy at `start` time (`--firewall deny|allow|off`, `--open
PORTS`, `--close PORTS`), or change it live on a running VM:

```bash
./fake-vm.sh firewall 172.30.0.10 status
./fake-vm.sh firewall 172.30.0.10 open  6443/tcp,8472/udp   # make reachable
./fake-vm.sh firewall 172.30.0.10 close 8080                # make unreachable
./fake-vm.sh firewall 172.30.0.10 default allow             # flip default policy
./fake-vm.sh firewall 172.30.0.10 reset                     # default-deny, only 22 open
./fake-vm.sh firewall 172.30.0.10 off                       # disable the firewall
```

Ports are comma/space lists; append `/tcp` or `/udp` to scope the protocol.
**Port 22 (SSH) is always kept open** and cannot be closed. The model is
declarative — every change resets ufw and reapplies the full desired state, so
reachability never depends on rule ordering. Under `default deny` the open set
is the allowlist; under `default allow` the close set is the denylist. Firewall
changes are applied over `docker exec` (never over SSH), so a default-deny
policy can never lock you out.

> To run **k3s behind the firewall**, open the ports it needs (`6443/tcp` for the
> API, `8472/udp` for flannel VXLAN, `10250/tcp` for the kubelet, plus your app
> ports). A single-node k3s reaches the API over loopback, so it comes up Ready
> even under default-deny — only external access to those ports is filtered.

## SSH access and keys

There is **nothing to set up**: you never generate a key, copy a public key into a VM,
type a password or accept a host key. `start` leaves you able to `ssh` into the VM
immediately, and `stop` undoes it.

```bash
./fake-vm.sh start 172.30.0.10

ssh fake-vm-172-30-0-10                 # by name
ssh 172-30-0-10.openvidu-local.dev      # by DNS name
ssh ubuntu@172.30.0.10                  # by IP

scp report.tar.gz fake-vm-172-30-0-10:  # scp / rsync / ansible work the same way
```

You land as **`ubuntu`** with passwordless `sudo`, exactly as on a real Ubuntu cloud
image. Root login and password authentication are disabled, so keys are the only way in.

**One key opens every VM.** It is created for you the first time you run `start` and then
reused, so it is a property of the checkout rather than of any single VM. It is
git-ignored and never leaves your machine. Tools that want to connect by themselves —
a test suite, a deploy CLI, `ansible` — take this path:

```text
<checkout>/.ssh/id_ed25519
```

`start` also registers the VM with your **`~/.ssh/config`**, which is what makes the
plain `ssh <name>` above work with no flags. `stop` removes exactly that registration and
nothing else, so your SSH config never accumulates dead entries. Two consequences worth
knowing:

- Recreating a VM on an IP you used before **never** produces a host-key warning — the
  old identity is dropped when you `stop`, so there is nothing stale to clash with.
- Deleting the key while VMs are running locks you out of them: a VM only accepts the key
  it was created with. Recreate them (`stop`, then `start`) to get back in.

If you would rather not rely on your SSH config at all — in a script, or from a different
shell — the wrapper connects with no configuration whatsoever:

```bash
./fake-vm.sh ssh 172.30.0.10                    # interactive shell
./fake-vm.sh ssh 172.30.0.10 'sudo systemctl status ssh'   # one-off command
```

## DNS & TLS

`*.openvidu-local.dev` is a public wildcard DNS alias that resolves
`a-b-c-d.openvidu-local.dev` → `a.b.c.d`, so a VM's DNS name resolves to its
container IP from the host with no `/etc/hosts` edits. A matching wildcard TLS
certificate is downloaded automatically from `https://certs.openvidu-local.dev/`
every time it is needed (`start`, `certs`, `fake-web.sh up`), landing next to the
scripts (git-ignored):

- Private key: `privkey.pem`
- Full-chain certificate: `fullchain.pem`

It is a real, publicly-trusted Let's Encrypt certificate, so **whatever you deploy on
a VM gets HTTPS that every client already trusts** — no CA to install, no `-k`, no
`/etc/hosts` entry. `start` prints its **absolute** paths and its expiry date, together
with an example of the flags that consume them, so the block can be pasted straight into
a command. Ask for it again at any time (the IP is optional when a single VM is running):

```bash
./fake-vm.sh certs 172.30.0.10
```

```text
HTTPS certificate for *.openvidu-local.dev — real and publicly trusted (valid until Oct 12 19:11:21 2026 GMT):

  public key (full chain): /abs/path/to/openvidu-fake-vm/fullchain.pem
  private key:             /abs/path/to/openvidu-fake-vm/privkey.pem

Serve real HTTPS on 172-30-0-10.openvidu-local.dev — e.g. paste into `ov stack deploy`:

  --domain-name 172-30-0-10.openvidu-local.dev \
  --certificate-type owncert \
  --owncert-public-key /abs/path/to/openvidu-fake-vm/fullchain.pem \
  --owncert-private-key /abs/path/to/openvidu-fake-vm/privkey.pem
```

Those example flags are the [OpenVidu CLI](https://openvidu.io)'s, since that is what
this tool was built to test — but the certificate is not tied to it: anything that takes
a domain plus a certificate/key path is configured the same way.

The certificate does expire, but renewal is automatic: every use re-downloads the pair
from `https://certs.openvidu-local.dev/`. When the download fails, a valid local copy
keeps being used (with a warning); without one, the same command prints the manual
`curl` lines to fetch the pair yourself.

## Container registries (transparent cache + local images)

Two tiny registries live on the `fake-vm` docker network, shared by every VM and
persistent across VM lifecycles (`registry.sh`, started automatically by `start`):

| Container | Role |
|---|---|
| `fake-vm-registry-cache` | **Pull-through cache of Docker Hub.** Every image a stack pulls is cached, so re-deploys and new VMs don't re-download gigabytes. |
| `fake-vm-registry` | **Read-write registry for locally-built images** — e.g. an image you just built and want a VM to pull. Published on the host as `localhost:5001` (Docker allows plain-HTTP pushes to `localhost`, so no `/etc/docker/daemon.json` edits). |

`start` writes **both** registry configurations into the VM (plus an `/etc/hosts` entry
for `fake-registry`) before k3s or Docker exist, so they are transparent whatever the
deploy path installs later:

| File | Read by | Picked up |
|---|---|---|
| `/etc/rancher/k3s/registries.yaml` | k3s's containerd | when k3s is installed |
| `/etc/docker/daemon.json` | a Docker installed **inside** the VM — e.g. a Docker Compose deploy over SSH | when dockerd first starts |

Both registries are endpoints of the same `docker.io` mirror, **in this order**:

```
1. fake-vm-registry        locally-built images (instant local 404 for anything else)
2. fake-vm-registry-cache  cached copy of Docker Hub
3. registry-1.docker.io    last resort
```

containerd tries them in order and falls through on any failure, including a 404 — so an
image you built and pushed is pulled **under its natural name** (`myorg/myimage:dev`, no
registry prefix), while everything else goes through the cache. That is why no DNS
trickery is needed: pointing `registry-1.docker.io` at a local registry would break TLS
and lose the fallback.

`dockerd` is configured the same way, in its own dialect: `registry-mirrors` (which
applies to Docker Hub only — exactly our case) with the same ordering and the same
fall-through, plus `insecure-registries` because both registries speak plain HTTP. Two
consequences of Docker's model: nothing but Docker Hub is cached (`ghcr.io`, `quay.io`,
… are pulled directly), and **pushes never go to a mirror** — publish a local image with
`registry.sh push` from the host, as below.

```bash
./registry.sh up                       # start both (idempotent; `start` does it for you)
./registry.sh push my/image:dev        # publish a local image; prints the VM-side reference
./registry.sh attach 172.30.0.10       # configure a VM that is ALREADY running (restarts
                                       #   k3s; reloads dockerd if it is running)
./registry.sh status
./registry.sh config                   # print the k3s registries.yaml body
./registry.sh docker-config            # print the VM's /etc/docker/daemon.json
./registry.sh down [--prune]           # stop them (--prune also deletes the cached blobs)
```

A locally-built image is then pulled by the cluster like any other image — same name, no
flags:

```bash
docker build -t myorg/myimage:dev .
./registry.sh push myorg/myimage:dev   # publish it under that same name; pass a second
                                       #   argument to publish under another repo:tag
```

Push it under **the exact tag your chart or compose file already references** and a
plain, flagless deploy uses your build with nothing to override. Note that this
**shadows that tag for every fake-vm** on the host — which is the point, but it does mean
the real upstream image is no longer reachable under that name until you clear it with
`./registry.sh down --prune`.

Caches live in `.cache/` (git-ignored) and survive `stop`; `stop --all --prune` removes
the registries and their blobs. Set `FAKE_VM_NO_REGISTRY=1` to disable the whole thing.

## Local web server for unreleased artifacts

What the registries do for container images, `fake-web.sh` does for **downloads**: it
serves a directory of artifacts to the VMs, so instructions that fetch a file can be
tested with **unreleased** artifacts, with nothing published on the Internet.

| Container | IP | Role |
|---|---|---|
| `fake-vm-web` | 172.30.0.4 | Static file server (caddy) for `www/` on **:80 and :443**, no host port published. |

```bash
./fake-web.sh up                                   # start (idempotent)
./fake-web.sh publish ./install.sh myproduct/1.0.0/install.sh
./fake-vm.sh ssh 172.30.0.10 'curl -fsSL http://172.30.0.4/myproduct/1.0.0/install.sh | sh'
./fake-web.sh logs -f                              # see exactly what was downloaded
```

Two URLs, and **both work with zero setup** — from the VM, from a container inside the VM,
from a pod, and from the host:

```
http://172.30.0.4/<path>                        plain HTTP, nothing to trust
https://172-30-0-4.openvidu-local.dev/<path>    HTTPS with the auto-downloaded PUBLICLY
                                                trusted wildcard certificate (see DNS & TLS)
```

That second URL is the interesting one: the certificate is a real, publicly-trusted
Let's Encrypt wildcard for `*.openvidu-local.dev`, and that DNS alias resolves the
dashed-IP name to the server's IP. So HTTPS needs **no `-k`, no CA and no `/etc/hosts`
entry anywhere** — verified from a nested container inside a VM with a plain `alpine`
image.

This deliberately does **not** impersonate a real hostname (no `/etc/hosts` or DNS
tricks) and installs **no CA**: a nested container or a pod would trust neither, since
each image carries its own trust store, and rewiring all of them is not worth it.
Instead, **whatever you are testing must take the download URL as configuration** — then
you point that configuration at one of the URLs above.

```bash
./fake-web.sh status                   # container state, document root, both URLs
./fake-web.sh logs [-f]                # trimmed access log: who asked for what, and got what
./fake-web.sh config                   # print the generated Caddyfile
./fake-web.sh down [--prune]           # stop (--prune also deletes the published artifacts)
```

Artifacts live in `www/` (git-ignored) and survive `stop`. `fake-vm.sh stop --all --prune`
removes the server along with the network, but keeps the artifacts. `up` downloads and
refreshes the certificate automatically; if the download fails and no valid local copy
exists, it says so and serves HTTP only.

## Using it from another project

fake-vm is a standalone tool: clone it wherever you like and call the scripts by path.
Automated test suites usually want to find it without hardcoding one developer's layout,
so the suggested convention is a **`FAKE_VM_DIR` environment variable falling back to a
sibling clone**:

```bash
FAKE_VM_DIR="${FAKE_VM_DIR:-../openvidu-fake-vm}"
"$FAKE_VM_DIR/fake-vm.sh" start 172.30.0.10
```

Two paths inside the checkout are the ones consumers need:

| Path | What it is |
|---|---|
| `.ssh/id_ed25519` | the private key that logs into every VM as `ubuntu` (generated on the first `start`) |
| `fullchain.pem` / `privkey.pem` | the publicly-trusted wildcard certificate for `*.openvidu-local.dev` (downloaded automatically) |

## How it works

- **Image** (`Dockerfile`): a *blank* Ubuntu 24.04 machine — systemd, sshd and
  the prerequisites k3s/Docker need — but **nothing pre-installed**, so it
  faithfully mimics a fresh remote VM you deploy onto. Built once, then cached.
- **Runtime**: `--runtime auto` (default) uses the `sysbox-runc` runtime **if it
  is registered with Docker**, otherwise falls back to `--privileged`. Force one
  with `--runtime privileged` / `--runtime sysbox`. Privileged is the proven
  path for running k3s this way; sysbox is an unprivileged alternative when
  available.
- **k3s & Docker-in-Docker storage**: `/var/lib/rancher` (k3s+containerd) and
  `/var/lib/docker` (nested Docker) are named docker volumes on the host's real
  filesystem, and the baked `/etc/docker/daemon.json` forces the classic
  `overlay2` driver. containerd's overlayfs snapshotter can't stack on docker's
  overlay (overlay-on-overlay is rejected by the kernel), so these are what let
  k3s/containerd and an inner `docker run` start inside the container.
  **`start` always begins from a clean slate**: it removes any pre-existing
  `<name>-rancher` / `<name>-docker` volumes before creating the container, so a VM
  never inherits a previous run's k3s state. This matters because those volumes can
  outlive the container (a host reboot, `docker rm`, `docker system prune`), and a
  reattached `/var/lib/rancher` carries stale local-path PVCs — e.g. a MongoDB/MinIO
  volume still holding the *old* generated passwords, which then breaks every service
  that authenticates against them on a redeploy.
- **Kernel modules**: `overlay`, `br_netfilter` and `nf_conntrack` are loaded
  into the shared host kernel on `start` via a throwaway privileged helper (no
  host `sudo` needed).
- **Login**: the `ubuntu` user (passwordless `sudo`) with key-only SSH; root
  login and password auth are disabled, as on a real cloud VM.
- **SSH**: the keypair is generated once under `.ssh/` (git-ignored) and its public
  half is injected into each VM at `start`. `start` also writes a per-VM managed
  block to `~/.ssh/config` (keyed by IP) plus a scoped `known_hosts`; `stop` removes
  exactly that block and those host keys again. See
  [SSH access and keys](#ssh-access-and-keys) for what this means in practice.
- **Firewall**: `ufw` with `DEFAULT_FORWARD_POLICY=ACCEPT`, so an enabled
  default-deny INPUT policy filters inbound port reachability without breaking
  k3s pod/service networking. The desired spec lives at
  `/etc/fake-vm/firewall.conf` inside the VM.

## Running it on macOS or Windows

**None of this has been tested.** fake-vm is developed and used on Linux; what follows is
reasoned from how the tool is built plus what the upstream projects document. Treat it as a
starting point for someone who wants to try, not as instructions known to work — and if you
do get it working, please open an issue or a PR.

### The one thing that decides it

fake-vm identifies each VM by its **container IP** and publishes **no host ports**, on
purpose. On Linux the docker bridge lives in the host's own network stack, so
`ssh 172.30.0.10` from the host simply works — and that single property is what SSH access,
the `openvidu-local.dev` names, the HTTPS certificate story and reaching `fake-web` from the
host are all built on.

On macOS and Windows, Docker runs inside a Linux VM and the bridge lives in there. Docker's
own documentation is explicit about the consequence:

> Per-container IP addressing is not possible. This is because the Docker `bridge` network
> is not reachable from the host.
>
> — [Networking how-tos on Docker Desktop](https://docs.docker.com/desktop/features/networking/networking-how-tos/)

This is not a detail you can work around later: `start` waits for SSH on the VM's IP **from
the host** and gives up if nothing answers, so where the bridge is unroutable the very first
command fails. For each platform, then, the only real question is: *can the host reach the
docker bridge?*

### Windows: use WSL2, and stay inside it

The promising path is Docker Engine installed **natively inside a WSL2 distro** (not Docker
Desktop's Windows integration), driving the scripts **from that distro's shell**. Inside the
distro you are on an ordinary Linux host with an ordinary docker bridge, so the assumption
above holds again and `ssh fake-vm-<ip>` should behave as documented.

- **Drive it from the WSL2 shell, not from Windows.** `172.30.0.x` is not routable from
  Windows itself, and the `~/.ssh/config` entry `start` writes is the distro's — Windows
  OpenSSH, PuTTY and your IDE's Windows-side SSH will not see it.
- **Mirrored networking does not obviously fix that.** `networkingMode=mirrored`
  (Windows 11 22H2+) lets Windows and the distro reach each other over `localhost`, but it
  is not documented to route the docker bridge subnet, and Docker Desktop does not use
  mirrored mode at all. See
  [WSL networking](https://learn.microsoft.com/en-us/windows/wsl/networking).
- **k3s is the risky part.** The WSL2 kernel ships no loadable modules, so the
  `modprobe overlay br_netfilter nf_conntrack` step will fail (the script warns and carries
  on). Whether k3s then works depends on those features being compiled into your kernel —
  historically `CONFIG_BRIDGE_NETFILTER` was not, and people resorted to a custom kernel or
  a hand-written `modules.builtin`. See
  [microsoft/WSL#4203](https://github.com/microsoft/WSL/issues/4203). Docker-based
  deployments carry no such dependency and are the safer thing to try first.
- **Keep the checkout on the Linux filesystem** (`~/…`, not `/mnt/c/…`): SSH refuses a
  private key with loose permissions, and the Windows drive mount cannot represent `600`.

### macOS: the runtime you pick decides everything

- **Docker Desktop** — the bridge is unreachable by design (quote above), so the IP-first
  model does not work at all. Nothing short of reworking the tool to publish host ports
  would help.
- **[OrbStack](https://docs.orbstack.dev/docker/network)** — the most promising option: it
  puts containers on unified bridge networks that *are* reachable from macOS by IP, which is
  precisely the property fake-vm needs. It manages its own subnets, so the hardcoded
  `172.30.0.0/16` may need revisiting.
- **[Colima](https://colima.run/docs/configuration/)** — plausible with extra assembly: a
  reachable VM address (`--network-address`) plus host routes into the bridge, or a helper
  such as `docker-mac-net-connect`.

Two problems will bite you regardless of the runtime, because they are in the scripts
themselves rather than in the platform:

| Where | Problem |
|---|---|
| `fake-vm.sh`, `remove_ssh_config_block` | GNU `sed -i` with no backup suffix. BSD/macOS `sed` requires `sed -i ''`, so `start` and `stop` abort under `set -e`. |
| `fake-vm.sh`, `cmd_list` | `sort -V`, which BSD `sort` does not have, so `list` fails. |

Both are small fixes that simply have never been made, because nobody has run this on a Mac.
The good news is that the scripts use no bash-4-only syntax, so Apple's bash 3.2 is not
itself an obstacle.

Beyond that, **systemd as PID 1** in a privileged container has been reported broken on
Apple Silicon Docker Desktop (`Failed to mount cgroup at /sys/fs/cgroup/systemd`), and that
report was closed without a resolution
([docker/for-mac#6073](https://github.com/docker/for-mac/issues/6073)) — old enough to be
worth re-testing rather than trusting either way. And on Apple Silicon the image builds
`arm64`, so whatever you deploy inside the VM needs arm64 images or it falls back to
emulation.

### What would still work anywhere

Everything that never crosses the host↔VM boundary is unaffected: the VM booting, Docker and
k3s installs *inside* it, the registry cache and locally-pushed images, `fake-web` as
consumed **from** a VM, and the firewall (driven over `docker exec`, never SSH).
`registry.sh push` also keeps working, because its host endpoint is a published
`127.0.0.1:5001` port rather than a bridge IP.

### The escape hatch

To get the tool's real behaviour on a non-Linux laptop with no porting at all, run it
**inside a Linux VM** — Lima, Multipass, UTM, or a cheap cloud box — and use it from that
VM's shell. Containers nested in a VM are exactly what the tool already does.
