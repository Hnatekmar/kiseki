#!/usr/bin/env bash
set -euo pipefail

# dev-env: spawn and destroy Kubernetes dev environments

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

source "$SCRIPT_DIR/dev-env.d/lib.sh"
source "$SCRIPT_DIR/dev-env.d/create.sh"
source "$SCRIPT_DIR/dev-env.d/manage.sh"
source "$SCRIPT_DIR/dev-env.d/proxy.sh"

cmd_help() {
  cat <<'EOF'
dev-env: Kubernetes dev environment manager

Usage: dev-env <command> [options]

Commands:
  create [<name>] [options]   Create a new dev environment
  list [--json]               List all active environments
  destroy <name> [-f]         Destroy an environment
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
  --persistence       Enable persistent volume (default 1Gi)
  --set KEY=VALUE     Helm value override, repeatable (e.g. image.tag=43)
  -f, --values FILE   Helm values file, repeatable
  --json              Print one JSON object on stdout, progress on stderr
  --no-check          Skip SSH connectivity check

Destroy options:
  -f                  Force destroy without confirmation

Examples:
  dev-env create my-env --cpu 2 --memory 4Gi
  dev-env create web --address app.dev-k8s.srv.example.com --port 3000
  dev-env create api --container redis=redis:7-alpine,port=6379 --container pg=postgres:17
  dev-env create build --docker --persistence --set storage.size=20Gi
  dev-env list --json
  dev-env destroy my-env -f
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
