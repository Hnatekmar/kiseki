# dev-env: shared paths and helpers (sourced by dev-env.sh)

STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/dev-env"
MANAGED_SSH="$HOME/.ssh/config.d/k8s-dev-envs"
SSH_CONFIG="$HOME/.ssh/config"
CHART_DIR="$SCRIPT_DIR/../charts/dev-env"

# Machine-readable mode: human progress goes to stderr, so stdout carries a
# single JSON document. Set by the --json flag.
JSON_MODE="${JSON_MODE:-0}"

err() {
  printf 'dev-env: %s\n' "$*" >&2
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
  if ! grep -q 'Include ~/.ssh/config.d/k8s-dev-envs' "$SSH_CONFIG" 2>/dev/null; then
    local tmp
    tmp="$(mktemp)"
    printf 'Include ~/.ssh/config.d/k8s-dev-envs\n' >"$tmp"
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
    printf '%s\n' "$line" >>"$tmp"
  done <"$MANAGED_SSH"

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
