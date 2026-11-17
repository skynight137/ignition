# shellcheck shell=bash
# Claude installer. Sourced by setup.sh.
# Claude Code (AI coding tool) — smart install ─────────────────────────────
# Claude Code is a single static binary served from downloads.claude.ai with a
# per-platform SHA256 manifest.json. No installer script, no $HOME hack,
# no .local/bin move — download, verify, place directly into XDG_BIN_HOME.
claude_platform() {
  local os arch libc
  case "$(uname -s)" in
    Linux)  os="linux" ;;
    Darwin) os="darwin" ;;
    *)      die "Claude: unsupported OS $(uname -s)" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)   arch="x64" ;;
    aarch64|arm64)  arch="arm64" ;;
    *)              die "Claude: unsupported arch $(uname -m)" ;;
  esac
  libc="gnu"
  if [[ -f /lib/libc.musl-x86_64.so.1 || -f /lib/libc.musl-aarch64.so.1 ]] \
     || { command -v ldd >/dev/null 2>&1 && ldd /bin/ls 2>&1 | grep -qi musl; }; then
    libc="musl"
  fi
  case "$os" in
    darwin) echo "darwin-$arch" ;;
    linux)  [[ "$libc" == "musl" ]] && echo "linux-$arch-musl" || echo "linux-$arch" ;;
  esac
}

# Extract the platform's checksum from Claude's manifest.json.
# Prefers python3 (robust JSON), falls back to pure-bash regex (no jq).
# Returns the SHA256 hex digest, or empty string if not found.
claude_checksum() {
  local platform="$1" manifest="$2"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
print(d.get('platforms',{}).get('$platform',{}).get('checksum',''))" 2>/dev/null <<< "$manifest" && return 0
  fi
  # bash fallback: '... "linux-x64": ... "checksum": "<hex>" ...'
  if [[ "$manifest" =~ \"$platform\"[^}]*\"checksum\":[[:space:]]*\"([a-f0-9]{64})\" ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  echo ""
}

install_claude() {
  step "Claude Code (direct SHA256-verified binary, pinned $CLAUDE_VERSION)"
  need_cmd curl
  mkdir -p "$XDG_BIN_HOME"

  local platform base version manifest
  platform="$(claude_platform)"
  base="$CLAUDE_RELEASE_BASE"
  version="$CLAUDE_VERSION"

  local tmp="$XDG_DATA_HOME/_claude.bin"
  local sha=""
  echo "  Resolving Claude Code $version ($platform)"
  manifest="$(curl -fsSL "$base/$version/manifest.json" 2>/dev/null || true)"
  if [[ -n "$manifest" ]]; then
    sha="$(claude_checksum "$platform" "$manifest")"
  fi

  echo "  Downloading claude-$version-$platform"
  curl -fsSL "$base/$version/$platform/claude" -o "$tmp" \
    || { rm -f "$tmp"; die "Claude download failed for $platform"; }

  verify_sha256 "$tmp" "$sha" "claude ($platform)"

  # Fresh-install contract: remove any stale target before installing.
  rm -f "$XDG_BIN_HOME/claude"
  mv -f "$tmp" "$XDG_BIN_HOME/claude"
  chmod +x "$XDG_BIN_HOME/claude"
  ok "claude installed: $XDG_BIN_HOME/claude ($version)"
  record_tool_env_vars CLAUDE_CONFIG_DIR
  record_tool_path_dirs "$XDG_BIN_HOME"
  wire_tool claude CLAUDE_CONFIG_DIR -- "$XDG_BIN_HOME"
}

