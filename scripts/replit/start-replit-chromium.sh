#!/usr/bin/env bash
# start-replit-chromium.sh — idempotent, ON-DEMAND launcher for the Replit
# Playwright-managed Chromium as a headless CDP daemon. Serves
# references/playwright-chromium.md.
#
# Scope: REPLIT's store browser ONLY ($REPLIT_PLAYWRIGHT_CHROMIUM_EXECUTABLE).
# It deliberately does NOT fall back to any other browser — the Hermes bundled
# Chrome is a separate lane with its own installer and launcher, see
# setup.sh --hermes-browser (launch-hermes-chrome) and docs/browser-lanes.md.
#
# Why no LD_LIBRARY_PATH here: the Replit store Chrome is a self-contained
# wrapper — it exports its own SSL_CERT_FILE/FONTCONFIG_FILE and execs a bundled
# binary with its own RPATH. It needs NO /nix/store closure. (Builds that DO
# need one — e.g. Hermes' chrome-linux64 — resolve it at install time in
# scripts/setup/hermes_chromium.sh via scripts/replit/resolve-libs.sh, never a hardcoded hash.)
#
# Usage: run ONCE when you need the browser; a no-op if the CDP port is live.
# Do NOT schedule it on recurring cron — launch on demand, kill it when done.
#
# Multiple agents: Chromium locks --user-data-dir (SingletonLock), so two
# instances can NEVER share one profile dir. Give each its own port + data dir:
#   CHROME_PORT=9223 CHROME_DATA_DIR="$XDG_DATA_HOME/chromium/agent-b" \
#       bash start-replit-chromium.sh
set -euo pipefail

PORT="${CHROME_PORT:-9222}"
DATA_DIR="${CHROME_DATA_DIR:-${XDG_DATA_HOME:-${REPL_HOME:-$HOME}/.local/share}/chromium/default}"
LOG="${CHROME_LOG:-$DATA_DIR/chrome-boot.log}"

# The Replit store browser. No PATH/other-browser fallback: another chromium
# means a different environment, where this skill's Replit lane does not apply.
CHROME="${REPLIT_PLAYWRIGHT_CHROMIUM_EXECUTABLE:-}"
if [[ -z "$CHROME" || ! -x "$CHROME" ]]; then
    echo "error: REPLIT_PLAYWRIGHT_CHROMIUM_EXECUTABLE is unset or not executable." >&2
    echo "       For the Hermes Chrome lane use: setup.sh --hermes-browser (launch-hermes-chrome)." >&2
    exit 1
fi

# If the CDP port already answers, nothing to do.
if curl -s --max-time 2 "http://127.0.0.1:${PORT}/json/version" >/dev/null 2>&1; then
    echo "chrome already up on :${PORT}"
    exit 0
fi

mkdir -p "$DATA_DIR"
setsid "$CHROME" \
    --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage \
    --remote-debugging-port="${PORT}" \
    --user-data-dir="$DATA_DIR" about:blank \
    >>"$LOG" 2>&1 &
for _ in 1 2 3 4 5; do
    sleep 1
    if curl -s --max-time 1 "http://127.0.0.1:${PORT}/json/version" >/dev/null 2>&1; then
        echo "chrome launched on :${PORT} (pid $!); profile: $DATA_DIR"
        echo "  browser: $CHROME"
        exit 0
    fi
done
echo "error: chrome failed to bind :${PORT}; see $LOG" >&2
exit 1