# shellcheck shell=bash
# rclone / qBittorrent-nox / aria2c / FFmpeg installers. Sourced by setup.sh.
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

# qBittorrent-nox — userdocs/qbittorrent-nox-static ships ONE static binary
# per arch (ARCH-qbittorrent-nox) under the tag release-$QBT_VERSION. The
# release publishes NO checksum asset, so the size + SHA256 pins below —
# computed from the official downloads — are the verification; they move
# WITH QBT_VERSION (profile): bump the version without refreshing them
# and the install dies on the size check, loudly, by design.
qbt_asset_name() {
  case "$(uname -m)" in
    x86_64|amd64)   echo "x86_64-qbittorrent-nox" ;;
    aarch64|arm64)  echo "aarch64-qbittorrent-nox" ;;
    *)              die "qBittorrent-nox: unsupported arch $(uname -m)" ;;
  esac
}

# Pinned size (bytes) + SHA256 of the official $QBT_VERSION asset.
qbt_asset_size() {
  case "$(uname -m)" in
    x86_64|amd64)   echo "72455104" ;;
    aarch64|arm64)  echo "69713864" ;;
    *)              die "qBittorrent-nox: unsupported arch $(uname -m)" ;;
  esac
}
qbt_asset_sha256() {
  case "$(uname -m)" in
    x86_64|amd64)   echo "563e695a2b830e62e627e1ae403bcfcc494e444d5cabb5ecc1e09907353d8ed5" ;;
    aarch64|arm64)  echo "ac1e57089795270489491320c5fff0ceaed8e8910cf3abb6be597879408eb033" ;;
    *)              die "qBittorrent-nox: unsupported arch $(uname -m)" ;;
  esac
}

install_qbt() {
  step "qBittorrent-nox (static binary, pinned $QBT_VERSION)"
  need_cmd curl
  mkdir -p "$XDG_BIN_HOME"

  local asset
  asset="$(qbt_asset_name)"
  local url="$QBT_RELEASE_BASE/release-$QBT_VERSION/$asset"
  local tmp="$XDG_DATA_HOME/_qbittorrent-nox.bin"

  echo "  Downloading $asset"
  curl -fsSL "$url" -o "$tmp" || die "qBittorrent-nox download failed: $url"
  verify_pinned_asset "$tmp" "$(qbt_asset_size)" "$(qbt_asset_sha256)" "qbittorrent-nox ($asset)"
  chmod +x "$tmp"
  rm -f "$XDG_BIN_HOME/qbittorrent-nox"
  mv -f "$tmp" "$XDG_BIN_HOME/qbittorrent-nox"
  ok "qbittorrent-nox installed: $XDG_BIN_HOME/qbittorrent-nox ($("$XDG_BIN_HOME/qbittorrent-nox" --version 2>&1 | head -1))"
  record_tool_path_dirs "$XDG_BIN_HOME"
  wire_tool qbt -- "$XDG_BIN_HOME"
}

# aria2c — github.com/aria2/aria2 releases ship SOURCE only (no Linux binary);
# abcfy2/aria2-static-build repackages them as static musl zips:
# aria2-<arch>-linux-musl_static.zip under the tag $ARIA2_VERSION; the zip
# holds a single top-level 'aria2c' binary. No checksum asset upstream, so
# the size + SHA256 pins below (computed from the official downloads, moved
# with ARIA2_VERSION) are the verification.
aria2_zip_name() {
  case "$(uname -m)" in
    x86_64|amd64)   echo "aria2-x86_64-linux-musl_static.zip" ;;
    aarch64|arm64)  echo "aria2-aarch64-linux-musl_static.zip" ;;
    *)              die "aria2c: unsupported arch $(uname -m)" ;;
  esac
}

# Pinned size (bytes) + SHA256 of the official $ARIA2_VERSION asset.
aria2_asset_size() {
  case "$(uname -m)" in
    x86_64|amd64)   echo "5407608" ;;
    aarch64|arm64)  echo "5798481" ;;
    *)              die "aria2c: unsupported arch $(uname -m)" ;;
  esac
}
aria2_asset_sha256() {
  case "$(uname -m)" in
    x86_64|amd64)   echo "e0a09b12ef67f35f8a8e4fdddbec851d235b7c31da549d0578bff459032b499a" ;;
    aarch64|arm64)  echo "0c681a89a40e0f82d1f5137608e86257eb0af201459c002941ea098f2b8c26b6" ;;
    *)              die "aria2c: unsupported arch $(uname -m)" ;;
  esac
}

install_aria2() {
  step "aria2c (direct static binary, pinned $ARIA2_VERSION)"
  need_cmd curl
  need_cmd unzip
  mkdir -p "$XDG_BIN_HOME"

  local zip
  zip="$(aria2_zip_name)"
  local url="$ARIA2_RELEASE_BASE/$ARIA2_VERSION/$zip"
  local tmp="$XDG_DATA_HOME/_aria2.zip"
  local tmpdir="$XDG_DATA_HOME/_aria2-extract"

  echo "  Downloading $zip"
  curl -fsSL "$url" -o "$tmp" || die "aria2c download failed: $url"
  verify_pinned_asset "$tmp" "$(aria2_asset_size)" "$(aria2_asset_sha256)" "aria2c ($zip)"

  rm -rf "$tmpdir"
  mkdir -p "$tmpdir"
  unzip -o -q "$tmp" -d "$tmpdir"
  [[ -f "$tmpdir/aria2c" ]] || die "aria2 archive is missing the 'aria2c' binary"
  rm -f "$XDG_BIN_HOME/aria2c"
  mv -f "$tmpdir/aria2c" "$XDG_BIN_HOME/aria2c"
  chmod +x "$XDG_BIN_HOME/aria2c"
  rm -rf "$tmpdir" "$tmp"
  ok "aria2c installed: $XDG_BIN_HOME/aria2c ($("$XDG_BIN_HOME/aria2c" --version 2>&1 | head -1))"
  record_tool_path_dirs "$XDG_BIN_HOME"
  wire_tool aria2 -- "$XDG_BIN_HOME"
}

# FFmpeg — BtbN static GPL build (newer than the Replit Nix-built 6.1.2).
# linux64/linuxarm64 GPL tarballs bundle ffmpeg/ffprobe/ffplay with no shared
# -lib deps. Pinned to one dated autobuild release ($FFMPEG_RELEASE_TAG):
# its assets are named by the exact master commit ($FFMPEG_VERSION), and
# SHA256 is verified against THAT release's checksums.sha256 (the rolling
# "latest" tag is never fetched).
ffmpeg_tar_name() {
  case "$(uname -m)" in
    x86_64|amd64)   echo "ffmpeg-$FFMPEG_VERSION-linux64-gpl.tar.xz" ;;
    aarch64|arm64)  echo "ffmpeg-$FFMPEG_VERSION-linuxarm64-gpl.tar.xz" ;;
    *)              die "FFmpeg: unsupported arch $(uname -m)" ;;
  esac
}

install_ffmpeg() {
  step "FFmpeg (static GPL build, pinned $FFMPEG_VERSION)"
  need_cmd curl
  need_cmd tar
  mkdir -p "$XDG_BIN_HOME"

  local asset sha
  asset="$(ffmpeg_tar_name)"
  local url="$FFMPEG_RELEASE_BASE/$FFMPEG_RELEASE_TAG/$asset"
  local tmp="$XDG_DATA_HOME/_ffmpeg.tar.xz"
  local tmpdir="$XDG_DATA_HOME/_ffmpeg-extract"

  echo "  Downloading $asset"
  curl -fsSL "$url" -o "$tmp" || die "FFmpeg download failed: $url"

  # Verify against the pinned release's checksums.sha256 (format "<sha>  <asset>").
  local sums="$XDG_DATA_HOME/_ffmpeg-checksums"
  sha=""
  if curl -fsSL "$FFMPEG_RELEASE_BASE/$FFMPEG_RELEASE_TAG/checksums.sha256" -o "$sums" 2>/dev/null; then
    sha="$(awk -v a="$asset" '$2 == a {print $1}' "$sums")"
    rm -f "$sums"
  fi
  verify_sha256 "$tmp" "$sha" "ffmpeg ($asset)"

  rm -rf "$tmpdir"
  mkdir -p "$tmpdir"
  tar -xJf "$tmp" -C "$tmpdir"

  local bindir
  bindir="$(find "$tmpdir" -type d -name bin -print -quit)"
  [[ -n "$bindir" && -f "$bindir/ffmpeg" ]] || die "FFmpeg archive is missing bin/ffmpeg"
  rm -f "$XDG_BIN_HOME/ffmpeg" "$XDG_BIN_HOME/ffprobe" "$XDG_BIN_HOME/ffplay"
  cp -f "$bindir/ffmpeg" "$XDG_BIN_HOME/ffmpeg"
  cp -f "$bindir/ffprobe" "$XDG_BIN_HOME/ffprobe"
  cp -f "$bindir/ffplay" "$XDG_BIN_HOME/ffplay"
  chmod +x "$XDG_BIN_HOME/ffmpeg" "$XDG_BIN_HOME/ffprobe" "$XDG_BIN_HOME/ffplay"
  rm -rf "$tmpdir" "$tmp"
  ok "ffmpeg installed: $XDG_BIN_HOME/ffmpeg ($("$XDG_BIN_HOME/ffmpeg" -version 2>&1 | head -1))"
  record_tool_path_dirs "$XDG_BIN_HOME"
  wire_tool ffmpeg -- "$XDG_BIN_HOME"
}
