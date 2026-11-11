# shellcheck shell=bash
# Interactive install/clean pick-menu (arrow keys). Sourced by setup.sh.
# Logging/cmd helpers live in scripts/setup/core.sh (shared library).

# ── Interactive arrow-key menu (cb.sh pattern, set -e-safe) ──────────────────
_MENU_ITEMS=(
  "android|Android toolchain (Java $JAVA_MAJOR + SDK)"
  "java|Java toolchain only (Temurin JDK $JAVA_MAJOR)"
  "uv|uv (Python package manager)"
  "zsh|zsh + oh-my-zsh + powerlevel10k (Termux-Setup style)"
  "node|Node.js $NODE_MAJOR (managed tarball)"
  "opencode|OpenCode (AI Coding — direct GitHub release)"
  "ollama|Ollama (LLM runtime)"
  "claude|Claude Code (AI Coding)"
  "hermes|Hermes (AI Agent)"
  "ori|ORI (AI Coding)"
  ""
  "camofox|Camofox browser (anti-detection Firefox server)"
  "lightpanda|Lightpanda browser (lightweight CDP engine — keepalive tours)"
  "rclone|rclone (cloud storage sync)"
  "qbt|qBittorrent-nox (headless BitTorrent)"
  "aria2|aria2c (download utility)"
  "ffmpeg|FFmpeg (static GPL build)"
  "cloudflared|cloudflared (Cloudflare Tunnel client)"
  "tailscale|tailscale (userspace tailnet client)"
  "sshx|sshx (collaborative web terminal)"
  "llm-wiki|llm-wiki server (knowledge base: MCP/REST + UI lewat noVNC)"
)
_MENU_CURSOR=0
_MENU_TOGGLE=()

_menu_init() {
  local i
  # Every item starts UNCHECKED in both modes — the user ticks what they want
  # (to install, or to remove in clean mode). In clean mode an empty selection
  # removes nothing; the menu can never trigger an irreversible full wipe
  # (that is --clean all only).
  for i in "${!_MENU_ITEMS[@]}"; do
    _MENU_TOGGLE[$i]=0
  done
  _status_init
}

# Current Status panel ─────────────────────────────────────────────────────
# Probed ONCE in _status_init (when the menu opens) and only re-echoed by
# _menu_draw — which redraws on EVERY keypress, so probing would fork a
# version binary per keystroke.
_STATUS_LINES=()

# Probes every tool once and stores pre-coloured status lines in
# _STATUS_LINES for _menu_draw to echo — one line per tool: green
# "[name] <version> (<path>)" when installed, red "[name] not installed"
# otherwise. The managed copy in XDG_BIN_HOME wins over a PATH hit.
_status_init() {
  local name bin path ver
  local TOOLS=(
    "java|java"
    "python|python"
    "uv|uv"
    "zsh|zsh"
    "node|node"
    "adb|adb"
    "opencode|opencode"
    "ollama|ollama"
    "claude|claude"
    "hermes|hermes"
    "ori|ori"
    "rclone|rclone"
    "qbt-nox|qbittorrent-nox"
    "aria2c|aria2c"
    "ffmpeg|ffmpeg"
    "cloudflared|cloudflared"
    "tailscale|tailscale"
    "sshx|sshx"
    "camofox|camofox-browser"
    "lightpanda|lightpanda"
    "llm-wiki|run-public.sh"
  )
  local npm_root; npm_root="$(npm root -g 2>/dev/null || true)"
  _STATUS_LINES=()
  for entry in "${TOOLS[@]}"; do
    IFS='|' read -r name bin <<< "$entry"
    path="$XDG_BIN_HOME/$bin"
    [[ -x "$path" ]] || path="$(command -v "$bin" 2>/dev/null || true)"
    ver=""
    if [[ "$bin" == "run-public.sh" ]]; then
      # llm-wiki ships a server, not a PATH binary: report the bundle and NEVER
      # exec the supervisor to probe it (that would start the app and the ports).
      local wiki_dir="${LLM_WIKI_HOME:-${REPL_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}}/llmwiki-app}"
      if [[ -x "$wiki_dir/run-public.sh" ]]; then
        path="$wiki_dir"
        ver="llm-wiki server"
      else
        path=""
      fi
    elif [[ "$bin" == "camofox-browser" ]]; then
      # NEVER exec camofox-browser to probe a version: it has no --version flag
      # and STARTS THE SERVER (binds the port, launches Firefox). Read the
      # shipped package.json instead — fast and side-effect free.
      ver="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' \
        "$npm_root/@askjo/camofox-browser/package.json" 2>/dev/null | head -1 || true)"
      [[ -n "$ver" ]] && ver="camofox-browser $ver"
    elif [[ "$bin" == "lightpanda" ]]; then
      # Lightpanda has no --version FLAG (it exits 1 as an unknown
      # command, and the generic probe would read its error line as a
      # version): the probe is the `version` SUBCOMMAND, which prints
      # the bare version.
      ver="$("$path" version 2>/dev/null | head -1 || true)"
      [[ -n "$ver" ]] && ver="lightpanda $ver"
    elif [[ -n "$path" ]]; then
      ver="$("$path" --version 2>&1 | grep -v '^Picked up' | head -1 || true)"
    fi
    if [[ -n "$ver" ]]; then
      _STATUS_LINES+=("${COL_GREEN}[$(printf '%-8s' "$name")] $ver${COL_RESET} ${COL_CYAN}($path)${COL_RESET}")
    else
      _STATUS_LINES+=("${COL_RED}[$(printf '%-8s' "$name")] not installed${COL_RESET}")
    fi
  done
}

_menu_draw() {
  clear
  local desc mark styled prefix selected=0
  local title="Toolchain Setup" verb="install"
  [[ "$MENU_MODE" == clean ]] && { title="Toolchain Cleanup"; verb="remove"; }
  [[ "$REPLIT_MODE" == true ]] && title="$title (Replit)"
  echo "${COL_BOLD}${COL_CYAN}${title}${COL_RESET}"
  if [[ "$REPLIT_MODE" == true ]]; then
    echo "${COL_GREEN}●${COL_RESET} ${COL_DIM}persistent workspace:${COL_RESET} ${COL_CYAN}$WORKSPACE${COL_RESET}"
  fi
  echo "${COL_DIM}↑/↓ move · space toggle · enter confirm · ${COL_RESET}${COL_RED}q${COL_RESET} ${COL_DIM}quit${COL_RESET}"
  echo ""
  echo "${COL_BOLD}Current Status${COL_RESET}"
  echo "${COL_DIM}─────────────────────────────────────────────${COL_RESET}"
  local line
  for line in "${_STATUS_LINES[@]}"; do
    echo "$line"
  done
  echo ""
  local i
  for i in "${!_MENU_ITEMS[@]}"; do
    IFS='|' read -r _ desc <<< "${_MENU_ITEMS[$i]}"
    if [[ "${_MENU_TOGGLE[$i]}" -eq 1 ]]; then
      mark="[${COL_GREEN}✓${COL_RESET}]"
    else
      mark="${COL_DIM}[ ]${COL_RESET}"
    fi
    if [[ "$i" -eq "$_MENU_CURSOR" ]]; then
      prefix="${COL_BOLD}${COL_CYAN}>${COL_RESET}"
      styled="${COL_BOLD}$desc${COL_RESET}"
    else
      prefix=" "
      styled="$desc"
    fi
    echo " ${prefix} ${mark} ${styled}"
  done
  for i in "${!_MENU_TOGGLE[@]}"; do
    [[ "${_MENU_TOGGLE[$i]}" -eq 1 ]] && selected=$((selected + 1))
  done
  echo ""
  if [[ $selected -gt 0 ]]; then
    echo "${COL_GREEN}enter${COL_RESET} ${verb} ${COL_BOLD}${selected}/${#_MENU_ITEMS[@]} selected tools${COL_RESET}"
  else
    echo "${COL_DIM}nothing selected — tick items with space${COL_RESET}"
  fi
}

_menu_read_key() {
  local key
  if ! IFS= read -rsn1 key; then
    echo quit  # EOF (Ctrl+D)
    return 0
  fi
  if [[ "$key" == $'\x1b' ]]; then
    IFS= read -rsn2 key || true
    case "$key" in
      '[A') echo up ;;
      '[B') echo down ;;
    esac
  elif [[ "$key" == " " ]]; then
    echo space
  elif [[ -z "$key" ]]; then
    echo enter
  elif [[ "$key" == "q" || "$key" == "Q" ]]; then
    echo quit
  fi
}

_menu_keyloop() {
  while true; do
    _menu_draw
    case "$(_menu_read_key)" in
      up)
        _MENU_CURSOR=$((_MENU_CURSOR - 1))
        ((_MENU_CURSOR < 0)) && _MENU_CURSOR=$((${#_MENU_ITEMS[@]} - 1))
        ;;
      down)
        _MENU_CURSOR=$((_MENU_CURSOR + 1))
        ((_MENU_CURSOR >= ${#_MENU_ITEMS[@]})) && _MENU_CURSOR=0
        ;;
      space)
        if [[ "${_MENU_TOGGLE[$_MENU_CURSOR]}" -eq 1 ]]; then
          _MENU_TOGGLE[$_MENU_CURSOR]=0
        else
          _MENU_TOGGLE[$_MENU_CURSOR]=1
        fi
        ;;
      enter) return 0 ;;
      quit)  return 130 ;;
    esac
  done
}

_menu_apply() {
  local i label
  if [[ "$MENU_MODE" == clean ]]; then
    # Clean menu: remember the TICKED labels — exactly the tools to remove. An
    # EMPTY selection removes nothing (the menu starts unchecked and tick-to-
    # remove; there is no implicit "clean all" here).
    CLEAN_TOOLS=()
    for i in "${!_MENU_ITEMS[@]}"; do
      if [[ "${_MENU_TOGGLE[$i]}" -eq 1 ]]; then
        IFS='|' read -r label _ <<< "${_MENU_ITEMS[$i]}"
        CLEAN_TOOLS+=("$label")
      fi
    done
    return 0
  fi
  for i in "${!_MENU_ITEMS[@]}"; do
    if [[ "${_MENU_TOGGLE[$i]}" -eq 0 ]]; then continue; fi
    IFS='|' read -r label _ <<< "${_MENU_ITEMS[$i]}"
    case "$label" in
      android)  INSTALL_ANDROID=true ;;
      java)     INSTALL_JAVA=true ;;
      uv)       INSTALL_UV=true ;;
      zsh) INSTALL_ZSH=true ;;
      node)     INSTALL_NODE=true ;;
      opencode) INSTALL_OPENCODE=true ;;
      ollama)   INSTALL_OLLAMA=true ;;
      claude)   INSTALL_CLAUDE=true ;;
      hermes)   INSTALL_HERMES=true ;;
      ori)      INSTALL_ORI=true ;;
      camofox)  INSTALL_CAMOFOX=true ;;
      lightpanda) INSTALL_LIGHTPANDA=true ;;
      moli) INSTALL_MOLI=true ;;
      llmwiki|llm-wiki) INSTALL_LLM_WIKI=true ;;
      rclone)   INSTALL_RCLONE=true ;;
      qbt)      INSTALL_QBT=true ;;
      aria2)    INSTALL_ARIA2=true ;;
      ffmpeg)   INSTALL_FFMPEG=true ;;
      cloudflared) INSTALL_CLOUDFLARED=true ;;
      tailscale)   INSTALL_TAILSCALE=true ;;
      sshx)        INSTALL_SSHX=true ;;
    esac
  done
}

# NOTE: there is deliberately NO second y/N prompt after the menu — pressing
# Enter on the ticked list in interactive_menu IS the confirmation (the menu
# footer spells this out: "enter = remove/install N selected tools"). Asking
# again with a `[y/N]` (default No) after Enter was the old source of a
# spurious "Aborted." on every multi-tool selection, since the Enter needed
# to dismiss it produced an empty answer. Only the flag-driven path
# (`--clean <target>` / `--clean all`) confirms via confirm_clean in main.

interactive_menu() {
  _menu_init
  printf '\033[?25l'
  trap 'printf "\033[?25h\n" "${COL_YELLOW}Interrupted. Exiting.${COL_RESET}"; exit 130' INT
  set +e
  _menu_keyloop
  local rc=$?
  set -e
  printf '\033[?25h'
  trap - INT
  if [[ $rc -ne 0 ]]; then
    echo -e "\n${COL_YELLOW}Aborted.${COL_RESET}"
    exit "$rc"
  fi
  _menu_apply
}
