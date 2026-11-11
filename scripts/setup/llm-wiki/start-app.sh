#!/usr/bin/env bash
# Launch the LLM Wiki desktop app (already extracted) on an X display.
# Portable by design: every path is discovered or overridable, nothing is required
# to live in /nix/store. Works the same on a Debian/Ubuntu server and on Nix.
#
# Overridable:
#   LLM_WIKI_APP_DIR   extracted AppImage root (default: dir of this script)
#   LLM_WIKI_LIB_DIRS  extra dirs for LD_LIBRARY_PATH, colon separated (prepended)
#   LLM_WIKI_MIME_DIR  dir that contains share/mime (shared-mime-info)
#   LLM_WIKI_DISPLAY   X display (default $DISPLAY, else :99)
#   DISPLAY_EXTRA      set to 1 to keep the display name from the environment as-is
set -uo pipefail
APP="${LLM_WIKI_APP_DIR:-$(cd "$(dirname "$0")" && pwd)}"
BUNDLE="$APP/squashfs-root/usr"
[ -x "$BUNDLE/bin/llm-wiki" ] || { echo "app binary not found: $BUNDLE/bin/llm-wiki" >&2; exit 1; }

# resolve this BEFORE touching LD_LIBRARY_PATH: the nix lib closure below makes some
# coreutils in /usr/bin fail to start (glibc mismatch)
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg-$(id -u 2>/dev/null || echo 0)}"

# --- library path -----------------------------------------------------------
# Anything that exists is added; the bundle's own dir goes LAST so system/bundled
# duplicates resolve to the ones the app shipped with.
LIBS=""
add_lib() { [ -d "$1" ] && LIBS="${LIBS:+$LIBS:}$1"; }
IFS=':' read -r -a EXTRA_LIBS <<<"${LLM_WIKI_LIB_DIRS:-}"
for d in "${EXTRA_LIBS[@]:-}"; do [ -n "$d" ] && add_lib "$d"; done
# a generated closure list for the machine this was set up on, if present
[ -f "$APP/.ldpath" ] && IFS=':' read -r -a LD_ENTRIES <"$APP/.ldpath" && for d in "${LD_ENTRIES[@]}"; do add_lib "$d"; done
# machine-specific dirs that must come BEFORE the bundle (e.g. a working mesa/EGL
# stack, an older libwayland). Absent on a plain server -> system libs are used.
if [ -f "$APP/.libdirs.pre" ]; then
  IFS=':' read -r -a PRE_DIRS <"$APP/.libdirs.pre"
  PRE=""
  for d in "${PRE_DIRS[@]}"; do [ -d "$d" ] && PRE="${PRE:+$PRE:}$d"; done
  [ -n "$PRE" ] && LIBS="${PRE}${LIBS:+:$LIBS}"
fi
# software GL + loader bits that are often packaged separately
for c in \
  "$(command -v glxinfo >/dev/null 2>&1 && dirname "$(dirname "$(command -v glxinfo)")" | sed 's|$|/lib|')" \
  /usr/lib/x86_64-linux-gnu /usr/lib64 /usr/lib; do
  add_lib "$c"
done
export LD_LIBRARY_PATH="${LIBS:+$LIBS:}$BUNDLE/lib"

# --- gdk-pixbuf ------------------------------------------------------------
# Optional on a normal machine (system loaders work); required on stripped bundles
# that ship no PNG loader, which is why this repo may carry pixbuf/loaders.cache.
if [ -f "$APP/pixbuf/loaders.cache" ]; then
  export GDK_PIXBUF_MODULE_FILE="$APP/pixbuf/loaders.cache"
  export LD_LIBRARY_PATH="$APP/pixbuf:$LD_LIBRARY_PATH"
fi

# --- MIME database ---------------------------------------------------------
# gdk-pixbuf picks a loader by MIME-sniffing; without shared-mime-info every image
# is "unrecognized" and GTK aborts on its first stock icon.
MIME_DIR="${LLM_WIKI_MIME_DIR:-}"
for c in "$MIME_DIR" /usr/share /usr/local/share \
         "$(ls -d /nix/store/*-shared-mime-info-*/share 2>/dev/null | head -1)" \
         "$APP/squashfs-root/usr/share"; do
  [ -n "$c" ] && [ -f "$c/mime/magic" ] && { MIME_DIR="$c"; break; }
done
export XDG_DATA_DIRS="${MIME_DIR:+$MIME_DIR:}$APP/squashfs-root/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"

# --- display / toolkit -----------------------------------------------------
export GDK_BACKEND=x11
export DISPLAY="${LLM_WIKI_DISPLAY:-${DISPLAY:-:99}}"
export WEBKIT_DISABLE_COMPOSITING_MODE=1
export WEBKIT_DISABLE_DMABUF_RENDERER=1
export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"
export GALLIUM_DRIVER="${GALLIUM_DRIVER:-llvmpipe}"
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null; chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null

cd "$BUNDLE" || exit 1
exec ./bin/llm-wiki
