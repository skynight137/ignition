# shellcheck shell=bash
# Argument parsing, usage, main() and the syntax gate. Sourced by setup.sh.
# Main ───────────────────────────────────────────────────────────────────────
main() {
  # Tool selection:
  #   "tool args" = any option that is NOT a BARE --clean/-c (an install flag,
  #     --all, --doctor, --help, or --clean with an explicit target such as
  #     '--clean all'). When no tool args are present and stdout is a
  #     terminal, open the interactive menu — which serves BOTH install
  #     (pick tools to install) and clean (pick tools to remove):
  #       bare `setup.sh`          -> install pick-menu
  #       bare `setup.sh --clean`  -> clean pick-menu    (`-c` is the same)
  #   - Explicit targets never open a menu: `--clean all` (or `--clean --all`)
  #     wipes everything, `--clean node` removes one tool, `--all` installs all.
  #   - Non-interactive (no TTY): parse_args decides — "no flag" installs all,
  #     and BARE --clean cleans all (full wipe), the documented
  #     non-interactive default.
  local _arg tool_args=0 bare_clean=0 menu_ran=0
  for _arg in "$@"; do
    if [[ "$_arg" == "--clean" || "$_arg" == "-c" ]]; then
      # Bare --clean / -c: records the clean intent. A following target word
      # (or flag) flips tool_args below and routes through parse_args.
      bare_clean=1
    else
      # A bareword target ('all', 'node', ...) or any other flag — an explicit
      # selection that never opens a pick-menu.
      tool_args=1
      break
    fi
  done
  if (( tool_args == 0 )) && [[ -t 1 ]]; then
    if (( bare_clean )); then
      # Bare --clean/-c on a terminal: open the CLEAN pick-menu.
      CLEAN=true
      MENU_MODE="clean"
    fi
    interactive_menu
    menu_ran=1
    unset _MENU_ITEMS _MENU_CURSOR _MENU_TOGGLE 2>/dev/null || true
    if ! $CLEAN \
      && ! $INSTALL_ANDROID && ! $INSTALL_JAVA && ! $INSTALL_NODE && ! $INSTALL_UV \
      && ! $INSTALL_ZSH && ! $INSTALL_OPENCODE && ! $INSTALL_OLLAMA && ! $INSTALL_CLAUDE \
      && ! $INSTALL_HERMES && ! $INSTALL_ORI && ! $INSTALL_RCLONE \
      && ! $INSTALL_QBT && ! $INSTALL_ARIA2 && ! $INSTALL_FFMPEG \
      && ! $INSTALL_CAMOFOX && ! $INSTALL_LIGHTPANDA && ! $INSTALL_MOLI && ! $INSTALL_HERMES_CHROMIUM && ! $INSTALL_LLM_WIKI \
      && ! $INSTALL_TOR \
      && ! $INSTALL_CLOUDFLARED && ! $INSTALL_TAILSCALE && ! $INSTALL_SSHX && ! $INSTALL_JOIN; then
      die "No tools selected. Aborting."
    fi
  else
    parse_args "$@"
    # A bare --clean (no target) means a full wipe when non-interactive — but
    # only when the caller EXPLICITLY opted in with -y/--yes. A bare `-c` in a
    # non-TTY used to default to wiping everything (Hermes included) with no
    # prompt; now it refuses and tells the caller the explicit form.
    if $CLEAN && [[ -z "$CLEAN_TARGET" ]]; then
      if $YES; then
        CLEAN_TARGET="all"
      else
        die "Non-interactive '--clean' with no target is ambiguous (would wipe EVERYTHING, including Hermes). Use '--clean all -y' to confirm, '--clean <tool>' for one tool, or run on a TTY for the pick-menu."
      fi
    fi
  fi

  if $CLEAN; then
    # The pick-menu already confirmed the selection; only a flag-driven
    # cleanup still needs the y/N prompt.
    (( menu_ran )) || confirm_clean
    clean
    exit 0
  fi

  if $LIST_STATE; then
    list_state
    exit 0
  fi

  # --fix: repair wiring WITHOUT deleting/reinstalling tools. --doctor --fix
  # reports first then repairs; bare --fix repairs then reports. The doctor
  # ALWAYS runs after run_fix as the post-repair verification pass. Exit
  # reflects what --fix is responsible for: 2 = wiring still broken after
  # repair (real failure — scripts can gate on it); 0 otherwise. Missing
  # tools (doctor's 1) are an install-scope fact --fix cannot act on, so
  # they warn in the report without failing the command.
  if $FIX; then
    if $DOCTOR; then doctor || true; fi
    run_fix
    local drc=0; doctor || drc=$?
    (( drc == 2 )) && exit 2
    exit 0
  fi

  # Always (re)wire the shell environment on exit — even if an install step
  # fails, the toolchain portions that succeeded remain usable in new
  # shells (e.g. running --all where one component errors out).
  add_exit_action 'write_bashrc'
  add_exit_action 'write_replit_env'
  # After write_replit_env, and unconditional in replit mode: the workflow
  # shim + its REPLIT_BASHRC pin must be re-asserted on every run, because
  # write_replit_env rewrites the [userenv.shared] table wholesale.
  add_exit_action 'write_replit_bashrc'

  mkdir -p "$XDG_BIN_HOME" "$XDG_DATA_HOME"
  # Independent of tool selection: official Node >= 22 tarballs (what
  # --node installs, and what Camofox needs) are linked against
  # libatomic.so.1 — needed even when neither Hermes nor Node is reinstalled
  # this run (a prior $HOME-wipe may have orphaned the pool).
  # INVARIANT: must run BEFORE install_node — its version probe execs the
  # fresh binary and relies on _ldpool_prepend's env on this process.
  ensure_libatomic

  # Each tool runs in its own errored-but-isolated step (run_install_step):
  # one broken installer no longer aborts the rest of the run. A failure is
  # reported, collected and re-surfaced in the summary.
  $INSTALL_JAVA     && run_install_step java                 install_java_tools
  $INSTALL_ANDROID  && run_install_step android-tools      install_android_tools
  $INSTALL_UV       && run_install_step uv                 install_uv
  $INSTALL_ZSH       && run_install_step zsh                 install_zsh
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
  if $INSTALL_JOIN; then
    $INSTALL_TAILSCALE || run_install_step tailscale install_tailscale
    run_install_step join install_join
  fi
  $INSTALL_CAMOFOX  && run_install_step camofox            install_camofox
  $INSTALL_LIGHTPANDA && run_install_step lightpanda       install_lightpanda
  $INSTALL_MOLI && run_install_step moli               install_moli
  $INSTALL_TOR && run_install_step tor                install_tor
  $INSTALL_HERMES_CHROMIUM && run_install_step hermes-chromium install_hermes_chromium
  # llm-wiki's server half is plain Node: on a fresh box without node the install used to
  # finish and then run-public.sh died with "node is required". Install it here instead.
  if $INSTALL_LLM_WIKI && ! command -v node >/dev/null 2>&1; then
    run_install_step node install_node
  fi
  $INSTALL_LLM_WIKI && run_install_step llm-wiki        install_llm_wiki

  # Fold in wiring registered inside the installers' subshells (spill file), then
  # derive from disk for tools already present but not installed this run.
  load_wiring_spill
  if declare -F fix_derive_wiring >/dev/null 2>&1; then
    fix_derive_wiring
  fi

  if $DOCTOR; then
    doctor || true
  fi

  if $INSTALL_ANDROID; then
    local USED
    USED=$(du -sh "$XDG_DATA_HOME" 2>/dev/null | cut -f1 || echo "?")
    echo ""
    echo "  Android toolchain size: $USED"
  fi

  if [[ "$REPLIT_MODE" == true ]]; then
    cat <<SUMMARY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 Setup complete!

 Toolchain lives in: $WORKSPACE
   binaries  $XDG_BIN_HOME
   payload   $XDG_DATA_HOME
 Shell env written to: $BASHRC
# (=$WORKSPACE/.config/bashrc; open a new shell to load it)
 Global env written to: ${REPL_HOME:-$WORKSPACE}/.replit
   ([userenv.shared] — applies to all repl processes after env rebuild)

 Run directly, no sourcing needed:
   java --version  adb --version  node --version
   opencode  ollama  claude  hermes  ori
   rclone  qbittorrent-nox  aria2c  ffmpeg  ffprobe
   cloudflared  tailscale  sshx
   camofox-browser  lightpanda  moli (version subcommands)
   tor  tor-browser (Tor daemon + CDP driver — browse via Tor)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SUMMARY
  else
    cat <<SUMMARY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 Setup complete! (default mode — \$HOME layout)

 Toolchain lives in:
   binaries  $XDG_BIN_HOME
   payload   $XDG_DATA_HOME
   workspace $WORKSPACE
 Shell env written to: $BASHRC
   (minimal PATH block — open a new shell)

 Run directly, no sourcing needed:
   java --version  adb --version  node --version
   opencode  ollama  claude  hermes  ori
   rclone  qbittorrent-nox  aria2c  ffmpeg  ffprobe
   cloudflared  tailscale  sshx
   camofox-browser  lightpanda  moli (version subcommands)
   tor  tor-browser (Tor daemon + CDP driver — browse via Tor)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SUMMARY
  fi

  # llm-wiki is a server, not a PATH binary: point at the supervisor it installed
  # instead of pretending it belongs in the "run directly" tool list above.
  if $INSTALL_LLM_WIKI; then
    echo "   llm-wiki server: bash ${LLM_WIKI_HOME:-${REPL_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}}/llmwiki-app}/run-public.sh"
  fi

  # Report (and fail on) tools that did not install. Run as the LAST step so
  # the exit actions (rc/userenv writers) still fire on a partial run, and
  # non-zero so automation can tell a complete install from a partial one.
  install_fail_summary || exit 1
}

# Syntax gate: validate the entry point and every sourced module. Resolve
# against SCRIPT_DIR, NOT "$0" — a top-level `cd "$WORKSPACE"` runs above this,
# so a RELATIVE invocation (`bash setup.sh` from the scripts dir) leaves "$0"
# unresolvable and the check false-positives 'syntax errors' on a valid file.
# SCRIPT_DIR was captured before any cd. Every file is already loaded by this
# point, so a failure anywhere means a real syntax error.
_syntax_ok=true
for _f in "$SETUP_ENTRY" "$SETUP_LIB_DIR"/*.sh; do
  [[ -f "$_f" ]] || continue
  bash -n "$_f" 2>/dev/null || { _syntax_ok=false; break; }
done
unset _f
if ! $_syntax_ok; then
  die "Script has syntax errors — refusing to run"
fi

main "$@"
