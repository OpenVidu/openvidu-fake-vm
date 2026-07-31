#!/usr/bin/env bash
#
# registry.sh — container registries for the fake-vm network.
#
# Two tiny registries live on the `fake-vm` docker network, shared by every VM and
# persistent across VM lifecycles:
#
#   fake-vm-registry-cache (172.30.0.2)  a PULL-THROUGH CACHE of Docker Hub. Every image
#                                        a stack pulls is cached here, so re-deploys (and
#                                        new VMs) don't re-download gigabytes.
#   fake-vm-registry       (172.30.0.3)  a read-write registry for LOCALLY BUILT images
#                                        (an image you just built and want a VM to pull).
#                                        Reachable from the VM as `fake-registry:5000`,
#                                        and from the host as `localhost:5001` (which
#                                        Docker trusts over plain HTTP with no daemon
#                                        configuration).
#
# `fake-vm.sh start` brings both up and writes the VM's registry configuration — for k3s
# AND for a Docker installed inside the VM — so for a VM this is entirely transparent:
# pulls are cached, and a locally-built image is pulled like any other image — no "copy
# the image into the node at the right moment" step in the middle of a deploy.
#
# Usage:
#   ./registry.sh up                    # start both (idempotent)
#   ./registry.sh push <image> [<ref>]  # publish a local image; prints the VM ref
#   ./registry.sh attach <VM_IP>        # configure a RUNNING VM + restart k3s
#   ./registry.sh config                # print the k3s registries.yaml body
#   ./registry.sh docker-config         # print the VM's /etc/docker/daemon.json
#   ./registry.sh status
#   ./registry.sh down [--prune]        # stop (--prune also drops the caches)
#
# Env: FAKE_VM_NO_REGISTRY=1 disables all of it (fake-vm.sh then configures nothing).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NETWORK="fake-vm"
CACHE_NAME="fake-vm-registry-cache"
CACHE_IP="172.30.0.2"
DEV_NAME="fake-vm-registry"
DEV_IP="172.30.0.3"
# The hostname VMs use for the dev registry. It is never resolved by containerd (the
# mirror rewrites it to DEV_IP) but is also added to the VM's /etc/hosts, so the
# reference works from every tool inside the VM. Keeping it a NAME instead of an IP
# means image references in charts/tutorials don't change if the IP does.
DEV_HOST="fake-registry:5000"
DEV_HOST_PORT="${FAKE_VM_REGISTRY_PORT:-5001}" # host-side port for pushes (localhost ⇒ HTTP ok)
REGISTRY_IMAGE="${FAKE_VM_REGISTRY_IMAGE:-registry:2}"
CACHE_DIR="${SCRIPT_DIR}/.cache/registry-cache"
DEV_DIR="${SCRIPT_DIR}/.cache/registry-dev"

err()  { echo "ERROR: $*" >&2; }
info() { echo ">>> $*"; }

disabled() { [[ -n "${FAKE_VM_NO_REGISTRY:-}" ]]; }

running() { [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]; }
exists()  { docker inspect "$1" >/dev/null 2>&1; }

# ensure_one starts (or restarts) one registry container with a pinned IP. Recreated
# when its IP drifted, so the k3s config written into the VMs stays valid.
ensure_one() {
    local name="$1" ip="$2" dir="$3"; shift 3
    if exists "$name"; then
        local cur
        cur="$(docker inspect -f "{{(index .NetworkSettings.Networks \"${NETWORK}\").IPAddress}}" "$name" 2>/dev/null || true)"
        if [[ "$cur" == "$ip" ]]; then
            running "$name" || { info "starting existing ${name} (${ip})"; docker start "$name" >/dev/null; }
            return 0
        fi
        info "recreating ${name} (was ${cur:-none}, want ${ip})"
        docker rm -f "$name" >/dev/null
    fi
    mkdir -p "$dir"
    info "launching ${name} on ${ip}"
    docker run -d --name "$name" --restart unless-stopped \
        --network "$NETWORK" --ip "$ip" \
        -v "${dir}:/var/lib/registry" \
        "$@" "$REGISTRY_IMAGE" >/dev/null
}

cmd_up() {
    disabled && { info "registries disabled (FAKE_VM_NO_REGISTRY)"; return 0; }
    command -v docker >/dev/null 2>&1 || { err "docker not found"; return 1; }
    docker network inspect "$NETWORK" >/dev/null 2>&1 || {
        err "docker network '${NETWORK}' does not exist yet — run: $(dirname "$0")/fake-vm.sh start"; return 1; }

    ensure_one "$CACHE_NAME" "$CACHE_IP" "$CACHE_DIR" \
        -e "REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io"
    # Published on loopback only: the host pushes to localhost:<port> (Docker allows
    # plain HTTP there without touching /etc/docker/daemon.json).
    ensure_one "$DEV_NAME" "$DEV_IP" "$DEV_DIR" \
        -p "127.0.0.1:${DEV_HOST_PORT}:5000" \
        -e "REGISTRY_STORAGE_DELETE_ENABLED=true"
}

cmd_status() {
    printf '%-24s %-14s %s\n' NAME IP STATUS
    local name ip st
    for pair in "${CACHE_NAME}=${CACHE_IP}" "${DEV_NAME}=${DEV_IP}"; do
        name="${pair%%=*}"; ip="${pair##*=}"
        # `docker inspect -f` prints an empty line before failing, so ask first.
        st="not created"
        exists "$name" && st="$(docker inspect -f '{{.State.Status}}' "$name")"
        printf '%-24s %-14s %s\n' "$name" "$ip" "$st"
    done
    echo
    echo "host push endpoint:  localhost:${DEV_HOST_PORT}"
    echo "VM pull endpoint:    ${DEV_HOST}"
    if running "$DEV_NAME"; then
        echo "images in the dev registry:"
        curl -sf "http://127.0.0.1:${DEV_HOST_PORT}/v2/_catalog" 2>/dev/null || echo "  (registry not answering yet)"
        echo
    fi
}

cmd_down() {
    local prune=""
    [[ "${1:-}" == "--prune" ]] && prune=1
    for name in "$CACHE_NAME" "$DEV_NAME"; do
        exists "$name" && { info "removing ${name}"; docker rm -f "$name" >/dev/null; }
    done
    if [[ -n "$prune" ]]; then
        info "deleting cached blobs (${CACHE_DIR}, ${DEV_DIR})"
        rm -rf "$CACHE_DIR" "$DEV_DIR"
    else
        info "caches preserved (${SCRIPT_DIR}/.cache) — pass --prune to delete them"
    fi
}

# cmd_push publishes a locally-built image so a VM can PULL it like any other image.
# It is tagged for the host endpoint (localhost:<port>) to push, and the VM-side
# reference is printed — same repository, different address for the same registry.
cmd_push() {
    local image="${1:?usage: registry.sh push <local-image> [<repo:tag>]}"
    local repo="${2:-}"
    if [[ -z "$repo" ]]; then
        # docker.io/myorg/myimage:dev -> myorg/myimage:dev
        repo="${image#docker.io/}"
    fi
    cmd_up
    local host_ref="localhost:${DEV_HOST_PORT}/${repo}"
    info "pushing ${image} → ${host_ref}"
    docker tag "$image" "$host_ref"
    docker push "$host_ref" >/dev/null
    echo
    echo "published as ${repo}."
    echo "A fake-vm pulls it under that SAME name — the dev registry is the first endpoint"
    echo "tried for docker.io, so no reference needs rewriting:"
    echo "  ${repo}"
    echo "  ${DEV_HOST}/${repo}   (equivalent, fully qualified)"
}

# cmd_config prints the k3s registry configuration. containerd tries a mirror's
# endpoints IN ORDER and falls through on any failure (including a 404), which is what
# makes locally-built images work under their NATURAL name:
#
#   1. the dev registry   — a local, instant 404 for anything not built here
#   2. the pull-through cache of Docker Hub
#   3. Docker Hub itself  — last resort, if the cache is down
#
# So `myorg/myimage:dev` resolves to the image you just pushed, while
# `library/redis:8.6.4-alpine` falls through to the cache. No image renaming, and no DNS
# tricks (pointing registry-1.docker.io at a local registry would break TLS and lose the
# fallback). The explicit ${DEV_HOST} entry stays for anyone who prefers a fully
# qualified reference. k3s reads this at install/start time.
cmd_config() {
    disabled && return 0
    cat <<EOF
mirrors:
  "docker.io":
    endpoint:
      - "http://${DEV_IP}:5000"
      - "http://${CACHE_IP}:5000"
      - "https://registry-1.docker.io"
  "${DEV_HOST}":
    endpoint:
      - "http://${DEV_IP}:5000"
EOF
}

# cmd_docker_config prints the VM's /etc/docker/daemon.json. k3s reads registries.yaml,
# but a Docker installed INSIDE the VM ignores that file entirely — and it is the one
# that pulls the images in the on-prem deploy path (Docker Compose over SSH), so it needs
# the same wiring spelled its own way:
#
#   registry-mirrors     applies to docker.io ONLY, which is exactly our case: the cache
#                        is a pull-through of Docker Hub. dockerd tries the mirrors in
#                        order and falls back to Docker Hub on any failure (a 404 from a
#                        mirror included), so — as with containerd — a locally-pushed
#                        image resolves under its NATURAL name and everything else is
#                        cached. Pushes never go to a mirror: publish with `push` below.
#   insecure-registries  both registries speak plain HTTP. Required for a mirror declared
#                        over http:// and for direct refs such as fake-registry:5000/foo.
#
# The DinD keys are baked into the image (see Dockerfile) and repeated here because this
# writes the WHOLE file — dockerd has no config.d — so keep the two in sync.
cmd_docker_config() {
    disabled && return 0
    cat <<EOF
{
  "features": { "containerd-snapshotter": false },
  "storage-driver": "overlay2",
  "registry-mirrors": ["http://${DEV_IP}:5000", "http://${CACHE_IP}:5000"],
  "insecure-registries": ["${DEV_IP}:5000", "${CACHE_IP}:5000", "${DEV_HOST}"]
}
EOF
}

# cmd_write installs the configuration into a VM CONTAINER (by name), without needing
# k3s or Docker to exist yet — fake-vm.sh calls this at VM start, before any deploy.
cmd_write() {
    local cname="${1:?usage: registry.sh write <container-name>}"
    disabled && return 0
    local body; body="$(mktemp)"
    cmd_config > "$body"
    docker exec "$cname" mkdir -p /etc/rancher/k3s
    docker cp "$body" "${cname}:/etc/rancher/k3s/registries.yaml" >/dev/null
    # Same wiring for a nested Docker. Written even when Docker is not installed yet:
    # dockerd reads daemon.json when it first starts, so `get.docker.com | sh` afterwards
    # comes up already using the cache.
    cmd_docker_config > "$body"
    chmod 0644 "$body"
    docker exec "$cname" mkdir -p /etc/docker
    docker cp "$body" "${cname}:/etc/docker/daemon.json" >/dev/null
    rm -f "$body"
    # docker cp preserves the HOST uid; these are root-owned config files in the VM.
    docker exec "$cname" chown root:root \
        /etc/docker/daemon.json /etc/rancher/k3s/registries.yaml
    # Belt and braces: the mirror rewrite means containerd never resolves the name, but
    # anything else in the VM (docker, curl, a manual `ctr` pull) then can.
    docker exec "$cname" bash -c \
        "grep -q ' ${DEV_HOST%%:*}$' /etc/hosts || echo '${DEV_IP} ${DEV_HOST%%:*}' >> /etc/hosts"
    # If dockerd is ALREADY running, make it pick the change up. Mirrors and
    # insecure-registries are live-reloadable, so no running container is disturbed.
    if docker exec "$cname" systemctl is-active --quiet docker 2>/dev/null; then
        info "reloading dockerd in ${cname} so it picks up the registry mirrors"
        docker exec "$cname" systemctl reload docker \
            || err "could not reload dockerd — restart it to pick up the mirrors"
    fi
}

# cmd_attach configures a VM that is ALREADY RUNNING (k3s possibly installed) and
# restarts k3s so containerd picks the configuration up.
cmd_attach() {
    local ip="${1:?usage: registry.sh attach <VM_IP>}"
    local cname="fake-vm-${ip//./-}"
    exists "$cname" || { err "no fake-vm at ${ip} (${cname})"; return 1; }
    cmd_up
    cmd_write "$cname"
    if docker exec "$cname" systemctl is-active --quiet k3s 2>/dev/null; then
        info "restarting k3s on ${ip} so containerd reloads the registry configuration"
        docker exec "$cname" systemctl restart k3s
        for _ in $(seq 1 60); do
            docker exec "$cname" k3s kubectl get --raw /readyz >/dev/null 2>&1 && break
            sleep 2
        done
    fi
    info "registry configuration active on ${ip}"
}

main() {
    local cmd="${1:-status}"; shift || true
    case "$cmd" in
        up)      cmd_up "$@" ;;
        down)    cmd_down "$@" ;;
        status)  cmd_status "$@" ;;
        push)    cmd_push "$@" ;;
        attach)  cmd_attach "$@" ;;
        config)  cmd_config "$@" ;;
        docker-config) cmd_docker_config "$@" ;;
        write)   cmd_write "$@" ;;
        # Print the header comment block (everything between the shebang and the first
        # line of code), so the help stays correct as that block grows.
        -h|--help|help) awk 'NR>1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}" ;;
        *)       err "unknown command: ${cmd}"; return 2 ;;
    esac
}

main "$@"
