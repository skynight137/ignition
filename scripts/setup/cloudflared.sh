# shellcheck shell=bash
# cloudflared installer (Cloudflare Tunnel client, pinned release). Sourced by setup.sh.
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

# cloudflared — Cloudflare's tunnel client, pinned release
# ($CLOUDFLARED_VERSION in the profile). Versionless asset names, and the
# release publishes no checksum asset (only the binary and the .deb/.rpm
# packages), so the size + SHA256 pins below — computed from the official
# downloads — are the verification; they move WITH CLOUDFLARED_VERSION.
cloudflared_asset_name() {
  local os=linux
  [[ "$(uname -s)" == Darwin ]] && os=darwin
  case "$(uname -m)" in
    x86_64|amd64)   echo "cloudflared-$os-amd64$([[ $os == darwin ]] && echo .tgz)" ;;
    aarch64|arm64)  echo "cloudflared-$os-arm64$([[ $os == darwin ]] && echo .tgz)" ;;
    *)              die "cloudflared: unsupported arch $(uname -m)" ;;
  esac
}

# Pinned size (bytes) + SHA256 of the official $CLOUDFLARED_VERSION asset.
cloudflared_asset_size() {
  case "$1" in
    cloudflared-linux-amd64)        echo "40283099" ;;
    cloudflared-linux-arm64)        echo "37668707" ;;
    cloudflared-darwin-amd64.tgz)   echo "21825349" ;;
    cloudflared-darwin-arm64.tgz)   echo "19890696" ;;
    *)              die "cloudflared: no size pin recorded for asset $1" ;;
  esac
}

cloudflared_asset_sha256() {
  case "$1" in
    cloudflared-linux-amd64)        echo "51f7c68b57ed7269164075d7e789efce5b59355982f06392deeb037d982a51fd" ;;
    cloudflared-linux-arm64)        echo "abe54a006acf9faf2d19ee9d953cb0d0804e92f59c5382a162e57b84d086f56f" ;;
    cloudflared-darwin-amd64.tgz)   echo "8a59d51120cebbe902f0a8d6e1b7a7fd4f9a5bb4dcb3e0f05872483e75e7db6b" ;;
    cloudflared-darwin-arm64.tgz)   echo "8c2f90277ef06a6080bb40b964d33f09f1188102f8798f2e344174b6cf41accf" ;;
    *)              die "cloudflared: no SHA256 pin recorded for asset $1" ;;
  esac
}

install_cloudflared() {
  step "cloudflared (Cloudflare Tunnel client, pinned $CLOUDFLARED_VERSION)"
  need_cmd curl
  mkdir -p "$XDG_BIN_HOME"

  local asset url tmp
  asset="$(cloudflared_asset_name)"
  url="$CLOUDFLARED_RELEASE_BASE/$CLOUDFLARED_VERSION/$asset"
  tmp="$XDG_DATA_HOME/_cloudflared.bin"

  echo "  Downloading $asset"
  curl -fsSL "$url" -o "$tmp" || die "cloudflared download failed: $url"
  verify_pinned_asset "$tmp" "$(cloudflared_asset_size "$asset")" "$(cloudflared_asset_sha256 "$asset")" "cloudflared ($asset)"
  if [[ "$asset" == *.tgz ]]; then
    # darwin assets ship as a tarball wrapping the bare binary
    local exdir="$XDG_DATA_HOME/_cloudflared-extract"
    rm -rf "$exdir"; mkdir -p "$exdir"
    tar -xzf "$tmp" -C "$exdir" || die "cloudflared archive extract failed"
    local inner
    inner="$(find "$exdir" -type f -name cloudflared -print -quit)"
    [[ -n "$inner" ]] || die "cloudflared archive is missing the 'cloudflared' binary"
    mv -f "$inner" "$tmp"; rm -rf "$exdir"
  fi
  chmod +x "$tmp"
  _bin_replace_note "$XDG_BIN_HOME/cloudflared"
  rm -f "$XDG_BIN_HOME/cloudflared"
  mv -f "$tmp" "$XDG_BIN_HOME/cloudflared"
  ok "cloudflared installed: $XDG_BIN_HOME/cloudflared ($("$XDG_BIN_HOME/cloudflared" --version 2>&1 | head -1))"
  ok "  quick tunnel (no account, prints a https://<rand>.trycloudflare.com URL):"
  ok "    cloudflared tunnel --url http://localhost:<port>"
  ok "  named tunnel: cloudflared tunnel run --token \"\$TOKEN\"  (see references/exposing-ports.md)"
  record_tool_path_dirs "$XDG_BIN_HOME"
  wire_tool cloudflared -- "$XDG_BIN_HOME"
}

