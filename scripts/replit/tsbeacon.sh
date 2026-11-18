#!/bin/sh
# tsbeacon.sh — node stats beacon: POST a small JSON self-report to the CC
# (payload-store on muse-hop, port 8099) over `tailscale nc`.
#
# Design: designs/beacon-cc.md in the heavenly-host repo. Fleet copy:
# this file ships with toolskit so every joined box carries it; the
# heavenly-host tools/ original is the pilot artifact it derives from.
# Machine stats ONLY — no secrets, no user data. If the POST fails, the
# payload is buffered in the
# workspace and shipped inside the next successful beacon ("backlog").
# Backlog entries are complete lines only, capped by count; a failed post
# retries once without the backlog, so a poisoned backlog can never
# deadlock the loop (repl-110, 2026-11-12: a byte-capped backlog cut a
# line mid-string and every later post answered 400).
#
# Usage: tsbeacon.sh [node-name]   (default: TAILSCALE_NODE_NAME from the
#        box's .replit userenv, else hostname)
# Env:   STORE_HOST (default muse-hop IP at authoring), STORE_PORT (8099),
#        TS_BIN, TS_SOCK (fleet join defaults), BEACON_BUFFER,
#        CF_BEACON_URL (default the live cf-hh Worker; empty = skip CF).
# Dual-write: the same body is POSTed to BOTH the muse-hop payload-store
# (primary: drives the fleet health watch, owns the backlog + exit code)
# AND the Cloudflare Worker (secondary liveness sink, best-effort). A CF
# failure is logged, never buffered and never changes the exit code.
set -u

WS="$HOME/workspace"
NODE="${1:-}"
if [ -z "$NODE" ]; then
  NODE=$(sed -n 's/^TAILSCALE_NODE_NAME = "\(.*\)"/\1/p' "$WS/.replit" 2>/dev/null | head -1)
  [ -n "$NODE" ] || NODE=$(hostname)
fi
HOST="${STORE_HOST:-100.113.127.73}"
PORT="${STORE_PORT:-8099}"
TS_BIN="${TS_BIN:-$WS/.local/bin/tailscale}"
TS_SOCK="${TS_SOCK:-$WS/.local/state/tailscale/tailscaled.sock}"
BUFFER="${BEACON_BUFFER:-$WS/.config/beacon/buffer.jsonl}"
CF_BEACON_URL="${CF_BEACON_URL:-https://cf-hh.zode.workers.dev/beacon}"

TS=$(date '+%Y-%m-%dT%H:%M:%S%z')
UP=$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)
# Bracket pattern: never self-match this script's own cmdline.
if pgrep -f '[t]our.py' >/dev/null 2>&1; then TOUR=true; else TOUR=false; fi
if curl -s --max-time 4 http://127.0.0.1:9377/health 2>/dev/null | grep -q '"ok":true'; then CFOK=true; else CFOK=false; fi
DISK=$(df --output=pcent "$WS" 2>/dev/null | tail -1 | tr -dc '0-9')
IGNITION=$(git -C "$WS/toolskit" rev-parse --short HEAD 2>/dev/null || echo unknown)
# Workflow logs end lines with CR (Replit shell logs are CRLF); a raw CR
# (or tab, or any control byte) inside the JSON string is invalid JSON
# and the CC answers 400. Strip ALL C0 controls (000-037: NUL, tab, LF,
# CR, ...) before the body is assembled. `xargs -r`: never run grep with
# no file args — without it, an empty logs dir makes grep read stdin
# and the beacon hangs.
VERDICT=$(ls -t "$WS"/.local/state/workflow-logs/*/*.shell.exec.0 2>/dev/null | head -3 | xargs -r grep -h 'verdict=' 2>/dev/null | tail -1 | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g' | cut -c1-160)

# Backlog: complete lines only, newest first, capped. A byte cap (head -c)
# can cut a JSON line mid-string, and the truncated fragment then poisons
# every later post with a 400 — the CC rejects the whole body, the body is
# buffered again, and the loop never recovers (repl-110, 2026-11-12).
# Only backlog-less bodies are buffered, so buffered lines stay small and
# self-contained instead of nesting previous backlogs inside each other.
BACKLOG_MAX_LINES=5
BUFFER_MAX_LINES=10

build_backlog() {
  if [ -s "$BUFFER" ]; then
    tail -n "$BACKLOG_MAX_LINES" "$BUFFER" | awk 'BEGIN{printf "["} {printf "%s%s", (NR>1?",":""), $0} END{printf "]"}'
  else
    printf '[]'
  fi
}

build_body() {
  printf '{"node":"%s","ignition":"%s","ts":"%s","uptime_s":%s,"tour_alive":%s,"camofox_ok":%s,"disk_pct":%s,"last_verdict":"%s","backlog":%s}' \
    "$NODE" "$IGNITION" "$TS" "${UP:-0}" "$TOUR" "$CFOK" "${DISK:-0}" "$VERDICT" "$1"
}

# Hold the pipe open after writing (sleep) — an instantly-closing stdin
# makes tailscale nc tear the session down before the reply returns
# (see tsfetch.sh). HTTP/1.0: the server closes after answering.
post_body() {
  _pb_len=$(printf '%s' "$1" | wc -c | tr -d ' ')  # wc -c pads with spaces; Content-Length must be bare digits
  (printf 'POST /beacon/%s HTTP/1.0\r\nHost: %s\r\nContent-Type: application/json\r\nContent-Length: %s\r\n\r\n%s' "$NODE" "$HOST" "$_pb_len" "$1"; sleep 5) \
    | timeout 30 "$TS_BIN" --socket="$TS_SOCK" nc "$HOST" "$PORT" 2>/dev/null | head -1
}

# CF Worker second sink (Beacon-to-CF): same body, direct curl — nodes
# have reliable egress to workers.dev. Best-effort only: always returns
# 0, never buffers, never changes the exit code. Empty CF_BEACON_URL
# disables it.
post_cf() {
  [ -n "$CF_BEACON_URL" ] || return 0
  _cf_resp=$(printf '%s' "$1" | curl -s --max-time 10 -X POST \
    -H 'Content-Type: application/json' --data-binary @- \
    "$CF_BEACON_URL" 2>/dev/null || true)
  case "$_cf_resp" in
    *'"ok":true'*) echo "tsbeacon: $NODE cf ok" ;;
    *) echo "tsbeacon: $NODE cf failed (resp: ${_cf_resp:-none})" >&2 ;;
  esac
  return 0
}

buffer_body() {
  mkdir -p "$(dirname "$BUFFER")"
  printf '%s\n' "$1" >> "$BUFFER"
  tail -n "$BUFFER_MAX_LINES" "$BUFFER" > "$BUFFER.tmp" && mv "$BUFFER.tmp" "$BUFFER"
}

BACKLOG=$(build_backlog)
BODY=$(build_body "$BACKLOG")
RESP=$(post_body "$BODY")

# muse-hop outcome drives the backlog + exit code; the CF post runs
# regardless and never changes it.
MH_RC=0
case "$RESP" in
  *" 200 "*)
    [ -s "$BUFFER" ] && : > "$BUFFER"
    echo "tsbeacon: $NODE ok"
    ;;
  *)
    # A failed post with a backlog may be the backlog's fault (a poisoned
    # line written by an older build). Retry once without it: a poisoned
    # backlog must never deadlock the loop.
    if [ "$BACKLOG" != "[]" ]; then
      BODY_NB=$(build_body "[]")
      RESP_NB=$(post_body "$BODY_NB")
      case "$RESP_NB" in
        *" 200 "*)
          [ -s "$BUFFER" ] && : > "$BUFFER"
          echo "tsbeacon: $NODE ok (backlog dropped)"
          ;;
        *)
          buffer_body "$BODY_NB"
          echo "tsbeacon: $NODE buffered (resp: ${RESP_NB:-none})" >&2
          MH_RC=1
          ;;
      esac
    else
      buffer_body "$BODY"
      echo "tsbeacon: $NODE buffered (resp: ${RESP:-none})" >&2
      MH_RC=1
    fi
    ;;
esac

post_cf "$BODY"
exit "$MH_RC"
