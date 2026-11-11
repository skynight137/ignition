# shellcheck shell=bash
# core.sh — shared library for BOTH setup entry points (muse + replit).
# Sourced, never executed. Stage S1 of the shared-setup refactor
# (one setup.sh --machine muse|repl): the primitives both setups used
# to carry as private copies live here exactly once. Machine-specific
# flows stay in the profiles; this file holds only what is identical.
#
# Contents: the house logging palette + helpers, need_cmd, the
# SHA256 verifier, and the tailscale channel asset naming. The repl
# setup adopts this file in S1; the muse setup adopts it in S2 when
# its profile is built on the shared modules.

# Logging ─────────────────────────────────────────────────────────────
# House log standard (user, 2026-11-07): every line is
#   [YYYY-MM-DD HH:MM:SS] [LEVEL] message
# so logs diagnose fast and grep clean. COLOUR IS OPT-IN: most logs
# land in files (WS/logs) where ANSI only hurts, so the default is
# plain. A script that loops or prints to a console opts in with a
# --colour argument (honoured anywhere in argv) or SETUP_LOG_COLOUR=1;
# colour then wraps ONLY the [LEVEL] token, by severity (INFO cyan,
# OK green, SKIP dim, WARN bold yellow, ERROR bold red), and the
# message text stays plain so grep keeps working. (This supersedes
# the 2026-11-06 always-on rule.)
COL_GREEN=$'\033[0;32m'
COL_YELLOW=$'\033[1;33m'
COL_RED=$'\033[0;31m'
COL_CYAN=$'\033[0;36m'
COL_DIM=$'\033[2m'
COL_RESET=$'\033[0m'
COL_BOLD=$'\033[1m'
SETUP_LOG_COLOUR="${SETUP_LOG_COLOUR:-0}"
for _core_arg in "$@"; do
  [[ "$_core_arg" == "--colour" ]] && SETUP_LOG_COLOUR=1
done
unset _core_arg
_log() {
  local _lvl="$1" _col="$2"; shift 2
  if [[ "$SETUP_LOG_COLOUR" == 1 ]]; then
    printf '[%s] [%s%s%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$_col" "$_lvl" "$COL_RESET" "$*"
  else
    printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$_lvl" "$*"
  fi
}
step() { _log INFO  "$COL_CYAN"         "$@"; }
ok()   { _log OK    "$COL_GREEN"        "$@"; }
skip() { _log SKIP  "$COL_DIM"          "$@"; }
warn() { _log WARN  "$COL_YELLOW"       "$@" >&2; }
die()  { _log ERROR "$COL_BOLD$COL_RED" "$@" >&2; exit 1; }
# ERROR without exiting — for failures that must be loud (and greppable at
# [ERROR]) but must not kill the run: exit actions run under a trap that
# swallows exit codes, and a mid-cleanup failure must not strand the rest.
err()  { _log ERROR "$COL_BOLD$COL_RED" "$@" >&2; }

need_cmd() { command -v "$1" &>/dev/null || die "'$1' not found and is required to continue"; }
need_cmd_or_install() { need_cmd "$1"; }  # reserved for future auto-install of deps

# Verify a downloaded file's SHA256 against the expected hex digest.
# verify_sha256 <file> <expected-hex-checksum> <label>
# The expected value is the FIRST FIELD of upstream's .sha256 file —
# upstream formats vary ("<sha>  <name>" vs a bare hash), and the
# caller extracts the field; this function only compares.
verify_sha256() {
  local file="$1" expected="$2" label="$3"
  if ! command -v sha256sum >/dev/null 2>&1; then
    warn "sha256sum not found — skipping integrity check for $label"
    return 0
  fi
  local actual
  actual="$(sha256sum "$file" | awk '{print $1}')"
  [[ -n "$expected" ]] || die "$label: no SHA256 obtained from upstream - refusing unverified install"
  if [[ "$actual" != "$expected" ]]; then
    rm -f "$file"
    die "$label checksum mismatch (got $actual, expected $expected) — download may be corrupt"
  fi
  ok "$label verified (SHA256)"
}

# Verify a download against a PINNED size + SHA256 pair recorded in
# a lane (the lightpanda/moli pattern): for upstreams that publish no
# checksum asset, the pin recorded when the version was pinned is the
# reference. Size first (cheap corruption catch), then the digest via
# verify_sha256. A version bump without refreshed pins dies here,
# loudly, by design.
# verify_pinned_asset <file> <expected-size-bytes> <expected-sha256> <label>
verify_pinned_asset() {
  local file="$1" want_size="$2" want_sha="$3" label="$4"
  local got_size
  got_size="$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0)"
  if [[ "$got_size" != "$want_size" ]]; then
    rm -f "$file"
    die "$label size mismatch (got $got_size, expected $want_size) — download may be corrupt, or the version pin moved without refreshing the size/SHA256 pins in its lane"
  fi
  verify_sha256 "$file" "$want_sha" "$label"
}

# Tailscale ───────────────────────────────────────────────────────────
# Channel asset name for a version from the pkgs.tailscale.com index.
tailscale_asset_name() {  # $1 = version from the channel index
  # pkgs.tailscale.com publishes user-local tarballs for Linux only;
  # macOS gets a system-wide .pkg, which this setup never installs.
  [[ "$(uname -s)" == Darwin ]] && die "tailscale: no user-local macOS build upstream (official .pkg is system-wide) — this lane is Linux-only"
  case "$(uname -m)" in
    x86_64|amd64)   echo "tailscale_${1}_amd64.tgz" ;;
    aarch64|arm64)  echo "tailscale_${1}_arm64.tgz" ;;
    *)              die "tailscale: unsupported arch $(uname -m)" ;;
  esac
}
