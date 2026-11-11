# llm-wiki.sh — the llm-wiki knowledge server, installed by one flag.
#
#   bash setup.sh --llm-wiki
#
# Installs the bundle shipped in scripts/setup/llm-wiki/ into
# ${LLM_WIKI_HOME:-$XDG_DATA_HOME/llmwiki-app}:
#
#   install.sh        fetch the AppImage, extract it, mint the shared token
#                     (the AppImage release is PINNED there — RELEASE_TAG —
#                     never resolved from releases/latest)
#   run-public.sh     supervisor: Xvfb + WM + app + the REST/MCP server
#                     (19828 app API · public port LLM_WIKI_PORT or 8319, token required
#                      · 8199 loopback, no token)
#   run-ui.sh         supervisor: x11vnc (loopback 5900) + noVNC (public 6800) so the real
#                     desktop UI opens in a browser — the frontend is Tauri, there is no
#                     web UI to serve
#   start-app.sh      app launcher with the software-GL / pixbuf env it needs headless
#   llmwiki-server.js the Node server that speaks REST + MCP (streamable HTTP)
#
# Replit is a NixOS box: packages come from the nix store, never apt. Everything on PATH
# here is already nix-provided, and a missing piece is one `nix build` away (a replit.nix
# entry makes it survive a recreate). Nothing in this path needs Nix itself — the app is a
# prebuilt AppImage and the server is Node stdlib.
#
# Runtime facts that cost real debugging time (see references/llm-wiki-server.md):
#   * a window manager is mandatory — without one GTK windows are created but never mapped
#   * shared-mime-info must be on XDG_DATA_DIRS, or gdk-pixbuf rejects every image format
#   * the app needs node >= 18 for the server, and curl for the download
#   * the bundle's own libwayland-client must not be the copy mesa's EGL loads, or the
#     WebProcess aborts (EGL_BAD_PARAMETER) and the window stays blank — the module
#     pins the nix wayland + mesa into .libdirs.pre, which start-app.sh reads first

# Xvfb + a window manager are system-ish; the container has neither root nor apt, so
# they come from nix. Always into a PER-USER store + the nixenv mount namespace, never
# into /nix/store: `nix build --store /nix/store` happily prints store paths while
# copying nothing when the dir only looks writable, so every `[ -x ]` then fails and
# nothing lands on PATH. A wrapper also pins -xkbdir, without which Xvfb dies with
# "Failed to activate virtual core keyboard". Report-only stays for what is still missing.
_nix_store_user() { printf '%s' "${REPL_HOME:-$HOME}/.store"; }

# A wrapper on PATH is not proof of a working display: it exec's nixenv + a path in
# ~/.store, and a wiped store (or a lost nixenv, which an older bug in this module
# caused) leaves both pointing nowhere while `command -v` still succeeds. Validate the
# whole chain, or a stale wrapper silently suppresses the provisioning that would fix it.
_llm_wiki_display_ok() {
  local b w sp
  [ -x "$XDG_BIN_HOME/nixenv" ] || return 1
  for b in Xvfb fluxbox; do
    w="$(command -v "$b" 2>/dev/null)" || return 1
    sp="$(sed -n 's#^exec [^ ]* \(/.*/bin/[^ "]*\).*#\1#p' "$w" 2>/dev/null | head -1)"
    [ -n "$sp" ] && [ -x "$sp" ] || return 1
  done
}

_llm_wiki_provision_display() {
  _llm_wiki_display_ok && return 0
  [ -n "$(nix_bin)" ] || return 0
  local st p up xkb="" b wrapper
  st="$(_nix_store_user)"; mkdir -p "$st/nix/store"

  step "llm-wiki: provisioning Xvfb + fluxbox (nix, no root needed)"
  local outs
  outs="$(nix_bin_out "$st")" || true
  [ -n "$outs" ] || { warn "llm-wiki: nix build for Xvfb failed"; return 1; }
  # nix prints /nix/store/<hash> even for a --store elsewhere, and that path need not
  # exist on this box: resolve each one inside the per-user store before testing it.
  for p in $outs; do
    case "$p" in *xkeyboard-config*) xkb="$st/nix/store/${p##*/}/share/X11/xkb" ;; esac
  done
  # nixenv is a repl-only payload: it lives in scripts/replit/ (reached
  # via $REPL_SKILL_DIR), NOT beside this lane in scripts/setup/.
  cp -f "$REPL_SKILL_DIR/nixenv" "$XDG_BIN_HOME/nixenv" \
    || { warn "llm-wiki: nixenv tidak ada di $REPL_SKILL_DIR — Xvfb hasil build tak bisa jalan"; return 1; }
  chmod +x "$XDG_BIN_HOME/nixenv"
  for p in $outs; do
    up="$st/nix/store/${p##*/}"
    for b in "$up/bin/Xvfb" "$up/bin/fluxbox"; do
      [ -x "$b" ] || continue
      wrapper="$XDG_BIN_HOME/${b##*/}"
      { printf '#!/bin/bash\nexec %s %s' "$XDG_BIN_HOME/nixenv" "$b"
        [ -n "$xkb" ] && printf ' -xkbdir %s' "$xkb"
        printf ' "$@"\n'; } > "$wrapper"
      chmod +x "$wrapper"
    done
  done
}

nix_bin_out() {
  "$(nix_bin)" --store "$1" build --no-link --print-out-paths \
    nixpkgs#xorg.xvfb nixpkgs#fluxbox nixpkgs#xkeyboard_config 2>/dev/null
}

install_llm_wiki() {
  local src="$SETUP_LIB_DIR/llm-wiki" dest note=""

  # Never create a SECOND copy: on a box that already runs the server from its own
  # directory (a workflow points at it and it holds that box's tokens + port), reuse
  # that directory. Otherwise a re-run silently forks the install and the old copy
  # keeps serving whatever the workflow starts.
  if [[ -n "${LLM_WIKI_HOME:-}" ]]; then
    dest="$LLM_WIKI_HOME"
  elif [[ -n "${WORKSPACE:-}" && -x "$WORKSPACE/tools/llmwiki-app/run-public.sh" ]]; then
    dest="$WORKSPACE/tools/llmwiki-app"
    note=" (reusing the existing install)"
  else
    dest="${LLM_WIKI_HOME:-${REPL_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}}/llmwiki-app}"
  fi

  [ -d "$src" ] || { warn "bundle missing: $src"; return 1; }
  mkdir -p "$dest"
  cp -f "$src/install.sh" "$src/run-public.sh" "$src/run-ui.sh" \
        "$src/start-app.sh" "$src/llmwiki-server.js" "$dest/"
  chmod +x "$dest"/*.sh
  echo "  llm-wiki bundle -> $dest$note"

  _llm_wiki_provision_display || true
  llm_wiki_requirements
  ( cd "$dest" && bash install.sh ) || return 1

  # install.sh can succeed at "nothing to do" while the app was never extracted
  # (a failed download, the wrong architecture's AppImage). Catch it here, where the
  # one-fla  # one-flag run can report a real failure instead of the supervisor dying later.
  if [ ! -x "$dest/squashfs-root/usr/bin/llm-wiki" ]; then
    warn "llm-wiki: app binary missing after install ($dest/squashfs-root/usr/bin/llm-wiki)"
    warn "  see $dest/extract.log, or re-run: bash $dest/install.sh"
    return 1
  fi

  # NixOS has no /usr/lib/x86_64-linux-gnu, and a nix-store lib is invisible to ld.so
  # unless its /lib is listed in .ldpath — so the binary extracts fine and then dies
  # with "libX11.so.6: cannot open shared object file". install.sh cannot know which
  # libs the bundle wants; resolve them from the binary's own "not found" list.
  local bin="$dest/squashfs-root/usr/bin/llm-wiki" miss dirs="" pre="" p d lib
  miss=$(ldd "$bin" 2>/dev/null | awk '/not found/{print $1}' | sort -u)
  if [ -n "$miss" ] && [ -n "$(nix_bin)" ]; then
    step "llm-wiki: resolving $(wc -l <<<"$miss") shared libs from nix"
    # Build into the PER-USER store, not /nix/store: /etc/nix/nix.conf enables a
    # local-overlay there, so nix happily prints /nix/store/<hash> while copying
    # nothing, and every [ -d ] below then misses (the documented trap). Outputs are
    # resolved back into our own store before they are tested.
    local st; st="$(_nix_store_user)"; mkdir -p "$st/nix/store"
    for p in $("$(nix_bin)" --store "$st" build --no-link --print-out-paths \
      nixpkgs#xorg.libX11 nixpkgs#xorg.libxcb nixpkgs#libdrm nixpkgs#mesa nixpkgs#expat \
      nixpkgs#fribidi nixpkgs#harfbuzz nixpkgs#zlib nixpkgs#libgpg-error \
      nixpkgs#wayland nixpkgs#stdenv.cc.cc.lib 2>/dev/null); do
      d="$st/nix/store/${p##*/}/lib"
      [ -d "$d" ] && dirs="${dirs:+$dirs:}$d"
      # wayland + mesa are also pinned into .libdirs.pre below: collect their dirs
      # here, identified by the soname each one must actually provide.
      [ -e "$d/libwayland-client.so.0" ] && pre="${pre:+$pre:}$d"
      [ -e "$d/libEGL_mesa.so.0" ] && pre="${pre:+$pre:}$d"
    done
    # Some libs sit in a non-default output (libcom_err in e2fsprogs), so nothing above
    # covers them: locate the file by name and take its directory. Our own store first.
    for lib in $(LD_LIBRARY_PATH="$dirs" ldd "$bin" 2>/dev/null | awk '/not found/{print $1}' | sort -u); do
      d=$(ls -d "$st"/nix/store/*/lib/"$lib" /nix/store/*/lib/"$lib" 2>/dev/null | head -1)
      [ -n "$d" ] && dirs="${dirs:+$dirs:}$(dirname "$d")"
    done
    # start-app reads this with `read -a`, which returns non-zero at EOF without a
    # trailing newline — and the read is chained with `&&`, so a missing newline would
    # silently drop every entry.
    [ -n "$dirs" ] && printf '%s\n' "$dirs" >"$dest/.ldpath"
    miss=$(LD_LIBRARY_PATH="$dirs" ldd "$bin" 2>/dev/null | awk '/not found/{print $1}' | sort -u | tr '\n' ' ')

    # The two passes above can only find libs that are ALREADY built. On a bare box the
    # bundle also wants packages nothing here pulled in yet (libXau, libXdmcp,
    # libgraphite2 …), so build the GTK/Electron runtime set once and resolve again.
    if [ -n "$miss" ]; then
      step "llm-wiki: building the packages for the still-missing libs"
      # shellcheck disable=SC2046
      "$(nix_bin)" --store "$st" build --no-link --print-out-paths \
        nixpkgs#xorg.libXau nixpkgs#xorg.libXdmcp nixpkgs#graphite2 nixpkgs#at-spi2-core \
        nixpkgs#nss nixpkgs#cups nixpkgs#alsa-lib nixpkgs#gtk3 nixpkgs#pango nixpkgs#cairo \
        nixpkgs#libsecret nixpkgs#libnotify nixpkgs#libxkbcommon >/dev/null 2>&1 || true
      for lib in $miss; do
        d=$(ls -d "$st"/nix/store/*/lib/"$lib" /nix/store/*/lib/"$lib" 2>/dev/null | head -1)
        [ -n "$d" ] && dirs="${dirs:+$dirs:}$(dirname "$d")"
      done
      [ -n "$dirs" ] && printf '%s\n' "$dirs" >"$dest/.ldpath"
      miss=$(LD_LIBRARY_PATH="$dirs" ldd "$bin" 2>/dev/null | awk '/not found/{print $1}' | sort -u | tr '\n' ' ')
    fi
    # Pin the nix wayland + mesa ahead of the bundle (start-app.sh reads
    # .libdirs.pre FIRST). The bundle ships its own libwayland-client and the app
    # binary resolves it via $ORIGIN/../lib, so wayland never appears in the
    # "not found" list above and the closure never contained a nix copy. Harmless
    # for GTK — fatal for EGL: WebKit dlopens mesa's libEGL_mesa, whose
    # libwayland-client is by then already loaded (the bundle's Ubuntu build), and
    # eglGetDisplay fails with EGL_BAD_PARAMETER. The WebProcess aborts, the API
    # and MCP stay healthy, and the desktop window renders blank — the failure
    # looks like a VNC problem and is not. Probed per-library on repl-wiki
    # (2026-11-01): of the bundle's libs only libwayland-client breaks the nix
    # mesa EGL stack. install.sh creates .libdirs.pre empty; a non-empty file is
    # an operator override and is never clobbered.
    if [ -n "$pre" ] && [ ! -s "$dest/.libdirs.pre" ]; then
      printf '%s\n' "$pre" >"$dest/.libdirs.pre"
      echo "  llm-wiki: .libdirs.pre <- nix wayland + mesa (the bundle libwayland breaks mesa EGL)"
    fi
    [ -n "$miss" ] && warn "llm-wiki: still unresolved: $miss (add the dir to $dest/.ldpath)"
  fi

  local port; port="$(sed -n 's/^LLM_WIKI_PORT=//p' "$dest/.env" 2>/dev/null | head -1)"
  port="${port:-${LLM_WIKI_PORT:-8319}}"
  cat <<NEXT

  llm-wiki is installed. Start it:
    bash $dest/run-public.sh        # app + REST/MCP server (public :$port, loopback :8199)
    bash $dest/run-ui.sh            # optional: the desktop UI in a browser (noVNC :6800)

  Add this URL to your MCP client:
    http://127.0.0.1:8199/mcp                # loopback, no token (agents on this machine)
    https://<host>:$port/mcp                 # other machines; header Authorization: Bearer <token>

  Token: $dest/.env (chmod 600) — share that file's value when access is needed.
NEXT
}

# Report-only: a user-level setup never installs system packages. Resolve each tool from
# PATH first, then the nix store — on Replit a built package is reachable there even when
# it never made it onto PATH.
_llm_wiki_bin() {
  command -v "$1" >/dev/null 2>&1 && return 0
  # shellcheck disable=SC2086
  ls -d $2 >/dev/null 2>&1
}

llm_wiki_requirements() {
  local missing=()
  command -v node >/dev/null 2>&1 || missing+=("node (>=18 — runs the REST/MCP server)")
  command -v curl >/dev/null 2>&1 || missing+=("curl (fetches the AppImage)")
  _llm_wiki_bin Xvfb '/nix/store/*-xorg-server-*/bin/Xvfb' \
    || missing+=("Xvfb (headless display)")
  { _llm_wiki_bin fluxbox '/nix/store/*fluxbox-*/bin/fluxbox' \
    || _llm_wiki_bin openbox '/nix/store/*openbox-*/bin/openbox'; } \
    || missing+=("a window manager (fluxbox/openbox) — GTK windows stay unmapped without one")
  _llm_wiki_bin x11vnc '/nix/store/*x11vnc-*/bin/x11vnc' \
    || missing+=("x11vnc (only for the noVNC browser view)")
  if ((${#missing[@]})); then
    warn "llm-wiki: missing on this machine —"
    local m
    for m in "${missing[@]}"; do printf '    - %s\n' "$m"; done
    printf '    nix_run build nixpkgs#xorg.xvfb nixpkgs#fluxbox nixpkgs#x11vnc nixpkgs#novnc\n'
    printf '    (or the same names in replit.nix, so they survive a recreate)\n'
  fi
  return 0
}
