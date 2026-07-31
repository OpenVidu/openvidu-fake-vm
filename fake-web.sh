#!/usr/bin/env bash
#
# fake-web.sh — a local web server for the fake-vm network, to test downloads.
#
# Serves a directory of artifacts to the VMs (and to the host) over HTTP and HTTPS, so
# instructions that download a file can be tested with UNRELEASED artifacts, with nothing
# published on the Internet:
#
#   fake-vm-web (172.30.0.4)   caddy, plain file server, no host port published. Serves
#                              `www/` (override with FAKE_WEB_ROOT) on :80 and :443.
#
# Two URLs, both usable with ZERO setup from a VM, from a container inside a VM, from a
# pod, and from the host:
#
#   http://172.30.0.4/<path>                        plain HTTP, nothing to trust
#   https://172-30-0-4.openvidu-local.dev/<path>    HTTPS with the bundled PUBLICLY
#                                                   trusted wildcard certificate for
#                                                   *.openvidu-local.dev (see README)
#
# It deliberately does NOT impersonate real hostnames (no /etc/hosts or DNS tricks) and
# installs no CA anywhere: a nested container or a pod would trust neither, and rewiring
# every trust store is not worth it. Whatever you are testing must take the download URL
# as CONFIGURATION — then you point that configuration here.
#
# Usage:
#   ./fake-web.sh up                          # start/refresh (idempotent)
#   ./fake-web.sh publish <file> [<url-path>] # copy an artifact in; print URLs
#   ./fake-web.sh logs [-f]                   # what was downloaded, and by whom
#   ./fake-web.sh status
#   ./fake-web.sh down [--prune]              # stop (--prune also deletes www)
#
# Env: FAKE_WEB_ROOT=<dir>  document root (default ./www, next to this script)
#      FAKE_WEB_IMAGE       server image (default caddy:2-alpine)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NETWORK="fake-vm"
WEB_NAME="fake-vm-web"
WEB_IP="172.30.0.4"
WEB_IMAGE="${FAKE_WEB_IMAGE:-caddy:2-alpine}"
WEB_ROOT="${FAKE_WEB_ROOT:-${SCRIPT_DIR}/www}"
STATE_DIR="${SCRIPT_DIR}/.cache/fake-web"
CADDYFILE="${STATE_DIR}/Caddyfile"

# The bundled publicly-trusted wildcard for *.openvidu-local.dev, and the name it covers
# for this IP (that public DNS alias resolves a-b-c-d.openvidu-local.dev → a.b.c.d).
LOCAL_FULLCHAIN="${SCRIPT_DIR}/fullchain.pem"
LOCAL_PRIVKEY="${SCRIPT_DIR}/privkey.pem"
LOCAL_NAME="${WEB_IP//./-}.openvidu-local.dev"

err()  { echo "ERROR: $*" >&2; }
info() { echo ">>> $*"; }

running() { [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]; }
exists()  { docker inspect "$1" >/dev/null 2>&1; }

# https_available is false when the bundled certificate is missing (it is a real
# Let's Encrypt certificate and does expire) — the server then serves HTTP only.
https_available() { [[ -f "$LOCAL_FULLCHAIN" && -f "$LOCAL_PRIVKEY" ]]; }

# auto_https is off: no ACME and no HTTP→HTTPS redirect (whatever you are testing may use
# either scheme). HTTPS is served ONLY on the publicly-trusted name, which is the whole
# point — every client already trusts it, so there is no CA to install anywhere.
write_caddyfile() {
    mkdir -p "$STATE_DIR"
    cat > "$CADDYFILE" <<EOF
{
	admin off
	auto_https off
	log {
		output stdout
		format console
	}
}

(artifacts) {
	root * /srv
	file_server browse
	# Access log trimmed to what matters when debugging a download: who asked for what,
	# and what they got. Tail it with: fake-web.sh logs -f
	log {
		format filter {
			wrap console
			fields {
				request>headers delete
				request>tls delete
				resp_headers delete
			}
		}
	}
}

:80 {
	import artifacts
}
EOF
    if https_available; then
        cat >> "$CADDYFILE" <<EOF

${LOCAL_NAME}:443 {
	tls /certs/local-fullchain.pem /certs/local-privkey.pem
	import artifacts
}
EOF
    fi
}

cmd_up() {
    command -v docker >/dev/null 2>&1 || { err "docker not found"; return 1; }
    docker network inspect "$NETWORK" >/dev/null 2>&1 || {
        err "docker network '${NETWORK}' does not exist yet — run: $(dirname "$0")/fake-vm.sh start"; return 1; }
    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { main --help; return 0; }
    [[ $# -eq 0 ]] || { err "unknown up option: $1"; return 2; }

    mkdir -p "$STATE_DIR" "$WEB_ROOT"
    https_available || err "no ${LOCAL_FULLCHAIN##*/}/${LOCAL_PRIVKEY##*/} — serving HTTP only"
    write_caddyfile

    # Recreated on every `up`: the container is stateless (the document root is a bind
    # mount), so this is the simplest way to pick up a configuration change.
    exists "$WEB_NAME" && docker rm -f "$WEB_NAME" >/dev/null
    info "launching ${WEB_NAME} on ${WEB_IP} (root: ${WEB_ROOT})"
    local certs=()
    if https_available; then
        certs=(-v "${LOCAL_FULLCHAIN}:/certs/local-fullchain.pem:ro"
               -v "${LOCAL_PRIVKEY}:/certs/local-privkey.pem:ro")
    fi
    docker run -d --name "$WEB_NAME" --restart unless-stopped \
        --network "$NETWORK" --ip "$WEB_IP" \
        -v "${WEB_ROOT}:/srv:ro" \
        -v "${CADDYFILE}:/etc/caddy/Caddyfile:ro" \
        ${certs[@]+"${certs[@]}"} \
        "$WEB_IMAGE" >/dev/null
    cmd_status
}

# cmd_publish copies an artifact in under a URL path of your choosing, so a released
# layout can be reproduced verbatim (e.g. community/singlenode/<version>/install.sh).
cmd_publish() {
    local file="${1:?usage: fake-web.sh publish <file> [<url-path>]}"
    [[ -f "$file" ]] || { err "no such file: ${file}"; return 1; }
    local path="${2:-$(basename "$file")}"
    path="${path#/}"
    local dest="${WEB_ROOT}/${path}"
    mkdir -p "$(dirname "$dest")"
    cp "$file" "$dest"
    chmod 644 "$dest"
    info "published ${file} → ${path}"
    echo
    echo "point the download URL under test at:"
    echo "  http://${WEB_IP}/${path}"
    https_available && echo "  https://${LOCAL_NAME}/${path}"
    echo
    echo "both work as-is from a VM, from a container inside a VM, from a pod and from"
    echo "the host — no CA and no /etc/hosts entry needed."
}

# cmd_logs tails the access log — the record of what was actually downloaded.
cmd_logs() {
    running "$WEB_NAME" || { err "${WEB_NAME} is not running"; return 1; }
    if [[ "${1:-}" == "-f" || "${1:-}" == "--follow" ]]; then
        docker logs -f --tail 50 "$WEB_NAME"
    else
        docker logs --tail "${1:-50}" "$WEB_NAME"
    fi
}

cmd_status() {
    # `docker inspect -f` prints an empty line before failing, so ask first.
    local st="not created"
    exists "$WEB_NAME" && st="$(docker inspect -f '{{.State.Status}}' "$WEB_NAME")"
    printf '%-16s %-14s %s\n' NAME IP STATUS
    printf '%-16s %-14s %s\n' "$WEB_NAME" "$WEB_IP" "$st"
    echo
    echo "document root:  ${WEB_ROOT}"
    echo "HTTP URL:       http://${WEB_IP}/"
    if https_available; then
        echo "HTTPS URL:      https://${LOCAL_NAME}/   (publicly trusted certificate)"
    else
        echo "HTTPS URL:      unavailable (bundled certificate missing)"
    fi
}

cmd_down() {
    local prune=""
    [[ "${1:-}" == "--prune" ]] && prune=1
    exists "$WEB_NAME" && { info "removing ${WEB_NAME}"; docker rm -f "$WEB_NAME" >/dev/null; }
    if [[ -n "$prune" ]]; then
        local n; n="$(find "$WEB_ROOT" -type f 2>/dev/null | wc -l)"
        info "deleting ${n} published artifact(s) (${WEB_ROOT}) and ${STATE_DIR}"
        rm -rf "$WEB_ROOT" "$STATE_DIR"
    else
        info "published artifacts preserved (${WEB_ROOT}) — pass --prune to delete them"
    fi
}

main() {
    local cmd="${1:-status}"; shift || true
    case "$cmd" in
        up)      cmd_up "$@" ;;
        down)    cmd_down "$@" ;;
        status)  cmd_status "$@" ;;
        publish) cmd_publish "$@" ;;
        logs)    cmd_logs "$@" ;;
        config)  write_caddyfile && cat "$CADDYFILE" ;;
        # Print the header comment block (everything between the shebang and the first
        # line of code), so the help stays correct as that block grows.
        -h|--help|help) awk 'NR>1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}" ;;
        *)       err "unknown command: ${cmd}"; return 2 ;;
    esac
}

main "$@"
