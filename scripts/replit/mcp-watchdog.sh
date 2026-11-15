# shellcheck shell=bash
# mcp-watchdog.sh — supervisor for the per-node MCP server (repl-mcp-server.mjs).
#
# The MCP server has no keeper of its own: a workspace sleep, a SIGKILL, or a
# hung event loop kills it (or wedges it) and it stays down until someone
# restarts it by hand. The pilot (repl-110, 2026-11-15) proved exactly that
# failure mode is the one that matters — the server itself never crashed,
# it just had nothing watching it. This loop keeps it alive instead: it
# checks every MCP_WATCHDOG_CHECK_S (default 60) and restarts the server
# when its process is dead OR when its /health stops answering.
# Started detached by the join lane (setup/join-repl.sh) once tailscaled
# is up; a workspace stop kills it with everything else and the next
# boot's join starts it again.
#
# Layout: the server file lives in this repo (scripts/replit/mcp-server.mjs)
# but is NEVER run from the repo path — it writes logs/ beside itself, and
# an untracked logs/ dir inside the repo would block the next git pull
# (the 2026-11-15 pull-fix lesson). The watchdog keeps a runtime copy in
# $WS/.local/share/repl-mcp/ (verified byte-identical by sha256 before
# every start) and runs node from there, so logs stay out of the repo.
#
# Dedup: a pidfile in the workspace repl-mcp dir; a second start while a
# live watchdog holds it exits quietly. The server itself is also deduped:
# the watchdog adopts a server that is already listening on the port
# (pidfile missing, e.g. a pilot or manual start) instead of starting a
# second one — two servers cannot share 127.0.0.1:16810. Config is big-env
# (system env wins, no .env is read here): MCP_WATCHDOG_CHECK_S,
# MCP_PORT, MCP_WATCHDOG_LOG.
set -u

WS="${REPL_HOME:-$HOME/workspace}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd)"
SERVER_SRC="${MCP_SERVER_SRC:-$SELF_DIR/mcp-server.mjs}"
PORT="${MCP_PORT:-16810}"
CHECK_S="${MCP_WATCHDOG_CHECK_S:-60}"
RUNTIME_DIR="$WS/.local/share/repl-mcp"
SERVER_FILE="$RUNTIME_DIR/mcp-server.mjs"
STATE_DIR="$WS/.config/repl-mcp"
PIDFILE="$STATE_DIR/server.pid"
WD_PIDFILE="$STATE_DIR/watchdog.pid"
LOG="${MCP_WATCHDOG_LOG:-$WS/.local/state/repl-mcp-watchdog.log}"

log() { printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >>"$LOG" 2>/dev/null || true; }

mkdir -p "$STATE_DIR" "$RUNTIME_DIR/logs" "$(dirname "$LOG")"

if [ -f "$WD_PIDFILE" ]; then
  old_pid="$(cat "$WD_PIDFILE" 2>/dev/null || true)"
  if [ -n "${old_pid:-}" ] && kill -0 "$old_pid" 2>/dev/null; then
    exit 0
  fi
fi
printf '%s\n' "$$" >"$WD_PIDFILE"
trap 'rm -f "$WD_PIDFILE"' EXIT

# Keep the logs bounded: rotate once at start when either outgrows ~1 MB.
for _f in "$LOG" "$RUNTIME_DIR/logs/exec.log" "$RUNTIME_DIR/logs/server.log"; do
  if [ -f "$_f" ] && [ "$(wc -c <"$_f" 2>/dev/null || echo 0)" -gt 1048576 ]; then
    mv "$_f" "$_f.1" 2>/dev/null || true
  fi
done

# A recycled pid is not the server: confirm the cmdline before trusting it.
# The cmdline alone is NOT enough — any shell whose command merely mentions
# the filename (an install payload, a grep, a test harness) matches a bare
# substring test, and the watchdog would then "adopt" a shell as its
# server (caught live on muse-hop, 2026-11-15: it adopted the exec shell
# that had run the manual start). The server is a node process, so also
# require /proc/<pid>/exe to be the node binary.
is_server() {
  local _exe
  [ -n "${1:-}" ] && [ -f "/proc/$1/cmdline" ] \
    && tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | grep -q 'mcp-server\.mjs' \
    && _exe="$(readlink "/proc/$1/exe" 2>/dev/null || true)" \
    && [ "$(basename "$_exe")" = "node" ]
}

# Find a running server without trusting any pidfile (pgrep is not
# guaranteed on these boxes; /proc is). Prints the pid or nothing.
find_server_pid() {
  local _p
  for _p in /proc/[0-9]*; do
    _p="${_p#/proc/}"
    if is_server "$_p"; then printf '%s\n' "$_p"; return 0; fi
  done
  return 1
}

resolve_node() {
  if command -v node >/dev/null 2>&1; then command -v node; return 0; fi
  if [ -x "$WS/.local/bin/node" ]; then printf '%s\n' "$WS/.local/bin/node"; return 0; fi
  return 1
}

# Best-effort: the server tolerates an empty MCP_TAILSCALE_IP (it reports
# null). The tailscale binary + socket live in different places per box,
# so probe the candidates in order.
resolve_ts_ip() {
  local _bin _sock _ip
  if command -v tailscale >/dev/null 2>&1; then _bin="$(command -v tailscale)";
  elif [ -x "$WS/.local/bin/tailscale" ]; then _bin="$WS/.local/bin/tailscale";
  else return 1; fi
  for _sock in "${TAILSCALE_SOCKET:-}" \
      "$WS/.local/state/tailscale/tailscaled.sock" \
      "$WS/.local/share/tailscale/state/tailscaled.sock" \
      "$HOME/.local/state/tailscale/tailscaled.sock"; do
    [ -S "$_sock" ] || continue
    _ip="$("$_bin" --socket="$_sock" ip -4 2>/dev/null | head -1)"
    [ -n "${_ip:-}" ] && { printf '%s\n' "$_ip"; return 0; }
  done
  return 1
}

health_ok() {
  command -v curl >/dev/null 2>&1 || return 1
  curl -sf --max-time 5 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1
}

# The server was started with setsid, so it is a session leader and its
# process group id equals its pid — killing the group also gets a hung
# exec child. If it is not a session leader (manual start), kill only
# the pid itself.
kill_server() {
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

sync_runtime() {
  if [ ! -f "$SERVER_SRC" ]; then
    log ERROR "server source missing: $SERVER_SRC"
    return 1
  fi
  _src_sha="$(sha256sum "$SERVER_SRC" 2>/dev/null | awk '{print $1}')"
  if [ -f "$SERVER_FILE" ]; then
    _cur_sha="$(sha256sum "$SERVER_FILE" 2>/dev/null | awk '{print $1}')"
    [ "$_src_sha" = "$_cur_sha" ] && return 0
  fi
  cp "$SERVER_SRC" "$SERVER_FILE" || { log ERROR "copy to runtime failed: $SERVER_SRC -> $SERVER_FILE"; return 1; }
  _cur_sha="$(sha256sum "$SERVER_FILE" 2>/dev/null | awk '{print $1}')"
  if [ "$_src_sha" != "$_cur_sha" ]; then
    log ERROR "runtime copy sha mismatch after copy: $_cur_sha != $_src_sha"
    return 1
  fi
  return 0
}

start_server() {
  _reason="$1"
  _old="$(cat "$PIDFILE" 2>/dev/null || true)"
  if is_server "$_old"; then
    kill_server "$_old"
  else
    _found="$(find_server_pid || true)"
    [ -n "${_found:-}" ] && kill_server "$_found"
  fi
  rm -f "$PIDFILE"
  if ! sync_runtime; then
    log ERROR "server start aborted reason=$_reason (runtime sync failed)"
    return 1
  fi
  _node="$(resolve_node || true)"
  if [ -z "${_node:-}" ]; then
    log ERROR "server start aborted reason=$_reason (no node binary on PATH or $WS/.local/bin)"
    return 1
  fi
  _ip="$(resolve_ts_ip || true)"
  (
    cd "$RUNTIME_DIR" || exit 1
    if [ -n "${_ip:-}" ]; then export MCP_TAILSCALE_IP="$_ip"; fi
    if command -v setsid >/dev/null 2>&1; then
      setsid nohup "$_node" "$SERVER_FILE" --port "$PORT" > logs/server.log 2>&1 </dev/null &
    else
      nohup "$_node" "$SERVER_FILE" --port "$PORT" > logs/server.log 2>&1 </dev/null &
    fi
    printf '%s\n' "$!" >"$PIDFILE"
  )
  sleep 4
  _new="$(cat "$PIDFILE" 2>/dev/null || true)"
  if is_server "$_new" && health_ok; then
    log INFO "server (re)started pid=$_new reason=$_reason ip=${_ip:-unknown}"
  else
    log ERROR "server restart FAILED reason=$_reason newpid=${_new:-none} health=$(health_ok && echo ok || echo fail)"
    tail -3 "$RUNTIME_DIR/logs/server.log" 2>/dev/null | while IFS= read -r _l; do log ERROR "  $_l"; done
  fi
}

log INFO "mcp-watchdog start pid=$$ check=${CHECK_S}s port=$PORT src=$SERVER_SRC"
while true; do
  server_pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  if ! is_server "$server_pid"; then
    if health_ok; then
      # A server is listening but the pidfile is missing or stale
      # (pilot/manual start, or the watchdog itself restarted) — adopt
      # it instead of starting a second one on the same port.
      _adopted="$(find_server_pid || true)"
      if [ -n "${_adopted:-}" ] && is_server "$_adopted"; then
        printf '%s\n' "$_adopted" >"$PIDFILE"
        log INFO "server adopted pid=$_adopted (listening, no pidfile)"
      else
        start_server "dead pid=${server_pid:-none} (listening, pid unknown)"
      fi
    else
      start_server "dead pid=${server_pid:-none}"
    fi
  elif ! health_ok; then
    start_server "unhealthy pid=$server_pid"
  fi
  sleep "$CHECK_S"
done
