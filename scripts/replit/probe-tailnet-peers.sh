#!/usr/bin/env bash
# Survey reachability over the local tailnet: real peers only, one port probe each.
# usage: probe-tailnet-peers.sh [port] [socks-port]
#
# Answers "which machines can we actually remote into" with evidence instead of a
# promise: a peer is only a target once it is online, has run `setup.sh --tailscale --join
# --join` there, and carries the hop key. Tailscale's own funnel-ingress nodes are
# skipped. Survey, not a gate: always exits 0.
#
# Needs netcat-openbsd (`-X 5`). Without it, fall back per peer to
# `<tsc> --socket=<sock> nc <ip> <port>`.
set -uo pipefail

port="${1:-6800}"
socks="${2:-1055}"
state="${TAILSCALE_STATE_DIR:-${XDG_STATE_HOME:-${REPL_HOME:-$HOME/workspace}/.local/state}/tailscale}"
sock="${TAILSCALE_SOCKET:-$state/tailscaled.sock}"
tsc="$(command -v tailscale || printf '%s' "${XDG_BIN_HOME:-$HOME/.local/bin}/tailscale")"
nc_bin="$(command -v nc || printf '%s' /repl/tools/bin/nc)"

[ -x "$tsc" ] || { printf 'tailscale not found at %s\n' "$tsc" >&2; exit 0; }

"$tsc" --socket="$sock" status --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
self_node = d.get("Self") or {}
self_ips = [i for i in (self_node.get("TailscaleIPs") or []) if ":" not in i]
print("SELF %s %s" % (self_node.get("HostName", "?"), (self_ips or ["?"])[0]))
for p in (d.get("Peer") or {}).values():
    if p.get("HostName", "").startswith("funnel-ingress-node"):
        continue
    ips = [i for i in (p.get("TailscaleIPs") or []) if ":" not in i] or p.get("TailscaleIPs") or ["?"]
    print("%s %s %s" % ("ONLINE" if p.get("Online") else "OFFLINE", p.get("HostName", "?"), ips[0]))
' | while read -r state_line name ip; do
  case "$state_line" in
    SELF) printf '%-6s %-24s %s\n' self "$name" "$ip" ;;
    OFFLINE) printf '%-7s %-24s %s\n' offline "$name" "$ip" ;;
    ONLINE)
      if "$nc_bin" -X 5 -x "127.0.0.1:$socks" -z -w 5 "$ip" "$port" 2>/dev/null; then
        printf '%-7s %-24s %-16s OPEN:%s\n' online "$name" "$ip" "$port"
      else
        printf '%-7s %-24s %-16s closed:%s\n' online "$name" "$ip" "$port"
      fi ;;
  esac
done
