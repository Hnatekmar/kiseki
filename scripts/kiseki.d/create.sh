# kiseki: create subcommand (sourced by kiseki.sh)

# Append one sidecar spec to a YAML fragment.
# Spec: name=image[:tag][,port=N][,env=KEY=VALUE][,env=KEY2=VALUE2]
append_sidecar() {
  local spec="$1" out="$2"
  local name image rest part port="" envs=()

  name="${spec%%=*}"
  [[ "$name" != "$spec" ]] || die "--container expects name=image[:tag], got '$spec'"
  if ! [[ "$name" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
    die "Invalid container name '$name' in --container '$spec'"
  fi

  rest="${spec#*=}"
  image="${rest%%,*}"
  rest="${rest#"$image"}"
  [[ -n "$image" ]] || die "Invalid --container '$spec': missing image"

  while [[ "$rest" == ,* ]]; do
    rest="${rest#,}"
    part="${rest%%,*}"
    rest="${rest#"$part"}"
    case "$part" in
    port=*)
      port="${part#port=}"
      [[ "$port" =~ ^[0-9]{1,5}$ ]] || die "Invalid port '$port' in --container '$spec'"
      port=$((10#$port))
      ((port >= 1 && port <= 65535)) || die "Port out of range in --container '$spec'"
      ;;
    env=*)
      local kv="${part#env=}"
      [[ "$kv" == *=* ]] || die "Invalid env '$kv' in --container '$spec' (expected KEY=VALUE)"
      envs+=("$kv")
      ;;
    *)
      die "Unknown --container option '$part' in '$spec' (supported: port=, env=)"
      ;;
    esac
  done

  {
    printf '  - name: %s\n' "$name"
    printf '    image: %s\n' "$(yaml_str "$image")"
    if [[ -n "$port" ]]; then
      printf '    ports:\n'
      printf '      - name: %s\n' "$name"
      printf '        containerPort: %s\n' "$port"
    fi
    if [[ ${#envs[@]} -gt 0 ]]; then
      printf '    env:\n'
      local kv
      for kv in "${envs[@]}"; do
        printf '      - name: %s\n' "${kv%%=*}"
        printf '        value: %s\n' "$(yaml_str "${kv#*=}")"
      done
    fi
  } >>"$out"
}

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
  local persistence_size=""
  local storage_class=""
  local docker=0
  local address=""
  local web_port=""
  local containers=()
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
    --address)
      address="$2"
      shift 2
      ;;
    --port)
      web_port="$2"
      shift 2
      ;;
    --container)
      containers+=("$2")
      shift 2
      ;;
    --docker)
      docker=1
      shift
      ;;
    --json)
      JSON_MODE=1
      shift
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
    --persistence-size)
      [[ $# -ge 2 ]] || die "--persistence-size requires a size such as 20Gi"
      persistence_size="$2"
      persistence=1
      shift 2
      ;;
    --storage-class)
      [[ $# -ge 2 ]] || die "--storage-class requires a StorageClass name"
      storage_class="$2"
      persistence=1
      shift 2
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

  # --address names the Ingress host; --port is the container port behind it.
  if [[ -n "$address" && -z "$web_port" ]] || [[ -z "$address" && -n "$web_port" ]]; then
    die "--address and --port must be given together"
  fi
  if [[ -n "$web_port" ]]; then
    [[ "$web_port" =~ ^[0-9]{1,5}$ ]] || die "Invalid --port '$web_port'"
    web_port=$((10#$web_port))
    ((web_port >= 1 && web_port <= 65535)) || die "--port must be 1-65535"
    ((web_port != 22)) || die "--port 22 is reserved for ssh"
    if ! [[ "$address" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || [[ "$address" != *.* ]]; then
      die "Invalid --address '$address': expected a DNS name such as app.dev-k8s.srv.example.com"
    fi
  fi

  # A Kubernetes quantity: positive number with an optional binary or decimal
  # suffix. Rejecting it here turns a typo into a flag error instead of a PVC
  # that never binds.
  if [[ -n "$persistence_size" ]]; then
    [[ "$persistence_size" =~ ^[0-9]+(\.[0-9]+)?(Ki|Mi|Gi|Ti|Pi|Ei|k|M|G|T|P|E)?$ ]] ||
      die "Invalid --persistence-size '$persistence_size': expected a quantity such as 20Gi"
  fi
  if [[ -n "$storage_class" ]]; then
    [[ "$storage_class" =~ ^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$ ]] ||
      die "Invalid --storage-class '$storage_class'"
  fi

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

  local ns="kiseki-$name"
  local dir="$STATE_ROOT/$name"

  # collision
  if [[ -d "$dir" ]]; then
    die "State directory '$dir' already exists. Run 'kiseki destroy $name' first"
  fi
  if helm --kube-context "$ctx" status "$ns" -n "$ns" >/dev/null 2>&1; then
    die "Release '$ns' already exists in namespace '$ns' on context '$ctx'. Run 'kiseki destroy $name' first"
  fi
  if kubectl --context "$ctx" get ns "$ns" >/dev/null 2>&1; then
    die "Namespace '$ns' already exists on context '$ctx'. Run 'kiseki destroy $name' first"
  fi

  # sidecar names must be unique inside the pod
  if [[ ${#containers[@]} -gt 0 ]]; then
    local seen=" " spec cname
    for spec in "${containers[@]}"; do
      cname="${spec%%=*}"
      if [[ "$seen" == *" $cname "* ]]; then
        die "Duplicate --container name '$cname'"
      fi
      seen+="$cname "
    done
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
    elif [[ -f "$HOME/.ssh/id_ed25519.pub" ]]; then
      # No TTY: prefer the conventional default key rather than whichever path
      # the glob listed first. A wrong guess surfaces later as "Permission
      # denied", which reads like a broken environment instead of a bad flag.
      key="$HOME/.ssh/id_ed25519.pub"
    else
      die "Several SSH keys found and no TTY. Pass --ssh-key PATH (found: ${pub_keys[*]})"
    fi
  fi
  [[ -f "$key" ]] || die "SSH key file not found: $key"

  # The chart takes sidecars as a list; build a values file so arbitrary env
  # values do not need --set escaping.
  local tmpdir
  tmpdir="$(mktemp -d)"
  # Expand at exit time, not definition time: tmpdir is a function local, so a
  # single-quoted trap would reference it after the function returns and fail
  # under `set -u`.
  trap 'rm -rf "${tmpdir:-}"' EXIT
  local sidecars_file="$tmpdir/sidecars.yaml" values_file="$tmpdir/values.yaml"
  : >"$sidecars_file"
  local spec
  for spec in "${containers[@]}"; do
    append_sidecar "$spec" "$sidecars_file"
  done
  if [[ -s "$sidecars_file" ]]; then
    {
      printf 'extraContainers:\n'
      cat "$sidecars_file"
    } >"$values_file"
  else
    : >"$values_file"
  fi

  # summary
  log ""
  log "Creating environment '$name':"
  log "  CPU:     $cpu"
  log "  Memory:  $memory"
  [[ "$gpu" -gt 0 ]] && log "  GPU:     $gpu"
  log "  Key:     $key"
  log "  Context: $ctx"
  [[ -n "$address" ]] && log "  Address: https://$address -> :$web_port"
  [[ ${#containers[@]} -gt 0 ]] && log "  Sidecars: ${containers[*]}"
  [[ "$docker" -eq 1 ]] && log "  Docker:  dind sidecar"
  [[ "$persistence" -eq 1 ]] &&
    log "  Home:    ${persistence_size:-10Gi} persistent${storage_class:+ on $storage_class}"

  # helm install
  if [[ "$persistence" -eq 1 ]]; then
    extra+=(--set "storage.enabled=true")
    [[ -n "$persistence_size" ]] && extra+=(--set "storage.size=$persistence_size")
    [[ -n "$storage_class" ]] && extra+=(--set "storage.storageClass=$storage_class")
  fi
  if [[ "$gpu" -gt 0 ]]; then
    extra+=(--set "gpu.enabled=true" --set "gpu.count=$gpu")
  fi
  if [[ -n "$address" ]]; then
    extra+=(--set "ingress.enabled=true" --set "ingress.host=$address" --set "ingress.port=$web_port")
  fi
  if [[ "$docker" -eq 1 ]]; then
    extra+=(--set "docker.enabled=true")
  fi

  # The namespace is created here rather than by `helm --create-namespace`: a
  # dind sidecar needs the privileged Pod Security level, and the label must be
  # in place before the ReplicaSet tries to create a pod. Clusters that enforce
  # baseline (the dev cluster does) otherwise reject the pod with a bare
  # "violates PodSecurity" error that the rollout only reports as a timeout.
  run_quiet kubectl --context "$ctx" create namespace "$ns"
  if [[ "$docker" -eq 1 ]]; then
    log "  PodSecurity: labeling $ns enforce=privileged for the dind sidecar"
    run_quiet kubectl --context "$ctx" label namespace "$ns" \
      pod-security.kubernetes.io/enforce=privileged --overwrite
  fi

  run_quiet helm --kube-context "$ctx" install "$ns" "$CHART_DIR" \
    -n "$ns" \
    --set "resources.requests.cpu=$cpu" \
    --set "resources.requests.memory=$memory" \
    --set "resources.limits.cpu=$cpu" \
    --set "resources.limits.memory=$memory" \
    --set-file "ssh.authorizedKey=$key" \
    --values "$values_file" \
    "${extra[@]}"

  # wait for pod ready
  log "Waiting for pod to become ready..."
  if ! run_quiet kubectl --context "$ctx" rollout status "deployment/$ns" -n "$ns" --timeout=20m; then
    err ""
    err "Pod did not become ready. Environment is still running."
    err "Debug commands:"
    err "  kubectl --context $ctx get pods -n $ns"
    err "  kubectl --context $ctx describe pod -l app.kubernetes.io/instance=$ns -n $ns"
    err "  kubectl --context $ctx logs -l app.kubernetes.io/instance=$ns -n $ns"
    exit 1
  fi

  # Report what the deployment actually runs: a values file can add sidecars
  # that no flag mentioned.
  local sidecar_names=()
  local container
  while IFS= read -r container; do
    [[ -n "$container" ]] && sidecar_names+=("$container")
  done < <(kubectl --context "$ctx" get deployment "$ns" -n "$ns" \
    -o jsonpath='{range .spec.template.spec.containers[*]}{.name}{"\n"}{end}' 2>/dev/null |
    grep -vxE 'kiseki|docker' || true)

  # allocate port
  local port
  port="$(find_free_port "$name")"

  # save state
  mkdir -p "$dir"
  echo "$port" >"$dir/port"
  echo "$ctx" >"$dir/context"
  # Remember which kubeconfig the context came from, so the proxy helper can
  # reach it without the caller's environment.
  if [[ -n "${KUBECONFIG:-}" ]]; then
    echo "$KUBECONFIG" >"$dir/kubeconfig"
  fi
  local url=""
  if [[ -n "$address" ]]; then
    url="https://$address"
    echo "$url" >"$dir/url"
  fi

  # ssh config
  ensure_ssh_config
  local abs_script
  abs_script="$(readlink -f "$0")"
  {
    printf '\n'
    printf '# >>> kiseki %s >>>\n' "$name"
    printf 'Host kiseki-%s\n' "$name"
    printf '    User root\n'
    printf '    ProxyCommand %s proxy %%h\n' "$abs_script"
    printf '    StrictHostKeyChecking no\n'
    printf '    UserKnownHostsFile /dev/null\n'
    printf '    GlobalKnownHostsFile /dev/null\n'
    printf '    CheckHostIP no\n'
    printf '    ServerAliveInterval 30\n'
    printf '    ServerAliveCountMax 3\n'
    printf '    LogLevel ERROR\n'
    printf '# <<< kiseki %s <<<\n' "$name"
  } >>"$MANAGED_SSH"

  # connectivity check
  if [[ "$no_check" -eq 0 ]]; then
    log "Running SSH connectivity check..."
    if ! run_quiet ssh -o BatchMode=yes -o ConnectTimeout=15 "kiseki-$name" true; then
      err ""
      err "Environment '$name' exists but SSH check failed."
      err "Debug: ssh -v kiseki-$name"
      exit 1
    fi
  fi

  if [[ "$JSON_MODE" -eq 1 ]]; then
    local json_containers="" c
    for c in "${sidecar_names[@]}"; do
      [[ -z "$json_containers" ]] || json_containers+=","
      json_containers+="$(json_str "$c")"
    done
    printf '{"name":%s,"namespace":%s,"context":%s,"ssh_alias":%s,"ssh_port":%s,"url":%s,"containers":[%s],"docker":%s}\n' \
      "$(json_str "$name")" \
      "$(json_str "$ns")" \
      "$(json_str "$ctx")" \
      "$(json_str "kiseki-$name")" \
      "$port" \
      "$(json_str "$url")" \
      "$json_containers" \
      "$([[ "$docker" -eq 1 ]] && echo true || echo false)"
    return 0
  fi

  log ""
  log "Environment '$name' is ready!"
  log "  SSH alias:   kiseki-$name"
  log "  Namespace:   $ns"
  log "  Context:     $ctx"
  log "  Port:        $port"
  if [[ ${#sidecar_names[@]} -gt 0 ]]; then
    log "  Sidecars:    ${sidecar_names[*]}"
  fi
  if [[ -n "$url" ]]; then
    log "  URL:         $url"
  fi
}
