#!/usr/bin/env bash
# llm-wiki installer + server bootstrap (plain Linux; nothing Nix-specific).
#
#   bash install.sh                       # fetch the AppImage, extract, make a token
#   LLM_WIKI_APPIMAGE=/tmp/app.AppImage bash install.sh
#   LLM_WIKI_APPIMAGE_URL=https://.../app.AppImage bash install.sh
#
# After it finishes:  bash run-public.sh   (supervisor: Xvfb + WM + app + node server)
# Server endpoint:    https://<host>${PORT:+:$PORT}/mcp      header: x-llm-wiki-token: <token>
# Local agents:       http://127.0.0.1:8199/mcp      (loopback, no token)
#
# Requirements: curl for the download, node >= 18 for the REST/MCP server, and an X
# display for the app (Xvfb + a window manager is enough). On NixOS:
#   nix build nixpkgs#xvfb nixpkgs#fluxbox nixpkgs#shared-mime-info
#
# The release publishes an AppImage for EVERY architecture (amd64, aarch64). Picking
# the wrong one does not fail loudly: its runtime cannot execute, --appimage-extract
# dies with "Exec format error", and you are left with an empty dir and the unhelpful
# "app binary not found" later. So this script resolves the asset BY ARCH, proves the
# download is an ELF for this machine, and shows the extraction error instead of
# throwing it away.
set -uo pipefail
APP="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$APP/.env"
REPO="nashsu/llm_wiki"
# Pinned upstream release — deliberately NOT releases/latest: the box
# gets the AppImage this pin names, and a fleet-wide bump is a
# one-line change here. Candidate URLs below resolve from this tag only.
RELEASE_TAG="v0.6.13"
BIN="$APP/squashfs-root/usr/bin/llm-wiki"

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "curl is required"

# --- arch facts -------------------------------------------------------------
# e_machine (little endian, offset 0x12): 3e00 = x86-64, b700 = AArch64
case "$(uname -m)" in
  x86_64|amd64)   ARCH_TAG="amd64"   ; ELF_WANT="3e00" ;;
  aarch64|arm64)  ARCH_TAG="aarch64" ; ELF_WANT="b700" ;;
  *)              ARCH_TAG=""        ; ELF_WANT="" ;;
esac

elf_magic()   { od -An -N4 -tx1 "$1" 2>/dev/null | tr -d ' \n'; }   # expect 7f454c46
elf_machine() { od -An -j18 -N2 -tx1 "$1" 2>/dev/null | tr -d ' \n'; }

# Names the release uses for our arch, most specific first.
arch_patterns() {
  case "$ARCH_TAG" in
    amd64)   printf '%s\n' "_amd64\\.AppImage$" "_x86_64\\.AppImage$" "_x64\\.AppImage$" ;;
    aarch64) printf '%s\n' "_aarch64\\.AppImage$" "_arm64\\.AppImage$" ;;
    *)       printf '%s\n' "\\.AppImage$" ;;
  esac
}

# Candidate AppImage URLs for the PINNED release: GitHub API first
# (60/h unauthenticated), then the release's expanded-assets HTML
# page, which needs no API quota at all.
appimage_urls() {
  curl -fsSL "https://api.github.com/repos/$REPO/releases/tags/$RELEASE_TAG" 2>/dev/null \
    | grep -o '"browser_download_url": *"[^"]*"' | cut -d'"' -f4 || true
  curl -fsSL "https://github.com/$REPO/releases/expanded_assets/$RELEASE_TAG" 2>/dev/null \
    | grep -o "/$REPO/releases/download/[^\"]*\.AppImage" \
    | sed 's|^|https://github.com|' | sort -u || true
}

resolve_url() {
  local urls pat pats picked
  urls="$(appimage_urls)"
  [ -n "$urls" ] || return 1
  pats="$(arch_patterns)"
  while IFS= read -r pat; do
    picked="$(printf '%s\n' "$urls" | grep -Ei "$pat" | head -1)"
    [ -n "$picked" ] && { printf '%s' "$picked"; return 0; }
  done <<<"$pats"
  # Unknown arch: take the first AppImage but say so.
  printf '%s\n' "$urls" | head -1
}

# --- 1. the desktop app -----------------------------------------------------
if [ ! -x "$BIN" ]; then
  IMG="${LLM_WIKI_APPIMAGE:-$APP/app.AppImage}"
  if [ ! -f "$IMG" ]; then
    URL="${LLM_WIKI_APPIMAGE_URL:-}"
    if [ -z "$URL" ]; then
      say "looking up the pinned $REPO release $RELEASE_TAG (arch: ${ARCH_TAG:-$(uname -m)}) ..."
      URL="$(resolve_url)" || true
    fi
    [ -n "$URL" ] || die "no AppImage URL found — pass LLM_WIKI_APPIMAGE=/path or LLM_WIKI_APPIMAGE_URL=..."
    case "$URL" in
      *"_${ARCH_TAG}"*) ;;   # expected
      *) [ -z "$ARCH_TAG" ] || say "warning: '$URL' does not look like the $ARCH_TAG build" ;;
    esac
    say "downloading $URL"
    curl -fL --retry 3 --retry-delay 2 -o "$IMG" "$URL" || die "download failed: $URL"
  fi

  # Prove the file before executing it: the usual failures are a saved HTML/JSON
  # error page (bad URL) and the other architecture's build, and both go wrong in
  # confusing ways later.
  size=$(wc -c <"$IMG" 2>/dev/null || echo 0)
  [ "$size" -gt 20000000 ] || die "$IMG is only ${size} bytes — not an AppImage (bad URL or an error page)"
  [ "$(elf_magic "$IMG")" = "7f454c46" ] || die "$IMG is not an ELF binary (magic $(elf_magic "$IMG"))"
  if [ -n "$ELF_WANT" ]; then
    got="$(elf_machine "$IMG")"
    [ "$got" = "$ELF_WANT" ] || die "$IMG is built for another machine (e_machine $got, need $ELF_WANT) — wrong asset for $(uname -m); delete it and re-run, or point LLM_WIKI_APPIMAGE_URL at the $ARCH_TAG build"
  fi

  chmod +x "$IMG"
  say "extracting $IMG"
  if ! ( cd "$APP" && "$IMG" --appimage-extract >"$APP/extract.log" 2>&1 ); then
    say "extraction failed — last lines of $APP/extract.log:"
    tail -5 "$APP/extract.log" 2>/dev/null | sed 's/^/    /'
    die "could not extract the AppImage (see above)"
  fi
  [ -x "$BIN" ] || die "extraction finished but $BIN is missing — log: $APP/extract.log"
  say "app binary ready: $BIN"
else
  say "app already extracted: $BIN"
fi

# --- 2. shared token --------------------------------------------------------
# Instalasi lama menyimpan token di llmwiki.env; pindahkan (bukan buat token baru),
# kalau tidak klien yang sudah memegang token lama kehilangan akses.
if [ ! -f "$ENV_FILE" ] && [ -f "$APP/llmwiki.env" ]; then
  mv "$APP/llmwiki.env" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  say "migrated llmwiki.env -> $ENV_FILE"
fi
_rand_token() {
  if command -v node >/dev/null 2>&1; then
    node -e 'console.log(require("crypto").randomBytes(32).toString("hex"))'
  elif command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}
if [ ! -f "$ENV_FILE" ]; then
  # Dua token: akses penuh, plus satu read-only untuk agen yang hanya membaca (server
  # menolak tulis dengan -32003). Dibuat di sini supaya gate read-only bisa diuji di
  # mesin bersih tanpa menyunting .env manual.
  TOKEN=$(_rand_token); [ -n "$TOKEN" ] || die "could not generate a token"
  RO_TOKEN=$(_rand_token); [ -n "$RO_TOKEN" ] || die "could not generate a read-only token"
  printf 'LLM_WIKI_API_TOKEN=%s\nLLM_WIKI_READONLY_TOKEN=%s\n' "$TOKEN" "$RO_TOKEN" >"$ENV_FILE"
  chmod 600 "$ENV_FILE"
  say "wrote $ENV_FILE (chmod 600; full + read-only token)"
  say "token sha256[:12] = $(printf %s "$TOKEN" | sha256sum | cut -c1-12)"
elif ! grep -q LLM_WIKI_READONLY_TOKEN "$ENV_FILE"; then
  printf 'LLM_WIKI_READONLY_TOKEN=%s\n' "$(_rand_token)" >>"$ENV_FILE"
  say "added missing read-only token to $ENV_FILE"
else
  say "token file already present: $ENV_FILE"
fi
# Port publik: Replit hanya me-routing port yang terdaftar, jadi pilih yang benar-benar
# bebas (8080 bisa dipegang dashboard) dan simpan pilihannya di .env supaya restart
# konsisten. Override tetap lewat LLM_WIKI_PORT.
_pick_port() {
  local c
  for c in "${LLM_WIKI_PORT:-}" 8319 8320 8081 8090; do
    [ -n "$c" ] || continue
    timeout 1 bash -c "echo >/dev/tcp/127.0.0.1/$c" 2>/dev/null || { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

# --- 3. node (the server runtime) -------------------------------------------
# A missing node must NOT abort the app install: the binary is useful on its own and
# setup.sh --node can add the runtime afterwards.
if ! command -v node >/dev/null 2>&1; then
  say "note: node not found — the REST/MCP server needs node >= 18 (bash setup.sh --node)"
elif ! node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 18 ? 0 : 1)'; then
  say "note: node $(node -v) is too old — the server needs >= 18 (bash setup.sh --node)"
fi

# --- 4. machine-specific library dirs (optional) ----------------------------
# start-app.sh already assembles LD_LIBRARY_PATH (bundle/lib + system dirs + whatever
# .ldpath/.libdirs.pre list) and finds shared-mime-info itself, including in the nix
# store. These files only matter when GTK still cannot load a library on THIS machine.
# Under setup.sh the module fills .libdirs.pre itself (nix wayland + mesa — the
# bundle's libwayland-client breaks mesa's EGL and blanks the window); left empty
# here, it stays a manual override: dirs that must resolve BEFORE the bundle.
[ -f "$APP/.libdirs.pre" ] || { : >"$APP/.libdirs.pre"; say "created empty .libdirs.pre (setup.sh fills it on nix; otherwise fill only if the app fails to load a library)"; }

# --- 5. display sanity ------------------------------------------------------
command -v Xvfb >/dev/null 2>&1 || say "note: no Xvfb — the app needs a display (nix build nixpkgs#xvfb)"
{ command -v fluxbox >/dev/null 2>&1 || command -v openbox >/dev/null 2>&1; } \
  || say "note: no window manager — GTK windows stay unmapped without one (nix build nixpkgs#fluxbox)"

if ! grep -q '^LLM_WIKI_PORT=' "$ENV_FILE" 2>/dev/null; then
  PORT="$(_pick_port)" && printf 'LLM_WIKI_PORT=%s\n' "$PORT" >>"$ENV_FILE" \
    && say "public port: $PORT (tersimpan sebagai LLM_WIKI_PORT di $ENV_FILE)"
fi
PORT="$(sed -n 's/^LLM_WIKI_PORT=//p' "$ENV_FILE" 2>/dev/null | head -1)"
# Wiki root default menempel di direktori app (mudah dihapus bersama app); override
# lewat LLM_WIKI_PROJECT, dan tiap request MCP juga menerima parameter `project`.
if ! grep -q '^LLM_WIKI_PROJECT=' "$ENV_FILE" 2>/dev/null; then
  printf 'LLM_WIKI_PROJECT=%s\n' "$APP/project" >>"$ENV_FILE" \
    && say "wiki root: $APP/project (override: LLM_WIKI_PROJECT)"
fi
mkdir -p "$APP/project/wiki"

# Deklarasikan port publik di .replit (idempotent): edge hanya memetakan port yang
# tertulis di situ. Port 80 otomatis tanpa sufiks lewat dev domain.
REPL_FILE="${REPL_HOME:-$HOME}/.replit"
if [ -n "$PORT" ] && [ -f "$REPL_FILE" ] && ! grep -qx "localPort = $PORT" "$REPL_FILE"; then
  printf '\n[[ports]]\nlocalPort = %s\nexternalPort = %s\n' "$PORT" "$PORT" >>"$REPL_FILE" \
    && say "port $PORT dideklarasikan di $REPL_FILE (berlaku setelah Repl di-restart)"
fi

say ""
say "done. start the stack with:"
say "  bash $APP/run-public.sh        # app + REST/MCP server"
say "  bash $APP/run-ui.sh            # optional: the desktop UI in a browser (noVNC :6080)"
say ""
say "add this URL to your MCP client:"
say "  http://127.0.0.1:8199/mcp                 (loopback, no token)"
SUF=""; [ "${PORT:-80}" = 80 ] || SUF=":${PORT}"
say "  https://<host>${SUF}/mcp   (other machines; header: x-llm-wiki-token: <token>)"
say "token: $ENV_FILE"