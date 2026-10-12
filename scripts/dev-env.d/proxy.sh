# dev-env: ssh ProxyCommand bridge (sourced by dev-env.sh)

cmd_proxy() {
  require_cmd kubectl
  require_cmd socat

  local alias_name="${1:?Usage: dev-env proxy <alias>}"
  local env_name="${alias_name#k8s-dev-}"

  local dir="$STATE_ROOT/$env_name"
  [[ -d "$dir" ]] || {
    err "No state for '$env_name'. Run 'dev-env list' for active environments."
    exit 1
  }

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
        >>"$dir/forward.log" 2>&1 </dev/null &
      local new_pid=$!
      echo "$new_pid" >"$dir/pid"
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
    echo "$new_port" >"$dir/port"
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
      >>"$dir/forward.log" 2>&1 </dev/null &
    echo "$!" >"$dir/pid"
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
