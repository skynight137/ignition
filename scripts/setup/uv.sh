# shellcheck shell=bash
# uv installer. Sourced by setup.sh.
# uv (no Python-specific dead code — uv IS the runtime manager) ──────────────
# Pinned release (UV_VERSION in the profile): the versioned GitHub
# tarball (astral-sh/uv) is downloaded directly and verified against
# the release's published .sha256 sidecar — no installer script, so
# the version that lands on the box is exactly the recorded one.

uv_asset_name() {
  local os arch libc
  case "$(uname -s)" in
    Linux)  os="linux" ;;
    Darwin) os="darwin" ;;
    *)      return 1 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)   arch="x86_64" ;;
    aarch64|arm64)  arch="aarch64" ;;
    *)              return 1 ;;
  esac
  if [[ "$os" == "darwin" ]]; then
    echo "uv-$arch-apple-darwin.tar.gz"
    return 0
  fi
  libc="gnu"
  if [[ -f /etc/alpine-release ]] \
     || { command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; }; then
    libc="musl"
  fi
  echo "uv-$arch-unknown-linux-$libc.tar.gz"
}

# Download + verify + stage the pinned uv into $XDG_BIN_HOME.
# Returns non-zero on any failure and never dies: install_uv turns a
# failure into a die; ensure_uv_bin turns it into a soft miss.
_uv_install_pinned() {
  command -v curl >/dev/null 2>&1 || return 1
  command -v tar >/dev/null 2>&1 || return 1
  local asset url tmp tmpdir sums sha dir
  asset="$(uv_asset_name)" || return 1
  [[ -n "$asset" ]] || return 1
  url="https://github.com/astral-sh/uv/releases/download/$UV_VERSION/$asset"
  tmp="$XDG_DATA_HOME/_uv.tar.gz"
  tmpdir="$XDG_DATA_HOME/_uv-extract"
  sums="$XDG_DATA_HOME/_uv.sha256"
  mkdir -p "$XDG_BIN_HOME" "$XDG_DATA_HOME" || return 1
  echo "  Downloading $asset (uv $UV_VERSION)"
  curl -fsSL "$url" -o "$tmp" || return 1
  sha=""
  if curl -fsSL "$url.sha256" -o "$sums" 2>/dev/null; then
    sha="$(awk 'NR==1{print $1}' "$sums")"
    rm -f "$sums"
  fi
  # verify_sha256 dies on a mismatch or a missing digest; run it in a
  # subshell so a bad download stays a soft failure here.
  ( verify_sha256 "$tmp" "$sha" "uv ($asset)" ) || { rm -f "$tmp"; return 1; }
  rm -rf "$tmpdir"
  mkdir -p "$tmpdir" || { rm -f "$tmp"; return 1; }
  tar -xzf "$tmp" -C "$tmpdir" || { rm -rf "$tmpdir" "$tmp"; return 1; }
  dir="$(find "$tmpdir" -maxdepth 1 -type d -name 'uv-*' -print -quit)"
  [[ -n "$dir" && -f "$dir/uv" && -f "$dir/uvx" ]] || { rm -rf "$tmpdir" "$tmp"; return 1; }
  # Fresh-install contract: replace any stale target before placing.
  rm -f "$XDG_BIN_HOME/uv" "$XDG_BIN_HOME/uvx"
  mv -f "$dir/uv" "$XDG_BIN_HOME/uv"
  mv -f "$dir/uvx" "$XDG_BIN_HOME/uvx"
  chmod +x "$XDG_BIN_HOME/uv" "$XDG_BIN_HOME/uvx"
  rm -rf "$tmpdir" "$tmp"
  return 0
}

install_uv() {
  step "uv (pinned $UV_VERSION)"
  need_cmd curl
  need_cmd tar
  _uv_install_pinned || die "uv install failed (pinned $UV_VERSION)"
  [[ -x "$XDG_BIN_HOME/uv" ]] || die "uv install did not produce $XDG_BIN_HOME/uv"
  ok "uv installed: $XDG_BIN_HOME/uv ($("$XDG_BIN_HOME/uv" --version 2>&1 | head -1))"
  record_tool_env_vars UV_PYTHON_DOWNLOADS UV_PYTHON_PREFERENCE PYTHONPATH
  record_tool_path_dirs "$XDG_BIN_HOME"
  wire_tool uv UV_PYTHON_DOWNLOADS UV_PYTHON_PREFERENCE PYTHONPATH -- "$XDG_BIN_HOME"
}

# Resolve a runnable uv into the variable named $1 — PATH first, then the
# lane's own install home — INSTALLING the pinned release (same
# _uv_install_pinned as install_uv) when neither has one. Unlike install_uv
# this never dies and never reinstalls over an existing binary: it exists for
# machinery that needs uv as a means to an end (the tomlkit provisioning in
# rc.sh) on boxes where the uv lane itself never ran. Returns 1 when uv
# cannot be obtained (no curl, no network, download/verify failure).
ensure_uv_bin() {
  local -n _uv_out="$1"
  if command -v uv &>/dev/null; then
    _uv_out="$(command -v uv)"
    return 0
  fi
  if [[ -x "$XDG_BIN_HOME/uv" ]]; then
    _uv_out="$XDG_BIN_HOME/uv"
    return 0
  fi
  command -v curl &>/dev/null || return 1
  step "uv not found — installing the pinned release (needed to provision the tomlkit python)"
  _uv_install_pinned || return 1
  [[ -x "$XDG_BIN_HOME/uv" ]] || return 1
  _uv_out="$XDG_BIN_HOME/uv"
  ok "uv installed: $_uv_out"
}
