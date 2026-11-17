# shellcheck shell=bash
# Ollama installer (pinned release tarball). Sourced by setup.sh.
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

  # Pinned release: versioned GitHub tarball + published sha256sum.txt.
  # No installer script — the old ollama.com/install.sh resolved latest
  # internally, so the version on the box floated. OLLAMA_VERSION lives
  # in scripts/setup/versions.sh (single source of truth).
  need_cmd curl
  need_cmd sha256sum
  mkdir -p "$XDG_DATA_HOME" "$XDG_BIN_HOME"
  local base="${OLLAMA_RELEASE_BASE:-https://github.com/ollama/ollama/releases/download}"
  local ver="${OLLAMA_VERSION:?OLLAMA_VERSION is not set (versions.sh)}"
  local tarball="$XDG_DATA_HOME/ollama-linux-amd64.tar.zst"
  local sums="$XDG_DATA_HOME/_ollama-sha256sum.txt"
  curl -fsSL "$base/v$ver/ollama-linux-amd64.tar.zst" -o "$tarball" \
    || die "could not download Ollama $ver tarball"
  curl -fsSL "$base/v$ver/sha256sum.txt" -o "$sums" \
    || die "could not download Ollama $ver checksums"
  ( cd "$XDG_DATA_HOME" && grep -F 'ollama-linux-amd64.tar.zst' "$sums" | sha256sum -c - ) \
    || die "Ollama $ver tarball checksum mismatch"

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

  # Extract the whole tarball into the payload (it carries lib/ runners
  # next to the binary — copying the binary alone would break model
  # serving). zstd is already verified above. The payload dir was wiped
  # above, so create it here (the old installer used to create it).
  mkdir -p "$OLLAMA_INSTALL_DIR"
  zstd -dc "$tarball" | tar -xf - -C "$OLLAMA_INSTALL_DIR" \
    || die "ollama $ver tarball extract failed"
  rm -f "$tarball" "$sums"

  # Release tarballs vary in layout (bin/ollama vs top-level ollama);
  # make sure the canonical path exists either way.
  if [[ ! -x "$OLLAMA_INSTALL_DIR/bin/ollama" ]]; then
    local found_bin
    found_bin="$(find "$OLLAMA_INSTALL_DIR" -name ollama -type f -perm -u+x 2>/dev/null | head -1)"
    [[ -n "$found_bin" ]] || die "ollama binary not found in $ver tarball"
    mkdir -p "$OLLAMA_INSTALL_DIR/bin"
    ln -sfn "$found_bin" "$OLLAMA_INSTALL_DIR/bin/ollama"
  fi

  [[ -x "$OLLAMA_INSTALL_DIR/bin/ollama" ]] \
    || die "ollama binary not found at $OLLAMA_INSTALL_DIR/bin/ollama"
  symlink_bins "$OLLAMA_INSTALL_DIR/bin" ollama
  ok "ollama installed: $OLLAMA_INSTALL_DIR/bin/ollama"
  record_tool_env_vars OLLAMA_INSTALL_DIR OLLAMA_MODELS
  record_tool_path_dirs "$XDG_BIN_HOME"
  wire_tool ollama OLLAMA_INSTALL_DIR OLLAMA_MODELS -- "$XDG_BIN_HOME"
}

