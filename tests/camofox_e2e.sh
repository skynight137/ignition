#!/usr/bin/env bash
# camofox_e2e.sh — end-to-end check for the npm-global Camofox lane
# (`bash setup.sh --camofox`). Exercises the REST API the MCP adapter and
# the tour's camofox engine speak, on a private port with a throwaway key.
#
# Runs against whatever is installed: `camofox-browser` on PATH (required),
# started directly — no wrapper. The GTK/X11 closure (if generated at
# $XDG_DATA_HOME/camofox/closure.txt) is prepended to LD_LIBRARY_PATH here.
#
# Nothing is hardcoded to one machine: node/npm come from PATH, the engine from
# CAMOUFOX_INSTALL_DIR (default $XDG_CACHE_HOME/camoufox).
#
# Usage: bash tests/camofox_e2e.sh
# Env:   CAMOFOX_E2E_PORT (default 9400)
set -uo pipefail

PORT="${CAMOFOX_E2E_PORT:-9400}"
BASE="http://127.0.0.1:$PORT"
SCRATCH="$(mktemp -d)"
KEYF="$SCRATCH/key"; PIDF="$SCRATCH/pid"; LOGF="$SCRATCH/server.log"
CFG="$SCRATCH/curlrc"
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
bad(){ echo "FAIL: $1"; fail=$((fail+1)); }

cleanup(){ [[ -f "$PIDF" ]] && kill "$(cat "$PIDF")" 2>/dev/null || true; rm -rf "$SCRATCH"; }
trap cleanup EXIT

command -v camofox-browser >/dev/null || { echo "FAIL: camofox-browser not on PATH — run: bash setup.sh --camofox"; exit 1; }

# 0. apply the GTK/X11 closure (Firefox needs it). setup.sh writes env.sh;
#    a live shell already sourced it via the rc, but a bare run has not.
#    NOTE: this is exactly what a NON-interactive shell (.replit workflow, Run
#    button, cron) fails to do — a bare `camofox-browser` there starts Firefox
#    with no GTK closure and dies with
#    `libmozgtk.so: libgtk-3.so.0: cannot open shared object file`. Use
#    $XDG_BIN_HOME/launch-camofox-browser (written by setup.sh --camofox /
#    --fix) in those shells instead of a bare camofox-browser.
ENVSH="${CAMOFOX_STATE_DIR:-${XDG_CONFIG_HOME:-${REPL_HOME:-$HOME}/.config}/camofox}/env.sh"
[[ -f "$ENVSH" ]] && . "$ENVSH"

# 1. throwaway key (header-safe), never printed
if [[ -n "${CAMOFOX_ACCESS_KEY:-}" ]]; then
  printf '%s' "$CAMOFOX_ACCESS_KEY" > "$KEYF"
else
  head -c 32 /dev/urandom | sha256sum | cut -c1-64 > "$KEYF"
fi
chmod 600 "$KEYF"; KEY="$(cat "$KEYF")"
printf 'header = "Authorization: Bearer %s"\n' "$KEY" > "$CFG"; chmod 600 "$CFG"

# 2. start the server directly (npm binary). Uses an explicit randomized key
#    for the privileged routes; loopback reads need none.
export CAMOFOX_PORT="$PORT" CAMOFOX_BIND_HOST=127.0.0.1 CAMOFOX_API_KEY="$KEY"
[[ -n "${CAMOUFOX_INSTALL_DIR:-}" ]] || export CAMOUFOX_INSTALL_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/camoufox"
nohup camofox-browser > "$LOGF" 2>&1 &
echo $! > "$PIDF"

ready=no
for _ in $(seq 1 60); do
  curl -sf -m 3 "$BASE/health" >/dev/null 2>&1 && { ready=yes; break; }
  sleep 1
done
[[ "$ready" = yes ]] && ok "server up on :$PORT" || { bad "server not ready"; tail -20 "$LOGF"; exit 1; }

# 3. auth model: loopback is trusted for reads, but privileged routes
#    (cookie import) require the CAMOFOX_API_KEY. No-key read is allowed.
curl -s -m 5 -o /dev/null "$BASE/tabs" && ok "no-key GET /tabs -> allowed on loopback" || bad "no-key GET /tabs failed"
code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST "$BASE/sessions/e2e/cookies" \
  -H 'Content-Type: application/json' -d '{"cookies":[]}')
[[ "$code" = 403 ]] && ok "no-key cookie import -> 403 (privileged route gated)" || bad "no-key cookie import -> $code (expected 403)"

# 3b. client/engine protocol compatibility. playwright-core >= 1.64 passes
#     `bypassServiceWorker` to Network.setRequestInterception; the Camoufox
#     engine's juggler schema only declares {enabled}, so it rejects the call.
#     Narrow but fatal: the param is sent ONLY for storage-state pages, i.e.
#     restoring a user whose persisted state carries localStorage/origins —
#     every real logged-in account — so cookie import 500s while tabs work.
#     A bare `npm install -g` bumps the client past the pin setup.sh writes.
_cb="$(command -v camofox-browser)"; _pw=""
[[ -n "$_cb" ]] && _pw="$(dirname "$(readlink -f "$_cb")")/../node_modules/playwright-core/lib/coreBundle.js"
if [[ -f "$_pw" ]] && grep -q bypassServiceWorker "$_pw"; then
  bad "playwright-core sends bypassServiceWorker (engine rejects it) — cookie import of a logged-in account will 500; run: bash setup.sh --camofox"
else
  ok "playwright-core compatible with the engine's juggler schema"
fi

# 4. open a tab (first launch can be slow — cold engine)
tab=$(curl -s -m 120 -X POST "$BASE/tabs" --config "$CFG" -H 'Content-Type: application/json' \
  -d '{"userId":"e2e","sessionKey":"e2e","url":"https://example.com/"}')
TID=$(printf '%s' "$tab" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("tabId",""))' 2>/dev/null)
STAT=$(printf '%s' "$tab" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("httpStatus",""))' 2>/dev/null)
[[ -n "$TID" && "$STAT" = 200 ]] && ok "POST /tabs -> httpStatus=200" || bad "POST /tabs -> ${tab:0:160}"

# 5. content present (snapshot is an accessibility tree; match page text)
snap=$(curl -s -m 60 "$BASE/tabs/$TID/snapshot?userId=e2e" --config "$CFG")
grep -qi 'domain\|example' <<<"$snap" && ok "snapshot -> page text present" || bad "snapshot missing content"

ua=$(curl -s -m 30 -X POST "$BASE/tabs/$TID/evaluate" --config "$CFG" -H 'Content-Type: application/json' \
  -d '{"userId":"e2e","expression":"navigator.userAgent"}')
grep -q Firefox <<<"$ua" && ok "evaluate -> Firefox engine" || bad "evaluate -> ${ua:0:120}"

# 6. cookie import + refresh + cookie reuse (the core ask)
ci=$(curl -s -m 60 -X POST "$BASE/sessions/e2e/cookies" --config "$CFG" -H 'Content-Type: application/json' \
  -d '{"cookies":[{"name":"e2ecookie","value":"v1","domain":"example.com","path":"/"}]}')
grep -q '"count":1' <<<"$ci" && ok "cookie import -> count=1" || bad "cookie import -> ${ci:0:120}"

rf=$(curl -s -m 60 -X POST "$BASE/tabs/$TID/refresh" --config "$CFG" -H 'Content-Type: application/json' -d '{"userId":"e2e"}')
grep -q '"ok":true' <<<"$rf" && ok "refresh -> ok" || bad "refresh -> ${rf:0:120}"

ck=$(curl -s -m 30 -X POST "$BASE/tabs/$TID/evaluate" --config "$CFG" -H 'Content-Type: application/json' \
  -d '{"userId":"e2e","expression":"document.cookie"}')
grep -q 'e2ecookie=v1' <<<"$ck" && ok "cookie survives refresh" || bad "cookie lost after refresh -> ${ck:0:120}"

# 7. close
curl -s -m 15 -X DELETE "$BASE/tabs/$TID?userId=e2e" --config "$CFG" | grep -q '"ok":true' \
  && ok "DELETE tab -> ok" || bad "DELETE tab failed"

# 8. MCP adapter (stdlib handshake) when available
MCP="$(command -v camofox-browser-mcp || true)"
if [[ -n "$MCP" ]]; then
  CAMOFOX_BASE_URL="$BASE" CAMOFOX_ACCESS_KEY="$KEY" python3 "$(dirname "$0")/mcp_stdio_test.py" "$MCP" "$KEYF" "$PORT" \
    && ok "MCP adapter e2e (initialize/tools/list/create/evaluate/close)" || bad "MCP adapter e2e"
else
  echo "SKIP: camofox-browser-mcp not on PATH"
fi

echo "== SUMMARY: $pass passed, $fail failed"
[[ $fail -eq 0 ]]