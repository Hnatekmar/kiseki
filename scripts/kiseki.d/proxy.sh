# kiseki: ssh ProxyCommand bridge (sourced by kiseki.sh)

# A port-forward pins one pod when it starts. After that pod is replaced, the
# forward keeps listening with a dead backend, and the next SSH connection hangs
# in banner exchange. Probe the banner before trusting an existing listener; a
# live sshd answers immediately.
forward_healthy() {
  local port="$1" banner=""
  (
    exec 3<>"/dev/tcp/127.0.0.1/$port" || exit 1
    IFS= read -r -N 4 -t 2 banner <&3 || exit 1
    [[ "$banner" == "SSH-" ]]
  ) 2>/dev/null
}

# Wait for a live pod that is Ready and not terminating, and put its name in
# READY_POD. `kubectl rollout status` is not a readiness gate when a single pod
# is replaced: the Deployment keeps one available replica until the old pod is
# gone, so it can report success before the replacement accepts SSH.
wait_for_ready_pod() {
  local ctx="$1" ns="$2" selector="$3" deadline=$((SECONDS + 300))
  local name deleting ready
  while [[ $SECONDS -lt $deadline ]]; do
    while IFS='|' read -r name deleting ready; do
      if [[ -n "$name" && -z "$deleting" && "$ready" == "True" ]]; then
        READY_POD="$name"
        return 0
      fi
    done < <(kubectl --context "$ctx" -n "$ns" get pods -l "$selector" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.deletionTimestamp}{"|"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null || true)
    sleep 2
  done
  return 1
}

# Wait until the local forward carries an SSH banner. A listening socket alone
# is not enough: kubectl accepts the connection before the pod is reachable.
wait_for_forward() {
  local port="$1" deadline=$((SECONDS + 30))
  while [[ $SECONDS -lt $deadline ]]; do
    forward_healthy "$port" && return 0
    sleep 0.5
  done
  return 1
}

cmd_proxy() {
  require_cmd kubectl
  require_cmd socat

  local alias_name="${1:?Usage: kiseki proxy <alias>}"
  local env_name="${alias_name#kiseki-}"

  local dir="$STATE_ROOT/$env_name"
  [[ -d "$dir" ]] || {
    err "No state for '$env_name'. Run 'kiseki list' for active environments."
    exit 1
  }

  load_state "$dir"

  # Resolve the current pod before touching the forward. Targeting the pod
  # directly avoids pinning a Service endpoint that still points at the pod
  # being replaced.
  local READY_POD=""
  if ! wait_for_ready_pod "$CTX" "kiseki-$env_name" "app.kubernetes.io/instance=kiseki-$env_name"; then
    echo "Pod is not ready after 300s. Check logs with:" >&2
    echo "  kubectl --context $CTX logs -l app.kubernetes.io/instance=kiseki-$env_name -n kiseki-$env_name" >&2
    exit 1
  fi

  # lock and manage forward
  exec 200>"$dir/lock"
  flock -x 200

  local need_forward=0
  if port_in_use "$PORT"; then
    if forward_healthy "$PORT"; then
      : # a live tunnel already exists
    elif [[ -n "$FW_PID" ]] && kill -0 "$FW_PID" 2>/dev/null; then
      # Our forward is alive but its pod is gone. Drop it and start a tunnel to
      # the replacement pod on the same port.
      kill "$FW_PID" 2>/dev/null || true
      wait "$FW_PID" 2>/dev/null || true
      for _ in $(seq 1 20); do
        port_in_use "$PORT" || break
        sleep 0.2
      done
      need_forward=1
    else
      # A foreign process owns the recorded port; move to a free one instead
      # of bridging to it.
      PORT="$(find_free_port "$env_name")"
      echo "$PORT" >"$dir/port"
      need_forward=1
    fi
  else
    need_forward=1
  fi

  if [[ "$need_forward" -eq 1 ]]; then
    if [[ -n "$FW_PID" ]] && kill -0 "$FW_PID" 2>/dev/null; then
      kill "$FW_PID" 2>/dev/null || true
      wait "$FW_PID" 2>/dev/null || true
    fi
    nohup kubectl --context "$CTX" port-forward -n "kiseki-$env_name" \
      "pod/$READY_POD" "$PORT:22" \
      >>"$dir/forward.log" 2>&1 </dev/null &
    echo "$!" >"$dir/pid"
  fi

  if ! wait_for_forward "$PORT"; then
    err "SSH forward on port $PORT did not answer. See $dir/forward.log"
    exit 1
  fi

  flock -u 200
  exec 200>&-

  exec socat - "TCP:127.0.0.1:$PORT"
}
