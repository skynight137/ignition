#!/usr/bin/env bash
set -euo pipefail
source "$HATCH_HOOK_RUNTIME"

# Watchdog for the muse-hop join stack: poll stack-health, stay silent while
# healthy, wake an agent (which runs the --join restore) when any probe FAILs.
# Wake at most once per cooldown while continuously down; the timestamp is
# cleared as soon as a healthy poll is seen again.

HEALTH="$HOME/workspace/tests/stack-health.sh"
STATE_DIR="$HOME/hooks/state"
STATE="$STATE_DIR/$(basename "$0" .sh).last-wake"
COOLDOWN=900

out="$("$HEALTH" 2>&1 || true)"

if [ -z "$out" ]; then
  log "inconclusive" '{"reason":"stack-health produced no output"}'
  silent "inconclusive" '{}'
elif ! printf '%s\n' "$out" | grep -q '^FAIL'; then
  if [ "${HATCH_HOOK_DRY_RUN:-0}" != "1" ]; then
    mkdir -p "$STATE_DIR"
    rm -f "$STATE"
  fi
  silent "stack healthy" '{}'
else
  fails="$(printf '%s\n' "$out" | grep '^FAIL' || true)"
  now="$(date +%s)"
  last=0
  if [ -f "$STATE" ]; then
    last="$(cat "$STATE" 2>/dev/null || echo 0)"
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
  fi
  if [ $((now - last)) -lt $COOLDOWN ]; then
    silent "stack still down; wake already sent within cooldown" '{}'
  else
    if [ "${HATCH_HOOK_DRY_RUN:-0}" != "1" ]; then
      mkdir -p "$STATE_DIR"
      printf '%s' "$now" > "$STATE"
    fi
    payload="$(jq -n --arg failures "$fails" '{failures: $failures}')"
    wake "stack_down" "$payload"
  fi
fi
