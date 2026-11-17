# shellcheck shell=bash
# Node.js installer (managed tarball). Sourced by setup.sh.
# Node.js (managed tarball) ───────────────────────────────────────────────────
install_node() {
  step "Node.js (managed tarball)"
  mkdir -p "$XDG_BIN_HOME" "$XDG_DATA_HOME"

  # wget is not on every box (the Ubuntu-based Replit container ships curl only)
  need_cmd curl
  # Platform/arch in nodejs.org naming — the sibling lanes in this file
  # (OpenCode, Claude, ORI) all map uname explicitly; this lane used to
  # hardcode linux-x64, so on macOS it staged an ELF binary that could
  # not load (caught by the probe below, and by the CI macOS leg).
  local os arch
  case "$(uname -s)" in
    Linux)  os="linux" ;;
    Darwin) os="darwin" ;;
    *)      die "Node: unsupported OS $(uname -s)" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)   arch="x64" ;;
    aarch64|arm64)  arch="arm64" ;;
    *)              die "Node: unsupported arch $(uname -m)" ;;
  esac
  local idx="https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/"
  local tar
  tar=$(curl -fsSL "$idx" | grep -oE "node-v[0-9]+\.[0-9]+\.[0-9]+-${os}-${arch}\.tar\.xz" | head -1)
  [[ -n "$tar" ]] || die "Could not resolve Node.js tarball from $idx"
  local url="$idx$tar"
  local tmp="$XDG_DATA_HOME/_node.tar.xz"

  echo "  Downloading $tar..."
  if command -v wget >/dev/null 2>&1; then
    wget -q --show-progress -O "$tmp" "$url" || die "Node.js download failed"
  else
    curl -fL --progress-bar -o "$tmp" "$url" || die "Node.js download failed"
  fi

  rm -rf "$NODE_DIR"
  mkdir -p "$NODE_DIR"
  tar -xJf "$tmp" -C "$XDG_DATA_HOME"
  local extracted="$XDG_DATA_HOME/$(tar -tf "$tmp" | head -1 | cut -d/ -f1)"
  { [[ -n "$extracted" ]] && [[ -d "$extracted" ]]; } || die "Node.js extraction produced no directory"
  cp -a "$extracted"/. "$NODE_DIR"/
  rm -rf "$tmp" "$extracted"

  symlink_bins "$NODE_DIR/bin" node npm npx
  # A failed $(node --version) inside an ok line does NOT trip set -e — on
  # this exact bug class it printed '✓ Node.js installed: ( )' with an empty
  # version while the binary could not load. Probe explicitly and die.
  local node_ver
  if ! node_ver="$("$NODE_DIR/bin/node" --version 2>&1)"; then
    die "node staged at $NODE_DIR but cannot load: $node_ver (ensure_libatomic output above? rerun: bash setup.sh --fix)"
  fi
  ok "Node.js installed: $NODE_DIR ($node_ver)"
  record_tool_env_vars NODE_DIR npm_config_prefix "${_TLS_ENV_VARS[@]}"
  record_tool_path_dirs "$NODE_DIR/bin" "$WORKSPACE/node_modules/.bin" "$XDG_BIN_HOME"
  wire_tool node NODE_DIR npm_config_prefix "${_TLS_ENV_VARS[@]}" -- "$NODE_DIR/bin" "$WORKSPACE/node_modules/.bin" "$XDG_BIN_HOME"
}

