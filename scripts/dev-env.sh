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
  list                        List all active environments
  destroy <name> [-f]         Destroy an environment
  proxy <alias>               Proxy SSH traffic (internal)
  help                        Show this help message

Create options:
  --cpu N             CPU cores (default: prompt then 4)
  --memory SIZE       Memory (default: prompt then 8Gi)
  --ssh-key PATH      SSH public key path
  --context CTX       Kubernetes context
  --persistence       Enable persistent volume (default 1Gi)
  --set KEY=VALUE     Helm value override, repeatable (e.g. image.tag=43)
  -f, --values FILE   Helm values file, repeatable
  --no-check          Skip SSH connectivity check

Destroy options:
  -f                  Force destroy without confirmation

Examples:
  dev-env create my-env --cpu 2 --memory 4Gi
  dev-env create my-env --persistence --set storage.size=5Gi
  dev-env list
  dev-env destroy my-env
  dev-env destroy my-env -f
  dev-env proxy k8s-dev-my-env
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
  help) cmd_help ;;
  *)
    err "Unknown command: $cmd"
    cmd_help
    exit 1
    ;;
  esac
}

main "$@"
