#!/usr/bin/env bash
# Put dev-env on PATH.
#
#   ./scripts/install.sh                     # symlink into ~/.local/bin
#   ./scripts/install.sh --prefix /usr/local # system-wide, needs write access
#   ./scripts/install.sh --uninstall
#
# The symlink points at this checkout, so edits in the repo take effect
# immediately. The chart is resolved relative to the real script path, so it
# works from any directory.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE="$SCRIPT_DIR/dev-env.sh"

PREFIX="${PREFIX:-$HOME/.local}"
BINDIR="${BINDIR:-}"
UNINSTALL=0

die() {
  printf 'install.sh: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
usage: scripts/install.sh [options]

  --prefix DIR    install under DIR (default: $HOME/.local)
  --bindir DIR    put the symlink in DIR (default: <prefix>/bin)
  --uninstall     remove the symlink
  -h, --help      show this help

Environment: PREFIX, BINDIR
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --prefix)
    PREFIX="$2"
    shift 2
    ;;
  --bindir)
    BINDIR="$2"
    shift 2
    ;;
  --uninstall)
    UNINSTALL=1
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *) die "unknown argument: $1 (try --help)" ;;
  esac
done

if [[ -z "$BINDIR" ]]; then
  BINDIR="$PREFIX/bin"
fi
TARGET="$BINDIR/dev-env"

if [[ "$UNINSTALL" -eq 1 ]]; then
  if [[ ! -L "$TARGET" ]]; then
    if [[ -e "$TARGET" ]]; then
      die "$TARGET is a regular file, not a symlink; remove it yourself"
    fi
    printf 'install.sh: %s is not installed\n' "$TARGET"
    exit 0
  fi
  current="$(readlink "$TARGET")"
  if [[ "$current" != "$SOURCE" ]]; then
    die "$TARGET points at $current, not this checkout ($SOURCE); not removing it"
  fi
  rm -f "$TARGET"
  printf 'install.sh: removed %s\n' "$TARGET"
  exit 0
fi

[[ -f "$SOURCE" ]] || die "missing $SOURCE"
[[ -x "$SOURCE" ]] || chmod +x "$SOURCE"

mkdir -p "$BINDIR"

if [[ -e "$TARGET" && ! -L "$TARGET" ]]; then
  die "$TARGET exists and is not a symlink; remove it first"
fi
if [[ -L "$TARGET" ]]; then
  previous="$(readlink "$TARGET")"
  if [[ "$previous" != "$SOURCE" ]]; then
    printf 'install.sh: replacing %s (was %s)\n' "$TARGET" "$previous"
  fi
fi

ln -sfn "$SOURCE" "$TARGET"

# The one check that matters: the symlink resolves and the CLI runs.
if ! "$TARGET" --help >/dev/null; then
  die "$TARGET does not run; the checkout at $REPO_DIR is incomplete"
fi

printf 'install.sh: %s -> %s\n' "$TARGET" "$SOURCE"
case ":$PATH:" in
*":$BINDIR:"*) ;;
*) printf 'install.sh: note: %s is not on PATH; add it with:\n  export PATH="%s:$PATH"\n' "$BINDIR" "$BINDIR" ;;
esac
