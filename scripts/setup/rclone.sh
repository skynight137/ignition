# shellcheck shell=bash
# rclone installer (direct binary, pinned release). Sourced by setup.sh.
# ── Download / media tools (direct binaries) ────────────────────────────────
# rclone — pinned release (RCLONE_VERSION in the profile) on
# downloads.rclone.org, the canonical mirror of GitHub releases. The
# zip wraps the binary in a versioned dir (rclone-vX-linux-<arch>/);
# the version dir publishes SHA256SUMS, verified below.
rclone_zip_name() {
  local os=linux
  [[ "$(uname -s)" == Darwin ]] && os=osx
  case "$(uname -m)" in
    x86_64|amd64)   echo "rclone-v$RCLONE_VERSION-$os-amd64.zip" ;;
    aarch64|arm64)  echo "rclone-v$RCLONE_VERSION-$os-arm64.zip" ;;
    *)              die "rclone: unsupported arch $(uname -m)" ;;
  esac
}

install_rclone() {
  step "rclone (pinned $RCLONE_VERSION)"
  need_cmd curl
  need_cmd unzip
  mkdir -p "$XDG_BIN_HOME"

  local zip
  zip="$(rclone_zip_name)"
  local url="$RCLONE_DOWNLOAD_BASE/v$RCLONE_VERSION/$zip"
  local tmp="$XDG_DATA_HOME/_rclone.zip"
  local tmpdir="$XDG_DATA_HOME/_rclone-extract"

  echo "  Downloading $zip"
  curl -fsSL "$url" -o "$tmp" || die "rclone download failed: $url"

  # Verify against the version dir's SHA256SUMS (format "<sha>  <name>").
  local sums="$XDG_DATA_HOME/_rclone-sha256sums" sha=""
  if curl -fsSL "$RCLONE_DOWNLOAD_BASE/v$RCLONE_VERSION/SHA256SUMS" -o "$sums" 2>/dev/null; then
    sha="$(awk -v a="$zip" '$2 == a {print $1}' "$sums")"
    rm -f "$sums"
  fi
  verify_sha256 "$tmp" "$sha" "rclone ($zip)"

  rm -rf "$tmpdir"
  mkdir -p "$tmpdir"
  unzip -o -q "$tmp" -d "$tmpdir"

  local bin
  bin="$(find "$tmpdir" -type f -name rclone -print -quit)"
  [[ -n "$bin" ]] || die "rclone archive is missing the 'rclone' binary"
  rm -f "$XDG_BIN_HOME/rclone"
  mv -f "$bin" "$XDG_BIN_HOME/rclone"
  chmod +x "$XDG_BIN_HOME/rclone"
  rm -rf "$tmpdir" "$tmp"
  ok "rclone installed: $XDG_BIN_HOME/rclone ($("$XDG_BIN_HOME/rclone" --version 2>&1 | head -1))"
  record_tool_path_dirs "$XDG_BIN_HOME"
  wire_tool rclone -- "$XDG_BIN_HOME"
}

