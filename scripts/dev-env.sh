#!/usr/bin/env bash
set -euo pipefail

# dev-env: spawn and destroy Kubernetes dev environments

STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/dev-env"
MANAGED_SSH="$HOME/.ssh/config.d/k8s-dev-envs"
SSH_CONFIG="$HOME/.ssh/config"

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
CHART_DIR="$SCRIPT_DIR/../charts/dev-env"

# ---- helpers ----

err() {
  printf 'dev-env: %s\n' "$*" >&2
}

die() {
  err "$@"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed"
}

load_state() {
  local dir="$1"
  PORT="$(cat "$dir/port")"
  CTX="$(cat "$dir/context")"
  PID_FILE="$dir/pid"
  if [[ -f "$PID_FILE" ]]; then
    FW_PID="$(cat "$PID_FILE")"
  else
    FW_PID=""
  fi
}

port_in_use() {
  local p="$1"
  ss -tlnH "sport = :$p" 2>/dev/null | grep -q .
}

port_in_state() {
  local p="$1"
  local name
  for d in "$STATE_ROOT"/*/; do
    [[ -f "$d/port" ]] || continue
    name="$(basename "$d")"
    [[ "$name" == "$2" ]] && continue
    [[ "$(cat "$d/port")" == "$p" ]] && return 0
  done
  return 1
}

find_free_port() {
  local skip_name="$1"
  for (( port=2200; port<=2299; port++ )); do
    if ! port_in_use "$port" && ! port_in_state "$port" "$skip_name"; then
      echo "$port"
      return 0
    fi
  done
  die "No free port in range 2200-2299"
}

ensure_ssh_config() {
  mkdir -p "$(dirname "$MANAGED_SSH")"
  touch "$MANAGED_SSH"
  if ! grep -q 'Include ~/.ssh/config.d/k8s-dev-envs' "$SSH_CONFIG" 2>/dev/null; then
    local tmp
    tmp="$(mktemp)"
    printf 'Include ~/.ssh/config.d/k8s-dev-envs\n' > "$tmp"
    cat "$SSH_CONFIG" >> "$tmp" 2>/dev/null || true
    mv "$tmp" "$SSH_CONFIG"
  fi
}

remove_ssh_block() {
  local name="$1"
  local found=0 in_block=0 deleted=0
  local tmp
  tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "# >>> dev-env $name >>>" ]]; then
      found=1
      in_block=1
      continue
    fi
    if [[ "$line" == "# <<< dev-env $name <<<" ]]; then
      in_block=0
      deleted=1
      continue
    fi
    if [[ "$in_block" -eq 1 ]]; then
      continue
    fi
    printf '%s\n' "$line" >> "$tmp"
  done < "$MANAGED_SSH"

  if [[ "$found" -eq 1 && "$deleted" -eq 1 ]]; then
    local count
    count="$(grep -c '# >>> dev-env ' "$MANAGED_SSH" 2>/dev/null || true)"
    mv "$tmp" "$MANAGED_SSH"
    if [[ "$count" -eq 1 ]]; then
      rm -f "$MANAGED_SSH"
    fi
  else
    rm -f "$tmp"
  fi
}

# ---- subcommands ----

cmd_create() {
  require_cmd kubectl
  require_cmd helm
  require_cmd ssh

  local ctx=""
  local name=""
  local cpu=""
  local memory=""
  local key=""
  local no_check=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cpu)        cpu="$2"; shift 2 ;;
      --memory)     memory="$2"; shift 2 ;;
      --ssh-key)    key="$2"; shift 2 ;;
      --context)    ctx="$2"; shift 2 ;;
      --no-check)   no_check=1; shift ;;
      -*)           die "Unknown flag: $1" ;;
      *)
        if [[ -n "$name" ]]; then
          die "Multiple names specified"
        fi
        name="$1"; shift ;;
    esac
  done

  # context
  if [[ -z "$ctx" ]]; then
    ctx="$(kubectl config current-context 2>/dev/null || true)"
  fi
  if [[ -z "$ctx" ]]; then
    die "No context: use --context or set a current context"
  fi
  kubectl --context "$ctx" cluster-info >/dev/null 2>&1 || die "Context '$ctx' is not reachable"

  # name
  if [[ -z "$name" ]]; then
    if [[ -t 0 ]]; then
      printf 'Environment name: '
      read -r name
    else
      die "Name is required (provide as argument or type it interactively)"
    fi
  fi
  if ! [[ "$name" =~ ^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$ ]]; then
    die "Invalid name '$name'. Must match ^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$"
  fi

  local ns="dev-$name"
  local dir="$STATE_ROOT/$name"

  # collision
  if [[ -d "$dir" ]]; then
    die "State directory '$dir' already exists. Run 'dev-env destroy $name' first"
  fi
  if helm --kube-context "$ctx" status "$ns" -n "$ns" >/dev/null 2>&1; then
    die "Release '$ns' already exists in namespace '$ns' on context '$ctx'. Run 'dev-env destroy $name' first"
  fi
  if kubectl --context "$ctx" get ns "$ns" >/dev/null 2>&1; then
    die "Namespace '$ns' already exists on context '$ctx'. Run 'dev-env destroy $name' first"
  fi

  # cpu
  if [[ -z "$cpu" ]]; then
    if [[ -t 0 ]]; then
      printf 'CPU cores [4]: '
      read -r cpu
      cpu="${cpu:-4}"
    else
      cpu=4
    fi
  fi

  # memory
  if [[ -z "$memory" ]]; then
    if [[ -t 0 ]]; then
      printf 'Memory (e.g. 8Gi) [8Gi]: '
      read -r memory
      memory="${memory:-8Gi}"
    else
      memory="8Gi"
    fi
  fi

  # key
  if [[ -z "$key" ]]; then
    local pub_keys=()
    for f in "$HOME/.ssh/"*.pub; do
      [[ -f "$f" ]] && pub_keys+=("$f")
    done
    if [[ ${#pub_keys[@]} -eq 0 ]]; then
      die "No SSH public key found in $HOME/.ssh/ (use --ssh-key to specify)"
    fi

    if [[ ${#pub_keys[@]} -eq 1 ]]; then
      key="${pub_keys[0]}"
    elif [[ -t 0 ]]; then
      printf 'Found SSH keys:\n'
      for i in "${!pub_keys[@]}"; do
        printf '  %d) %s\n' "$((i+1))" "${pub_keys[$i]}"
      done
      printf 'Key number [1]: '
      read -r num
      num="${num:-1}"
      key="${pub_keys[$((num-1))]}"
    else
      key="${pub_keys[0]}"
    fi
  fi
  [[ -f "$key" ]] || die "SSH key file not found: $key"

  # summary
  echo ""
  echo "Creating environment '$name':"
  echo "  CPU:    $cpu"
  echo "  Memory: $memory"
  echo "  Key:    $key"
  echo "  Context: $ctx"

  # helm install
  helm --kube-context "$ctx" install "$ns" "$CHART_DIR" \
    -n "$ns" --create-namespace \
    --set "resources.requests.cpu=$cpu" \
    --set "resources.requests.memory=$memory" \
    --set "resources.limits.cpu=$cpu" \
    --set "resources.limits.memory=$memory" \
    --set-file "ssh.authorizedKey=$key"

  # wait for pod ready
  echo "Waiting for pod to become ready..."
  if ! kubectl --context "$ctx" rollout status "deployment/$ns" -n "$ns" --timeout=300s 2>&1; then
    echo ""
    echo "Pod did not become ready. Environment is still running."
    echo "Debug commands:"
    echo "  kubectl --context $ctx get pods -n $ns"
    echo "  kubectl --context $ctx describe pod -l app.kubernetes.io/instance=$ns -n $ns"
    echo "  kubectl --context $ctx logs -l app.kubernetes.io/instance=$ns -n $ns"
    exit 1
  fi

  # allocate port
  local port
  port="$(find_free_port "$name")"

  # save state
  mkdir -p "$dir"
  echo "$port" > "$dir/port"
  echo "$ctx" > "$dir/context"

  # ssh config
  ensure_ssh_config
  local abs_script
  abs_script="$(readlink -f "$0")"
  {
    printf '\n'
    printf '# >>> dev-env %s >>>\n' "$name"
    printf 'Host k8s-dev-%s\n' "$name"
    printf '    User root\n'
    printf '    ProxyCommand %s proxy %%h\n' "$abs_script"
    printf '    StrictHostKeyChecking no\n'
    printf '    UserKnownHostsFile /dev/null\n'
    printf '    GlobalKnownHostsFile /dev/null\n'
    printf '    CheckHostIP no\n'
    printf '    ServerAliveInterval 30\n'
    printf '    ServerAliveCountMax 3\n'
    printf '    LogLevel ERROR\n'
    printf '# <<< dev-env %s <<<\n' "$name"
  } >> "$MANAGED_SSH"

  # connectivity check
  if [[ "$no_check" -eq 0 ]]; then
    echo "Running SSH connectivity check..."
    if ! ssh -o BatchMode=yes -o ConnectTimeout=15 "k8s-dev-$name" true; then
      echo ""
      echo "Environment '$name' exists but SSH check failed."
      echo "Debug: ssh -v k8s-dev-$name"
      exit 1
    fi
  fi

  echo ""
  echo "Environment '$name' is ready!"
  echo "  SSH alias:   k8s-dev-$name"
  echo "  Namespace:   $ns"
  echo "  Context:     $ctx"
  echo "  Port:        $port"
}

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
      -f) force=1; shift ;;
      -*) die "Unknown flag: $1" ;;
      *)
        if [[ -n "$name" ]]; then
          die "Multiple names specified"
        fi
        name="$1"; shift ;;
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
      [yY][eE][sS]|[yY]) ;;
      *) echo "Cancelled"; exit 0 ;;
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

cmd_proxy() {
  require_cmd kubectl
  require_cmd socat

  local alias_name="${1:?Usage: dev-env proxy <alias>}"
  local env_name="${alias_name#k8s-dev-}"

  local dir="$STATE_ROOT/$env_name"
  [[ -d "$dir" ]] || { err "No state for '$env_name'. Run 'dev-env list' for active environments."; exit 1; }

  load_state "$dir"

  # pod check
  local wait_out=""
  if ! wait_out="$(kubectl --context "$CTX" rollout status "deployment/dev-$env_name" -n "dev-$env_name" --timeout=300s 2>&1)"; then
    printf '%s\n' "$wait_out" >&2
    echo "" >&2
    echo "Pod is not ready. Check logs with:" >&2
    echo "  kubectl --context $CTX logs -l app.kubernetes.io/instance=dev-$env_name -n dev-$env_name" >&2
    exit 1
  fi

  # lock and manage forward
  exec 200>"$dir/lock"
  flock -x 200

  local forward_ok=0
  if port_in_use "$PORT"; then
    forward_ok=1
  fi

  if [[ "$forward_ok" -eq 1 ]]; then
    : # existing forward is listening
  else
    if [[ -n "$FW_PID" ]] && kill -0 "$FW_PID" 2>/dev/null; then
      : # our forwarder still alive (but port not listening yet — wait)
      sleep 2
      if port_in_use "$PORT"; then
        forward_ok=1
      fi
    fi

    if [[ "$forward_ok" -eq 0 ]]; then
      nohup kubectl --context "$CTX" port-forward -n "dev-$env_name" \
        "svc/dev-$env_name" "$PORT:22" \
        >> "$dir/forward.log" 2>&1 </dev/null &
      local new_pid=$!
      echo "$new_pid" > "$dir/pid"
    fi
  fi

  flock -u 200
  exec 200>&-

  # wait for port to accept
  local deadline=$((SECONDS + 10))
  while [[ $SECONDS -lt $deadline ]]; do
    (echo >/dev/tcp/127.0.0.1/"$PORT") >/dev/null 2>&1 && break
    sleep 0.5
  done

  # check if port was taken by another process
  if ! (echo >/dev/tcp/127.0.0.1/"$PORT") >/dev/null 2>&1; then
    local new_port
    new_port="$(find_free_port "$env_name")"
    echo "$new_port" > "$dir/port"
    PORT="$new_port"

    # restart forward on new port
    exec 200>"$dir/lock"
    flock -x 200
    if [[ -n "$FW_PID" ]] && kill -0 "$FW_PID" 2>/dev/null; then
      kill "$FW_PID" 2>/dev/null || true
      wait "$FW_PID" 2>/dev/null || true
    fi
    nohup kubectl --context "$CTX" port-forward -n "dev-$env_name" \
      "svc/dev-$env_name" "$PORT:22" \
      >> "$dir/forward.log" 2>&1 </dev/null &
    echo "$!" > "$dir/pid"
    flock -u 200
    exec 200>&-
    deadline=$((SECONDS + 10))
    while [[ $SECONDS -lt $deadline ]]; do
      (echo >/dev/tcp/127.0.0.1/"$PORT") >/dev/null 2>&1 && break
      sleep 0.5
    done
  fi

  exec socat - "TCP:127.0.0.1:$PORT"
}

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
  --no-check          Skip SSH connectivity check

Destroy options:
  -f                  Force destroy without confirmation

Examples:
  dev-env create my-env --cpu 2 --memory 4Gi
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
    create)   cmd_create "$@" ;;
    list)     cmd_list "$@" ;;
    destroy)  cmd_destroy "$@" ;;
    proxy)    cmd_proxy "$@" ;;
    help)     cmd_help ;;
    *)        err "Unknown command: $cmd"; cmd_help; exit 1 ;;
  esac
}

main "$@"