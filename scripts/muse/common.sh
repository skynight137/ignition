# shellcheck shell=bash
# Muse-side environment, paths, mode detection and shared registries.
# Sourced by profile-muse.sh — the muse counterpart of scripts/replit/common.sh.
# Same var names, HOME-based values; no Replit-only content (no package-firewall
# registry overrides, no Nix, no [userenv.shared], no workflow shim).
#
# Source order (profile-muse.sh): XDG defaults + REPLIT_MODE=false + BASHRC
# + _PRESET_ENV snapshot are set BEFORE this file, so the defs below honor a
# pre-set value and otherwise fall back under $HOME. INSTALL_* flags use
# `:-` defaults so the arg parser (which runs before this file is sourced)
# can set them first.

# Tool dirs ─────────────────────────────────────────────────────────────────
NODE_DIR="${NODE_DIR:-$XDG_DATA_HOME/node}"
# npm's ONLY global prefix (where `-g` installs actually land). Captured
# BEFORE the node-toolchain override below so clean_* can uninstall
# globally-installed packages from the real location, not the (possibly
# empty) $NODE_DIR.
NPM_GLOBAL_PREFIX="${NPM_GLOBAL_PREFIX:-${npm_config_prefix:-}}"
npm_config_prefix="$NODE_DIR"

# TLS / CA bundle — the system location, /etc/ssl/certs, always.
# curl/node/python all reach the registry with these unset; they are exported
# because tools that ignore the platform default (Node keeps its OWN bundled
# roots) need the system roots added — hence NODE_EXTRA_CA_CERTS.
# The guard is the bundle itself, so nothing is ever exported as a dead path.
_TLS_ENV_VARS=()
if [[ -r /etc/ssl/certs/ca-certificates.crt ]]; then
  SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
  SSL_CERT_DIR=/etc/ssl/certs
  NODE_EXTRA_CA_CERTS="$SSL_CERT_FILE"
  REQUESTS_CA_BUNDLE="$SSL_CERT_FILE"
  # git, the AWS SDKs and requests each read their OWN variable name and do
  # not fall back to SSL_CERT_FILE — point all three at the same bundle.
  GIT_SSL_CAINFO="$SSL_CERT_FILE"
  AWS_CA_BUNDLE="$SSL_CERT_FILE"
  export SSL_CERT_FILE SSL_CERT_DIR NODE_EXTRA_CA_CERTS REQUESTS_CA_BUNDLE GIT_SSL_CAINFO AWS_CA_BUNDLE
  _TLS_ENV_VARS=(SSL_CERT_FILE SSL_CERT_DIR NODE_EXTRA_CA_CERTS REQUESTS_CA_BUNDLE GIT_SSL_CAINFO AWS_CA_BUNDLE)
fi

ORI_CONFIG_DIR="${ORI_CONFIG_DIR:-$XDG_CONFIG_HOME/ori}"
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$XDG_CONFIG_HOME/claude}"
OPENCODE_CONFIG_DIR="${OPENCODE_CONFIG_DIR:-$XDG_CONFIG_HOME/opencode}"

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
# Hermes' two env vars and the dir that holds the real launcher. All three are
# ordinary wire-registered tool vars/PATH dirs now. The launcher dir is the
# ONLY provider of `hermes` / `hermes-acp` on this box.
HERMES_LAUNCHER_DIR="${HERMES_LAUNCHER_DIR:-$HERMES_HOME/hermes-agent/.hermes/bin}"
# Managed-scope dir: Hermes defaults to /etc/hermes, which cannot be created
# without root, so it is pinned under HERMES_HOME.
HERMES_MANAGED_DIR="${HERMES_MANAGED_DIR:-$HERMES_HOME/managed}"

OLLAMA_INSTALL_DIR="${OLLAMA_INSTALL_DIR:-$XDG_DATA_HOME/ollama}"
OLLAMA_MODELS="${OLLAMA_MODELS:-$OLLAMA_INSTALL_DIR/models}"

# tailscale user data (node key + login) — preserved by `--clean tailscale`.
# The binaries themselves live in $XDG_BIN_HOME, like the other direct-download
# tools (see scripts/setup/tailscale.sh).
# Defaults here are the XDG layout; profile-muse.sh re-assigns STATE_DIR /
# SOCKET / LOG from its own resolved TSDIR / LOGDIR after sourcing this file
# (the state file IS the node's identity, and the profile owns that
# resolution, including the legacy-workspace adoption — so no adoption block
# lives here).
TAILSCALE_DATA_DIR="${TAILSCALE_DATA_DIR:-$HOME/.local/share/tailscale}"
TAILSCALE_STATE_DIR="${TAILSCALE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/tailscale}"
TAILSCALE_SOCKET="${TAILSCALE_SOCKET:-$TAILSCALE_STATE_DIR/tailscaled.sock}"
TAILSCALE_LOG="${TAILSCALE_LOG:-$HOME/workspace/logs/tailscaled.log}"
# Node name asserted at join, empty = leave whatever the console says. Not a registry
# var: which name a machine gets is the operator's choice, pinned per run (args/secret).
TAILSCALE_NODE_NAME="${TAILSCALE_NODE_NAME:-}"

# Tool dirs exported ONCE for child processes — the rest of the script
# uses the values directly (no re-exporting inline in install functions).
export NODE_DIR \
       OPENCODE_CONFIG_DIR \
       CLAUDE_CONFIG_DIR ORI_CONFIG_DIR \
       HERMES_HOME HERMES_MANAGED_DIR OLLAMA_INSTALL_DIR OLLAMA_MODELS

# Make binaries discoverable for the rest of this script run.
# Snapshot the INCOMING PATH first: doctor's "XDG_BIN_HOME on PATH" check
# must test the user's shell wiring, not the PATH this script just built
# (otherwise the export below makes the check self-fulfilling).
_ENTRY_PATH="$PATH"
export PATH="$XDG_BIN_HOME:$NODE_DIR/bin:$PATH"

# Per-tool registration ─────────────────────────────────────────────────────
# Each install function registers (a) the env vars the tool needs and (b) the
# PATH dirs its binaries live in. The rc writer emits ONLY what was
# registered this run — a --node-only install must not resurrect vars from
# tools that were not installed.
_TOOL_ENV_VARS=()
_TOOL_PATH_DIRS=()
# Installers run inside run_install_step's SUBSHELL, so an array append there
# dies with the subshell. Mirror every registration into a spill file (which a
# subshell CAN write) and fold it back after the install loop — this is what
# keeps an installer's declared wiring from being silently dropped.
_TOOL_WIRING_SPILL="${_TOOL_WIRING_SPILL:-$(mktemp)}"
export _TOOL_WIRING_SPILL
_load_wiring_add() {  # $1=E|P  $2=name  (no spill write; used by the load pass)
  case "$1" in
    E) [[ " ${_TOOL_ENV_VARS[*]-} " == *" $2 "* ]] || _TOOL_ENV_VARS+=("$2") ;;
    P) [[ " ${_TOOL_PATH_DIRS[*]-} " == *" $2 "* ]] || _TOOL_PATH_DIRS+=("$2") ;;
  esac
}
record_tool_env_vars() {
  # Idempotent: the same var can register twice (installer AND fix_derive_wiring,
  # or two installers sharing one), which would emit the export twice.
  local v
  for v in "$@"; do
    _load_wiring_add E "$v"
    [[ -n "${_TOOL_WIRING_SPILL:-}" ]] && printf 'E %s\n' "$v" >> "$_TOOL_WIRING_SPILL"
  done
}
record_tool_path_dirs() {
  local d
  for d in "$@"; do
    _load_wiring_add P "$d"
    [[ -n "${_TOOL_WIRING_SPILL:-}" ]] && printf 'P %s\n' "$d" >> "$_TOOL_WIRING_SPILL"
  done
}
load_wiring_spill() {  # fold in registrations made in installer subshells
  [[ -s "${_TOOL_WIRING_SPILL:-}" ]] || return 0
  local kind val
  while IFS=' ' read -r kind val; do
    [[ -n "$val" ]] && _load_wiring_add "$kind" "$val"
  done < "$_TOOL_WIRING_SPILL"
  : > "$_TOOL_WIRING_SPILL"   # consumed; later appends start clean
}

# Per-tool OWNERSHIP wiring: each install function declares which env
# vars and PATH dirs belong to it, so per-tool `--clean <tool>` can drop
# exactly that tool's lines from the managed block instead of stripping
# everything.
declare -A -A _WIRE_OWNER=()
wire_tool() {
  local tool="$1"; shift
  local item
  for item in "$@"; do
    if [[ "$item" == "--" ]]; then in_dirs=true; continue; fi
    [[ -n "${_WIRE_OWNER[$item]:-}" ]] && _WIRE_OWNER["$item"]+="," || true
    _WIRE_OWNER["$item"]+="$tool"
  done
}
env_var_owner()  { printf '%s' "${_WIRE_OWNER[$1]:-}"; }
path_dir_owner() { printf '%s' "${_WIRE_OWNER[$1]:-}"; }
owned_only_by(){
  # True when EVERY owner in comma-joined $1 appears in space-joined $2.
  # Empty owner list -> false (unregistered lines are always kept).
  local owners cleaned it
  owners="${1//,/ }"
  [[ -n "${owners// /}" ]] || return 1
  cleaned=" $2 "
  for it in $owners; do
    [[ "$cleaned" == *" $it "* ]] || return 1
  done
  return 0
}

seed_tool_wiring(){
  # Static ownership registrations (mirrors the wire_tool calls in the
  # install functions) so --clean can resolve line owners without
  # running an installer. wire_tool is an idempotent map assignment.
  wire_tool node NODE_DIR npm_config_prefix "${_TLS_ENV_VARS[@]}" -- "$NODE_DIR/bin" "$XDG_BIN_HOME"
  wire_tool opencode OPENCODE_CONFIG_DIR -- "$XDG_BIN_HOME"
  wire_tool ollama OLLAMA_INSTALL_DIR OLLAMA_MODELS -- "$XDG_BIN_HOME"
  wire_tool claude CLAUDE_CONFIG_DIR -- "$XDG_BIN_HOME"
  wire_tool hermes HERMES_HOME HERMES_MANAGED_DIR -- "$HERMES_LAUNCHER_DIR"
  wire_tool ori ORI_CONFIG_DIR -- "$XDG_BIN_HOME"
  wire_tool rclone -- "$XDG_BIN_HOME"
  wire_tool qbt -- "$XDG_BIN_HOME"
  wire_tool aria2 -- "$XDG_BIN_HOME"
  wire_tool ffmpeg -- "$XDG_BIN_HOME"
  wire_tool cloudflared -- "$XDG_BIN_HOME"
  wire_tool tailscale TAILSCALE_DATA_DIR TAILSCALE_STATE_DIR TAILSCALE_SOCKET TAILSCALE_LOG -- "$XDG_BIN_HOME"
  wire_tool sshx -- "$XDG_BIN_HOME"
}

# State flags ───────────────────────────────────────────────────────────────
# `:-` defaults (not plain assignments): profile-muse.sh's arg parser runs
# BEFORE this file is sourced and sets the flags it was given; a plain
# `INSTALL_NODE=false` here would reset them.
INSTALL_NODE="${INSTALL_NODE:-false}"
INSTALL_UV="${INSTALL_UV:-false}"
INSTALL_OPENCODE="${INSTALL_OPENCODE:-false}"
INSTALL_OLLAMA="${INSTALL_OLLAMA:-false}"
INSTALL_CLAUDE="${INSTALL_CLAUDE:-false}"
INSTALL_HERMES="${INSTALL_HERMES:-false}"
INSTALL_ORI="${INSTALL_ORI:-false}"
INSTALL_RCLONE="${INSTALL_RCLONE:-false}"
INSTALL_QBT="${INSTALL_QBT:-false}"
INSTALL_ARIA2="${INSTALL_ARIA2:-false}"
INSTALL_FFMPEG="${INSTALL_FFMPEG:-false}"
INSTALL_CLOUDFLARED="${INSTALL_CLOUDFLARED:-false}"
INSTALL_TAILSCALE="${INSTALL_TAILSCALE:-false}"
INSTALL_SSHX="${INSTALL_SSHX:-false}"
INSTALL_LLM_WIKI="${INSTALL_LLM_WIKI:-false}"
INSTALL_ALL="${INSTALL_ALL:-false}"
DOCTOR="${DOCTOR:-false}"
# Install failures accumulated by run_install_step (multi-tool runs).
# One broken tool must not abort the rest of the run — see run_install_step.
_INSTALL_FAILURES=()
# Exit trap accumulator — multiple functions register cleanup actions
# without overwriting each other's traps.
_EXIT_ACTIONS=()
add_exit_action() { _EXIT_ACTIONS+=("$1"); }
_run_exit_actions() {
  local rc=$?
  local action
  for action in "${_EXIT_ACTIONS[@]}"; do
    eval "$action" || true
  done
  exit $rc
}
trap '_run_exit_actions' EXIT

# Install manifest (muse) ───────────────────────────────────────────────────
# The canonical payload paths each tool's installer creates, mirroring what
# its clean_<tool> removes (user data a clean preserves — ollama models,
# hermes state — is NOT recorded, so a sweep can never take it). Called by
# run_install_step after a successful install. tailscale is deliberately
# absent: its state is a live daemon + node identity, owned by
# clean_tailscale's own explicit logic, not by a path list.
MUSE_MANIFEST_DIR="${MUSE_MANIFEST_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/muse-setup}"
MUSE_MANIFEST="${MUSE_MANIFEST:-$MUSE_MANIFEST_DIR/manifest.tsv}"
manifest_record() {  # $1=label, rest=paths
  local label="$1"; shift
  mkdir -p "$MUSE_MANIFEST_DIR" 2>/dev/null || return 0
  local p
  for p in "$@"; do
    [[ -n "$p" ]] || continue
    printf '%s\t%s\n' "$label" "$p" >> "$MUSE_MANIFEST"
  done
}
manifest_record_for() {  # $1=install-step label (same table as root.sh)
  case "$1" in
    node)    manifest_record node "$NODE_DIR" ;;
    opencode) manifest_record opencode "$XDG_BIN_HOME/opencode" "$OPENCODE_CONFIG_DIR" ;;
    ollama)  manifest_record ollama "$OLLAMA_INSTALL_DIR" "$XDG_BIN_HOME/ollama" ;;
    claude)  manifest_record claude "$XDG_BIN_HOME/claude" ;;
    hermes)  manifest_record hermes "$HERMES_HOME" ;;
    ori)     manifest_record ori "$XDG_BIN_HOME/ori" ;;
    rclone)  manifest_record rclone "$XDG_BIN_HOME/rclone" ;;
    qbt)     manifest_record qbt "$XDG_BIN_HOME/qbittorrent-nox" ;;
    aria2)   manifest_record aria2 "$XDG_BIN_HOME/aria2c" ;;
    ffmpeg)  manifest_record ffmpeg "$XDG_BIN_HOME/ffmpeg" "$XDG_BIN_HOME/ffprobe" "$XDG_BIN_HOME/ffplay" ;;
    cloudflared) manifest_record cloudflared "$XDG_BIN_HOME/cloudflared" ;;
    sshx)    manifest_record sshx "$XDG_BIN_HOME/sshx" ;;
    llm-wiki) manifest_record llm-wiki "${LLM_WIKI_HOME:-${REPL_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}}/llmwiki-app}" ;;
    *) : ;;
  esac
}

# Per-tool isolation ─────────────────────────────────────────────────────────
# installers call `die` on failure, and `die` exits the whole script. Under
# `--all` / multi-tool runs one broken tool (bad download, missing upstream
# asset, …) must NOT abort the rest: run_install_step runs each installer in
# its own errexit subshell, catches the failure and records it, then the run
# carries on to the next tool. The summary + exit code reflect what failed.
#
# A subshell inherits the parent EXIT trap; the trap is cleared inside so a
# failing installer's `exit 1` cannot run the parent's exit actions early.
run_install_step() {
  local label="$1"; shift
  local rc=0
  set +e
  ( trap - EXIT; set -e; "$@" )
  rc=$?
  set -e
  if (( rc != 0 )); then
    warn "$label failed (exit $rc) — continuing with the remaining tools"
    _INSTALL_FAILURES+=("$label")
    return 0
  fi
  # Record what this install created (above): clean() later sweeps
  # exactly these paths instead of only re-deriving them.
  manifest_record_for "$label"
  return 0
}

# Summary + exit status for a multi-tool install run. Reuses the same
# wording doctor uses (missing tools are an install-scope fact, not a wiring
# bug) and returns 1 when anything failed so scripts can gate on it.
install_fail_summary() {
  ((${#_INSTALL_FAILURES[@]})) || return 0
  echo ""
  warn "Some tools did NOT install: ${_INSTALL_FAILURES[*]}"
  warn "Re-run just those, e.g.  bash setup.sh --machine muse --${_INSTALL_FAILURES[0]}"
  return 1
}

# Muse tool dispatcher ──────────────────────────────────────────────────────
# The muse counterpart of cli.sh main()'s install portion: no interactive
# menu (profile-muse.sh has its own phase picker), no --clean/--fix (not
# implemented for muse yet), no replit writers (write_replit_env /
# write_replit_bashrc early-return when REPLIT_MODE != true, so only
# write_bashrc is registered here). ensure_libatomic is NOT called: it
# scans the Replit /nix/store lib pool — on muse the node tarball loads
# against the system libatomic and the probe in install_node is the gate.
any_tool_requested() {
  [[ "${INSTALL_ALL:-false}" == true ]] && return 0
  [[ "${INSTALL_NODE:-false}" == true ]] && return 0
  [[ "${INSTALL_OPENCODE:-false}" == true ]] && return 0
  [[ "${INSTALL_OLLAMA:-false}" == true ]] && return 0
  [[ "${INSTALL_CLAUDE:-false}" == true ]] && return 0
  [[ "${INSTALL_HERMES:-false}" == true ]] && return 0
  [[ "${INSTALL_ORI:-false}" == true ]] && return 0
  [[ "${INSTALL_RCLONE:-false}" == true ]] && return 0
  [[ "${INSTALL_QBT:-false}" == true ]] && return 0
  [[ "${INSTALL_ARIA2:-false}" == true ]] && return 0
  [[ "${INSTALL_FFMPEG:-false}" == true ]] && return 0
  [[ "${INSTALL_CLOUDFLARED:-false}" == true ]] && return 0
  [[ "${INSTALL_TAILSCALE:-false}" == true ]] && return 0
  [[ "${INSTALL_SSHX:-false}" == true ]] && return 0
  [[ "${INSTALL_LLM_WIKI:-false}" == true ]] && return 0
  [[ "${DOCTOR:-false}" == true ]] && return 0
  return 1
}

muse_main() {
  if [[ "${INSTALL_ALL:-false}" == true ]]; then
    INSTALL_NODE=true; INSTALL_OPENCODE=true; INSTALL_OLLAMA=true; INSTALL_CLAUDE=true
    INSTALL_HERMES=true; INSTALL_ORI=true; INSTALL_RCLONE=true; INSTALL_QBT=true
    INSTALL_ARIA2=true; INSTALL_FFMPEG=true; INSTALL_CLOUDFLARED=true; INSTALL_TAILSCALE=true
    INSTALL_SSHX=true
  fi
  local _any_install=false
  [[ "${INSTALL_NODE:-false}" == true ]] && _any_install=true
  [[ "${INSTALL_OPENCODE:-false}" == true ]] && _any_install=true
  [[ "${INSTALL_OLLAMA:-false}" == true ]] && _any_install=true
  [[ "${INSTALL_CLAUDE:-false}" == true ]] && _any_install=true
  [[ "${INSTALL_HERMES:-false}" == true ]] && _any_install=true
  [[ "${INSTALL_ORI:-false}" == true ]] && _any_install=true
  [[ "${INSTALL_RCLONE:-false}" == true ]] && _any_install=true
  [[ "${INSTALL_QBT:-false}" == true ]] && _any_install=true
  [[ "${INSTALL_ARIA2:-false}" == true ]] && _any_install=true
  [[ "${INSTALL_FFMPEG:-false}" == true ]] && _any_install=true
  [[ "${INSTALL_CLOUDFLARED:-false}" == true ]] && _any_install=true
  [[ "${INSTALL_TAILSCALE:-false}" == true ]] && _any_install=true
  [[ "${INSTALL_SSHX:-false}" == true ]] && _any_install=true

  # Always (re)wire the shell environment on exit — even if an install step
  # fails, the toolchain portions that succeeded remain usable in new shells.
  add_exit_action 'write_bashrc'

  mkdir -p "$XDG_BIN_HOME" "$XDG_DATA_HOME"

  # Each tool runs in its own errored-but-isolated step (run_install_step):
  # one broken installer no longer aborts the rest of the run. A failure is
  # reported, collected and re-surfaced in the summary.
  $INSTALL_UV       && run_install_step uv                 install_uv
  $INSTALL_NODE     && run_install_step node               install_node
  $INSTALL_OPENCODE && run_install_step opencode           install_opencode
  $INSTALL_OLLAMA   && run_install_step ollama             install_ollama
  $INSTALL_CLAUDE   && run_install_step claude             install_claude
  $INSTALL_HERMES   && run_install_step hermes             install_hermes
  $INSTALL_ORI      && run_install_step ori                install_ori
  $INSTALL_RCLONE   && run_install_step rclone             install_rclone
  $INSTALL_QBT      && run_install_step qbt                install_qbt
  $INSTALL_ARIA2    && run_install_step aria2              install_aria2
  $INSTALL_FFMPEG   && run_install_step ffmpeg             install_ffmpeg
  $INSTALL_CLOUDFLARED && run_install_step cloudflared      install_cloudflared
  $INSTALL_TAILSCALE && run_install_step tailscale         install_tailscale
  $INSTALL_SSHX     && run_install_step sshx               install_sshx
  $INSTALL_LLM_WIKI && run_install_step llm-wiki           install_llm_wiki

  # Fold in wiring registered inside the installers' subshells (spill file).
  load_wiring_spill

  if [[ "${DOCTOR:-false}" == true ]]; then
    doctor || true
  fi

  if $_any_install; then
    cat <<SUMMARY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 Setup complete! (muse — \$HOME layout)

 Toolchain lives in:
   binaries  $XDG_BIN_HOME
   payload   $XDG_DATA_HOME
   workspace $WORKSPACE
 Shell env written to: $BASHRC
   (minimal PATH block — open a new shell)

 Run directly, no sourcing needed:
   node --version
   opencode  ollama  claude  hermes  ori
   rclone  qbittorrent-nox  aria2c  ffmpeg  ffprobe
   cloudflared  tailscale  sshx
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SUMMARY
  fi

  # Report (and fail on) tools that did not install. Run as the LAST step so
  # the exit actions (rc writer) still fire on a partial run, and non-zero so
  # automation can tell a complete install from a partial one.
  install_fail_summary || return 1
}
