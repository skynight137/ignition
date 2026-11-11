#!/usr/bin/env bash
# Heal the durable lib pool at $POOL (default $REPL_HOME/.local/lib).
#
# The pool's ONLY job is libs the dynamic loader cannot find ANY OTHER WAY —
# today that means the staged libatomic.so.1 (official Node >= 22 tarballs;
# staged by setup.sh ensure_libatomic). Everything else a consumer needs is
# already reachable by that consumer: nix binaries resolve their own deps via
# RUNPATH, and camoufox's GTK stack arrives per-process via the closure dir
# list the camofox launcher exports for the server.
#
# Why host-wide closure pooling was REMOVED (pre-4.6.0 behavior): glibc's
# search order puts LD_LIBRARY_PATH ABOVE RUNPATH, so any pooled SONAME
# shadows the exact build each nix binary links against. Pooling the camoufox
# closure's openssl-3.4.1 + libcurl-8.14.1 symlinks broke the platform's
# curl (8.22) with "version OPENSSL_3.5.0 not found", then with "undefined
# symbol curl_multi_notify_enable" — setup.sh --node could no longer download
# Node. A host-wide pool must be STRICTLY ADDITIVE: only SONAMEs found
# nowhere else may live there. (A dlopen-based filter does not save pooling:
# resolvability is per-binary via RUNPATH, not global.)
#
# Usage: bash libpool.sh   (idempotent; the camofox launcher calls it
# so machines upgrading across the behavior change self-heal once.)
#
# Rules:
#  - deletes ONLY symlinks pointing into /nix/store — leftover closure links
#    from older versions sweep away on the next run. Real files (the
#    libatomic.so.1.2.0 copy) are never touched; the libatomic.so.1 SONAME
#    link points RELATIVELY so it survives its own sweep.
#  - recreates SONAME links (libX.so.N -> libX.so.N.m.p) for the pool's own
#    real files, so a store GC dangling-pref companion link heals without
#    re-staging (node: error while loading shared libraries: libatomic.so.1).
set -uo pipefail
REPL="${REPL_HOME:-/home/runner/workspace}"
POOL="${POOL:-$REPL/.local/lib}"
mkdir -p "$POOL"

swept=$(find "$POOL" -maxdepth 1 -type l -lname '/nix/store/*' -print -delete | wc -l)

healed=0
for real in "$POOL"/lib*.so.[0-9]*; do
    [[ -f "$real" && ! -L "$real" ]] || continue
    base=$(basename "$real")
    # libatomic.so.1.2.0 -> libatomic.so.1 (strip everything after the major)
    stem=${base%%.so.*}
    ver=${base#*.so.}
    soname="$stem.so.${ver%%.*}"
    [[ "$soname" == "$base" ]] && continue
    link="$POOL/$soname"
    if [[ ! -e "$link" && ! -L "$link" ]]; then
        ln -s "$base" "$link" && healed=$((healed+1))
    fi
done
echo "libpool: swept $swept closure links (host-wide pooling deprecated), self-healed $healed SONAME links (pool now has $(find "$POOL" -maxdepth 1 \( -type l -o -type f \) | wc -l) entries)"
