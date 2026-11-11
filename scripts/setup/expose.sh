# shellcheck shell=bash
# Remote-access installers: cloudflared (Cloudflare Tunnel), tailscale
# (userspace tailnet client), sshx (collaborative web terminal). Sourced by
# setup.sh. Runtime recipes live in references/exposing-ports.md — auth,
# funnel/serve, exit nodes and the Cloudflare edge gotchas.
# ─────────────────────────────────────────────────────────────────────────────
# setup.sh owns these names in $XDG_BIN_HOME, and a box that was set up BY HAND
# first (binaries in some random directory, symlinked onto PATH) must not end up
# with two versions fighting over one name:
#   * an existing SYMLINK at a target is reported before it is replaced — a
#     symlink is the fingerprint of a hand-rolled install, since these installers
#     always write real files;
#   * a plain file is replaced quietly (it is almost always our own previous
#     install, and announcing that on every re-run is noise);
#   * tailscaled's user data (node key + login) lives in $TAILSCALE_DATA_DIR and
#     is ADOPTED, never re-initialised: that is the same state dir a hand install
#     used, so the node stays logged in and only the binary paths change.
# None of the three is STARTED here — tailscaled needs a tailnet login first, so
# it gets a generated launcher instead (tailscale_write_launcher).
# ─────────────────────────────────────────────────────────────────────────────

# Report a foreign binary we are about to replace. See the header: only a symlink
# is worth announcing, because only a symlink proves the path came from elsewhere.
_bin_replace_note() {
  local p="$1"
  [[ -L "$p" ]] || return 0
  warn "replacing the existing symlink $p -> $(readlink "$p" 2>/dev/null) (left by an older manual install)"
}

# cloudflared — Cloudflare's tunnel client, pinned release
# ($CLOUDFLARED_VERSION in the profile). Versionless asset names, and the
# release publishes no checksum asset (only the binary and the .deb/.rpm
# packages), so the size + SHA256 pins below — computed from the official
# downloads — are the verification; they move WITH CLOUDFLARED_VERSION.
cloudflared_asset_name() {
  local os=linux
  [[ "$(uname -s)" == Darwin ]] && os=darwin
  case "$(uname -m)" in
    x86_64|amd64)   echo "cloudflared-$os-amd64$([[ $os == darwin ]] && echo .tgz)" ;;
    aarch64|arm64)  echo "cloudflared-$os-arm64$([[ $os == darwin ]] && echo .tgz)" ;;
    *)              die "cloudflared: unsupported arch $(uname -m)" ;;
  esac
}

# Pinned size (bytes) + SHA256 of the official $CLOUDFLARED_VERSION asset.
cloudflared_asset_size() {
  case "$1" in
    cloudflared-linux-amd64)        echo "40274445" ;;
    cloudflared-linux-arm64)        echo "37667293" ;;
    cloudflared-darwin-amd64.tgz)   echo "21834416" ;;
    cloudflared-darwin-arm64.tgz)   echo "19847161" ;;
    *)              die "cloudflared: no size pin recorded for asset $1" ;;
  esac
}
cloudflared_asset_sha256() {
  case "$1" in
    cloudflared-linux-amd64)        echo "1f99fb518b83dec2ba8d870a7cc991d82a77e6196295a3d2754ba17ab9f91872" ;;
    cloudflared-linux-arm64)        echo "3df43aedc9ff291d1735b5cb576cb97e0b157488796db2e32b28aecabb445775" ;;
    cloudflared-darwin-amd64.tgz)   echo "02f3edfd87684dd5b705607688e4eb4b323f6e777b81e7b3a85af556aa356848" ;;
    cloudflared-darwin-arm64.tgz)   echo "3586ccf397e98e5f437e60e7c307ca6ac463e110580503af8bb8e6f9ebf831bd" ;;
    *)              die "cloudflared: no SHA256 pin recorded for asset $1" ;;
  esac
}

install_cloudflared() {
  step "cloudflared (Cloudflare Tunnel client, pinned $CLOUDFLARED_VERSION)"
  need_cmd curl
  mkdir -p "$XDG_BIN_HOME"

  local asset url tmp
  asset="$(cloudflared_asset_name)"
  url="$CLOUDFLARED_RELEASE_BASE/$CLOUDFLARED_VERSION/$asset"
  tmp="$XDG_DATA_HOME/_cloudflared.bin"

  echo "  Downloading $asset"
  curl -fsSL "$url" -o "$tmp" || die "cloudflared download failed: $url"
  verify_pinned_asset "$tmp" "$(cloudflared_asset_size "$asset")" "$(cloudflared_asset_sha256 "$asset")" "cloudflared ($asset)"
  if [[ "$asset" == *.tgz ]]; then
    # darwin assets ship as a tarball wrapping the bare binary
    local exdir="$XDG_DATA_HOME/_cloudflared-extract"
    rm -rf "$exdir"; mkdir -p "$exdir"
    tar -xzf "$tmp" -C "$exdir" || die "cloudflared archive extract failed"
    local inner
    inner="$(find "$exdir" -type f -name cloudflared -print -quit)"
    [[ -n "$inner" ]] || die "cloudflared archive is missing the 'cloudflared' binary"
    mv -f "$inner" "$tmp"; rm -rf "$exdir"
  fi
  chmod +x "$tmp"
  _bin_replace_note "$XDG_BIN_HOME/cloudflared"
  rm -f "$XDG_BIN_HOME/cloudflared"
  mv -f "$tmp" "$XDG_BIN_HOME/cloudflared"
  ok "cloudflared installed: $XDG_BIN_HOME/cloudflared ($("$XDG_BIN_HOME/cloudflared" --version 2>&1 | head -1))"
  ok "  quick tunnel (no account, prints a https://<rand>.trycloudflare.com URL):"
  ok "    cloudflared tunnel --url http://localhost:<port>"
  ok "  named tunnel: cloudflared tunnel run --token \"\$TOKEN\"  (see references/exposing-ports.md)"
  record_tool_path_dirs "$XDG_BIN_HOME"
  wire_tool cloudflared -- "$XDG_BIN_HOME"
}

# tailscale — official stable channel, pinned version (TAILSCALE_VERSION
# in the profile; the muse profile pins its own copy as TSVER). The
# tarball name embeds the version; each archive ships a
# `<tarball>.sha256` next to it, which is verified.
# tailscale_asset_name lives in scripts/setup/core.sh (shared library).

# The daemon cannot be started by an installer (it needs a tailnet login first),
# but it CAN be started from a stable path. This launcher is that path: written
# on install and re-written by --fix, like the camofox launcher, so a .replit
# workflow never points at a hand-installed binary in a random directory.
# `curl | bash`-style quoting: the heredoc is UNQUOTED so the three paths below
# are baked in at write time; every other $ and " is escaped to stay literal.
# NOTE: inside an unquoted heredoc a backtick pair or $( ) would EXECUTE at emit
# time — keep this body free of both.
tailscale_write_launcher() {
  local f="$XDG_BIN_HOME/launch-tailscaled"
  mkdir -p "$XDG_BIN_HOME" || { warn "cannot create $XDG_BIN_HOME — tailscale launcher not written"; return 0; }
  cat > "$f" <<EOF
#!/usr/bin/env bash
# Generated by setup.sh (--tailscale / --fix) — do not hand-edit; re-run --fix.
#
# USERSPACE MODE IS MANDATORY here: /dev/net/tun is mode 600 owned by nobody and
# this container holds no CAP_NET_ADMIN, so the kernel TUN device cannot be
# opened. Userspace networking needs no TUN and still accepts INBOUND, which is
# what Funnel and a tailnet ssh target need. Side effect: this host dials the
# tailnet through the SOCKS5/HTTP proxy it exposes on 127.0.0.1:1055.
#
# Point a .replit workflow at THIS file (waitForPort = 1055). The binaries below
# are the managed ones in $XDG_BIN_HOME, so a version bump or a --fix cannot
# leave the workflow running an orphaned older copy.
#   \$1 or FUNNEL_PORT = local port to publish with Funnel. Omitted = nothing is
#   published; Cloudflare Tunnel is this box's public path, so Funnel is opt-in.
set -uo pipefail

BASE="\${TAILSCALE_DATA_DIR:-$TAILSCALE_DATA_DIR}"
STATE="\${TAILSCALE_STATE_DIR:-$TAILSCALE_STATE_DIR}"
SOCK="\${TAILSCALE_SOCKET:-$TAILSCALE_SOCKET}"
LOG="\${TAILSCALE_LOG:-$TAILSCALE_LOG}"
BIN="$XDG_BIN_HOME"
TSD="\$BIN/tailscaled"
TS="\$BIN/tailscale"
SERVICE_PORT="\${1:-\${FUNNEL_PORT:-}}"
NOW="bash $SETUP_ENTRY --machine repl"

for b in "\$TSD" "\$TS"; do
  [[ -x "\$b" ]] || { echo "launch-tailscaled: \$b is missing — run: \$NOW --tailscale" >&2; exit 1; }
done

mkdir -p "\$STATE"
mkdir -p "\${LOG%/*}"
# Liveness is OUR socket answering, not a pid pattern: a second daemon on another
# socket (test node, second tailnet) matches any reasonable pattern and would
# silently suppress the start, leaving this socket dead.
if ! "\$TS" --socket="\$SOCK" status >/dev/null 2>&1; then
  echo "starting tailscaled (userspace networking)"
  nohup "\$TSD" \\
    --tun=userspace-networking \\
    --state="\$STATE/tailscaled.state" \\
    --statedir="\$STATE" \\
    --socket="\$SOCK" \\
    --socks5-server=localhost:1055 \\
    --outbound-http-proxy-listen=localhost:1055 \\
    >> "\$LOG" 2>&1 &
  sleep 8
fi

echo "--- status ---"
"\$TS" --socket="\$SOCK" status || true

if [[ -n "\$SERVICE_PORT" ]]; then
  echo "--- funnel -> 127.0.0.1:\$SERVICE_PORT (explicitly requested) ---"
  "\$TS" --socket="\$SOCK" funnel --bg "\$SERVICE_PORT" || true
fi
"\$TS" --socket="\$SOCK" serve status || true
EOF
  chmod +x "$f"
  ok "tailscale launcher: $f (workflow target; waitForPort 1055)"
}

install_tailscale() {
  step "tailscale (userspace tailnet client, pinned $TAILSCALE_VERSION)"
  need_cmd curl
  need_cmd tar
  mkdir -p "$XDG_BIN_HOME" "$TAILSCALE_STATE_DIR"

  local ver asset url tmp tmpdir sums sha dir
  ver="$TAILSCALE_VERSION"
  asset="$(tailscale_asset_name "$ver")"
  url="$TAILSCALE_PKGS_BASE/$asset"
  tmp="$XDG_DATA_HOME/_tailscale.tgz"
  tmpdir="$XDG_DATA_HOME/_tailscale-extract"

  # Already at the pinned version: no tarball, no checksum fetch, no rewiring —
  # only the launcher is re-asserted. Re-running an installer is the repair path,
  # so it must be cheap and quiet, not a re-download every boot.
  if [[ -x "$XDG_BIN_HOME/tailscale" && -x "$XDG_BIN_HOME/tailscaled" ]] \
     && "$XDG_BIN_HOME/tailscale" version 2>/dev/null | grep -qF "$ver"; then
    skip "tailscale $ver sudah terpasang (tidak unduh ulang)"
    record_tool_path_dirs "$XDG_BIN_HOME"
    tailscale_write_launcher
    return 0
  fi

  echo "  Downloading $asset"
  curl -fsSL "$url" -o "$tmp" || die "tailscale download failed: $url"

  # The channel publishes <tarball>.sha256 as "<sha>  <name>".
  sha=""
  sums="$XDG_DATA_HOME/_tailscale.sha256"
  if curl -fsSL "$url.sha256" -o "$sums" 2>/dev/null; then
    sha="$(awk 'NR==1{print $1}' "$sums")"
    rm -f "$sums"
  fi
  verify_sha256 "$tmp" "$sha" "tailscale ($asset)"

  rm -rf "$tmpdir"
  mkdir -p "$tmpdir"
  tar -xzf "$tmp" -C "$tmpdir"

  dir="$(find "$tmpdir" -maxdepth 1 -type d -name 'tailscale_*' -print -quit)"
  [[ -n "$dir" && -f "$dir/tailscale" && -f "$dir/tailscaled" ]] \
    || die "tailscale archive is missing tailscale/tailscaled"

  # A hand-installed copy may sit in $TAILSCALE_DATA_DIR (which is also where the
  # node state lives). Ours goes to $XDG_BIN_HOME and ADOPTS that state, so the
  # node stays logged in and nothing needs re-auth. The old copy is left where it
  # is — an operator's own scripts may call it — and reported instead.
  if [[ -x "$TAILSCALE_DATA_DIR/tailscale" || -x "$TAILSCALE_DATA_DIR/tailscaled" ]]; then
    warn "an older tailscale copy is present in $TAILSCALE_DATA_DIR — this install uses $XDG_BIN_HOME and the same state dir (no re-auth); retire the old copy when your scripts allow it"
  fi
  _bin_replace_note "$XDG_BIN_HOME/tailscale"
  _bin_replace_note "$XDG_BIN_HOME/tailscaled"
  rm -f "$XDG_BIN_HOME/tailscale" "$XDG_BIN_HOME/tailscaled"
  mv -f "$dir/tailscale" "$XDG_BIN_HOME/tailscale"
  mv -f "$dir/tailscaled" "$XDG_BIN_HOME/tailscaled"
  chmod +x "$XDG_BIN_HOME/tailscale" "$XDG_BIN_HOME/tailscaled"
  rm -rf "$tmpdir" "$tmp"

  # These are REAL binaries in $XDG_BIN_HOME, not symlinks into a payload dir:
  # two files, no indirection, and --clean tailscale removes exactly them plus
  # the launcher while preserving the tailnet state under $TAILSCALE_DATA_DIR.
  ok "tailscale installed: $XDG_BIN_HOME/tailscale ($("$XDG_BIN_HOME/tailscale" version 2>&1 | head -1))"
  ok "  start it with: $XDG_BIN_HOME/launch-tailscaled [funnel-port]"
  ok "  (userspace networking + --statedir; state in $TAILSCALE_DATA_DIR — see references/exposing-ports.md)"
  record_tool_path_dirs "$XDG_BIN_HOME"
  # Paths AND the node name travel with the tool: every script reads them from the
  # environment instead of re-spelling the socket dir, and the rc block carries them
  # across shells so a run never has to be prefixed by hand.
  record_tool_env_vars TAILSCALE_DATA_DIR TAILSCALE_STATE_DIR TAILSCALE_SOCKET TAILSCALE_LOG
  wire_tool tailscale TAILSCALE_DATA_DIR TAILSCALE_STATE_DIR TAILSCALE_SOCKET TAILSCALE_LOG -- "$XDG_BIN_HOME"
  tailscale_write_launcher
}

# sshx — collaborative web terminal. Its GitHub releases carry NO assets, so the
# versionless S3 tarball (what sshx.io/get pulls) is the only artifact; no
# checksum is published. The archive holds a single `sshx` binary.
sshx_asset_name() {
  case "$(uname -m)" in
    x86_64|amd64)   echo "sshx-x86_64-unknown-linux-musl.tar.gz" ;;
    aarch64|arm64)  echo "sshx-aarch64-unknown-linux-musl.tar.gz" ;;
    *)              die "sshx: unsupported arch $(uname -m)" ;;
  esac
}

install_sshx() {
  step "sshx (collaborative web terminal)"
  need_cmd curl
  need_cmd tar
  mkdir -p "$XDG_BIN_HOME"

  local asset url tmp tmpdir bin
  asset="$(sshx_asset_name)"
  url="$SSHX_DOWNLOAD_BASE/$asset"
  tmp="$XDG_DATA_HOME/_sshx.tar.gz"
  tmpdir="$XDG_DATA_HOME/_sshx-extract"

  echo "  Downloading $asset"
  curl -fsSL "$url" -o "$tmp" || die "sshx download failed: $url"

  rm -rf "$tmpdir"
  mkdir -p "$tmpdir"
  tar -xzf "$tmp" -C "$tmpdir"
  # Layout-agnostic: the archive may or may not wrap the binary in a dir.
  bin="$(find "$tmpdir" -type f -name sshx -print -quit)"
  [[ -n "$bin" ]] || die "sshx archive is missing the 'sshx' binary"
  _bin_replace_note "$XDG_BIN_HOME/sshx"
  rm -f "$XDG_BIN_HOME/sshx"
  mv -f "$bin" "$XDG_BIN_HOME/sshx"
  chmod +x "$XDG_BIN_HOME/sshx"
  rm -rf "$tmpdir" "$tmp"
  ok "sshx installed: $XDG_BIN_HOME/sshx ($("$XDG_BIN_HOME/sshx" --version 2>&1 | head -1))"
  ok "  share a shell: sshx   (prints a web URL; nothing listens locally)"
  record_tool_path_dirs "$XDG_BIN_HOME"
  wire_tool sshx -- "$XDG_BIN_HOME"
}
