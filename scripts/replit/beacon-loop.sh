# shellcheck shell=bash
# beacon-loop.sh — periodic driver for tsbeacon.sh (node stats beacon).
#
# Design: heavenly-host designs/beacon-cc.md. The one-shot tsbeacon.sh
# does the reporting; this loop only wakes it every BEACON_INTERVAL_S
# (default 300). Started detached by the join lane (setup/join-repl.sh)
# once tailscaled is up; a workspace stop kills it with everything else
# and the next boot's join starts it again. No resident interpreter —
# between runs the loop is a plain `sleep`.
#
# Dedup: a pidfile in the workspace beacon dir; a second start while a
# live loop holds it exits quietly. Config is big-env (system env wins,
# no .env is read here): BEACON_INTERVAL_S, BEACON_LOG.
set -u

WS="${REPL_HOME:-$HOME/workspace}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd)"
BEACON_SH="${BEACON_SH:-$SELF_DIR/tsbeacon.sh}"
INTERVAL="${BEACON_INTERVAL_S:-300}"
STATE_DIR="$WS/.config/beacon"
PIDFILE="$STATE_DIR/loop.pid"
LOG="${BEACON_LOG:-$WS/.local/state/beacon.log}"

log() { printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >>"$LOG" 2>/dev/null || true; }

mkdir -p "$STATE_DIR" "$(dirname "$LOG")"

if [ -f "$PIDFILE" ]; then
  old_pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [ -n "${old_pid:-}" ] && kill -0 "$old_pid" 2>/dev/null; then
    exit 0
  fi
fi
printf '%s\n' "$$" >"$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT

# Keep the log bounded: rotate once at start when it outgrows ~1 MB.
if [ -f "$LOG" ] && [ "$(wc -c <"$LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then
  mv "$LOG" "$LOG.1" 2>/dev/null || true
fi

log INFO "beacon-loop start pid=$$ interval=${INTERVAL}s one-shot=$BEACON_SH"
while true; do
  if [ -x "$BEACON_SH" ]; then
    if out="$(sh "$BEACON_SH" 2>&1)"; then
      log INFO "$out"
    else
      log WARN "$out"
    fi
  else
    log ERROR "one-shot missing or not executable: $BEACON_SH"
  fi
  sleep "$INTERVAL"
done
