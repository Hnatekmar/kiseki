# dev-env: list and destroy subcommands (sourced by dev-env.sh)

cmd_list() {
  require_cmd kubectl

  if [[ ! -d "$STATE_ROOT" ]]; then
    echo "No environments found."
    return 0
  fi

  printf '%-20s %-25s %-10s %-20s %s\n' "NAME" "CONTEXT" "PORT" "NAMESPACE" "PHASE"
  printf '%s\n' "$(printf '%.0s-' {1..90})"

  for dir in "$STATE_ROOT"/*/; do
    [[ -d "$dir" ]] || continue
    local name port ns ctx
    name="$(basename "$dir")"
    port="$(cat "$dir/port")"
    ctx="$(cat "$dir/context")"
    ns="dev-$name"

    local phase="unreachable"
    if pods="$(kubectl --context "$ctx" get pods -l "app.kubernetes.io/instance=$ns" -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}={.status.phase}{"\n"}{end}' 2>/dev/null)"; then
      if [[ -n "$pods" ]]; then
        phase="$(echo "$pods" | head -1 | cut -d= -f2)"
      else
        phase="no pods"
      fi
    fi

    printf '%-20s %-25s %-10s %-20s %s\n' "$name" "$ctx" "$port" "$ns" "$phase"
  done
}

cmd_destroy() {
  require_cmd kubectl
  require_cmd helm

  local name=""
  local force=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
    -f)
      force=1
      shift
      ;;
    -*) die "Unknown flag: $1" ;;
    *)
      if [[ -n "$name" ]]; then
        die "Multiple names specified"
      fi
      name="$1"
      shift
      ;;
    esac
  done

  if [[ -z "$name" ]]; then
    die "Name is required"
  fi

  local dir="$STATE_ROOT/$name"
  local ns="dev-$name"
  local ctx=""

  if [[ -d "$dir" ]]; then
    ctx="$(cat "$dir/context")"
  else
    ctx="$(kubectl config current-context 2>/dev/null || true)"
  fi
  if [[ -z "$ctx" ]]; then
    die "No context available (state missing and no current context)"
  fi

  # check existence
  local state_exists=0 helm_exists=0
  [[ -d "$dir" ]] && state_exists=1
  helm --kube-context "$ctx" status "$ns" -n "$ns" >/dev/null 2>&1 && helm_exists=1

  if [[ "$state_exists" -eq 0 && "$helm_exists" -eq 0 ]]; then
    die "Environment '$name' not found (no state directory, no helm release)"
  fi

  # confirm
  if [[ "$force" -eq 0 ]]; then
    if [[ ! -t 0 ]]; then
      die "Confirmation required. Use -f to force or run interactively"
    fi
    printf 'Destroy %s (namespace, release, ssh entry, state)? [y/N]: ' "$ns"
    read -r ans
    case "$ans" in
    [yY][eE][sS] | [yY]) ;;
    *)
      echo "Cancelled"
      exit 0
      ;;
    esac
  fi

  # kill forward
  if [[ -d "$dir" && -f "$dir/pid" ]]; then
    local fw_pid
    fw_pid="$(cat "$dir/pid")"
    if [[ -n "$fw_pid" ]] && kill -0 "$fw_pid" 2>/dev/null; then
      kill "$fw_pid" 2>/dev/null || true
      wait "$fw_pid" 2>/dev/null || true
    fi
  fi

  # helm uninstall
  helm --kube-context "$ctx" uninstall "$ns" -n "$ns" 2>/dev/null || true

  # delete namespace
  kubectl --context "$ctx" delete namespace "$ns" --ignore-not-found --timeout=120s 2>/dev/null || true

  # ssh block
  if [[ -f "$MANAGED_SSH" ]]; then
    remove_ssh_block "$name"
  fi

  # state dir
  if [[ -d "$dir" ]]; then
    rm -rf "$dir"
  fi

  echo "Environment '$name' destroyed."
}
