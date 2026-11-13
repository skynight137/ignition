#!/usr/bin/env bash
# dotreplit-pin.sh — CI driver: prove the REPLIT_BASHRC pin lands via the
# stdlib-only dotreplit.py on a box that has no tomlkit and no uv (the
# fresh-box case that used to need setup to provision a tomlkit venv + uv).
#
#   SETUP_ROOT=<dir> bash tests/dotreplit-pin.sh
#
# The runner is the simulation: its PATH python3 carries no tomlkit and
# no uv is installed, and every XDG var is unset so all state must land
# inside the isolated root — and nothing may be provisioned from the
# network (no uv download, no tomlkit install). Assertions are on
# outcomes, not on which resolution step fired:
#   1. after `--fix`, the REPLIT_BASHRC pin is in .replit [userenv.shared]
#      exactly once and the operator's own key survived;
#   2. --doctor's `dotreplit writer:` line names a python3 (not "none");
#   3. no tomlkit provisioning was attempted anywhere in the log;
#   4. a second `--fix` is idempotent — still exactly one pin.
set -u
: "${SETUP_ROOT:?SETUP_ROOT must name the isolated install root}"

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
setup_sh="$repo_root/scripts/setup.sh"
log="${RUNNER_TEMP:-/tmp}/dotreplit-pin.log"

unset XDG_DATA_HOME XDG_BIN_HOME XDG_CONFIG_HOME XDG_STATE_HOME XDG_CACHE_HOME
export HOME="$SETUP_ROOT/home"
mkdir -p "$SETUP_ROOT" "$HOME"
printf '[userenv.shared]\nNODE_ENV = "production"\n' > "$SETUP_ROOT/.replit"

pin_count() { grep -c '^REPLIT_BASHRC' "$SETUP_ROOT/.replit" || true; }

echo "== fix run 1: setup.sh --fix (root: $SETUP_ROOT) =="
# A bare root's end-of-run doctor reports every uninstalled tool, so the
# exit code is not the oracle here — the pin is.
bash "$setup_sh" --machine repl --fix </dev/null >"$log" 2>&1 || true
grep -E 'REPLIT_BASHRC|dotreplit' "$log" || true
if [[ "$(pin_count)" != 1 ]]; then
  echo "FAIL: REPLIT_BASHRC pin did not land exactly once; .replit is:"
  cat "$SETUP_ROOT/.replit"
  tail -40 "$log"
  exit 1
fi
grep -q '^NODE_ENV = "production"' "$SETUP_ROOT/.replit" || {
  echo "FAIL: operator key NODE_ENV lost from .replit"
  exit 1
}

echo "== doctor check: dotreplit writer =="
doctor_out="$(bash "$setup_sh" --machine repl --doctor </dev/null 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')"
line="$(printf '%s\n' "$doctor_out" | grep -F 'dotreplit writer:' | head -1 || true)"
echo "${line:-<no dotreplit writer line>}"
if [[ -z "$line" ]] || printf '%s' "$line" | grep -q 'no python3'; then
  echo "FAIL: doctor does not name a dotreplit writer python"
  exit 1
fi

echo "== no tomlkit provisioning =="
if grep -qi 'tomlkit' "$log"; then
  echo "FAIL: tomlkit referenced in the log (provisioning not fully removed):"
  grep -in 'tomlkit' "$log" | head -5
  exit 1
fi

echo "== fix run 2: idempotency =="
bash "$setup_sh" --machine repl --fix </dev/null >>"$log" 2>&1 || true
if [[ "$(pin_count)" != 1 ]]; then
  echo "FAIL: pin count after second --fix is $(pin_count), expected 1"
  exit 1
fi
echo "PASS: REPLIT_BASHRC pin landed via dotreplit.py (stdlib, no tomlkit, no uv) and is idempotent"
