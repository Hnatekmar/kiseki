#!/usr/bin/env bash
# Install the pinned CI toolchain.
#
# Every binary is checked against a sha256 before it is used: these downloads run
# with runner privileges, so a mutable or compromised release asset must fail the
# job instead of executing. `just` publishes no checksum file, so its digest is
# the one GitHub records for the release asset; with the version pinned, that is
# a constant like any other.
#
# Usage: install-tools.sh [--docker] [--bindir DIR]
#   --docker   also install kind (needs the docker CLI, which the caller provides)
#   --bindir   where to put the binaries (default /usr/local/bin)
set -euo pipefail

KIND_VERSION=v0.33.0
KIND_SHA256=aee6151561422756b764a4ae28e7f44cda5af5a9eead3cc9985112b1de8d8e0d
KUBECTL_VERSION=v1.37.1
KUBECTL_SHA256=65691ff77eb6fa44c908b77a1082c9f092c3b9733b5cefabec0d1104890e21a8
# Major version 3 on purpose: the chart is helm-3 era and the local toolchain is
# v3, so CI should not prove a toolchain nobody runs.
HELM_VERSION=v3.22.1
HELM_SHA256=896cf63684a42a723d61c980369d6e588330927deb13676ca0d85006dd6da0ea
JUST_VERSION=1.42.4
JUST_SHA256=678efc1cfbd5fa5a88375daa7e2f3864a049d6d63a0296df925a2ae5f516cb56

with_docker=0
bindir=/usr/local/bin
while [[ $# -gt 0 ]]; do
  case "$1" in
  --docker) with_docker=1 ;;
  --bindir)
    bindir="${2:?--bindir needs a directory}"
    shift
    ;;
  *)
    echo "usage: $0 [--docker] [--bindir DIR]" >&2
    exit 1
    ;;
  esac
  shift
done
mkdir -p "$bindir"

# fetch_verified <url> <destination> <sha256>
fetch_verified() {
  local url="$1" dest="$2" want="$3" got
  curl -fsSL -o "$dest" "$url"
  got="$(sha256sum "$dest" | awk '{print $1}')"
  if [[ "$got" != "$want" ]]; then
    echo "checksum mismatch for $url" >&2
    echo "  expected $want" >&2
    echo "  got      $got" >&2
    rm -f "$dest"
    exit 1
  fi
  chmod 0755 "$dest"
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fetch_verified "https://github.com/casey/just/releases/download/${JUST_VERSION}/just-${JUST_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
  "$work/just.tgz" "$JUST_SHA256"
tar -xzf "$work/just.tgz" -C "$work" just
install -m0755 "$work/just" "$bindir/just"

fetch_verified "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
  "$bindir/kubectl" "$KUBECTL_SHA256"

fetch_verified "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
  "$work/helm.tgz" "$HELM_SHA256"
tar -xzf "$work/helm.tgz" -C "$work"
install -m0755 "$work/linux-amd64/helm" "$bindir/helm"

if [[ "$with_docker" -eq 1 ]]; then
  fetch_verified "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64" \
    "$bindir/kind" "$KIND_SHA256"
  "$bindir/kind" version
fi

# Absolute paths: the point of the log line is what was installed, not whatever
# happens to be first on PATH.
"$bindir/just" --version
"$bindir/kubectl" version --client
"$bindir/helm" version --short
