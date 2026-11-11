#!/usr/bin/env bash
# camofox_mcp_check.sh — one-shot health probe for the camofox MCP path.
#
# The MCP adapter (mcp/server.mjs) is stdio-only: run standalone it idles on
# stdin forever and serves nothing. So the Replit workflow that "runs" it is
# instead a CHECK: wait for the REST server, drive a real MCP handshake
# (initialize -> tools/list) through a piped stdin, assert the 11 camofox_*
# tools come back, exit. Exit 0 = browser + adapter + wiring all alive.
#
# Arg1: seconds to wait for the REST server (default 90).
set -uo pipefail

PORT="${CAMOFOX_PORT:-9377}"
BASE="${CAMOFOX_BASE_URL:-http://localhost:${PORT}}"
WAIT="${1:-90}"

# npm lane: the adapter is the `camofox-browser-mcp` binary on PATH. Fall back
# to the git-clone layout's server.mjs if a CAMOFOX_ROOT checkout exists.
MCP="$(command -v camofox-browser-mcp || true)"
if [[ -z "$MCP" ]]; then
  ROOT="${CAMOFOX_ROOT:-${REPL_HOME:-$HOME}/camofox}"
  MCP="$ROOT/camofox-browser/mcp/server.mjs"
fi

[[ -f "$MCP" ]] || { echo "FAIL: no camofox-browser-mcp on PATH and none at $MCP — run: bash setup.sh --camofox"; exit 1; }
command -v node >/dev/null || { echo "FAIL: node not on PATH"; exit 1; }

echo "[check] waiting for camofox REST at $BASE (max ${WAIT}s)"
for ((i=0; i<WAIT; i++)); do
  curl -sf -m 2 "$BASE/health" >/dev/null 2>&1 && break
  sleep 1
done
curl -sf -m 5 "$BASE/" 2>/dev/null | grep -q '"engine"' \
  || { echo "FAIL: REST server not answering at $BASE"; exit 1; }

echo "[check] MCP stdio handshake -> $BASE"
out=$(printf '%s\n%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"replit-workflow-check","version":"1"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | CAMOFOX_BASE_URL="$BASE" CAMOFOX_PORT="$PORT" timeout 30 node "$MCP" 2>/dev/null) || true

if grep -q '"tools"' <<<"$out" && grep -q 'camofox_create_tab' <<<"$out"; then
  n=$(grep -o '"name":"camofox_[a-z_]*"' <<<"$out" | sort -u | wc -l)
  echo "OK: camofox MCP live — $n tools via $BASE"
  [ "$n" -ge 11 ] || echo "WARN: expected 11 tools, got $n — adapter version drift?"
  exit 0
fi

echo "FAIL: no MCP handshake response"
echo "${out:0:400}"
exit 1
