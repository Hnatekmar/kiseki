#!/bin/bash
set -euo pipefail

echo "=== provisioning dev environment ==="

if ! command -v sshd >/dev/null 2>&1; then
  dnf5 install -y --setopt=install_weak_deps=0 openssh-server zsh
  dnf5 clean packages || true
fi

ssh-keygen -A
mkdir -p /run/sshd /usr/share/empty.sshd

mkdir -p /root/.ssh
cp /etc/dev-ssh/authorized_keys /root/.ssh/authorized_keys
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys

echo "=== provisioning complete, starting sshd ==="
exec /usr/sbin/sshd -D -e