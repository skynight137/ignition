#!/usr/bin/env bash
# setup.sh

set -e

# The payloads use bash 4+ features (associative arrays). Fail loudly
# here instead of dying mid-run with a cryptic declare error — stock
# macOS ships bash 3.2 (on a Mac: brew install bash, then re-run).
if (( BASH_VERSINFO[0] < 4 )); then
  printf 'setup: bash >= 4 required (this is %s)\n' "$BASH_VERSION" >&2
  exit 1
fi

# Absolute path of this script's directory (scripts/setup/ — the
# profile, the shared modules and every lane live here since S5c).
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Location map after the S5c move (this profile lives in scripts/setup/
# and so do ALL the setup lanes now — the tree is shared, the machine
# kind is --machine, not a directory):
SETUP_LIB_DIR="$SCRIPT_DIR"               # scripts/setup — core.sh, join.sh (engine), profiles, every lane
# scripts/replit — REPL-ONLY payloads: the runtime files a repl box
# executes (dotreplit.py, the probes, the chromium
# launcher) plus the nix machinery the lanes invoke (nixenv,
# resolve-libs.sh, generate-closure.sh, libpool.sh). Lanes reach them
# ONLY through this var — never a spelled-out ../replit path.
REPL_SKILL_DIR="$SCRIPT_DIR/../replit"
SETUP_ENTRY="$SCRIPT_DIR/../setup.sh"     # the one entry (scripts/setup.sh)
# scripts/ root — the shared READY-TO-RUN scripts (tour.py/tour.sh,
# socks5-probe.py). They are not setup (setup prepares; these run);
# lanes only ever CITE them (e.g. a lane's ready line), never source.
SCRIPTS_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# Install root (resolved once — no flag, one env override) ──────────────────
# Set BEFORE the XDG defaults below because every path root depends on it.
# Resolve the install root ONCE, before anything else derives a path
# (scripts/setup/root.sh). The resolver owns $REPL_HOME from here on: explicit
# $SETUP_ROOT -> recorded root -> platform workspace -> die. The old silent
# default layout (WORKSPACE=$(pwd), $HOME roots) was a trap — a shell missing
# the platform env installed into the wiped $HOME tree without a word — so
# it is gone: every root uses the persistent layout, and an unresolvable
# root stops the run before anything installs.
source "$SETUP_LIB_DIR/root.sh"
resolve_setup_root || exit 1
[[ "$SETUP_ROOT_SOURCE" == env ]] && record_setup_root
setup_root_persistence_check
mkdir -p "$SETUP_ROOT"
# A root other than the platform home must also own the XDG dirs: the
# platform pre-sets them under ITS workspace, and "pre-set wins" below
# would otherwise leak installs back into the platform workspace.
if [[ "$SETUP_ROOT" != "$(__setup_platform_home)" ]]; then
  unset XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME XDG_BIN_HOME
fi
REPL_HOME="$SETUP_ROOT"
REPLIT_MODE=true
printf 'setup root: %s (source: %s)\n' "$SETUP_ROOT" "$SETUP_ROOT_SOURCE"

source "$SETUP_LIB_DIR/versions.sh"  # shared pins (one source of truth for repl + muse)

# Paths ──────────────────────────────────────────────────────────────────────
# The resolved root ($REPL_HOME, owned by the resolver above) is the
# persistent dir ($HOME is wiped on restart), so the workspace and every
# XDG dir live under it.
WORKSPACE="$REPL_HOME"
cd "$WORKSPACE"

# XDG roots ──────────────────────────────────────────────────────────────────
# The FOUR vars below must end set, each honoring a pre-set XDG_* value
# (the platform/operator may have chosen one) and otherwise falling back
# UNDER $WORKSPACE (persistent). $HOME is forbidden — wiped on restart.
# NOTE (soft assumption — tweak if needed): the rc target is
# $WORKSPACE/.config/bashrc — the Replit bootstrap auto-sources it (see
# _bashrc_candidate). XDG_BIN_HOME is the single PATH entry every tool
# binary lands in. Var names below are load-bearing: the rest of the
# script, the emitted shell rc, and [userenv.shared] all read them.
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$WORKSPACE/.config}"
XDG_CACHE_HOME="${XDG_CACHE_HOME:-$WORKSPACE/.cache}"
XDG_DATA_HOME="${XDG_DATA_HOME:-$WORKSPACE/.local/share}"
XDG_BIN_HOME="${XDG_BIN_HOME:-$REPL_HOME/.local/bin}"
export XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_BIN_HOME WORKSPACE

# Binaries live in XDG_BIN_HOME (single PATH entry). Use directly —
# no redundant alias.

# Shell target.
# replit mode: managed rc lives at $WORKSPACE/.config/bashrc — the
# platform-native persistent slot Replit's bootstrap (/home/runner/.bashrc)
# sets BASHRC="${REPL_HOME}/.config/bashrc" and sources it as ${BASHRC}
# (guarded by a -f check + REPLIT_MODE unset — i.e. interactive consoles
# only). Lives under the persistent workspace, so it survives container
# recreate (unlike $HOME, which is wiped). One file; no bare root rc.
#
# CONSOLES vs WORKFLOWS — two different hooks, both needed:
#   - interactive consoles read $BASHRC (above), so they need no pin;
#   - workflow tasks run bash NON-interactively, never read $BASHRC, and
#     instead bootstrap through $REPLIT_BASHRC (which the platform presets
#     to the read-only Nix-store bashrc). We therefore DO pin
#     REPLIT_BASHRC in [userenv.shared] — see write_replit_bashrc — pointing
#     it at $XDG_CONFIG_HOME/replit_bashrc, a thin `source ~/.bashrc` shim.
#     This SUPERSEDES the older note that the pin was a no-op: that
#     observation was about the console path, where the platform's own
#     value (and $BASHRC) legitimately win. For workflows the pin is the
#     only thing that reaches them. The platform overriding the key in
#     consoles is harmless — $BASHRC still wins there.
_bashrc_candidate(){
  echo "$WORKSPACE/.config/bashrc"
}
BASHRC="${BASHRC:-$(_bashrc_candidate)}"

# Workflow bashrc shim (replit mode) ─────────────────────────────────────────
# Replit workflows run their tasks in a NON-INTERACTIVE shell with
# REPLIT_MODE=agent|workflow. The platform's store bashrc sources the
# toolchain rc (${REPL_HOME}/.config/bashrc) ONLY when REPLIT_MODE is EMPTY
# (store bashrc: `if [[ -f "${BASHRC}" ]] && [[ -z "${REPLIT_MODE}" ]]`), so in
# a workflow shell that guard fails and the managed block is skipped — a
# workflow process (shell.exec tasks in .replit, the Run button, deploys)
# inherited none of the toolchain env, and managed binaries in XDG_BIN_HOME
# were "command not found" even though the same command worked in the terminal.
#
# The platform runs non-interactive bash with $REPLIT_BASHRC as its rc file.
# Pinning REPLIT_BASHRC to this shim closes the gap: the shim unsets
# REPLIT_MODE and re-sources ~/.bashrc, so the store bashrc's guard passes and
# workflows get exactly the user terminal's env.
#
# Deliberately a DIFFERENT file from $BASHRC: $BASHRC is the user rc
# (setup-managed, writable, may be edited by the operator); this shim is
# fixed wiring that must not drift, so it is regenerated on every run.
REPLIT_BASHRC_FILE="${REPLIT_BASHRC_FILE:-}"
if [[ "$REPLIT_MODE" == true ]]; then
  REPLIT_BASHRC_FILE="${REPLIT_BASHRC_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/replit_bashrc}"
fi

# Snapshot the environment (name → value) BEFORE the script assigns or
# exports anything — input to write_replit_env's no-shadowing rule. Values
# matter, not names: our own previous managed block comes back through the
# inherited env on re-runs (userenv feeds every repl) and must be re-emitted,
# not mistaken for operator choices.
declare -A _PRESET_ENV=()
# compgen prints BARE variable names (one per line, no value) — read each
# name and capture its VALUE via ${!name}. (The old "read line, split on ="
# form broke on '=' in input, storing name→name so no-shadowing never
# actually compared values.) Names are valid identifiers, safe to index.
while IFS= read -r _env_name; do
  [[ "$_env_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && _PRESET_ENV["$_env_name"]="${!_env_name}"
done < <(compgen -e)

# Source order matters only for the top-level setup each module runs at
# source time (common initialises env/paths first; cli runs main last).
source "$SETUP_LIB_DIR/core.sh"
source "$SETUP_LIB_DIR/join.sh"  # shared join engine (S3)
source "$SETUP_LIB_DIR/../replit/common.sh"  # repl-only env/paths/wiring (not loaded under muse)
source "$SETUP_LIB_DIR/ui_menu.sh"
source "$SETUP_LIB_DIR/bin.sh"
source "$SETUP_LIB_DIR/fix.sh"
source "$SETUP_LIB_DIR/rc.sh"
source "$SETUP_LIB_DIR/doctor.sh"
source "$SETUP_LIB_DIR/uv.sh"
source "$SETUP_LIB_DIR/zsh.sh"
source "$SETUP_LIB_DIR/java.sh"
source "$SETUP_LIB_DIR/android.sh"
source "$SETUP_LIB_DIR/node.sh"
source "$SETUP_LIB_DIR/opencode.sh"
source "$SETUP_LIB_DIR/ollama.sh"
source "$SETUP_LIB_DIR/claude.sh"
source "$SETUP_LIB_DIR/hermes.sh"
source "$SETUP_LIB_DIR/ori.sh"
source "$SETUP_LIB_DIR/rclone.sh"
source "$SETUP_LIB_DIR/qbittorrent.sh"
source "$SETUP_LIB_DIR/aria2c.sh"
source "$SETUP_LIB_DIR/ffmpeg.sh"
source "$SETUP_LIB_DIR/cloudflared.sh"
source "$SETUP_LIB_DIR/tailscale.sh"
source "$SETUP_LIB_DIR/sshx.sh"
source "$SETUP_LIB_DIR/join-repl.sh"  # the repl join LANE (install_join); join.sh above is the shared engine
source "$SETUP_LIB_DIR/camofox.sh"
source "$SETUP_LIB_DIR/lightpanda.sh"
source "$SETUP_LIB_DIR/moli.sh"
source "$SETUP_LIB_DIR/tor.sh"
source "$SETUP_LIB_DIR/hermes_chromium.sh"
source "$SETUP_LIB_DIR/llm-wiki.sh"
source "$SETUP_LIB_DIR/cleanup.sh"
source "$SETUP_LIB_DIR/cli.sh"
