# shellcheck shell=bash
# Wiring repair (--fix): re-derive registrations, never reinstall. Sourced by setup.sh.
# Repair mode: re-apply wiring without reinstalling tools (--fix) ────────────
# Normal flow is delete+reinstall (write_bashrc regenerates the managed
# block from what installers register). --fix instead DERIVES the same
# registrations from the payloads already on disk, then calls the regular
# writers — so it repairs exactly what the user cares about without touching
# a single binary:
#   - $BASHRC managed toolchain block (PATH dirs + tool vars, rescue merge
#     preserves operator edits and unrelated tool lines),
#   - the hermes-tools rc block (Hermes env + launcher PATH; only when
#     $HERMES_HOME/tools exists),
#   - .replit [userenv.shared] keys (existing keys re-set to canonical
#     values; keys of tools NOT installed are left alone — never resurrected),
#   - the workflow shim + REPLIT_BASHRC pin (unconditional in replit mode),
#   - $HOME/.profile (ephemeral dir — Replit's own template is recreated +
#     toolchain PATH lines appended; makes login/ssh shells self-contained),
#   - hermes config terminal.shell_init_files (~/.profile + $REPLIT_BASHRC —
#     makes Hermes terminal/cron shells source the same chain),
#   - durable libatomic (cheap no-op once in place).
# Bare --fix also prints the doctor report after repairing; --doctor --fix
# reports first, then repairs.
fix_derive_wiring() {
  # PATH dirs must mirror the installer registrations exactly (same order),
  # because write_bashrc rewrites the whole block and rescue re-adds existing
  # lines after them — any deviation duplicates entries in every shell.
  if [[ -d "$SDK" ]]; then
    record_tool_env_vars JAVA_HOME ANDROID_HOME JAVA_TOOL_OPTIONS
    record_tool_path_dirs "$JAVA_HOME/bin" "$SDK/cmdline-tools/bin" "$SDK/platform-tools" "$XDG_BIN_HOME"
  elif [[ -x "$JAVA_HOME/bin/java" ]]; then
    # Standalone Java (no Android SDK): mirror install_java_tools.
    record_tool_env_vars JAVA_HOME
    record_tool_path_dirs "$JAVA_HOME/bin" "$XDG_BIN_HOME"
  fi
  if [[ -x "$XDG_BIN_HOME/uv" ]]; then
    record_tool_env_vars UV_PYTHON_DOWNLOADS UV_PYTHON_PREFERENCE PYTHONPATH
    record_tool_path_dirs "$XDG_BIN_HOME"
  fi
  # node payload marker: install_node extracts the official tarball, whose
  # bin/node is the load-bearing artifact (no VERSION file is written).
  # Do NOT gate on an inherited npm_config_prefix — Replit's platform sets
  # it on EVERY repl, so it would resurrect node wiring where our payload
  # never landed.
  if [[ -x "$NODE_DIR/bin/node" ]]; then
    record_tool_env_vars NODE_DIR npm_config_prefix "${_TLS_ENV_VARS[@]}"
    record_tool_path_dirs "$NODE_DIR/bin" "$WORKSPACE/node_modules/.bin" "$XDG_BIN_HOME"
  fi
  if [[ -x "$XDG_BIN_HOME/opencode" ]]; then
    record_tool_env_vars OPENCODE_CONFIG_DIR; record_tool_path_dirs "$XDG_BIN_HOME"
  fi
  if [[ -x "$XDG_BIN_HOME/ollama" ]]; then
    record_tool_env_vars OLLAMA_INSTALL_DIR OLLAMA_MODELS; record_tool_path_dirs "$XDG_BIN_HOME"
  fi
  if [[ -x "$XDG_BIN_HOME/claude" ]]; then
    record_tool_env_vars CLAUDE_CONFIG_DIR; record_tool_path_dirs "$XDG_BIN_HOME"
  fi
  # Mirror install_hermes' registration exactly: HERMES_HOME /
  # HERMES_MANAGED_DIR and the launcher dir (an ordinary managed-block PATH
  # line since the pre-merge hermes-tools block was folded in). Gate on an
  # actual install — a bare $HERMES_HOME dir (leftovers, a wiped launcher)
  # must not resurrect wiring the tool cannot back.
  if [[ -x "$HERMES_LAUNCHER_DIR/hermes" || -d "$HERMES_HOME/tools" ]]; then
    record_tool_env_vars HERMES_HOME HERMES_MANAGED_DIR
    record_tool_path_dirs "$XDG_BIN_HOME" "$HERMES_LAUNCHER_DIR"
  fi
  # Mirror install_zsh's registration exactly. The zsh profile symlink is the
  # marker; ZDOTDIR is the load-bearing var (there is no $HOME/.zshrc, so a
  # bare `zsh` with no ZDOTDIR starts with no dotfiles, theme or plugins).
  # Without this branch a --fix could never restore ZDOTDIR: install_zsh only
  # registers it on the run that installs zsh.
  if [[ -x "$XDG_BIN_HOME/zsh" ]]; then
    record_tool_env_vars ZDOTDIR
    record_tool_path_dirs "$XDG_BIN_HOME"
  fi
  if [[ -x "$XDG_BIN_HOME/ori" ]]; then
    record_tool_env_vars ORI_CONFIG_DIR; record_tool_path_dirs "$XDG_BIN_HOME"
  fi
  # Camofox: the npm binary is the marker (installed globally, on PATH).
  if [[ -x "$XDG_BIN_HOME/camofox-browser" || -x "$NODE_DIR/bin/camofox-browser" ]]; then
    record_tool_env_vars CAMOUFOX_INSTALL_DIR; record_tool_path_dirs "$XDG_BIN_HOME"
    # state dirs: a cookie jar under $HOME/.camofox is wiped on recreate, so
    # the four server vars are re-asserted here (no install needed to repair).
    record_tool_env_vars CAMOFOX_STATE_DIR CAMOFOX_PROFILE_DIR CAMOFOX_COOKIES_DIR \
                         CAMOFOX_UPLOADS_DIR CAMOFOX_TRACES_DIR
    mkdir -p "$CAMOFOX_PROFILE_DIR" "$CAMOFOX_COOKIES_DIR" "$CAMOFOX_UPLOADS_DIR" "$CAMOFOX_TRACES_DIR" 2>/dev/null || true
    camofox_migrate_state
    # env.sh + the launcher shim are pure wiring for non-interactive shells
    # (.replit workflows / Run button): regenerated here so `--fix` restores a
    # wiped closure snippet, and `--doctor` can gate on them.
    camofox_write_env_snippet
    camofox_write_launcher
  fi
  # Lightpanda: the home binary is the marker. Re-assert the PATH symlink
  # and the config template so --fix repairs a wiped bin entry or a lost
  # .env.example without a reinstall.
  if [[ -x "$LIGHTPANDA_BIN" ]]; then
    record_tool_env_vars LIGHTPANDA_HOME LIGHTPANDA_BIN; record_tool_path_dirs "$XDG_BIN_HOME"
    ln -sfn "$LIGHTPANDA_BIN" "$XDG_BIN_HOME/lightpanda"
    lightpanda_write_env_example
  fi
  # Moli: same shape — re-assert the PATH symlink, the launcher and
  # the config template.
  if [[ -x "$MOLI_BIN" ]]; then
    record_tool_env_vars MOLI_HOME MOLI_BIN; record_tool_path_dirs "$XDG_BIN_HOME"
    ln -sfn "$MOLI_BIN" "$XDG_BIN_HOME/moli"
    moli_write_launcher
    moli_write_env_example
  fi
  local b
  # Direct-binary tools own nothing but their file in $XDG_BIN_HOME, so one
  # presence check per tool is the whole wiring.
  for b in rclone qbittorrent-nox aria2c ffmpeg cloudflared tailscale sshx; do
    [[ -x "$XDG_BIN_HOME/$b" ]] && record_tool_path_dirs "$XDG_BIN_HOME"
  done
  # tailscale is the one of these with a generated companion: refresh its
  # launcher too, so a .replit workflow target is never a stale copy. Its path
  # and node-name exports are re-registered here because a --fix run never calls
  # the installer, and a lost export would strand the socket path in the rc block.
  if [[ -x "$XDG_BIN_HOME/tailscaled" ]]; then
    record_tool_env_vars TAILSCALE_DATA_DIR TAILSCALE_STATE_DIR TAILSCALE_SOCKET TAILSCALE_LOG
    wire_tool tailscale TAILSCALE_DATA_DIR TAILSCALE_STATE_DIR TAILSCALE_SOCKET TAILSCALE_LOG -- "$XDG_BIN_HOME"
    tailscale_write_launcher
  fi
  return 0
}

# Merge helper: keep existing keys, but correct values of keys ALREADY
# present (a drifted REPLIT_BASHRC pin / stale HERMES_HOME path gets
# rewritten; absent keys of uninstalled tools are NOT added).
fix_reanchor_existing_keys() {
  local replit_file="$REPL_HOME/.replit"
  [[ "$REPLIT_MODE" == true && -f "$replit_file" && -w "$replit_file" ]] || return 0
  local var
  for var in ${_TOOL_ENV_VARS[@]+"${_TOOL_ENV_VARS[@]}"}; do
    if grep -qE "^${var}[[:space:]]*=" "$replit_file"; then
      _PRESET_ENV["$var"]="${!var}"
    fi
  done
}

fix_profile() {
  local p="$HOME/.profile"
  [[ -f "$p" ]] || cat > "$p" <<'EOF'
# ~/.profile: executed by the command interpreter for login shells.
# Recreated by setup.sh (--fix) — Replit's /etc/skel template lives
# on ephemeral $HOME; the toolchain lines below are the managed part.

if [ -n "$BASH_VERSION" ]; then
    if [ -f "$HOME/.bashrc" ]; then
	. "$HOME/.bashrc"
    fi
fi
EOF
  grep -qF '>>> toolchain-profile >>>' "$p" && { ok "toolchain lines already in $p"; return 0; }
  local tmp; tmp="$(mktemp)"
  cat "$p" > "$tmp"
  {
    echo ""
    echo "# >>> toolchain-profile >>> (managed by setup.sh --fix)"
    echo "export WORKSPACE=\"$WORKSPACE\""
    # Only export tool vars whose payload exists: a JAVA tool honoring a
    # JAVA_HOME that points at a deleted dir mis-detects worse than one
    # that is unset. XDG/HERMES_HOME are platform paths — always valid.
    local vars=(XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_BIN_HOME HERMES_HOME)
    [[ -d "$SDK" ]] && vars+=(JAVA_HOME ANDROID_HOME)
    local v
    for v in "${vars[@]}"; do printf 'export %s="%s"\n' "$v" "${!v}"; done
    echo "export PATH=\"$XDG_BIN_HOME:\$PATH\""
    local dirs=() d
    [[ -d "$SDK" ]] && dirs+=("$JAVA_HOME/bin" "$SDK/cmdline-tools/bin" "$SDK/platform-tools")
    [[ -x "$NODE_DIR/bin/node" ]] && dirs+=("$NODE_DIR/bin")
    for d in "${dirs[@]+"${dirs[@]}"}"; do
      printf 'case ":$PATH:" in *":%s:"*) ;; *) export PATH="%s:$PATH" ;; esac\n' "$d" "$d"
    done
    echo "# <<< toolchain-profile <<<"
  } >> "$tmp"
  if bash -n "$tmp" 2>/dev/null; then
    cat "$tmp" > "$p"
    ok "toolchain lines appended to $p"
  else
    warn "$p failed bash -n — left untouched"
  fi
  rm -f "$tmp"
}

# Parse terminal.shell_init_files from the RAW config.yaml: the key line plus
# immediately-following '- ' items (any indent depth, unbounded count —
# grep -A3 silently misses the chain when other keys sit between). Prints the
# block; empty when the key is absent. Shared by fix_hermes_config and doctor.
_parse_shell_init() {
  awk '
    /^[[:space:]]*shell_init_files:/ {f=1; print; next}
    f && /^[[:space:]]*-/             {print; next}
    f                                 {exit}
  ' "$1"
}

fix_hermes_config() {
  local cfg="${HERMES_HOME:-${REPL_HOME:-$HOME}/.hermes}/config.yaml"
  # Parse the RAW yaml (hermes config get EXPANDS ${REPLIT_BASHRC} to its
  # value, so a resolved-read can't prove the literal is stored). Accept
  # either order of the two entries.
  local raw=""
  [[ -f "$cfg" ]] && raw="$(_parse_shell_init "$cfg")"
  if [[ "$raw" == *~/.profile* && "$raw" == *REPLIT_BASHRC* ]]; then
    ok "hermes config terminal.shell_init_files already chained"
    return 0
  fi
  # NEVER execute the `hermes` launcher from a wiring-only repair: any
  # subcommand can boot the full source-update cycle (venv sync, npm build,
  # a multi-GB runtime clone) — minutes of side effects for a YAML write.
  # Edit the file textually instead (comments/format outside the block
  # untouched), verify by re-parsing, revert from backup if wrong.
  if [[ ! -f "$cfg" ]]; then
    warn "$cfg missing — start hermes once (or create it), then re-run: bash setup.sh --fix"
    return 0
  fi
  [[ -w "$cfg" ]] || { warn "$cfg not writable — edit by hand: shell_init_files: [~/.profile, \${REPLIT_BASHRC}]"; return 0; }
  local backup; backup="$(mktemp)"
  cp "$cfg" "$backup"
  # Preferred edit: yq (mikefarah v4, on PATH as /repl/tools/bin/yq). It
  # rewrites ONLY the targeted key and preserves comments — verified on this
  # box's 254 KB config.yaml (comment count unchanged). The old awk fallback
  # below stays for boxes without yq. The yq expression is SINGLE-quoted so
  # ${REPLIT_BASHRC} is written literally into the YAML (it is expanded by
  # the shell that sources the file, not by us).
  local edited=0
  if command -v yq >/dev/null 2>&1; then
    if yq -i '.terminal.shell_init_files = ["~/.profile", "${REPLIT_BASHRC}"]' "$cfg" 2>/dev/null; then
      edited=1
    fi
  fi
  if (( ! edited )) && grep -qE '^[[:space:]]*shell_init_files:' "$cfg"; then
    awk '
      /^[[:space:]]*shell_init_files:/ && !done {
        indent = match($0, /[^ ]/) - 1
        print substr("                ", 1, indent) "shell_init_files:"
        print substr("                  ", 1, indent + 2) "- ~/.profile"
        print substr("                  ", 1, indent + 2) "- ${REPLIT_BASHRC}"
        done = 1; swallow = 1; next
      }
      swallow && /^[[:space:]]*-/ { next }
      { swallow = 0; print }
    ' "$backup" > "$cfg"
  elif (( ! edited )) && grep -qE '^terminal:' "$cfg"; then
    awk '
      { print }
      /^terminal:/ && !done {
        print "  shell_init_files:"
        print "    - ~/.profile"
        print "    - ${REPLIT_BASHRC}"
        done = 1
      }
    ' "$backup" > "$cfg"
  elif (( ! edited )); then
    rm -f "$backup"
    warn "no terminal: block in $cfg — edit by hand: terminal.shell_init_files: [~/.profile, \${REPLIT_BASHRC}]"
    return 0
  fi
  local after; after="$(_parse_shell_init "$cfg")"
  if [[ "$after" == *~/.profile* && "$after" == *REPLIT_BASHRC* ]]; then
    rm -f "$backup"
    if (( edited )); then
      ok "hermes config terminal.shell_init_files -> [~/.profile, \${REPLIT_BASHRC}] (yq)"
    else
      ok "hermes config terminal.shell_init_files -> [~/.profile, \${REPLIT_BASHRC}] (direct edit)"
    fi
  else
    cat "$backup" > "$cfg"; rm -f "$backup"
    warn "shell_init_files edit failed verification — $cfg reverted; edit it by hand"
  fi
}

run_fix() {
  step "Wiring repair (no tools deleted or reinstalled)"
  local replit_file="${REPL_HOME:-$WORKSPACE}/.replit"

  # --- 1. shell rc (managed toolchain block + hermes-tools block) ---
  fix_derive_wiring
  # The hermes-tools block is re-appended by write_bashrc itself (gated on
  # $INSTALL_HERMES / its marker / $HERMES_HOME/tools), so a missing or
  # mis-ordered block is rebuilt here too. No separate call: it would only
  # repeat the same work and print the ok line twice.
  write_bashrc

  # --- 2. .replit [userenv.shared] ---
  if [[ "$REPLIT_MODE" == true && -f "$replit_file" && -w "$replit_file" ]]; then
    local before after; before="$(md5sum "$replit_file")"
    rescue_userenv_keys "$replit_file"
    fix_reanchor_existing_keys
    write_replit_env
    after="$(md5sum "$replit_file")"
    [[ "$before" == "$after" ]] && ok ".replit userenv already canonical (unchanged)"
  fi

  # --- 3. workflow shim + pin (unconditional in replit mode) ---
  write_replit_bashrc

  # --- 4. login-shell profile + hermes config chain ---
  fix_profile
  fix_hermes_config

  # Camofox GTK closure + Hermes Chromium closure: re-resolve on THIS machine
  # (store hashes are not portable) so a --fix after a machine change repairs them.
  [[ -n "$(hermes_chrome_bin 2>/dev/null || true)" ]] && install_hermes_chromium

  # --- 5. durable libatomic (official Node tarballs need it regardless) ---
  ensure_libatomic

  ok "wiring repair complete — open a new shell (or 'source $BASHRC') to load"
}
