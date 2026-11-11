# shellcheck shell=bash
# Environment, paths, mode detection and shared registries. Sourced by setup.sh.
JAVA_HOME="$XDG_DATA_HOME/java"
SDK="$XDG_DATA_HOME/android-sdk"
NODE_DIR="$XDG_DATA_HOME/node"
# Setup's OWN runtime venv: the one interpreter guaranteed to carry tomlkit
# for the .replit writers (rc.sh replit_resolve_py provisions it via uv
# when no candidate python qualifies). Under a setup/ subdir of the data
# home — not a tool home, so no single tool's --clean removes it, and it
# persists with the rest of the toolchain state.
TOML_VENV="$XDG_DATA_HOME/setup/toml-venv"
# npm's ONLY global prefix (where `-g` installs actually land — Replit pins
# this via the inherited env). Captured BEFORE the node-toolchain override
# below so clean_* can uninstall globally-installed packages from the real
# location, not the (possibly empty) $NODE_DIR.
NPM_GLOBAL_PREFIX="${npm_config_prefix:-}"
npm_config_prefix="$NODE_DIR"
# Replit's package firewall rewrites registries to an internal HTTP mirror
# (http://package-firewall.replit.internal/...). npm >= 12 refuses non-https
# URLs, so in-process npm installs (hermes, camofox) fail unless the
# public https registries are forced for THIS run — emit_managed_block() only
# writes them into the emitted rc for future shells.
if [[ "${npm_config_registry:-}" != https://* ]]; then
  export npm_config_registry="https://registry.npmjs.org"
  export NPM_CONFIG_REGISTRY="https://registry.npmjs.org"
  export PIP_INDEX_URL="https://pypi.org/simple"
  export YARN_REGISTRY="https://registry.yarnpkg.com"
  export YARN_NPM_REGISTRY_SERVER="https://registry.yarnpkg.com"
  export GOPROXY="https://proxy.golang.org,direct"
fi
JAVA_TOOL_OPTIONS="$JAVA_TOOL_OPTS_VALUE"

# uv runs its own managed Python: download whatever version a project pins
# (UV_PYTHON_DOWNLOADS=auto) instead of erroring on a missing system one
# (UV_PYTHON_PREFERENCE=managed). PYTHONPATH is emptied so an inherited
# Nix/agent PYTHONPATH (pointing at the read-only store Python) can't poison
# uv's managed interpreter. Defined HERE (not in install_uv) so
# rescue_userenv_keys can carry them forward on runs that skip the installer.
UV_PYTHON_DOWNLOADS="auto"
UV_PYTHON_PREFERENCE="managed"
PYTHONPATH=""

# TLS / CA bundle — the PLATFORM location, /etc/ssl/certs, always. NOT the Nix
# cacert bundle ($SYSTEM_CERTIFICATE_PATH / pkgs.cacert): that bundle carries
# none of the Replit roots (0 Replit-named subjects vs 2 in the system bundle,
# "Replit internal proxy Root CA" and "Replit Localhost Development CA"), so
# wiring it in REPLACES a trust store that knows the proxy with one that does
# not — the public registry still answers 200 while proxied hosts
# (*.replit.dev, connectors) fail, which is painful to attribute. It is also a
# pinned /nix/store path: after a rebuild or GC the variable points at a
# missing file, and a missing SSL_CERT_FILE breaks every TLS client outright.
# curl/node/python all reach the registry with these unset; they are exported
# because tools that ignore the platform default (Node keeps its OWN bundled
# roots) need the Replit roots added — hence NODE_EXTRA_CA_CERTS.
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

ORI_CONFIG_DIR="$XDG_CONFIG_HOME/ori"

# Replit platform sets XDG_CONFIG_HOME=$REPL_HOME/.config, so this
# resolves to REPL_HOME/.config/claude — persistent, survives $HOME wipes.
CLAUDE_CONFIG_DIR="$XDG_CONFIG_HOME/claude"

OPENCODE_CONFIG_DIR="$XDG_CONFIG_HOME/opencode"

HERMES_HOME="${REPL_HOME:-$HOME}/.hermes"
# Hermes' two env vars and the dir that holds the real launcher. All three are
# ordinary wire-registered tool vars/PATH dirs now (the pre-merge layout kept
# them in a separate rc block outside the managed one, which every rewrite then
# had to re-append to keep PATH precedence stable). The launcher dir is the
# ONLY provider of `hermes` / `hermes-acp` on this box: $XDG_BIN_HOME holds just
# the chrome shim, no forwarder, so PATH order cannot pick a different binary.
HERMES_LAUNCHER_DIR="$HERMES_HOME/hermes-agent/.hermes/bin"
# Managed-scope dir: Hermes defaults to /etc/hermes, which on Replit is a
# read-only mount that cannot be created without root, so it is pinned under
# HERMES_HOME. Exported with HERMES_HOME so interactive, gateway and workflow
# shells all resolve the same scope.
HERMES_MANAGED_DIR="$HERMES_HOME/managed"

# zsh interactive shell (oh-my-zsh + powerlevel10k). Binaries come from a
# durable nix profile, the framework and dotfiles from $XDG_DATA_HOME and
# $XDG_CONFIG_HOME/zsh. ZDOTDIR is what lets a bare `zsh` find them: there
# is no $HOME/.zshrc, and $HOME is wiped on recreate.
NIX_PROFILE_DIR="${REPL_HOME:-$HOME}/.local/nix-profiles"
ZSH_PROFILE="$NIX_PROFILE_DIR/zsh"
ZSH_DIR="$XDG_DATA_HOME/oh-my-zsh"
ZSH_DOTDIR="$XDG_CONFIG_HOME/zsh"
export ZDOTDIR="$ZSH_DOTDIR"

OLLAMA_INSTALL_DIR="$XDG_DATA_HOME/ollama"
OLLAMA_MODELS="$OLLAMA_INSTALL_DIR/models"

# tailscale user data (node key + login) — preserved by `--clean tailscale`.
# The binaries themselves live in $XDG_BIN_HOME, like the other direct-download
# tools (see scripts/setup/expose.sh).
# NOT under $HOME: the container wipes $HOME on every restart, so a node key kept
# there re-registers as a NEW node each boot — new 100.x address, new node name, and
# every .ssh/config entry or saved URL pointing at the old one rots. Park the identity
# in the persistent repl workspace (REPL_HOME) instead, and adopt a pre-existing
# $HOME identity once so already-registered boxes keep their address.
RS_PORT="${RS_PORT:-6800}"
TAILSCALE_DATA_DIR="${TAILSCALE_DATA_DIR:-${REPL_HOME:-$HOME/workspace}/.local/share/tailscale}"
# Derived once here and exported by the tools registry (below, and in
# install_tailscale), so no script has to re-spell the socket path and get it wrong.
# Layout follows the fleet XDG pattern (same as the Muse side): daemon STATE
# (the node identity) lives at $XDG_STATE_HOME/tailscale — flat, no /state
# suffix — and the daemon LOG lives with the other workspace logs at
# $REPL_HOME/logs/tailscaled.log. $TAILSCALE_DATA_DIR remains as the legacy
# home: it still holds the identity backup (tailscaled.state.bak) and is the
# first place the migration below looks for a pre-relocation state file.
TAILSCALE_STATE_DIR="${TAILSCALE_STATE_DIR:-${XDG_STATE_HOME:-${REPL_HOME:-$HOME/workspace}/.local/state}/tailscale}"
TAILSCALE_SOCKET="${TAILSCALE_SOCKET:-$TAILSCALE_STATE_DIR/tailscaled.sock}"
TAILSCALE_LOG="${TAILSCALE_LOG:-${REPL_HOME:-$HOME/workspace}/logs/tailscaled.log}"
# Relocation migration: before the XDG layout, the default state dir was
# $TAILSCALE_DATA_DIR/state, and the rc registry has been recording that
# value into every shell since — so a plain ${VAR:-new-default} never
# fires on an installed box (verified on repl-test, 2026-11-05: registry
# value won, no migration). A value that still spells EXACTLY the old
# default is the old default, not an operator choice: re-derive it (and
# the socket spelled from it) to the XDG location. The state file itself
# is adopted by the copy block below, and join stops the legacy daemon
# before starting on the new paths. Any other explicit value is respected.
if [[ "$TAILSCALE_STATE_DIR" == "$TAILSCALE_DATA_DIR/state" ]]; then
  TAILSCALE_STATE_DIR="${XDG_STATE_HOME:-${REPL_HOME:-$HOME/workspace}/.local/state}/tailscale"
fi
if [[ "$TAILSCALE_SOCKET" == "$TAILSCALE_DATA_DIR/state/tailscaled.sock" ]]; then
  TAILSCALE_SOCKET="$TAILSCALE_STATE_DIR/tailscaled.sock"
fi
# Node name asserted at join, empty = leave whatever the console says. Not a registry
# var: which name a machine gets is the operator's choice, pinned per run (args/secret).
TAILSCALE_NODE_NAME="${TAILSCALE_NODE_NAME:-}"
if [[ ! -e "$TAILSCALE_STATE_DIR/tailscaled.state" ]]; then
  for _ts_old in "$TAILSCALE_DATA_DIR/state/tailscaled.state" "$XDG_DATA_HOME/tailscale/state/tailscaled.state" "$HOME/.ts/state.json"; do
    [[ -f "$_ts_old" ]] || continue
    mkdir -p "$TAILSCALE_STATE_DIR"
    if cp -f "$_ts_old" "$TAILSCALE_STATE_DIR/tailscaled.state"; then
      echo "tailscale: adopted node identity from $_ts_old" >&2
    fi
    break
  done
fi

# Tool dirs exported ONCE for child processes — the rest of the script
# uses the values directly (no re-exporting inline in install functions).
ANDROID_HOME="$SDK"
export JAVA_HOME ANDROID_HOME NODE_DIR \
       OPENCODE_CONFIG_DIR \
       CLAUDE_CONFIG_DIR ORI_CONFIG_DIR \
       HERMES_HOME HERMES_MANAGED_DIR OLLAMA_INSTALL_DIR OLLAMA_MODELS

# Make binaries discoverable for the rest of this script run.
# Snapshot the INCOMING PATH first: doctor's "XDG_BIN_HOME on PATH" check
# must test the user's shell wiring, not the PATH this script just built
# (otherwise the export below makes the check self-fulfilling).
_ENTRY_PATH="$PATH"
export PATH="$XDG_BIN_HOME:$JAVA_HOME/bin:$SDK/cmdline-tools/bin:$SDK/platform-tools:$NODE_DIR/bin:$PATH"

# Per-tool registration ─────────────────────────────────────────────────────
# Each install function registers (a) the env vars the tool needs and (b) the
# PATH dirs its binaries live in. [userenv.shared] writers emit ONLY what was
# registered this run — a --node-only install must not resurrect JAVA_HOME or
# JAVA's PATH dirs (the rc lines are inert for missing dirs, but userenv keys
# are not: they shadow whatever the platform env had).
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
# exactly that tool's lines from the managed block (rc + .replit) instead
# of stripping everything.
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
  wire_tool uv UV_PYTHON_DOWNLOADS UV_PYTHON_PREFERENCE PYTHONPATH -- "$XDG_BIN_HOME"
  wire_tool zsh ZDOTDIR -- "$XDG_BIN_HOME"
  wire_tool android JAVA_HOME ANDROID_HOME JAVA_TOOL_OPTIONS -- "$JAVA_HOME/bin" "$SDK/cmdline-tools/bin" "$SDK/platform-tools" "$XDG_BIN_HOME"
  wire_tool node NODE_DIR npm_config_prefix "${_TLS_ENV_VARS[@]}" -- "$NODE_DIR/bin" "$WORKSPACE/node_modules/.bin" "$XDG_BIN_HOME"
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
  wire_tool camofox CAMOUFOX_INSTALL_DIR CAMOFOX_STATE_DIR CAMOFOX_PROFILE_DIR \
    CAMOFOX_COOKIES_DIR CAMOFOX_UPLOADS_DIR CAMOFOX_TRACES_DIR -- "$XDG_BIN_HOME"
  wire_tool lightpanda LIGHTPANDA_HOME LIGHTPANDA_BIN -- "$XDG_BIN_HOME"
  wire_tool hermes-chromium HERMES_CHROME_STATE -- "$XDG_BIN_HOME"
  # Kept in sync with install_hermes_chromium: a --fix run with no staged chrome
  # never calls the installer, so the export has to be re-derived here or the rc
  # block loses it and Hermes' browser starts a chrome without the lib closure.
  if [[ -x "$XDG_BIN_HOME/launch-hermes-chrome" ]]; then
    export AGENT_BROWSER_EXECUTABLE_PATH="$XDG_BIN_HOME/launch-hermes-chrome"
    record_tool_env_vars AGENT_BROWSER_EXECUTABLE_PATH
  fi
}

# State flags ───────────────────────────────────────────────────────────────
INSTALL_ANDROID=false
INSTALL_JAVA=false
INSTALL_NODE=false
INSTALL_OPENCODE=false
INSTALL_OLLAMA=false
INSTALL_CLAUDE=false
INSTALL_HERMES=false
INSTALL_ORI=false
INSTALL_UV=false
INSTALL_RCLONE=false
INSTALL_QBT=false
INSTALL_ARIA2=false
INSTALL_FFMPEG=false
INSTALL_CLOUDFLARED=false
INSTALL_TAILSCALE=false
INSTALL_SSHX=false
INSTALL_JOIN=false
WF=false # --workflow: workflow mode (stream logs to the terminal, keep the job alive)
INSTALL_CAMOFOX=false
INSTALL_LIGHTPANDA=false
INSTALL_MOLI=false
INSTALL_HERMES_CHROMIUM=false
INSTALL_LLM_WIKI=false
INSTALL_ZSH=false
INSTALL_ALL=false
DOCTOR=false
FIX=false
CLEAN=false
LIST_STATE=false
YES=false
# Install failures accumulated by run_install_step (`--all` / multi-tool runs).
# One broken tool must not abort the rest of the run — see run_install_step.
_INSTALL_FAILURES=()
# User-data backups taken by back_up_tool before a destructive clean (--clean).
_BACKUPS_TAKEN=()
# Tools whose removal was refused because their backup failed.
_CLEAN_SKIPPED=()
# Empty means BARE --clean (no target): main() opens the clean menu on a
# terminal and defaults to 'all' when non-interactive. Set to a tool
# name (or 'all') when the user gave an explicit target — skips the menu.
CLEAN_TARGET=""
# Tools ticked in the clean menu (same menu, same "tick to select" behavior as
# install — every item starts UNCHECKED; you tick what to remove). An empty
# selection removes nothing; only explicit `--clean all` strips env wiring.
CLEAN_TOOLS=()
# Which menu the script opens: install (pick tools to install) or clean
# (pick tools to remove). The same menu serves both.
MENU_MODE="install"
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
  # Record what this install created (scripts/setup/root.sh): clean() later sweeps
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
  warn "Re-run just those, e.g.  bash setup.sh --${_INSTALL_FAILURES[0]}"
  return 1
}

# nix exists only in the store on Replit containers (never on PATH), and the shipped
# local-overlay store config points at a root-owned lower dir — /nix/store is the
# writable one. Both traps are invisible to `command -v nix`.
nix_bin() { command -v nix 2>/dev/null || ls -d /nix/store/*-nix-2*/bin/nix 2>/dev/null | tail -1; }
nix_run() {
  local n; n="$(nix_bin)"; [ -n "$n" ] || return 127
  # shellcheck disable=SC2046
  grep -q local-overlay /etc/nix/nix.conf 2>/dev/null && set -- --store /nix/store "$@"
  "$n" "$@"
}
