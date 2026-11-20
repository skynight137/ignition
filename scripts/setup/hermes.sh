# shellcheck shell=bash
# Hermes installer. Sourced by setup.sh.
# Hermes Agent (AI agent assistant) ──────────────────────────────────────────
# Fresh-install contract: a re-run REPLACES the existing install —
# HERMES_HOME (venv, config, state) and the launcher binaries are removed
# first so no stale files survive. To keep existing Hermes data
# (sessions/memory/config), back up memories/, config.yaml, state.db etc.
# before re-running.
# Fallback for when the upstream installer's own uv sync dies on
# parallel CONNECTs (env not propagated to its uv subprocess — seen
# 2026-11-19 with `hermes pm repair` ignoring exported
# UV_CONCURRENT_DOWNLOADS). Warms the shared uv cache with a direct
# serial sync of the recorded feature set, then lets pm repair commit
# the environment. Proven 2026-11-19: serial sync exit 0, repair
# exit 0, `hermes --version` works. Runs only when the checkout and
# the bundled uv exist; otherwise returns 1.
hermes_serial_repair() {
  local checkout="$HERMES_HOME/hermes-agent"
  local uv_bin
  uv_bin=$(ls -d "$HERMES_HOME"/tools/uv-*/uv 2>/dev/null | head -n 1)
  [[ -d "$checkout" && -x "$uv_bin" ]] || return 1
  ( cd "$checkout" && \
    UV_CACHE_DIR="$HERMES_HOME/cache/uv" UV_HTTP_TIMEOUT=120 \
    UV_CONCURRENT_DOWNLOADS=1 "$uv_bin" sync \
      --extra all --extra doc-extract --extra vision --extra web ) \
    || return 1
  "$checkout/.hermes/bin/hermes" pm repair || return 1
  "$checkout/.hermes/bin/hermes" --version >/dev/null 2>&1
}

install_hermes() {
  step "Hermes Agent (AI agent assistant)"
  need_cmd curl
  rm -rf "$HERMES_HOME"
  rm -f "$XDG_BIN_HOME/hermes" "$XDG_BIN_HOME/hermes-agent" "$XDG_BIN_HOME/hermes-acp"
  mkdir -p "$HERMES_HOME" "$XDG_BIN_HOME"

  local installer="$XDG_DATA_HOME/_hermes-install.sh"
  curl -fsSL "$HERMES_INSTALL_URL" -o "$installer" \
    || die "could not download Hermes installer: $HERMES_INSTALL_URL"
  chmod +x "$installer"

  # The installer places the `hermes` launcher in `$HOME/.local/bin` and only
  # appends that dir to `$HOME/.bashrc` when it is NOT on PATH. We
  # exploit that guard so no real rc is touched:
  #   replit mode: run with HOME=$WORKSPACE (the read-only/ephemeral Replit
  #     $HOME would fail the write anyway); $WORKSPACE/.local/bin == XDG_BIN_HOME
  #   default: run with the real $HOME — $HOME/.local/bin == XDG_BIN_HOME, the
  #     script's exported PATH contains it, and the
  #     installer's PATH check skips the .bashrc append.
  # HERMES_HOME governs the data dir (INSTALL_DIR=$HERMES_HOME/hermes-agent).
  # Skip the bundled Playwright Chromium; we hand Hermes the Replit Chromium.
  local chrome="${REPLIT_PLAYWRIGHT_CHROMIUM_EXECUTABLE:-}"
  if [[ -n "$chrome" && -x "$chrome" ]]; then
    export AGENT_BROWSER_EXECUTABLE_PATH="$chrome"
    echo "  reusing Replit Chromium for Hermes browser tools: $chrome"
  fi

  local hermes_home="$WORKSPACE"
  if [[ "$REPLIT_MODE" != true ]]; then
    hermes_home="$HOME"
  fi
  # muse-hop egress stalls on parallel uv downloads (uv default ~50
  # concurrent CONNECTs time out; proven 2026-11-19: serial uv sync
  # installed 66 pkgs in 122s where parallel died repeatedly ~45s).
  # The serial knobs live in env.sh (written by the uv lane on muse,
  # so every `source env.sh && uv ...` gets them). This prefix is
  # belt-and-braces for the installer invocation itself: the setup
  # process may not have sourced env.sh yet. Correct order on a Muse
  # VM: toolskit uv first, then Hermes (-ha implies -u).
  local uv_serial=()
  if [[ "$REPLIT_MODE" != true ]]; then
    uv_serial=(UV_CONCURRENT_DOWNLOADS=1 UV_HTTP_TIMEOUT=120)
  fi
  if ! env "${uv_serial[@]}" HERMES_HOME="$HERMES_HOME" HOME="$hermes_home" \
    bash "$installer" --skip-setup --skip-browser --skip-computer-use; then
    echo "  installer failed — trying the proven serial repair (uv sync + pm repair)"
    hermes_serial_repair || die "Hermes installer failed"
  fi
  rm -f "$installer"

  # Hermes publishes its own convenience forwarders (`hermes`, `hermes-acp`,
  # `hermes-agent`) into $HOME/.local/bin via _launchers.expose_cli; each
  # forwards to the durable launcher under $HERMES_HOME. Leave them alone:
  # deleting them is futile (Hermes republishes on every install/update) and
  # breaks `hermes-agent`, which has no .hermes/bin entry of its own.
  local real_bin="$HERMES_HOME/hermes-agent/.hermes/bin/hermes"
  [[ -x "$real_bin" ]] || warn "expected Hermes launcher at $real_bin — check the install"
  ok "HERMES_HOME=$HERMES_HOME launcher=$real_bin browser=$([ -n "$chrome" ] && echo 'replit chromium' || echo 'none')"
  record_tool_env_vars HERMES_HOME HERMES_MANAGED_DIR
  record_tool_path_dirs "$XDG_BIN_HOME" "$HERMES_LAUNCHER_DIR"
  wire_tool hermes HERMES_HOME HERMES_MANAGED_DIR -- "$XDG_BIN_HOME" "$HERMES_LAUNCHER_DIR"
}

