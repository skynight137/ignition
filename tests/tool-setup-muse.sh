#!/usr/bin/env bash
# tool-setup-muse.sh — CI driver: install ONE setup.sh tool lane on a Muse VM
# into an isolated root and verify it with setup's own doctor.
#
#   MUSE_ROOT=<dir> bash tests/tool-setup-muse.sh <flag> <doctor-label>
#
# The lanes read XDG_* + $HOME, so point ALL of them at a scratch root and
# the install stays isolated (same trick as the repl driver's SETUP_ROOT,
# but muse has no root resolver — XDG/HOME *are* the roots).
#
# The doctor is the oracle on purpose: it already knows every tool's
# expected path and runs each binary's version probe, so a ✓ line for
# the label means "installed AND executes" without this script keeping
# a second, drifting copy of the path/probe table. A label whose line
# still says NOT FOUND / not installed fails the leg.
#
# The install log is kept and tailed on failure so a red leg shows the
# lane's own error, not just the doctor's verdict.
#
# NEVER run this with a real $HOME: lanes install for real (node 26,
# rclone, ollama...). Scratch root only, on muse-hop; e2e on muse-test
# uses real XDG.
set -u
flag="${1:?usage: tool-setup-muse.sh <setup-flag> <doctor-label>}"
label="${2:?usage: tool-setup-muse.sh <setup-flag> <doctor-label>}"
: "${MUSE_ROOT:?MUSE_ROOT must name the isolated install root}"

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
setup_sh="$repo_root/scripts/setup.sh"
log="${RUNNER_TEMP:-/tmp}/install-muse-${label//[^A-Za-z0-9]/_}.log"

# GNU timeout is absent on macOS (gtimeout lives in coreutils); fall
# back to the job-level timeout there rather than failing every leg.
TIMEOUT_BIN=""
for c in timeout gtimeout; do
  if command -v "$c" >/dev/null 2>&1; then TIMEOUT_BIN="$c"; break; fi
done

# Scratch the whole identity: HOME (HERMES_HOME, ~/.ssh, ~/.config/stack),
# all five XDG roots, and the muse wire target (MUSE_ENV_FILE) — the lanes
# and the rc writer then see only the scratch tree.
export HOME="$MUSE_ROOT"
export XDG_CONFIG_HOME="$MUSE_ROOT/.config"
export XDG_CACHE_HOME="$MUSE_ROOT/.cache"
export XDG_DATA_HOME="$MUSE_ROOT/.local/share"
export XDG_STATE_HOME="$MUSE_ROOT/.local/state"
export XDG_BIN_HOME="$MUSE_ROOT/.local/bin"
export MUSE_ENV_FILE="$MUSE_ROOT/env.sh"
export PATH="$XDG_BIN_HOME:$PATH"

echo "== install: setup.sh --machine muse $flag (root: $MUSE_ROOT) =="
if ! ${TIMEOUT_BIN:+$TIMEOUT_BIN "${TOOL_TIMEOUT:-1200}"} bash "$setup_sh" --machine muse "$flag" </dev/null >"$log" 2>&1; then
  echo "FAIL: install step exited non-zero; last 40 log lines:"
  tail -40 "$log"
  exit 1
fi
tail -5 "$log"

echo "== doctor check: $label =="
doctor_out="$(bash "$setup_sh" --machine muse --doctor </dev/null 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')"
line="$(printf '%s\n' "$doctor_out" | grep -F "$label" | head -1 || true)"
if [[ -z "$line" ]]; then
  echo "FAIL: doctor printed no line for '$label'"
  printf '%s\n' "$doctor_out" | tail -30
  exit 1
fi
echo "$line"
if printf '%s' "$line" | grep -qE "NOT FOUND|not installed|FAILED to run"; then
  echo "FAIL: doctor still reports $label missing after install"
  exit 1
fi
echo "PASS: $label installed and verified by doctor"
