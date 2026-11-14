# shellcheck shell=bash
# Per-tool cleanup (--clean). Sourced by setup.sh.
# Cleanup (removes installed toolchain artifacts) ─────────────────────────────
rm_bin() { local b; for b in "$@"; do rm -f "$XDG_BIN_HOME/$b"; done; }
rm_dir() { local d; for d in "$@"; do rm -rf "$d"; done; }

rm_data() {
  local tool="$1" dir="$2"
  rm -rf "$dir"
  rm_bin "$tool"
}

# True when the tool has something to remove — a binary in XDG_BIN_HOME or
# any of the extra paths given (payload dirs, npm-global copies, …). Used by
# every clean_* to skip rather than claim a removal that never happened.
# [[ -e || -L ]] so a dangling symlink (target already gone) still counts as
# present and gets cleaned up rather than left as a stale link.
_present() {
  local p
  for p in "$@"; do [[ -e "$p" || -L "$p" ]] && return 0; done
  return 1
}

# nothing_removed <label>: honest skip for an already-absent tool.
nothing_removed() { skip "$1 not installed — nothing to remove"; }

# ── User-data backup before destructive removal ──────────────────────────────
# Some payload dirs are NOT pure install artifacts — they hold the operator's
# data. `--clean` must not destroy that silently, so any tool that owns user
# data goes through back_up_tool FIRST. The archive lives OUTSIDE the dir being
# removed (a backup inside $HERMES_HOME would be deleted by the very rm it is
# protecting against).
#
# hermes_backup: use the tool's OWN CLI (`hermes backup`) to produce the
# archive, then COPY it to the destination OUTSIDE $HERMES_HOME. The CLI knows
# what to include/exclude (skills, sessions, memory-provider state) and takes
# SQLite-safe copies of state.db, producing an archive `hermes import` can
# restore. A manual zip is only a fallback for a box where the CLI is missing
# or fails — the guarantee that matters is: no deletion without a backup.
HERMES_BACKUP_EXCLUDES=(
  '*/cache/*' '*/installs/*' '*/hermes-agent/*' '*/tools/*' '*/logs/*'
  '*/telemetry/*' '*/audio_cache/*' '*/image_cache/*' '*/node_modules/*'
  '*/models_dev_cache.json' '*/provider_models_cache.json' '*.lock'
)

# Manual fallback archive (used only when the CLI is unavailable/failed).
_hermes_backup_zip_fallback() {
  local dest="$1"
  command -v zip >/dev/null 2>&1 || return 1
  rm -f "$dest"
  ( cd "$(dirname "$HERMES_HOME")" \
      && zip -q -r "$dest" "$(basename "$HERMES_HOME")" -x "${HERMES_BACKUP_EXCLUDES[@]}" )
  [[ -s "$dest" ]]
}

hermes_backup() {
  local dest_dir="$XDG_CONFIG_HOME/hermes"
  local dest="$dest_dir/hermes-backup.zip"
  [[ -d "$HERMES_HOME" ]] || return 0
  mkdir -p "$dest_dir"

  # 1. Preferred: the tool's own CLI, staged OUTSIDE $HERMES_HOME (scratch
  #    TMPDIR), then copied in — a backup written inside the dir being removed
  #    would be deleted by the very rm it protects against. `timeout` guards
  #    against the launcher booting a source-update cycle (never block a
  #    --clean on the network); HERMES_HOME is passed explicitly so the CLI
  #    archives THIS home.
  local staging_dir staging rc=1
  staging_dir="$(mktemp -d)"; staging="$staging_dir/hermes-backup.zip"
  if command -v hermes >/dev/null 2>&1; then
    if HERMES_HOME="$HERMES_HOME" timeout "${HERMES_BACKUP_TIMEOUT:-900}" \
         hermes backup -o "$staging" >/dev/null 2>&1 \
       && [[ -s "$staging" ]]; then
      rc=0
    fi
  fi

  # 2. Fallback: manual zip when the CLI is absent or produced no archive.
  if (( rc != 0 )); then
    warn "hermes backup CLI unavailable or produced no archive — falling back to a manual zip"
    _hermes_backup_zip_fallback "$staging" && rc=0
  fi

  if (( rc == 0 )) && cp -f "$staging" "$dest" && [[ -s "$dest" ]]; then
    rm -rf "$staging_dir"
    ok "Hermes user data backed up: $dest"
    _BACKUPS_TAKEN+=("hermes->$dest")
    return 0
  fi

  rm -rf "$staging_dir"
  warn "Hermes backup produced no archive — refusing to delete $HERMES_HOME"
  rm -f "$dest"
  return 1
}

# Dispatcher: back up <tool>'s user data before removal. Returns 0 when there
# is nothing to back up OR the backup succeeded; non-zero means the backup was
# attempted and FAILED, in which case the caller must NOT delete the payload.
back_up_tool() {
  case "$1" in
    hermes)  hermes_backup ;;
    ollama)  : ;;  # models are preserved in place by clean_ollama (too big to archive)
    camofox) : ;;  # ~/.camofox server state is preserved by clean_camofox
    lightpanda) : ;;  # tour config + cookie jar are preserved by clean_lightpanda
    moli) : ;;  # tour config + cookie jar are preserved by clean_moli
    tor) : ;;  # DataDirectory + .env.example are preserved by clean_tor
    hermes-chromium) : ;;  # the browser itself is Hermes-managed; clean_ drops only the closure
    *)       : ;;  # nothing user-owned (binary-only tools)
  esac
}

# Human-readable "what this tool owns" — used by the pre-flight summary.
clean_paths_for() {
  case "$1" in
    android)       echo "$JAVA_HOME $SDK (binaries: java/adb/sdkmanager/…)" ;;
    java)          echo "$JAVA_HOME (binaries: java/javac/…)" ;;
    uv)            echo "uv/uvx binaries, $XDG_DATA_HOME/uv, uv cache" ;;
    node)          echo "$NODE_DIR + node/npm/npx symlinks" ;;
    zsh)           echo "$ZSH_PROFILE (nix profile), $ZSH_DIR, $ZSH_DOTDIR, zsh/fzf symlinks" ;;
    opencode)      echo "$XDG_BIN_HOME/opencode, $OPENCODE_CONFIG_DIR" ;;
    ollama)        echo "$OLLAMA_INSTALL_DIR binaries (MODELS PRESERVED)" ;;
    claude)        echo "$XDG_BIN_HOME/claude" ;;
    hermes)        echo "$HERMES_HOME (backed up via hermes CLI first), hermes launchers, hermes-chromium closure prep" ;;
    ori)           echo "$XDG_BIN_HOME/ori" ;;
    camofox)       echo "npm package, $CAMOUFOX_INSTALL_DIR engine, closure (server state PRESERVED)" ;;
    lightpanda)    echo "$LIGHTPANDA_BIN binary + tour venv (config + cookie jar PRESERVED)" ;;
    moli)          echo "$MOLI_BIN binary + launcher (config + cookie jar PRESERVED)" ;;
    tor)           echo "$TOR_HOME/bundle + $TOR_BIN_DIR/{tor,tor-browser} (DataDirectory + .env.example PRESERVED)" ;;
    hermes-chromium) echo "$HERMES_CHROME_STATE closure + launch-hermes-chrome launcher (the browser itself is Hermes-managed; untouched)" ;;
    rclone)        echo "$XDG_BIN_HOME/rclone" ;;
    qbt)           echo "$XDG_BIN_HOME/qbittorrent-nox" ;;
    aria2)         echo "$XDG_BIN_HOME/aria2c" ;;
    ffmpeg)        echo "$XDG_BIN_HOME/ffmpeg ffprobe ffplay" ;;
    cloudflared)   echo "$XDG_BIN_HOME/cloudflared" ;;
    tailscale)     echo "$XDG_BIN_HOME/{tailscale,tailscaled,launch-tailscaled} + $RS_DIR + state tailnet + blok ssh config & [host]:$RS_PORT di known_hosts + baris repl-hop ($HOME/.ssh tetap ada)" ;;
    sshx)          echo "$XDG_BIN_HOME/sshx" ;;
    llm-wiki)      echo "${LLM_WIKI_HOME:-${REPL_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}}/llmwiki-app} (AppImage + bundle + token; WIKI DATA PRESERVED)" ;;
    *)             echo "$1" ;;
  esac
}

# Pre-flight: print exactly what is about to be removed (and what is kept)
# BEFORE anything is deleted. Purely informational — the y/N confirm in
# confirm_clean is the actual gate.
clean_preflight() {
  local -a targets=("$@")
  ((${#targets[@]})) || return 0
  echo ""
  echo "${COL_BOLD}The following will be REMOVED:${COL_RESET}"
  local t
  for t in "${targets[@]}"; do
    printf '  %s- %-12s%s %s\n' "$COL_RED" "$t" "$COL_RESET" "$(clean_paths_for "$t")"
  done
  case " ${targets[*]} " in
    *" hermes "*) echo "  ${COL_YELLOW}• hermes: backed up via 'hermes backup' CLI -> $XDG_CONFIG_HOME/hermes/hermes-backup.zip first${COL_RESET}" ;;
  esac
}

# True when the given package is installed as a GLOBAL npm package (opencode-ai,
# @anthropic-ai/claude-code). Those installs don't create an XDG_BIN_HOME binary,
# so _present alone would skip them and leak the global package on clean.
_npm_global_installed() {
  command -v npm &>/dev/null || return 1
  npm_config_prefix="$NPM_GLOBAL_PREFIX" npm ls -g --depth=0 "$1" &>/dev/null 2>&1
}

clean_android() {
  if ! _present "$JAVA_HOME" "$SDK" "$XDG_BIN_HOME/java" "$XDG_BIN_HOME/adb"; then
    nothing_removed "Android toolchain"; return 0
  fi
  step "Removing Android toolchain (Java $JAVA_MAJOR + SDK)"
  rm_data android "$JAVA_HOME"
  rm -rf "$SDK"
  rm_bin java javac jar jshell javap sdkmanager avdmanager adb
  ok "Android toolchain removed"
}

clean_java() {
  if ! _present "$JAVA_HOME" "$XDG_BIN_HOME/java"; then
    nothing_removed "Java toolchain"; return 0
  fi
  step "Removing Java toolchain (JDK $JAVA_MAJOR)"
  rm_data java "$JAVA_HOME"
  rm_bin java javac jar jshell javap
  ok "Java toolchain removed"
}

clean_uv() {
  if ! _present "$XDG_BIN_HOME/uv" "$XDG_BIN_HOME/uvx" "$XDG_DATA_HOME/uv" \
                "$WORKSPACE/.local/bin/uv" "$WORKSPACE/.cargo/bin/uv" "$WORKSPACE/.cache/uv"; then
    nothing_removed "uv"; return 0
  fi
  step "Removing uv"
  rm -rf "$XDG_BIN_HOME/uv" "$XDG_BIN_HOME/uvx" "$XDG_DATA_HOME/uv" \
         "$WORKSPACE/.local/bin/uv" "$WORKSPACE/.cargo/bin/uv" "$WORKSPACE/.cache/uv"
  ok "uv removed"
}

clean_node() {
  if ! _present "$NODE_DIR" "$XDG_BIN_HOME/node"; then
    nothing_removed "Node.js"; return 0
  fi
  step "Removing Node.js"
  rm_data node "$NODE_DIR"
  rm_bin node npm npx
  ok "Node.js removed"
}

clean_zsh() {
  if ! _present "$ZSH_PROFILE" "$ZSH_DIR" "$ZSH_DOTDIR" "$XDG_BIN_HOME/zsh"; then
    nothing_removed "zsh"; return 0
  fi
  step "Removing zsh"
  rm -rf "$ZSH_PROFILE" "$ZSH_DIR" "$ZSH_DOTDIR"
  rm_bin zsh fzf
  ok "zsh removed"
}

clean_opencode() {
  if ! _present "$XDG_BIN_HOME/opencode" "$OPENCODE_CONFIG_DIR" \
       && ! _npm_global_installed "opencode-ai"; then
    nothing_removed "OpenCode"; return 0
  fi
  step "Removing OpenCode"
  # Binary lives directly in XDG_BIN_HOME (single-file install); the npm
  # package (opencode-ai) is a GLOBAL install, so it must be removed with
  # `npm uninstall -g` — a local `npm uninstall` leaves the global bin intact.
  rm -f "$XDG_BIN_HOME/opencode"
  if command -v npm &>/dev/null \
     && npm_config_prefix="$NPM_GLOBAL_PREFIX" npm ls -g --depth=0 opencode-ai &>/dev/null 2>&1; then
    npm_config_prefix="$NPM_GLOBAL_PREFIX" npm uninstall -g opencode-ai \
      || warn "npm uninstall -g opencode-ai failed — remove it manually"
  fi
  rm -rf "$OPENCODE_CONFIG_DIR"
  ok "OpenCode removed"
}

clean_ollama() {
  if ! _present "$OLLAMA_INSTALL_DIR" "$XDG_BIN_HOME/ollama"; then
    nothing_removed "Ollama"; return 0
  fi
  step "Removing Ollama"
  rm_data ollama "$OLLAMA_INSTALL_DIR"
  rm_bin ollama
  ok "Ollama removed"
}

clean_claude() {
  if ! _present "$XDG_BIN_HOME/claude" \
       && ! _npm_global_installed "@anthropic-ai/claude-code"; then
    nothing_removed "Claude Code"; return 0
  fi
  step "Removing Claude Code"
  # Binary lives directly in XDG_BIN_HOME (single-file smart install); if it
  # was installed as the global npm package @anthropic-ai/claude-code instead,
  # that copy survives an rm — so also `npm uninstall -g` it.
  rm -f "$XDG_BIN_HOME/claude"
  if command -v npm &>/dev/null \
     && npm_config_prefix="$NPM_GLOBAL_PREFIX" npm ls -g --depth=0 @anthropic-ai/claude-code &>/dev/null 2>&1; then
    npm_config_prefix="$NPM_GLOBAL_PREFIX" npm uninstall -g @anthropic-ai/claude-code \
      || warn "npm uninstall -g @anthropic-ai/claude-code failed — remove it manually"
  fi
  ok "Claude Code removed"
}

clean_hermes() {
  if _present "$HERMES_HOME" "$XDG_BIN_HOME/hermes"; then
    step "Removing Hermes Agent"
    # User data (config.yaml, .env, auth.json, sessions, memories, cron, skills,
    # state.db) lives in $HERMES_HOME — back it up BEFORE the rm. If the backup
    # cannot be produced, do NOT delete: a silent loss of the whole agent config
    # is exactly the failure this guards against.
    if ! back_up_tool hermes; then
      warn "Hermes NOT removed — backup failed; $HERMES_HOME left intact"
      _CLEAN_SKIPPED+=("hermes")
      return 0
    fi
    rm_data hermes "$HERMES_HOME"
    rm_bin hermes hermes-agent hermes-acp
    ok "Hermes Agent removed"
  else
    nothing_removed "Hermes Agent"
  fi
  # The Chromium closure prep (hermes-chromium) exists only to serve Hermes:
  # without Hermes its closure dir, launcher and env wiring are orphans, so
  # sweep them with their owner. The backup-failure return above skips this —
  # a surviving Hermes keeps its browser prep. The standalone
  # `--clean hermes-chromium` remains for closure-only resets.
  clean_hermes_chromium
}

clean_ori() {
  if ! _present "$XDG_BIN_HOME/ori"; then
    nothing_removed "ORI"; return 0
  fi
  step "Removing ORI"
  # Binary lives directly in XDG_BIN_HOME (single-file smart install).
  rm -f "$XDG_BIN_HOME/ori"
  ok "ORI removed"
}

clean_rclone() {
  if ! _present "$XDG_BIN_HOME/rclone"; then
    nothing_removed "rclone"; return 0
  fi
  step "Removing rclone"
  rm -f "$XDG_BIN_HOME/rclone"
  ok "rclone removed"
}

clean_qbt() {
  if ! _present "$XDG_BIN_HOME/qbittorrent-nox"; then
    nothing_removed "qBittorrent-nox"; return 0
  fi
  step "Removing qBittorrent-nox"
  rm -f "$XDG_BIN_HOME/qbittorrent-nox"
  ok "qBittorrent-nox removed"
}

clean_aria2() {
  if ! _present "$XDG_BIN_HOME/aria2c"; then
    nothing_removed "aria2c"; return 0
  fi
  step "Removing aria2c"
  rm -f "$XDG_BIN_HOME/aria2c"
  ok "aria2c removed"
}

clean_ffmpeg() {
  if ! _present "$XDG_BIN_HOME/ffmpeg" "$XDG_BIN_HOME/ffprobe" "$XDG_BIN_HOME/ffplay"; then
    nothing_removed "FFmpeg"; return 0
  fi
  step "Removing FFmpeg"
  rm -f "$XDG_BIN_HOME/ffmpeg" "$XDG_BIN_HOME/ffprobe" "$XDG_BIN_HOME/ffplay"
  ok "FFmpeg removed"
}

clean_cloudflared() {
  if ! _present "$XDG_BIN_HOME/cloudflared"; then
    nothing_removed "cloudflared"; return 0
  fi
  step "Removing cloudflared"
  rm -f "$XDG_BIN_HOME/cloudflared"
  ok "cloudflared removed"
}

# tailscale — the binaries go, the node state does NOT: $TAILSCALE_DATA_DIR holds
# the node key and the login, so a re-install keeps this machine on the tailnet
# (and its Funnel/serve config) without a re-auth. Copies an older manual install
# left in $TAILSCALE_DATA_DIR are deliberately KEPT: that dir also holds the
# user's own start scripts, and those binaries belong to whoever wrote them.

clean_tailscale() {
  local home ours=() sock="${TAILSCALE_SOCKET:-}"
  local legacy_dir="${REPL_HOME:-$WORKSPACE}/.ssh/join-sshd"
  home="$(cd "$HOME" && pwd)"
  [ -d "$RS_DIR" ] && ours+=("$RS_DIR")
  # The legacy dir counts toward presence too: a box with only the
  # pre-rename dir left must not short-circuit to "nothing removed".
  [ -d "$legacy_dir" ] && ours+=("$legacy_dir")
  [ -n "$sock" ] && ours+=("$sock")
  local bins=("$XDG_BIN_HOME/tailscale" "$XDG_BIN_HOME/tailscaled" "$XDG_BIN_HOME/launch-tailscaled")
  _present "${ours[@]}" "${bins[@]}" || { nothing_removed "tailscale"; return 0; }
  step "Removing tailscale join (biner + sshd + node state + wiring ssh)"

  # sshd first: pid file when sshd wrote one, else the listener is matched by the
  # config path only (a second daemon on another socket is a different story).
  if [ -f "$RS_DIR/sshd.pid" ]; then
    kill "$(cat "$RS_DIR/sshd.pid")" 2>/dev/null || true
  fi
  pkill -f -- "$RS_DIR/sshd_config" 2>/dev/null || true
  sleep 1

  # Pre-rename state dir (join-sshd era): a box whose skill was updated in
  # place still runs its sshd from the legacy dir until the workflow
  # restarts — stop that listener too, or the rename leaves a live daemon
  # behind on the same port.
  if [[ "$legacy_dir" != "$RS_DIR" && -d "$legacy_dir" ]]; then
    if [ -f "$legacy_dir/sshd.pid" ]; then
      kill "$(cat "$legacy_dir/sshd.pid")" 2>/dev/null || true
    fi
    pkill -f -- "$legacy_dir/sshd_config" 2>/dev/null || true
    sleep 1
  fi

  # tailscaled: matched through OUR socket, not by name, so a client on another
  # socket (test node, second tailnet) keeps running.
  if [ -n "$sock" ]; then
    pkill -f -- "--socket=$sock" 2>/dev/null || true
    sleep 1
  fi

  # Hop key we appended to ~/.ssh/authorized_keys (tag: repl-hop).
  [ -f "$home/.ssh/authorized_keys" ] &&     sed -i '/repl-hop/d' "$home/.ssh/authorized_keys"

  # ~/.ssh/config: remove only blocks that are ours — a Host/Match block whose body
  # names our port and a tailnet hop. Any other block stays byte-identical.
  if [ -f "$home/.ssh/config" ]; then
    local removed
    removed="$(awk -v port="$RS_PORT" '
      function flush(   ours) {
        if (hdr == "") { printf "%s", blk; blk = ""; return }
        ours = (body ~ ("(^|[^0-9])" port "([^0-9]|$)") && body ~ /(ProxyCommand|ts\.net|tailscale)/)
        if (!ours) printf "%s", blk
        else print "REMOVED " hdr > "/dev/stderr"
        blk = ""; hdr = ""; body = ""
      }
      /^(Host|Match)[[:space:]]/ { flush(); hdr = $0; blk = $0 "\n"; body = ""; next }
      { blk = blk $0 "\n"; body = body $0 "\n" }
      END { flush() }
    ' "$home/.ssh/config" 2>/tmp/rs_cfg_removed)"
    if [ -s /tmp/rs_cfg_removed ]; then
      printf '%s\n' "$removed" >"$home/.ssh/config"
      while read -r _ h; do ok "config ssh dihapus: $h"; done </tmp/rs_cfg_removed
    fi
    rm -f /tmp/rs_cfg_removed
  fi

  # known_hosts: only the [host]:port forms — the plain 22 entries are not ours.
  for f in "$home/.ssh/known_hosts" "$home/.ssh/known_hosts2"; do
    [ -f "$f" ] && sed -i "\#^\[[^]]*\]:$RS_PORT #d" "$f"
  done

  rm -rf "$RS_DIR"
  ok "join sshd dihapus ($RS_DIR)"
  if [[ "$legacy_dir" != "$RS_DIR" && -d "$legacy_dir" ]]; then
    rm -rf "$legacy_dir"
    ok "legacy join sshd dihapus ($legacy_dir)"
  fi
  # Identity policy: KEEP the node key by default. Deleting it makes the next
  # join register a NEW node while the old one lingers offline in the admin
  # console (stacked machines). With the state kept, `tailscale up` reuses the
  # same node: offline here = offline there, back online = the same machine.
  if [[ "${TAILSCALE_PURGE_IDENTITY:-false}" == true ]]; then
    [ -n "$sock" ] && rm -rf "${TAILSCALE_STATE_DIR:-$(dirname "$sock")}"
    rm -f "${TAILSCALE_DATA_DIR:-}/tailscaled.state.bak"
    ok "state tailnet dihapus (host key + node identity) — purge diminta"
    warn "node masih terdaftar di console sampai kedaluwarsa — hapus manual di admin panel"
  else
    ok "node identity DIPERTAHANKAN (${TAILSCALE_STATE_DIR:-$(dirname "${sock:-}")}) — rejoin memakai node yang sama"
    warn "mau buang identity? ulangi dengan TAILSCALE_PURGE_IDENTITY=true (node lama akan nyangkut di console)"
  fi
  rm -f "${bins[@]}"
  ok "biner tailscale/launch-tailscaled dihapus"
  warn "~/.ssh tetap ada dan tidak ikut terhapus; .replit --join dibiarkan (hapus manual)"
}

clean_sshx() {
  if ! _present "$XDG_BIN_HOME/sshx"; then
    nothing_removed "sshx"; return 0
  fi
  step "Removing sshx"
  rm -f "$XDG_BIN_HOME/sshx"
  ok "sshx removed"
}

# llm-wiki server — removes the app bundle, the AppImage, its extraction and the
# token file. THE WIKI DATA IS NEVER TOUCHED: the markdown project lives in the
# workspace (the supervisor's project dir), not inside the install dir.
clean_llm_wiki() {
  local dir="${LLM_WIKI_HOME:-${REPL_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}}/llmwiki-app}"
  if ! _present "$dir/run-public.sh"; then
    nothing_removed "llm-wiki"; return 0
  fi
  step "Removing llm-wiki server"
  rm -rf "$dir"
  ok "llm-wiki removed ($dir — wiki data untouched)"
}

# Strip the '# >>> toolchain >>>' … '# <<< toolchain <<<' managed block from a
# file, writing the result back THROUGH the path (cat >) so a symlink target
# is preserved — sed -i would replace the symlink with a plain file.
strip_rc_block() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local tmp
  tmp="$(mktemp)"
  awk '/^# >>> toolchain >>>/{s=1} s{ if(/^# <<< toolchain <<</) s=0; next } {print}' "$f" > "$tmp"
  cat "$tmp" > "$f"
  rm -f "$tmp"
}

# Remove ONLY the lines owned by <tool> from the managed shell block (rc;
# the .replit twin is strip_userenv_keys, below).
# The block is stripped line-by-line; lines whose var/dir maps to <tool> via
# _WIRE_OWNER are dropped; everything else (including unregistered lines like
# the XDG exports from the replit block) is kept. The block markers themselves
# are preserved if ANY lines remain; if the block becomes empty, the whole
# block (markers + contents) is removed.
strip_tool_wiring() {
  local tool="$1" file="$2"
  [[ -f "$file" ]] || return 0

  local in_block=0
  local -a out=()
  local line var dir owner

  while IFS= read -r line; do
    case "$line" in
      '# >>> toolchain >>>')
        in_block=1
        out+=("$line")
        continue
        ;;
      '# <<< toolchain <<<')
        if (( in_block )); then
          # If the block is only markers (no tool lines left) remove both.
          local last_idx=$(( ${#out[@]} - 1 ))
          if [[ $last_idx -ge 0 && "${out[last_idx]}" == '# >>> toolchain >>>' ]]; then
            unset 'out[last_idx]'
          else
            out+=("$line")
          fi
        else
          out+=("$line")
        fi
        in_block=0
        continue
        ;;
    esac

    if (( in_block )); then
      owner=""
      if [[ "$line" == 'case ":$PATH:" in '* ]]; then
        local re='\*"([^"]*)"\*'
        if [[ "$line" =~ $re ]]; then
          dir="${BASH_REMATCH[1]#:}"
          dir="${dir%:}"
          owner="$(path_dir_owner "$dir")"
        fi
      elif [[ "$line" =~ ^export[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)= ]] \
         || [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*= ]]; then
        var="${BASH_REMATCH[1]}"
        owner="$(env_var_owner "$var")"
      fi

      if owned_only_by "$owner" "$tool"; then
        # Drop the line — it's owned by the tool being cleaned.
        continue
      fi
      # Keep lines owned by other tools and unregistered lines (platform exports, etc.)
      out+=("$line")
    else
      out+=("$line")
    fi
  done < "$file"

  # Write back through the path (preserves symlinks)
  local tmp="$(mktemp)"
  printf '%s\n' ${out[@]+"${out[@]}"} > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

# Prompts for confirmation before an irreversible cleanup. Skips when
# `--yes` was given or stdin isn't a TTY (non-interactive default is proceed).
confirm_clean() {
  $YES && return 0
  [[ -t 0 ]] || return 0
  local ans
  printf '%sProceed with cleanup of %s%s? [y/N] ' \
    "$COL_YELLOW" "${CLEAN_TARGET:-all}" "$COL_RESET"
  IFS= read -r ans || true
  # Declining (or Ctrl-D) is a voluntary no-op, NOT a failure — never a red
  # ERROR and never exit 1. Mirrors the menu-quit idiom in interactive_menu.
  if [[ "$ans" != y && "$ans" != Y && "$ans" != yes && "$ans" != YES ]]; then
    echo -e "\n${COL_YELLOW}Cleanup cancelled.${COL_RESET}"
    exit 130
  fi
}

clean() {
  seed_tool_wiring
  mkdir -p "$XDG_BIN_HOME"
  unset _MENU_ITEMS _MENU_CURSOR _MENU_TOGGLE 2>/dev/null || true
  local summary hint

  # Pre-flight: show what is about to go (and which tools keep user data)
  # BEFORE any deletion. Label normalization: android-tools -> android,
  # oc -> opencode, matching the wire labels used below.
  local _pf=""
  case "$CLEAN_TARGET" in
    ""|all) _pf="" ;;
    android-tools|java|uv|node|zsh|oc|opencode|ollama|claude|hermes|ori|camofox|lightpanda|moli|tor|hermes-chromium|llm-wiki|rclone|qbt|aria2|ffmpeg|cloudflared|tailscale|sshx)
      _pf="$CLEAN_TARGET"; [[ "$_pf" == android-tools ]] && _pf=android; [[ "$_pf" == oc ]] && _pf=opencode ;;
  esac
  if [[ -n "$_pf" ]]; then
    clean_preflight "$_pf"
  elif [[ "$CLEAN_TARGET" == all || -z "$CLEAN_TARGET" ]]; then
    (( ${#CLEAN_TOOLS[@]} )) && clean_preflight "${CLEAN_TOOLS[@]}" || clean_preflight all
  fi

  # Dispatch order (explicit target / full wipe / misc state → wiring
  # strip; menu-selected tools → per-tool only). No set -e trap under us: the
  # function returns 0 only after real cleanup; an empty menu selection
  # (nothing ticked) short-circuits below as a graceful no-op — the menu can
  # never trigger an irreversible full wipe.
  summary="$CLEAN_TARGET"
  hint="bash setup.sh --all"
  case "$CLEAN_TARGET" in
    android-tools|java|uv|node|zsh|oc|opencode|ollama|claude|hermes|ori|camofox|lightpanda|moli|tor|hermes-chromium|llm-wiki|rclone|qbt|aria2|ffmpeg|cloudflared|tailscale|sshx)
      hint="bash setup.sh --$CLEAN_TARGET"
      ;;
  esac
  case "$CLEAN_TARGET" in
    all)
      step "Cleaning entire toolchain"
      # Strip env wiring FIRST: the .replit/.bashrc edits must land while
      # the toolchain is still intact (clean_* removes binaries + payload
      # the edits may reference). Stripping first keeps every source
      # available.
      # 'all' is the ONLY path that strips env wiring (the rc / .replit
      # managed blocks) — per-target clean removes binaries + payload only.
      if [[ -f "$BASHRC" ]]; then
        strip_rc_block "$BASHRC"
        ok "Stripped managed block from $BASHRC"
        strip_legacy_hermes_block "$BASHRC"
      fi
      local replit_file="${REPL_HOME:-$WORKSPACE}/.replit"
      # Only replit mode ever wrote a userenv block — don't touch .replit
      # otherwise (default mode is .bashrc-only by design). strip_userenv_keys
      # checks writability and removes every managed key (an emptied
      # [userenv.shared] table is dropped by the dotreplit writer).
      if [[ "$REPLIT_MODE" == true && -f "$replit_file" ]]; then
        strip_userenv_keys all "$replit_file"
      fi
      clean_android
      clean_java
      clean_uv
      clean_node
      clean_zsh
      clean_opencode
      clean_ollama
      clean_claude
      clean_hermes
      clean_ori
      clean_rclone
      clean_qbt
      clean_aria2
      clean_ffmpeg
      clean_cloudflared
      clean_tailscale
      clean_sshx
      clean_camofox
      clean_lightpanda
      clean_moli
      clean_tor
      clean_hermes_chromium
      clean_llm_wiki
      ok "Full toolchain cleanup complete"
      ;;
    android-tools|java|uv|node|zsh|oc|opencode|ollama|claude|hermes|ori|camofox|lightpanda|moli|tor|hermes-chromium|llm-wiki|rclone|qbt|aria2|ffmpeg|cloudflared|tailscale|sshx)
      # Drop this tool's wiring from the managed blocks FIRST, then remove
      # the binaries + payload. Labels here differ from
      # wire_tool ownership labels: android-tools -> android, oc -> opencode.
      local wire_label="$CLEAN_TARGET"
      case "$wire_label" in
        android-tools) wire_label=android ;;
        oc) wire_label=opencode ;;
      esac
      [[ -f "$BASHRC" ]] && strip_tool_wiring "$wire_label" "$BASHRC"
      # Pre-merge rcs carry a separate hermes-tools block outside the managed
      # markers, which strip_tool_wiring cannot see — drop it here too, so a
      # clean on an rc never re-written after the merge still works.
      [[ "$wire_label" == hermes ]] && strip_legacy_hermes_block "$BASHRC"
      # hermes-chromium's wiring is part of hermes' lifecycle: its
      # AGENT_BROWSER_EXECUTABLE_PATH export must not outlive Hermes.
      [[ "$wire_label" == hermes && -f "$BASHRC" ]] && strip_tool_wiring hermes-chromium "$BASHRC"
      local replit_file="${REPL_HOME:-$WORKSPACE}/.replit"
      [[ "$REPLIT_MODE" == true && -f "$replit_file" ]] && strip_userenv_keys "$wire_label" "$replit_file"
      [[ "$REPLIT_MODE" == true && -f "$replit_file" && "$wire_label" == hermes ]] && strip_userenv_keys hermes-chromium "$replit_file"
      case "$CLEAN_TARGET" in
        android-tools) clean_android ;;
        java)          clean_java ;;
        uv)            clean_uv ;;
        node)          clean_node ;;
        zsh)           clean_zsh ;;
        oc|opencode)   clean_opencode ;;
        ollama)        clean_ollama ;;
        claude)        clean_claude ;;
        hermes)        clean_hermes ;;
        ori)           clean_ori ;;
        camofox)       clean_camofox ;;
        lightpanda)    clean_lightpanda ;;
        moli)          clean_moli ;;
        tor)           clean_tor ;;
        llm-wiki)      clean_llm_wiki ;;
        hermes-chromium) clean_hermes_chromium ;;
        rclone)        clean_rclone ;;
        qbt)           clean_qbt ;;
        aria2)         clean_aria2 ;;
        ffmpeg)        clean_ffmpeg ;;
        cloudflared)   clean_cloudflared ;;
        tailscale)     clean_tailscale ;;
        sshx)          clean_sshx ;;
      esac
      ;;
    "")
      # Reached from the clean MENU: remove exactly the tools TICKED
      # (binary + payload only, not env wiring). An empty selection is a
      # graceful no-op — nothing to remove.
      if [[ ${#CLEAN_TOOLS[@]} -eq 0 ]]; then
        skip "no tools selected in the cleanup menu — nothing removed"
        return 0
      fi
      summary="$(IFS=','; echo "${CLEAN_TOOLS[*]}")"
      hint="bash setup.sh"
      # Drop env wiring FIRST, then remove the ticked binaries + payload.
      [[ -f "$BASHRC" ]] && strip_tool_wiring "${CLEAN_TOOLS[*]}" "$BASHRC"
      [[ " ${CLEAN_TOOLS[*]} " == *" hermes "* ]] && strip_legacy_hermes_block "$BASHRC" || true
      local replit_file="${REPL_HOME:-$WORKSPACE}/.replit"
      [[ "$REPLIT_MODE" == true && -f "$replit_file" ]] && strip_userenv_keys "${CLEAN_TOOLS[*]}" "$replit_file"
      local label
      for label in "${CLEAN_TOOLS[@]}"; do
        case "$label" in
          android)  clean_android ;;
          java)     clean_java ;;
          uv)       clean_uv ;;
          node)     clean_node ;;
          opencode) clean_opencode ;;
          ollama)   clean_ollama ;;
          claude)   clean_claude ;;
          hermes)   clean_hermes ;;
          ori)      clean_ori ;;
          camofox)  clean_camofox ;;
          lightpanda) clean_lightpanda ;;
          moli) clean_moli ;;
          tor) clean_tor ;;
          hermes-chromium) clean_hermes_chromium ;;
          zsh)      clean_zsh ;;
          llm-wiki) clean_llm_wiki ;;
          rclone)   clean_rclone ;;
          qbt)      clean_qbt ;;
          aria2)    clean_aria2 ;;
          ffmpeg)   clean_ffmpeg ;;
          cloudflared) clean_cloudflared ;;
          tailscale)   clean_tailscale ;;
          sshx)        clean_sshx ;;
          *)        warn "Unknown clean target '$label' — skipped" ;;
        esac
      done
      ;;
    *)
      die "Unknown --clean target '$CLEAN_TARGET'. Valid: all, android-tools, java, uv, node, zsh, oc, opencode, ollama, claude, hermes, ori, camofox, lightpanda, moli, hermes-chromium, llm-wiki, rclone, qbt, aria2, ffmpeg, cloudflared, tailscale, sshx"
      ;;
  esac
  # Manifest mop-up: remove anything install recorded for the labels this
  # run cleaned that the per-tool clean did not reach (e.g. a payload whose
  # derived location moved between install and clean). Labels in
  # _CLEAN_SKIPPED are exempt — a tool that refused removal (Hermes backup
  # failure) keeps its payload, manifest or not. tailscale has no manifest
  # records by design, so it is a no-op there.
  local -a _sweep_labels=()
  case "$CLEAN_TARGET" in
    all) _sweep_labels=(android uv node zsh opencode ollama claude hermes ori camofox lightpanda moli hermes-chromium llm-wiki rclone qbt aria2 ffmpeg cloudflared sshx) ;;
    "")  _sweep_labels=("${CLEAN_TOOLS[@]}") ;;
    *)   local _one="$CLEAN_TARGET"
         [[ "$_one" == android-tools ]] && _one=android
         [[ "$_one" == oc ]] && _one=opencode
         _sweep_labels=("$_one") ;;
  esac
  local _lbl
  for _lbl in "${_sweep_labels[@]}"; do
    [[ " ${_CLEAN_SKIPPED[*]} " == *" $_lbl "* ]] && continue
    manifest_sweep "$_lbl" || true
  done

  cat <<CLEANMSG
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 Cleanup complete for: $summary

 Reinstall: $hint
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
CLEANMSG
  if ((${#_BACKUPS_TAKEN[@]})); then
    echo ""
    for summary in "${_BACKUPS_TAKEN[@]}"; do
      ok "Backup kept: ${summary#*->}"
    done
  fi
  if ((${#_CLEAN_SKIPPED[@]})); then
    echo ""
    for summary in "${_CLEAN_SKIPPED[@]}"; do
      warn "Not removed (backup failed, payload intact): $summary"
    done
  fi
}
