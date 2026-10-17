# dev-env: list and destroy subcommands (sourced by dev-env.sh)

# Print one word describing the environment's pod: a phase, "no pods", or
# "unreachable" when the context cannot be queried.
env_phase() {
  local ctx="$1" ns="$2" pods
  if pods="$(kubectl --context "$ctx" get pods -l "app.kubernetes.io/instance=$ns" -n "$ns" \
    -o jsonpath='{range .items[*]}{.metadata.name}={.status.phase}{"\n"}{end}' 2>/dev/null)"; then
    if [[ -n "$pods" ]]; then
      printf '%s\n' "$pods" | head -1 | cut -d= -f2
    else
      printf 'no pods\n'
    fi
  else
    printf 'unreachable\n'
  fi
}

cmd_list() {
  require_cmd kubectl

  local json=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --json)
      json=1
      shift
      ;;
    -*) die "Unknown flag: $1" ;;
    *) die "Unexpected argument: $1" ;;
    esac
  done
  JSON_MODE="$json"

  local dirs=()
  if [[ -d "$STATE_ROOT" ]]; then
    local d
    for d in "$STATE_ROOT"/*/; do
      [[ -d "$d" ]] && dirs+=("$d")
    done
  fi

  if [[ ${#dirs[@]} -eq 0 ]]; then
    if [[ "$json" -eq 1 ]]; then
      printf '[]\n'
    else
      printf 'No environments found.\n'
    fi
    return 0
  fi

  if [[ "$json" -eq 0 ]]; then
    printf '%-20s %-25s %-8s %-20s %-12s %s\n' NAME CONTEXT PORT NAMESPACE PHASE URL
    printf '%s\n' "$(printf '%.0s-' {1..100})"
  else
    printf '['
  fi

  local first=1 name port ctx ns phase url dir
  for dir in "${dirs[@]}"; do
    apply_env_kubeconfig "$dir"
    name="$(basename "$dir")"
    port="$(cat "$dir/port")"
    ctx="$(cat "$dir/context")"
    ns="dev-$name"
    url=""
    [[ -f "$dir/url" ]] && url="$(cat "$dir/url")"
    phase="$(env_phase "$ctx" "$ns")"

    if [[ "$json" -eq 1 ]]; then
      [[ "$first" -eq 1 ]] || printf ','
      first=0
      printf '{"name":%s,"context":%s,"port":%s,"namespace":%s,"phase":%s,"url":%s}' \
        "$(json_str "$name")" "$(json_str "$ctx")" "$port" \
        "$(json_str "$ns")" "$(json_str "$phase")" "$(json_str "$url")"
    else
      printf '%-20s %-25s %-8s %-20s %-12s %s\n' "$name" "$ctx" "$port" "$ns" "$phase" "$url"
    fi
  done

  [[ "$json" -eq 1 ]] && printf ']\n'
  return 0
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
    apply_env_kubeconfig "$dir"
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
