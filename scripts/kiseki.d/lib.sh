# kiseki: shared paths and helpers (sourced by kiseki.sh)

STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/kiseki"
MANAGED_SSH="$HOME/.ssh/config.d/kiseki"
SSH_CONFIG="$HOME/.ssh/config"
CHART_DIR="$SCRIPT_DIR/../charts/kiseki"

# Machine-readable mode: human progress goes to stderr, so stdout carries a
# single JSON document. Set by the --json flag.
JSON_MODE="${JSON_MODE:-0}"

err() {
  printf 'kiseki: %s\n' "$*" >&2
}

die() {
  err "$@"
  exit 1
}

# Progress output that stays off stdout when --json is active.
log() {
  if [[ "$JSON_MODE" -eq 1 ]]; then
    printf '%s\n' "$*" >&2
  else
    printf '%s\n' "$*"
  fi
}

# Run a noisy command, keeping its output off stdout in JSON mode.
run_quiet() {
  if [[ "$JSON_MODE" -eq 1 ]]; then
    "$@" >&2
  else
    "$@"
  fi
}

# Quote a string for a YAML double-quoted scalar.
yaml_str() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

# Quote a string for a JSON string value.
json_str() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed"
}

# Pin kubectl to the kubeconfig the environment was created with. The context
# name alone is ambiguous: a context can live in any file on KUBECONFIG, and
# `proxy` runs in a fresh shell that does not inherit the caller's export.
apply_env_kubeconfig() {
  local dir="$1"
  if [[ -f "$dir/kubeconfig" && -s "$dir/kubeconfig" ]]; then
    export KUBECONFIG
    KUBECONFIG="$(cat "$dir/kubeconfig")"
  fi
}

load_state() {
  local dir="$1"
  apply_env_kubeconfig "$dir"
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
  for ((port = 2200; port <= 2299; port++)); do
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
  if ! grep -q 'Include ~/.ssh/config.d/kiseki' "$SSH_CONFIG" 2>/dev/null; then
    local tmp
    tmp="$(mktemp)"
    printf 'Include ~/.ssh/config.d/kiseki\n' >"$tmp"
    cat "$SSH_CONFIG" >>"$tmp" 2>/dev/null || true
    mv "$tmp" "$SSH_CONFIG"
  fi
}

remove_ssh_block() {
  local name="$1"
  local found=0 in_block=0 deleted=0
  local tmp
  tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "# >>> kiseki $name >>>" ]]; then
      found=1
      in_block=1
      continue
    fi
    if [[ "$line" == "# <<< kiseki $name <<<" ]]; then
      in_block=0
      deleted=1
      continue
    fi
    if [[ "$in_block" -eq 1 ]]; then
      continue
    fi
    printf '%s\n' "$line" >>"$tmp"
  done <"$MANAGED_SSH"

  if [[ "$found" -eq 1 && "$deleted" -eq 1 ]]; then
    local count
    count="$(grep -c '# >>> kiseki ' "$MANAGED_SSH" 2>/dev/null || true)"
    mv "$tmp" "$MANAGED_SSH"
    if [[ "$count" -eq 1 ]]; then
      rm -f "$MANAGED_SSH"
    fi
  else
    rm -f "$tmp"
  fi
}

# --- waiting for an environment ---------------------------------------------
# `helm install` returns before the pod runs anything, and a first start pulls
# the Fedora image, installs packages and clones dotfiles: several minutes in
# which the old code printed nothing at all. These helpers turn the pod's own
# state into a status line, so the wait is legible on a terminal and in CI logs.

# Translate one container's waiting state into what the user would see in the
# pod's `kubectl describe`.
_waiting_text() {
  case "$1" in
  ContainerCreating) printf 'pulling the image and creating containers' ;;
  PodInitializing) printf 'running init containers' ;;
  ImagePullBackOff | ErrImagePull | InvalidImageName) printf 'image pull failing (%s)' "$1" ;;
  CrashLoopBackOff) printf 'container crash-looping' ;;
  CreateContainerConfigError) printf 'container config rejected' ;;
  *) printf '%s' "$1" ;;
  esac
}

# One line describing what the environment pod is doing right now. Prints
# "ready" when every container reports ready, and a "fatal: ..." line when the
# environment cannot become ready on its own, so the caller can stop waiting.
environment_state() {
  local ctx="$1" ns="$2"
  # Field separator is US (0x1f), not a tab: bash treats tab as IFS whitespace,
  # which collapses consecutive empty fields, so a pod with no init containers
  # would shift the container statuses into the message field.
  local sep=$'\x1f' out phase message init containers deleting err="" errfile
  errfile="$(mktemp)"
  # A failing kubectl call must not be reported as "no pod yet": a deleted
  # namespace or an unreachable context would otherwise look like a pod that
  # never gets created, for the whole 20 minute budget.
  if ! out="$(kubectl --context "$ctx" get pods -n "$ns" \
    -l "app.kubernetes.io/instance=$ns" \
    -o jsonpath='{range .items[*]}{.metadata.deletionTimestamp}{"\u001f"}{.status.phase}{"\u001f"}{.status.conditions[?(@.type=="PodScheduled")].message}{"\u001f"}{range .status.initContainerStatuses[*]}{.name}={.ready},{.state.waiting.reason},{.state.terminated.exitCode} {end}{"\u001f"}{range .status.containerStatuses[*]}{.name}={.ready},{.state.waiting.reason},{.state.running.startedAt},{.state.terminated.exitCode},{.lastState.terminated.exitCode} {end}{"\n"}{end}' \
    2>"$errfile")"; then
    err="$(<"$errfile")"
    err="${err%%$'\n'*}"
  fi
  rm -f "$errfile"

  if [[ -z "$out" ]]; then
    if [[ -n "$err" ]]; then
      printf 'fatal: cannot read the pod: %s' "$err"
      return 0
    fi
    # kubectl reports a missing namespace as an empty list with exit 0, so the
    # only way to tell "not created yet" from "deleted underneath us" is to ask.
    if ! kubectl --context "$ctx" get namespace "$ns" >/dev/null 2>&1; then
      printf 'fatal: namespace %s no longer exists' "$ns"
      return 0
    fi
    printf 'waiting for the pod to be created'
    return 0
  fi

  # A replaced pod can overlap with its predecessor for a moment, and a
  # terminating pod still reports ready containers. Describe the pod that will
  # serve, not the one that is leaving.
  local line="" candidate
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    [[ "${candidate%%$sep*}" == "" ]] && { line="$candidate"; break; }
    [[ -z "$line" ]] && line="$candidate"
  done <<<"$out"
  IFS="$sep" read -r deleting phase message init containers <<<"$line"
  if [[ -n "$deleting" ]]; then
    printf 'fatal: the pod is being deleted'
    return 0
  fi

  if [[ "$phase" == "Failed" || "$phase" == "Succeeded" ]]; then
    printf 'fatal: the pod exited (%s)' "$phase"
    return 0
  fi

  # An unschedulable pod reports why only in the PodScheduled condition; without
  # that the wait looks stuck with no cause, which is the worst failure mode.
  if [[ "$phase" == "Pending" && -n "$message" ]]; then
    message="${message% preemption:*}"
    ((${#message} > 140)) && message="${message:0:137}..."
    printf 'not scheduled: %s' "$message"
    return 0
  fi

  local item name rest flag reason started exit_code last_exit
  for item in $init; do
    [[ -n "$item" ]] || continue
    name="${item%%=*}"
    rest="${item#*=}"            # <ready>,<waiting reason>,<terminated exit code>
    flag="${rest%%,*}"
    rest="${rest#*,}"
    reason="${rest%%,*}"
    exit_code="${rest#*,}"
    [[ "$flag" == "true" ]] && continue
    if [[ -n "$reason" ]]; then
      printf 'init %s: %s' "$name" "$(_waiting_text "$reason")"
    elif [[ -n "$exit_code" ]]; then
      # Init containers are retried, so a non-zero exit is progress, not a verdict.
      printf 'init %s: exited %s, retrying' "$name" "$exit_code"
    else
      printf 'init %s: starting' "$name"
    fi
    return 0
  done

  local total=0 ready=0
  for item in $containers; do
    [[ -n "$item" ]] || continue
    name="${item%%=*}"
    rest="${item#*=}"            # <ready>,<waiting reason>,<running since>,<exit>,<last exit>
    flag="${rest%%,*}"
    rest="${rest#*,}"
    reason="${rest%%,*}"
    rest="${rest#*,}"
    started="${rest%%,*}"
    rest="${rest#*,}"
    exit_code="${rest%%,*}"
    last_exit="${rest#*,}"
    if [[ "$flag" == "true" ]]; then
      total=$((total + 1))
      ready=$((ready + 1))
      continue
    fi
    # A container that ran to completion is not a readiness gate: it did its job.
    # `exit` covers the moment it finishes, `last_exit` the restarts that follow
    # under restartPolicy: Always, where it would otherwise read as crash-looping.
    if [[ "$exit_code" == "0" || "$last_exit" == "0" ]]; then
      continue
    fi
    total=$((total + 1))
    if [[ -n "$reason" ]]; then
      printf '%s: %s' "$name" "$(_waiting_text "$reason")"
    elif [[ -n "$started" ]]; then
      if [[ "$name" == "kiseki" ]]; then
        # Running, probe not passing yet: this is up.sh installing packages and
        # cloning dotfiles, which is the slow part of a first start.
        printf 'provisioning (packages and dotfiles)'
      else
        printf '%s: starting' "$name"
      fi
    elif [[ -n "$exit_code" ]]; then
      printf '%s: crash-looping (exit %s)' "$name" "$exit_code"
    else
      printf '%s: creating' "$name"
    fi
    return 0
  done

  if [[ "$total" -gt 0 && "$ready" -eq "$total" ]]; then
    printf 'ready'
    return 0
  fi

  case "$phase" in
  Running) printf 'provisioning (packages and dotfiles)' ;;
  Pending) printf 'pending' ;;
  *) printf '%s' "${phase:-unknown}" ;;
  esac
}

# Poll the pod until it is ready. A terminal gets one line rewritten in place
# with a spinner; a pipe gets one line per state change, which is what makes the
# CI log readable. Returns 1 on timeout.
wait_for_environment() {
  local ctx="$1" ns="$2" timeout="${3:-1200}"
  local started=$SECONDS detail="" last="" frame=0 interactive=0
  local -a frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  if [[ "$JSON_MODE" -eq 0 && -t 1 ]]; then
    interactive=1
  fi

  while :; do
    detail="$(environment_state "$ctx" "$ns")"
    if [[ "$detail" == "ready" ]]; then
      [[ "$interactive" -eq 1 ]] && printf '\r\033[K'
      log "  ✓ ready after $((SECONDS - started))s"
      return 0
    fi
    # Unrecoverable states are reported now, not after twenty minutes of polling.
    if [[ "$detail" == fatal:* ]]; then
      [[ "$interactive" -eq 1 ]] && printf '\r\033[K'
      log "  ✗ ${detail#fatal: } ($((SECONDS - started))s)"
      return 1
    fi
    if [[ "$interactive" -eq 1 ]]; then
      printf '\r\033[K  %s %s (%ds)' "${frames[frame]}" "$detail" "$((SECONDS - started))"
      frame=$(((frame + 1) % ${#frames[@]}))
    elif [[ "$detail" != "$last" ]]; then
      log "  $detail ($((SECONDS - started))s)"
    fi
    last="$detail"
    if ((SECONDS - started >= timeout)); then
      [[ "$interactive" -eq 1 ]] && printf '\r\033[K'
      log "  ✗ still not ready after $((SECONDS - started))s: $detail"
      return 1
    fi
    sleep 2
  done
}
