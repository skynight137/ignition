# shellcheck shell=bash
# beacon-watchdog.sh — supervisor for beacon-loop.sh (node stats beacon).
#
# The beacon loop dies silently: a hard kill (SIGKILL, container stop)
# leaves a stale pidfile and no error line — the loop itself never exits
# on a post failure (it logs WARN and keeps looping), so a dead loop is
# always an external kill. On 2026-11-14 a tailscale relay flap killed
# 14 loops in one evening and every one had to be healed from outside.
# This loop keeps the beacon alive instead: it checks every
# BEACON_WATCHDOG_CHECK_S (default 60) and restarts the loop when it is
# dead OR when it is alive but has stopped posting (repl-44, 2026-11-14:
# loop alive, no beacon for ~7 min — blocked inside a hung tsbeacon
# post). Started detached by the join lane (setup/join-repl.sh) once
# tailscaled is up; a workspace stop kills it with everything else and
# the next boot's join starts it again.
#
# Dedup: a pidfile in the workspace beacon-watchdog dir; a second start
# while a live watchdog holds it exits quietly. The loop itself is also
# deduped by its own pidfile, so a watchdog restart never doubles the
# loop. Config is big-env (system env wins, no .env is read here):
# BEACON_WATCHDOG_CHECK_S, BEACON_WATCHDOG_STALE_S,
# BEACON_WATCHDOG_LOG, BEACON_INTERVAL_S (for the stale default).
set -u

WS="${REPL_HOME:-$HOME/workspace}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd)"
LOOP="${BEACON_LOOP:-$SELF_DIR/beacon-loop.sh}"
CHECK_S="${BEACON_WATCHDOG_CHECK_S:-60}"
INTERVAL="${BEACON_INTERVAL_S:-300}"
STALE_S="${BEACON_WATCHDOG_STALE_S:-$((2 * INTERVAL))}"
STATE_DIR="$WS/.config/beacon-watchdog"
PIDFILE="$STATE_DIR/loop.pid"
LOOP_PIDFILE="$WS/.config/beacon/loop.pid"
BEACON_LOG="${BEACON_LOG:-$WS/.local/state/beacon.log}"
LOG="${BEACON_WATCHDOG_LOG:-$WS/.local/state/beacon-watchdog.log}"

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

# A stale threshold at or below the loop interval would restart a healthy
# loop on every check — the log only refreshes once per interval, so the
# age is 0..INTERVAL between posts. Clamp it to 2x the interval and say
# so (this exact misconfiguration restarted a healthy loop 4x in 6 min
# during the repl-48 pilot, 2026-11-14).
if [ "$STALE_S" -le "$INTERVAL" ]; then
  log WARN "stale=${STALE_S}s <= interval=${INTERVAL}s — clamping to $((2 * INTERVAL))s"
  STALE_S=$((2 * INTERVAL))
fi

# Keep the log bounded: rotate once at start when it outgrows ~1 MB.
if [ -f "$LOG" ] && [ "$(wc -c <"$LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then
  mv "$LOG" "$LOG.1" 2>/dev/null || true
fi

# A recycled pid is not the loop: confirm the cmdline before trusting it
# (kill -0 alone lies — repl-10's pid 407 was the camofox browser).
is_loop() {
  [ -n "${1:-}" ] && [ -f "/proc/$1/cmdline" ] \
    && tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | grep -q 'beacon-loop'
}

# The loop was started with setsid, so it is a session leader and its
# process group id equals its pid — killing the group also gets a hung
# tsbeacon child stuck in a post. If it is not a session leader (manual
# start), kill only the pid itself.
kill_loop() {
  _pid="$1"
  if [ "$(ps -o sid= -p "$_pid" 2>/dev/null | tr -d ' ')" = "$_pid" ]; then
    kill -TERM "-$_pid" 2>/dev/null || kill -TERM "$_pid" 2>/dev/null || true
  else
    kill -TERM "$_pid" 2>/dev/null || true
  fi
  sleep 5
  if kill -0 "$_pid" 2>/dev/null; then
    if [ "$(ps -o sid= -p "$_pid" 2>/dev/null | tr -d ' ')" = "$_pid" ]; then
      kill -KILL "-$_pid" 2>/dev/null || kill -KILL "$_pid" 2>/dev/null || true
    else
      kill -KILL "$_pid" 2>/dev/null || true
    fi
    sleep 2
  fi
}

restart_loop() {
  _reason="$1"
  _old="$(cat "$LOOP_PIDFILE" 2>/dev/null || true)"
  if is_loop "$_old"; then
    kill_loop "$_old"
  fi
  rm -f "$LOOP_PIDFILE"
  if [ ! -x "$LOOP" ]; then
    log ERROR "loop missing or not executable: $LOOP"
    return 1
  fi
  if command -v setsid >/dev/null 2>&1; then
    setsid nohup bash "$LOOP" >>"$WS/.local/state/beacon-loop.out" 2>&1 </dev/null &
  else
    nohup bash "$LOOP" >>"$WS/.local/state/beacon-loop.out" 2>&1 </dev/null &
  fi
  disown 2>/dev/null || true
  sleep 4
  _new="$(cat "$LOOP_PIDFILE" 2>/dev/null || true)"
  if is_loop "$_new"; then
    log INFO "loop (re)started pid=$_new reason=$_reason"
  else
    log ERROR "loop restart FAILED reason=$_reason newpid=${_new:-none}"
    tail -3 "$WS/.local/state/beacon-loop.out" 2>/dev/null | while IFS= read -r _l; do log ERROR "  $_l"; done
  fi
}

log INFO "beacon-watchdog start pid=$$ check=${CHECK_S}s stale=${STALE_S}s loop=$LOOP"
while true; do
  now="$(date +%s)"
  loop_pid="$(cat "$LOOP_PIDFILE" 2>/dev/null || true)"
  if ! is_loop "$loop_pid"; then
    restart_loop "dead pid=${loop_pid:-none}"
  elif [ ! -f "$BEACON_LOG" ]; then
    restart_loop "no-beacon-log pid=$loop_pid"
  else
    mtime="$(stat -c %Y "$BEACON_LOG" 2>/dev/null || echo 0)"
    age=$((now - mtime))
    if [ "$age" -gt "$STALE_S" ]; then
      restart_loop "stale-beacon age=${age}s pid=$loop_pid"
    fi
  fi
  sleep "$CHECK_S"
done
