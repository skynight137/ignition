# shellcheck shell=bash
# join entry (sshd key-only) — lets the operator's box reach this one over the tailnet
# instead of a browser canvas. Runtime story: references/join-bridge.md, proxy/
# port facts: references/exposing-ports.md.
# ─────────────────────────────────────────────────────────────────────────────
# Two container facts drive every path here:
#   * $HOME is WIPED on restart, $REPL_HOME is not. So ~/.ssh itself is made a
#     symlink into $REPL_HOME/.ssh — the operator's own ssh config, keys and
#     known_hosts then survive a reboot, and so do this sshd's host key and
#     authorized_keys (a new host key on every boot is an ssh warning cascade).
#   * an autostart line in a shell rc re-fires every time a terminal opens. The
#     daemon is therefore published as a `.replit` [workflows] entry, which runs
#     once per boot and is start/stop-able from the UI.
# One mode only: join. This script always ends with sshd + tailscaled running and the
# node joined; there is no prepare-then-exit branch. `setup.sh --tailscale` (binaries
# only, no join) does not reach this file at all. `--workflow`/`-w` is the workflow
# variant: same
# thing, but the log streams and the process stays in the foreground.
# The tailnet auth key is NEVER baked in: export TAILSCALE_AUTH_KEY for the first
# start, afterwards the stored node identity carries the login on its own.
# ─────────────────────────────────────────────────────────────────────────────

: "${RS_PORT:=6800}"
RS_DIR="${RS_DIR:-${REPL_HOME:-$HOME/workspace}/.ssh/join-tailnet}"
# This lane's own directory. Since S5c the lane lives in scripts/setup/
# (as join-repl.sh — scripts/setup/join.sh is the shared ENGINE it calls),
# so the entry setup.sh is exactly one level up from here; __rs_cmd
# resolves it as "$RS_SKILL_ROOT/../setup.sh".
RS_SKILL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd)"

__rs_homedir() { getent passwd "$(id -un)" | cut -d: -f6; }

# The command a user pastes/runs. Relative to the workspace whenever the skill lives
# inside it: workflows run with the workspace as cwd, so moving or renaming the skill
# dir cannot leave a dead absolute path behind. Only an outside copy needs the absolute
# one, and then the caller says so.
__rs_cmd() {
  local base="${REPL_HOME:-$HOME/workspace}" cmd
  cmd="$(cd -- "$(dirname -- "$RS_SKILL_ROOT/../setup.sh")" 2>/dev/null && pwd)/setup.sh"
  [[ "$cmd" == "$base"/* ]] && cmd="${cmd#"$base"/}"
  printf '%s\n' "$cmd"
}
__rs_cmd_external() { [[ "$(__rs_cmd)" == /* ]]; }

# sshd/ssh live in different PATH entries per shell; probe absolute candidates.
__rs_find() {
  local n="$1"; shift
  command -v "$n" 2>/dev/null && return 0
  local g p
  for g in "$@"; do for p in $g; do [ -x "$p" ] && { printf '%s\n' "$p"; return 0; }; done; done
  return 1
}

# Banner probe: engine_banner in scripts/setup/join.sh (shared engine, S3a).

# Client-side hop. `nc` is not portable: netcat-openbsd has -X/-x, but
# netcat-traditional and busybox nc reject -X ("invalid option -- 'X'"). Print
# every form, best first, so the operator never has to guess which nc they own.
__rs_ssh_hint() {
  local u="$1" ip="$2" h="${2:-<ip-tailnet>}"
  echo "  dari mesin lain (pilih yang ada di klien itu):"
  echo "    tailscale (socket default): ssh -o ProxyCommand='tailscale nc %h %p' -p $RS_PORT $u@$h"
  echo "    tailscale userspace:        ssh -o ProxyCommand='tailscale --socket=<sock tailscaled klien> nc %h %p' -p $RS_PORT $u@$h"
  echo "    ncat:                       ssh -o ProxyCommand='ncat --proxy 127.0.0.1:1055 --proxy-type socks5 %h %p' -p $RS_PORT $u@$h"
  echo "    netcat-openbsd:             ssh -o ProxyCommand='nc -X 5 -x 127.0.0.1:1055 %h %p' -p $RS_PORT $u@$h"
  echo "    busybox/traditional nc tidak punya -X → pakai tailscale atau ncat"
  [ -n "$ip" ] || echo "    alamat tailnet belum ada: isi TAILSCALE_AUTH_KEY lalu jalankan ulang"
}

# ~/.ssh -> persistent. Runs before anything writes a key, so an existing
# hand-installed ~/.ssh is moved into the persistent dir instead of discarded.
__rs_persist_ssh() {
  local home; home="$(__rs_homedir)"
  local target="${REPL_HOME:-$home/workspace}/.ssh"
  mkdir -p "$target" && chmod 700 "$target"
  if [ -L "$home/.ssh" ]; then
    [ "$(readlink -f "$home/.ssh")" = "$(readlink -f "$target")" ] || warn "~/.ssh menunjuk $(readlink "$home/.ssh"), bukan $target"
    return 0
  fi
  if [ -d "$home/.ssh" ]; then
    cp -a "$home/.ssh/." "$target/" 2>/dev/null || warn "sebagian isi ~/.ssh gagal dipindah"
    rm -rf "$home/.ssh"
  fi
  ln -s "$target" "$home/.ssh" && ok "~/.ssh -> $target (persisten, tak hilang saat restart)"
}

# .replit workflow: REPORT ONLY, never written. A boot start belongs in .replit,
# but the file belongs to the operator: their workflow names, their tasks, their
# ordering. Appending a block steals a name (a second `name = "join"` collides
# with one they already use) and rewrites a file we do not own.
__rs_workflow() {
  local rp="${REPL_HOME:-$HOME/workspace}/.replit"
  [ -f "$rp" ] || { warn ".replit tidak ada — workflow autostart dilewati"; return 0; }
  local base="${REPL_HOME:-$HOME/workspace}"

  # Already wired? Then only two things matter: does the command it points at still
  # exist, and does it carry --workflow. Path first — a moved skill dir must not be masked
  # by the --workflow check, or a dead absolute path sits there forever.
  if grep -qE 'setup\.sh.*--join' "$rp"; then
    local wired
    # Only the line that carries --join: other workflows point at the same script.
    wired="$(grep -oE 'bash +[^"]*setup\.sh' "$rp" | head -1 | sed -E 's/^bash +//')"
    if [[ -n "$wired" && ! -f "$wired" && ! -f "$base/$wired" ]]; then
      warn "entri workflow menunjuk '$wired' yang tak ada (skill dipindah?) — perbarui barisnya"
    else
      local changed=""
      # Pin the node name on the args line (and keep it in step on a rename): the
      # workflow is what rejoins the box, so the name has to travel with it. Only
      # when the operator pinned one — an unpinned box lets the console win.
      if [ -n "${TAILSCALE_NODE_NAME:-}" ]; then
        local pinned
        pinned="$(grep -oE '^args = "TAILSCALE_NODE_NAME=[^ ]+' "$rp" | head -1 | sed 's/.*=//')"
        if [ "$pinned" != "$TAILSCALE_NODE_NAME" ]; then
          if [ -n "$pinned" ]; then
            sed -i -E "s#^args = \"TAILSCALE_NODE_NAME=$pinned #args = \"TAILSCALE_NODE_NAME=$TAILSCALE_NODE_NAME #" "$rp"
            changed="$changed nama-node"
          else
            sed -i -E "s#^args = \"(bash [^\"]*setup\.sh[^\"]*--join)#args = \"TAILSCALE_NODE_NAME=$TAILSCALE_NODE_NAME \1#" "$rp"
            changed="$changed nama-node"
          fi
          grep -qE "^args = \"TAILSCALE_NODE_NAME=$TAILSCALE_NODE_NAME " "$rp" \
            && ok "nama node dipin di args workflow: $TAILSCALE_NODE_NAME" \
            || warn "gagal mem-pin TAILSCALE_NODE_NAME di $rp"
        fi
      fi
      # --join implies the start; only --workflow can still be missing (an entry wired before
      # that modifier existed). Verified afterwards — sed on a file we do not own gets
      # no trust from us.
      if ! grep -qE 'setup\.sh.*--join --workflow' "$rp"; then
        sed -i -E 's#^(args = ".*setup\.sh.*--join\b[^"]*)"$#\1 --workflow"#' "$rp"
        changed="--workflow"
      fi
      if [ -n "${changed# }" ]; then
        grep -qE 'setup\.sh.*--join --workflow' "$rp" \
          && { ok "workflow join di-upgrade ke $changed (entri lama)"; return 0; } \
          || warn "entri workflow join ada tapi gagal ditambahi $changed — cek $rp baris 'args'"
        return 0
      fi
      grep -qE 'setup\.sh.*--join --workflow' "$rp" && { ok "workflow join sudah terdaftar (--workflow)"; return 0; }
      skip "workflow join sudah ada di $rp — tidak diubah"
      return 0
    fi
  fi

  # One line to hand over, nothing to paste wholesale: the Replit UI adds the
  # task for them, the name and the ordering stay theirs at no cost.
  # Relative to the workspace when the skill lives inside it: workflows run with
  # the workspace as cwd, so the command survives the user moving or renaming the
  # skill dir. Only an out-of-workspace copy needs the absolute path.
  echo
  ok "boot start: di UI Replit, tambahkan task 'shell.exec' ke workflow mana pun, isinya:"
  echo "    bash $(__rs_cmd) --machine repl --tailscale --join --workflow"
  ok "  nama workflow & urutannya bebas; --join yang menyalakan daemon, --workflow menahan task tetap hidup selama daemon jalan (terminal workflow hanya berisi summary; log penuh di file) supaya job tidak di-reap"
  # `cmd && cmd` as the last statement returns 1 under errexit; use an if.
  if __rs_cmd_external; then ok "  path absolut: skill ada di luar workspace, pindahkan ke dalamnya agar tak basi"; fi
}

install_join() {
  local user; user="$(id -un)"
  [ "$(id -u)" = 0 ] && { warn "jalankan sebagai user biasa, bukan root"; return 1; }

  local sshd; sshd="$(__rs_find sshd '/nix/store/*replit-runtime-path*/bin/sshd' '/nix/store/*openssh*/bin/sshd' /run/current-system/sw/bin/sshd /usr/sbin/sshd || true)"
  [ -n "$sshd" ] || { warn "sshd tidak tersedia di box ini"; return 1; }

  __rs_persist_ssh
  [ -n "$RS_SKILL_ROOT" ] || { warn "tak bisa menentukan root skill"; return 1; }
  engine_join_tree "$RS_DIR"

  # the operator pastes hop keys here; a key already present is not duplicated
  engine_seed_key "$RS_DIR" "${RS_AUTHORIZED_KEYS:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA7sltdUAAm1gZGopAj3je5mpEX73kSGTiFH74NmPfxh repl-hop}"

  # detached loopback hop for the operator's own box lives in ~/.ssh/authorized_keys
  # too, because the platform's port-22 proxy honours only that file.
  local home; home="$(__rs_homedir)"
  mkdir -p "$home/.ssh"
  touch "$home/.ssh/authorized_keys" && chmod 600 "$home/.ssh/authorized_keys"
  grep -qF "repl-hop" "$home/.ssh/authorized_keys" || tail -n 1 "$RS_DIR/authorized_keys" >>"$home/.ssh/authorized_keys"

  engine_sshd_render "$RS_DIR" "$RS_PORT" "$user"
  engine_sshd_validate "$sshd" "$RS_DIR" || return 1

  # File environment untuk PermitUserEnvironment di atas: statis,
  # dirender dari nilai yang sama dengan yang dipakai stack ini.
  # ~/.ssh adalah symlink ke $REPL_HOME/.ssh, jadi file ini persisten.
  local env_base="${REPL_HOME:-$home/workspace}"
  mkdir -p "$home/.ssh"
  cat >"$home/.ssh/environment" <<ENVEOF
REPL_HOME=$env_base
XDG_DATA_HOME=${XDG_DATA_HOME:-$env_base/.local/share}
XDG_CONFIG_HOME=${XDG_CONFIG_HOME:-$env_base/.config}
XDG_CACHE_HOME=${XDG_CACHE_HOME:-$env_base/.cache}
XDG_BIN_HOME=${XDG_BIN_HOME:-$env_base/.local/bin}
PATH=${XDG_BIN_HOME:-$env_base/.local/bin}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
REPLIT_BASHRC=${REPLIT_BASHRC_FILE:-${XDG_CONFIG_HOME:-$env_base/.config}/replit_bashrc}
ENVEOF
  chmod 600 "$home/.ssh/environment" 2>/dev/null || true
  # REPLIT_BASHRC di atas hanya mirror dari pin [userenv.shared]: file
  # shim + pin itu milik write_replit_bashrc (rc.sh), join tidak membuat
  # atau menulis ulangnya — sesi ssh cuma diberi pointer yang sama.
  # Landing: sesi interaktif mulai di workspace. cwd urusan shell
  # (sshd tidak bisa mengaturnya); var di atas tidak bergantung rc.
  # ~/.bashrc di platform ini symlink ke /nix/store (milik platform,
  # read-only) — jangan disentuh. Channel-nya ~/.bash_profile, yang
  # dibaca login shell: masuk lewat shim yang sama dengan workflow
  # (ia membersihkan REPLIT_MODE sebelum .bashrc platform jalan),
  # fallback ke .bashrc platform, lalu landing.
  if [ ! -L "$home/.bash_profile" ] && ! grep -q "repl landing" "$home/.bash_profile" 2>/dev/null; then
    cat >>"$home/.bash_profile" <<'RCEOF'

# >>> repl landing >>>
if [ -r "${REPLIT_BASHRC:-}" ]; then . "$REPLIT_BASHRC"; elif [ -f "$HOME/.bashrc" ]; then . "$HOME/.bashrc"; fi
case $- in *i*) [[ "$PWD" == "$HOME" ]] && cd "${REPL_HOME:-$HOME/workspace}" ;; esac
# <<< repl landing <<<
RCEOF
  fi

  # tailnet binaries: needed to prepare the identity dirs even without joining the tailnet
  local bin="$XDG_BIN_HOME" td="$XDG_BIN_HOME/tailscaled" tsc="$XDG_BIN_HOME/tailscale"
  if [ ! -x "$td" ] || [ ! -x "$tsc" ]; then
    warn "tailscale belum terpasang — dipasang sekarang (butuh --tailscale sekali saja)"
    install_tailscale || { warn "tailscale gagal dipasang"; return 1; }
  fi
  # Paths come from the environment (registered by install_tailscale and --fix),
  # never re-spelled here: one definition, no drift, and no absolute copy in a script.
  local state="$TAILSCALE_STATE_DIR" sock="$TAILSCALE_SOCKET"
  mkdir -p "$state"
  record_tool_path_dirs "$bin"
  wire_tool tailscale -- "$bin"

  # ── start ───────────────────────────────────────────────────────────────────
  engine_sshd_start "$sshd" "$RS_DIR" "$RS_PORT" || return 1

  __rs_workflow

  engine_tailscaled_start "$td" "$tsc" "$state" "$sock" "$TAILSCALE_LOG" "$TAILSCALE_DATA_DIR" || return 1
  engine_tailnet_join "$tsc" "$sock"
  __rs_ssh_hint "$user" "$ENGINE_TS_IP"


  # Workflow mode: a task whose command exits counts as DONE and the job is
  # reaped, so the daemons die with it — the task must stay in the foreground
  # for as long as the workflow should run. It used to `exec tail -F` the
  # daemon log for that, but streaming a daemon log into the workflow
  # terminal grows the console without bound and hangs the Replit UI
  # (operator rule, 2026-11-05). The daemon already writes its full log to
  # $TAILSCALE_LOG; the console gets a short summary
  # only, and the task holds itself open by watching the daemon's socket —
  # when the daemon dies the socket vanishes and the workflow ends, which
  # is the truthful lifetime for both.
  if $WF; then
    echo
    ok "mode workflow: tailscaled jalan (socket $sock)"
    ok "  log penuh: $TAILSCALE_LOG"
    ok "  terminal workflow sengaja sepi (summary saja) agar UI tidak hang; task menahan diri selama daemon hidup"
    while [ -S "$sock" ]; do sleep 30; done
    warn "tailscaled berhenti (socket $sock hilang) — workflow selesai"
  fi
}
