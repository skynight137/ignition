# shellcheck shell=bash
# Lightpanda — lightweight headless browser (CDP server) for session
# keep-alive tours. Sourced by setup.sh.
#
# Design: one static binary, pinned by version + size + SHA256, plus a
# small Python venv that runs the tour client (scripts/tour.py
# drives the engine over CDP with Playwright's client library — no browser
# download, Lightpanda IS the browser). There is no resident server:
# tour.py spawns one `lightpanda serve` per tour stop and tears it
# down, so the engine costs ~380 MB only while a stop is held and zero
# at idle. See references/lightpanda.md.
#
# Layout (mirrors the camofox state root): everything lives under
# $XDG_CONFIG_HOME/lightpanda (persistent, under $REPL_HOME) —
#   lightpanda        the engine binary (symlinked into $XDG_BIN_HOME)
#   venv/             the tour client's Python + playwright
#   .env / cookies.json   operator config + the login jar (user data —
#                     preserved by --clean, like camofox server state)
#   logs/             lane-created; tour.py's per-stop server logs
#                     default to the machine log dir ($REPL_HOME/logs
#                     here) — TOUR_LOG_DIR can point them back here
#
# The release publishes NO checksum asset (checked 1.0.3: binaries +
# .debs only), so the SHA256 pins below were computed from the official
# release downloads when the pin was made. They move WITH
# LIGHTPANDA_VERSION (setup.sh): bump the version without refreshing
# them and the install dies on the size check, loudly, by design.

LIGHTPANDA_HOME="${LIGHTPANDA_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/lightpanda}"
LIGHTPANDA_BIN="$LIGHTPANDA_HOME/lightpanda"
LIGHTPANDA_VENV="$LIGHTPANDA_HOME/venv"

lightpanda_asset_name() {
  case "$(uname -m)" in
    x86_64|amd64)   echo "lightpanda-x86_64-linux" ;;
    aarch64|arm64)  echo "lightpanda-aarch64-linux" ;;
    *)              die "lightpanda: unsupported arch $(uname -m)" ;;
  esac
}

# Pinned size (bytes) + SHA256 of the official $LIGHTPANDA_VERSION asset.
lightpanda_asset_size() {
  case "$(uname -m)" in
    x86_64|amd64)   echo "77403464" ;;
    aarch64|arm64)  echo "74485832" ;;
    *)              die "lightpanda: unsupported arch $(uname -m)" ;;
  esac
}
lightpanda_asset_sha256() {
  case "$(uname -m)" in
    x86_64|amd64)   echo "53eb34da09159dcf8f04865dbfe3e63e9a652062684495aa7ced5ddd7c82e8b0" ;;
    aarch64|arm64)  echo "20a5348bf3b6f71e41088223b188552ab550c1b9c9a9cbd8f099e6f7f3d78549" ;;
    *)              die "lightpanda: unsupported arch $(uname -m)" ;;
  esac
}

lightpanda_write_env_example() {
  # A fill-in TEMPLATE for the tour config, dropped by setup next to the
  # real .env in $LIGHTPANDA_HOME — refreshed on every --lightpanda run
  # (it is a template, not user config; the real .env is never touched).
  local f="$LIGHTPANDA_HOME/.env.example"
  mkdir -p "$(dirname "$f")" || return 0
  cat > "$f" <<'EOF'
# tour config — copy this file to ".env" in this same directory and
# fill in the values. Only the vars you set are used.
#
# Precedence ("big env" rule): a var already set in the system
# environment WINS; this file only fills gaps. tour.py logs at
# startup which source each var came from ("from system env (.env
# file skipped)" / "from .env file"), so a run's config is auditable,
# never silent.
#
# Template written by setup.sh --lightpanda; safe to regenerate, never
# read by the tour itself.

# REQUIRED: the projects the tour keeps alive, comma-separated, in
# stop order. Put the tour's own host FIRST — a pilot that opens
# itself first heals itself before it tours the others.
# (The lp-tour-era name LP_LINKS is still honoured as a fallback.)
TOUR_LINKS=https://replit.com/@you/this-project,https://replit.com/@you/other-project

# The login jar (browser-export or Playwright JSON) for the account
# that can open every project in TOUR_LINKS.
# TOUR_COOKIES=/path/to/cookies.json

# Tour shape (defaults shown — the proven fleet config):
# TOUR_DWELL_S=60            seconds the tab is held per stop
# TOUR_GAP_S=0               sleep between stops, tab closed
# TOUR_MAX_EARLY_FAILURES=3  consecutive failed stops before the tour aborts (0 = never)
EOF
  ok "lightpanda tour config template: $f (copy to .env and fill in)"
}

# The tour client venv: python + the playwright CLIENT library only
# (connect_over_cdp; no browser is ever downloaded — the engine is the
# browser). The pin is the version the fleet trial proved against
# Lightpanda 1.0.3's CDP (references/lightpanda.md).
#
# The venv is created by uv when uv is on PATH, else by
# python3 -m venv — and the playwright install uses whatever the
# resulting venv actually offers: a uv-created venv ships NO pip (uv
# manages it from outside), so it is installed into with
# `uv pip install --python <venv python>`; a python3 venv carries its
# own pip and uses it. (Verified the hard way on the first fleet
# rollout: `python -m pip` inside a uv venv dies "No module named
# pip", mid-lane, on both captain boxes.)
lightpanda_venv_ok() {
  local py="$LIGHTPANDA_VENV/bin/python"
  [[ -x "$py" ]] && "$py" -c 'import playwright' 2>/dev/null
}

# Lane-start preflight for the venv step. Creating the venv needs uv
# or a venv-CAPABLE python3 — a bare python3 is not enough, it must
# bring the venv + ensurepip modules. A fresh Replit join shell has
# NEITHER (no uv, no python3 on PATH), so without this check the lane
# died mid-run, after the ~77 MB binary download. Die here instead,
# before any download, naming the remedy. A healthy existing venv
# exempts the run: re-running the installer is the repair path and
# must stay cheap on a box whose shell PATH lost python.
lightpanda_preflight_venv() {
  lightpanda_venv_ok && return 0
  if command -v uv >/dev/null 2>&1; then return 0; fi
  if command -v python3 >/dev/null 2>&1 \
     && python3 -c 'import venv, ensurepip' 2>/dev/null; then return 0; fi
  die "lightpanda: cannot create the tour venv — neither uv nor a venv-capable python3 found. Run 'setup.sh --uv' first (installs uv), then re-run --lightpanda"
}

lightpanda_ensure_venv() {
  local py="$LIGHTPANDA_VENV/bin/python"
  if lightpanda_venv_ok; then
    skip "lightpanda tour venv present ($LIGHTPANDA_VENV)"
    return 0
  fi
  echo "  creating the tour venv in $LIGHTPANDA_VENV (playwright==$LIGHTPANDA_PLAYWRIGHT_VERSION)"
  rm -rf "$LIGHTPANDA_VENV"
  if command -v uv >/dev/null 2>&1; then
    uv venv "$LIGHTPANDA_VENV" >/dev/null \
      || die "lightpanda: 'uv venv' failed — cannot create the tour venv"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -m venv "$LIGHTPANDA_VENV" \
      || die "lightpanda: 'python3 -m venv' failed — install uv (setup.sh --uv) or a venv-capable python3, then re-run"
  else
    # Unreachable via install_lightpanda (its preflight dies first);
    # kept so this function stays safe if reused standalone.
    die "lightpanda: neither uv nor python3 found — run 'setup.sh --uv' first, then re-run"
  fi
  # Install via the venv's own pip ONLY when the venv actually has
  # pip (python3-created venvs); otherwise install through uv against
  # the venv's interpreter (uv-created venvs have no pip — see the
  # note above). End state is identical either way: playwright ==
  # $LIGHTPANDA_PLAYWRIGHT_VERSION importable from the venv.
  if "$py" -m pip --version >/dev/null 2>&1; then
    "$py" -m pip install --quiet "playwright==$LIGHTPANDA_PLAYWRIGHT_VERSION" \
      || die "lightpanda: pip install playwright==$LIGHTPANDA_PLAYWRIGHT_VERSION failed in the tour venv"
  elif command -v uv >/dev/null 2>&1; then
    uv pip install --python "$py" "playwright==$LIGHTPANDA_PLAYWRIGHT_VERSION" \
      || die "lightpanda: 'uv pip install' playwright==$LIGHTPANDA_PLAYWRIGHT_VERSION failed in the tour venv"
  else
    die "lightpanda: the tour venv has no pip and uv is not available — run 'setup.sh --uv' first, then re-run"
  fi
  "$py" -c 'import playwright' 2>/dev/null \
    || die "lightpanda: playwright still not importable in $LIGHTPANDA_VENV after install"
  ok "lightpanda tour venv ready: $LIGHTPANDA_VENV (playwright $LIGHTPANDA_PLAYWRIGHT_VERSION)"
}

install_lightpanda() {
  step "Lightpanda browser (pinned $LIGHTPANDA_VERSION + tour venv)"
  # Before ANY download: the venv step's toolchain preflight (dies
  # naming the --uv remedy on a fresh shell with neither uv nor a
  # venv-capable python3 — see lightpanda_preflight_venv).
  lightpanda_preflight_venv
  need_cmd curl
  mkdir -p "$XDG_BIN_HOME" "$LIGHTPANDA_HOME"

  local asset url tmp
  asset="$(lightpanda_asset_name)"
  url="$LIGHTPANDA_RELEASE_BASE/$LIGHTPANDA_VERSION/$asset"
  tmp="$XDG_DATA_HOME/_lightpanda.bin"

  # Already at the pinned version: no download, no re-verify — only the
  # venv/template/wiring below are re-asserted. Re-running an installer
  # is the repair path, so it must be cheap and quiet (tailscale shape).
  if [[ -x "$LIGHTPANDA_BIN" ]] \
     && [[ "$("$LIGHTPANDA_BIN" version 2>/dev/null || true)" == "$LIGHTPANDA_VERSION" ]]; then
    skip "lightpanda $LIGHTPANDA_VERSION already installed ($LIGHTPANDA_BIN)"
  else
    echo "  Downloading $asset"
    curl -fsSL "$url" -o "$tmp" || die "lightpanda download failed: $url"
    # Size first (cheap corruption catch), then the pinned SHA256 —
    # upstream publishes no checksum asset, so the pin recorded in this
    # module is the reference (see the header).
    local got_size want_size
    got_size="$(stat -c%s "$tmp" 2>/dev/null || echo 0)"
    want_size="$(lightpanda_asset_size)"
    if [[ "$got_size" != "$want_size" ]]; then
      rm -f "$tmp"
      die "lightpanda ($asset) size mismatch (got $got_size, expected $want_size for $LIGHTPANDA_VERSION) — download may be corrupt, or LIGHTPANDA_VERSION moved without refreshing the pins in scripts/setup/lightpanda.sh"
    fi
    verify_sha256 "$tmp" "$(lightpanda_asset_sha256)" "lightpanda ($asset)"
    chmod +x "$tmp"
    _bin_replace_note "$LIGHTPANDA_BIN"
    rm -f "$LIGHTPANDA_BIN"
    mv -f "$tmp" "$LIGHTPANDA_BIN"
    # The binary must actually run on this box. NOTE: the probe is the
    # `version` SUBCOMMAND — `--version` is an unknown command and
    # exits 1 by design.
    local ver; ver="$("$LIGHTPANDA_BIN" version 2>/dev/null || true)"
    [[ "$ver" == "$LIGHTPANDA_VERSION" ]] \
      || die "lightpanda binary does not run as $LIGHTPANDA_VERSION (got '${ver:-nothing}') — wrong arch or a corrupt install"
    ok "lightpanda installed: $LIGHTPANDA_BIN ($ver)"
  fi

  # PATH entry: a symlink in the single bin dir, the real file stays in
  # the tool's home (the camofox state-root shape).
  ln -sfn "$LIGHTPANDA_BIN" "$XDG_BIN_HOME/lightpanda"

  lightpanda_ensure_venv
  lightpanda_write_env_example

  record_tool_env_vars LIGHTPANDA_HOME LIGHTPANDA_BIN
  record_tool_path_dirs "$XDG_BIN_HOME"
  wire_tool lightpanda LIGHTPANDA_HOME LIGHTPANDA_BIN -- "$XDG_BIN_HOME"

  ok "lightpanda ready — tour: bash $SCRIPTS_DIR/tour.sh --browser lightpanda --machine repl (config: $LIGHTPANDA_HOME/.env, see .env.example there; preflight: tour.sh --check)"
}

clean_lightpanda() {
  if ! _present "$LIGHTPANDA_BIN" "$LIGHTPANDA_VENV" "$XDG_BIN_HOME/lightpanda"; then
    nothing_removed "Lightpanda"; return 0
  fi
  step "Removing Lightpanda browser"
  rm -f "$XDG_BIN_HOME/lightpanda"
  rm -f "$LIGHTPANDA_BIN"
  rm -rf "$LIGHTPANDA_VENV"
  rm -f "$LIGHTPANDA_HOME/.jar-array.json"
  rm -rf "$LIGHTPANDA_HOME/logs"
  # Operator data (.env config + the cookie jar login) is user data —
  # kept; delete $LIGHTPANDA_HOME to wipe it.
  ok "Lightpanda removed (binary + venv; config + cookie jar kept in $LIGHTPANDA_HOME)"
}
