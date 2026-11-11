#!/usr/bin/env bash
# tour.sh — launcher for tour.py, the SHARED tour (scripts/ root —
# a ready-to-run script, NOT part of setup; --machine muse|repl).
# It exists ONLY to do the env assembly the
# program cannot do for itself:
#   1. (nix boxes only — repl) the tour venv's greenlet needs
#      libstdc++.so.6, which on a Replit box lives in the nix store,
#      and LD_LIBRARY_PATH must be exported BEFORE python starts (the
#      running interpreter's loader will not pick it up afterwards).
#      The assembly runs ONLY when a nix store exists; on a muse box
#      there is none and the step is skipped entirely;
#   2. it resolves WHICH python runs the tour (the venv the setup
#      entry created under $LIGHTPANDA_HOME, falling back to a PATH
#      python3) and the managed engine home, so a workflow/Run-button
#      shell needs no sourcing first;
#   3. NOTHING for the local Playwright engines' lib closure —
#      tour.py scopes that to the browser process alone (the
#      driver Node in this tree must never see the nix glibc).
# All tour logic lives in tour.py; this file adds no behaviour of its
# own — --browser/--machine and every other arg pass straight through.
# (Same justified-shim shape as the camofox-mcp wrapper: env assembly
# for a caller that gets none.)
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"

LIGHTPANDA_HOME="${LIGHTPANDA_HOME:-${XDG_CONFIG_HOME:-${REPL_HOME:-$HOME}/.config}/lightpanda}"
export LIGHTPANDA_HOME

if [ -d /nix/store ]; then
  LIB=$(ls /nix/store/*gcc*lib*/lib/libstdc++.so.6 2>/dev/null | head -1)
  [ -n "$LIB" ] && export LD_LIBRARY_PATH="$(dirname "$LIB")${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

# Local Playwright engines (patchright / cloakbrowser): their
# Chromium loads only under a matched nix ld.so/glibc pair plus a
# closure of store lib dirs — but that closure must reach the
# BROWSER PROCESS ONLY, never this process tree: the Playwright
# driver is a foreign-interp Node binary, and the nix glibc in a
# shared LD_LIBRARY_PATH kills it with the same GLIBC_PRIVATE
# error (the generate-closure.sh regression, re-proven on repl-30
# 2026-11-07). tour.py therefore reads <engine home>/closure.txt
# itself and passes it via Playwright's per-launch env. Nothing
# for this shell to do.

if [ -x "$LIGHTPANDA_HOME/venv/bin/python" ]; then
  PY="$LIGHTPANDA_HOME/venv/bin/python"
elif command -v python3 >/dev/null 2>&1; then
  PY="$(command -v python3)"
else
  echo "tour: no python found — run: bash $D/setup.sh --lightpanda" >&2
  exit 1
fi
exec "$PY" -u "$D/tour.py" "$@"
