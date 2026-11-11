#!/usr/bin/env bash
# Serve the llm-wiki desktop UI to a browser: Xvfb (:99) -> x11vnc (loopback) -> noVNC (public).
#
#   bash run-ui.sh            # foreground supervisor (idempotent, restarts what died)
#
# Ports:  VNC 127.0.0.1:5900 (never public) · noVNC 0.0.0.0:3000 (public, VNC password required)
# Open:   https://<host>:6080/vnc.html     (password in $STATE/vnc-password.txt)
#
# Why not expose the app directly: the frontend is Tauri (invoke), so there is no
# web UI to serve; VNC is the only way to see the real desktop window in a browser.
set -uo pipefail
APP="$(cd "$(dirname "$0")" && pwd)"
# Replit: $HOME is wiped on recreate — state must live under $REPL_HOME.
# Replit env: XDG_* and PATH live in the platform env file (/run/replit/env/latest),
# which a workflow/agent shell only sees if something sources it — no rc is sourced
# in a workflow task. Source it, then still fall back under $REPL_HOME so the state
# is persistent even when the file is missing ($HOME is wiped on recreate).
[ -r /run/replit/env/latest ] && . /run/replit/env/latest
# The file is regenerated and can lag, so do not trust it for REPL_HOME: pin the
# roots to the bundle's parent (=$REPL_HOME) whenever they are unset. Without this
# the state lands in $HOME and dies with the next recreate.
REPL_HOME="${REPL_HOME:-$(cd "$APP/.." && pwd)}"
export REPL_HOME
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$REPL_HOME/.config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$REPL_HOME/.local/share}"
STATE="${XDG_CONFIG_HOME:-${REPL_HOME:-$HOME}/.config}/llmwiki-ui"
DISP="${LLM_WIKI_DISPLAY:-:99}"
VNC_PORT="${LLM_WIKI_VNC_PORT:-5900}"
WEB_PORT="${LLM_WIKI_UI_PORT:-3000}"   # same number local and public: .replit maps 3000 -> 3000
SLEEP="${LLM_WIKI_UI_SLEEP:-15}"

mkdir -p "$STATE"; chmod 700 "$STATE"
# `nix build` here writes to a per-user store (~/.store), because /nix/store takes build
# outputs only through the local-overlay upper layer, which is root-owned on Replit. Look
# there first, then /nix/store for boxes that build straight into it.
X11VNC="$(ls -d "${REPL_HOME:-$HOME}"/.store/nix/store/*x11vnc-*/bin/x11vnc "$HOME"/.store/nix/store/*x11vnc-*/bin/x11vnc /nix/store/*x11vnc-*/bin/x11vnc 2>/dev/null | head -1)"
NOVNC="$(ls -d "${REPL_HOME:-$HOME}"/.store/nix/store/*novnc-*/bin/novnc "$HOME"/.store/nix/store/*novnc-*/bin/novnc /nix/store/*novnc-*/bin/novnc 2>/dev/null | head -1)"
NIXENV="$(command -v nixenv 2>/dev/null)"

# A binary built into the per-user store (~/.store) cannot run directly: its interpreter
# and RUNPATH name /nix/store paths that only exist inside the nixenv mount namespace.
# /nix/store builds run normally, so only prefix nixenv for store-local paths.
run_ui_bin() {
  if [ -n "$NIXENV" ]; then case "$1" in *"/.store/"*) "$NIXENV" "$@"; return ;; esac; fi
  env -u LD_LIBRARY_PATH "$@"
}

port_open() { (exec 3<>/dev/tcp/127.0.0.1/"$1") >/dev/null 2>&1; }
log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }

# --- VNC password (chmod 600; the plaintext copy is what you type in the browser) ---
if [ ! -s "$STATE/vnc-pass" ] || [ ! -s "$STATE/vnc-password.txt" ]; then
  [ -n "$X11VNC" ] || { echo "x11vnc not built yet — nix_run build nixpkgs#x11vnc" >&2; exit 1; }
  PW="$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-12)"
  run_ui_bin "$X11VNC" -storepasswd "$PW" "$STATE/vnc-pass" >/dev/null 2>&1
  printf '%s\n' "$PW" > "$STATE/vnc-password.txt"
  chmod 600 "$STATE/vnc-password.txt"
  log "VNC password written to $STATE/vnc-password.txt (chmod 600)"
fi

start_vnc() {
  port_open "$VNC_PORT" && return 0
  [ -n "$X11VNC" ] || return 1
  run_ui_bin "$X11VNC" -display "$DISP" -localhost -rfbport "$VNC_PORT" \
    -rfbauth "$STATE/vnc-pass" -forever -shared -repeat -noxdamage -quiet \
    >"$STATE/x11vnc.log" 2>&1 &
  for _ in $(seq 1 15); do port_open "$VNC_PORT" && { log "x11vnc up (127.0.0.1:$VNC_PORT -> $DISP)"; return 0; }; sleep 1; done
  log "x11vnc FAILED (see $STATE/x11vnc.log)"; return 1
}

# x11vnc needs a live X server. A stale /tmp/.X11-unix socket must not be trusted: require
# a running Xvfb for this display, otherwise the VNC server dies silently and the browser
# shows a black page. run-public.sh starts the same display; whichever supervisor comes
# first wins and the other just finds it there.
ensure_display() {
  # Truth = a live Xvfb for THIS display. The /tmp/.X11-unix socket can vanish
  # (tmpfs sweep) while the server keeps running; trusting the socket then starts a
  # second Xvfb that dies with "server already running" and spams FAILED every loop.
  if pgrep -f "Xvfb.*[[:space:]]${DISP}([[:space:]]|$)" >/dev/null 2>&1; then
    [ -S "/tmp/.X11-unix/X${DISP#:}" ] || log "display $DISP alive (socket swept, server fine)"
    return 0
  fi
  local xvfb
  xvfb="$(command -v Xvfb || ls -d "${REPL_HOME:-$HOME}"/.store/nix/store/*-xorg-server-*/bin/Xvfb "$HOME"/.store/nix/store/*-xorg-server-*/bin/Xvfb /nix/store/*-xorg-server-*/bin/Xvfb 2>/dev/null | head -1)"
  [ -n "$xvfb" ] || { log "no Xvfb found — cannot create display $DISP"; return 1; }
  rm -f "/tmp/.X11-unix/X${DISP#:}" "/tmp/.X${DISP#:}-lock"
  run_ui_bin "$xvfb" "$DISP" -screen 0 1600x1000x24 +extension GLX +extension RANDR +render -noreset >/tmp/xvfb.log 2>&1 &
  for _ in $(seq 1 10); do [ -S "/tmp/.X11-unix/X${DISP#:}" ] && { log "Xvfb up on $DISP"; return 0; }; sleep 1; done
  log "Xvfb FAILED (see /tmp/xvfb.log)"; return 1
}

start_novnc() {
  port_open "$WEB_PORT" && return 0
  [ -n "$NOVNC" ] || { log "noVNC not built yet — nix_run build nixpkgs#novnc"; return 1; }
  run_ui_bin "$NOVNC" --listen "0.0.0.0:$WEB_PORT" --vnc "127.0.0.1:$VNC_PORT" --file-only \
    >"$STATE/novnc.log" 2>&1 &
  for _ in $(seq 1 20); do port_open "$WEB_PORT" && { log "noVNC up (0.0.0.0:$WEB_PORT)"; return 0; }; sleep 1; done
  log "noVNC FAILED (see $STATE/novnc.log)"; return 1
}

# Workflow-console hygiene (skill-wide rule, references/exposing-ports.md):
# when stdout is not a TTY (a .replit workflow or agent run), print a short
# summary to the console, then send the supervisor's own output to a log
# file in the persistent workspace — a supervisor loop streaming into the
# workflow terminal hangs the Replit UI. Interactive runs keep the console.
LOG_FILE="${LLM_WIKI_UI_LOG_FILE:-$REPL_HOME/logs/llm-wiki-ui.log}"
if [ ! -t 1 ]; then
  mkdir -p "$(dirname "$LOG_FILE")"
  log "llm-wiki ui supervisor: display=$DISP vnc=$VNC_PORT web=$WEB_PORT"
  log "  full log: $LOG_FILE"
  exec >>"$LOG_FILE" 2>&1
  log "supervisor output redirected from console $(date -Is)"
fi
log "ui supervisor: display=$DISP vnc=$VNC_PORT web=$WEB_PORT"
while true; do
  ensure_display; start_vnc; start_novnc
  sleep "$SLEEP"
done
