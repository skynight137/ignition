#!/usr/bin/env bash
# generate-closure.sh — build the curated LD_LIBRARY_PATH.txt closure for
# Camoufox-Firefox on a Nix host (Replit or otherwise).
#
# WHY: Replit's rtld-loader (LD_AUDIT) only searches REPLIT_LD_LIBRARY_PATH,
# which holds the TOP-LEVEL lib dirs of the declared packages (~6) — the
# packages you list in .replit [nix] packages (a root replit.nix is the older
# equivalent form).
# Firefox's GTK3 runtime needs the TRANSITIVE X11 closure (~40+ dirs) — those
# live in dependency stores the loader never sees. This script generates it.
# The generated file is what the camofox launcher consumes
# is unset) from $REPO/LD_LIBRARY_PATH.txt.
#
# RESOLUTION (per package, so the INSTALLED version is always used):
#   1. nix-env profile: if ~/.nix-profile/lib/<lib> exists (manual install),
#      the store root is derived from its symlink target.
#   2. otherwise: resolve via the nixpkgs channel
#      (`nix eval --raw nixpkgs#<attr>`) — a pure eval, needs NO replit.nix
#      file. But the resolved store path must ACTUALLY EXIST in /nix/store:
#      declaring it is not required, the store being WARM is (a prior
#      replit.nix build, nix-env, or the sandbox's own history). On a cold
#      store this script fails loudly (empty closure) and leaves no file.
#   Then: `nix path-info --recursive <root>` gives the full dependency closure;
#   keep every store path that ships a `lib/` dir, and EXCLUDE the
#   base-image-provided families (glibc/gcc/libgcc/ncurses/readline/binutils) —
#   stale nix copies shadow the base's newer libs and break Node itself.
#   2026-10-05 regression proof: a hand-built closure that INCLUDED the nix
#   glibc lib64 dir made `node -e "console.log('ok')"` die instantly with
#   "*** stack smashing detected ***" (any node build, v26.7/v26.10). The
#   exclusion list below is load-bearing, not cosmetic — keep it.
#
# Usage: generate-closure.sh <output-file>
# Requirements: nix (nix-env, or a rebuild of .replit [nix] packages / replit.nix), nixpkgs channel.
# Output: colon-separated `lib` dirs, sorted, single line.

set -euo pipefail

if [[ -n "${1:-}" ]]; then
    OUT="$1"
else
    echo "ERROR: generate-closure.sh needs an output path." >&2
    echo "       setup.sh (--camofox) calls it for you — prefer that entry point." >&2
    exit 2
fi

PROFILE_LIB="${HOME}/.nix-profile/lib"

resolve_root() { # $1 = lib soname ; prints store root path (or nothing)
    local lib="$1" target root
    # 1) manual nix-env install: profile symlink -> store root
    if [[ -e "$PROFILE_LIB/$lib" ]]; then
        target="$(readlink -f "$PROFILE_LIB/$lib" 2>/dev/null || true)"
        if [[ "$target" == /nix/store/*/lib/* ]]; then
            root="${target%/lib/*}"
            [[ -d "$root" ]] && { printf '%s' "$root"; return 0; }
        fi
    fi
    # 2) nixpkgs-channel resolution (works whether the package was declared
    #    in .replit [nix] packages, in replit.nix, or installed via nix-env)
    case "$lib" in
        libgtk-3.so.0)   nix eval --raw "nixpkgs#gtk3" 2>/dev/null ;;
        libasound.so.2)  nix eval --raw "nixpkgs#alsa-lib" 2>/dev/null ;;
        libXdamage.so.1) nix eval --raw "nixpkgs#xorg.libXdamage" 2>/dev/null ;;
    esac
}

declare -A paths=()
declare -a roots=()
for lib in libgtk-3.so.0 libasound.so.2 libXdamage.so.1; do
    root="$(resolve_root "$lib")"
    if [[ -z "${root:-}" ]]; then
        echo "ERROR: no store root for $lib — install gtk3/alsa-lib/xorg.libXdamage" >&2
        echo "       or: nix-env -iA nixpkgs.gtk3 nixpkgs.alsa-lib nixpkgs.xorg.libXdamage" >&2
        exit 1
    fi
    if [[ ! -d "$root" ]]; then
        echo "ERROR: $lib resolved to $root, but that path is NOT in /nix/store." >&2
        echo "       Cold store: nothing has installed the GTK/ALSA/X11 libs yet (no [nix]" >&2
        echo "       packages build, no nix-env). The nixpkgs channel resolves the name; the libs must" >&2
        echo "       actually exist in the store. Fix (one of):" >&2
        echo "         replit.nix (workspace root)  deps = [ pkgs.gtk3 pkgs.alsa-lib pkgs.xorg.libXdamage ]  # setup.sh --camofox writes this for you; wait for rebuild" >&2
        echo "         .replit  [nix] packages = [\"gtk3\", \"alsa-lib\", \"xorg.libXdamage\"]  # alternate lane" >&2
        echo "         nix-env -iA nixpkgs.gtk3 nixpkgs.alsa-lib nixpkgs.xorg.libXdamage" >&2
        exit 1
    fi
    roots+=("$root")
    echo "root for $lib: $root" >&2
    while IFS= read -r p; do
        [[ -n "$p" ]] && paths["$p"]=1
    done < <(nix path-info --recursive "$root" 2>/dev/null)
done

echo "closure paths: ${#paths[@]}" >&2

{
    for p in "${!paths[@]}"; do
        # Two exclusion families:
        #  1) base-image-provided runtime (glibc/gcc/libgcc/ncurses/readline/
        #     binutils) — stale nix copies shadow the base's newer libs.
        #  2) NETWORK/TLS families — a nix libssl/libcurl on LD_LIBRARY_PATH
        #     collides with the platform's openssl 3.5 (curl dies with
        #     "symbol lookup error: curl_multi_notify_enable" / openssl version
        #     mismatch) and can pull in stale systemd/krb5. Firefox needs none of
        #     these here. Excluding them makes the closure GLOBALLY safe to put
        #     on LD_LIBRARY_PATH (interactive shells + every tool), so camofox
        #     can simply be `camofox-browser` with no per-process wrapper.
        case "$p" in
            *glibc*|*gcc*|*libgcc*|*ncurses*|*readline*|*binutils*) continue ;;
            *-openssl-*|*-ngtcp2-*|*-libssh2-*|*-curl-*|*-libidn2-*|*-libpsl-*|*-krb5-*|*-gnutls-*|*-nettle-*|*-libtasn1-*|*-unbound-*|*-libgcrypt-*|*-libgpg-error-*|*-systemd-*|*-systemd-minimal*|*-libcap-*|*-audit-*) continue ;;
        esac
        [[ -d "$p/lib" ]] && printf '%s\n' "$p/lib"
    done
} | sort -u | paste -sd: - > "$OUT"
n=$(tr ':' '\n' < "$OUT" | grep -c .)
echo "Wrote $OUT with $n lib dirs" >&2

# Prepend the base node's own linked store dirs to the FRONT of the closure.
# Why: node (and anything else it links — sqlite, nghttp2, brotli, ...) will
# resolve those sonames to the CLOSURE's older copies (e.g. gtk3-3.24.30's
# sqlite-3.35.5 / nghttp2-1.44.x) and die with "undefined symbol: ...". The
# base system's own copies are what node was built against, so they must win.
# Firefox is unaffected: it only needs the X11/GTK libs from the tail, and any
# lib it shares with node (zlib, icu, ...) resolves to the base's NEWER copy,
# which is soname-compatible.
node_dirs=""
node_bin="$(command -v node || true)"
if [[ -n "$node_bin" ]]; then
    if [[ "$(head -c4 "$node_bin" 2>/dev/null | od -An -tx1 | tr -d ' \n')" != "7f454c46" ]]; then
        node_bin="$(grep -oE '/nix/store/[^ "]*nodejs-[^ "]*' "$node_bin" 2>/dev/null | head -1 || true)"
    fi
    if [[ -x "$node_bin" ]]; then
        # `|| node_dirs=""`: with a managed (tarball) node, ldd shows NO
        # /nix/store paths, the grep -vE selects nothing and exits 1, and
        # pipefail + set -e then killed the script here — after the closure
        # file was written, so callers reported a spurious failure and the
        # sanity check below never ran (verified live on repl-test,
        # 2026-11-05, after the read-EOF fix exposed this next failure).
        node_dirs="$(ldd "$node_bin" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i ~ /^\/nix\/store\//) print $i}' \
            | xargs -r -n1 dirname 2>/dev/null \
            | grep -vE '(^|/)libg?c\.so|glibc|libgcc' \
            | sort -u | paste -sd: -)" || node_dirs=""
    fi
fi
if [[ -n "$node_dirs" ]]; then
    pre_n="$(tr ':' '\n' <<< "$node_dirs" | grep -c .)"
    printf '%s:%s' "$node_dirs" "$(cat "$OUT")" > "$OUT"
    echo "prepended $pre_n node-linked dirs to front" >&2
fi

# sanity: the critical libs must be resolvable inside the closure
# (`|| true`: the closure file is one line with NO trailing newline, so
# `read` hits EOF and returns 1 even though it filled the array — under
# `set -e` that killed the script here, after the file was written, and
# callers reported a spurious "closure generation failed". Verified live
# on repl-test 2026-11-05: file written, exit code 1, sanity never ran.)
IFS=':' read -ra dirs < "$OUT" || true
for lib in libgtk-3.so.0 libXdamage.so.1 libasound.so.2 libX11-xcb.so.1; do
    ok=0
    for d in "${dirs[@]}"; do
        [[ -e "$d/$lib" ]] && { ok=1; break; }
    done
    if ((ok)); then echo "  ok       $lib" >&2; else echo "  MISSING  $lib" >&2; fi
done
