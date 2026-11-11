#!/usr/bin/env bash
# setup.sh — THE setup entry for both machine kinds (shared-setup
# refactor, S4). One command surface; the machine profile does the
# work:
#
#   bash setup.sh [--machine muse|repl] [profile flags...]
#
# --machine wins when given. Without it the machine is detected:
# REPL_HOME set (a Replit workspace) → repl, otherwise muse.
# Profiles: scripts/setup/profile-repl.sh, profile-muse.sh.
# Shared modules: scripts/setup/core.sh (logging/verify),
# scripts/setup/join.sh (the join engine).
set -euo pipefail
if (( BASH_VERSINFO[0] < 4 )); then
  echo "setup: bash >= 4 required (this is bash $BASH_VERSION) — on macOS: brew install bash" >&2
  exit 2
fi
MACHINE=""
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --machine)   MACHINE="${2:?--machine needs a value}"; shift 2 ;;
    --machine=*) MACHINE="${1#--machine=}"; shift ;;
    *)           ARGS+=("$1"); shift ;;
  esac
done
if [[ -z "$MACHINE" ]]; then
  if [[ -n "${REPL_HOME:-}" ]]; then MACHINE=repl; else MACHINE=muse; fi
fi
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
case "$MACHINE" in
  repl) exec bash "$HERE/setup/profile-repl.sh" "${ARGS[@]}" ;;
  muse) exec bash "$HERE/setup/profile-muse.sh" "${ARGS[@]}" ;;
  *)    echo "setup: unknown --machine '$MACHINE' (want muse|repl)" >&2; exit 2 ;;
esac
