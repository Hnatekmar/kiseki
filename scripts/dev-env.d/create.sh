# dev-env: create subcommand (sourced by dev-env.sh)

cmd_create() {
  require_cmd kubectl
  require_cmd helm
  require_cmd ssh

  local ctx=""
  local name=""
  local cpu=""
  local memory=""
  local gpu=0
  local key=""
  local no_check=0
  local persistence=0
  local extra=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --cpu)
      cpu="$2"
      shift 2
      ;;
    --memory)
      memory="$2"
      shift 2
      ;;
    --gpu)
      [[ $# -ge 2 ]] || die "--gpu requires a count"
      gpu="$2"
      [[ "$gpu" =~ ^[0-9]{1,3}$ ]] || die "Invalid GPU count '$gpu'. Must be 0-999"
      gpu="$((10#$gpu))"
      shift 2
      ;;
    --ssh-key)
      key="$2"
      shift 2
      ;;
    --context)
      ctx="$2"
      shift 2
      ;;
    --set)
      extra+=(--set "$2")
      shift 2
      ;;
    -f | --values)
      extra+=(--values "$2")
      shift 2
      ;;
    --persistence)
      persistence=1
      shift
      ;;
    --no-check)
      no_check=1
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
        printf '  %d) %s\n' "$((i + 1))" "${pub_keys[$i]}"
      done
      printf 'Key number [1]: '
      read -r num
      num="${num:-1}"
      key="${pub_keys[$((num - 1))]}"
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
  [[ "$gpu" -gt 0 ]] && echo "  GPU:    $gpu"
  echo "  Key:    $key"
  echo "  Context: $ctx"

  # helm install
  if [[ "$persistence" -eq 1 ]]; then
    extra+=(--set "storage.enabled=true")
  fi
  if [[ "$gpu" -gt 0 ]]; then
    extra+=(--set "gpu.enabled=true" --set "gpu.count=$gpu")
  fi
  helm --kube-context "$ctx" install "$ns" "$CHART_DIR" \
    -n "$ns" --create-namespace \
    --set "resources.requests.cpu=$cpu" \
    --set "resources.requests.memory=$memory" \
    --set "resources.limits.cpu=$cpu" \
    --set "resources.limits.memory=$memory" \
    --set-file "ssh.authorizedKey=$key" \
    "${extra[@]}"

  # wait for pod ready
  echo "Waiting for pod to become ready..."
  if ! kubectl --context "$ctx" rollout status "deployment/$ns" -n "$ns" --timeout=20m 2>&1; then
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
  echo "$port" >"$dir/port"
  echo "$ctx" >"$dir/context"

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
  } >>"$MANAGED_SSH"

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
