#!/usr/bin/env bash
set -euo pipefail

# Creates or recreates the test cluster. Use --gpu for an nvkind cluster.

CLUSTER_NAME=kiseki-test-cluster
GPU=0

case "${1:-}" in
--gpu) GPU=1 ;;
"") ;;
*)
  echo "Usage: $0 [--gpu]" >&2
  exit 1
  ;;
esac

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "$1 is required" >&2
    exit 1
  }
}

require_cmd kind
if [[ "$GPU" -eq 1 ]]; then
  command -v nvkind >/dev/null 2>&1 || {
    echo "nvkind is required for --gpu (go install github.com/NVIDIA/nvkind/cmd/nvkind@main; add \$HOME/go/bin to PATH)" >&2
    exit 1
  }
  require_cmd kubectl
  require_cmd helm
fi

if kind get clusters | grep -qx "$CLUSTER_NAME"; then
  echo "Cluster already exists destroying it and then bringing it up"
  kind delete cluster --name "$CLUSTER_NAME"
fi

# A kind cluster normally binds its API server to 127.0.0.1 of the docker host.
# When the daemon is not on localhost (a dind runner, a remote engine) that
# address is unreachable from the caller, so KIND_CONFIG lets the caller supply
# a networking.apiServerAddress and the matching certificate SAN.
kind_config=()
if [[ -n "${KIND_CONFIG:-}" ]]; then
  kind_config=(--config "$KIND_CONFIG")
fi

if [[ "$GPU" -eq 1 ]]; then
  if ! nvkind cluster create --name "$CLUSTER_NAME"; then
    echo "nvkind failed. Use a recent nvkind build: go install github.com/NVIDIA/nvkind/cmd/nvkind@main" >&2
    kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
    exit 1
  fi

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
fi

# kind copies the docker host's /etc/resolv.conf into the node. When the daemon
# runs inside another cluster (a dind CI runner), that resolver forwards to the
# orchestrating cluster's DNS, which lives inside kind's own service CIDR
# (10.96.0.0/16). The node's kube-proxy then intercepts those queries towards a
# service that has no endpoints, and every image pull fails with "server
# misbehaving". KIND_DNS=<ip> points the node at a resolver outside that range.
if [[ -n "${KIND_DNS:-}" ]]; then
  docker exec "$CLUSTER_NAME-control-plane" \
    sh -c "printf 'nameserver %s\n' '$KIND_DNS' > /etc/resolv.conf"
  echo "node resolver set to $KIND_DNS"
fi
