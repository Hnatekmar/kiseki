#!/bin/bash
set -euo pipefail

echo "=== provisioning kiseki environment ==="

# A persistent volume mounted at /root arrives with the provisioner's mode
# (local-path gives 0777). sshd's StrictModes refuses a group- or
# world-writable home directory, and the client only sees a bare
# "Permission denied (publickey)". Normalize it before sshd starts.
chown root:root /root
chmod 755 /root

# docker-cli is only needed when the chart wired up the dind sidecar.
need_install=0
command -v sshd >/dev/null 2>&1 || need_install=1
if [ -n "${DOCKER_HOST:-}" ] && ! command -v docker >/dev/null 2>&1; then
  need_install=1
fi

if [ "$need_install" = 1 ]; then
  packages=(openssh-server zsh git rsync)
  [ -n "${DOCKER_HOST:-}" ] && packages+=(docker-cli)
  dnf5 install -y --setopt=install_weak_deps=0 "${packages[@]}"
  dnf5 clean packages || true
fi

ssh-keygen -A
mkdir -p /run/sshd /usr/share/empty.sshd

mkdir -p /root/.ssh
cp /etc/kiseki-ssh/authorized_keys /root/.ssh/authorized_keys
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys

# Wait for the dind sidecar before handing the shell to the user, so the first
# `docker build` does not race the daemon.
if [ -n "${DOCKER_HOST:-}" ]; then
  echo "=== waiting for docker daemon at $DOCKER_HOST ==="
  for _ in $(seq 1 60); do
    docker info >/dev/null 2>&1 && break
    sleep 1
  done
  if ! docker info >/dev/null 2>&1; then
    echo "WARN: docker daemon is not reachable at $DOCKER_HOST" >&2
  fi

  # sshd does not pass arbitrary environment variables into sessions, so the
  # daemon address has to come from the shell startup files. ~/.zshenv covers
  # non-interactive zsh (`ssh host 'docker build'`), which is what tooling uses.
  printf 'export DOCKER_HOST=%s\n' "$DOCKER_HOST" >/etc/profile.d/10-docker-host.sh
  for rc in /root/.zshenv /root/.bashrc; do
    if ! grep -q '^export DOCKER_HOST=' "$rc" 2>/dev/null; then
      printf 'export DOCKER_HOST=%s\n' "$DOCKER_HOST" >>"$rc"
    fi
  done
fi

# Wait for the sidecar ports the chart declared. A dev container that connects
# to redis or postgres at startup would otherwise race them, and the failure
# surfaces as the app crashing rather than as a missing dependency.
if [ -n "${KISEKI_WAIT_PORTS:-}" ]; then
  echo "=== waiting for sidecar ports: $KISEKI_WAIT_PORTS ==="
  for port in $KISEKI_WAIT_PORTS; do
    ready=0
    for _ in $(seq 1 120); do
      if (echo >/dev/tcp/127.0.0.1/"$port") >/dev/null 2>&1; then
        ready=1
        break
      fi
      sleep 1
    done
    if [ "$ready" -eq 1 ]; then
      echo "--- port $port is accepting connections"
    else
      echo "WARN: sidecar port $port did not open within 120s" >&2
    fi
  done
fi

mkdir -p /workdir
# Re-running on a restarted pod with persistent storage must not fail on an
# existing clone, so update in place instead of cloning unconditionally.
if [ -d /workdir/dots/.git ]; then
  git -C /workdir/dots pull --ff-only || true
else
  rm -rf /workdir/dots
  git clone --depth 1 https://github.com/Hnatekmar/dots.git /workdir/dots
fi
cd /workdir/dots
bash bootstrap.sh

echo "=== provisioning complete, starting sshd ==="
exec /usr/sbin/sshd -D -e
