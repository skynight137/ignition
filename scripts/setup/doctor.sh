# shellcheck shell=bash
# Read-only toolchain self-check (--doctor). Sourced by setup.sh.
# Doctor (no-install self-check) ──────────────────────────────────────────────
doctor() {
  step "Environment doctor"
  local fail=0 wfail=0
  local name cmd ver

  check_tool() {
    name="$1"; cmd="$2"
    # Optional 3rd arg: the version flag to probe with. Defaults to GNU
    # --version; FFmpeg only accepts the single-dash -version and exits 8 on
    # --version by design, which used to read as a broken install.
    local vflag="${3:---version}"
    if command -v "$cmd" &>/dev/null; then
      # Gate on the tool's OWN exit status: a pipe under pipefail reports the
      # pipeline (a loader-failed binary exits nonzero but the exit-141 of a
      # short 'head' is noise, and 'grep -q' masks the real code). Capture
      # raw output + rc, then filter. Loader failures (libatomic.so.1) used
      # to print as '✓ Node: error while loading shared libraries...'.
      local _raw _rc=0
      _raw="$("$cmd" "$vflag" 2>&1)" || _rc=$?
      _raw="$(printf '%s\n' "$_raw" | grep -v '^Picked up' | head -1)"
      if (( _rc == 0 )); then
        ok "$name: $_raw"
      else
        warn "$name: found but FAILED to run (exit $_rc): ${_raw:-no output} (check ldd / LD_LIBRARY_PATH wiring; 'bash setup.sh --fix' heals the pool+rc wiring — some tools like ffmpeg's static builds exit nonzero on --version by design)"
        fail=1
      fi
    else
      # NOT FOUND is an INSTALLATION state, not a wiring failure — --fix
      # cannot make a never-installed tool appear. Tracked separately from
      # the wiring checks below so the summary doesn't point at --fix for
      # tools the operator deliberately skipped.
      warn "$name: NOT FOUND ($cmd) — install it, or ignore if not used"
      fail=1
    fi
  }

  check_tool "Java" java
  check_tool "Android SDK (adb)" adb
  check_tool "uv" uv
  check_tool "Node" node
  check_tool "npm" npm
  check_tool "OpenCode" "$XDG_BIN_HOME/opencode"
  check_tool "Ollama" ollama
  check_tool "Claude" "$XDG_BIN_HOME/claude"
  check_tool "zsh" "$XDG_BIN_HOME/zsh"
  # The real launcher (the official installer's .local/bin shim just execs
  # this) — the managed rc block registers this dir on PATH.
  check_tool "Hermes" "$HERMES_HOME/hermes-agent/.hermes/bin/hermes"
  check_tool "ORI" "$XDG_BIN_HOME/ori"
  check_tool "rclone" "$XDG_BIN_HOME/rclone"
  check_tool "qBittorrent-nox" "$XDG_BIN_HOME/qbittorrent-nox"
  check_tool "aria2c" "$XDG_BIN_HOME/aria2c"
  # FFmpeg probes with -version (single dash): --version prints the banner
  # and exits 8 by design, so the generic --version probe false-fails.
  check_tool "FFmpeg" "$XDG_BIN_HOME/ffmpeg" -version
  # Remote access (see references/exposing-ports.md). All three are optional
  # extras; tailscale takes a SUBCOMMAND ('version'), not a flag.
  check_tool "cloudflared" "$XDG_BIN_HOME/cloudflared"
  # The gate is the EXPORT line, not a marker: tailscale's state dir and socket
  # are consumed by other scripts, so a missing export breaks them silently.
  check_tool "tailscale" "$XDG_BIN_HOME/tailscale" version
  # Gate the wiring on the EXPORT line itself: check_tool returns 0 even on a
  # failure, and these paths are consumed by other scripts, so a lost export
  # breaks them silently.
  if [[ -x "$XDG_BIN_HOME/tailscale" ]] && ! grep -q '^export TAILSCALE_SOCKET=' "$BASHRC" 2>/dev/null; then
    warn "tailscale: TAILSCALE_SOCKET/TAILSCALE_DATA_DIR export missing from the rc block — run 'bash setup.sh --fix'"
  fi
  check_tool "sshx" "$XDG_BIN_HOME/sshx"
  # Lightpanda also takes a SUBCOMMAND ('version'), not a flag — passing
  # --version exits 1 by design and would read as a broken install.
  check_tool "Lightpanda" "$XDG_BIN_HOME/lightpanda" version
  # Moli takes the --version FLAG (its `version` is not a subcommand).
  check_tool "Moli" "$XDG_BIN_HOME/moli" --version
  if [[ -x "$XDG_BIN_HOME/lightpanda" ]]; then
    if [[ -x "${LIGHTPANDA_HOME:-}/venv/bin/python" ]] \
       && "${LIGHTPANDA_HOME}/venv/bin/python" -c 'import playwright' 2>/dev/null; then
      ok "lightpanda tour venv: playwright importable (${LIGHTPANDA_HOME}/venv)"
    else
      warn "lightpanda tour venv missing or playwright not importable (${LIGHTPANDA_HOME:-}/venv) — the tour cannot run; run: bash setup.sh --lightpanda"
    fi
  fi
  # The .replit TOML writer's interpreter. Doctor is READ-ONLY: probe with
  # provisioning disabled — a miss here is not a failure, because the next
  # setup write provisions uv + a tomlkit venv itself (rc.sh). The line
  # exists so a fleet audit can see WHICH source each box resolves.
  local -a _tpy=()
  if SETUP_TOML_NO_PROVISION=1 replit_resolve_py _tpy; then
    local _tver; _tver="$("${_tpy[@]}" -c 'import tomlkit; print(tomlkit.__version__)' 2>/dev/null)"
    ok "toml python: $TOML_PY_DESC (tomlkit ${_tver:-unknown})"
  else
    warn "toml python: none tomlkit-capable yet — the next setup write provisions one (uv + $TOML_VENV)"
  fi
  # llm-wiki is a server, not a CLI: there is no --version to probe, so check the
  # installed bundle instead. Warn-only — the server is opt-in and a box that
  # does not want a knowledge base must not fail its doctor run over it.
  local _wiki_dir="${LLM_WIKI_HOME:-${REPL_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}}/llmwiki-app}"
  if [[ -x "$_wiki_dir/run-public.sh" ]]; then
    if [[ -s "$_wiki_dir/.env" || -s "$_wiki_dir/llmwiki.env" ]]; then
      ok "llm-wiki: server installed ($_wiki_dir)"
    else
      warn "llm-wiki: bundle present but no $_wiki_dir/.env — re-run: bash setup.sh --llm-wiki"
    fi
  else
    warn "llm-wiki: not installed — bash setup.sh --llm-wiki (optional knowledge-base server)"
  fi
  # Camofox: the npm binary on PATH + engine presence.
  if command -v camofox-browser >/dev/null 2>&1; then
    if [[ -f "$CAMOUFOX_INSTALL_DIR/version.json" ]]; then
      ok "Camofox: camofox-browser + engine ($(cat "$CAMOUFOX_INSTALL_DIR/version.json" 2>/dev/null))"
    else
      warn "camofox-browser present but engine missing in $CAMOUFOX_INSTALL_DIR — run: bash setup.sh --camofox"
      fail=1
    fi
  else
    warn "Camofox: NOT FOUND (camofox-browser) — install with --camofox, or ignore if not used"
    fail=1
  fi
  case ":$_ENTRY_PATH:" in
    *":$XDG_BIN_HOME:"*) ok "XDG_BIN_HOME on PATH" ;;
    *) warn "XDG_BIN_HOME NOT on PATH (open a new shell)"; fail=1 ;;
  esac

  # --- wiring integrity (repairs: bash setup.sh --fix) ---
  if [[ "$REPLIT_MODE" == true ]]; then
    if [[ -f "${REPLIT_BASHRC_FILE:-}" ]]; then
      ok "workflow shim: $REPLIT_BASHRC_FILE"
    else
      warn "workflow shim missing ($REPLIT_BASHRC_FILE) — run: bash setup.sh --fix"
      wfail=1
    fi
  fi
  if [[ -f "$BASHRC" ]] && grep -q '# >>> toolchain >>>' "$BASHRC"; then
    ok "managed toolchain block in $BASHRC"
  else
    warn "no managed toolchain block in $BASHRC — run: bash setup.sh --fix"
    wfail=1
  fi
  # libatomic pool: the exact v4.5.x failure class ('✓ staged' while node
  # dies) is invisible to every other wiring check — verify the durable copy
  # itself. Skip on boxes where the system loader really resolves it (same
  # trust-but-verify as ensure_libatomic: cached path must exist + be x86-64).
  _doc_la="$(command -v ldconfig &>/dev/null && ldconfig -p 2>/dev/null | grep 'libatomic\.so\.1' | head -1)"; _doc_la="${_doc_la##*=> }"
  if [[ -n "$_doc_la" && -e "$_doc_la" ]] && file -L "$_doc_la" 2>/dev/null | grep -q 'ELF 64-bit LSB shared object, x86-64'; then
    ok "libatomic resolved by the system loader"
  elif [[ -e "$WORKSPACE/.local/lib/libatomic.so.1" ]] \
     && file -L "$WORKSPACE/.local/lib/libatomic.so.1" 2>/dev/null | grep -q 'ELF 64-bit LSB shared object, x86-64'; then
    ok "libatomic in pool ($WORKSPACE/.local/lib)"
  else
    warn "libatomic missing/not x86-64 in $WORKSPACE/.local/lib — node will fail to load; run: bash setup.sh --fix"
    wfail=1
  fi
  if [[ -d "$HERMES_HOME/tools" ]]; then
    # Hermes wiring lives in the managed toolchain block now (the separate
    # hermes-tools block was folded in): HERMES_HOME / HERMES_MANAGED_DIR as
    # tool vars, the launcher dir as a PATH line.
    if [[ -f "$BASHRC" ]] \
       && grep -qE '^export[[:space:]]+HERMES_HOME=' "$BASHRC" \
       && grep -qF "$HERMES_LAUNCHER_DIR" "$BASHRC"; then
      ok "hermes env + launcher PATH in the managed block of $BASHRC"
    else
      warn "hermes wiring missing from $BASHRC — run: bash setup.sh --fix"
      wfail=1
    fi
  fi
  if [[ -x "$XDG_BIN_HOME/zsh" ]]; then
    # ZDOTDIR is the whole zsh wiring: no $HOME/.zshrc exists, so without it a
    # bare `zsh` starts with no theme, plugins or tool paths. It must live in
    # the managed block, not in a hand-added snippet above it, or a rewritten
    # rc drops it (nothing else writes it).
    if [[ -f "$BASHRC" ]] && grep -qE '^export[[:space:]]+ZDOTDIR=' "$BASHRC"; then
      ok "ZDOTDIR in the managed block of $BASHRC"
    else
      warn "ZDOTDIR missing from $BASHRC — bare zsh loses its dotfiles; run: bash setup.sh --fix"
      wfail=1
    fi
  fi
  # Camofox closure bus: env.sh + the launcher shim. A NON-interactive shell
  # (every .replit workflow task, the Run button, MCP/cron children) never
  # sources env.sh, so a bare `camofox-browser` there launches Firefox with no
  # GTK closure and dies with `libmozgtk.so: libgtk-3.so.0: cannot open shared
  # object file` — surfacing to the client as an opaque 500 on cookie import
  # (six logged "rp" runs hit this). Gate on the wiring, not just the binary.
  if [[ -x "$XDG_BIN_HOME/camofox-browser" || -x "$NODE_DIR/bin/camofox-browser" ]]; then
    if [[ -s "$CAMOFOX_CLOSURE_FILE" ]]; then
      ok "camofox lib closure ($(tr ':' '\n' < "$CAMOFOX_CLOSURE_FILE" | grep -c .) lib dirs)"
    else
      warn "camofox lib closure missing/empty ($CAMOFOX_CLOSURE_FILE) — Firefox cannot start; run: bash setup.sh --camofox"
      wfail=1
    fi
    if [[ -s "$CAMOFOX_ENV_SNIPPET" ]]; then
      ok "camofox env snippet: $CAMOFOX_ENV_SNIPPET"
    else
      warn "camofox env snippet missing ($CAMOFOX_ENV_SNIPPET) — non-interactive shells get no GTK closure; run: bash setup.sh --fix"
      wfail=1
    fi
    if [[ -x "$XDG_BIN_HOME/launch-camofox-browser" ]]; then
      ok "camofox launcher shim: $XDG_BIN_HOME/launch-camofox-browser"
    else
      warn "camofox launcher shim missing ($XDG_BIN_HOME/launch-camofox-browser) — a bare 'camofox-browser' in a workflow shell dies without GTK; run: bash setup.sh --fix"
      wfail=1
    fi
    # playwright-core vs the engine's juggler schema: a client newer than the
    # schema breaks EVERY cookie import (storage-state pages pass
    # bypassServiceWorker, which the engine's Protocol.js does not declare)
    # while ordinary tab work keeps working — so a bare `npm install -g`
    # silently re-breaks logins. setup.sh --camofox pins it; check the pin here.
    local _pwj; _pwj="$(camofox_pkg_dir)/node_modules/playwright-core/package.json"
    if [[ -f "$_pwj" ]] && command -v node >/dev/null 2>&1; then
      local _pw; _pw="$(node -p "require('$_pwj').version" 2>/dev/null || true)"
      if [[ -z "$_pw" ]]; then
        warn "camofox playwright-core version unreadable ($_pwj)"
        wfail=1
      elif camofox_engine_accepts_bypass_sw; then
        ok "camofox playwright-core $_pw (engine accepts bypassServiceWorker)"
      elif [[ "$(printf '%s\n%s\n' "$CAMOFOX_PLAYWRIGHT_MAX" "$_pw" | sort -V | tail -1)" == "$_pw" && "$_pw" != "$CAMOFOX_PLAYWRIGHT_MAX" ]]; then
        warn "camofox playwright-core $_pw is newer than the engine's juggler schema — every cookie import will 500; run: bash setup.sh --camofox (pins $CAMOFOX_PLAYWRIGHT_MAX)"
        wfail=1
      else
        ok "camofox playwright-core $_pw (compatible with the engine)"
      fi
    fi
    # State dir: $HOME is wiped on recreate, so a profile/cookie jar left at the
    # package default (~/.camofox) silently loses the login. Gate on the pins.
    if [[ "${CAMOFOX_PROFILE_DIR:-}" == "$WORKSPACE"/* || "${CAMOFOX_PROFILE_DIR:-}" == "$REPL_HOME"/* ]]; then
      ok "camofox state dir: ${CAMOFOX_PROFILE_DIR}"
    elif [[ -n "${CAMOFOX_PROFILE_DIR:-}" ]]; then
      warn "camofox state dir is OUTSIDE the persistent workspace (${CAMOFOX_PROFILE_DIR}) — profiles/cookies die on recreate; run: bash setup.sh --fix"
      wfail=1
    else
      warn "camofox state dir not pinned — the server defaults to \$HOME/.camofox (wiped on recreate); run: bash setup.sh --fix"
      wfail=1
    fi
    # Legacy state still sitting at the volatile $HOME default: only a problem when
    # the persistent target has NOT been populated yet (migration pending). Both
    # dirs holding data is the normal post-migration state — the copy is
    # deliberately non-destructive, so it must not read as a wiring failure.
    if [[ -n "${CAMOFOX_PROFILE_DIR:-}" && "$CAMOFOX_PROFILE_DIR" != "$HOME/.camofox/profiles" ]] \
       && [[ -z "$(find "$CAMOFOX_PROFILE_DIR" -mindepth 1 -print -quit 2>/dev/null)" ]] \
       && [[ -d "$HOME/.camofox/profiles" ]] \
       && [[ -n "$(find "$HOME/.camofox/profiles" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
      warn "camofox state not migrated: \$HOME/.camofox has cookies/profiles but ${CAMOFOX_PROFILE_DIR} is empty — run: bash setup.sh --camofox"
      wfail=1
    fi
  fi
  if [[ -f "$HOME/.profile" ]] && grep -qF 'toolchain-profile' "$HOME/.profile"; then
    ok "toolchain lines in ~/.profile"
  else
    warn "no toolchain lines in ~/.profile (login/ssh shells lack PATH) — run: bash setup.sh --fix"
    wfail=1
  fi
  if [[ -f "${HERMES_HOME}/config.yaml" ]] \
     && _parse_shell_init "${HERMES_HOME}/config.yaml" | grep -q '~/.profile' \
     && _parse_shell_init "${HERMES_HOME}/config.yaml" | grep -q 'REPLIT_BASHRC'; then
    ok "hermes config shell_init_files chained"
  else
    warn "hermes terminal shells don't source ~/.profile/\$REPLIT_BASHRC — run: bash setup.sh --fix"
    wfail=1
  fi

  # Summary: installation gaps (missing tools) and wiring gaps get separate
  # advice — --fix repairs wiring, only an install run brings back binaries.
  if (( fail == 0 && wfail == 0 )); then
    ok "All checks passed"
  else
    (( wfail )) && warn "Wiring incomplete — repair with: bash setup.sh --fix"
    (( fail )) && warn "Some tools missing — install them (or ignore if never installed)"
  fi
  (( wfail )) && return 2
  return $fail
}

# Show current toolchain state — read-only, no installs run.
list_state() {
  step "Toolchain state"
  local found
  echo "Mode: $( [[ "$REPLIT_MODE" == true ]] && echo 'replit (persistent)' || echo 'default (HOME)')"
  echo "Workspace: $WORKSPACE"
  echo "XDG_BIN_HOME: $XDG_BIN_HOME"
  echo "XDG_DATA_HOME: $XDG_DATA_HOME"
  echo "BASHRC target: $BASHRC"
  echo

  # Check managed block in BASHRC
  if [[ -f "$BASHRC" ]] && grep -q '# >>> toolchain >>>' "$BASHRC"; then
    echo "=== $BASHRC managed block ==="
    local in_block=0 line
    while IFS= read -r line; do
      case "$line" in
        '# >>> toolchain >>>') in_block=1; continue ;;
        '# <<< toolchain <<<') in_block=0; continue ;;
      esac
      (( in_block )) && echo "$line"
    done < "$BASHRC"
    echo
  else
    echo "=== $BASHRC: no managed block ==="
    echo
  fi

  # Check .replit [userenv.shared]
    local replit_file="${REPL_HOME:-$WORKSPACE}/.replit"
    if [[ "$REPLIT_MODE" == true && -f "$replit_file" ]] && grep -q '^\[userenv\.shared\]' "$replit_file"; then
      echo "=== $replit_file [userenv.shared] ==="
      awk '/^\[userenv\.shared\]/{s=1; print; next} /^\[/{s=0} s' "$replit_file"
      echo
    elif [[ "$REPLIT_MODE" == true ]]; then
      echo "=== $replit_file: no [userenv.shared] section ==="
      echo
    fi

  # Installed binaries
  echo "=== Installed binaries in $XDG_BIN_HOME ==="
  found=false
  local f
  for f in "$XDG_BIN_HOME"/*; do
    [[ -e "$f" && -x "$f" ]] || continue
    found=true
    local bin_name="$(basename "$f")"
    local owner="$(path_dir_owner "$XDG_BIN_HOME")"
    if [[ -n "$owner" ]]; then
      echo "  $bin_name (owned by: $owner)"
    else
      echo "  $bin_name"
    fi
  done
  $found || echo "  (none)"
  echo

  # Tool env vars registered this run (if any)
  echo "=== Tool env vars (current run registrations) ==="
  local var
  if [[ ${#_TOOL_ENV_VARS[@]} -eq 0 ]]; then
    echo "  (none registered this run)"
  else
    for var in "${_TOOL_ENV_VARS[@]}"; do
      local owner="$(env_var_owner "$var")"
      if [[ -n "$owner" ]]; then
        echo "  $var (owned by: $owner)"
      else
        echo "  $var"
      fi
    done
  fi
  echo

  # PATH dirs registered this run
  echo "=== PATH dirs (current run registrations) ==="
  local dir
  if [[ ${#_TOOL_PATH_DIRS[@]} -eq 0 ]]; then
    echo "  (none registered this run)"
  else
    for dir in "${_TOOL_PATH_DIRS[@]}"; do
      local owner="$(path_dir_owner "$dir")"
      if [[ -n "$owner" ]]; then
        echo "  $dir (owned by: $owner)"
      else
        echo "  $dir"
      fi
    done
  fi
}
