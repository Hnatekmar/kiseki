#!/usr/bin/env bash
set -euo pipefail

# Creates, or with --delete removes, the test cluster. Use --gpu for an nvkind
# cluster.
#
# KIND_CONFIG=<file>  kind config to pass through. Needed when the docker daemon
#                     is not on localhost (a dind runner): kind would otherwise
#                     publish its API server on an address the caller cannot reach.
# KIND_DNS=<ip>       resolver to write into the nodes. Needed when the daemon's
#                     own resolver is unreachable from inside the node (dind).

CLUSTER_NAME=kiseki-test-cluster
GPU=0
DELETE=0

usage() {
  echo "Usage: $0 [--gpu] [--delete]" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --gpu) GPU=1 ;;
  --delete) DELETE=1 ;;
  "") ;;
  *) usage ;;
  esac
  shift
done

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "$1 is required" >&2
    exit 1
  }
}

require_cmd kind

# `--delete` exists so callers (CI cleanup) do not have to repeat the cluster
# name: it is owned here, and a second copy silently leaks a renamed cluster.
if [[ "$DELETE" -eq 1 ]]; then
  if kind get clusters | grep -qx "$CLUSTER_NAME"; then
    kind delete cluster --name "$CLUSTER_NAME"
  else
    echo "Cluster '$CLUSTER_NAME' does not exist"
  fi
  exit 0
fi

kind_config=()
if [[ -n "${KIND_CONFIG:-}" ]]; then
  [[ -f "$KIND_CONFIG" ]] || {
    echo "KIND_CONFIG file not found: $KIND_CONFIG" >&2
    exit 1
  }
  kind_config=(--config "$KIND_CONFIG")
fi

if [[ -n "${KIND_DNS:-}" ]]; then
  # The value is handed to a shell inside each node as an argument, but validate
  # it anyway: a bad nameserver leaves an environment that cannot resolve
  # anything, and the failure surfaces much later as an image pull error.
  [[ "$KIND_DNS" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || {
    echo "KIND_DNS must be an IPv4 address, got '$KIND_DNS'" >&2
    exit 1
  }
fi

if [[ "$GPU" -eq 1 ]]; then
  command -v nvkind >/dev/null 2>&1 || {
    echo "nvkind is required for --gpu (go install github.com/NVIDIA/nvkind/cmd/nvkind@main; add \$HOME/go/bin to PATH)" >&2
    exit 1
  }
  require_cmd kubectl
  require_cmd helm
  if [[ ${#kind_config[@]} -gt 0 ]]; then
    # nvkind builds its own kind config for the GPU runtime; silently ignoring
    # the caller's would produce a cluster whose API server it cannot reach.
    echo "KIND_CONFIG is not supported with --gpu (nvkind owns the cluster config)" >&2
    exit 1
  fi
fi

if kind get clusters | grep -qx "$CLUSTER_NAME"; then
  echo "Cluster already exists destroying it and then bringing it up"
  kind delete cluster --name "$CLUSTER_NAME"
fi

# Applied to every node, not just the control plane: nvkind's workers run the
# device plugin, and they inherit the same unusable resolver.
set_node_resolver() {
  local dns="$1" node
  [[ -n "$dns" ]] || return 0
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    docker exec "$node" sh -c 'printf "nameserver %s\n" "$1" > /etc/resolv.conf' _ "$dns"
  done < <(kind get nodes --name "$CLUSTER_NAME")
  echo "node resolver set to $dns"
}

if [[ "$GPU" -eq 1 ]]; then
  if ! nvkind cluster create --name "$CLUSTER_NAME"; then
    echo "nvkind failed. Use a recent nvkind build: go install github.com/NVIDIA/nvkind/cmd/nvkind@main" >&2
    kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
    exit 1
  fi

  # Before the device plugin is installed: its image pulls happen on the nodes.
  set_node_resolver "${KIND_DNS:-}"

  kubectl --context "kind-$CLUSTER_NAME" label node \
    -l '!node-role.kubernetes.io/control-plane' \
    nvidia.com/gpu.present=true --overwrite

  helm repo add nvdp https://nvidia.github.io/k8s-device-plugin --force-update
  helm repo update nvdp
  helm upgrade --install nvidia-device-plugin nvdp/nvidia-device-plugin \
    --kube-context "kind-$CLUSTER_NAME" \
    --namespace nvidia --create-namespace \
    --set runtimeClassName=nvidia --wait

  for _ in {1..30}; do
    kubectl --context "kind-$CLUSTER_NAME" get nodes \
      -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' |
      grep -q '[1-9]' && break
    sleep 2
  done

  kubectl --context "kind-$CLUSTER_NAME" get nodes \
    -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' |
    grep -q '[1-9]' || {
    echo "No allocatable GPUs found in cluster '$CLUSTER_NAME'" >&2
    exit 1
  }
else
  kind create cluster --name "$CLUSTER_NAME" "${kind_config[@]}"
  set_node_resolver "${KIND_DNS:-}"
fi
