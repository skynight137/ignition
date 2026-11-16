#!/usr/bin/env bash
# pull-setup.sh — robust ignition update via clone-move (NO pull in WS).
# The old `git pull --ff-only` aborted whenever the tree was dirty
# (local edits) or an untracked file would be overwritten — and even the
# backup-and-pull variant still runs a merge in the live workspace.
# This version never pulls in the live dir at all:
#   1. fresh clone to /tmp, verify HEAD
#   2. preserve local work: untracked files that the repo does NOT
#      provide are copied into the fresh clone; the whole old dir is
#      moved aside to a timestamped backup (nothing deleted)
#   3. move the fresh clone into place
# Usage: bash ignition/scripts/replit/pull-setup.sh
set -u
U="https://github.com/skynight137/ignition.git"
D="$HOME/workspace/ignition"
TMP="/tmp/ignition-new-$$"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] pull-setup: $*"; }

# 1. Fresh clone to /tmp
git clone "$U" "$TMP" || { log "FAIL clone"; exit 1; }
NEW_HEAD=$(git -C "$TMP" rev-parse --short HEAD)
log "cloned HEAD $NEW_HEAD"

# 2. Preserve local work from the live dir (if it exists)
BAK=""
if [ -d "$D" ]; then
  OLD_HEAD=$(git -C "$D" rev-parse --short HEAD 2>/dev/null || echo "none")
  BAK="$HOME/workspace/ignition-backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BAK"
  # Untracked local files the repo does NOT provide -> copy into the
  # fresh clone so local state (e.g. a node .env) survives the swap.
  # Files the repo now provides are skipped (repo version wins).
  git -C "$D" status --porcelain | awk '$1 == "??" {print $2}' | while read -r f; do
    [ -n "$f" ] || continue
    if [ ! -e "$TMP/$f" ]; then
      mkdir -p "$TMP/$(dirname "$f")"
      cp "$D/$f" "$TMP/$f" 2>/dev/null && log "kept local untracked $f"
    fi
  done
  # Whole old dir aside (preserves modified tracked files + .git).
  mv "$D" "$BAK/ignition-old-$OLD_HEAD"
  log "old dir -> $BAK/ignition-old-$OLD_HEAD (was $OLD_HEAD)"
fi

# 3. Move fresh clone into place
mv "$TMP" "$D"
log "OK HEAD $NEW_HEAD backup=$BAK"
