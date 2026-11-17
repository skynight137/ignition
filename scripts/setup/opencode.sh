# shellcheck shell=bash
# OpenCode installer. Sourced by setup.sh.
# ── OpenCode (direct GitHub release — smart installer, no curl|bash) ───────────
# The official installer hardcodes INSTALL_DIR=$HOME/.opencode/bin and just
# downloads opencode-$os-$arch.tar.gz from GitHub releases. We bypass it:
# resolve the asset name ourselves, download the tarball, extract the single
# binary to XDG_DATA_HOME/opencode/bin, symlink into XDG_BIN_HOME.
opencode_asset_name() {
  local os arch combo target
  case "$(uname -s)" in
    Linux)  os="linux" ;;
    Darwin) os="darwin" ;;
    *)      die "OpenCode: unsupported OS $(uname -s)" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)   arch="x64" ;;
    aarch64|arm64)  arch="arm64" ;;
    *)              die "OpenCode: unsupported arch $(uname -m)" ;;
  esac
  combo="$os-$arch"
  target="$combo"
  # musl detection (Alpine / ldd reports musl)
  local is_musl=false
  if [[ "$os" == "linux" ]]; then
    if [[ -f /etc/alpine-release ]] || { command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; }; then
      is_musl=true
    fi
  fi
  # baseline (x64 without AVX2)
  local needs_baseline=false
  if [[ "$target" == "linux-x64" ]] && ! grep -qwi avx2 /proc/cpuinfo 2>/dev/null; then
    needs_baseline=true
  fi
  $needs_baseline && target="$target-baseline"
  $is_musl && target="$target-musl"
  echo "opencode-$target.tar.gz"
}

# Pinned size (bytes) + SHA256 of the official $OPENCODE_VERSION asset,
# keyed by asset name (the release publishes no checksum asset). They
# move WITH OPENCODE_VERSION (profile): bump the version without
# refreshing them and the install dies on the size check, loudly, by
# design. Linux assets only: upstream ships the darwin builds as .zip
# while opencode_asset_name emits .tar.gz — a pre-existing gap with no
# CI leg; a darwin download dies at the 404 before ever reaching here.
opencode_asset_size() {
  case "$1" in
    opencode-linux-x64.tar.gz)                echo "79651896" ;;
    opencode-linux-x64-baseline.tar.gz)       echo "79651821" ;;
    opencode-linux-x64-musl.tar.gz)           echo "79682863" ;;
    opencode-linux-x64-baseline-musl.tar.gz)  echo "79682889" ;;
    opencode-linux-arm64.tar.gz)              echo "78513091" ;;
    opencode-linux-arm64-musl.tar.gz)         echo "78255927" ;;
    *)              die "OpenCode: no size pin recorded for asset $1" ;;
  esac
}

opencode_asset_sha256() {
  case "$1" in
    opencode-linux-x64.tar.gz)                echo "588310a336fa3b9df36b3f0225b26f679d453efaad0cf3d66c3651ef3ec1647a" ;;
    opencode-linux-x64-baseline.tar.gz)       echo "17c200fd4b2289954cc01552559f9b6d03ec157b2ddfb5eb54144f491656333d" ;;
    opencode-linux-x64-musl.tar.gz)           echo "e8d5be23bf8f3f69bc3206f3311215c049329cd6afa7c06d733987cc2d33b568" ;;
    opencode-linux-x64-baseline-musl.tar.gz)  echo "e796ccff81070b527b2aea144741928e56bdbc6650cd90fb5564d5c114f0e08b" ;;
    opencode-linux-arm64.tar.gz)              echo "fae5be262d693b7c5e562856cc473e59e741772936db0c0600ac0d5ed5bd088b" ;;
    opencode-linux-arm64-musl.tar.gz)         echo "3522eccafd30d84a2d770b72a56d4877c576b9072b36a5a9ea0fa30ed82b896e" ;;
    *)              die "OpenCode: no SHA256 pin recorded for asset $1" ;;
  esac
}

install_opencode() {
  step "OpenCode (direct GitHub release, pinned $OPENCODE_VERSION)"
  need_cmd curl
  need_cmd tar
  mkdir -p "$XDG_BIN_HOME"

  local asset
  asset="$(opencode_asset_name)"
  local url="https://github.com/$OPENCODE_REPO/releases/download/v$OPENCODE_VERSION/$asset"
  local tmp="$XDG_DATA_HOME/_opencode.tar.gz"
  local tmpdir="$XDG_DATA_HOME/_opencode-extract"

  echo "  Downloading $asset"
  curl -fsSL "$url" -o "$tmp" || die "OpenCode download failed: $url"
  verify_pinned_asset "$tmp" "$(opencode_asset_size "$asset")" "$(opencode_asset_sha256 "$asset")" "opencode ($asset)"

  rm -rf "$tmpdir"
  mkdir -p "$tmpdir"
  tar -xzf "$tmp" -C "$tmpdir"

  # The tarball holds a single 'opencode' binary — drop it straight into
  # XDG_BIN_HOME (already on PATH). No install dir, no symlink needed.
  [[ -f "$tmpdir/opencode" ]] || die "OpenCode archive is missing the 'opencode' binary"
  # Fresh-install contract: remove any stale target before installing.
  rm -f "$XDG_BIN_HOME/opencode"
  mv -f "$tmpdir/opencode" "$XDG_BIN_HOME/opencode"
  chmod +x "$XDG_BIN_HOME/opencode"
  rm -rf "$tmpdir" "$tmp"
  ok "opencode installed: $XDG_BIN_HOME/opencode ($("$XDG_BIN_HOME/opencode" --version 2>&1 | head -1))"
  record_tool_env_vars OPENCODE_CONFIG_DIR
  record_tool_path_dirs "$XDG_BIN_HOME"
  wire_tool opencode OPENCODE_CONFIG_DIR -- "$XDG_BIN_HOME"
}

