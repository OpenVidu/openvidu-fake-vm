#!/usr/bin/env bash
#
# Install sysbox-ce on a GitHub-hosted ubuntu runner and confirm dockerd registers the
# sysbox-runc runtime. sysbox is NOT preinstalled on hosted runners.
#
# Note: sysbox on hosted runners is best-effort — it needs recent-kernel features (idmapped
# mounts / shiftfs). The e2e "sysbox" matrix leg is kept non-blocking for that reason.
# Override the version with SYSBOX_VER; releases: https://github.com/nestybox/sysbox/releases
set -euxo pipefail

ver="${SYSBOX_VER:-}"
if [[ -z "$ver" ]]; then
    ver="$(curl -fsSL https://api.github.com/repos/nestybox/sysbox/releases/latest \
        | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -1)"
fi
[[ -n "$ver" ]] || { echo "could not determine sysbox version; set SYSBOX_VER" >&2; exit 1; }

deb="sysbox-ce_${ver}-0.linux_amd64.deb"

# sysbox refuses to install while containers exist; the runner may have some.
docker rm -f "$(docker ps -aq)" 2>/dev/null || true

wget -q "https://downloads.nestybox.com/sysbox/releases/v${ver}/${deb}"
sudo apt-get update
sudo apt-get install -y "./${deb}"

# The package registers sysbox-runc with dockerd and restarts it; make sure it is back.
sudo systemctl restart docker || true
for _ in $(seq 1 20); do
    docker info >/dev/null 2>&1 && break
    sleep 2
done

docker info --format '{{range .Runtimes}}{{println .}}{{end}}' | grep -qw sysbox-runc
echo "sysbox-runc registered (v${ver}); waiting for it to become ready ..."

# The runtime shows up in `docker info` before sysbox-mgr/sysbox-fs are actually ready to
# launch a container (especially right after the docker restart). Warm up: pull a tiny image
# and launch a throwaway sysbox container until it succeeds, so the tests never race sysbox.
docker pull -q alpine:latest >/dev/null 2>&1 || true
for _ in $(seq 1 40); do
    if docker run --rm --runtime=sysbox-runc alpine:latest true >/dev/null 2>&1; then
        echo "sysbox is ready."
        exit 0
    fi
    sleep 3
done
echo "sysbox-runc is registered but a warmup container never launched" >&2
exit 1
