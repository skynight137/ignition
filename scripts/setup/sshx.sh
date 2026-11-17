# shellcheck shell=bash
# sshx installer (collaborative web terminal, pinned release). Sourced by setup.sh.
# setup.sh owns this name in $XDG_BIN_HOME. An existing SYMLINK at the
# target is reported before it is replaced (a symlink is the fingerprint
# of a hand-rolled install); a plain file is replaced quietly.
# Report a foreign binary we are about to replace. Only a symlink is worth
# announcing, because only a symlink proves the path came from elsewhere.
# (Shared with the sibling remote-access files cloudflared.sh / tailscale.sh /
# sshx.sh — keep the three copies in sync.)
_bin_replace_note() {
  local p="$1"
  [[ -L "$p" ]] || return 0
  warn "replacing the existing symlink $p -> $(readlink "$p" 2>/dev/null) (left by an older manual install)"
}

# sshx — collaborative web terminal. Its GitHub releases carry NO assets, so the
# versionless S3 tarball (what sshx.io/get pulls) is the only artifact; no
# checksum is published. The archive holds a single `sshx` binary.
sshx_asset_name() {
  case "$(uname -m)" in
    x86_64|amd64)   echo "sshx-x86_64-unknown-linux-musl.tar.gz" ;;
    aarch64|arm64)  echo "sshx-aarch64-unknown-linux-musl.tar.gz" ;;
    *)              die "sshx: unsupported arch $(uname -m)" ;;
  esac
}

install_sshx() {
  step "sshx (collaborative web terminal)"
  need_cmd curl
  need_cmd tar
  mkdir -p "$XDG_BIN_HOME"

  local asset url tmp tmpdir bin
  asset="$(sshx_asset_name)"
  url="$SSHX_DOWNLOAD_BASE/$asset"
  tmp="$XDG_DATA_HOME/_sshx.tar.gz"
  tmpdir="$XDG_DATA_HOME/_sshx-extract"

  echo "  Downloading $asset"
  curl -fsSL "$url" -o "$tmp" || die "sshx download failed: $url"

  rm -rf "$tmpdir"
  mkdir -p "$tmpdir"
  tar -xzf "$tmp" -C "$tmpdir"
  # Layout-agnostic: the archive may or may not wrap the binary in a dir.
  bin="$(find "$tmpdir" -type f -name sshx -print -quit)"
  [[ -n "$bin" ]] || die "sshx archive is missing the 'sshx' binary"
  _bin_replace_note "$XDG_BIN_HOME/sshx"
  rm -f "$XDG_BIN_HOME/sshx"
  mv -f "$bin" "$XDG_BIN_HOME/sshx"
  chmod +x "$XDG_BIN_HOME/sshx"
  rm -rf "$tmpdir" "$tmp"
  ok "sshx installed: $XDG_BIN_HOME/sshx ($("$XDG_BIN_HOME/sshx" --version 2>&1 | head -1))"
  ok "  share a shell: sshx   (prints a web URL; nothing listens locally)"
  record_tool_path_dirs "$XDG_BIN_HOME"
  wire_tool sshx -- "$XDG_BIN_HOME"
}

