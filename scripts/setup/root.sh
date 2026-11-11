# shellcheck shell=bash
# root.sh — single install-root resolver + install manifest.
#
# Why: the base directory used to be re-derived at dozens of call sites with
# different silent fallbacks (${REPL_HOME:-$HOME}, :-$WORKSPACE, :-$(pwd)...),
# so install/doctor/clean could each pick a different base in the same run —
# and a shell missing the platform env silently installed into the wiped
# $HOME layout. Now the root is resolved ONCE, here, printed, and recorded;
# everything downstream keys off $REPL_HOME, which the resolver owns.
#
# Resolution order (first hit wins):
#   1. $SETUP_ROOT (explicit — the operator chose this directory)
#   2. the recorded root (written by an earlier explicit choice)
#   3. the platform persistent workspace ($REPL_HOME)
#   4. die — no silent fallback, ever.
#
# The manifest ($SETUP_ROOT/.config/replit-setup/manifest.tsv, lines
# "tool<TAB>path") records what each installer created, so clean removes
# exactly what install wrote instead of re-deriving paths.

SETUP_ROOT="${SETUP_ROOT:-}"
SETUP_ROOT_SOURCE=""
SETUP_STATE_DIRNAME="replit-setup"

__setup_platform_home() {
  # Where the platform itself says the persistent workspace is. Used ONLY
  # for root discovery/recording and the persistence check — never as a
  # silent install target.
  if [[ -n "${REPL_HOME:-}" && -d "${REPL_HOME:-}" ]]; then printf '%s' "$REPL_HOME"
  elif [[ -d "$HOME/workspace" ]]; then printf '%s' "$HOME/workspace"
  else printf '%s' ""; fi
}

__setup_discovery_file() {
  local ph; ph="$(__setup_platform_home)"
  # Always succeed: with no platform home there is simply no discovery
  # file, and callers test the (empty) result. Returning 1 here killed
  # the whole setup under `set -e` when a caller captured the output —
  # record_setup_root died before its own empty-check could skip.
  [[ -n "$ph" ]] && printf '%s/.config/%s/root' "$ph" "$SETUP_STATE_DIRNAME"
  return 0
}

resolve_setup_root() {
  local ph; ph="$(__setup_platform_home)"
  # 1. explicit choice
  if [[ -n "${SETUP_ROOT:-}" ]]; then SETUP_ROOT_SOURCE="env"; return 0; fi
  # 2. recorded choice from an earlier run
  local disc recorded=""
  disc="$(__setup_discovery_file)"
  if [[ -n "$disc" && -f "$disc" ]]; then
    recorded="$(head -n 1 "$disc" 2>/dev/null || true)"
    if [[ -n "$recorded" && -d "$recorded" ]]; then
      SETUP_ROOT="$recorded"; SETUP_ROOT_SOURCE="recorded"; return 0
    fi
  fi
  # 3. platform default
  if [[ -n "$ph" ]]; then SETUP_ROOT="$ph"; SETUP_ROOT_SOURCE="default"; return 0; fi
  # 4. die loudly — this is the trap the old $(pwd)/$HOME fallback hid.
  printf '%s\n' \
    "setup: cannot determine the install root." \
    "  - set SETUP_ROOT=<dir> to choose the install directory, or" \
    "  - run from the platform workspace (no REPL_HOME detected)." >&2
  return 1
}

# Warn (once, explicitly) when the chosen root is outside the platform's
# persistent workspace: on Replit everything outside it is wiped on recreate.
# Proceeds — the choice was deliberate — but never silently.
setup_root_persistence_check() {
  local ph; ph="$(__setup_platform_home)"
  [[ -z "$ph" ]] && return 0
  case "$SETUP_ROOT" in
    "$ph"|"$ph"/*) ;;
    *) printf 'setup: WARNING: root %s is OUTSIDE the persistent workspace (%s) — it will be wiped on recreate. Proceeding because it was chosen explicitly.\n' "$SETUP_ROOT" "$ph" >&2 ;;
  esac
}

record_setup_root() {
  local disc; disc="$(__setup_discovery_file)"
  [[ -z "$disc" ]] && return 0
  mkdir -p "$(dirname "$disc")"
  printf '%s\n' "$SETUP_ROOT" > "$disc"
}

# ── manifest ─────────────────────────────────────────────────────────────
__setup_manifest_file() { printf '%s/.config/%s/manifest.tsv' "$SETUP_ROOT" "$SETUP_STATE_DIRNAME"; }

manifest_record() {
  local tool="$1"; shift
  local f; f="$(__setup_manifest_file)"
  mkdir -p "$(dirname "$f")"
  local p
  for p in "$@"; do
    [[ -n "$p" ]] || continue
    grep -qxF "$(printf '%s\t%s' "$tool" "$p")" "$f" 2>/dev/null \
      || printf '%s\t%s\n' "$tool" "$p" >> "$f"
  done
}

# manifest_sweep <tool>: remove every path the manifest recorded for <tool>
# (the mop-up clean() runs after the per-tool clean). Returns 0 when it
# removed at least one path. Entries are forgotten either way — a recorded
# path that no longer exists is done.
manifest_sweep() {
  local tool="$1" mp removed=0
  while IFS= read -r mp; do
    if [[ -n "$mp" && -e "$mp" ]]; then
      rm -rf "$mp"; ok "$tool removed (manifest): $mp"; removed=1
    fi
  done < <(manifest_paths "$tool")
  manifest_forget "$tool"
  [[ "$removed" -eq 1 ]]
}

# manifest_record_for <install-step label>: the canonical payload paths each
# tool's installer creates, mirroring what its clean_<tool> removes (user
# data a clean preserves — ollama models, camofox server state, wiki data —
# is NOT recorded, so a sweep can never take it). Called by run_install_step
# after a successful install. tailscale/join are deliberately absent: their
# state is a live daemon + node identity, owned by clean_tailscale's own
# explicit logic, not by a path list.
manifest_record_for() {
  case "$1" in
    android-tools|android) manifest_record android "$JAVA_HOME" "$SDK" ;;
    uv)      manifest_record uv "$XDG_BIN_HOME/uv" "$XDG_BIN_HOME/uvx" "$XDG_DATA_HOME/uv" ;;
    node)    manifest_record node "$NODE_DIR" ;;
    zsh)     manifest_record zsh "$ZSH_PROFILE" "$ZSH_DIR" "$ZSH_DOTDIR" ;;
    opencode) manifest_record opencode "$XDG_BIN_HOME/opencode" "$OPENCODE_CONFIG_DIR" ;;
    ollama)  manifest_record ollama "$OLLAMA_INSTALL_DIR" "$XDG_BIN_HOME/ollama" ;;
    claude)  manifest_record claude "$XDG_BIN_HOME/claude" ;;
    hermes)  manifest_record hermes "$HERMES_HOME" ;;
    ori)     manifest_record ori "$XDG_BIN_HOME/ori" ;;
    camofox) manifest_record camofox "$(camofox_pkg_dir 2>/dev/null || true)" "$CAMOUFOX_INSTALL_DIR" \
               "$XDG_BIN_HOME/camofox-browser" "$XDG_BIN_HOME/launch-camofox-browser" \
               "$CAMOUFOX_CLOSURE_FILE" "$CAMOUFOX_ENV_SNIPPET" ;;
    lightpanda) manifest_record lightpanda "$LIGHTPANDA_BIN" "$LIGHTPANDA_VENV" \
               "$XDG_BIN_HOME/lightpanda" ;;
    moli) manifest_record moli "$MOLI_BIN" \
               "$XDG_BIN_HOME/moli" "$XDG_BIN_HOME/launch-moli" ;;
    hermes-chromium) manifest_record hermes-chromium "$HERMES_CHROME_STATE" "$XDG_BIN_HOME/launch-hermes-chrome" ;;
    llm-wiki) manifest_record llm-wiki "${LLM_WIKI_HOME:-${REPL_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}}/llmwiki-app}" ;;
    rclone)  manifest_record rclone "$XDG_BIN_HOME/rclone" ;;
    qbt)     manifest_record qbt "$XDG_BIN_HOME/qbittorrent-nox" ;;
    aria2)   manifest_record aria2 "$XDG_BIN_HOME/aria2c" ;;
    ffmpeg)  manifest_record ffmpeg "$XDG_BIN_HOME/ffmpeg" "$XDG_BIN_HOME/ffprobe" "$XDG_BIN_HOME/ffplay" ;;
    cloudflared) manifest_record cloudflared "$XDG_BIN_HOME/cloudflared" ;;
    sshx)    manifest_record sshx "$XDG_BIN_HOME/sshx" ;;
    *) : ;;
  esac
}

manifest_paths() {
  local tool="$1" f; f="$(__setup_manifest_file)"
  [[ -f "$f" ]] || return 0
  awk -F '\t' -v t="$tool" '$1 == t { print $2 }' "$f"
}

manifest_forget() {
  local tool="$1" f; f="$(__setup_manifest_file)"
  [[ -f "$f" ]] || return 0
  local tmp; tmp="$(mktemp)"
  awk -F '\t' -v t="$tool" '$1 != t' "$f" > "$tmp" && mv "$tmp" "$f"
}
