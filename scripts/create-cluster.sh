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
  kind create cluster --name "$CLUSTER_NAME"
fi
