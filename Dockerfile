# Simulated "remote VM" for local development.
#
# A blank Ubuntu 24.04 machine with systemd (PID 1) and an SSH server — the same
# surface a real remote host offers. It ships NO k3s: the prerequisites for k3s
# (and its bundled containerd) to run are baked in, but k3s itself is installed
# over SSH afterwards, exactly like you would on a real VM.
#
# It is meant to run with `--privileged` (or `--runtime=sysbox-runc` when that
# runtime is available); see fake-vm.sh. k3s + containerd then run inside it.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# python3-minimal is here because every real cloud image has python3 (cloud-init is
# written in it) while the ubuntu CONTAINER base image does not. Without it this VM
# would misrepresent a real node for anything that runs a python one-liner on the
# host (a port listener, a small probe…): a tool with a python path plus a fallback
# would only ever exercise the fallback here. Hide it deliberately to test that
# fallback: `mv /usr/bin/python3 /usr/bin/python3.hidden`.
RUN apt-get update && apt-get install -y --no-install-recommends \
        systemd systemd-sysv \
        openssh-server \
        sudo curl ca-certificates gnupg \
        iproute2 iptables ufw iputils-ping net-tools kmod \
        python3-minimal \
        vim less \
    && rm -rf /var/lib/apt/lists/*

# kubelet reads /dev/kmsg, which does not exist inside a container. Recreate it
# as a symlink to /dev/console on every boot via systemd-tmpfiles.
RUN printf 'L! /dev/kmsg - - - - /dev/console\n' > /etc/tmpfiles.d/kmsg.conf

# Login user: the base image ships 'ubuntu' (uid 1000, in the sudo group), like
# a real Ubuntu cloud image. Give it passwordless sudo and an .ssh dir.
RUN echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-ubuntu \
    && chmod 440 /etc/sudoers.d/90-ubuntu \
    && install -d -m 700 -o ubuntu -g ubuntu /home/ubuntu/.ssh

# SSH: key-only login as 'ubuntu' (fake-vm.sh injects the public key at runtime);
# root login and password auth disabled, as on a real cloud VM.
RUN mkdir -p /run/sshd \
    && sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config

# ufw is the VM's simulated perimeter firewall (fake-vm.sh firewall drives it).
# Route/forward traffic through so an enabled default-deny INPUT policy filters
# inbound port reachability without breaking k3s pod/service networking.
RUN sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

# Nested Docker (DinD): if the user installs Docker inside this VM, its data root
# /var/lib/docker is a volume on the host's real filesystem (see fake-vm.sh), and
# this config forces the classic overlay2 driver + disables the containerd image
# store — containerd's overlay snapshotter can't stack on docker's overlay, so
# without this an inner `docker run` fails with an overlay mount error.
# This is the no-registry baseline: `fake-vm.sh start` rewrites the file with the
# same two keys PLUS the registry mirrors (registry.sh docker-config), unless
# FAKE_VM_NO_REGISTRY=1. Keep both copies of these keys in sync.
RUN mkdir -p /etc/docker \
    && printf '{\n  "features": { "containerd-snapshotter": false },\n  "storage-driver": "overlay2"\n}\n' > /etc/docker/daemon.json

# Start sshd at boot; mask units that fight a containerized PID 1. resolved is
# masked so /etc/resolv.conf stays the one Docker injects (working DNS).
RUN systemctl enable ssh \
    && systemctl mask systemd-logind.service getty.target console-getty.service \
                       systemd-resolved.service systemd-networkd.service || true

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
