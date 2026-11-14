#!/usr/bin/env bash
# install.sh — install the muse-hop-stack-watch hook from this repo into
# the live hook locations.
#
# Repo is the source of truth; live copies are synced from here (repo ->
# live, never the reverse). The hook runner only executes scripts under
# ~/hooks/scripts/, so the live script must stay there — this repo holds
# the versioned copy (hooks/).
#
# Usage (from the repo root, after clone or after a VM migration):
#   bash hooks/install.sh
# Idempotent: safe to re-run. A live copy that differs from the repo
# version is overwritten with the repo version and the overwrite is logged.
#
# Verification after copying: script exists + executable, definition
# parses as JSON, and the installed script is dry-run once
# (HATCH_HOOK_DRY_RUN=1 — no state written, no wake emitted). If the
# platform hook runtime is not present yet (fresh VM), the dry-run is
# skipped with a warning instead of failing the install.
set -euo pipefail
export TZ=Asia/Jakarta

log() {
  local level="$1"; shift
  printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*"
}
die() { log ERROR "$*"; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$REPO_ROOT/hooks"
SCRIPT_SRC="$SRC_DIR/scripts/muse-hop-stack-watch.sh"
DEF_SRC="$SRC_DIR/definitions/muse-hop-stack-watch.json"
HOOKS_DIR="${HOME}/hooks"
SCRIPT_DST="$HOOKS_DIR/scripts/muse-hop-stack-watch.sh"
DEF_DST="$HOOKS_DIR/definitions/muse-hop-stack-watch.json"
RUNTIME="${HATCH_HOOK_RUNTIME:-$HOOKS_DIR/runtime/hatch_hook_runtime.sh}"

[ -f "$SCRIPT_SRC" ] || die "missing source: $SCRIPT_SRC"
[ -f "$DEF_SRC" ] || die "missing source: $DEF_SRC"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"
mkdir -p "$HOOKS_DIR/scripts" "$HOOKS_DIR/definitions" "$HOOKS_DIR/state"

install_file() {
  local src="$1" dst="$2" mode="$3"
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
    log INFO "unchanged: $dst"
  else
    [ -f "$dst" ] && log INFO "overwriting live copy with repo version (repo is source of truth): $dst"
    cp "$src" "$dst" || die "copy failed: $src -> $dst"
    log INFO "installed: $dst"
  fi
  chmod "$mode" "$dst" || die "chmod $mode failed: $dst"
}

install_file "$SCRIPT_SRC" "$SCRIPT_DST" 755
install_file "$DEF_SRC" "$DEF_DST" 644

[ -x "$SCRIPT_DST" ] || die "not executable after install: $SCRIPT_DST"
jq -e . "$DEF_DST" >/dev/null || die "definition is not valid JSON: $DEF_DST"
log INFO "definition parses as JSON: $DEF_DST"

if [ ! -f "$RUNTIME" ]; then
  log WARN "hook runtime not found at $RUNTIME — skipping dry-run (platform hook runtime not present yet on this VM); files are installed, the runner will pick them up once the runtime exists"
else
  result="$(HATCH_HOOK_RUNTIME="$RUNTIME" HATCH_HOOK_STATE_DIR="$HOOKS_DIR/state" HATCH_HOOK_ID=muse-hop-stack-watch HATCH_HOOK_DRY_RUN=1 bash "$SCRIPT_DST")" \
    || die "dry-run of installed script failed (exit $?)"
  log INFO "dry-run OK: $result"
fi

log INFO "muse-hop-stack-watch installed"
