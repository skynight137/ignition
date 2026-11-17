# shellcheck shell=bash
# qBittorrent-nox installer (static binary, pinned release). Sourced by setup.sh.
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

