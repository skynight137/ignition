#!/usr/bin/env bash
# pull-setup.sh — robust ignition update for Replit nodes.
# Replaces the old one-liner `git pull --ff-only`, which aborts whenever
# the tree is dirty (local edits) or an untracked file would be
# overwritten. This version NEVER deletes local work: anything that
# would block the update is copied to a timestamped backup dir first,
# then the tree is made clean and pulled. The backup is reported so the
# owner can review / re-apply it (the correct route is a PR to the
# ignition repo, not a local edit on a node).
#
# Usage: bash ignition/scripts/replit/pull-setup.sh
#   (also safe to run directly on a node for testing)
set -u
U="https://github.com/skynight137/ignition.git"
D="$HOME/workspace/ignition"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] pull-setup: $*"; }

if [ ! -d "$D/.git" ]; then
  log "no repo, cloning"
  git clone "$U" "$D" || { log "FAIL clone"; exit 1; }
  log "cloned HEAD $(git -C "$D" rev-parse --short HEAD)"
  exit 0
fi

git -C "$D" remote set-url origin "$U"
git -C "$D" fetch origin || { log "FAIL fetch"; exit 1; }

BAK="$HOME/workspace/ignition-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BAK"
BACKED_UP=0

# 1. Modified tracked files: back up, then restore to HEAD.
git -C "$D" status --porcelain | awk '$1 ~ /^[MADRC]/ {print $2}' | while read -r f; do
  [ -n "$f" ] || continue
  mkdir -p "$BAK/$(dirname "$f")"
  cp "$D/$f" "$BAK/$f" 2>/dev/null && log "backed up modified $f -> $BAK/$f"
  git -C "$D" checkout -- "$f"
done

# 2. Untracked files that origin/main would overwrite: back up, then remove.
git -C "$D" ls-tree -r --name-only origin/main | while read -r f; do
  [ -n "$f" ] || continue
  if [ -e "$D/$f" ] && ! git -C "$D" ls-files --error-unmatch "$f" >/dev/null 2>&1; then
    mkdir -p "$BAK/$(dirname "$f")"
    cp "$D/$f" "$BAK/$f" 2>/dev/null && log "backed up untracked $f -> $BAK/$f"
    rm "$D/$f"
  fi
done

# 3. Tree is clean now; pull.
if git -C "$D" pull --ff-only; then
  log "OK HEAD $(git -C "$D" rev-parse --short HEAD) backup=$BAK"
else
  log "FAIL pull (backup kept at $BAK)"
  exit 1
fi
