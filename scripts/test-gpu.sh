#!/usr/bin/env bash
set -euo pipefail

# GPU smoke test. Creates an nvkind cluster, checks nvidia-smi over SSH, and cleans up.

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
NAME=gpu-test
CTX=kind-kiseki-test-cluster

"$SCRIPT_DIR/create-cluster.sh" --gpu

cleanup() {
  "$SCRIPT_DIR/kiseki.sh" destroy "$NAME" -f >/dev/null 2>&1 || {
    helm --kube-context "$CTX" uninstall "kiseki-$NAME" -n "kiseki-$NAME" >/dev/null 2>&1 || true
    kubectl --context "$CTX" delete namespace "kiseki-$NAME" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  }
}
trap cleanup EXIT

"$SCRIPT_DIR/kiseki.sh" create "$NAME" --gpu 1 --cpu 1 --memory 1Gi \
  --ssh-key "$HOME/.ssh/id_ed25519.pub" --context "$CTX"

ssh -o BatchMode=yes -o ConnectTimeout=15 "kiseki-$NAME" 'nvidia-smi -L'
