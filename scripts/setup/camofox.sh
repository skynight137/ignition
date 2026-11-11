# shellcheck shell=bash
# Camofox browser (anti-detection Firefox server) — npm-global install.
# Sourced by setup.sh.
#
# Design: the npm package IS the interface. `setup.sh --camofox` installs
# `@askjo/camofox-browser` globally, so you call the real binaries directly —
# `camofox-browser` (server) and `camofox-browser-mcp` (MCP adapter). There is
# no wrapper script and no env file; a default loopback server needs no key.
#
# Replit-specific work this module does (all measured on-box):
#   1. lib closure — Camoufox-Firefox needs the transitive GTK/X11/ALSA closure
#      from /nix/store, which the Replit loader never searches. generate-closure.sh
#      writes it and EXCLUDES the network/TLS families (openssl/curl/…) so the
#      closure is safe on a GLOBAL LD_LIBRARY_PATH (an unpruned one shadows the
#      platform openssl and breaks curl). See rc.sh / the managed shell block for
#      the wiring; the pool dir is also prepended there.
#   2. WebGL spoof — camoufox-js seeds WebGL from a LIVE GPU sample. On a
#      GPU-less Replit (no /dev/dri) there is no GL context (WebGL is null) and
#      the spoof HANGS every Firefox content process, so pages never load. We
#      patch the installed camoufox-js to AUTO-SKIP (detect /dev/dri at launch),
#      so no env var and no wrapper is needed; a GL-capable host keeps the full
#      spoof. Override with CAMOFOX_SKIP_WEBGL_FP=0|1.
#   3. newPage timeout — camofox.config.json ships 10000ms, too tight for a cold
#      Nix repl; raised to a 60000ms floor.
#   4. engine dir — CAMOUFOX_INSTALL_DIR (with the U; that is camoufox-js's
#      spelling) is pinned to $XDG_CACHE_HOME/camoufox (persistent, not $HOME).
#   5. playwright-core pin — camofox-browser asks for `playwright-core ^1.58.0`
#      and camoufox-js declares peer `*`, so npm resolves the LATEST playwright
#      and can outrun the engine's frozen juggler schema. Playwright 1.64 added
#      `bypassServiceWorker` to Network.setRequestInterception and sends it on
#      storage-state pages — the exact call a COOKIE IMPORT makes — so every
#      cookie import 500s while ordinary tab work keeps working. Pinned to the
#      newest compatible release (see CAMOFOX_PLAYWRIGHT_MAX).
#   6. managed Node.js requirement — the install runs under the managed
#      tarball node ($NODE_MAJOR, the --node install), NEVER the platform nix
#      node: generate-closure.sh prepends the current node's linked store
#      dirs to the closure, and the platform node's sqlite needs a newer
#      glibc than the system one, so Firefox dies at every launch while the
#      server looks healthy. camofox_ensure_node enforces it up front.

CAMOFOX_NPM_PKG="@askjo/camofox-browser"
camofox_pkg_dir() { printf '%s/lib/node_modules/@askjo/camofox-browser' "$NODE_DIR"; }

CAMOUFOX_INSTALL_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/camoufox"

# Server STATE dir (cookies/profiles/uploads/traces + the closure + env snippet) ──
# The npm package defaults every state var under $HOME/.camofox
# (lib/config.js:139-142) — and on Replit $HOME is WIPED on recreate, so a
# login silently evaporates. Anchor them under $XDG_CONFIG_HOME (persistent,
# under $REPL_HOME) and export them so the server picks them up.
#
# The server has NO single "state dir" variable: it reads four SEPARATE env
# vars, each with its own ~/.camofox default. CAMOFOX_STATE_DIR was a
# camofox.py-only convenience (the deleted CLI's --state/listing
# fallback; the CLI was removed in S5d) and is NOT read by the server
# or the tour — setting it alone moves nothing.
#
# closure.txt and env.sh live in this SAME dir (not $XDG_DATA_HOME): one
# state root for the whole camofox install, so a wipe/move touches one path.
CAMOFOX_STATE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/camofox"
CAMOFOX_PROFILE_DIR="$CAMOFOX_STATE_DIR/profiles"
CAMOFOX_COOKIES_DIR="$CAMOFOX_STATE_DIR/cookies"
CAMOFOX_UPLOADS_DIR="$CAMOFOX_STATE_DIR/uploads"
CAMOFOX_TRACES_DIR="$CAMOFOX_STATE_DIR/traces"
CAMOFOX_CLOSURE_FILE="$CAMOFOX_STATE_DIR/closure.txt"
CAMOFOX_ENV_SNIPPET="$CAMOFOX_STATE_DIR/env.sh"
# Stamp recording WHICH node generated closure.txt (resolved path + version).
# The closure is a function of the node that ran generate-closure.sh — that
# script prepends the node's own linked store dirs — so a closure built under
# a different node is stale even when every dir listed in it still exists.
CAMOFOX_CLOSURE_STAMP="$CAMOFOX_STATE_DIR/closure.node"

# One-time move of closure.txt/env.sh off the older $XDG_DATA_HOME/camofox
# layout so an existing install keeps working without a re-fetch. Copy, never
# move: the old path stays valid, and a second run is a no-op.
camofox_migrate_aux_files() {
  local old_dir="${XDG_DATA_HOME:-$HOME/.local/share}/camofox" f
  [[ -d "$old_dir" ]] || return 0
  mkdir -p "$CAMOFOX_STATE_DIR" 2>/dev/null || return 0
  for f in closure.txt env.sh; do
    [[ -s "$old_dir/$f" && ! -e "$CAMOFOX_STATE_DIR/$f" ]] || continue
    cp -a "$old_dir/$f" "$CAMOFOX_STATE_DIR/$f" 2>/dev/null \
      && warn "camofox: moved $f -> $CAMOFOX_STATE_DIR (copied; old file left in place)"
  done
}

# One-time migration off the volatile $HOME default. Copy, never move: the old
# dir stays valid, and a second run is a no-op because the target only takes
# files it does not already have.
camofox_migrate_state() {
  local old="$HOME/.camofox"
  [[ -d "$old" ]] || return 0
  mkdir -p "$CAMOFOX_PROFILE_DIR" 2>/dev/null || return 0
  if [[ -n "$(find "$CAMOFOX_PROFILE_DIR" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
    return 0   # already populated — never clobber live state
  fi
  cp -a "$old"/. "$CAMOFOX_STATE_DIR"/ 2>/dev/null || true
  warn "camofox state: re-anchored \$HOME/.camofox -> $CAMOFOX_STATE_DIR (copied; old dir left in place)"
}

# --- camoufox-js patches (idempotent) ---------------------------------------
# (a) WebGL: auto-detect a GPU render node at launch instead of hanging on a
#     GPU-less host. Env CAMOFOX_SKIP_WEBGL_FP=0|1 still wins.
# (b) import existsSync for that check.
camofox_patch_webgl() {
  local pkg; pkg="$(camofox_pkg_dir)"
  local util="$pkg/node_modules/camoufox-js/dist/utils.js"
  [[ -f "$util" ]] || { warn "camoufox-js utils.js not found ($util) — WebGL patch skipped"; return 0; }
  if grep -q 'CAMOFOX_SKIP_WEBGL_FP' "$util"; then
    skip "camoufox-js WebGL auto-skip patch already applied"
    return 0
  fi
  if ! grep -q 'if (block_webgl || launch_options.allow_webgl === false) {' "$util"; then
    warn "camoufox-js WebGL branch shape changed — patch not applied (upstream may have fixed it; verify pages load)"
    return 0
  fi
  local tmp; tmp="$(mktemp)"
  awk '
    # import existsSync for the /dev/dri check (import line is stable).
    /^import \{ readFileSync \} from "node:fs";/ && !fs && !done {
      print "import { readFileSync, existsSync } from \"node:fs\";"; fs = 1; next
    }
    # auto-skip WebGL when no GPU render node exists (env override wins).
    /if \(block_webgl \|\| launch_options\.allow_webgl === false\) \{/ && !done {
      print "    // setup.sh patch: skip the WebGL spoof when there is no GPU."
      print "    // On a GPU-less host there is no GL context and the spoofed"
      print "    // renderer deadlocks the content process. Env override wins."
      print "    const _cfWebglEnv = process.env.CAMOFOX_SKIP_WEBGL_FP;"
      print "    const _cfNoGpu = !(existsSync(\"/dev/dri/renderD128\") || existsSync(\"/dev/dri/card0\"));"
      print "    if (_cfWebglEnv === \"1\" || (_cfWebglEnv !== \"0\" && _cfNoGpu)) { /* no WebGL spoof */ }"
      print "    else if (block_webgl || launch_options.allow_webgl === false) {"
      done = 1; next
    }
    { print }
  ' "$util" > "$tmp"
  if grep -q 'CAMOFOX_SKIP_WEBGL_FP' "$tmp" && grep -q 'readFileSync, existsSync' "$tmp"; then
    cat "$tmp" > "$util"; rm -f "$tmp"
    ok "patched camoufox-js: WebGL spoof auto-skipped on GPU-less hosts"
  else
    rm -f "$tmp"; warn "WebGL patch failed to apply — leaving camoufox-js untouched"
  fi
}

# Raise the newPage timeout floor in the package config (file-only setting).
camofox_raise_newpage_timeout() {
  local pkg; pkg="$(camofox_pkg_dir)"
  local cfg="$pkg/camofox.config.json"
  [[ -f "$cfg" ]] || return 0
  command -v node >/dev/null 2>&1 || return 0
  NEW_PAGE_TIMEOUT_FLOOR="${NEW_PAGE_TIMEOUT_FLOOR:-60000}" node -e '
const fs=require("fs"),p=process.argv[1];
const floor=Number(process.env.NEW_PAGE_TIMEOUT_FLOOR)||60000;
let j; try{ j=JSON.parse(fs.readFileSync(p,"utf8")); }catch{ process.exit(0); }
const cur=Number(j.newPageTimeoutMs);
if(!Number.isFinite(cur)||cur<floor){ j.newPageTimeoutMs=floor; fs.writeFileSync(p,JSON.stringify(j,null,2)+"\n"); console.log("  camofox.config.json newPageTimeoutMs "+cur+" -> "+floor); }
' "$cfg" || true
}

# Newest playwright-core whose Firefox network manager does NOT pass
# `bypassServiceWorker` to Network.setRequestInterception (added in 1.64.0 and
# sent on storage-state pages). The Camoufox engine's juggler schema
# (chrome/juggler/content/protocol/Protocol.js inside omni.ja) declares only
# `{enabled}`, so a newer client fails every cookie import:
#   browser.newContext: Error setting storage state: Protocol error
#   (Network.setRequestInterception): ... "bypassServiceWorker" ... is not
#   described in this scheme                              -> HTTP 500
# Raise this ONLY after confirming the engine's Protocol.js grew the param, or
# after camoufox-js ships an engine that accepts it (camofox_engine_accepts_
# bypass_sw checks exactly that and skips the pin when the engine is new enough).
CAMOFOX_PLAYWRIGHT_MAX="${CAMOFOX_PLAYWRIGHT_MAX:-1.63.0}"

# Does the INSTALLED engine's juggler declare bypassServiceWorker?
camofox_engine_accepts_bypass_sw() {
  local ja="${CAMOUFOX_INSTALL_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/camoufox}/omni.ja"
  local proto="chrome/juggler/content/protocol/Protocol.js"
  [[ -f "$ja" ]] || return 1
  if command -v unzip >/dev/null 2>&1; then
    unzip -p "$ja" "$proto" 2>/dev/null | grep -q bypassServiceWorker && return 0
    return 1
  fi
  command -v python3 >/dev/null 2>&1 || return 1
  python3 -c 'import sys,zipfile
d=zipfile.ZipFile(sys.argv[1]).read(sys.argv[2])
sys.exit(0 if b"bypassServiceWorker" in d else 1)' "$ja" "$proto" 2>/dev/null
}

# Pin playwright-core so the client cannot outrun the engine. Idempotent: a
# re-run of `npm install -g @askjo/camofox-browser` bumps it straight back to
# the latest (its range is ^1.58.0, camoufox-js's peer is `*`), which is why
# this runs after every install rather than being a one-off fix.
camofox_pin_playwright() {
  local pkg; pkg="$(camofox_pkg_dir)"
  local pj="$pkg/node_modules/playwright-core/package.json"
  [[ -f "$pj" ]] || { warn "playwright-core not found under $pkg — pin skipped"; return 0; }
  command -v node >/dev/null 2>&1 || { warn "node not on PATH — playwright-core pin skipped"; return 0; }
  local cur; cur="$(node -p "require('$pj').version" 2>/dev/null || true)"
  [[ -n "$cur" ]] || { warn "could not read the installed playwright-core version — pin skipped"; return 0; }

  if camofox_engine_accepts_bypass_sw; then
    skip "engine accepts bypassServiceWorker — playwright-core $cur kept"
    return 0
  fi
  [[ "$cur" == "$CAMOFOX_PLAYWRIGHT_MAX" ]] && { skip "playwright-core pinned at $CAMOFOX_PLAYWRIGHT_MAX"; return 0; }
  # Never UPGRADE an already-older client: the pin is a ceiling, not a target.
  if [[ "$(printf '%s\n%s\n' "$CAMOFOX_PLAYWRIGHT_MAX" "$cur" | sort -V | tail -1)" != "$cur" ]]; then
    skip "playwright-core $cur is below the pin ($CAMOFOX_PLAYWRIGHT_MAX) — left alone"
    return 0
  fi

  echo "  playwright-core $cur -> $CAMOFOX_PLAYWRIGHT_MAX (engine juggler has no bypassServiceWorker)"
  # --no-save: the enclosing package.json is regenerated on the next global
  # install, so writing the pin there would be silently undone.
  npm install --prefix "$pkg" --no-audit --no-fund --no-save "playwright-core@$CAMOFOX_PLAYWRIGHT_MAX" >/dev/null 2>&1 \
    || { warn "playwright-core pin failed — cookie import will 500 until it is pinned"; return 0; }
  local new; new="$(node -p "require('$pj').version" 2>/dev/null || true)"
  if [[ "$new" == "$CAMOFOX_PLAYWRIGHT_MAX" ]]; then
    ok "playwright-core pinned at $CAMOFOX_PLAYWRIGHT_MAX (restart the camofox server to load it)"
  else
    warn "playwright-core pin did not take (now ${new:-unknown}) — cookie import will 500"
  fi
}

# Runtime env for camofox, applied by sourcing this file. Co-locates the GTK/X11
# closure with the two fixes a bare `camofox-browser` needs on this box:
#   * a stale ambient CAMOUFOX_INSTALL_DIR (an old [userenv.shared] value) would
#     point camoufox-js at the wrong engine dir and re-download there;
#   * an ambient CAMOFOX_ACCESS_KEY (from a workflow/agent) gates EVERY route,
#     breaking keyless loopback use.
# NOT sourced by the interactive shell rc — a 7 KB env var on every shell is
# wasteful and hung this box's rc writer.
#
# TWO consumers, and the second one is why the launcher below exists:
#   1. a shell CAN source it (`bash -c '. env.sh; exec camofox-browser'`);
#   2. the npm `camofox-browser` binary CANNOT — it is a JS entry point and the
#      GTK closure must be in LD_LIBRARY_PATH before the process starts. So a
#      workflow / Run-button / MCP / cron shell that just runs
#      `camofox-browser` launches Firefox with no GTK stack.
camofox_write_env_snippet() {
  local f="$CAMOFOX_ENV_SNIPPET"
  [[ -s "$CAMOFOX_CLOSURE_FILE" ]] || return 0
  mkdir -p "$(dirname "$f")"
  {
    echo "# camofox runtime env (setup.sh --camofox). Source before camofox-browser."
    echo "export LD_LIBRARY_PATH=\"\$(cat \"$CAMOFOX_CLOSURE_FILE\")\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}\""
    echo "export CAMOUFOX_INSTALL_DIR=\"$CAMOUFOX_INSTALL_DIR\""
    # State dirs: without these the server defaults every one to $HOME/.camofox
    # (lib/config.js:139-142) — wiped on recreate, so a cookie jar/login dies
    # with it. The [userenv.shared] pins cover workflow shells; this covers any
    # consumer that only sources env.sh.
    echo "export CAMOFOX_STATE_DIR=\"$CAMOFOX_STATE_DIR\""
    echo "export CAMOFOX_PROFILE_DIR=\"$CAMOFOX_PROFILE_DIR\""
    echo "export CAMOFOX_COOKIES_DIR=\"$CAMOFOX_COOKIES_DIR\""
    echo "export CAMOFOX_UPLOADS_DIR=\"$CAMOFOX_UPLOADS_DIR\""
    echo "export CAMOFOX_TRACES_DIR=\"$CAMOFOX_TRACES_DIR\""
    # Crash reporter redirect: the server's sendToRelay() POSTs to this
    # URL. A Replit box cannot dial the tailnet directly, so the URL
    # points at the loopback crash-shim (crash-shim-loop.sh keeps it
    # alive), which forwards each report to the CC on muse-hop over
    # `tailscale nc`. The shim stamps the node name itself, so this
    # value is the same on every box. Never set
    # CAMOFOX_CRASH_REPORT_ENABLED=false here: that kills the watchdog
    # (stall/hang/leak detection) along with the relay.
    echo "export CAMOFOX_CRASH_REPORT_URL=\"http://127.0.0.1:18099/crash-report\""
    echo 'if [[ "${CAMOFOX_BIND_HOST:-127.0.0.1}" = 127.0.0.1 && "${PORT:-9377}" = "9377" ]]; then unset CAMOFOX_ACCESS_KEY; fi'
  } > "$f"
  ok "camofox env snippet: $f"
}

camofox_write_env_example() {
  # A fill-in TEMPLATE for the CLIENT config, dropped by setup — never by
  # hand — next to the real .env in the canonical config home
  # ($XDG_CONFIG_HOME/camofox, the same dir as server-keys.env), so an
  # operator learns what to configure from the box itself instead of from
  # docs. Refreshed on every --camofox run: it is a template, not user
  # config, and the real .env next to it is never touched by setup.
  local f="$CAMOFOX_STATE_DIR/.env.example"
  mkdir -p "$(dirname "$f")" || return 0
  cat > "$f" <<'EOF'
# camofox CLIENT config — copy this file to ".env" in this same directory
# and fill in the values. Only the vars you set are used.
#
# Precedence ("big env" rule): a var already set in the system environment
# WINS; this file only fills gaps. The tour's built-in camofox client
# logs at startup which source each var came from ("from system env
# (.env file skipped)" / "from .env file"), so a run's config is
# auditable, never silent.
#
# Template written by setup.sh --camofox; safe to regenerate, never read
# by the client itself.

# NOT NEEDED for the default pairing: with the launcher's default
# port the server binds 9377 and clients default to
# http://127.0.0.1:9377 — no CAMOFOX_* vars at all. Fill this file
# in ONLY for a non-default (public) endpoint: the dev domain (as
# here) plus the port the server was started with (PORT=80 is the
# public opt-in).
CAMOFOX_BASE_URL=https://<your-repl-dev-domain>
CAMOFOX_PORT=80

# Auth keys — copy the values from server-keys.env in this directory.
# The ACCESS key is preferred; the API key is the fallback.
CAMOFOX_ACCESS_KEY=
CAMOFOX_API_KEY=

# Optional overrides (defaults shown; leave unset unless you mean it):
# CAMOFOX_ROOT=$HOME/camofox            legacy client state root
# CAMOFOX_STATE_DIR=$XDG_CONFIG_HOME/camofox
# CAMOFOX_ENV_FILE=/path/to/other.env   point discovery at another file
EOF
  ok "camofox client config template: $f (copy to .env and fill in)"
}

# Shell shim for consumers that cannot source env.sh.
#
# WHY THIS EXISTS (measured 2026-10-06): the `.replit` "camofox browser"
# workflow ran a bare `camofox-browser`. A workflow task is a NON-interactive
# shell with REPLIT_MODE set, and an old run predated the REPLIT_BASHRC shim,
# so the env snippet never reached it: the server inherited only the pinned
# `[userenv.shared] LD_LIBRARY_PATH=/home/runner/workspace/.local/lib`, which
# carries the pool but NOT GTK. Camoufox
# then died on every launch with
#   XPCOMGlueLoad error for .../libmozgtk.so: libgtk-3.so.0: cannot open shared
#   object file: No such file or directory
# and, because the client imports cookies FIRST (camofox.py then, the
# tour's camofox engine now), the client only ever showed
#   import failed: {'_http_error': 500, '_body': '{"error":"browserType.launch:
#   Failed to launch the browser process..."}'}
# — i.e. the "refresh page" workflow failed while the browser was dead. 6 logged
# rp runs hit exactly this; it is not an intermittent bug.
#
# Fix: a shim that sources env.sh then execs the npm binary. The NAME IS
# DELIBERATELY DIFFERENT from `camofox-browser`, so it never shadows the npm bin
# on PATH and cannot recurse. Regenerated by `--fix`, so `--doctor` can verify it.
#
# ORDERING: run this AFTER the package + engine are in place (install_camofox
# step 5; --fix derives from the installed payloads). It is best-effort by
# design — it must never fail an install — but it is NOT a substitute for
# installing: each prerequisite is asserted at RUNTIME below, so a half-run
# ("launched the shim, forgot setup.sh --camofox") prints the exact missing
# piece and the one command that fixes it, instead of the loader's
# `libgtk-3.so.0: cannot open shared object file`.
camofox_write_launcher() {
  local f="$XDG_BIN_HOME/launch-camofox-browser"
  mkdir -p "$XDG_BIN_HOME" || { warn "cannot create $XDG_BIN_HOME — camofox launcher not written"; return 0; }
  # Quoted heredoc: every $ stays literal in the emitted script.
  cat > "$f" <<'EOF'
#!/usr/bin/env bash
# Generated by setup.sh (--camofox / --fix) — do not hand-edit; re-run --fix.
#
# Use this from any shell that has NOT sourced env.sh: .replit workflows, the
# Run button, cron/MCP children. A bare `camofox-browser` there launches
# Firefox with no GTK closure and dies with
# `libmozgtk.so: libgtk-3.so.0: cannot open shared object file` — which reaches
# the user as a bare "Internal server error" on the first tab/cookie call.
#
# This is a convenience wrapper, NOT the install. Run `setup.sh --camofox`
# first; the checks below tell you precisely what is missing if you didn't.
set -uo pipefail

X="${XDG_CONFIG_HOME:-${REPL_HOME:-$HOME}/.config}"
# A camofox-only install lands the npm binaries in $XDG_DATA_HOME/node/bin,
# which is on PATH only when the node tool was also installed/wired — a
# fresh box that ran just `setup.sh --camofox` fails this shim's own
# preflight with "camofox-browser is not installed" even though setup.sh
# reported success (verified live on repl-test, 2026-11-05). The shim is
# the entry point for shells that cannot source anything, so it puts the
# two bin dirs it relies on onto PATH itself.
D="${XDG_DATA_HOME:-${REPL_HOME:-$HOME}/.local/share}"
B="${XDG_BIN_HOME:-${REPL_HOME:-$HOME}/.local/bin}"
case ":$PATH:" in *":$D/node/bin:"*) ;; *) PATH="$D/node/bin:$PATH" ;; esac
case ":$PATH:" in *":$B:"*) ;; *) PATH="$B:$PATH" ;; esac
export PATH
ENVSH="$X/camofox/env.sh"
CLOSURE="$X/camofox/closure.txt"
ENGINE="${CAMOUFOX_INSTALL_DIR:-${XDG_CACHE_HOME:-${REPL_HOME:-$HOME}/.cache}/camoufox}"
NOW="bash __CAMOFOX_SETUP_CMD__"

missing=0
if ! command -v camofox-browser >/dev/null 2>&1; then
  echo "launch-camofox-browser: camofox-browser is not installed." >&2
  echo "  Camofox was never installed (or a \$HOME wipe removed its PATH dir)." >&2
  echo "  Fix: $NOW --camofox" >&2
  missing=1
fi
if [[ ! -s "$CLOSURE" ]]; then
  echo "launch-camofox-browser: the GTK/X11 lib closure is missing ($CLOSURE)." >&2
  echo "  Camofox's Firefox cannot start without it (libgtk-3.so.0)." >&2
  echo "  Fix: $NOW --camofox" >&2
  missing=1
fi
if [[ ! -s "$ENVSH" ]]; then
  echo "launch-camofox-browser: runtime env snippet missing ($ENVSH)." >&2
  echo "  Fix: $NOW --fix" >&2
  missing=1
fi
if [[ ! -f "$ENGINE/version.json" ]]; then
  echo "launch-camofox-browser: Camoufox engine missing ($ENGINE)." >&2
  echo "  Fix: $NOW --camofox   (~1.3 GB fetch)" >&2
  missing=1
fi
(( missing )) && { echo "launch-camofox-browser: refusing to start — see the fixes above." >&2; exit 1; }

# Prerequisites OK. env.sh APPENDS the closure, so an inherited LD_LIBRARY_PATH
# (the [userenv.shared] pool with libatomic) is preserved, not clobbered.
#
# PORT defaults to 9377: the camofox-native pairing. The server
# binds the default port and every client (the tour included)
# defaults to http://127.0.0.1:9377, so a plain install needs NO
# CAMOFOX_* variables anywhere. Going public is the explicit
# opt-in: export PORT=80 (plus a [[ports]] mapping and
# CAMOFOX_BASE_URL + key on the clients) — env.sh only drops
# CAMOFOX_ACCESS_KEY on the default loopback port, so the key
# stays in place under its own name on a public bind.
export PORT="${PORT:-9377}"
. "$ENVSH"

# Workflow-console hygiene (skill-wide rule, references/exposing-ports.md):
# the server's JSON request log streamed into a workflow terminal grows
# without bound and makes the Replit UI hang, so the full log goes to a
# file in the persistent workspace and the console gets a short summary
# only. The launcher still holds its workflow open — by waiting on the
# server process itself, never by tailing the log.
LOG_DIR="${REPL_HOME:-$HOME}/logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/camofox-browser.log"
echo "=== launch-camofox-browser $(date -Is) ===" >>"$LOG"
camofox-browser "$@" >>"$LOG" 2>&1 &
SRV=$!
echo "camofox-browser: starting on port ${PORT} (pid $SRV)"
echo "  public: https://${REPLIT_DEV_DOMAIN:-<dev-domain>}/"
echo "  full log: $LOG"
wait $SRV
EOF
  # The heredoc above is quoted (every runtime $ stays literal), so the one
  # generation-time value — this skill's own setup.sh, derived from
  # $SCRIPT_DIR like every other generated launcher (cf. expose.sh) — is
  # substituted in afterwards. A hardcoded clone path here
  # (/home/runner/workspace/skynight137-skills/...) sent fresh users to a
  # root that exists on none of the npx-installed boxes.
  sed -i "s#__CAMOFOX_SETUP_CMD__#$SETUP_ENTRY#" "$f"
  chmod +x "$f"
  ok "camofox launcher shim: $f"
}

# --- cold store: replit.nix (persistence) + nix-env (immediate) -------------
# Verified fresh-box behaviour (repl-test, 2026-11-05):
# * A fresh workspace has NO replit.nix and a COLD store: `nix eval` resolves
#   gtk3/alsa-lib/libXdamage/xvfb/cacert but none of those paths exist, so
#   generate-closure.sh fails — and a fresh user was told to hand-edit the
#   package list into replit.nix themselves.
# * Writing replit.nix from a command DOES work (it is just a workspace
#   file), but the platform does NOT rebuild on the write (store still cold
#   minutes later, no restart); it applies only at the next platform
#   rebuild/restart. The file alone cannot finish an install in the same run.
# * `nix-env -iA` warms the CURRENT container in seconds (cache.nixos.org ->
#   local overlay store) and feeds generate-closure.sh through its
#   ~/.nix-profile lane. Attr spelling differs per lane: the nix expression
#   in replit.nix wants `pkgs.xorg.xvfb`, while `nix-env -iA` has NO
#   `nixpkgs.xorg.xvfb` attr (verified: "attribute 'xvfb' ... not found") —
#   the legacy attr that ships a working Xvfb is `nixpkgs.xorg.xorgserver`.
# * `nix --store /nix/store build nixpkgs#xorg.xvfb` is NOT a substitute:
#   its output lands in the chroot store (/nix/store/nix/store/<hash>) and
#   is invisible to the shell that checks for it (references/nix.md §3b).
# So: declare in replit.nix for the next rebuild AND nix-env for now. The
# user never hand-edits a package list.
CAMOFOX_NIX_DEPS_EXPR=(cacert gtk3 alsa-lib xorg.libXdamage xorg.xvfb)
CAMOFOX_NIXENV_ATTRS=(nixpkgs.cacert nixpkgs.gtk3 nixpkgs.alsa-lib nixpkgs.xorg.libXdamage nixpkgs.xorg.xorgserver)

camofox_store_cold() {
  # Mirror generate-closure.sh's resolution: the profile symlink target OR
  # the nixpkgs eval root must exist for each of the three closure libs.
  local lib root target
  for lib in libgtk-3.so.0 libasound.so.2 libXdamage.so.1; do
    if [[ -e "$HOME/.nix-profile/lib/$lib" ]]; then
      target="$(readlink -f "$HOME/.nix-profile/lib/$lib" 2>/dev/null || true)"
      [[ -e "$target" ]] && continue
    fi
    case "$lib" in
      libgtk-3.so.0)   root="$(nix eval --raw nixpkgs#gtk3 2>/dev/null || true)" ;;
      libasound.so.2)  root="$(nix eval --raw nixpkgs#alsa-lib 2>/dev/null || true)" ;;
      libXdamage.so.1) root="$(nix eval --raw nixpkgs#xorg.libXdamage 2>/dev/null || true)" ;;
    esac
    [[ -n "$root" && -e "$root/lib/$lib" ]] && continue
    return 0   # cold: at least one lib unresolvable
  done
  return 1     # warm
}

camofox_ensure_replit_nix() {
  local f="${REPL_HOME:-$WORKSPACE}/replit.nix"
  local -a missing=()
  local d tmp
  if [[ ! -f "$f" ]]; then
    {
      echo '{pkgs}: {'
      echo '  deps = ['
      for d in "${CAMOFOX_NIX_DEPS_EXPR[@]}"; do echo "    pkgs.$d"; done
      echo '  ];'
      echo '}'
    } > "$f" || { warn "camofox: cannot write $f — add pkgs gtk3/alsa-lib/xorg.libXdamage/xorg.xvfb/cacert there by hand"; return 0; }
    ok "camofox: wrote $f with the Camofox nix deps (applies at the next Replit rebuild/restart)"
    return 0
  fi
  for d in "${CAMOFOX_NIX_DEPS_EXPR[@]}"; do
    grep -qF "pkgs.$d" "$f" || missing+=("$d")
  done
  if ((${#missing[@]} == 0)); then
    skip "camofox: $f already declares the Camofox nix deps"
    return 0
  fi
  if grep -q 'deps = \[' "$f"; then
    # Insert each missing dep right after the `deps = [` line (idempotent —
    # the grep above filters deps already present anywhere in the file).
    tmp="$(mktemp)"
    if awk -v deps="$(printf '%s ' "${missing[@]}")" '
      BEGIN { n = split(deps, a, " "); done = 0 }
      { print }
      /deps = \[/ && !done { for (i = 1; i <= n; i++) if (a[i] != "") print "    pkgs." a[i]; done = 1 }
    ' "$f" > "$tmp" && mv "$tmp" "$f"; then
      ok "camofox: added to $f: ${missing[*]} (applies at the next Replit rebuild/restart)"
    else
      rm -f "$tmp"
      warn "camofox: could not edit $f — add by hand: pkgs.${missing[*]}"
      return 0
    fi
  else
    warn "camofox: $f has no 'deps = [' block — not auto-edited. Add by hand: pkgs.${missing[*]} (file: $f)"
    return 0
  fi
  if command -v nix-instantiate >/dev/null 2>&1; then
    nix-instantiate --parse "$f" >/dev/null 2>&1 \
      || warn "camofox: $f no longer parses as nix — check the edit before the next rebuild"
  fi
}

CAMOFOX_NIX_CHANNEL="stable-25_05"

# replit.nix only takes effect when .replit declares a nix channel: with no
# [nix] table the platform drops the repl into recovery mode and never
# rebuilds (operator-verified on repl-test, 2026-11-05 — replit.nix written,
# terminal said recovery mode, store stayed cold). Ensure the channel next
# to the deps file; an existing channel (any value) is the operator's call
# and is left untouched.
camofox_ensure_nix_channel() {
  local f="${REPL_HOME:-$WORKSPACE}/.replit" out
  [[ -f "$f" ]] || { warn "camofox: no .replit at $f — cannot ensure the [nix] channel"; return 0; }
  command -v python3 >/dev/null 2>&1 || { warn "camofox: python3 missing — add [nix] channel = \"$CAMOFOX_NIX_CHANNEL\" to .replit by hand"; return 0; }
  out="$(CAMOFOX_NIX_CHANNEL="$CAMOFOX_NIX_CHANNEL" python3 - "$f" <<'PY'
import os, re, sys
p = sys.argv[1]; ch = os.environ["CAMOFOX_NIX_CHANNEL"]
s = open(p).read()
if re.search(r"(?m)^\[nix\]\s*$", s):
    block = re.search(r"(?ms)^\[nix\]\n(.*?)(?=^\[|\Z)", s).group(1)
    cm = re.search(r'(?m)^channel\s*=\s*"([^"]+)"', block)
    if cm:
        print("keep:" + cm.group(1)); sys.exit(0)
    s = re.sub(r"(?m)^\[nix\]\s*$", '[nix]\nchannel = "%s"' % ch, s, count=1)
    open(p, "w").write(s); print("inserted"); sys.exit(0)
if not s.endswith("\n"):
    s += "\n"
open(p, "w").write(s + '\n[nix]\nchannel = "%s"\n' % ch)
print("appended")
PY
)" || { warn "camofox: [nix] channel edit failed — add channel = \"$CAMOFOX_NIX_CHANNEL\" under [nix] in .replit by hand"; return 0; }
  case "$out" in
    keep:*)     skip "camofox: .replit [nix] channel already set (${out#keep:})" ;;
    inserted)   ok "camofox: added channel = \"$CAMOFOX_NIX_CHANNEL\" under the existing [nix] in .replit (replit.nix can now rebuild)" ;;
    appended)   ok "camofox: added [nix] channel = \"$CAMOFOX_NIX_CHANNEL\" to .replit (without it replit.nix triggers recovery mode and never rebuilds)" ;;
    *)          warn "camofox: unexpected [nix] channel result: $out" ;;
  esac
  # A malformed .replit breaks every later dot_replit / setup run — verify.
  python3 -c "import tomllib; tomllib.load(open('$f','rb'))" 2>/dev/null \
    || warn "camofox: .replit no longer parses as TOML after the channel edit — check $f"
}

camofox_ensure_store_libs() {
  # The persistence lane must be complete even on a warm box: replit.nix
  # deps + the .replit [nix] channel that lets the platform rebuild it.
  camofox_ensure_replit_nix
  camofox_ensure_nix_channel
  if ! camofox_store_cold; then
    skip "camofox: nix store warm (GTK/ALSA/X11 libs present)"
    return 0
  fi
  warn "camofox: nix store is COLD — no GTK/ALSA/X11 libs yet (fresh workspace)"
  if command -v nix-env >/dev/null 2>&1; then
    echo "  warming the store for THIS container: nix-env -iA ${CAMOFOX_NIXENV_ATTRS[*]}"
    nix-env -iA "${CAMOFOX_NIXENV_ATTRS[@]}" \
      || warn "camofox: nix-env warm-up failed — closure generation will likely fail; the replit.nix above fixes it after a Replit rebuild/restart"
  else
    warn "camofox: nix-env not found — cannot warm the store now; the replit.nix above fixes it after a Replit rebuild/restart"
  fi
  camofox_store_cold || ok "camofox: store warmed for this container (nix-env profile; replit.nix carries it across recreates)"
}

# --- managed Node.js requirement ---------------------------------------------
# Camofox REQUIRES the managed tarball node v$NODE_MAJOR (what --node
# installs). The node that runs THIS install is load-bearing twice over:
# `npm install -g` runs under it, and generate-closure.sh prepends the
# CURRENT node's linked store dirs to the front of the closure. The platform
# nix node's libs can require a newer glibc than the system one (its
# sqlite-3.53.3 needs GLIBC_2.44; the system glibc is 2.39), and Firefox — a
# system-glibc binary — then dies at EVERY launch with `GLIBC_2.44 not
# found` while the server and /health look fine (verified repl-test +
# repl-cfx, 2026-11-05). The managed node links only system libs, so nothing
# is prepended and the closure's own older sqlite wins.
# A bare `setup.sh --camofox` therefore installs the managed node FIRST
# (the same install_node --node runs) instead of warning after the damage
# is done, and dies if the node it ends up with is not the managed
# $NODE_MAJOR — never a silent fallback to the platform node.
camofox_node_id() {
  local bin; bin="$(command -v node 2>/dev/null || true)"
  [[ -n "$bin" ]] || { printf 'none'; return 0; }
  printf '%s %s' "$(readlink -f "$bin" 2>/dev/null || printf '%s' "$bin")" \
    "$(node --version 2>/dev/null || printf 'unknown')"
}

camofox_ensure_node() {
  local bin="$NODE_DIR/bin/node" ver major
  if [[ -x "$bin" ]]; then
    ver="$("$bin" --version 2>/dev/null || true)"
    major="${ver#v}"; major="${major%%.*}"
    if [[ "$major" == "$NODE_MAJOR" ]]; then
      skip "camofox: managed Node.js $ver present ($NODE_DIR)"
    else
      echo "  camofox: managed node at $NODE_DIR is ${ver:-unreadable} — camofox requires v$NODE_MAJOR.x, reinstalling"
      install_node
    fi
  else
    echo "  camofox requires the managed Node.js v$NODE_MAJOR.x (setup.sh --node) — installing it first"
    install_node
  fi
  # Present is not enough: THIS run must resolve node/npm to the managed
  # install even when PATH prefers the platform node (the usual case).
  export PATH="$NODE_DIR/bin:$PATH"
  # Hard-verify what the run will actually use — fail loudly, never fall
  # back to whatever node PATH would otherwise have found.
  local resolved; resolved="$(command -v node 2>/dev/null || true)"
  [[ -n "$resolved" && "$(readlink -f "$resolved")" == "$(readlink -f "$bin")" ]] \
    || die "camofox: node resolves to '${resolved:-nothing}' after ensuring the managed node — expected $bin. Fix PATH and re-run."
  ver="$(node --version 2>/dev/null || true)"
  major="${ver#v}"; major="${major%%.*}"
  [[ "$major" == "$NODE_MAJOR" ]] \
    || die "camofox: node is ${ver:-unknown} — camofox requires the managed v$NODE_MAJOR.x (the platform nix node poisons the closure; see camofox_ensure_node). Re-run: bash $SETUP_ENTRY --machine repl --node"
  command -v npm >/dev/null 2>&1 \
    || die "camofox: npm not on PATH after ensuring the managed node ($NODE_DIR/bin)"
  ok "camofox: using managed Node.js $ver ($bin)"
}

install_camofox() {
  step "Camofox browser (npm-global @askjo/camofox-browser, pinned $CAMOFOX_VERSION)"
  # FIRST: the managed Node.js $NODE_MAJOR — the closure is generated from
  # the node that runs this install, and the platform nix node poisons it
  # (see camofox_ensure_node). Installs it via --node's installer if absent.
  camofox_ensure_node
  mkdir -p "$XDG_BIN_HOME" "$CAMOFOX_STATE_DIR" "$CAMOUFOX_INSTALL_DIR"
  # Re-anchor closure.txt/env.sh from the older $XDG_DATA_HOME/camofox layout.
  camofox_migrate_aux_files

  # 1) package (idempotent; the version is PINNED — CAMOFOX_VERSION in
  # the profile — so a re-run can never float the browser to latest)
  # --allow-scripts: npm >= 12 BLOCKS dependency install scripts that are
  # not approved (npm <= 11 only warns — measured, see references/platform.md).
  # A global install has no project package.json to approve in, so approve
  # this install's script-bearing packages on the command line (npm's own
  # suggestion): the package itself + better-sqlite3 (native prebuild fetch).
  # Scoped to THIS install only — it does not touch the global guard
  # (npm_config_dangerously_allow_all_scripts stays unset, per rc.sh policy).
  echo "  npm install -g --allow-scripts=$CAMOFOX_NPM_PKG,better-sqlite3 $CAMOFOX_NPM_PKG@$CAMOFOX_VERSION"
  npm install -g --allow-scripts="$CAMOFOX_NPM_PKG,better-sqlite3" --registry=https://registry.npmjs.org/ "$CAMOFOX_NPM_PKG@$CAMOFOX_VERSION" \
    || die "npm install -g $CAMOFOX_NPM_PKG@$CAMOFOX_VERSION failed"
  [[ -x "$XDG_BIN_HOME/camofox-browser" || -x "$NODE_DIR/bin/camofox-browser" ]] \
    || command -v camofox-browser >/dev/null 2>&1 \
    || die "camofox-browser not on PATH after install"

  # 2) Replit compatibility patches
  camofox_patch_webgl
  camofox_raise_newpage_timeout
  camofox_pin_playwright

  # 2b) cold store (fresh workspace): declare the deps in replit.nix for the
  #     next rebuild AND warm this container with nix-env, so the closure
  #     below can be generated in the same run. No manual package editing.
  camofox_ensure_store_libs

  # 2c) (The platform-node guard used to warn here, after the fact; the
  #     requirement now runs FIRST — see camofox_ensure_node at the top.)

  # 3) lib closure (globally-safe: generate-closure.sh prunes openssl/curl/…).
  #     Regenerate when the file is missing, when a listed dir has vanished,
  #     OR when it was built under a DIFFERENT node than the one this run
  #     ensured (stamp mismatch). Closures built before the node requirement
  #     carry no stamp at all, so a poisoned platform-node closure left on a
  #     box regenerates here automatically instead of needing a manual rm.
  local _closure_stale=0
  [[ -s "$CAMOFOX_CLOSURE_FILE" ]] || _closure_stale=1
  if [[ -s "$CAMOFOX_CLOSURE_FILE" ]]; then
    [[ "$(tr ':' '\n' < "$CAMOFOX_CLOSURE_FILE" | while IFS= read -r d; do [[ -d "$d" ]] || echo gone; done)" != "" ]] && _closure_stale=1
    [[ "$(cat "$CAMOFOX_CLOSURE_STAMP" 2>/dev/null || true)" == "$(camofox_node_id)" ]] || _closure_stale=1
  fi
  if ((_closure_stale)); then
    echo "  generating GTK/X11 lib closure -> $CAMOFOX_CLOSURE_FILE"
    if bash "$REPL_SKILL_DIR/generate-closure.sh" "$CAMOFOX_CLOSURE_FILE"; then
      camofox_node_id > "$CAMOFOX_CLOSURE_STAMP"
    else
      warn "closure generation failed — camofox will not start until the nix store has gtk3/alsa-lib/xorg.libXdamage"
    fi
  fi

  # 4) engine (package-pinned Camoufox; skipped when already present+valid)
  local engine_bin="$CAMOUFOX_INSTALL_DIR/camoufox-bin"
  if [[ -x "$engine_bin" && -f "$CAMOUFOX_INSTALL_DIR/version.json" ]]; then
    skip "Camoufox engine present: $CAMOUFOX_INSTALL_DIR ($(cat "$CAMOUFOX_INSTALL_DIR/version.json" 2>/dev/null))"
  else
    echo "  fetching Camoufox engine into $CAMOUFOX_INSTALL_DIR (~1.3 GB)"
    ( cd "$(camofox_pkg_dir)" && CAMOUFOX_INSTALL_DIR="$CAMOUFOX_INSTALL_DIR" node lib/camoufox-download.js ) \
      || die "Camoufox engine fetch failed"
  fi

  # 5) closure env snippet + launcher shim (the latter for non-interactive
  #    consumers: .replit workflows, Run button — they never source env.sh)
  camofox_write_env_snippet
  camofox_write_env_example
  camofox_write_launcher

  # 6) state dir: re-anchor off the volatile $HOME/.camofox + persist the vars
  #    server-wide. ensure_libatomic is not the only durable-state concern —
  #    a cookie jar under $HOME is wiped on recreate.
  mkdir -p "$CAMOFOX_PROFILE_DIR" "$CAMOFOX_COOKIES_DIR" "$CAMOFOX_UPLOADS_DIR" "$CAMOFOX_TRACES_DIR" 2>/dev/null || true
  camofox_migrate_state
  record_tool_env_vars CAMOFOX_STATE_DIR CAMOFOX_PROFILE_DIR CAMOFOX_COOKIES_DIR \
                       CAMOFOX_UPLOADS_DIR CAMOFOX_TRACES_DIR

  ok "camofox installed — run: camofox-browser   (API on http://127.0.0.1:9377)"

  record_tool_env_vars CAMOUFOX_INSTALL_DIR
  record_tool_path_dirs "$XDG_BIN_HOME"
  wire_tool camofox CAMOUFOX_INSTALL_DIR -- "$XDG_BIN_HOME"
}

clean_camofox() {
  local pkg; pkg="$(camofox_pkg_dir)"
  if ! _present "$pkg" "$CAMOUFOX_INSTALL_DIR" "$XDG_BIN_HOME/camofox-browser"; then
    nothing_removed "Camofox"; return 0
  fi
  step "Removing Camofox browser"
  if command -v npm >/dev/null 2>&1; then
    npm_config_prefix="$NPM_GLOBAL_PREFIX" npm uninstall -g "$CAMOFOX_NPM_PKG" \
      || warn "npm uninstall -g $CAMOFOX_NPM_PKG failed — remove $pkg by hand"
  fi
  rm -f "$XDG_BIN_HOME/camofox-browser" "$XDG_BIN_HOME/camofox-browser-mcp" \
        "$XDG_BIN_HOME/launch-camofox-browser"
  # Engine (re-fetchable) + closure/env snippet (aux files under the state dir).
  rm -rf "$CAMOUFOX_INSTALL_DIR"
  rm -f "$CAMOFOX_CLOSURE_FILE" "$CAMOFOX_CLOSURE_STAMP" "$CAMOFOX_ENV_SNIPPET"
  rm -rf "${XDG_DATA_HOME:-$HOME/.local/share}/camofox"   # older layout, if still present
  # Server state (cookies/profiles) is user data — kept; delete $CAMOFOX_STATE_DIR to wipe.
  ok "Camofox removed (engine + closure + package; server state kept in $CAMOFOX_STATE_DIR)"
}