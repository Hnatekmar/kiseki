#!/usr/bin/env bash
set -euo pipefail

# GPU smoke test. Creates an nvkind cluster, checks nvidia-smi over SSH, and cleans up.

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
NAME=gpu-test
CTX=kind-dev-envs-test-cluster

"$SCRIPT_DIR/create-cluster.sh" --gpu

cleanup() {
  "$SCRIPT_DIR/dev-env.sh" destroy "$NAME" -f >/dev/null 2>&1 || {
    helm --kube-context "$CTX" uninstall "dev-$NAME" -n "dev-$NAME" >/dev/null 2>&1 || true
    kubectl --context "$CTX" delete namespace "dev-$NAME" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  }
}
trap cleanup EXIT

"$SCRIPT_DIR/dev-env.sh" create "$NAME" --gpu 1 --cpu 1 --memory 1Gi \
  --ssh-key "$HOME/.ssh/id_ed25519.pub" --context "$CTX"

ssh -o BatchMode=yes -o ConnectTimeout=15 "k8s-dev-$NAME" 'nvidia-smi -L'
