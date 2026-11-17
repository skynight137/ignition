# shellcheck shell=bash
# ORI installer. Sourced by setup.sh.
# ORI (AI coding tool) — smart install ─────────────────────────────────────
# ORI is a single static binary on GitHub releases with a SHA256SUMS file for
# verification. No installer script, no symlink — download, verify, place the
# binary directly into XDG_BIN_HOME (already on PATH).
ori_asset_name() {
  local os arch libc
  case "$(uname -s)" in
    Linux)  os="linux" ;;
    Darwin) os="darwin" ;;
    *)      die "ORI: unsupported OS $(uname -s)" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)   arch="x64" ;;
    aarch64|arm64)  arch="arm64" ;;
    *)              die "ORI: unsupported arch $(uname -m)" ;;
  esac
  libc="gnu"
  if grep -qi musl /etc/alpine-release 2>/dev/null \
     || { command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; }; then
    libc="musl"
  fi
  if [[ "$os" == "darwin" ]]; then
    echo "ori-darwin-$arch"
  elif [[ "$os" == "linux" && "$libc" == "musl" ]]; then
    echo "ori-linux-$arch-musl"
  else
    echo "ori-linux-$arch"
  fi
}

install_ori() {
  step "ORI (direct GitHub release, pinned $ORI_VERSION)"
  need_cmd curl
  mkdir -p "$XDG_BIN_HOME"

  local asset url checksums_url
  asset="$(ori_asset_name)"
  url="$ORI_RELEASE_BASE/$ORI_VERSION/$asset"
  checksums_url="$ORI_RELEASE_BASE/$ORI_VERSION/SHA256SUMS"
  local tmp="$XDG_DATA_HOME/_ori.bin"
  local sha=""

  echo "  Downloading $asset"
  curl -fsSL "$url" -o "$tmp" || die "ORI download failed: $url"

  # Fetch the matching checksum for this asset from SHA256SUMS.
  # Format per line: "<sha256>  <asset-name>" (two spaces).
  local sums="$XDG_DATA_HOME/_ori-sha256sums"
  if curl -fsSL "$checksums_url" -o "$sums" 2>/dev/null; then
    sha="$(awk -v a="$asset" '$2 == a {print $1}' "$sums")"
    rm -f "$sums"
  fi

  verify_sha256 "$tmp" "$sha" "ori ($asset)"

  # Fresh-install contract: remove any stale target before installing.
  rm -f "$XDG_BIN_HOME/ori"
  mv -f "$tmp" "$XDG_BIN_HOME/ori"
  chmod +x "$XDG_BIN_HOME/ori"
  ok "ori installed: $XDG_BIN_HOME/ori ($("$XDG_BIN_HOME/ori" --version 2>&1 | head -1))"
  record_tool_env_vars ORI_CONFIG_DIR
  record_tool_path_dirs "$XDG_BIN_HOME"
  wire_tool ori ORI_CONFIG_DIR -- "$XDG_BIN_HOME"
}

