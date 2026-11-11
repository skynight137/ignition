#!/usr/bin/env bash
# Lifecycle test for the join bridge: install -> detached uninstall -> assertions -> (rejoin
# from the operator box). RUN THIS ON THE TARGET BOX. The uninstall leg is detached because it
# kills tailscaled and takes the tailnet leg (and the session) with it; results are written to
# $HOME/lifecycle.out, which you read after rejoining.
#
# Planted foreign state (another Host block, a 22-era known_hosts line, a foreign authorized
# key) is what proves the sweep is narrow: those must survive untouched.
set -u
cd "${REPL_HOME:-$HOME/workspace}" || exit 1
S="${SETUP_SH:-${REPL_HOME:-$HOME/workspace}/.agents/skills/replit/scripts/setup.sh}"  # payload setup.sh (repo layout: scripts/setup.sh --machine repl — override with SETUP_SH)
TS="${REPL_HOME:-$HOME/workspace}/.local/bin/tailscale"
SOCK="${TAILSCALE_SOCKET:-${TAILSCALE_STATE_DIR:-${XDG_STATE_HOME:-${REPL_HOME:-$HOME/workspace}/.local/state}/tailscale}/tailscaled.sock}"
OUT="$HOME/lifecycle.out"
: >"$OUT"
exec >>"$OUT" 2>&1
say() { printf '%s\n' "$*"; }

mkdir -p "$HOME/.ssh"
cat >"$HOME/.ssh/config" <<'CFG'
# user preamble
Host github.com
    HostName github.com
    User git

Host <peer>
    HostName <peer>
    Port 6800
    User runner
    ProxyCommand /repl/tools/bin/nc -X 5 -x 127.0.0.1:1055 %h %p

Host other-box
    HostName 10.0.0.9
    Port 6800
    User runner
CFG
printf 'gh.example.com ssh-ed25519 AAAAforeign\n[127.0.0.1]:6800 ssh-ed25519 AAAAgone\n' >"$HOME/.ssh/known_hosts"
printf 'ssh-ed25519 AAAAother other-key\n' >"$HOME/.ssh/authorized_keys"

say "== INSTALL =="
TAILSCALE_NODE_NAME="${TAILSCALE_NODE_NAME:-$(hostname)}" bash $S --tailscale -j 2>&1 \
  | tail -8
say "sshd-up: $( (exec 3<>/dev/tcp/127.0.0.1/6800) 2>/dev/null && echo yes || echo no)"
say "node-ip: $($TS --socket="$SOCK" ip -4 2>/dev/null)"

say "== UNINSTALL (detached) =="
setsid nohup bash -c "cd \"\${REPL_HOME:-\$HOME/workspace}\"; bash \"$S\" --clean tailscale" \
  </dev/null >"$HOME/clean.log" 2>&1 &
for _ in $(seq 1 40); do grep -q 'dibiarkan (hapus manual)' "$HOME/clean.log" 2>/dev/null && break; sleep 1; done

{
  say "== POST-CLEAN ASSERTIONS =="
  say "sshd-up-after: $( (exec 3<>/dev/tcp/127.0.0.1/6800) 2>/dev/null && echo yes || echo no)   # expect no"
  say "socket-after: $([ -S "$SOCK" ] && echo present || echo gone)   # expect gone"
  say "processes-left: $(pgrep -af '[s]shd_config|[t]ailscaled --tun' | wc -l)   # expect 0"
  say "state-dir: $([ -d "${RS_DIR:-${REPL_HOME:-$HOME/workspace}/.ssh/join-tailnet}" ] && echo present || echo gone)   # expect gone"
  say "-- clean.log --";  sed -n '1,40p' "$HOME/clean.log"
  say "-- config --";     cat "$HOME/.ssh/config"        # peer block gone, github.com + other-box intact
  say "-- known_hosts --"; cat "$HOME/.ssh/known_hosts"  # :6800 line gone, others intact
  say "-- authorized_keys --"; cat "$HOME/.ssh/authorized_keys"
}
