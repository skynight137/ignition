# shellcheck shell=bash
# crash-shim-loop.sh — supervisor for crash-shim.py (camofox crash-reporter
# loopback receiver).
#
# The shim is a long-running loopback HTTP server (127.0.0.1:18099): the
# camofox server POSTs its crash/hang/stuck-loop reports to it, and the
# shim forwards each one to the CC on muse-hop over `tailscale nc`. This
# loop only keeps the shim alive — it starts it when no live shim holds
# the pidfile and restarts it when it dies, checking every
# CRASH_SHIM_CHECK_S (default 60). Started detached by the join lane
# (setup/join-repl.sh) once tailscaled is up; a workspace stop kills it
# with everything else and the next boot's join starts it again.
#
# Dedup: a pidfile in the workspace crash-shim dir; a second start while
# a live loop holds it exits quietly. The shim itself is also deduped by
# its own pidfile, so a loop restart never doubles the server. Config is
# big-env (system env wins, no .env is read here): CRASH_SHIM_CHECK_S,
# CRASH_SHIM_LOG, CRASH_SHIM_PY.
set -u

WS="${REPL_HOME:-$HOME/workspace}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd)"
SHIM_PY="${CRASH_SHIM_PY:-$SELF_DIR/crash-shim.py}"
CHECK_S="${CRASH_SHIM_CHECK_S:-60}"
STATE_DIR="$WS/.config/crash-shim"
PIDFILE="$STATE_DIR/loop.pid"
SHIM_PIDFILE="$STATE_DIR/shim.pid"
LOG="${CRASH_SHIM_LOG:-$WS/.local/state/crash-shim-loop.log}"

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

# The box's python: the ctls build first (what the tour uses), then PATH.
find_python() {
  local p
  p="$(ls /repl/ctls/*/bin/python3 2>/dev/null | head -1)"
  [ -n "${p:-}" ] && [ -x "$p" ] && { printf '%s' "$p"; return 0; }
  command -v python3 2>/dev/null
}

log INFO "crash-shim-loop start pid=$$ check=${CHECK_S}s shim=$SHIM_PY"
while true; do
  alive=0
  if [ -f "$SHIM_PIDFILE" ]; then
    shim_pid="$(cat "$SHIM_PIDFILE" 2>/dev/null || true)"
    if [ -n "${shim_pid:-}" ] && kill -0 "$shim_pid" 2>/dev/null; then
      # A recycled pid is not a shim: confirm the cmdline before trusting it.
      if [ -r "/proc/$shim_pid/cmdline" ]; then
        tr '\0' ' ' <"/proc/$shim_pid/cmdline" 2>/dev/null | grep -q 'crash-shim.py' && alive=1
      else
        alive=1
      fi
    fi
  fi
  if [ "$alive" -eq 0 ]; then
    if [ -f "$SHIM_PY" ]; then
      py="$(find_python)"
      if [ -n "${py:-}" ]; then
        setsid nohup "$py" "$SHIM_PY" >"$WS/.local/state/crash-shim.out" 2>&1 </dev/null &
        log INFO "shim (re)started"
      else
        log ERROR "no python3 found for crash-shim.py"
      fi
    else
      log ERROR "shim missing or not readable: $SHIM_PY"
    fi
  fi
  sleep "$CHECK_S"
done
