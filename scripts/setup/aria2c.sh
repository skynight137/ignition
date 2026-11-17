# shellcheck shell=bash
# aria2c installer (direct static binary, pinned release). Sourced by setup.sh.
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

