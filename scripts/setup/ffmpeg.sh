# shellcheck shell=bash
# FFmpeg installer (BtbN static GPL build, pinned release). Sourced by setup.sh.
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

