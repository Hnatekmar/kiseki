#!/usr/bin/env bash
set -euo pipefail

# kiseki: spawn and destroy Kubernetes dev environments

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

source "$SCRIPT_DIR/kiseki.d/lib.sh"
source "$SCRIPT_DIR/kiseki.d/create.sh"
source "$SCRIPT_DIR/kiseki.d/manage.sh"
source "$SCRIPT_DIR/kiseki.d/proxy.sh"
source "$SCRIPT_DIR/kiseki.d/example.sh"

cmd_help() {
  cat <<'EOF'
kiseki: Kubernetes dev environment manager

Usage: kiseki <command> [options]

Commands:
  create [<name>] [options]   Create a new dev environment
  list [--json]               List all active environments
  destroy <name> [-f]         Destroy an environment
  example [--output FILE]     Print the sidecar values example, or write it
  proxy <alias>               Proxy SSH traffic (internal)
  help                        Show this help message

Create options:
  --cpu N             CPU cores (default: prompt then 4)
  --memory SIZE       Memory (default: prompt then 8Gi)
  --gpu N             Request N NVIDIA GPUs (default: 0)
  --ssh-key PATH      SSH public key path
  --context CTX       Kubernetes context
  --address HOST      Publish an Ingress for HOST; requires --port
  --port PORT         Container port the app listens on; requires --address
  --container SPEC    Sidecar in the pod, repeatable:
                      name=IMAGE[:TAG][,port=N][,env=KEY=VALUE]
  --docker            Add a docker:dind sidecar and set DOCKER_HOST
  --persistence       Persist /root on a PVC (default 10Gi)
  --persistence-size SIZE
                      PVC size, implies --persistence (e.g. 20Gi)
  --storage-class CLASS
                      StorageClass for the PVC, implies --persistence
  --set KEY=VALUE     Helm value override, repeatable (e.g. image.tag=43)
  -f, --values FILE   Helm values file, repeatable
  --json              Print one JSON object on stdout, progress on stderr
  --no-check          Skip SSH connectivity check

Destroy options:
  -f                  Force destroy without confirmation

Examples:
  kiseki create my-env --cpu 2 --memory 4Gi
  kiseki create web --address app.dev-k8s.srv.example.com --port 3000
  kiseki create api --container redis=redis:7-alpine,port=6379 --container pg=postgres:17
  kiseki example > extraSVC.yaml      # sidecars with volumes and an init container
  kiseki create api -f extraSVC.yaml
  kiseki create build --docker --persistence --set storage.size=20Gi
  kiseki list --json
  kiseki destroy my-env -f
EOF
}

# ---- main ----

main() {
  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
  create) cmd_create "$@" ;;
  list) cmd_list "$@" ;;
  destroy) cmd_destroy "$@" ;;
  example) cmd_example "$@" ;;
  proxy) cmd_proxy "$@" ;;
  help | -h | --help) cmd_help ;;
  *)
    err "Unknown command: $cmd"
    cmd_help
    exit 1
    ;;
  esac
}

main "$@"
