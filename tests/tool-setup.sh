#!/usr/bin/env bash
# tool-setup.sh — CI driver: install ONE setup.sh tool lane into an
# isolated root and verify it with setup's own doctor.
#
#   SETUP_ROOT=<dir> bash tests/tool-setup.sh <flag> <doctor-label>
#
# The doctor is the oracle on purpose: it already knows every tool's
# expected path and runs each binary's version probe, so a ✓ line for
# the label means "installed AND executes" without this script keeping
# a second, drifting copy of the path/probe table. A label whose line
# still says NOT FOUND / not installed fails the leg.
#
# The install log is kept and tailed on failure so a red leg shows the
# lane's own error, not just the doctor's verdict.
set -u
flag="${1:?usage: tool-setup.sh <setup-flag> <doctor-label>}"
label="${2:?usage: tool-setup.sh <setup-flag> <doctor-label>}"
: "${SETUP_ROOT:?SETUP_ROOT must name the isolated install root}"

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
setup_sh="$repo_root/scripts/setup.sh"
log="${RUNNER_TEMP:-/tmp}/install-${label//[^A-Za-z0-9]/_}.log"

# GNU timeout is absent on macOS (gtimeout lives in coreutils); fall
# back to the job-level timeout there rather than failing every leg.
TIMEOUT_BIN=""
for c in timeout gtimeout; do
  if command -v "$c" >/dev/null 2>&1; then TIMEOUT_BIN="$c"; break; fi
done

echo "== install: setup.sh $flag (root: $SETUP_ROOT) =="
if ! ${TIMEOUT_BIN:+$TIMEOUT_BIN "${TOOL_TIMEOUT:-1200}"} bash "$setup_sh" --machine repl "$flag" </dev/null >"$log" 2>&1; then
  echo "FAIL: install step exited non-zero; last 40 log lines:"
  tail -40 "$log"
  exit 1
fi
tail -5 "$log"

echo "== doctor check: $label =="
doctor_out="$(bash "$setup_sh" --machine repl --doctor </dev/null 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')"
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
