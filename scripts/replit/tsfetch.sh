#!/bin/sh
# tsfetch.sh — fetch a payload from the muse-hop payload store over the tailnet.
#
# Why this exists: on a Replit node (userspace tailscaled, no TUN) a plain
# curl to a tailnet IP goes nowhere — the only working carrier is
# `tailscale nc`. This helper speaks HTTP/1.0 through nc, strips the
# headers, verifies a pinned sha256, and lands the file atomically.
# v1 scope: text payloads (scripts/config), per the fetch-at-destination
# design. Secrets are NEVER fetched this way — they are read on-box.
#
# Usage: tsfetch.sh <store-name> <dest-path> [expected-sha256]
#        tsfetch.sh --gist-raw <raw-url> <dest-path> [expected-sha256]
#        (gist-raw mode: secret-gist fallback for off-tailnet
#         destinations; the raw URL needs NO token -- the token is only
#         used on muse-hop to create/update the gist)
# Env:   STORE_HOST (default muse-hop IP at authoring; prefer the name your
#        tailscaled resolves, or override), STORE_PORT (8099),
#        TS_BIN, TS_SOCK (fleet join defaults below).
set -eu

# Gist-raw mode: tsfetch.sh --gist-raw <raw-url> <dest-path> [expected-sha256]
# Fallback for off-tailnet destinations (netmap mode below is primary).
# The raw URL of a gist -- secret or public -- is fetchable with NO token:
# anonymous curl to https://gist.githubusercontent.com/<user>/<id>/raw/<file>
# returns 200. The token is only ever needed to CREATE/UPDATE a gist,
# which happens on muse-hop (gist-publish.sh); it never leaves muse-hop
# and never appears on any node. Same atomic-land + trap discipline as
# netmap mode.
if [ "${1:-}" = "--gist-raw" ]; then
  RAW_URL="${2:?usage: tsfetch.sh --gist-raw <raw-url> <dest-path> [expected-sha256]}"
  DEST="${3:?usage: tsfetch.sh --gist-raw <raw-url> <dest-path> [expected-sha256]}"
  WANT="${4:-}"
  case "$RAW_URL" in
    https://gist.githubusercontent.com/*) ;;
    *) echo 'tsfetch: bad gist raw url (want https://gist.githubusercontent.com/...)' >&2; exit 1;;
  esac

  TMP="$DEST.tmp.$$"
  trap 'rm -f "$TMP"' EXIT INT TERM

  CODE=$(curl -sS -o "$TMP" -w '%{http_code}' "$RAW_URL")
  [ "$CODE" = "200" ] || { echo "tsfetch: gist raw fetch failed http=$CODE url=$RAW_URL" >&2; exit 1; }

  [ -s "$TMP" ] || { echo "tsfetch: empty response for $RAW_URL" >&2; exit 1; }

  if [ -n "$WANT" ]; then
    GOT=$(sha256sum "$TMP" | awk '{print $1}')
    [ "$GOT" = "$WANT" ] || { echo "tsfetch: sha256 mismatch got=$GOT want=$WANT" >&2; exit 1; }
  fi

  mkdir -p "$(dirname "$DEST")"
  mv "$TMP" "$DEST"
  trap - EXIT INT TERM
  echo "tsfetch: gist-raw $RAW_URL -> $DEST ok"
  exit 0
fi

NAME="${1:?usage: tsfetch.sh <store-name> <dest-path> [expected-sha256]}"
DEST="${2:?usage: tsfetch.sh <store-name> <dest-path> [expected-sha256]}"
WANT="${3:-}"
HOST="${STORE_HOST:-100.113.127.73}"
PORT="${STORE_PORT:-8099}"
TS_BIN="${TS_BIN:-$HOME/workspace/.local/bin/tailscale}"
TS_SOCK="${TS_SOCK:-$HOME/workspace/.local/state/tailscale/tailscaled.sock}"

TMP="$DEST.tmp.$$"
trap 'rm -f "$TMP"' EXIT INT TERM

RAW="$TMP.raw"
# The stdin hold-open is LOAD-BEARING: if the request pipe closes the
# instant printf finishes, tailscale nc tears the session down before the
# response crosses the relay (observed: request arrives and is served,
# client receives 0 bytes, rc=0). ssh never hits this because it holds
# stdin open. Sleep keeps the pipe open until the server has answered and
# closed (HTTP/1.0); timeout bounds the whole thing.
(printf 'GET /%s HTTP/1.0\r\nHost: %s\r\n\r\n' "$NAME" "$HOST"; sleep 5) \
  | timeout 30 "$TS_BIN" --socket="$TS_SOCK" nc "$HOST" "$PORT" > "$RAW"

# Split headers/body byte-exactly. Preferred: the box's workflow python
# (bare python3 is not on a Replit ssh PATH; the ctls glob is the fleet
# standard). Fallback: awk line split (text payloads, strips CR).
PY=$(ls /repl/ctls/*/bin/python3 2>/dev/null | head -1)
if [ -n "$PY" ]; then
  "$PY" - "$RAW" "$TMP" <<'PYEOF'
import sys
data = open(sys.argv[1], 'rb').read()
head, sep, body = data.partition(b'\r\n\r\n')
if not sep:
    head, sep, body = data.partition(b'\n\n')
status = head.split(b'\r\n')[0] if sep else b''
if not sep or b' 200 ' not in status:
    sys.stderr.write('tsfetch: bad response: %r\n' % status[:80])
    sys.exit(1)
open(sys.argv[2], 'wb').write(body)
PYEOF
else
  awk 'body{print} /^\r?$/{body=1}' "$RAW" | sed 's/\r$//' > "$TMP"
fi
rm -f "$RAW"

[ -s "$TMP" ] || { echo "tsfetch: empty response for $NAME" >&2; exit 1; }

if [ -n "$WANT" ]; then
  GOT=$(sha256sum "$TMP" | awk '{print $1}')
  [ "$GOT" = "$WANT" ] || { echo "tsfetch: sha256 mismatch got=$GOT want=$WANT" >&2; exit 1; }
fi

mkdir -p "$(dirname "$DEST")"
mv "$TMP" "$DEST"
trap - EXIT INT TERM
echo "tsfetch: $NAME -> $DEST ok"
