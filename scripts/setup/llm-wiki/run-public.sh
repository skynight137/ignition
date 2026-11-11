#!/usr/bin/env bash
# Supervisor for the llm-wiki stack. One loop, restarts whatever died:
#   Xvfb + window manager (only when there is no usable display)
#   the desktop app (it dies with "Failed to initialize GTK" when its X server goes)
#   the node server: a public port (token required) and a loopback port (token-free
#   for same-machine agents).
#
#   bash run-public.sh
#
# Node.js is the only runtime dependency for the server part; the app part needs an
# X display (real desktop, or Xvfb + a window manager).
# Overridable: LLM_WIKI_PORT(80 -> https://$REPLIT_DEV_DOMAIN/mcp tanpa sufiks) LLM_WIKI_LOCAL_PORT(8199) LLM_WIKI_DISPLAY(:99)
#              LLM_WIKI_PROJECT(default <app dir>/project) LLM_WIKI_APP_DIR LLM_WIKI_ENV_FILE
[ -r /run/replit/env/latest ] && . /run/replit/env/latest   # workflow shells source no rc
# env/latest is regenerated and can lag, so pin the roots ourselves: a bare ssh or
# workflow shell would otherwise resolve REPL_HOME/XDG to $HOME (wiped on recreate).
REPL_HOME="${REPL_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
export REPL_HOME
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$REPL_HOME/.config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$REPL_HOME/.local/share}"
set -uo pipefail
APP="${LLM_WIKI_APP_DIR:-$(cd "$(dirname "$0")" && pwd)}"
ENV_FILE="${LLM_WIKI_ENV_FILE:-$APP/.env}"
# instalasi lama menyimpan token di llmwiki.env; pakai itu selama .env belum ada
if [ -z "${LLM_WIKI_ENV_FILE:-}" ] && [ ! -f "$ENV_FILE" ] && [ -f "$APP/llmwiki.env" ]; then
  ENV_FILE="$APP/llmwiki.env"
fi
# port (dan kredensial) ikut .env supaya restart jarak jauh tak perlu env manual
if [ -f "$ENV_FILE" ]; then set -a; . "$ENV_FILE"; set +a; fi
PORT="${LLM_WIKI_PORT:-80}"

# Replit merouting port hanya kalau sudah terdaftar, dan registry itu ditulis platform —
# bukan .replit. Satu GET lewat dev-domain sudah cukup untuk memicu pendaftaran; ulangi
# sebentar karena entri bisa belum hidup di percobaan pertama. Best-effort: box non-Replit
# tak punya REPLIT_DEV_DOMAIN dan tak ada yang perlu didaftarkan.
register_public_port() {
  [ -n "${REPLIT_DEV_DOMAIN:-}" ] || return 0
  local i
  for i in 1 2 3 4 5; do
    if curl -fsS -m 4 -o /dev/null "https://$REPLIT_DEV_DOMAIN:$PORT/health" 2>/dev/null; then
      log "port $PORT registered on https://$REPLIT_DEV_DOMAIN:$PORT/"
      return 0
    fi
    sleep 3
  done
  log "warn: port $PORT belum ter-routing lewat dev-domain (buka https://$REPLIT_DEV_DOMAIN:$PORT/ sekali di browser)"
}
LOCAL_PORT="${LLM_WIKI_LOCAL_PORT:-8199}"
DISP="${LLM_WIKI_DISPLAY:-:99}"
# wiki menempel di direktori app supaya app+wiki terhapus sekaligus; arahkan
# LLM_WIKI_PROJECT kalau mau proyek lain. Semua request MCP menerima `project` juga.
PROJECT="${LLM_WIKI_PROJECT:-$APP/project}"
mkdir -p "$PROJECT/wiki"
APP_PORT=19828
CLIP_PORT=19827
SLEEP=15

port_open() { (exec 3<>/dev/tcp/127.0.0.1/"$1") >/dev/null 2>&1; }
log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

if [ -f "$ENV_FILE" ]; then set -a; . "$ENV_FILE"; set +a; fi
[ -n "${LLM_WIKI_API_TOKEN:-}" ] || log "warning: LLM_WIKI_API_TOKEN empty ($ENV_FILE) — public port will refuse clients"

start_display() {
  # A socket file lies: a crashed Xvfb leaves /tmp/.X11-unix/X99 behind, so the old
  # `[ -S ... ] && return 0` skipped the restart and the app died with
  # "Failed to initialize GTK". Require a live Xvfb for this display, not just the file.
  if [ -S "/tmp/.X11-unix/X${DISP#:}" ] && pgrep -f "Xvfb ${DISP} " >/dev/null; then return 0; fi
  have Xvfb || { log "no Xvfb and no X display — on a desktop set LLM_WIKI_DISPLAY"; return 1; }
  rm -f "/tmp/.X11-unix/X${DISP#:}" "/tmp/.X${DISP#:}-lock"
  Xvfb "$DISP" -screen 0 1600x1000x24 +extension GLX +extension RANDR +render -noreset >/tmp/xvfb.log 2>&1 &
  for _ in $(seq 1 10); do [ -S "/tmp/.X11-unix/X${DISP#:}" ] && break; sleep 1; done
  log "Xvfb started on $DISP"
  DISPLAY_RESTARTED=1
}

start_wm() {
  # without a WM, GTK/tao windows are created but never mapped
  local wm
  # A WM left over from the previous (dead) display holds no window and blocks the
  # `pgrep` guard below, so drop it when we just rebuilt the display.
  [ "${DISPLAY_RESTARTED:-0}" = 1 ] && pkill -x fluxbox 2>/dev/null
  for wm in fluxbox openbox icewm matchbox-window-manager twm; do
    have "$wm" || continue
    pgrep -x "$wm" >/dev/null && return 0
    DISPLAY="$DISP" "$wm" >/tmp/wm.log 2>&1 &
    sleep 2
    log "$wm started"
    return 0
  done
  log "no window manager found — the app window may stay unmapped"
}

start_app() {
  port_open "$APP_PORT" && return 0
  LLM_WIKI_DISPLAY="$DISP" "$APP/start-app.sh" >"$APP/run-live.log" 2>&1 &
  for _ in $(seq 1 40); do port_open "$APP_PORT" && break; sleep 1; done
  port_open "$APP_PORT" && log "app api up ($APP_PORT)" || log "app api FAILED (see run-live.log)"
}

assert_project() {
  # the app keeps the current project in memory only; re-assert it every pass so a
  # restarted app (or a dropped clip server) never leaves "current" unset
  curl -s -m 5 -X POST -H 'Content-Type: application/json' \
    -d "{\"path\":\"$PROJECT\"}" "http://127.0.0.1:$CLIP_PORT/project" >/dev/null 2>&1
}

start_public_server() {
  port_open "$PORT" && return 0
  LLM_WIKI_PORT="$PORT" LLM_WIKI_PROJECT="$PROJECT" \
  LLM_WIKI_BIND_HOST="${LLM_WIKI_BIND_HOST:-$ANY_HOST}" \
    node "$APP/llmwiki-server.js" >"$APP/server-live.log" 2>&1 &
  for _ in $(seq 1 15); do port_open "$PORT" && break; sleep 1; done
  if port_open "$PORT"; then
    log "public server up ($PORT, token required)"
    register_public_port
  else
    log "public server FAILED (see server-live.log)"
  fi
}

start_local_server() {
  # loopback-only instance, so same-machine agents need no secret in their config
  port_open "$LOCAL_PORT" && return 0
  LLM_WIKI_PORT="$LOCAL_PORT" LLM_WIKI_BIND_HOST=127.0.0.1 LLM_WIKI_TRUST_LOOPBACK=1 \
  LLM_WIKI_PROJECT="$PROJECT" \
    node "$APP/llmwiki-server.js" >"$APP/server-local.log" 2>&1 &
  for _ in $(seq 1 10); do port_open "$LOCAL_PORT" && break; sleep 1; done
  port_open "$LOCAL_PORT" && log  "local server up ($LOCAL_PORT, loopback, no token)" || log "local server FAILED"
}

# wrapper display (Xvfb/fluxbox) dan node tinggal di REPL_HOME/.local/bin + .local/share/node
[[ -n "${REPL_HOME:-}" ]] && PATH="$PATH:$REPL_HOME/.local/bin:$REPL_HOME/.local/share/node/bin"
[[ -n "${REPL_HOME:-}" ]] && export PATH
have node || { echo "node is required (the server part needs nothing else)" >&2; exit 1; }
# The managed node build wants libatomic/libstdc++ from the toolchain dir; a bare shell
# (ssh, systemd, cron) has no LD_LIBRARY_PATH and node dies "libatomic.so.1: cannot open".
for _d in "${REPL_HOME:-}/.local/lib" "$HOME/workspace/.local/lib" "$HOME/.local/lib"; do
  case "${LD_LIBRARY_PATH:-}" in *"$_d"*) continue ;; esac
  [ -d "$_d" ] && LD_LIBRARY_PATH="$_d${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH:-}}"
done
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
ANY=0; ANY_HOST="${ANY}.${ANY}.${ANY}.${ANY}"
# Workflow-console hygiene (skill-wide rule, references/exposing-ports.md):
# when stdout is not a TTY (a .replit workflow or agent run), print a short
# summary to the console, then send the supervisor's own output to a log
# file in the persistent workspace. A supervisor loop streaming into the
# workflow terminal grows the console without bound and hangs the Replit
# UI; the file stays diagnosable. Interactive terminal runs keep the
# console. The supervised children already log to files under $APP.
LOG_FILE="${LLM_WIKI_LOG_FILE:-$REPL_HOME/logs/llm-wiki-public.log}"
if [ ! -t 1 ]; then
  mkdir -p "$(dirname "$LOG_FILE")"
  log "llm-wiki public supervisor: public=:$PORT local=:$LOCAL_PORT project=$PROJECT"
  log "  full log: $LOG_FILE"
  exec >>"$LOG_FILE" 2>&1
  log "supervisor output redirected from console $(date -Is)"
fi
log "supervisor start: app=$APP_PORT public=$PORT local=$LOCAL_PORT project=$PROJECT"
while true; do
  start_display; start_wm; start_app; assert_project; start_public_server; start_local_server
  sleep "$SLEEP"
done
