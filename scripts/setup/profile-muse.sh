#!/usr/bin/env bash
# setup.sh — stand up the remote-access stack on a FRESH Muse VM
# (the muse-test pattern: a second Muse instance you can redeploy freely
# and use as an end-to-end join target, the way repl-test serves Replit).
#
# What it installs (all inside the persistent tree):
#   ~/.ssh/                     canonical ssh store + sshd stack + configs
#                               (fresh installs — the OFFICIAL location,
#                               a real directory; a box whose stack tree
#                               already lives at <ws>/.ssh keeps that
#                               path — see the SSHDIR resolution below)
#   $SSHDIR/reverse/            reverse-tunnel client config + loop state
#   <ws>/tools/                 tailscale / tailscaled + tool binaries
#                               (fresh installs, FLAT — no bin/ subdir;
#                               a box already running from
#                               <ws>/.local/bin keeps that path —
#                               see the BINDIR resolution below)
#   ${XDG_STATE_HOME:-~/.local/state}/tailscale
#                               daemon state/socket + hosts override
#                               (fresh installs — state follows
#                               XDG_STATE_HOME; a box whose node state
#                               already lives at
#                               <ws>/.local/share/tailscale keeps that
#                               path — see the TSDIR resolution below)
#   <ws>/config/                shared env + tool configs (env.sh, ...)
#   /root/.ssh                  symlink -> $SSHDIR (root's passwd home is
#                               /root, so tooling that resolves ~ via
#                               passwd needs the pointer). Legacy boxes
#                               also get ~/.ssh as a symlink -> <ws>/.ssh;
#                               a fresh box's ~/.ssh IS the store.
#   Termix user units (when installed under ~/.config/systemd/user/):
#                               the join re-asserts the /root pointer,
#                               logind, and root lingering on every
#                               start, so the units auto-start after a
#                               redeploy (see reassert_termix_user_units).
#
# Usage (mirrors the replit setup's shape: phase flags + an interactive
# menu, instead of one monolith that beelines to the join):
#   bash setup.sh                     full setup; on a TTY, opens the menu
#   bash setup.sh --menu              interactive phase picker (arrow keys)
#   bash setup.sh --sshd              sshd stack only (users, openssh, keys,
#                                     configs)
#   bash setup.sh --tailscale         tailscale binaries only
#   bash setup.sh -j | --join         start the stack and join the tailnet
#                                     (implies --sshd/--tailscale when their
#                                     outputs are missing)
#   bash setup.sh --verify            read-only status
#   bash setup.sh --start-sshd        start the join sshd (only if down)
#   bash setup.sh --start-ts          start the node (only if down) + join
#   bash setup.sh --loop              run the reverse loop (hop; foreground)
#   bash setup.sh --check-reverse     probe the forward from the peer
#   bash setup.sh [--peer <ip>] ...   peer = reverse-forward holder
#   bash setup.sh [--user <name>] ... stack service user: the user the join
#                                     sshd runs as and accepts logins for,
#                                     and the tailscaled run-user. Env
#                                     RS_SSH_USER sets it too; the flag
#                                     wins. Default: root (setup prints a
#                                     warning — root sessions can read the
#                                     stack .env and client key). The
#                                     fleet-proven isolated choice is
#                                     --user runner. The install-time
#                                     choice is recorded in .env as
#                                     RS_SSH_USER; the runtime verbs read
#                                     the same flag/env, flag wins.
#
# Secrets never live in this repo: the operator creates $SSHDIR/.env
# (mode 600) with TAILSCALE_AUTH_KEY=<key for the tailnet> — setup writes
# a template and stops short of the join while the key is empty.
# The peer (set via --peer or RS_PEER; prefer its MagicDNS name — tailnet
# IPs are ephemeral and must never be pinned) is the machine that will
# hold the reverse forwards; its public key must be added to
# $SSHDIR/join-tailnet/authorized_keys and this VM's client pubkey
# ($SSHDIR/id_ed25519.pub, printed at the end) to the peer's sshd.
set -euo pipefail

PEER="${RS_PEER:-}" VERIFY=0
SSH_USER="${RS_SSH_USER:-root}"
DO_SSHD=0 DO_TAILSCALE=0 DO_JOIN=0 DO_MENU=0 SELECTED=0
DO_START_SSHD=0 DO_START_TS=0 DO_LOOP=0 DO_CHECK_REVERSE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --peer) PEER=$2; shift 2 ;;
    --user) SSH_USER=$2; shift 2 ;;
    --verify) VERIFY=1; shift ;;
    --sshd) DO_SSHD=1; SELECTED=1; shift ;;
    --tailscale) DO_TAILSCALE=1; SELECTED=1; shift ;;
    -j|--join) DO_JOIN=1; SELECTED=1; shift ;;
    --menu) DO_MENU=1; shift ;;
    --start-sshd) DO_START_SSHD=1; SELECTED=1; shift ;;
    --start-ts) DO_START_TS=1; SELECTED=1; shift ;;
    --loop) DO_LOOP=1; SELECTED=1; shift ;;
    --check-reverse) DO_CHECK_REVERSE=1; SELECTED=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
# Shared primitives (logging, verify_sha256, tailscale_asset_name)
# live in scripts/setup/core.sh — one copy for both setups (shared
# setup refactor, S2). This script runs from a clone of the repo;
# the SKILL.md payload flow fetches this file's sibling with it.
_SETUP_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MUSE_PAYLOAD_DIR="$(cd -- "$_SETUP_DIR/../muse" 2>/dev/null && pwd)"  # ts_proxy_connect.py stayed with the muse payloads
SETUP_ENTRY="$(cd -- "$_SETUP_DIR/.." 2>/dev/null && pwd)/setup.sh"  # the unified entry (scripts/setup.sh); _SETUP_DIR is unset below, this stays
if [[ -f "$_SETUP_DIR/core.sh" ]]; then
  source "$_SETUP_DIR/core.sh"
else
  echo "setup: missing shared library $_SETUP_DIR/core.sh — run from a full clone of skynight137/skills" >&2
  exit 2
fi
unset _SETUP_DIR
WS="$HOME/workspace"
# The stack tree's home: fresh installs use the OFFICIAL location,
# ~/.ssh, as a REAL directory — the path standard tooling (ssh, git
# signing) resolves via passwd/$HOME with no shim in between.
# Install-location stickiness, same shape as BINDIR below: a box
# whose tree already lives at the legacy workspace path
# (~/workspace/.ssh — the Replit-layout carry-over) KEEPS it —
# silently relocating a working stack would churn every generated
# config's absolute paths and the paths approvals are keyed by.
# RS_SSH_DIR (process env, or recorded in a stack .env) overrides
# both — it is also the deliberate-migration path: set it, re-run
# the phases to render into the new tree, then retire the old one.
LEGACY_SSHDIR="$WS/.ssh"
_ssh_dir_env=""
for _cand in "$LEGACY_SSHDIR/.env" "$HOME/.ssh/.env"; do
  if [[ -z "$_ssh_dir_env" ]]; then
    _v="$(grep -E '^RS_SSH_DIR=' "$_cand" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
    [[ -n "$_v" ]] && _ssh_dir_env="$_v"
  fi
done
if [[ -n "${RS_SSH_DIR:-}" ]]; then
  SSHDIR="$RS_SSH_DIR"
elif [[ -n "$_ssh_dir_env" ]]; then
  SSHDIR="$_ssh_dir_env"
elif [[ -f "$LEGACY_SSHDIR/join-tailnet/sshd_config" || -f "$LEGACY_SSHDIR/.env" ]]; then
  SSHDIR="$LEGACY_SSHDIR"
else
  SSHDIR="$HOME/.ssh"
fi
unset _ssh_dir_env _cand _v
# Tool binaries live in the workspace tools dir — the fleet's chosen
# layout (~/workspace/tools for binaries — FLAT, no bin/ subdir —
# ~/workspace/config for tool configs), away from the platform's own
# directories.
# Install-location stickiness: egress approvals are keyed by binary
# path, so a box already running tailscale from the legacy bin dir
# (~/workspace/.local/bin) keeps using it — silently relocating a live
# stack would re-mint approval cards and strand its state for no gain.
# Only a fresh install (no tailscaled in the legacy dir) lands in
# tools/ (flat). RS_TS_BIN_DIR (process env, or the stack .env) overrides
# both — it is also the deliberate-migration path: set it, let
# phase_tailscale install there, then retire the legacy copy.
LEGACY_BINDIR="$WS/.local/bin"
_ts_bin_dir_env="$(grep -E '^RS_TS_BIN_DIR=' "$SSHDIR/.env" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
if [[ -n "${RS_TS_BIN_DIR:-}" ]]; then
  BINDIR="$RS_TS_BIN_DIR"
elif [[ -n "$_ts_bin_dir_env" ]]; then
  BINDIR="$_ts_bin_dir_env"
elif [[ -x "$LEGACY_BINDIR/tailscaled" ]]; then
  BINDIR="$LEGACY_BINDIR"
else
  BINDIR="$WS/tools"
fi
unset _ts_bin_dir_env
# The daemon's state dir is runtime state, so it follows the XDG
# state home — NOT the workspace: a fresh install lands in
# ${XDG_STATE_HOME:-~/.local/state}/tailscale (the platform's
# guest.env already sets XDG_STATE_HOME=~/.local/state, persistent).
# Install-location stickiness, same shape as BINDIR/SSHDIR above:
# the state file IS the node's identity, so a box whose node state
# already lives at the legacy workspace path
# (~/workspace/.local/share/tailscale — where pre-XDG installs
# pinned it) KEEPS it — silently moving state would re-register
# the node as a new machine. RS_TS_STATE_DIR (process env, or the
# stack .env) overrides both — it is also the deliberate-migration
# path: stop the daemon, move the state dir, set it, restart.
LEGACY_TSDIR="$WS/.local/share/tailscale"
_ts_state_dir_env="$(grep -E '^RS_TS_STATE_DIR=' "$SSHDIR/.env" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
if [[ -n "${RS_TS_STATE_DIR:-}" ]]; then
  TSDIR="$RS_TS_STATE_DIR"
elif [[ -n "$_ts_state_dir_env" ]]; then
  TSDIR="$_ts_state_dir_env"
elif [[ -f "$LEGACY_TSDIR/state/tailscaled.state" ]]; then
  TSDIR="$LEGACY_TSDIR"
else
  TSDIR="${XDG_STATE_HOME:-$HOME/.local/state}/tailscale"
fi
unset _ts_state_dir_env
REVDIR="$SSHDIR/reverse"
LOGDIR="$WS/logs"
TSVER=1.104.4
CLEANENV=(env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy)

say() { printf '\n== %s ==\n' "$*"; }

# ── Stack service user (--user / RS_SSH_USER; flag wins; default root) ──
# Governs THIS box's stack identity only: the join sshd's run/login user,
# the service home, the tailscaled run-user, and where the sshd-injected
# session-environment file lives. Peer-side literals (runner@<peer>,
# User runner in the peer configs) are the PEER's platform user and are
# deliberately NOT parameterized.
[[ "$SSH_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "invalid --user value: $SSH_USER" >&2; exit 2; }
if [[ "$SSH_USER" == root ]]; then
  SVC_HOME=/root
  SVC_PERMIT_ROOT_LOGIN=prohibit-password
  # Root's passwd home is /root (ephemeral), but /root/.ssh is a symlink
  # into $SSHDIR, so the environment file sshd reads for root physically
  # persists at $SSHDIR/environment.
  SVC_ENV_FILE="$SSHDIR/environment"
else
  SVC_HOME="$SSHDIR/home"
  SVC_PERMIT_ROOT_LOGIN=no
  SVC_ENV_FILE="$SVC_HOME/.ssh/environment"
fi
# Run a command as the service user (directly when it is root: setup and
# the generated launchers already run as root).
svc_run() {
  if [[ "$SSH_USER" == root ]]; then "$@"; else runuser -u "$SSH_USER" -- "$@"; fi
}

# ── Runtime verbs ───────────────────────────────────────────────────
# The stack is STARTED by this script's own verbs (--start-sshd,
# --start-ts, --loop, --check-reverse), replit-style: no launcher code
# is generated into the ssh store. Only DATA is generated (sshd_config,
# ssh client configs, the session-environment file, .env). Per-box
# values come from the flags and .env at run time, so there is no
# generated copy to drift from this source.
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
SELF_DIR="$(dirname "$SELF")"

revport() { local p; p="$(grep -E '^RS_REVERSE_PORT=' "$SSHDIR/.env" 2>/dev/null | tail -1 | cut -d= -f2 || true)"; echo "${p:-16801}"; }
revpeer() { local p; p="$(grep -E '^RS_REVERSE_PEER=' "$SSHDIR/.env" 2>/dev/null | tail -1 | cut -d= -f2 || true)"; echo "${p:-$PEER}"; }

# reverse-alloc — claim a reverse-forward port on the peer when
# RS_REVERSE_PORT=auto. The claim IS the bind: the probe ssh registers
# the forward with ExitOnForwardFailure and runs `true`; exit 0 means
# the port was ours for that session. A passive "is it free?" check
# would race — two claimants can both SEE a port free, they cannot
# both BIND it; the peer's sshd is the arbiter. "forwarding failed"
# advances to the next candidate; any other failure retries the SAME
# candidate (peer or network not ready — burning the range would help
# nobody). Args: $1=SSHDIR $2=PEER $3=LOG; transport ssh args follow.
# Prints the claimed port on stdout; the caller pins it into .env.
alloc_claim_port() {
  local sshdir=$1 peer=$2 log=$3; shift 3
  local cand=16801 out rc
  while [ $cand -le 16899 ]; do
    out=$(env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy \
      ssh -R 127.0.0.1:$cand:127.0.0.1:6800 \
      -p 6800 -i "$sshdir/id_ed25519" -o IdentitiesOnly=yes \
      -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ExitOnForwardFailure=yes -o ConnectTimeout=20 \
      "$@" \
      runner@$peer true 2>&1); rc=$?
    if [ $rc -eq 0 ]; then echo $cand; return 0; fi
    case "$out" in
      *"forwarding failed"*) cand=$((cand+1));;
      *) echo "[alloc] candidate $cand transient failure (rc=$rc), retrying same port" >>"$log"; sleep 15;;
    esac
  done
  return 1
}

# reassert_termix_user_units — restore the Termix user-manager stack
# after a redeploy (proven by redeploy #15, 2026-11-13 01:01 WIB):
# the Termix units live as USER units under $HOME/.config/systemd/user/
# (files survive — they are under ~), but three things do NOT survive:
#   (1) the /root/.config/systemd/user symlink (root's user manager
#       reads HOME=/root from passwd, not the runtime $HOME),
#   (2) systemd-logind (is-enabled static is NOT auto-start at boot;
#       nothing pulls it in here, so it is inactive after a boot),
#   (3) the linger flag in /var/lib/systemd/linger (outside ~).
# Without all three, user@0 never starts and the enabled Termix units
# stay down (8080: 000). Re-asserting all three lets the units
# auto-start on their own via default.target.wants — no manual start.
# Guarded: no-op when the Termix user units are not installed
# (other Muse VMs never migrated), and never fatal to the join.
reassert_termix_user_units() {
  local user_units="$HOME/.config/systemd/user"
  [[ -f "$user_units/termix-backend.service" ]] || return 0
  command -v systemctl >/dev/null 2>&1 || return 0
  command -v loginctl >/dev/null 2>&1 || return 0
  # (1) the /root pointer: only touch it when it is a symlink or
  # absent — a real directory there would be a divergent copy, not
  # ours to delete.
  if [[ "$(readlink /root/.config/systemd/user 2>/dev/null)" != "$user_units" ]]; then
    if [[ -L /root/.config/systemd/user || ! -e /root/.config/systemd/user ]]; then
      mkdir -p /root/.config/systemd
      rm -f /root/.config/systemd/user
      ln -s "$user_units" /root/.config/systemd/user
    else
      echo "[termix] /root/.config/systemd/user is a real directory, leaving it alone" >&2
    fi
  fi
  # (2) logind must be running before linger can be enabled.
  systemctl start systemd-logind 2>/dev/null || true
  # (3) lingering starts user@0 immediately and at every boot after;
  # the enabled user units then start on their own.
  loginctl enable-linger root 2>/dev/null || true
  return 0
}

start_sshd() {
  # (Re)start the join sshd as $SSH_USER on 6800. Run as root after a
  # redeploy: /etc/passwd + /run + /root/.ssh are ephemeral; everything
  # else persists. Start-only-if-down; the permission end state is
  # re-asserted on every call (without it, both test boxes needed
  # manual permission surgery before sshd would start).
  if [[ "$(readlink /root/.ssh 2>/dev/null)" != "$SSHDIR" ]]; then rm -rf /root/.ssh; ln -s "$SSHDIR" /root/.ssh; fi
  # Termix user units (when installed): re-assert the three ephemeral
  # pieces the redeploy wipes, so the units auto-start with user@0.
  reassert_termix_user_units || true
  chmod o+x "$HOME" "$WS"
  # The store root itself needs the same guarantee, and opening its
  # ancestors is not enough: on a fresh box the store IS ~/.ssh, and
  # the service user must traverse INTO it to reach rootfs/ (the sshd
  # binary) and join-tailnet/ (config + host key). Nothing pins the
  # root's creation mode — mkdir inherits the caller's umask (770
  # under the agent shells' 007, 700 under 077; both shut for a
  # non-root service user when the dir is root-owned) — so re-assert
  # traverse on every start, like the other end states below. o+x
  # only: traverse, never readability.
  [[ -d "$SSHDIR" ]] && chmod o+x "$SSHDIR"
  if [[ "$SSH_USER" != root ]]; then
    id "$SSH_USER" >/dev/null 2>&1 || useradd -d "$SVC_HOME" -s /bin/bash "$SSH_USER"
  fi
  getent passwd sshd >/dev/null 2>&1 || useradd -r -d /run/sshd -s /usr/sbin/nologin sshd
  mkdir -p /run/sshd && chmod 755 /run/sshd
  mkdir -p "$LOGDIR"
  # join-tailnet is pinned SHUT: owned by the service user, 700. sshd
  # (service user) keeps everything it needs — pid write, host key,
  # config, authorized_keys — as owner; setup runs as root and is
  # unaffected; nobody else can read, write or traverse. Replaces the
  # 777 of the 2026-11-02 idmapped-mount workaround: since the host-key
  # fix every file inside is service-user-owned 600, so the loose dir
  # mode is no longer load-bearing — it only left the dir's CONTENTS
  # replaceable by any local user (integrity hole, found 2026-11-07).
  chown "$SSH_USER:$SSH_USER" "$SSHDIR/join-tailnet" 2>/dev/null || true
  chmod 700 "$SSHDIR/join-tailnet"
  if [[ "$SSH_USER" != root ]]; then
    chown "$SSH_USER:$SSH_USER" "$SVC_HOME" 2>/dev/null || true; chmod 755 "$SVC_HOME"
    if [[ -f "$SSHDIR/join-tailnet/ssh_host_ed25519_key" ]]; then
      chown "$SSH_USER:$SSH_USER" "$SSHDIR/join-tailnet/ssh_host_ed25519_key" 2>/dev/null || true; chmod 600 "$SSHDIR/join-tailnet/ssh_host_ed25519_key" 2>/dev/null || true
    fi
  else
    if [[ -f "$SSHDIR/join-tailnet/ssh_host_ed25519_key" ]]; then
      chown root:root "$SSHDIR/join-tailnet/ssh_host_ed25519_key" 2>/dev/null || true; chmod 600 "$SSHDIR/join-tailnet/ssh_host_ed25519_key" 2>/dev/null || true
    fi
  fi
  chown "$SSH_USER:$SSH_USER" "$SSHDIR/join-tailnet/authorized_keys" 2>/dev/null || true; chmod 600 "$SSHDIR/join-tailnet/authorized_keys" 2>/dev/null || true
  chown "$SSH_USER:$SSH_USER" "$SSHDIR/join-tailnet/sshd_config" 2>/dev/null || true; chmod 600 "$SSHDIR/join-tailnet/sshd_config" 2>/dev/null || true
  if [[ "$SSH_USER" != root ]]; then
    chown "$SSH_USER:$SSH_USER" "$SVC_HOME/.ssh/environment" 2>/dev/null || true; chmod 600 "$SVC_HOME/.ssh/environment" 2>/dev/null || true
    if [[ -f "$SSHDIR/join-tailnet/ssh_host_ed25519_key" ]]; then
      runuser -u "$SSH_USER" -- test -r "$SSHDIR/join-tailnet/ssh_host_ed25519_key" 2>/dev/null || { chown "$SSH_USER:$SSH_USER" "$SSHDIR/join-tailnet/ssh_host_ed25519_key"; chmod 600 "$SSHDIR/join-tailnet/ssh_host_ed25519_key"; }
    fi
  else
    chown root:root "$SSHDIR/environment" 2>/dev/null || true; chmod 600 "$SSHDIR/environment" 2>/dev/null || true
  fi
  if [[ -f "$SSHDIR/join-tailnet/sshd.pid" ]] && kill -0 "$(cat "$SSHDIR/join-tailnet/sshd.pid")" 2>/dev/null; then
    echo "sshd already running (pid $(cat "$SSHDIR/join-tailnet/sshd.pid"))"; return 0
  fi
  if [[ "$SSH_USER" != root ]]; then
    runuser -u "$SSH_USER" -- bash -c \
      "setsid $SSHDIR/rootfs/usr/sbin/sshd -f $SSHDIR/join-tailnet/sshd_config -E $LOGDIR/sshd.log </dev/null >/dev/null 2>&1 & disown"
  else
    bash -c \
      "setsid $SSHDIR/rootfs/usr/sbin/sshd -f $SSHDIR/join-tailnet/sshd_config -E $LOGDIR/sshd.log </dev/null >/dev/null 2>&1 & disown"
  fi
  local _up=0
  for _ in $(seq 1 10); do
    if timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/6800; IFS= read -r -t 1 l <&3; echo "$l"' 2>/dev/null; then _up=1; break; fi
    sleep 1
  done
  if [[ "$_up" -eq 0 ]]; then
    # The launch above discards ALL of sshd's output, so a failed
    # start is otherwise invisible — the join would "succeed" with
    # no sshd listening. Name the log and the usual cause instead of
    # returning silently. (Warning only: exit behavior unchanged.)
    echo "WARNING: sshd is not answering on port 6800 — the launch failed. Common cause: $SSH_USER cannot traverse into $SSHDIR or read the host key in join-tailnet/. See $LOGDIR/sshd.log"
  fi
}

start_tailscale() {
  # Userspace tailscale node for a Muse VM. Three sandbox fixes, all
  # required: 1. real control-plane IPs via an /etc/hosts override
  # bind-mounted in a private mount namespace (stock resolver is
  # fake-IP); 2. daemon runs with the *_PROXY env scrubbed (proxied
  # control fetches get reset by the gateway; direct dials to real IPs
  # succeed); 3. listeners on 127.0.0.1, never "localhost".
  # Run in a FOREGROUND agent turn (its first direct dials may need an
  # egress approval a background run cannot mint).
  local sock="$TSDIR/tailscaled.sock"
  local tsctl="$BINDIR/tailscale --socket=$sock"
  local TSENV=(env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy -u NO_PROXY -u no_proxy)
  local runas=() daemon_runas=""
  if [[ "$SSH_USER" != root ]]; then
    runas=(runuser -u "$SSH_USER" --)
    daemon_runas="runuser -u $SSH_USER -- "
  fi
  chmod o+x "$HOME" "$WS" "$WS/.local" "$WS/.local/share"
  # The daemon (service user) must traverse every ancestor of the
  # resolved state dir to reach its socket — wherever TSDIR landed
  # (XDG state home or legacy workspace share).
  local _anc="$TSDIR"
  while [[ "$_anc" == "$HOME"/* ]]; do [ -d "$_anc" ] && chmod o+x "$_anc" || true; _anc="$(dirname "$_anc")"; done
  [[ -d "$WS/tools" ]] && chmod o+x "$WS/tools"
  [[ -d "$BINDIR" ]] && chmod o+x "$BINDIR"
  if [[ "$SSH_USER" != root ]]; then
    id "$SSH_USER" >/dev/null 2>&1 || useradd -d "$SVC_HOME" -s /bin/bash "$SSH_USER"
  fi
  mkdir -p "$TSDIR/state" "$LOGDIR"
  # The state tree holds the node identity: pin it shut like
  # join-tailnet — service-user-owned, 700. tailscaled runs as the
  # service user (owner keeps full access); the ancestor walk above
  # only adds traverse (o+x) and runs BEFORE this pin, so 700 stands.
  chown "$SSH_USER:$SSH_USER" "$TSDIR" "$TSDIR/state" 2>/dev/null || true
  chmod 700 "$TSDIR" "$TSDIR/state"
  if [[ -f "$SSHDIR/.env" ]]; then set -a; source "$SSHDIR/.env"; set +a; fi
  # dig's anycast answers rotate, and most endpoints are unreachable
  # through this gateway at any given time (observed: one of four
  # probed answered; a dead pick = "fetch control key: context deadline
  # exceeded" and a node stuck Logged out). Probe the candidates and
  # pin the first that actually answers; .102 is the known-good
  # fallback. Fixed preference order first: the egress approvals are
  # keyed per destination IP, so re-pinning the SAME control IP every
  # boot reuses the existing approval instead of minting a new prompt.
  local IP="" cand
  for cand in $(printf '%s\n' 192.200.0.102 192.200.0.107 192.200.0.110 192.200.0.104 192.200.0.106 192.200.0.112 $(dig +short +time=4 +tries=1 @8.8.8.8 controlplane.tailscale.com A 2>/dev/null | grep -E '^[0-9.]+$') | awk '!seen[$0]++'); do
    if timeout 8 curl -s -o /dev/null --noproxy '*' --resolve "controlplane.tailscale.com:443:$cand" --max-time 6 "https://controlplane.tailscale.com/key?v=148"; then IP="$cand"; break; fi
  done
  [[ -n "$IP" ]] || IP="192.200.0.102"
  cp /etc/hosts "$TSDIR/hosts"
  printf '%s controlplane.tailscale.com\n%s login.tailscale.com\n' "$IP" "$IP" >> "$TSDIR/hosts"
  if ! "${runas[@]}" "${TSENV[@]}" $tsctl status >/dev/null 2>&1 \
     && ! "${runas[@]}" "${TSENV[@]}" $tsctl status 2>&1 | grep -q "Logged out"; then
    local p
    for p in $(pgrep tailscaled 2>/dev/null); do
      tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | grep -qF "$TSDIR/" && kill "$p" || true
    done
    sleep 1; rm -f "$sock"
    unshare -m bash -c "
      mount --bind $TSDIR/hosts /etc/hosts || exit 1
      ${daemon_runas}env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy -u NO_PROXY -u no_proxy \
        setsid $BINDIR/tailscaled --tun=userspace-networking \
          --socks5-server=127.0.0.1:1056 --outbound-http-proxy-listen=127.0.0.1:1056 \
          --state=$TSDIR/state/tailscaled.state --statedir=$TSDIR/state --socket=$sock \
          </dev/null >>$LOGDIR/tailscaled.log 2>&1 &
    "
    for _ in $(seq 1 12); do [[ -S "$sock" ]] && break; sleep 1; done
  fi
  [[ -S "$sock" ]] || { echo "tailscaled socket not ready — see $LOGDIR/tailscaled.log"; return 1; }
  # Wait for a definitive status line: the "Tailscale is starting"
  # health block can hide a "Logged out." first line and skip the join.
  local STATE=""
  for _ in $(seq 1 15); do
    STATE="$("${runas[@]}" "${TSENV[@]}" $tsctl status 2>&1 | head -1 || true)"
    [[ "$STATE" != "# Health check:" ]] && break
    sleep 1
  done
  echo "status: $STATE"
  if [[ "$STATE" == "Logged out." ]]; then
    if [[ -n "${TAILSCALE_AUTH_KEY:-}" ]]; then
      "${runas[@]}" "${TSENV[@]}" $tsctl up \
        --authkey "$TAILSCALE_AUTH_KEY" --hostname "${TAILSCALE_NODE_NAME:-muse-join}" --accept-routes=false 2>&1 \
        | sed -E 's/(tskey-)[A-Za-z0-9_-]+/\1***/g'
    else
      echo "logged out and no TAILSCALE_AUTH_KEY in $SSHDIR/.env"; return 1
    fi
  fi
  "${runas[@]}" "${TSENV[@]}" $tsctl status 2>&1 | head -3 || true
  "${runas[@]}" "${TSENV[@]}" $tsctl ip -4 2>/dev/null || true
}

run_loop() {
  # The node-carried reverse loop (hop boxes only). Runs as root — a
  # non-root service user cannot read the client key. Foreground:
  # callers setsid it. Guard: ExitOnForwardFailure + ServerAlive on
  # the client, exponential backoff 5s -> 300s (reset after >120s
  # uptime). Peer/port come from .env (RS_REVERSE_PEER / _PORT).
  local log="$LOGDIR/reverse-node.log"
  local peer port
  peer="$(revpeer)"
  port="$(revport)"
  local extra=(-o "ProxyCommand=$BINDIR/tailscale --socket=$TSDIR/tailscaled.sock nc %h %p")
  mkdir -p "$LOGDIR" "$REVDIR"
  exec 9>"$REVDIR/reverse-node.lock"; flock -n 9 || return 0
  local PORT="$port"
  if [ "$PORT" = auto ]; then
    PORT=$(alloc_claim_port "$SSHDIR" "$peer" "$log" "${extra[@]}") || { echo "[alloc] no port claimed in 16801-16899" >>"$log"; return 1; }
    if grep -q "^RS_REVERSE_PORT=" "$SSHDIR/.env" 2>/dev/null; then sed -i "s/^RS_REVERSE_PORT=.*/RS_REVERSE_PORT=$PORT/" "$SSHDIR/.env"; else echo "RS_REVERSE_PORT=$PORT" >>"$SSHDIR/.env"; fi
    echo "[alloc] claimed peer port $PORT (pinned to .env RS_REVERSE_PORT)" >>"$log"
  fi
  local delay=5 start lived
  while true; do
    start=$(date +%s)
    echo "[--loop] dialing $(date -Is)" >>"$log"
    "${CLEANENV[@]}" ssh -N \
      -R 127.0.0.1:$PORT:127.0.0.1:6800 \
      -p 6800 -i "$SSHDIR/id_ed25519" -o IdentitiesOnly=yes \
      -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ExitOnForwardFailure=yes \
      -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
      "${extra[@]}" \
      runner@"$peer" >>"$log" 2>&1 || true
    lived=$(( $(date +%s) - start ))
    echo "[--loop] ended, lived ${lived}s, redial in ${delay}s" >>"$log"
    sleep "$delay"
    if (( lived > 120 )); then delay=5; else delay=$(( delay * 2 )); (( delay > 300 )) && delay=300; fi
  done
}

check_reverse() {
  # Probe the reverse forward FROM the peer: OK / ZOMBIE / DOWN, plus
  # the peer's live 16800-16899 listener map.
  local port; port="$(revport)"
  ssh -F "$REVDIR/ssh_config_ts" -o "ProxyCommand=$BINDIR/tailscale --socket=$TSDIR/tailscaled.sock nc %h %p" repl-test '
SSH=$(command -v ssh 2>/dev/null || ls /nix/store/*-replit-runtime-path/bin/ssh 2>/dev/null | head -1)
KEYF=$HOME/.ssh/join-tailnet/host_ed25519; [ -f "$KEYF" ] || KEYF=$HOME/.ssh/id_muse_vm
probe() {
  local port=$1 name=$2 out
  out=$(timeout 20 "$SSH" -p "$port" -i "$KEYF" -o IdentitiesOnly=yes \
        -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        '"$SSH_USER"'@127.0.0.1 "hostname" 2>&1)
  if [[ "$out" == *"htch-runtime"* ]]; then echo "$name ($port): OK"
  elif [[ "$out" == *"Connection refused"* ]]; then echo "$name ($port): DOWN"
  else echo "$name ($port): ZOMBIE — $(echo "$out" | tail -1 | cut -c1-80)"; fi
}
probe '"$port"' node
echo "peer listeners 16800-16899:"
while read sl la ra st rest; do
  if [ "$st" = 0A ]; then
    ph=${la##*:}
    case $ph in 41[ABCDEF][0-9A-F]|420[0-3]) echo "  $((16#$ph))";; esac
  fi
done < /proc/net/tcp
' 2>&1 | grep -v "Warning: Permanently"
}

say "stack service user: $SSH_USER (service home: $SVC_HOME)"
if [[ "$SSH_USER" == root ]]; then
  cat <<'WARN'
WARNING: the stack service user is root. SSH sessions will land as root
and can read the stack .env (the tailnet auth key) and the client
private key in the ssh store. The fleet-proven isolated setup is
--user runner; choose root only when you accept that exposure.
WARN
fi

if [[ $VERIFY -eq 1 ]]; then
  say "verify"
  timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/6800; IFS= read -r -t 1 l <&3; echo "sshd: $l"' 2>/dev/null || echo "sshd: DOWN"
  NODE_STATUS="$(svc_run "${CLEANENV[@]}" "$BINDIR/tailscale" --socket="$TSDIR/tailscaled.sock" status 2>&1 | head -2)"
  [[ -n "$NODE_STATUS" ]] && printf '%s
' "$NODE_STATUS" || echo "node: DOWN"
  echo "reverse forwards (probe runs from the peer): bash $SETUP_ENTRY --machine muse --user $SSH_USER --check-reverse"
  exit 0
fi

phase_sshd() {
say "layout + users"
chmod o+x "$HOME" "$WS"
mkdir -p "$SSHDIR/join-tailnet" "$SSHDIR/bin" "$REVDIR" "$BINDIR" "$TSDIR/state" "$WS/config" "$LOGDIR"
chown "$SSH_USER:$SSH_USER" "$LOGDIR" 2>/dev/null || true
chmod o+x "$WS/.local" "$WS/.local/share" "$SSHDIR"
# Same traverse walk as start_tailscale: the daemon's ancestors of
# the resolved state dir must be walkable by the service user.
_anc="$TSDIR"; while [[ "$_anc" == "$HOME"/* ]]; do [ -d "$_anc" ] && chmod o+x "$_anc" || true; _anc="$(dirname "$_anc")"; done; unset _anc
# The walk just gave TSDIR itself o+x; re-pin it shut (700,
# service-user-owned — see start_tailscale) so phase order cannot
# leave the state dir traverse-open.
if [[ -d "$TSDIR" ]]; then chown "$SSH_USER:$SSH_USER" "$TSDIR" 2>/dev/null || true; chmod 700 "$TSDIR"; fi
[[ -d "$WS/tools" ]] && chmod o+x "$WS/tools"
chmod o+x "$BINDIR"
# sshd runs as the service user and must write its pid inside
# join-tailnet (its log goes to $WS/logs, also service-user-owned),
# read its host key and authorized_keys, and land in a
# home it owns. Pin the end state here AND in start_sshd():
# without this, both test boxes needed manual permission surgery before
# sshd would start. The store root is re-pinned too (the layout block's
# o+x is the only earlier assertion): creation mode is whatever the
# caller's umask made it, and the service user must traverse the root
# to reach join-tailnet/ and rootfs/ below it.
chmod o+x "$SSHDIR"
# join-tailnet itself is pinned 700, service-user-owned (see the note
# in start_sshd) — NOT the old 777 idmapped workaround.
chown "$SSH_USER:$SSH_USER" "$SSHDIR/join-tailnet" 2>/dev/null || true
chmod 700 "$SSHDIR/join-tailnet"
if [[ "$SSH_USER" != root ]]; then
  mkdir -p "$SVC_HOME"
  chown "$SSH_USER:$SSH_USER" "$SVC_HOME" 2>/dev/null || true; chmod 755 "$SVC_HOME"
  id "$SSH_USER" >/dev/null 2>&1 || useradd -d "$SVC_HOME" -s /bin/bash "$SSH_USER"
fi
getent passwd sshd >/dev/null 2>&1 || useradd -r -d /run/sshd -s /usr/sbin/nologin sshd
mkdir -p /run/sshd && chmod 755 /run/sshd

say "openssh (extracted .deb — no package install, nothing in /usr/bin)"
if ! command -v sshd >/dev/null && [[ ! -x "$SSHDIR/rootfs/usr/sbin/sshd" ]]; then
  DEB=/tmp/openssh-server.deb
  curl -fsSL -o "$DEB" "http://archive.ubuntu.com/ubuntu/pool/main/o/openssh/openssh-server_9.6p1-3ubuntu13.20_amd64.deb"
  mkdir -p "$SSHDIR/rootfs"
  dpkg -x "$DEB" "$SSHDIR/rootfs"
  rm -f "$DEB"
fi
[[ -x "$SSHDIR/rootfs/usr/sbin/sshd" ]] && ln -sf "$SSHDIR/rootfs/usr/sbin/sshd" "$SSHDIR/bin/sshd"

say "sshd stack"
[[ -f "$SSHDIR/join-tailnet/ssh_host_ed25519_key" ]] || \
  ssh-keygen -t ed25519 -f "$SSHDIR/join-tailnet/ssh_host_ed25519_key" -N '' >/dev/null
if [[ "$SSH_USER" == root ]]; then
  chown root:root "$SSHDIR/join-tailnet/ssh_host_ed25519_key" 2>/dev/null || true
  chmod 600 "$SSHDIR/join-tailnet/ssh_host_ed25519_key"
else
  # sshd 9.6 rejects a 0640 host key as too open (verified on
  # muse-test, 2026-11-07): the key must be 0600, owned by the
  # service user whose sshd reads it.
  chown "$SSH_USER:$SSH_USER" "$SSHDIR/join-tailnet/ssh_host_ed25519_key" 2>/dev/null || true
  chmod 600 "$SSHDIR/join-tailnet/ssh_host_ed25519_key"
fi
touch "$SSHDIR/join-tailnet/authorized_keys"; chmod 600 "$SSHDIR/join-tailnet/authorized_keys"
# Default trust: the fleet hop (mirrors the replit skill's hermes-join-hop).
# Every box stood up with this setup authorizes the muse-hop key —
# the operator's main Muse VM — from birth, so onboarding never needs a
# per-machine key exchange; the hop reaches every fleet box directly and
# any-to-any goes through it (star, not mesh: one distributed pubkey).
# The hop's private key never leaves the hop machine. Override by setting
# RS_AUTHORIZED_KEYS (one pubkey per line) in the .env before running.
HOP_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtOrYNU7XhUsf+6dygX5j9xdDlT7hId3NO7gwi8GhBq muse-hop"
seed_key() { grep -q " $2 " "$SSHDIR/join-tailnet/authorized_keys" 2>/dev/null || echo "$1" >> "$SSHDIR/join-tailnet/authorized_keys"; }
if [[ -n "${RS_AUTHORIZED_KEYS:-}" ]]; then
  while IFS= read -r line; do
    [[ -n "$line" ]] && seed_key "$line" "$(echo "$line" | awk '{print $2}')"
  done <<< "$RS_AUTHORIZED_KEYS"
else
  seed_key "$HOP_KEY" "$(echo "$HOP_KEY" | awk '{print $2}')"
fi
chown "$SSH_USER:$SSH_USER" "$SSHDIR/join-tailnet/authorized_keys" 2>/dev/null || true
chmod 600 "$SSHDIR/join-tailnet/authorized_keys"
cat > "$SSHDIR/join-tailnet/sshd_config" <<EOF
Port 6800
ListenAddress 0.0.0.0
Protocol 2
HostKey $SSHDIR/join-tailnet/ssh_host_ed25519_key
PidFile $SSHDIR/join-tailnet/sshd.pid
AuthorizedKeysFile $SSHDIR/join-tailnet/authorized_keys
PasswordAuthentication no
PubkeyAuthentication yes
# StrictModes off is load-bearing on this platform: the idmapped home
# mount forces group/world-writable modes on the persistent tree (the
# proven live stack runs home at 777), and StrictModes would refuse
# every authorized_keys for exactly that. Key-only auth stays on.
StrictModes no
ChallengeResponseAuthentication no
PermitRootLogin $SVC_PERMIT_ROOT_LOGIN
AllowUsers $SSH_USER
UsePAM no
# Session environment comes from sshd itself (~/.ssh/environment in the
# service home), not from shell rc: login, non-login and `ssh host cmd`
# sessions each source different rc files (or none), which is why the
# shared-env vars kept vanishing in ssh sessions.
PermitUserEnvironment yes
PermitTunnel no
AllowTcpForwarding yes
GatewayPorts no
ClientAliveInterval 30
ClientAliveCountMax 3
Subsystem sftp $SSHDIR/rootfs/usr/lib/openssh/sftp-server
EOF
chown "$SSH_USER:$SSH_USER" "$SSHDIR/join-tailnet/sshd_config" 2>/dev/null || true; chmod 600 "$SSHDIR/join-tailnet/sshd_config" 2>/dev/null || true
[[ -f "$SSHDIR/id_ed25519" ]] || ssh-keygen -t ed25519 -f "$SSHDIR/id_ed25519" -N '' >/dev/null
# ~/.ssh shim: only when the tree does NOT live at ~/.ssh (legacy or
# RS_SSH_DIR placements) — tooling that resolves ~/.ssh via $HOME
# would otherwise never see the store. When SSHDIR IS ~/.ssh the real
# directory is already in place (mkdir'd at the top of this phase).
if [[ "$SSHDIR" != "$HOME/.ssh" ]]; then
  [[ -e "$HOME/.ssh" ]] || ln -s "$SSHDIR" "$HOME/.ssh"
fi
# /root/.ssh always points at the store: root's passwd home is /root
# (ephemeral), so tooling that resolves ~ via passwd needs the link.
if [[ "$(readlink /root/.ssh 2>/dev/null)" != "$SSHDIR" ]]; then rm -rf /root/.ssh; ln -s "$SSHDIR" /root/.ssh; fi

say "shared env (config/env.sh) + .env template"
cat > "$WS/config/env.sh" <<EOF
# Shared environment for this VM — non-secret config only.
# XDG values mirror the platform's own guest.env (runtime-cell):
# HOME-based, all on the persistent home volume. (The tailscale
# daemon's state dir is runtime state: it follows XDG_STATE_HOME,
# resolved by setup.sh — see RS_TS_STATE_DIR in the stack .env.)
export XDG_DATA_HOME="\$HOME/.local/share"
export XDG_CONFIG_HOME="\$HOME/.config"
export XDG_CACHE_HOME="\$HOME/.cache"
export XDG_STATE_HOME="\$HOME/.local/state"
# Toolchain anchor: the persistent target path for fleet tooling.
export MUSE_HOME="\$HOME/workspace"
case ":\$PATH:" in
  *":\$HOME/workspace/tools:"*) ;;
  *) export PATH="\$HOME/workspace/tools:\$HOME/workspace/.local/bin:$SSHDIR/bin:\$PATH" ;;
esac
if [ -r "$SSHDIR/.env" ]; then
  set -a; . "$SSHDIR/.env"; set +a
fi
EOF
chmod 644 "$WS/config/env.sh"
if ! grep -q "muse shared env" "$HOME/.bashrc" 2>/dev/null; then
  cat >> "$HOME/.bashrc" <<'EOF'

# >>> muse shared env >>>
[ -f "$HOME/workspace/config/env.sh" ] && . "$HOME/workspace/config/env.sh"
# <<< muse shared env <<<
EOF
fi
if [[ ! -f "$SSHDIR/.env" ]]; then
  cat > "$SSHDIR/.env" <<EOF
TAILSCALE_AUTH_KEY=
TAILSCALE_NODE_NAME=muse-join
RS_SSH_USER=$SSH_USER
# (the stack service user chosen at install time; setup's --user flag overrides it)
RS_SSH_DIR=$SSHDIR
# (the stack tree's home, recorded at install time; the RS_SSH_DIR env var overrides it.
#  Fresh installs use ~/.ssh — the official location, a real directory. A box whose tree
#  already lives in ~/workspace/.ssh keeps that path: the stack never relocates itself.
#  Change this to migrate deliberately, the same way RS_TS_BIN_DIR migrates the binaries.)
RS_TS_STATE_DIR=$TSDIR
# (the tailscale daemon's state dir, recorded at install time; the RS_TS_STATE_DIR env
#  var overrides it. Fresh installs use \$XDG_STATE_HOME/tailscale — daemon state is
#  runtime state and follows the XDG state home. A box whose node state already lives
#  in ~/workspace/.local/share/tailscale keeps that path: the state file is the node's
#  identity and the stack never relocates it. Change this to migrate deliberately —
#  stop the daemon first and move the whole state dir, socket path included.)
#RS_TS_BIN_DIR= (optional override: where the tailscale binaries live. Defaults:
# a fresh install uses ~/workspace/tools (flat), but a box already running tailscale
# from ~/workspace/.local/bin keeps that path — egress approvals are keyed by
# binary path, so the stack never relocates itself. Set this to migrate deliberately.)
#RS_AUTHORIZED_KEYS= (optional override: pubkeys to authorize instead of the muse-hop default)
#RS_REVERSE_PEER= (HOP ONLY: peer IP that receives this box's reverse forward. Leaves leave
#  this unset — a leaf runs NO reverse loop; only the fleet hop opens one, to the repl hop.)
#RS_REVERSE_PORT=16801 (forward port on the peer when RS_REVERSE_PEER is set;
# "auto" = claim the first free port in 16801-16899 on the peer at first run and pin it here)
EOF
  chmod 600 "$SSHDIR/.env"
  echo "created $SSHDIR/.env — fill TAILSCALE_AUTH_KEY (600, never commit it), then re-run this script"
fi

say "session environment (sshd-injected, not rc)"
# sshd reads ~/.ssh/environment under the service user's passwd home:
# $SVC_HOME/.ssh/environment — which for root is the file $SVC_ENV_FILE
# ($SSHDIR/environment, reached through the /root/.ssh symlink).
if [[ "$SSH_USER" != root ]]; then mkdir -p "$SVC_HOME/.ssh"; fi
# XDG below mirrors the platform's guest.env values (HOME-based) so an
# ssh session sees the same environment the platform's own processes get.
cat > "$SVC_ENV_FILE" <<EOF
MUSE_HOME=$WS
XDG_DATA_HOME=$HOME/.local/share
XDG_CONFIG_HOME=$HOME/.config
XDG_CACHE_HOME=$HOME/.cache
XDG_STATE_HOME=$HOME/.local/state
PATH=$BINDIR:$SSHDIR/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
BASH_ENV=$WS/config/env.sh
EOF
if [[ "$SSH_USER" != root ]]; then
  chown -R "$SSH_USER:$SSH_USER" "$SVC_HOME/.ssh" 2>/dev/null || true
  chmod 700 "$SVC_HOME/.ssh"
fi
chmod 600 "$SVC_ENV_FILE"
# No landing cd: interactive sessions land in the service home itself
# (the passwd home — ~/.ssh/home on a fresh box), decided 2026-11-04.
# An earlier template appended a "muse landing" block to the service
# .bashrc that cd'd interactive shells into $MUSE_HOME (the workspace —
# a Replit-landing carry-over from when the service home lived inside
# the workspace tree). Remove that block wherever a previous run left
# it; MUSE_HOME stays as an environment anchor for tooling, not a
# working directory.
touch "$SVC_HOME/.bashrc"
sed -i '/# >>> muse landing >>>/,/# <<< muse landing <<</d' "$SVC_HOME/.bashrc" 2>/dev/null || true
cat > "$SVC_HOME/.bash_profile" <<'EOF'
[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"
EOF
chown "$SSH_USER:$SSH_USER" "$SVC_HOME/.bashrc" "$SVC_HOME/.bash_profile" 2>/dev/null || true

# sshd itself is started by start_sshd() (a runtime verb of this
# script) — no launcher code is generated.

say "ssh client configs (peer $(revpeer))"
# The ProxyCommand helper is a real file in this skill
# (scripts/ts_proxy_connect.py); the configs point at it by absolute
# path — re-running --sshd refreshes the path if the skill ever moves.
rm -f "$REVDIR/ts_proxy_connect.py"   # stale generated copy (pre-refactor installs)
cat > "$REVDIR/ssh_config_ts" <<EOF
Host repl-test
  HostName $(revpeer)
  Port 6800
  User runner
  IdentityFile $SSHDIR/id_ed25519
  IdentitiesOnly yes
  ProxyCommand python3 $MUSE_PAYLOAD_DIR/ts_proxy_connect.py %h %p
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
EOF
cat > "$SSHDIR/config" <<EOF
Host repl-test
  HostName $(revpeer)
  Port 6800
  User runner
  IdentityFile $SSHDIR/id_ed25519
  IdentitiesOnly yes
  ProxyCommand python3 $MUSE_PAYLOAD_DIR/ts_proxy_connect.py %h %p
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
EOF
# The reverse loop and its probe are runtime verbs of this script
# (--loop / --check-reverse) — nothing is generated for them.

}
phase_tailscale() {
say "tailscale binaries (pinned $TSVER, checksum verified)"
if [[ ! -x "$BINDIR/tailscaled" ]]; then
  mkdir -p "$BINDIR"
  TGZ="$(tailscale_asset_name "$TSVER")"
  curl -fsSL -o "/tmp/$TGZ" "https://pkgs.tailscale.com/stable/$TGZ"
  # Upstream's .sha256 may be a bare hash with no filename, which makes
  # `sha256sum -c` fail ("no properly formatted checksum lines") — take
  # the first field, robust to both formats, and let core's verifier
  # do the comparison.
  EXPECTED="$(curl -fsSL "https://pkgs.tailscale.com/stable/$TGZ.sha256" | awk '{print $1}')"
  verify_sha256 "/tmp/$TGZ" "$EXPECTED" "tailscale ($TGZ)"
  tar -xzf "/tmp/$TGZ" -C /tmp
  install -m755 "/tmp/${TGZ%.tgz}/tailscale" "/tmp/${TGZ%.tgz}/tailscaled" "$BINDIR/"
  rm -rf "/tmp/$TGZ" "/tmp/${TGZ%.tgz}"
fi
chown "$SSH_USER:$SSH_USER" "$TSDIR" 2>/dev/null || true

# The node itself is started by start_tailscale() (a runtime verb
# of this script) — no launcher code is generated.

}
phase_join() {
say "start the stack"
mkdir -p "$LOGDIR"
# REVPORT lives in .env; derive it here. (phase_sshd used to set it as
# a render side effect, but -j skips that phase whenever it can — on
# re-runs the hop-mode branch then died under set -u BEFORE the loop
# launched. Deriving from .env directly removes that coupling.)
REVPORT="$(revport)"
start_sshd || true
if grep -q "^TAILSCALE_AUTH_KEY=.\+" "$SSHDIR/.env"; then
  start_tailscale || true
  if grep -qE "^RS_REVERSE_PEER=.+" "$SSHDIR/.env"; then
    (setsid bash "$SELF" --user "$SSH_USER" --loop >>"$LOGDIR/reverse-node.outer.log" 2>&1 &)
    echo "hop mode (RS_REVERSE_PEER set): node-carried reverse loop launched on port $REVPORT; verify shortly: bash $SELF --user $SSH_USER --check-reverse"
  else
    echo "leaf mode (RS_REVERSE_PEER unset): no reverse loop launched — only the fleet hop runs one. This box is reachable through the hop; it opens no tunnels and registers its key nowhere."
  fi
else
  echo "TAILSCALE_AUTH_KEY still empty in $SSHDIR/.env — sshd is up; fill the key and re-run to join (+ launch the reverse loop if this box is a hop)"
fi

say "handoff"
echo "client pubkey (register it ONLY at the fleet hop, and only if this box must initiate ssh to the hop):"
cat "$SSHDIR/id_ed25519.pub"
echo "authorized_keys already trusts the muse-hop key (seeded above) — nothing else belongs there by default"
echo "redeploy restore: bash $SETUP_ENTRY --machine muse --user $SSH_USER --join (starts sshd, the node, and the hop's loop — the skill script is the only code; there are no launcher scripts)"

}

# ── Interactive phase menu (arrow keys; pattern after the replit
#    setup's ui_menu.sh, scaled to this skill's three phases) ──────────
_MENU_ITEMS=(
  "sshd|sshd stack — users, openssh, keys, configs"
  "tailscale|tailscale — pinned binaries (node starts via join)"
  "join|join — start the stack, join the tailnet, launch the hop's loop"
)
_MENU_CURSOR=0
_MENU_TOGGLE=(0 0 0)

_menu_status() {
  local b n
  b="$(timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/6800; IFS= read -r -t 1 l <&3; echo "$l"' 2>/dev/null || true)"
  [[ -n "$b" ]] && echo "sshd: $b" || echo "sshd: DOWN"
  [[ -x "$BINDIR/tailscaled" ]] && echo "tailscale binaries: installed ($TSVER)" || echo "tailscale binaries: not installed"
  n="$(svc_run "${CLEANENV[@]}" "$BINDIR/tailscale" --socket="$TSDIR/tailscaled.sock" status 2>/dev/null | head -1 || true)"
  [[ -n "$n" ]] && echo "node: $n" || echo "node: DOWN"
}

_menu_draw() {
  clear
  echo "Muse VM — remote-access setup"
  echo "↑/↓ move · space toggle · enter confirm · q quit"
  echo ""
  echo "Current status"
  _menu_status
  echo ""
  local i desc mark prefix
  for i in "${!_MENU_ITEMS[@]}"; do
    IFS='|' read -r _ desc <<< "${_MENU_ITEMS[$i]}"
    [[ "${_MENU_TOGGLE[$i]}" -eq 1 ]] && mark="[✓]" || mark="[ ]"
    [[ "$i" -eq "$_MENU_CURSOR" ]] && prefix=">" || prefix=" "
    echo " $prefix $mark $desc"
  done
}

_menu_read_key() {
  local key
  if ! IFS= read -rsn1 key; then echo quit; return 0; fi
  if [[ "$key" == $'\x1b' ]]; then
    IFS= read -rsn2 key || true
    case "$key" in '[A') echo up ;; '[B') echo down ;; esac
  elif [[ "$key" == " " ]]; then echo space
  elif [[ -z "$key" ]]; then echo enter
  elif [[ "$key" == "q" || "$key" == "Q" ]]; then echo quit; fi
}

interactive_menu() {
  printf '\033[?25l'; trap 'printf "\033[?25h\n"; exit 130' INT
  set +e
  while true; do
    _menu_draw
    case "$(_menu_read_key)" in
      up)   _MENU_CURSOR=$(( (_MENU_CURSOR + ${#_MENU_ITEMS[@]} - 1) % ${#_MENU_ITEMS[@]} )) ;;
      down) _MENU_CURSOR=$(( (_MENU_CURSOR + 1) % ${#_MENU_ITEMS[@]} )) ;;
      space) _MENU_TOGGLE[$_MENU_CURSOR]=$(( 1 - _MENU_TOGGLE[$_MENU_CURSOR] )) ;;
      enter) break ;;
      quit)  printf '\033[?25h'; trap - INT; echo "Aborted."; exit 130 ;;
    esac
  done
  printf '\033[?25h'; trap - INT
  set -e
  [[ "${_MENU_TOGGLE[0]}" -eq 1 ]] && { DO_SSHD=1; SELECTED=1; }
  [[ "${_MENU_TOGGLE[1]}" -eq 1 ]] && { DO_TAILSCALE=1; SELECTED=1; }
  [[ "${_MENU_TOGGLE[2]}" -eq 1 ]] && { DO_JOIN=1; SELECTED=1; }
}


# ── dispatch ──────────────────────────────────────────────────────────
if [[ $DO_MENU -eq 1 ]] || { [[ $SELECTED -eq 0 ]] && [[ -t 0 ]]; }; then
  interactive_menu
fi
if [[ $SELECTED -eq 0 ]]; then
  # Bare run without a TTY (agent exec): the full setup, as before —
  # the menu must never deadlock a non-interactive shell.
  DO_SSHD=1 DO_TAILSCALE=1 DO_JOIN=1
fi
# Runtime verbs are terminal: run them (in dependency order) and stop.
run_verbs() {
  [[ $DO_START_SSHD -eq 1 ]] && start_sshd
  [[ $DO_START_TS -eq 1 ]] && start_tailscale
  [[ $DO_CHECK_REVERSE -eq 1 ]] && check_reverse
  [[ $DO_LOOP -eq 1 ]] && run_loop
  return 0
}
if [[ $((DO_START_SSHD + DO_START_TS + DO_CHECK_REVERSE + DO_LOOP)) -gt 0 ]]; then
  run_verbs
  exit 0
fi
if [[ $DO_JOIN -eq 1 ]]; then
  # -j implies the phases whose outputs it starts, when they are missing.
  [[ -f "$SSHDIR/join-tailnet/sshd_config" && -x "$SSHDIR/rootfs/usr/sbin/sshd" ]] || DO_SSHD=1
  [[ -x "$BINDIR/tailscaled" ]] || DO_TAILSCALE=1
fi
[[ $DO_SSHD -eq 1 ]] && phase_sshd
[[ $DO_TAILSCALE -eq 1 ]] && phase_tailscale
[[ $DO_JOIN -eq 1 ]] && phase_join
