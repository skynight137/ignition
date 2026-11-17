# shellcheck shell=bash
# Shared version / URL pins — one source of truth for both profiles.
# Sourced by profile-repl.sh and profile-muse.sh; lanes read these names.
# A pin moves here, never in a profile or a lane.

# Version / URL config ──────────────────────────────────────────────────────
JAVA_MAJOR="${JAVA_MAJOR:-24}"
NODE_MAJOR="26"
ANDROID_PLATFORM="android-37.0"
ANDROID_BUILD_TOOLS="37.0.0"
CMDLINE_TOOLS_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
JAVA_TOOL_OPTS_VALUE="-XX:-UsePerfData --enable-native-access=ALL-UNNAMED"
# uv: pinned release, installed from the versioned GitHub tarball
# (astral-sh/uv) with its published .sha256 sidecar — no installer
# script, so the version on the box is the version recorded here.
UV_VERSION="0.13.8"
# ollama: pinned release, installed from the versioned GitHub tarball
# (ollama/ollama) with its published sha256sum.txt — no installer
# script, so the version on the box is the version recorded here.
OLLAMA_VERSION="0.40.16"
OLLAMA_RELEASE_BASE="https://github.com/ollama/ollama/releases/download"

# AI coding (direct binary downloads — no curl|bash installers)
OPENCODE_REPO="anomalyco/opencode"
OPENCODE_VERSION="1.19.5"
CLAUDE_RELEASE_BASE="https://downloads.claude.ai/claude-code-releases"
CLAUDE_VERSION="2.1.325"
# ORI tags its CLI releases cli-<version>-<commit>; the tag is the
# release path segment, so ORI_VERSION carries the whole tag.
ORI_VERSION="cli-0.17.0-31fbdff"
ORI_RELEASE_BASE="https://github.com/OpenRouterLabs/ori-releases/releases/download"

# Download / media tools (direct binaries — no curl|bash, no installers)
# rclone: pinned release on downloads.rclone.org (the canonical
# mirror of github.com/rclone/rclone/releases); the version dir
# publishes SHA256SUMS, which the lane verifies against.
RCLONE_VERSION="1.76.0"
RCLONE_DOWNLOAD_BASE="https://downloads.rclone.org"
# qbittorrent-nox: static single binary, arch-prefixed asset name.
# The release tag is release-<qbt version>_v<libtorrent version>; the
# release publishes no checksum asset, so scripts/setup/qbittorrent.sh
# carries size + SHA256 pins that move with this version.
QBT_VERSION="5.3.0_v2.1.2"
QBT_RELEASE_BASE="https://github.com/userdocs/qbittorrent-nox-static/releases/download"
# aria2c: github.com/aria2/aria2 releases ship SOURCE ONLY (no Linux binary);
# abcfy2/aria2-static-build repackages those releases as static musl binaries.
# No checksum asset either — size + SHA256 pins live in aria2c.sh.
ARIA2_VERSION="1.37.0"
ARIA2_RELEASE_BASE="https://github.com/abcfy2/aria2-static-build/releases/download"
# ffmpeg: BtbN static GPL builds (newer than the Replit Nix-built ffmpeg 6.1.2).
# BtbN publishes no numbered-release tarballs: the pinned form is one
# dated autobuild release (immutable) whose assets are named by the
# exact master commit they were built from; its checksums.sha256 is
# verified by the lane.
FFMPEG_VERSION="N-128915-g3d16b774d7"
FFMPEG_RELEASE_TAG="autobuild-2026-11-15-12-40"
FFMPEG_RELEASE_BASE="https://github.com/BtbN/FFmpeg-Builds/releases/download"

# Remote access (direct binaries — see references/exposing-ports.md)
# cloudflared: Cloudflare's tunnel client. Versionless asset names,
# and the release publishes NO checksum asset (only the binary and
# the .deb/.rpm packages), so scripts/setup/cloudflared.sh carries size +
# SHA256 pins computed from the official downloads; they move with
# this version.
CLOUDFLARED_VERSION="2026.11.0"
CLOUDFLARED_RELEASE_BASE="https://github.com/cloudflare/cloudflared/releases/download"
# tailscale: official stable channel, pinned version — one pin for both
# machines (the muse profile's old TSVER copy is gone). The tarball name
# embeds the version, and each archive has a `<tarball>.sha256` next to
# it (verified).
TAILSCALE_VERSION="1.104.7"
TAILSCALE_PKGS_BASE="https://pkgs.tailscale.com/stable"
# sshx: collaborative web terminal. Its GitHub releases carry NO assets at all
# (checked: v0.4.1 has none); the canonical artifact is the versionless S3
# tarball the sshx.io/get script pulls. No checksum published.
SSHX_DOWNLOAD_BASE="https://s3.amazonaws.com/sshx"

# Lightpanda: lightweight headless browser (CDP server) for keep-alive
# tours. Pinned release — the release publishes NO checksum asset, so
# scripts/setup/lightpanda.sh carries the per-arch size + SHA256 pins computed
# from the official downloads; they move with this version.
LIGHTPANDA_VERSION="1.0.4"
LIGHTPANDA_RELEASE_BASE="https://github.com/lightpanda-io/browser/releases/download"
# The tour client's playwright pin — the version proven against
# Lightpanda 1.0.3's CDP in the fleet trial (references/lightpanda.md).
LIGHTPANDA_PLAYWRIGHT_VERSION="1.65.1"
MOLI_VERSION="1.1.25"
MOLI_RELEASE_BASE="https://github.com/lexmount/moli/releases/download"
# Camofox: the npm package is pinned — a bare `npm install -g` would
# float to latest on every re-run and silently move the browser (and
# the engine camoufox-js fetches for it) under a running fleet.
CAMOFOX_VERSION="1.19.0"

# AI agent
HERMES_INSTALL_URL="https://hermes-agent.nousresearch.com/install.sh"
