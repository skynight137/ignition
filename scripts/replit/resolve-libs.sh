#!/usr/bin/env bash
# resolve-libs.sh — build an LD_LIBRARY_PATH closure for a set of sonames,
# resolving each to its INSTALLED /nix/store path on THIS machine.
#
# WHY THIS EXISTS
#   /nix/store paths embed a content hash that is DIFFERENT on every machine
#   and every nixpkgs revision. Hardcoding a path captured on one box is not
#   portable: the same library lives at ...-nspr-4.34-<hashA>/lib on one host
#   and ...-nspr-4.36-<hashB>/lib on another, and a store GC can drop either.
#   So resolve by SONAME -> nixpkgs attr -> store root at run time, exactly the
#   way the camofox lane resolves its GTK closure (generate-closure.sh). Never
#   copy a literal /nix/store/... path into a doc or a script.
#
# USAGE
#   resolve-libs.sh <out-file> <profile> [<lib> ...]
#   profiles (builtin attr maps): chromium, firefox
#     chromium -> libnspr4.so libnss3.so libnssutil3.so libsmime3.so
#                 libxkbcommon.so.0 libgbm.so.1
#     firefox  -> libgtk-3.so.0 libasound.so.2 libXdamage.so.1
#   With no <lib> args the profile's list is used; explicit libs override.
#
# Resolution order per lib (first hit wins):
#   1. a real file already on the current LD_LIBRARY_PATH that is x86-64
#   2. nix-env user profile ($HOME/.nix-profile/lib/<lib>)
#   3. nixpkgs#<attr> via `nix eval --raw` (pure eval; store must be warm)
# The union of `nix path-info --recursive <root>` for every root is filtered
# (glibc/gcc/base + network/TLS families excluded, so the closure is safe to
# put on a GLOBAL LD_LIBRARY_PATH) and written colon-separated to <out-file>.
#
# Exit 0 and writes the file only when EVERY requested lib is resolvable;
# otherwise exits 1 with the exact missing names (fail loudly, never write a
# partial closure — a half closure makes a browser die mid-load).

set -uo pipefail

OUT="${1:-}"
PROFILE="${2:-}"
shift 2 2>/dev/null || true

[[ -n "$OUT" && -n "$PROFILE" ]] || {
    echo "usage: resolve-libs.sh <out-file> <chromium|firefox> [<lib> ...]" >&2
    exit 2
}

# SONAME -> nixpkgs attr. Add a row when a lane needs another lib.
_lib_attr() {
    case "$1" in
        libnspr4.so)              echo nspr ;;
        libnss3.so|libnssutil3.so|libsmime3.so|libssl3.so) echo nss ;;
        libxkbcommon.so.0)        echo libxkbcommon ;;
        libgbm.so.1)              echo libgbm ;;
        libgtk-3.so.0)            echo gtk3 ;;
        libasound.so.2)           echo alsa-lib ;;
        libXdamage.so.1)          echo xorg.libXdamage ;;
        *)                        echo "" ;;
    esac
}

case "$PROFILE" in
    chromium) DEFAULT_LIBS=(libnspr4.so libnss3.so libnssutil3.so libsmime3.so libxkbcommon.so.0 libgbm.so.1) ;;
    firefox)  DEFAULT_LIBS=(libgtk-3.so.0 libasound.so.2 libXdamage.so.1) ;;
    *) echo "resolve-libs.sh: unknown profile '$PROFILE' (chromium|firefox)" >&2; exit 2 ;;
esac
LIBS=("$@")
((${#LIBS[@]})) || LIBS=("${DEFAULT_LIBS[@]}")

_is_x86_64() { file -L "$1" 2>/dev/null | grep -q 'ELF 64-bit LSB shared object, x86-64'; }

# 1) already resolvable on the current loader path?
_on_ldpath() {
    local lib="$1" d
    local -a _dirs=()
    IFS=':' read -ra _dirs <<< "${LD_LIBRARY_PATH:-}"
    for d in "${_dirs[@]}"; do
        [[ -e "$d/$lib" ]] && _is_x86_64 "$d/$lib" && return 0
    done
    return 1
}

# 2/3) store root for a lib (prints root, or nothing)
_store_root() {
    local lib="$1" attr target root
    attr="$(_lib_attr "$lib")"
    [[ -n "$attr" ]] || return 1
    for pl in "${HOME}/.nix-profile/lib" /nix/var/nix/profiles/default/lib; do
        if [[ -e "$pl/$lib" ]]; then
            target="$(readlink -f "$pl/$lib" 2>/dev/null || true)"
            if [[ "$target" == /nix/store/*/lib/* ]]; then
                root="${target%/lib/*}"; [[ -d "$root" ]] && { printf '%s' "$root"; return 0; }
            fi
        fi
    done
    command -v nix >/dev/null 2>&1 || return 1
    root="$(nix eval --raw "nixpkgs#$attr" 2>/dev/null || true)"
    [[ -n "$root" && -d "$root" ]] && { printf '%s' "$root"; return 0; }
    return 1
}

declare -A paths=()
missing=()
for lib in "${LIBS[@]}"; do
    if _on_ldpath "$lib"; then
        echo "  (already on LD_LIBRARY_PATH) $lib" >&2
        continue
    fi
    root="$(_store_root "$lib")"
    if [[ -z "${root:-}" ]]; then
        # Try resolving the root from the CLOSURE of another requested lib's
        # root later; for now record the miss.
        missing+=("$lib")
        echo "  MISSING  $lib (no $(_lib_attr "$lib") store root in /nix/store)" >&2
        continue
    fi
    echo "  root for $lib: $root" >&2
    while IFS= read -r p; do
        [[ -n "$p" ]] && [[ -d "$p/lib" ]] && paths["$p/lib"]=1
    done < <(nix path-info --recursive "$root" 2>/dev/null || true)
    # A root's own lib/ dir always counts even if nix path-info is unavailable.
    paths["$root/lib"]=1
done

if ((${#missing[@]})); then
    echo "resolve-libs.sh: unresolved: ${missing[*]}" >&2
    echo "  install them, e.g.:  nix-env -iA nixpkgs.nss nixpkgs.nspr nixpkgs.libxkbcommon nixpkgs.mesa" >&2
    exit 1
fi

{
    for p in "${!paths[@]}"; do
        # Exclusions (load-bearing — keep): base-image runtime, and the
        # network/TLS families whose stale nix copies break platform curl.
        case "$p" in
            *glibc*|*gcc*|*libgcc*|*ncurses*|*readline*|*binutils*) continue ;;
            *-openssl-*|*-ngtcp2-*|*-libssh2-*|*-curl-*|*-libidn2-*|*-libpsl-*|*-krb5-*|*-gnutls-*|*-nettle-*|*-libtasn1-*|*-unbound-*|*-libgcrypt-*|*-libgpg-error-*|*-systemd-*|*-systemd-minimal*|*-libcap-*|*-audit-*) continue ;;
        esac
        [[ -d "$p" ]] && printf '%s\n' "$p"
    done
} | sort -u | paste -sd: - > "$OUT"

n=$(tr ':' '\n' < "$OUT" | grep -c .)
echo "resolve-libs.sh: wrote $OUT ($n lib dirs) for $PROFILE" >&2

# sanity: every requested lib must now resolve inside the closure
IFS=':' read -ra dirs < "$OUT"
fail=0
for lib in "${LIBS[@]}"; do
    _on_ldpath "$lib" && continue
    found=0
    for d in "${dirs[@]}"; do [[ -e "$d/$lib" ]] && { found=1; break; }; done
    ((found)) && echo "  ok       $lib" >&2 || { echo "  MISSING  $lib (post-check)" >&2; fail=1; }
done
((fail)) && { echo "resolve-libs.sh: closure incomplete" >&2; exit 1; }
exit 0