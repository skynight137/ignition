# shellcheck shell=bash
# Hermes installer. Sourced by setup.sh.
# Hermes Agent (AI agent assistant) ──────────────────────────────────────────
# Fresh-install contract: a re-run REPLACES the existing install —
# HERMES_HOME (venv, config, state) and the launcher binaries are removed
# first so no stale files survive. To keep existing Hermes data
# (sessions/memory/config), back up memories/, config.yaml, state.db etc.
# before re-running.
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
  HERMES_HOME="$HERMES_HOME" HOME="$hermes_home" bash "$installer" \
    --skip-setup --skip-browser --skip-computer-use \
    || die "Hermes installer failed"
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

