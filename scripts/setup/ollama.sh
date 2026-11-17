# shellcheck shell=bash
# Ollama installer. Sourced by setup.sh.
# Ollama (LLM runtime) ───────────────────────────────────────────────────────
install_ollama() {
  step "Ollama (LLM runtime)"

  # The official Ollama installer needs zstd to decompress the release archive.
  # Replit: apt is blocked but zstd ships in the Nix store — surface it on PATH.
  # Muse: the box has apt (root) — install it; update first, stale lists fail.
  if ! command -v zstd >/dev/null; then
    if [[ "${REPLIT_MODE:-false}" == true ]]; then
      local zstd_bin
      zstd_bin="$(ls -d /nix/store/*zstd-*-bin/bin 2>/dev/null | head -1)"
      if [[ -n "$zstd_bin" ]]; then
        export PATH="$zstd_bin:$PATH"
      fi
    elif command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq 2>/dev/null || true
      apt-get install -y zstd 2>/dev/null || true
    fi
  fi
  command -v zstd >/dev/null || die "ollama needs zstd (muse: apt-get install -y zstd; repl: Nix store)"

  # The official Ollama installer hardcodes /usr/local/bin and insists on sudo.
  # Patch it to honor OLLAMA_INSTALL_DIR (payload) and OLLAMA_BIN_DIR (symlink).
  need_cmd curl
  mkdir -p "$XDG_DATA_HOME" "$XDG_BIN_HOME"
  local installer="$XDG_DATA_HOME/_ollama-install.sh"
  curl -fsSL https://ollama.com/install.sh -o "$installer" \
    || die "could not download Ollama installer"
  chmod +x "$installer"

  sed -i \
    -e 's/SUDO="sudo"/SUDO=""/' \
    -e 's/ -o0 -g0//g' \
    -e 's/^    configure_systemd$/    : # user-local install: no systemd service, no system user/' \
    -e 's#^OLLAMA_INSTALL_DIR=$(dirname${BINDIR})#:#' \
    -e "s#for BINDIR in /usr/local/bin /usr/bin /bin; do#OLLAMA_INSTALL_DIR=\"\${OLLAMA_INSTALL_DIR:-/usr/local}\"; OLLAMA_BIN_DIR=\"\${OLLAMA_BIN_DIR:-\$OLLAMA_INSTALL_DIR/bin}\"; for BINDIR in \"\$OLLAMA_BIN_DIR\"; do#" \
    "$installer"

  if grep -q 'SUDO="sudo"' "$installer"; then
    rm -f "$installer"
    die "Ollama installer patch failed (sudo still present) — upstream changed. Report: https://github.com/ollama/ollama/releases"
  fi

  # The upstream script calls configure_systemd whenever a systemctl
  # binary exists; that function creates a system user and a systemd
  # unit, which a user-local install must never do (it hard-fails
  # without root — caught by the CI tool-setup leg on a stock Ubuntu
  # runner, where systemctl exists but there is no systemd running).
  if grep -qE '^    configure_systemd$' "$installer"; then
    rm -f "$installer"
    die "Ollama installer patch failed (configure_systemd call still present) — upstream changed. Report: https://github.com/ollama/ollama/releases"
  fi

  # Fresh-install contract: replace the payload, KEEP downloaded models
  # ($OLLAMA_MODELS) — they are user data, not install artifacts.
  if [[ -d "$OLLAMA_MODELS" ]]; then
    local models_backup="$XDG_DATA_HOME/_ollama-models-backup"
    mv "$OLLAMA_MODELS" "$models_backup"
  fi
  rm -rf "$OLLAMA_INSTALL_DIR"
  mkdir -p "$XDG_BIN_HOME"
  if [[ -d "${models_backup:-}" ]]; then
    mkdir -p "$OLLAMA_INSTALL_DIR"
    mv "$models_backup" "$OLLAMA_MODELS"
  fi

  OLLAMA_INSTALL_DIR="$OLLAMA_INSTALL_DIR" OLLAMA_BIN_DIR="$OLLAMA_INSTALL_DIR/bin" bash "$installer" \
    || die "ollama installer failed"
  rm -f "$installer"

  if [[ ! -x "$OLLAMA_INSTALL_DIR/bin/ollama" && -x "$OLLAMA_INSTALL_DIR/ollama" ]]; then
    mkdir -p "$OLLAMA_INSTALL_DIR/bin"
    ln -sfn "$OLLAMA_INSTALL_DIR/ollama" "$OLLAMA_INSTALL_DIR/bin/ollama"
  fi

  [[ -x "$OLLAMA_INSTALL_DIR/bin/ollama" ]] \
    || die "ollama binary not found at $OLLAMA_INSTALL_DIR/bin/ollama"
  symlink_bins "$OLLAMA_INSTALL_DIR/bin" ollama
  ok "ollama installed: $OLLAMA_INSTALL_DIR/bin/ollama"
  record_tool_env_vars OLLAMA_INSTALL_DIR OLLAMA_MODELS
  record_tool_path_dirs "$XDG_BIN_HOME"
  wire_tool ollama OLLAMA_INSTALL_DIR OLLAMA_MODELS -- "$XDG_BIN_HOME"
}

