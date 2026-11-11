# shellcheck shell=bash
# Binary symlinking + parallel-job helpers. Sourced by setup.sh.
# Symlink tool binaries into XDG_BIN_HOME — a single PATH entry covers everything.
# Usage: symlink_bins <target_dir> <binary1> [binary2 ...]
symlink_bins() {
  local target_dir="$1"; shift
  local bin
  for bin in "$@"; do
    if [[ -f "$target_dir/$bin" ]]; then
      ln -sfn "$target_dir/$bin" "$XDG_BIN_HOME/$bin"
    fi
  done
}

wait_for_jobs() {
  local context="$1"; shift
  local failed=0
  local pid
  for pid in "$@"; do
    if ! wait "$pid"; then
      failed=1
    fi
  done
  (( failed != 0 )) && die "$context failed"
  return 0
}

# verify_sha256 lives in scripts/setup/core.sh (shared library).
