#!/usr/bin/env bash
#
# fake-vm.sh — manage locally-simulated remote VMs for development.
#
# Each VM is a Docker container that behaves like a real remote host: Ubuntu
# 24.04 + systemd (PID 1) + SSH, login as the 'ubuntu' user (passwordless sudo),
# capable of running k3s and Docker-in-Docker inside it. A VM is identified by
# its internal IP and is NOT published on any host port — reach it directly on
# that IP over the docker bridge, or via <ip-with-dashes>.openvidu-local.dev.
#
# Usage:
#   fake-vm.sh <command> [args]
#
# Commands:
#   start [IP] [options]        create + start a VM (auto-assigns an IP if omitted)
#   stop  <IP|name> | --all     stop + remove a VM (and its SSH credentials)
#   firewall <IP> <action>      manage a running VM's simulated firewall
#   ssh   <IP|name> [cmd...]    ssh into a VM (as the ubuntu user)
#   certs [IP|name]             print the paths of the bundled HTTPS certificate for
#                               *.openvidu-local.dev, ready to copy-paste
#   list                        list running fake-vms
#   help                        show this help
#
# start options:
#   --runtime auto|privileged|sysbox   container runtime (default auto: sysbox if
#                                       registered with Docker, else privileged)
#   --verify           install k3s over SSH, wait until Ready, then uninstall it
#                      (proves k3s works; VM left blank). Needs internet.
#   --verify-keep      like --verify but leaves k3s installed and running.
#   --firewall MODE    deny (default-deny incoming) | allow | off. 22 always open.
#   --open  PORTS      open these ports (comma list, e.g. 80,443,6443/tcp).
#                      Implies --firewall deny. Repeatable.
#   --close PORTS      close these ports (implies --firewall allow). Repeatable.
#
# stop options:
#   --all              stop every fake-vm on this host
#   --prune            with --all, also remove the docker network (and the registries)
#
# firewall actions (applied over docker exec, never SSH; 22 always stays open):
#   status                     show the firewall state
#   open  <ports>              make ports reachable
#   close <ports>              make ports unreachable
#   default <deny|allow>       set the default incoming policy
#   reset                      default-deny, only 22 open
#   off                        disable the firewall
#
# Examples:
#   fake-vm.sh start
#   fake-vm.sh start 172.30.0.10 --verify --open 80,443,6443/tcp
#   fake-vm.sh firewall 172.30.0.10 open 8472/udp
#   fake-vm.sh ssh 172.30.0.10 'curl -sfL https://get.k3s.io | sudo sh -'
#   fake-vm.sh certs 172.30.0.10
#   fake-vm.sh stop --all --prune
#
# Companion scripts on the same network:
#   registry.sh   Docker Hub pull-through cache + a registry for locally-built images
#                 (wired into a VM automatically at start)
#   fake-web.sh   a web server for unreleased artifacts, reached by IP or by its public
#                 openvidu-local.dev name — nothing to configure inside the VM
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMAGE="openvidu-fake-vm:ubuntu-24.04"
NETWORK="fake-vm"
SUBNET="172.30.0.0/16"
GATEWAY="172.30.0.1"
IP_PREFIX="172.30.0"
IP_RANGE_START=10          # auto-assigned IPs start at 172.30.0.10
IP_RANGE_END=250

SSH_USER="ubuntu"
SSH_HOME="/home/ubuntu"
KEY="${SCRIPT_DIR}/.ssh/id_ed25519"
REGISTRY_SH="${SCRIPT_DIR}/registry.sh"
FAKE_WEB_SH="${SCRIPT_DIR}/fake-web.sh"
KNOWN_HOSTS="${SCRIPT_DIR}/.ssh/known_hosts"
DNS_SUFFIX="openvidu-local.dev"
FW_CONF="/etc/fake-vm/firewall.conf"

# The bundled wildcard certificate for *.openvidu-local.dev (also used by fake-web.sh).
# Absolute paths on purpose: they are printed to be pasted into a command run from
# anywhere, not only from this directory.
CERT_FULLCHAIN="${SCRIPT_DIR}/fullchain.pem"
CERT_PRIVKEY="${SCRIPT_DIR}/privkey.pem"

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=no
          -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
          -o ConnectTimeout=5)

err()  { echo "ERROR: $*" >&2; }
info() { echo ">>> $*"; }
# usage prints the header comment block (everything between the shebang and the first
# line of code), so it stays correct as that block grows.
usage() { awk 'NR>1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; }

# --- identity helpers: a fake-vm is identified by its IP -----------------------

dashed()  { echo "${1//./-}"; }                     # 172.30.0.10 -> 172-30-0-10
vm_name() { echo "fake-vm-$(dashed "$1")"; }        # -> fake-vm-172-30-0-10
vm_dns()  { echo "$(dashed "$1").${DNS_SUFFIX}"; }  # -> 172-30-0-10.openvidu-local.dev

# fake-vm-172-30-0-10 / 172-30-0-10.openvidu-local.dev / 172.30.0.10 -> 172.30.0.10
ip_from_arg() {
    local a="$1"; a="${a#fake-vm-}"; a="${a%.${DNS_SUFFIX}}"; echo "${a//-/.}"
}

container_ip() {
    docker inspect -f "{{(index .NetworkSettings.Networks \"${NETWORK}\").IPAddress}}" "$1" 2>/dev/null
}

vm_running() { [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]; }

# vm_volumes prints a VM's named data volumes (must match the `docker run -v` mounts
# in cmd_start): -rancher = k3s state (incl. local-path PVCs), -docker = nested Docker.
vm_volumes() { echo "${1}-rancher" "${1}-docker"; }

# reset_vm_volumes removes a VM's named data volumes if they exist, so a fresh start
# never inherits a prior VM's k3s/PVC state. Safe because callers invoke it only after
# confirming the container does not exist (the volumes are therefore not in use).
reset_vm_volumes() {
    local name="$1" vol
    for vol in $(vm_volumes "$name"); do
        docker volume inspect "$vol" >/dev/null 2>&1 || continue
        if docker volume rm "$vol" >/dev/null 2>&1; then
            info "regenerated stale volume ${vol}"
        else
            err "could not remove stale volume ${vol} (in use?) — the VM may boot with old data"
        fi
    done
}

# --- prerequisites ------------------------------------------------------------

ensure_key() {
    if [[ ! -f "$KEY" ]]; then
        mkdir -p "$(dirname "$KEY")"; chmod 700 "$(dirname "$KEY")"
        ssh-keygen -t ed25519 -N '' -f "$KEY" -C "openvidu-fake-vm" >/dev/null
        info "generated SSH key: $KEY"
    fi
}

ensure_image() {
    if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
        info "building image $IMAGE ..."
        docker build -t "$IMAGE" "$SCRIPT_DIR"
    fi
}

ensure_network() {
    if ! docker network inspect "$NETWORK" >/dev/null 2>&1; then
        info "creating docker network $NETWORK ($SUBNET)"
        docker network create --driver bridge \
            --subnet "$SUBNET" --gateway "$GATEWAY" "$NETWORK" >/dev/null
    fi
}

# k3s (and DinD) need these modules in the shared host kernel. Loading them is a
# global op; do it from a throwaway privileged container so no host sudo needed.
ensure_host_modules() {
    local mods="overlay br_netfilter nf_conntrack"
    if docker run --rm --privileged --network none -v /:/host \
        --entrypoint chroot "$IMAGE" /host sh -c "for m in $mods; do modprobe \$m; done" \
        >/dev/null 2>&1; then
        info "host kernel modules loaded ($mods)"
    else
        err "could not load host kernel modules ($mods); k3s networking may fail."
        err "load them manually: sudo modprobe $mods"
    fi
}

# --- bundled TLS certificate for *.openvidu-local.dev --------------------------
# A real, publicly-trusted Let's Encrypt wildcard, so anything served on a VM's
# <ip-with-dashes>.openvidu-local.dev name gets HTTPS every client already trusts —
# no CA to install, no `-k`, no /etc/hosts entry. It is a real certificate, so it
# does expire and may be missing from a checkout.

certs_available() { [[ -f "$CERT_FULLCHAIN" && -f "$CERT_PRIVKEY" ]]; }

# certs_validity prints "valid until <date>" / "EXPIRED on <date>", or nothing when
# openssl is unavailable (the paths are still worth printing).
certs_validity() {
    command -v openssl >/dev/null 2>&1 || return 0
    local end; end="$(openssl x509 -in "$CERT_FULLCHAIN" -noout -enddate 2>/dev/null)" || return 0
    end="${end#notAfter=}"
    [[ -n "$end" ]] || return 0
    if openssl x509 -in "$CERT_FULLCHAIN" -noout -checkend 0 >/dev/null 2>&1; then
        echo "valid until ${end}"
    else
        echo "EXPIRED on ${end}"
    fi
}

# certs_missing_banner explains where the certificate is expected and how to get it back
# (it is a real Let's Encrypt pair, kept in the repo and refreshed when it expires).
certs_missing_banner() {
    cat <<EOF
HTTPS certificate for *.${DNS_SUFFIX}: NOT bundled in this checkout. Expected at:
  ${CERT_FULLCHAIN}
  ${CERT_PRIVKEY}
Download a fresh pair with:
  curl -fsSL https://certs.${DNS_SUFFIX}/fullchain.pem -o ${CERT_FULLCHAIN}
  curl -fsSL https://certs.${DNS_SUFFIX}/privkey.pem   -o ${CERT_PRIVKEY}
EOF
}

# certs_flags prints, as a ready-to-paste example, how a consumer wires the certificate to
# a VM's public name — the reason the paths are worth printing at all. The flags shown are
# the OpenVidu CLI's (`ov stack deploy`); anything that takes a domain plus a cert/key path
# is configured the same way. $1 is the domain.
certs_flags() {
    cat <<EOF
  --domain-name ${1} \\
  --certificate-type owncert \\
  --owncert-public-key ${CERT_FULLCHAIN} \\
  --owncert-private-key ${CERT_PRIVKEY}
EOF
}

# certs_banner is the standalone `certs` output: paths + flags. $1 is a VM IP; with no
# argument the domain is left as a placeholder.
certs_banner() {
    local ip="${1:-}" domain="<ip-with-dashes>.${DNS_SUFFIX}"
    [[ -n "$ip" ]] && domain="$(vm_dns "$ip")"

    certs_available || { certs_missing_banner; return 0; }

    local validity; validity="$(certs_validity)"
    cat <<EOF
HTTPS certificate for *.${DNS_SUFFIX} — real and publicly trusted${validity:+ (${validity})}:

  public key (full chain): ${CERT_FULLCHAIN}
  private key:             ${CERT_PRIVKEY}

Serve real HTTPS on ${domain} — e.g. paste into \`ov stack deploy\`:

$(certs_flags "$domain")
EOF
}

has_sysbox() {
    docker info --format '{{range .Runtimes}}{{.}} {{end}}' 2>/dev/null | grep -qw sysbox-runc
}

inject_ssh_key() {
    local name="$1" pub; pub="$(cat "${KEY}.pub")"
    docker exec "$name" sh -c \
        "install -d -m 700 -o ${SSH_USER} -g ${SSH_USER} ${SSH_HOME}/.ssh && \
         printf '%s\n' '$pub' > ${SSH_HOME}/.ssh/authorized_keys && \
         chmod 600 ${SSH_HOME}/.ssh/authorized_keys && \
         chown ${SSH_USER}:${SSH_USER} ${SSH_HOME}/.ssh/authorized_keys"
}

# --- host ssh client integration ----------------------------------------------
# A per-VM managed block in ~/.ssh/config keyed by the VM's IP, so `ssh
# fake-vm-<ip>` / `ssh <ip>.openvidu-local.dev` just work. Removed on stop.

ssh_block_begin() { echo "# >>> fake-vm $1 (managed) >>>"; }
ssh_block_end()   { echo "# <<< fake-vm $1 (managed) <<<"; }

remove_ssh_config_block() {
    local ip="$1" cfg="${HOME}/.ssh/config"
    [[ -f "$cfg" ]] || return 0
    sed -i "/^$(ssh_block_begin "$ip")\$/,/^$(ssh_block_end "$ip")\$/d" "$cfg"
    sed -i -e :a -e '/^\n*$/{$d;N;ba}' "$cfg" 2>/dev/null || true
}

write_ssh_config() {
    local ip="$1" name; name="$(vm_name "$ip")"
    local cfg="${HOME}/.ssh/config"
    mkdir -p "${HOME}/.ssh"; chmod 700 "${HOME}/.ssh" 2>/dev/null || true
    touch "$cfg"; chmod 600 "$cfg" 2>/dev/null || true

    remove_ssh_config_block "$ip"
    {
        ssh_block_begin "$ip"
        echo "Host ${name} $(vm_dns "$ip") ${ip}"
        echo "    HostName ${ip}"
        echo "    User ${SSH_USER}"
        echo "    IdentityFile ${KEY}"
        echo "    IdentitiesOnly yes"
        echo "    UserKnownHostsFile ${KNOWN_HOSTS}"
        echo "    StrictHostKeyChecking accept-new"
        echo "    LogLevel ERROR"
        ssh_block_end "$ip"
    } >> "$cfg"

    local hostkey; hostkey="$(docker exec "$name" cat /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null | awk '{print $1, $2}')"
    touch "$KNOWN_HOSTS"; chmod 600 "$KNOWN_HOSTS"
    remove_known_hosts "$ip"
    if [[ -n "$hostkey" ]]; then
        printf '%s %s\n' "$name" "$hostkey"           >> "$KNOWN_HOSTS"
        printf '%s %s\n' "$(vm_dns "$ip")" "$hostkey" >> "$KNOWN_HOSTS"
        printf '%s %s\n' "$ip" "$hostkey"             >> "$KNOWN_HOSTS"
    fi
}

remove_known_hosts() {
    local ip="$1"
    [[ -f "$KNOWN_HOSTS" ]] || return 0
    ssh-keygen -R "$(vm_name "$ip")" -f "$KNOWN_HOSTS" >/dev/null 2>&1 || true
    ssh-keygen -R "$(vm_dns "$ip")"  -f "$KNOWN_HOSTS" >/dev/null 2>&1 || true
    ssh-keygen -R "$ip"              -f "$KNOWN_HOSTS" >/dev/null 2>&1 || true
}

# --- simulated perimeter firewall (ufw), driven over docker exec --------------
# Declarative model: the desired spec (default policy + open/close port sets) is
# stored in the VM and every change resets ufw and reapplies from scratch, so
# port reachability is unambiguous (no dependence on ufw rule ordering). Under
# default-deny the open set becomes the only allow rules (closed = blocked by
# default); under default-allow the close set becomes the only deny rules. All
# ops run via docker exec — never SSH — and 22/tcp is always kept open.

_fw_ports() { echo "${1:-}" | tr ',' ' ' | xargs 2>/dev/null; }
_set_add()  { echo "${1:-} ${2:-}" | tr ' ' '\n' | grep -v '^$' | sort -u | xargs 2>/dev/null; }
_set_del()  { local out="" t; for t in ${1:-}; do case " ${2:-} " in *" $t "*) ;; *) out+="$t ";; esac; done; echo $out; }

_fw_load() {   # -> FW_DEF / FW_O / FW_C (defaults if no spec stored yet)
    FW_DEF="deny"; FW_O=""; FW_C=""
    local k v
    while IFS='=' read -r k v; do
        case "$k" in default) FW_DEF="${v:-deny}";; open) FW_O="$v";; close) FW_C="$v";; esac
    done < <(docker exec "$1" cat "$FW_CONF" 2>/dev/null || true)
}

fw_apply() {   # $1 name  $2 default  $3 open  $4 close
    local name="$1" def="$2" open close; open="$(_fw_ports "${3:-}")"; close="$(_fw_ports "${4:-}")"
    [[ "$def" == "allow" ]] || def="deny"
    local s="ufw --force reset >/dev/null; ufw default allow outgoing >/dev/null; "
    s+="ufw default ${def} incoming >/dev/null; ufw allow 22/tcp >/dev/null; "
    local p
    if [[ "$def" == "allow" ]]; then
        for p in $close; do [[ "$p" == "22" || "$p" == "22/tcp" ]] && continue; s+="ufw deny ${p} >/dev/null; "; done
    else
        for p in $open; do s+="ufw allow ${p} >/dev/null; "; done
    fi
    s+="ufw --force enable >/dev/null; mkdir -p $(dirname "$FW_CONF"); "
    s+="printf 'default=%s\nopen=%s\nclose=%s\n' '${def}' '${open}' '${close}' > ${FW_CONF}"
    docker exec "$name" bash -c "$s"
}

fw_open() {
    local name="$1" ports; ports="$(_fw_ports "$2")"
    _fw_load "$name"
    fw_apply "$name" "$FW_DEF" "$(_set_add "$FW_O" "$ports")" "$(_set_del "$FW_C" "$ports")"
}

fw_close() {
    local name="$1" ports p filtered=""; ports="$(_fw_ports "$2")"
    for p in $ports; do
        [[ "$p" == "22" || "$p" == "22/tcp" ]] && { err "refusing to close SSH port $p"; continue; }
        filtered+="$p "
    done
    _fw_load "$name"
    fw_apply "$name" "$FW_DEF" "$(_set_del "$FW_O" "$filtered")" "$(_set_add "$FW_C" "$filtered")"
}

fw_default() { local name="$1" def="$2"; _fw_load "$name"; fw_apply "$name" "$def" "$FW_O" "$FW_C"; }
fw_disable() { docker exec "$1" bash -c "ufw --force reset >/dev/null; ufw --force disable >/dev/null; rm -f ${FW_CONF}"; }
fw_status()  { docker exec "$1" ufw status verbose 2>/dev/null; }

# ==============================================================================
# Commands
# ==============================================================================

cmd_start() {
    local runtime_mode="auto" want_ip="" verify="" fw_mode="" fw_open_l="" fw_close_l=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --runtime)     runtime_mode="${2:?}"; shift 2 ;;
            --verify)      verify="reset"; shift ;;
            --verify-keep) verify="keep"; shift ;;
            --firewall)    fw_mode="${2:?}"; shift 2 ;;
            --open)        fw_open_l="${fw_open_l} ${2:?}"; shift 2 ;;
            --close)       fw_close_l="${fw_close_l} ${2:?}"; shift 2 ;;
            -h|--help)     usage; return 0 ;;
            -*)            err "unknown start option: $1"; return 2 ;;
            *)             want_ip="$(ip_from_arg "$1")"; shift ;;
        esac
    done

    if [[ -z "$fw_mode" ]]; then
        if   [[ -n "${fw_open_l// }"  ]]; then fw_mode="deny"
        elif [[ -n "${fw_close_l// }" ]]; then fw_mode="allow"
        fi
    fi

    command -v docker >/dev/null 2>&1 || { err "docker not found"; return 1; }
    ensure_key; ensure_image; ensure_network; ensure_host_modules

    local ip; ip="${want_ip:-$(pick_free_ip)}"
    local name; name="$(vm_name "$ip")"
    if docker inspect "$name" >/dev/null 2>&1; then
        err "VM ${ip} (${name}) already exists — stop it first: $0 stop ${ip}"; return 1
    fi

    # Fresh slate: the container is gone, but its named volumes (/var/lib/rancher,
    # /var/lib/docker) may have survived if it was removed outside `fake-vm.sh stop`
    # (a host reboot, `docker rm`, `docker system prune`, …). `docker run -v name:path`
    # would silently REATTACH those old volumes, so the new VM would boot with the
    # previous deployment's k3s state — stale local-path PVCs whose MongoDB/MinIO data
    # still holds the OLD generated passwords, breaking every service that
    # authenticates against them on the redeploy. Regenerate the volumes so each start
    # is a clean machine.
    reset_vm_volumes "$name"

    local run_runtime=() runtime_desc
    case "$runtime_mode" in
        sysbox)
            has_sysbox || { err "--runtime sysbox requested but sysbox-runc is not registered with Docker"; return 1; }
            run_runtime=(--runtime=sysbox-runc); runtime_desc="sysbox-runc" ;;
        privileged)
            run_runtime=(--privileged --tmpfs /run --tmpfs /run/lock); runtime_desc="privileged" ;;
        auto)
            if has_sysbox; then run_runtime=(--runtime=sysbox-runc); runtime_desc="sysbox-runc (auto-detected)"
            else run_runtime=(--privileged --tmpfs /run --tmpfs /run/lock); runtime_desc="privileged (sysbox not available)"; fi ;;
        *) err "invalid --runtime: $runtime_mode (auto|privileged|sysbox)"; return 2 ;;
    esac

    info "starting fake-vm ${ip} (${name}) [runtime: ${runtime_desc}] ..."
    docker run -d \
        --name "$name" --hostname "$name" \
        "${run_runtime[@]}" \
        --network "$NETWORK" --ip "$ip" \
        -v "${name}-rancher:/var/lib/rancher" \
        -v "${name}-docker:/var/lib/docker" \
        "$IMAGE" >/dev/null

    for _ in $(seq 1 30); do
        vm_running "$name" && docker exec "$name" true 2>/dev/null && break || sleep 1
    done
    inject_ssh_key "$name"

    # Container registries for this network (see registry.sh): a pull-through cache of
    # Docker Hub so deploys don't re-download gigabytes, and a read-write registry for
    # locally-built images. Written BEFORE k3s or Docker exist, so containerd reads it on
    # install and dockerd on first start. Opt out with FAKE_VM_NO_REGISTRY=1.
    if [[ -z "${FAKE_VM_NO_REGISTRY:-}" ]] && [[ -x "$REGISTRY_SH" ]]; then
        "$REGISTRY_SH" up >/dev/null || err "could not start the fake-vm registries (continuing without cache)"
        "$REGISTRY_SH" write "$name" || err "could not write the registry configuration"
    fi

    # NOTE: the fake web server (fake-web.sh) needs no wiring inside the VM at all — it is
    # reached by IP or by its public openvidu-local.dev name. See fake_web_summary.

    info "waiting for SSH on ${ip}:22 ..."
    local up=""
    for _ in $(seq 1 30); do
        if ssh -i "$KEY" "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" true 2>/dev/null; then up=1; break; fi
        sleep 1
    done
    [[ -n "$up" ]] || { err "SSH did not come up on ${ip}:22"; docker logs "$name" 2>&1 | tail -20 >&2; return 1; }

    write_ssh_config "$ip"

    if [[ -n "$fw_mode" && "$fw_mode" != "off" ]]; then
        info "applying firewall (default ${fw_mode} incoming; open:${fw_open_l:- none} close:${fw_close_l:- none}; 22 always open)"
        fw_apply "$name" "$fw_mode" "$fw_open_l" "$fw_close_l"
    fi

    if [[ -n "$verify" ]]; then
        verify_k3s "$ip" "$verify" || { err "k3s verification failed"; return 1; }
    fi

    cat <<EOF

fake-vm is up.

  IP:        ${ip}
  DNS:       $(vm_dns "$ip")
  user:      ${SSH_USER} (passwordless sudo)
  SSH:       ssh ${name}          (or: ssh $(vm_dns "$ip"))
  SSH (raw): ssh -i ${KEY} ${SSH_USER}@${ip}
  HTTPS crt: $(certs_summary cert)
  HTTPS key: $(certs_summary key)
  firewall:  $0 firewall ${ip} status
  registry:  $(registry_summary)
  fake web:  $(fake_web_summary)
  stop:      $0 stop ${ip}

Install k3s on it over SSH (as on a real remote VM):
  ssh ${name} 'curl -sfL https://get.k3s.io | sudo sh -'
Install Docker (nested Docker works out of the box, and pulls go through the cache):
  ssh ${name} 'curl -fsSL https://get.docker.com | sudo sh'

$(start_certs_block "$ip")
EOF
}

# start_certs_block is the certificate section of the start banner: the flags that turn
# the two paths above into real, publicly-trusted HTTPS on this VM's name.
start_certs_block() {
    local ip="$1"
    certs_available || { certs_missing_banner; return 0; }
    cat <<EOF
Serve real HTTPS on $(vm_dns "$ip") with that wildcard certificate — e.g. paste into
\`ov stack deploy\` (or show it again with \`$0 certs ${ip}\`):

$(certs_flags "$(vm_dns "$ip")")
EOF
}

# certs_summary is the one-line form of a certificate path for the start banner
# ($1 is cert|key; only the cert line carries the expiry, to keep the block readable).
certs_summary() {
    local path="$CERT_FULLCHAIN" validity=""
    [[ "$1" == "key" ]] && path="$CERT_PRIVKEY"
    certs_available || { echo "${path}   (MISSING)"; return 0; }
    [[ "$1" == "cert" ]] && validity="$(certs_validity)"
    echo "${path}${validity:+   (${validity})}"
}

# registry_summary describes the registry wiring for the start banner.
registry_summary() {
    if [[ -n "${FAKE_VM_NO_REGISTRY:-}" ]]; then
        echo "disabled (FAKE_VM_NO_REGISTRY)"
    else
        echo "Docker Hub cached; push local images with $(basename "$REGISTRY_SH") push <image>"
    fi
}

# fake_web_summary describes the fake web server for the start banner. Nothing is
# configured inside the VM for it: it is reachable by IP, and over HTTPS on its public
# openvidu-local.dev name, from the VM and from any container or pod in it.
fake_web_summary() {
    if vm_running "fake-vm-web"; then
        echo "http://172.30.0.4/ · https://172-30-0-4.openvidu-local.dev/"
    else
        echo "not running; serve unreleased artifacts with $(basename "$FAKE_WEB_SH") up"
    fi
}

pick_free_ip() {
    local used i ip
    used="$(docker network inspect "$NETWORK" \
        -f '{{range .Containers}}{{.IPv4Address}} {{end}}' 2>/dev/null | tr -d '\n')"
    for i in $(seq "$IP_RANGE_START" "$IP_RANGE_END"); do
        ip="${IP_PREFIX}.${i}"
        [[ "$used" == *"${ip}/"* ]] && continue
        echo "$ip"; return 0
    done
    err "no free IP in ${SUBNET}"; return 1
}

verify_k3s() {
    local ip="$1" mode="$2" name; name="$(vm_name "$ip")"
    info "installing k3s inside ${name} (smoke test) ..."
    if ! ssh -i "$KEY" "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" \
        'curl -sfL https://get.k3s.io | sudo sh -' >/dev/null 2>&1; then
        err "k3s install failed (no internet inside the VM?)"; return 1
    fi
    info "waiting for the k3s node to become Ready ..."
    local ok=""
    for _ in $(seq 1 60); do
        if ssh -i "$KEY" "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" \
            'sudo k3s kubectl get nodes --no-headers 2>/dev/null | grep -qw Ready'; then ok=1; break; fi
        sleep 2
    done
    if [[ -z "$ok" ]]; then
        err "k3s node did not reach Ready"
        ssh -i "$KEY" "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" 'sudo k3s kubectl get nodes' 2>&1 | sed 's/^/    /' || true
        return 1
    fi
    ssh -i "$KEY" "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" 'sudo k3s kubectl get nodes' 2>/dev/null | sed 's/^/    /'
    info "k3s works on this VM ✔"
    if [[ "$mode" == "reset" ]]; then
        info "uninstalling k3s to leave the VM blank ..."
        ssh -i "$KEY" "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" 'sudo /usr/local/bin/k3s-uninstall.sh' >/dev/null 2>&1 || true
    fi
}

cmd_stop() {
    local all="" prune="" target=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)   all=1; shift ;;
            --prune) prune=1; shift ;;
            -h|--help) usage; return 0 ;;
            -*)      err "unknown stop option: $1"; return 2 ;;
            *)       target="$1"; shift ;;
        esac
    done

    stop_one() {
        local ip="$1" name; name="$(vm_name "$ip")"
        info "removing fake-vm ${ip} (${name}) ..."
        docker stop -t 15 "$name" >/dev/null 2>&1 || true
        docker rm -f "$name" >/dev/null 2>&1 || true
        docker volume rm $(vm_volumes "$name") >/dev/null 2>&1 || true
        remove_ssh_config_block "$ip"; remove_known_hosts "$ip"
        info "removed ${ip} and its SSH credentials"
    }

    if [[ -n "$all" ]]; then
        # IP-named containers only: the shared infrastructure on this network (registries,
        # fake web) is not a VM and is torn down by its own script, below.
        local ips; ips="$(docker ps -a --filter "name=^fake-vm-" --format '{{.Names}}' \
            | { grep -E '^fake-vm-[0-9]+-[0-9]+-[0-9]+-[0-9]+$' || true; } \
            | while read -r n; do ip_from_arg "$n"; done)"
        if [[ -z "$ips" ]]; then info "no fake-vm containers found"; else
            while read -r ip; do [[ -n "$ip" ]] && stop_one "$ip"; done <<< "$ips"
        fi
        if [[ -n "$prune" ]]; then
            # The registries and the fake web sit on this network, so they must go first.
            [[ -x "$REGISTRY_SH" ]] && "$REGISTRY_SH" down >/dev/null 2>&1 || true
            [[ -x "$FAKE_WEB_SH" ]] && "$FAKE_WEB_SH" down >/dev/null 2>&1 || true
            docker network rm "$NETWORK" >/dev/null 2>&1 && info "removed docker network $NETWORK" || true
        fi
        return 0
    fi
    [[ -n "$target" ]] || { err "specify an IP/name, or --all"; return 2; }
    stop_one "$(ip_from_arg "$target")"
}

cmd_firewall() {
    [[ $# -ge 2 ]] || { err "usage: $0 firewall <IP> <status|open|close|default|reset|off> [ports]"; return 2; }
    local ip; ip="$(ip_from_arg "$1")"; shift
    local action="$1"; shift || true
    local name; name="$(vm_name "$ip")"
    vm_running "$name" || { err "fake-vm ${ip} (${name}) is not running"; return 1; }

    case "$action" in
        status)  fw_status "$name" ;;
        open)    [[ $# -ge 1 ]] || { err "open needs a port list"; return 2; }
                 fw_open  "$name" "$*"; info "opened: $*"; fw_status "$name" ;;
        close)   [[ $# -ge 1 ]] || { err "close needs a port list"; return 2; }
                 fw_close "$name" "$*"; info "closed: $*"; fw_status "$name" ;;
        default) case "${1:-}" in
                     deny|allow) fw_default "$name" "$1"; info "default incoming: $1"; fw_status "$name" ;;
                     *) err "default needs 'deny' or 'allow'"; return 2 ;;
                 esac ;;
        reset)   fw_apply "$name" deny "" ""; info "firewall reset (default-deny, only 22 open)"; fw_status "$name" ;;
        off)     fw_disable "$name"; info "firewall disabled"; fw_status "$name" ;;
        *)       err "unknown firewall action: $action"; return 2 ;;
    esac
}

cmd_ssh() {
    [[ $# -ge 1 ]] || { err "usage: $0 ssh <IP|name> [cmd...]"; return 2; }
    local ip; ip="$(ip_from_arg "$1")"; shift
    ssh -i "$KEY" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$KNOWN_HOSTS" \
        -o LogLevel=ERROR "${SSH_USER}@${ip}" "$@"
}

# cmd_certs prints the bundled HTTPS certificate paths, ready to copy-paste. With no
# argument it fills the domain in from the only running VM (if there is exactly one),
# so the common case needs no typing at all.
cmd_certs() {
    local ip=""
    case "${1:-}" in
        -h|--help) usage; return 0 ;;
        "")        ip="$(only_running_vm_ip)" ;;
        *)         ip="$(ip_from_arg "$1")" ;;
    esac
    certs_banner "$ip"
}

# only_running_vm_ip echoes the IP of the single running fake-vm, or nothing when there
# is none or more than one.
only_running_vm_ip() {
    local names; names="$(docker ps --filter "name=^fake-vm-" --format '{{.Names}}' 2>/dev/null \
        | { grep -E '^fake-vm-[0-9]+-[0-9]+-[0-9]+-[0-9]+$' || true; })"
    [[ "$(echo "$names" | grep -c .)" == "1" ]] || return 0
    ip_from_arg "$names"
}

cmd_list() {
    # IP-named containers only: the shared infrastructure on this network (the registries,
    # the fake web server) is not a VM, so it does not belong in this listing.
    local names; names="$(docker ps --filter "name=^fake-vm-" --format '{{.Names}}' \
        | { grep -E '^fake-vm-[0-9]+-[0-9]+-[0-9]+-[0-9]+$' || true; } | sort -V)"
    if [[ -z "$names" ]]; then echo "no running fake-vms"; return 0; fi
    printf "%-16s %-30s %-10s %s\n" "IP" "DNS" "RUNTIME" "STATUS"
    local n ip st fw
    while read -r n; do
        [[ -z "$n" ]] && continue
        ip="$(container_ip "$n")"
        st="$(docker inspect -f '{{.State.Status}}' "$n" 2>/dev/null)"
        docker exec "$n" ufw status 2>/dev/null | grep -q "Status: active" && fw="fw:on" || fw="fw:off"
        printf "%-16s %-30s %-10s %s\n" "$ip" "$(vm_dns "$ip")" "$st" "$fw"
    done <<< "$names"
}

# ==============================================================================
# Dispatch
# ==============================================================================

main() {
    local cmd="${1:-help}"; shift || true
    case "$cmd" in
        start)         cmd_start "$@" ;;
        stop)          cmd_stop "$@" ;;
        firewall|fw)   cmd_firewall "$@" ;;
        ssh)           cmd_ssh "$@" ;;
        certs|cert)    cmd_certs "$@" ;;
        list|ls)       cmd_list "$@" ;;
        help|-h|--help) usage ;;
        *) err "unknown command: $cmd"; echo; usage >&2; exit 2 ;;
    esac
}

main "$@"
