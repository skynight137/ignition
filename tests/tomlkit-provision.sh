#!/usr/bin/env bash
# tomlkit-provision.sh — CI driver: prove setup provisions its own
# tomlkit-capable python on a box that has none (the fresh-box case that
# used to lose the REPLIT_BASHRC pin to a warning + return 0).
#
#   SETUP_ROOT=<dir> bash tests/tomlkit-provision.sh
#
# The runner is the simulation: its PATH python3 carries no tomlkit and
# no uv is installed, and every XDG var is unset so all state (uv, the
# provisioned venv, the shim) must land inside the isolated root.
# Assertions are on outcomes, not on which resolution step fired:
#   1. after `--fix`, the REPLIT_BASHRC pin is in .replit [userenv.shared]
#      exactly once and the operator's own key survived;
#   2. --doctor's `toml python:` line names a real source (not "none");
#   3. a second `--fix` is idempotent — still exactly one pin.
set -u
: "${SETUP_ROOT:?SETUP_ROOT must name the isolated install root}"

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
setup_sh="$repo_root/scripts/setup.sh"
log="${RUNNER_TEMP:-/tmp}/tomlkit-provision.log"

unset XDG_DATA_HOME XDG_BIN_HOME XDG_CONFIG_HOME XDG_STATE_HOME XDG_CACHE_HOME
export HOME="$SETUP_ROOT/home"
mkdir -p "$SETUP_ROOT" "$HOME"
printf '[userenv.shared]\nNODE_ENV = "production"\n' > "$SETUP_ROOT/.replit"

pin_count() { grep -c '^REPLIT_BASHRC' "$SETUP_ROOT/.replit" || true; }

echo "== fix run 1: setup.sh --fix (root: $SETUP_ROOT) =="
# A bare root's end-of-run doctor reports every uninstalled tool, so the
# exit code is not the oracle here — the pin is.
bash "$setup_sh" --machine repl --fix </dev/null >"$log" 2>&1 || true
grep -E 'tomlkit|REPLIT_BASHRC|uv installed' "$log" || true
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

echo "== doctor check: toml python =="
doctor_out="$(bash "$setup_sh" --machine repl --doctor </dev/null 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')"
line="$(printf '%s\n' "$doctor_out" | grep -F 'toml python:' | head -1 || true)"
echo "${line:-<no toml python line>}"
if [[ -z "$line" ]] || printf '%s' "$line" | grep -q 'none tomlkit-capable'; then
  echo "FAIL: doctor does not name a resolved toml python"
  exit 1
fi

echo "== fix run 2: idempotency =="
bash "$setup_sh" --machine repl --fix </dev/null >>"$log" 2>&1 || true
if [[ "$(pin_count)" != 1 ]]; then
  echo "FAIL: pin count after second --fix is $(pin_count), expected 1"
  exit 1
fi
echo "PASS: tomlkit provisioned by setup; REPLIT_BASHRC pin landed and is idempotent"
