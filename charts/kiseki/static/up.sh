#!/bin/bash
set -euo pipefail

echo "=== provisioning kiseki environment ==="

# A persistent volume mounted at /root arrives with the provisioner's mode
# (local-path gives 0777). sshd's StrictModes refuses a group- or
# world-writable home directory, and the client only sees a bare
# "Permission denied (publickey)". Normalize it before sshd starts.
chown root:root /root
chmod 755 /root

if [ -f /etc/kiseki-image ]; then
  echo "=== image: $(cat /etc/kiseki-image)"
fi

# docker-cli is only needed when the chart wired up the dind sidecar. git is
# needed to clone the dots checkout; on the kiseki base image everything is
# already present and this whole block is skipped, which keeps pod start off the
# Fedora mirrors.
need_install=0
command -v sshd >/dev/null 2>&1 || need_install=1
command -v git >/dev/null 2>&1 || need_install=1
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
# The dotfiles checkout is optional (chart value dots.enabled): its installer is
# the slowest part of a first start and needs more than the pod's memory limits
# on a small environment. Without it the pod is a plain Fedora shell, which is
# what the smoke test needs.
if [ -n "${KISEKI_DOTS_REPO:-}" ]; then
  # Bound every git fetch in this shell and below. A blackholed GitHub edge does
  # not fail: it dribbles (measured at ~1MB/min on hermes-agent) and the pod then
  # never reaches sshd. With these, git aborts after 30s below 1KB/s and the
  # failure is visible in the log instead. GIT_TERMINAL_PROMPT=0 stops a clone
  # that wants credentials from waiting on a prompt no one can answer.
  export GIT_TERMINAL_PROMPT=0
  export GIT_HTTP_LOW_SPEED_LIMIT="${GIT_HTTP_LOW_SPEED_LIMIT:-1000}"
  export GIT_HTTP_LOW_SPEED_TIME="${GIT_HTTP_LOW_SPEED_TIME:-30}"

  # Re-running on a restarted pod with persistent storage must not fail on an
  # existing clone, so update in place instead of cloning unconditionally.
  if [ -d /workdir/dots/.git ]; then
    git -C /workdir/dots pull --ff-only || true
  else
    rm -rf /workdir/dots
    git clone --depth 1 "$KISEKI_DOTS_REPO" /workdir/dots
  fi
  cd /workdir/dots
  # dots.repo is configurable, so the checkout may have no installer. Dying here
  # would restart the container forever and leave no way to log in and look.
  if [ -f bootstrap.sh ]; then
    if [ -n "${DOTS_CACHE_DIR:-}" ]; then
      echo "=== dots download cache: $DOTS_CACHE_DIR"
    fi
    # Wall-clock cap. The bootstrap is idempotent, so a timeout costs nothing but
    # a second run; what it buys is a reachable environment, because sshd only
    # starts after this returns. A hard failure keeps the old behaviour (abort
    # and let the container restart) so a broken base image still fails loudly.
    #
    # 0 means "no cap" (coreutils treats it that way), so only non-numeric values
    # are corrected: `timeout abc` exits 125 and would restart-loop the pod,
    # which is the failure this block exists to remove.
    timeout_s="${KISEKI_DOTS_TIMEOUT:-1200}"
    if ! [[ "$timeout_s" =~ ^[0-9]+$ ]]; then
      echo "WARN: KISEKI_DOTS_TIMEOUT='$timeout_s' is not a number, using 1200" >&2
      timeout_s=1200
    fi
    bootstrap_rc=0
    timeout -k 30 "$timeout_s" bash bootstrap.sh || bootstrap_rc=$?
    if [ "$bootstrap_rc" = 124 ]; then
      echo "WARN: dotfiles bootstrap exceeded ${timeout_s}s and was killed; starting sshd anyway." >&2
      echo "WARN: re-run /workdir/dots/bootstrap.sh inside the environment to resume (it is idempotent)." >&2
      # A killed bootstrap can leave children holding the network. They are not
      # waited on; the environment is usable and the next run re-checks versions.
    elif [ "$bootstrap_rc" = 137 ]; then
      # 128+SIGKILL: either `timeout -k` after the cap, or the OOM killer. Both
      # leave an environment worth logging into, so start sshd but say which.
      echo "WARN: dotfiles bootstrap was SIGKILLed (timeout -k or OOM), not a clean timeout; starting sshd anyway." >&2
      echo "WARN: re-run /workdir/dots/bootstrap.sh inside the environment to resume (it is idempotent)." >&2
    elif [ "$bootstrap_rc" != 0 ]; then
      echo "ERROR: dotfiles bootstrap exited $bootstrap_rc" >&2
      exit "$bootstrap_rc"
    fi
  else
    echo "WARN: $KISEKI_DOTS_REPO has no bootstrap.sh, skipping dotfiles install" >&2
  fi
else
  echo "=== dotfiles bootstrap disabled (dots.enabled=false) ==="
fi

echo "=== provisioning complete, starting sshd ==="
exec /usr/sbin/sshd -D -e
