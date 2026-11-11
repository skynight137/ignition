# shellcheck shell=bash
# join.sh — the shared join engine for BOTH setups (muse + replit).
# Sourced, never executed. Stage S3 of the shared-setup refactor:
# the steps both join implementations share live here exactly once,
# parameterized by the calling profile (tree dir, port, service user,
# binary paths). Profile-specific wiring (workflow entries, reverse
# loop, session-env content) stays in the profiles.
#
# S3a: sshd render + validate + start. S3b: tailscaled start +
# identity + tailnet join. S3c: tree prepare + host key + key
# seeding. The repl profile adopts them here; the muse profile
# adopts them when its profile is built (S4).

# engine_banner <host> <port> — read one banner line over raw TCP.
engine_banner() {
  local h="$1" p="$2"
  timeout 3 bash -c "exec 3<>/dev/tcp/$h/$p; IFS= read -r -t 2 l <&3 && printf '%s' \"\$l\"" 2>/dev/null
}

# engine_sshd_render <dir> <port> <user> — write <dir>/sshd_config.
# The fleet's settled sshd shape: key-only on the join port, sshd-
# injected session environment, no root, liveness probes on.
engine_sshd_render() {
  local dir="$1" port="$2" user="$3"
  cat >"$dir/sshd_config" <<EOF
Port $port
ListenAddress 0.0.0.0
AddressFamily inet
HostKey $dir/host_ed25519
PidFile $dir/sshd.pid
AuthorizedKeysFile $dir/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
PermitEmptyPasswords no
UsePAM no
# Environment sesi disuntik sshd sendiri (~/.ssh/environment), bukan
# lewat rc: sesi login/non-login/`ssh host cmd` membaca rc yang
# berbeda-beda, dan [userenv.shared] hanya sampai ke proses platform.
PermitUserEnvironment yes
StrictModes no
PrintMotd no
X11Forwarding no
AllowTcpForwarding yes
AllowUsers $user
ClientAliveInterval 30
ClientAliveCountMax 3
LogLevel VERBOSE
EOF
}

# engine_sshd_validate <sshd-bin> <dir>
engine_sshd_validate() {
  "$1" -t -f "$2/sshd_config" || { warn "config sshd tidak valid"; return 1; }
}

# engine_sshd_start <sshd-bin> <dir> <port> — start only if the port
# is not already answering with an SSH banner; a live sshd is never
# killed (running sessions are safe).
engine_sshd_start() {
  local sshd="$1" dir="$2" port="$3"
  if engine_banner 127.0.0.1 "$port" | grep -q '^SSH-2.0-'; then
    ok "sshd sudah hidup di $port (tidak dibunuh, sesi berjalan aman)"
    return 0
  fi
  : >"$dir/sshd.log"
  setsid "$sshd" -f "$dir/sshd_config" -E "$dir/sshd.log" </dev/null >/dev/null 2>&1 || \
    nohup "$sshd" -f "$dir/sshd_config" -E "$dir/sshd.log" </dev/null >/dev/null 2>&1 &
  local i=0
  for i in $(seq 1 10); do engine_banner 127.0.0.1 "$port" | grep -q '^SSH-2.0-' && break; sleep 1; done
  engine_banner 127.0.0.1 "$port" | grep -q '^SSH-2.0-' || {
    warn "sshd tidak menjawab di $port"; tail -8 "$dir/sshd.log" 2>/dev/null; return 1; }
  ok "sshd hidup di $port (key-only)"
}

# engine_tailscaled_start <tailscaled> <tailscale> <state-dir>
#                         <socket> <log-file> <data-dir>
# Identity-safe daemon start. Liveness is the socket answering, not
# a pid guess: a SECOND daemon on another socket would otherwise
# suppress the start and leave this socket dead. An EMPTY state file
# means the node key is gone and starting from it registers a
# brand-new node — the last good copy (<data-dir>/tailscaled.state.bak)
# is restored first and refreshed once the daemon answers. A legacy
# daemon on the pre-XDG statedir (<data-dir>/state) is stopped first:
# never two daemons on one identity.
engine_tailscaled_start() {
  local td="$1" tsc="$2" state="$3" sock="$4" TS_LOG="$5" TS_DATA="$6"
  local state_bak="$TS_DATA/tailscaled.state.bak"
  if [[ ! -s "$state/tailscaled.state" ]] && [[ -s "$state_bak" ]]; then
    cp -p "$state_bak" "$state/tailscaled.state"
    ok "identity tailnet dipulihkan dari backup ($state_bak) — tidak ada node baru"
  fi
  local legacy_state="$TS_DATA/state"
  if [[ "$legacy_state" != "$state" && -S "$legacy_state/tailscaled.sock" ]]; then
    echo "  migrasi: menghentikan tailscaled lama (statedir $legacy_state)"
    pkill -f "tailscaled.*--statedir=$legacy_state" 2>/dev/null || true
    sleep 2
  fi
  if ! "$tsc" --socket="$sock" status >/dev/null 2>&1; then
    mkdir -p "$(dirname "$TS_LOG")"
    setsid "$td" --tun=userspace-networking --socks5-server=localhost:1055 \
      --outbound-http-proxy-listen=localhost:1055 \
      --state="$state/tailscaled.state" --statedir="$state" --socket="$sock" \
      </dev/null >>"$TS_LOG" 2>&1 &
    local w=0
    for w in $(seq 1 10); do [ -S "$sock" ] && break; sleep 1; done
  fi
  [ -S "$sock" ] || { warn "tailscaled tidak siap (log: $TS_LOG)"; return 1; }
  if [[ -s "$state/tailscaled.state" ]] && ! cmp -s "$state/tailscaled.state" "$state_bak"; then
    cp -p "$state/tailscaled.state" "$state_bak" 2>/dev/null || true
  fi
}

# engine_tailnet_join <tailscale> <socket> — brings the node up and
# reports its IPv4 in ENGINE_TS_IP. --hostname is asserted only where
# it must be: the first join (auth key present), or when the operator
# pins TAILSCALE_NODE_NAME. A later start that kept re-sending
# $(hostname) would undo a console rename, so it stays quiet.
engine_tailnet_join() {
  local tsc="$1" sock="$2"
  local hn=()
  if [ -n "${TAILSCALE_AUTH_KEY:-}" ]; then
    hn=(--hostname="${TAILSCALE_NODE_NAME:-$(hostname)}")
    # The key itself never needs printing twice; mask it in the echoed command line.
    "$tsc" --socket="$sock" up --authkey="$TAILSCALE_AUTH_KEY" "${hn[@]}" --accept-routes=false 2>&1 \
      | sed -E 's/(tskey-)[A-Za-z0-9_-]+/\1***/g' | tail -2
  else
    # Normal boots already carry an identity, and `up` refuses to change one pref
    # without every non-default being restated; `set` takes them one at a time.
    # It still fails on a box that was never logged in, so keep `up` as the fallback.
    [ -n "${TAILSCALE_NODE_NAME:-}" ] && hn=(--hostname="$TAILSCALE_NODE_NAME")
    "$tsc" --socket="$sock" set --accept-routes=false "${hn[@]}" 2>&1 | tail -2 \
      || "$tsc" --socket="$sock" up --accept-routes=false 2>&1 | tail -2 \
      || warn "login tailnet perlu auth key: TAILSCALE_AUTH_KEY=tskey-... setup.sh --tailscale --join"
  fi
  ENGINE_TS_IP="$("$tsc" --socket="$sock" ip -4 2>/dev/null | head -1)"
  [ -n "$ENGINE_TS_IP" ] && ok "tailnet: $ENGINE_TS_IP" || warn "node belum punya alamat tailnet"
}

# engine_join_tree <dir> — prepare the join tree: the dir itself
# (700), sshd's privsep dirs (a non-root sshd exits immediately
# without /run/sshd), the host key (generated once — a new host key
# on every boot is an ssh warning cascade), and an empty
# authorized_keys. Everything idempotent, everything 600.
engine_join_tree() {
  local dir="$1" d
  mkdir -p "$dir" && chmod 700 "$dir"
  for d in /run/sshd /var/empty; do
    [ -d "$d" ] || mkdir -p "$d" 2>/dev/null || true
  done
  [ -f "$dir/host_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -f "$dir/host_ed25519"
  [ -f "$dir/authorized_keys" ] || : >"$dir/authorized_keys"
  chmod 600 "$dir/host_ed25519" "$dir/authorized_keys"
}

# engine_seed_key <dir> <full-key-line> — additive seeding: append
# the key only if the file does not already contain it. Takes ONE
# full key line per call (the pre-engine loop word-split its input,
# which only ever worked because the in-code default is quoted as a
# single word — an operator-supplied multi-word value would have
# been appended as fragments).
engine_seed_key() {
  local dir="$1" k="$2"
  [ -n "$k" ] || return 0
  grep -qF "$k" "$dir/authorized_keys" 2>/dev/null || printf '%s\n' "$k" >>"$dir/authorized_keys"
}
