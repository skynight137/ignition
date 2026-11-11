#!/usr/bin/env python3
"""tour.py — the unified session keep-alive tour (fleet session keep-alive).

A SHARED ready-to-run script: it lives at the scripts/ root — NOT in
scripts/setup/ (setup prepares; it never runs things) — and serves
both machine kinds, selected by `--machine muse|repl` (env
TOUR_MACHINE fallback; default auto-detect, mirroring setup.sh:
REPL_HOME set → repl, else muse). The machine picks the defaults that
differ per VM kind — the XDG base the engine homes resolve under, the
default cookie-jar location, the default log dir — while every
explicit env var still wins over a machine default.

ONE tour program, engine chosen by flag: `--browser lightpanda|camofox`
(env TOUR_BROWSER fallback, default lightpanda). It supersedes lp-tour.py
(the Lightpanda-only tour) — the Lightpanda engine below is that proven
program ported unchanged in mechanics; the camofox engine drives the
camofox server API through its own built-in client (below) and reaches
the same diagnosis grade. See references/lightpanda.md and
references/session-keepalive.md for the engine comparison and mechanics.

Both engines implement ONE adapter pattern, and engine selection is
a REGISTRY, not a branch: the ENGINES dict (engine registry section,
above the config block) maps each --browser value to one adapter, and
every dispatch site — --check, tour-start prepare, the per-round and
per-stop calls, signal teardown — goes through it. Adding an engine
(say --browser chromium) is exactly two steps: write one adapter
implementing the interface (env_file, jar_default, config_line,
check, prepare, prepare_round, run_stop, teardown — see the _Engine
base class) and add one line to ENGINES. No dispatch site changes.
The stop lifecycle every adapter follows:
  prepare (resolve config + credentials, probe the engine's runtime)
  → plant cookies → open one session/tab on the target URL → poll and
  sample until the shared verdict engine decides → optional cookie
  read-back (Lightpanda write-back) → close the session/tab.
Verdicts, dwell handling and the circuit breaker live OUTSIDE the
adapters, in the shared tour loop.

The job, engine-independent: sequential stops over TOUR_LINKS — for each
project URL, open the page logged-in (cookie jar), hold it for the dwell,
close everything, move to the next stop. A round is len(LINKS) x
(DWELL + GAP); that open cadence — not any in-tab refresh — is what holds
a fleet of Replit workspaces inside their idle tolerance.

Verdicts per stop (BOTH engines): SHELL / LOGGED-OUT-WALL (visible text
contains both "Log in" and "Sign up", confirmed by a second probe 5s
later — the camofox --fail-text discipline) / CF-STALL (poll budget spent
on the "Just a moment..." title; Cloudflare normally clears by itself in
~7-18s) / ERROR (transport/server failure) / UNKNOWN, with time-to-shell
per stop and title tracking. After a SHELL verdict the tab is held for
the full dwell and re-probed: still-shell is logged. Circuit breaker:
TOUR_MAX_EARLY_FAILURES CONSECUTIVE non-SHELL stops abort the tour
(`*** tour ABORTED`, exit 1); a SHELL stop resets the count. ALL page
reads in the poll loop are bounded — asyncio.wait_for on the Lightpanda
side, an explicit request timeout on every camofox call — because a
stuck challenge page once wedged an unbounded read for ~100s.

Lightpanda engine (proven shape, fleet trial 2026-11-06):
  * one fresh server per stop, torn down after the stop: Lightpanda has
    zero idle cost, so there is no resident server to keep warm;
  * the server's stdout/stderr go to a per-stop log FILE, never a pipe —
    an undrained PIPE wedges the server silently;
  * cookies plant ONLY via the server's native --cookie loader, with the
    jar converted to a CDP cookie array. Playwright's Storage.setCookies
    FAILS against Lightpanda (BrowserContextNotLoaded) — do not "fix"
    this by switching to CDP planting;
  * navigation always goes through a fresh ctx.new_page(): the default
    CDP page is a non-navigable startup session;
  * the jar is re-converted every round, so a re-imported jar is picked
    up without restarting the tour;
  * TOUR_JAR_WRITEBACK: after each SHELL stop the live session's cookies
    are merged back into the jar (freshest per name/domain/path, atomic
    tmp+replace, mode 600, fail-open), so the session keeps what it
    earns — notably a cf_clearance — across stops and rounds instead of
    re-facing the challenge from a static jar.

Popup dismissal (BOTH engines): a rendered shell is not a booted
workspace — Replit parks blocking dialogs on the project page (the
"Keep using Replit?" session dialog, the Starter-limit upsell) and
the workspace does not start until they are closed (fleet finding,
user-verified 2026-11-07: SHELL in the log, node offline in the
netmap). Each stop therefore dismisses popups — once the shell is
reached, before the dwell, and again before the post-hold sample —
clicking ONLY whitelisted dismiss controls (see POPUP_SAFE_TEXTS /
POPUP_NEVER_RE above the Lightpanda engine). The stop summary counts
them (`popups_dismissed=<n>`); a limit/upsell dialog still standing
afterwards is logged as `popup-wall:` (observability only — SHELL
alone never proved a boot; the netmap is the judge).

Camofox engine (the fallback engine):
  * drives the camofox SERVER's HTTP API via its own built-in client
    (cf_req/cf_convert/cf_dismiss_dialogs/cf_diagnose_timeout, in the
    engine section below) — SELF-CONTAINED since S5d: the client is
    the one the deleted camofox.py CLI used (same requests, same key
    selection, same timeout diagnosis), carried into the tour when
    that refresh-page-era CLI was removed; no cross-tree import, so
    --browser camofox works in any tree that carries tour.py alone;
  * the server is a resident service the CALLER runs (its own workflow);
    the tour NEVER spawns it — an unreachable server is an ERROR verdict
    (and a --check failure), surfaced, not papered over;
  * cookies go in through the server's import path
    (POST /sessions/<user>/cookies) once at tour start, when a jar file
    exists; with no jar the server's persisted per-user cookies are used;
  * one session per stop, closed at teardown (DELETE /tabs/group/<s>),
    so tabs never outlive the stop that opened them.

Log standard: every line is `[YYYY-MM-DD HH:MM:SS] [LEVEL] message`
(LEVEL = INFO/OK/SKIP/WARN/ERROR), PLAIN by default so file logs grep
clean; colour is opt-in via --colour or TOUR_LOG_COLOUR=1 and wraps ONLY
the [LEVEL] token.

Config (fleet "big env" rule: a var already set in the system
environment WINS; the engine home's .env file only fills gaps; the
source of every var is logged at startup, name + source only):
  file      lightpanda: $LIGHTPANDA_HOME/.env (LIGHTPANDA_ENV_FILE wins)
            camofox:    $XDG_CONFIG_HOME/camofox/.env (CAMOFOX_ENV_FILE
                        wins, then legacy $CAMOFOX_ROOT/.env — the same
                        discovery the camofox lane itself documents)
  TOUR_LINKS          required: comma/whitespace-separated project URLs
                      (fallback: LP_LINKS — the lp-tour-era name, kept
                      for one release so captain .env files work as-is)
  TOUR_BROWSER        lightpanda|camofox (fallback for --browser)
  TOUR_MACHINE        muse|repl (fallback for --machine; default
                      auto-detect: REPL_HOME set → repl, else muse —
                      the same rule setup.sh uses. Like TOUR_BROWSER
                      it is NOT read from the .env file: the file's
                      own location depends on the machine's homes)
  TOUR_COOKIES        cookie jar, browser-export or Playwright format
                      (fallback LP_COOKIES; default lightpanda:
                      $LIGHTPANDA_HOME/cookies.json, camofox:
                      $XDG_CONFIG_HOME/camofox/cookies.json)
  TOUR_DWELL_S        seconds the tab is held per stop   (default 60)
  TOUR_GAP_S          sleep between stops, tab closed    (default 0)
  TOUR_POLL_S         budget for the shell marker        (default 150;
                      fallback LP_POLL_S)
  TOUR_MAX_EARLY_FAILURES  circuit breaker, 0 = never    (default 3)
  TOUR_MAX_ROUNDS     0 = tour forever                   (default 0;
                      fallback LP_MAX_ROUNDS)
  TOUR_ONLY           run only the stop with this last path segment
                      (fallback LP_ONLY)
  TOUR_JAR_WRITEBACK  lightpanda only: 1 = merge live cookies back into
                      the jar after each SHELL stop (default off;
                      fallback LP_JAR_WRITEBACK; merge-only, fail-open)
  TOUR_LOG_COLOUR     1 = colour the [LEVEL] token       (default off)
  TOUR_BASE_PORT      lightpanda: first CDP port; stop i uses +i
                      (default 19401; fallback LP_BASE_PORT)
  TOUR_LOG_DIR        lightpanda: per-stop server logs   (fallback
                      LP_LOG_DIR; default is machine-chosen: repl
                      $REPL_HOME/logs, muse ~/workspace/logs)
  TOUR_CAMOFOX_USER   camofox: server user id holding the session
                      (default "tour")
  TOUR_CAMOFOX_SESSION  camofox: session-key prefix; stop i uses
                      "<prefix>-<i>"                     (default "tour")
  TOUR_CAMOFOX_WAIT_S  camofox: seconds the run-path prepare waits
                      for the server at tour start (Project starts
                      the launcher and the tour in parallel; the
                      --check probe stays one-shot)    (default 180)
  CAMOFOX_BASE_URL    camofox: server URL (default http://127.0.0.1:9377)
  TOUR_PW_HEADLESS    patchright/cloakbrowser: headless launch
                      (default true)
  TOUR_CLOAK_HUMANIZE cloakbrowser: behavioural humanize layer
                      (default off)
  MOLI_CDP_URL        moli: `moli serve` CDP endpoint
                      (default http://127.0.0.1:9222)
  TOUR_MOLI_AUTOSTART moli: 1 = the tour spawns `moli serve` itself
                      when the endpoint is down (default on; 0 = a
                      resident launcher owns the server)
  MOLI_BIN            moli: engine binary (default $MOLI_HOME/moli,
                      then `moli` on PATH)
  MOLI_HOME           install/state root (default <machine XDG
                      config base>/moli)
  LIGHTPANDA_HOME     install/state root (default <machine XDG config
                      base>/lightpanda: $XDG_CONFIG_HOME when set, else
                      repl $REPL_HOME/.config, muse ~/.config)
  LIGHTPANDA_BIN      engine binary (default $LIGHTPANDA_HOME/lightpanda,
                      then `lightpanda` on PATH)

Run via tour.sh (it assembles LD_LIBRARY_PATH on nix boxes + the
venv python, and passes --browser/--machine straight through).
`tour.py --check` resolves and prints the config, probes the engine
(binary + jar for lightpanda, server health + jar for camofox), and
exits without opening anything.
"""
import asyncio, json, os, shutil, signal, socket, subprocess, sys, time, urllib.error, urllib.request

# ── engine selection ───────────────────────────────────────────────────
# Resolved BEFORE the rest of config: the .env fallback file lives in
# the chosen engine's home, so the engine must be known first. CLI
# --browser wins, then TOUR_BROWSER from the SYSTEM env (the .env file
# cannot move its own home, so it is not consulted for this one var),
# then DEFAULT_BROWSER. The name is only a KEY: the ENGINES registry
# (below, after machine selection — env discovery needs the machine's
# homes) maps it to the adapter that actually runs.


def _cli_browser(argv):
    for i, a in enumerate(argv):
        if a == "--browser" and i + 1 < len(argv):
            return argv[i + 1]
        if a.startswith("--browser="):
            return a.split("=", 1)[1]
    return None


DEFAULT_BROWSER = "lightpanda"
BROWSER = (_cli_browser(sys.argv[1:])
           or os.environ.get("TOUR_BROWSER")
           or DEFAULT_BROWSER).strip().lower()
_COLOUR_FLAG = "--colour" in sys.argv or "--color" in sys.argv


def _cli_machine(argv):
    for i, a in enumerate(argv):
        if a == "--machine" and i + 1 < len(argv):
            return argv[i + 1]
        if a.startswith("--machine="):
            return a.split("=", 1)[1]
    return None


# ── machine selection ──────────────────────────────────────────────────
# Mirrors setup.sh exactly: --machine wins, then TOUR_MACHINE from the
# SYSTEM env (not the .env file — the file lives in the machine's
# engine home, so it cannot choose its own machine), then auto-detect:
# REPL_HOME set (a Replit workspace) → repl, otherwise muse. The
# machine selects the defaults that differ per VM kind (the XDG base
# below, the jar and log-dir defaults); every explicit env var still
# wins over a machine default.
_cli_m = _cli_machine(sys.argv[1:])
if _cli_m:
    MACHINE, MACHINE_SOURCE = _cli_m.strip().lower(), "--machine flag"
elif os.environ.get("TOUR_MACHINE"):
    MACHINE = os.environ["TOUR_MACHINE"].strip().lower()
    MACHINE_SOURCE = "TOUR_MACHINE env"
elif os.environ.get("REPL_HOME"):
    MACHINE, MACHINE_SOURCE = "repl", "auto-detect (REPL_HOME set)"
else:
    MACHINE, MACHINE_SOURCE = "muse", "auto-detect (default)"

# XDG config base: a set XDG_CONFIG_HOME wins on both machines (it IS
# the system env); the fallback is machine-shaped — repl anchors app
# config in the workspace (.config under REPL_HOME), muse uses the
# platform home (~/.config, which guest.env also exports).
if os.environ.get("XDG_CONFIG_HOME"):
    _XDG = os.environ["XDG_CONFIG_HOME"]
elif MACHINE == "repl":
    _XDG = os.path.join(os.environ.get("REPL_HOME")
                        or os.path.expanduser("~"), ".config")
else:
    _XDG = os.path.expanduser("~/.config")
_LP_HOME_AMBIENT = os.environ.get("LIGHTPANDA_HOME") or os.path.join(
    _XDG, "lightpanda")
_CF_CONFIG_HOME = os.path.join(_XDG, "camofox")
_PW_HOME = os.path.join(_XDG, "patchright")
_CLOAK_HOME = os.path.join(_XDG, "cloakbrowser")
_MOLI_HOME = os.path.join(_XDG, "moli")


# ══ engine registry ═══════════════════════════════════════════════════
# --browser selects an ADAPTER from this registry — there are no
# engine-name branches anywhere else in the file. An adapter owns
# everything that differs per engine:
#   env_file()    -> the .env fallback file for this engine (its home
#                    must be discoverable before config loads, so this
#                    one may only use the ambient homes above)
#   jar_default() -> default cookie-jar path when TOUR_COOKIES is unset
#   config_line() -> the engine's `config: resolved: ...` line
#   check()       -> the engine's --check probe block; returns 0 or 1
#   prepare()     -> tour-start work (probe the runtime, plant the
#                    cookies); returns the cookies note for the start
#                    log line; FATAL problems log + sys.exit(2) here,
#                    exactly as the inline blocks did
#   prepare_round(rnd) -> per-round work before the stops (default:
#                    none — Lightpanda re-converts its jar)
#   run_stop(idx, url) -> async; one stop, returning
#                    (verdict, time_to_shell_s, rss_peak_mb,
#                    popups_dismissed)
#   teardown()    -> signal-time cleanup of a live stop (default:
#                    none); _cleanup calls it on EVERY registered
#                    engine, so the inactive engine's no-op keeps the
#                    old both-globals-checked semantics
# The engine bodies themselves (run_stop_lightpanda, the cf_* client,
# run_stop_camofox) live in the engine sections below and are called
# from these adapters at runtime. Adding an engine = one more adapter
# class + one more ENGINES line.


class _Engine:
    """The adapter interface. Methods an engine does not need keep
    the base no-op; the rest raise until implemented."""

    def env_file(self):
        raise NotImplementedError

    def jar_default(self):
        raise NotImplementedError

    def config_line(self):
        raise NotImplementedError

    def check(self):
        raise NotImplementedError

    def prepare(self):
        raise NotImplementedError

    def prepare_round(self, rnd):
        pass

    async def run_stop(self, idx, url):
        raise NotImplementedError

    def teardown(self):
        pass


class _LightpandaEngine(_Engine):
    def env_file(self):
        # The lightpanda home — the same discovery the engine's own
        # tooling uses.
        return (os.environ.get("LIGHTPANDA_ENV_FILE")
                or os.path.join(_LP_HOME_AMBIENT, ".env"))

    def jar_default(self):
        return os.path.join(HOME, "cookies.json")

    def config_line(self):
        return (f"config: resolved: home={HOME} bin={BIN} jar={JAR} "
                f"base_port={BASE_PORT} writeback={WRITEBACK}")

    def check(self):
        rc = 0
        if os.path.isfile(BIN) and os.access(BIN, os.X_OK):
            ver = subprocess.run([BIN, "version"], capture_output=True,
                                 text=True, timeout=10)
            print(f"check: binary ok: {BIN} (version "
                  f"{ver.stdout.strip() or '?'})", flush=True)
        else:
            print(f"check: binary MISSING or not executable: {BIN} — "
                  "run: bash setup.sh --lightpanda", flush=True)
            rc = 1
        if os.path.exists(JAR):
            try:
                n = convert_jar()
                print(f"check: jar ok: {JAR} ({n} cookies)", flush=True)
            except Exception as e:
                print(f"check: jar UNREADABLE: {JAR}: {e}", flush=True)
                rc = 1
        else:
            print(f"check: jar missing: {JAR} — a tour would FATAL on "
                  "it; export a fresh jar from the account's browser "
                  "session", flush=True)
            rc = 1
        return rc

    def prepare(self):
        if not os.path.exists(JAR):
            log(f"FATAL: jar missing at {JAR}", "ERROR")
            sys.exit(2)
        if not (os.path.isfile(BIN) and os.access(BIN, os.X_OK)):
            log(f"FATAL: lightpanda binary missing at {BIN} — "
                "run: bash setup.sh --lightpanda", "ERROR")
            sys.exit(2)
        n = convert_jar()
        return f" cookies={n}"

    def prepare_round(self, rnd):
        try:
            n = convert_jar()
            log(f"round {rnd}: jar reconverted, cookies={n}", "SKIP")
        except Exception as e:
            log(f"round {rnd}: jar reconvert failed ({e}); "
                "reusing previous", "WARN")

    async def run_stop(self, idx, url):
        return await run_stop_lightpanda(idx, url)

    def teardown(self):
        if CURRENT_SRV is not None:
            try:
                CURRENT_SRV.kill()
            except Exception:
                pass


class _CamofoxEngine(_Engine):
    def env_file(self):
        # The camofox lane's documented candidate order.
        root = os.environ.get("CAMOFOX_ROOT") or os.path.join(
            os.environ.get("REPL_HOME") or os.path.expanduser("~"),
            "camofox")
        for p in (os.environ.get("CAMOFOX_ENV_FILE"),
                  os.path.join(_CF_CONFIG_HOME, ".env"),
                  os.path.join(root, ".env")):
            if p and os.path.exists(p):
                return p
        return os.path.join(_CF_CONFIG_HOME, ".env")

    def jar_default(self):
        return os.path.join(_CF_CONFIG_HOME, "cookies.json")

    def config_line(self):
        return (f"config: resolved: camofox url={CF_URL} "
                f"user={CF_USER} session={CF_SESSION}-<i> jar={JAR}")

    def check(self):
        rc = 0
        key = cf_key()
        h = cf_health(key)
        if h is not None:
            print(f"check: camofox server ok: {CF_URL} "
                  f"(browserRunning={h.get('browserRunning')}, "
                  f"activeSessions={h.get('activeSessions')})",
                  flush=True)
        else:
            print(f"check: camofox server UNREACHABLE at {CF_URL} — "
                  "the tour never spawns it; start the camofox service "
                  "(camofox launcher / its workflow) first",
                  flush=True)
            print(cf_diagnose_timeout(), flush=True)
            rc = 1
        if os.path.exists(JAR):
            try:
                raw = json.load(open(JAR))
                items = raw.get("cookies", raw) \
                    if isinstance(raw, dict) else raw
                print(f"check: jar ok: {JAR} ({len(items)} cookies, "
                      f"imported for user {CF_USER} at tour start)",
                      flush=True)
            except Exception as e:
                print(f"check: jar UNREADABLE: {JAR}: {e}", flush=True)
                rc = 1
        else:
            print(f"check: jar missing: {JAR} — not fatal for camofox: "
                  f"the server's persisted cookies for user {CF_USER} "
                  "will be used; import a jar to refresh them",
                  flush=True)
        return rc

    def prepare(self):
        key = cf_key()
        h = cf_health(key)
        waited = 0.0
        if h is None and CF_WAIT > 0:
            # Project starts launch-camofox and this tour in the
            # same second: the server needs seconds to bind and
            # pre-warm its browser that a one-shot probe does not
            # give it (proven live on repl-10 2026-11-07 — FATAL at
            # T+0, server answering T+2, pre-warm done T+10). Poll
            # the same health check until it answers or the budget
            # expires; --check stays one-shot (it diagnoses the
            # current state, it does not wait for a future one).
            log(f"camofox: server not answering at {CF_URL} yet — "
                f"waiting up to {CF_WAIT}s for it "
                "(TOUR_CAMOFOX_WAIT_S)")
            t0 = time.time()
            nxt = 30.0
            while h is None and waited < CF_WAIT:
                time.sleep(min(3.0, CF_WAIT - waited))
                h = cf_health(key)
                waited = time.time() - t0
                if h is None and waited >= nxt:
                    log(f"camofox: still waiting for the server "
                        f"({waited:.0f}s of {CF_WAIT}s)", "SKIP")
                    nxt += 30.0
            if h is not None:
                log(f"camofox: server up after {waited:.0f}s of "
                    "waiting", "OK")
        if h is None:
            log(f"FATAL: camofox server unreachable at {CF_URL} — "
                "the tour never spawns it; start the camofox service "
                f"first (waited {waited:.0f}s)", "ERROR")
            sys.exit(2)
        if os.path.exists(JAR):
            ok, detail = cf_import_cookies(key)
            if not ok:
                log(f"FATAL: cookie import failed: {detail}", "ERROR")
                sys.exit(2)
            log(f"camofox: imported {detail} cookies for user {CF_USER}")
            return f" cookies={detail} (imported, user={CF_USER})"
        log(f"camofox: no jar at {JAR} — using the server's "
            f"persisted cookies for user {CF_USER}", "WARN")
        return f" cookies=persisted (user={CF_USER})"

    async def run_stop(self, idx, url):
        # The camofox stop is sync HTTP; run it in a thread so the
        # event loop stays free (the pre-registry dispatch did the
        # same via asyncio.to_thread).
        return await asyncio.to_thread(run_stop_camofox, idx, url)

    def teardown(self):
        if CURRENT_CF is not None:
            try:
                key, session = CURRENT_CF
                cf_req(key, "DELETE",
                       f"/tabs/group/{session}?userId={CF_USER}",
                       timeout=5)
            except Exception:
                pass


class _PwEngine(_Engine):
    """Shared adapter for the local Playwright engines (the section
    below the Lightpanda engine): a real local Chromium, launched
    once per tour process and reused by every stop. Subclasses set
    KEY (registry name), HOME (engine home), LAUNCH (the async
    launcher in the engine section). prepare() is sync by interface,
    so it only validates; the browser itself launches lazily inside
    the first stop (pw_ensure_session) and the cookie injection is
    logged there."""

    KEY = ""
    HOME = ""
    LAUNCH = None

    def env_file(self):
        return os.path.join(self.HOME, ".env")

    def jar_default(self):
        return os.path.join(self.HOME, "cookies.json")

    def profile_dir(self):
        return os.path.join(self.HOME, "profile")

    def fragment(self):
        # The pgrep -f pattern that finds this engine's browser
        # processes (RSS sampling + teardown). Local engines match
        # on their profile dir (it is in the browser's cmdline);
        # server-shaped engines override it.
        return self.profile_dir()

    def session_killable(self):
        # Whether teardown may kill the browser processes behind a
        # live session of this engine. Local engines launch theirs;
        # a server-shaped engine whose server the tour did NOT spawn
        # (moli with a resident launcher) overrides this.
        return True

    def config_line(self):
        return (f"config: resolved: {self.KEY} "
                f"profile={self.profile_dir()} jar={JAR} "
                f"headless={PW_HEADLESS}")

    def check(self):
        rc = 0
        import importlib.util
        if importlib.util.find_spec(self.KEY) is not None:
            print(f"check: {self.KEY} package importable in the tour "
                  "venv", flush=True)
        else:
            print(f"check: {self.KEY} package MISSING in the tour "
                  f"venv — pip install {self.KEY} into it",
                  flush=True)
            rc = 1
        if os.path.exists(JAR):
            try:
                n = len(pw_cookies())
                print(f"check: jar ok: {JAR} ({n} cookies)", flush=True)
            except Exception as e:
                print(f"check: jar UNREADABLE: {JAR}: {e}", flush=True)
                rc = 1
        else:
            print(f"check: jar missing: {JAR} — a tour would FATAL "
                  "on it", flush=True)
            rc = 1
        return rc

    def prepare(self):
        if not os.path.exists(JAR):
            log(f"FATAL: jar missing at {JAR}", "ERROR")
            sys.exit(2)
        import importlib.util
        if importlib.util.find_spec(self.KEY) is None:
            log(f"FATAL: {self.KEY} package missing in the tour "
                f"venv — pip install {self.KEY} into it", "ERROR")
            sys.exit(2)
        n = len(pw_cookies())
        return f" cookies={n} (injected at first stop)"

    async def run_stop(self, idx, url):
        try:
            sess = await pw_ensure_session(self)
        except Exception as e:
            # A launch failure (missing libs, a license gate, a
            # broken download) is THIS stop's ERROR verdict, not a
            # dead tour — the breaker decides when to give up.
            log(f"stop {url.rsplit('/', 1)[-1]}: session launch "
                f"failed: {type(e).__name__} {str(e)[:160]}", "ERROR")
            return "ERROR", None, 0, 0
        return await run_stop_pw(idx, url, sess)

    def teardown(self):
        pw_kill_session()


class _PatchrightEngine(_PwEngine):
    KEY = "patchright"
    HOME = _PW_HOME
    LAUNCH = "_pw_launch_patchright"


class _CloakEngine(_PwEngine):
    KEY = "cloakbrowser"
    HOME = _CLOAK_HOME
    LAUNCH = "_pw_launch_cloak"


class _MoliEngine(_PwEngine):
    """Moli differs from the other Playwright engines in two ways:
    there is no pip package to probe (the engine is a standalone
    binary + CDP server, installed by the --moli setup lane), and
    the browser process is the server — so the session fragment is
    the serve cmdline, and teardown kills ONLY a server this tour
    spawned (a resident launch-moli server is the caller's, like
    camofox's)."""

    KEY = "moli"
    HOME = _MOLI_HOME
    LAUNCH = "_pw_launch_moli"

    def fragment(self):
        return "moli serve"

    def session_killable(self):
        # Only a server THIS tour spawned is the tour's to kill; a
        # resident launch-moli server belongs to the caller.
        return MOLI_SERVER_PROC is not None

    def config_line(self):
        return (f"config: resolved: {self.KEY} "
                f"cdp={MOLI_CDP_URL} jar={JAR} "
                f"autostart={MOLI_AUTOSTART}")

    def check(self):
        rc = 0
        if os.path.exists(MOLI_BIN) and os.access(MOLI_BIN, os.X_OK):
            print(f"check: moli binary ok: {MOLI_BIN}", flush=True)
        else:
            print(f"check: moli binary MISSING at {MOLI_BIN} — "
                  "run: bash setup.sh --moli", flush=True)
            rc = 1
        import importlib.util
        if importlib.util.find_spec("playwright") is not None:
            print("check: playwright package importable in the tour "
                  "venv", flush=True)
        else:
            print("check: playwright package MISSING in the tour "
                  "venv — the moli engine drives CDP through it",
                  flush=True)
            rc = 1
        if os.path.exists(JAR):
            try:
                n = len(pw_cookies())
                print(f"check: jar ok: {JAR} ({n} cookies)",
                      flush=True)
            except Exception as e:
                print(f"check: jar UNREADABLE: {JAR}: {e}",
                      flush=True)
                rc = 1
        else:
            print(f"check: jar missing: {JAR} — a tour would FATAL "
                  "on it", flush=True)
            rc = 1
        return rc

    def prepare(self):
        if not os.path.exists(JAR):
            log(f"FATAL: jar missing at {JAR}", "ERROR")
            sys.exit(2)
        if not os.path.exists(MOLI_BIN):
            log(f"FATAL: moli binary missing at {MOLI_BIN} — run: "
                "bash setup.sh --moli", "ERROR")
            sys.exit(2)
        n = len(pw_cookies())
        return f" cookies={n} (injected at first stop)"

    def teardown(self):
        global MOLI_SERVER_PROC
        if MOLI_SERVER_PROC is not None:
            try:
                MOLI_SERVER_PROC.kill()
            except Exception:
                pass
            MOLI_SERVER_PROC = None


ENGINES = {
    "lightpanda": _LightpandaEngine(),
    "camofox": _CamofoxEngine(),
    "patchright": _PatchrightEngine(),
    "cloakbrowser": _CloakEngine(),
    "moli": _MoliEngine(),
}
# The resolved adapter for this run (None when --browser names no
# registered engine — check()/main() reject that before anything
# runs). _CFG_ENGINE is the config-time view: for an unknown name it
# falls back to the default engine, exactly as the old else-branches
# resolved an unknown name's env file and jar default.
ENGINE = ENGINES.get(BROWSER)
_CFG_ENGINE = ENGINE if ENGINE is not None else ENGINES[DEFAULT_BROWSER]

ENV_FILE = _CFG_ENGINE.env_file()


# ── config ─────────────────────────────────────────────────────────────
def _load_env_file(path):
    """KEY=VALUE lines from the .env file (no expansion, quotes stripped)."""
    out = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                v = v.strip()
                if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                    v = v[1:-1]
                out[k.strip()] = v
    except FileNotFoundError:
        pass
    return out


_FILE_ENV = _load_env_file(ENV_FILE)
CONFIG_SOURCES = []


def cfg_chain(names, default=""):
    """First name that resolves wins: system env > .env file > default.
    TOUR_* names are listed before their lp-tour-era fallbacks, so an
    old .env keeps working and a new one takes precedence. The
    resolution is logged (name + source only, never a value)."""
    for name in names:
        if os.environ.get(name):
            CONFIG_SOURCES.append(
                f"{name}: from system env (.env file skipped)")
            return os.environ[name]
        if _FILE_ENV.get(name):
            CONFIG_SOURCES.append(f"{name}: from .env file ({ENV_FILE})")
            return _FILE_ENV[name]
    CONFIG_SOURCES.append(f"{'/'.join(names)}: from default")
    return default


def cfg(name, default=""):
    return cfg_chain([name], default)


def cfg_int_chain(names, default):
    raw = cfg_chain(names, str(default))
    try:
        return int(raw)
    except ValueError:
        print(f"config: {'/'.join(names)}={raw!r} is not an integer — "
              f"using {default}", flush=True)
        return default


def cfg_int(name, default):
    return cfg_int_chain([name], default)


HOME = cfg("LIGHTPANDA_HOME", _LP_HOME_AMBIENT)
BIN = cfg("LIGHTPANDA_BIN") or os.path.join(HOME, "lightpanda")
if not os.path.exists(BIN):
    BIN = shutil.which("lightpanda") or BIN
_JAR_DEFAULT = _CFG_ENGINE.jar_default()
JAR = cfg_chain(["TOUR_COOKIES", "LP_COOKIES"], _JAR_DEFAULT)
ARRAY = os.path.join(HOME, ".jar-array.json")
# Default log dir is machine-chosen (the workspace log hub on both
# kinds); TOUR_LOG_DIR/LP_LOG_DIR still override it.
_LOG_DIR_DEFAULT = (os.path.join(os.environ.get("REPL_HOME")
                                 or os.path.expanduser("~"), "logs")
                    if MACHINE == "repl"
                    else os.path.join(os.path.expanduser("~"),
                                      "workspace", "logs"))
LOG_DIR = cfg_chain(["TOUR_LOG_DIR", "LP_LOG_DIR"], _LOG_DIR_DEFAULT)

DWELL = cfg_int("TOUR_DWELL_S", 60)
GAP = cfg_int("TOUR_GAP_S", 0)
BREAKER = cfg_int("TOUR_MAX_EARLY_FAILURES", 3)
POLL = cfg_int_chain(["TOUR_POLL_S", "LP_POLL_S"], 150)
BASE_PORT = cfg_int_chain(["TOUR_BASE_PORT", "LP_BASE_PORT"], 19401)
MAX_ROUNDS = cfg_int_chain(["TOUR_MAX_ROUNDS", "LP_MAX_ROUNDS"], 0)
WRITEBACK = cfg_chain(["TOUR_JAR_WRITEBACK", "LP_JAR_WRITEBACK"], "") \
    in ("1", "true", "yes")
ONLY = cfg_chain(["TOUR_ONLY", "LP_ONLY"], "")
COLOUR = _COLOUR_FLAG or cfg("TOUR_LOG_COLOUR", "") in ("1", "true", "yes")

CF_USER = cfg("TOUR_CAMOFOX_USER", "tour")
CF_SESSION = cfg("TOUR_CAMOFOX_SESSION", "tour")
CF_URL = cfg("CAMOFOX_BASE_URL", "http://127.0.0.1:9377").rstrip("/")
# Key selection mirrors the deleted camofox.py's load_key: the ACCESS
# key wins (the server's global gate checks it on every route except
# /health); the API key is the fallback — and the ONLY key the cookie
# import route accepts, so it is resolved separately too.
CF_KEY = cfg_chain(["CAMOFOX_ACCESS_KEY", "CAMOFOX_API_KEY"], "") or None
CF_API_KEY = cfg("CAMOFOX_API_KEY", "") or None
# Startup wait budget for the camofox prepare below: Project starts
# launch-camofox and the tour in parallel, so the server is routinely
# still starting when the tour first probes it.
CF_WAIT = cfg_int("TOUR_CAMOFOX_WAIT_S", 180)

# Local Playwright engines (patchright / cloakbrowser): one shared
# headless knob; cloak's behavioural layer is opt-in (a tour only
# opens pages — humanize matters when a flow types/clicks through).
PW_HEADLESS = cfg("TOUR_PW_HEADLESS", "true") in ("1", "true", "yes")
CLOAK_HUMANIZE = cfg("TOUR_CLOAK_HUMANIZE", "") in ("1", "true", "yes")

# Moli engine: a CDP server (`moli serve`) driven through
# Playwright's connect_over_cdp, like the local engines — but the
# session state (cookies + web storage, in the server's own SQLite
# partitions) persists inside the server across restarts, so the
# jar import at session start is a seed, not the state itself.
MOLI_CDP_URL = cfg("MOLI_CDP_URL", "http://127.0.0.1:9222").rstrip("/")
MOLI_AUTOSTART = cfg("TOUR_MOLI_AUTOSTART", "1") in ("1", "true", "yes")
MOLI_BIN = cfg("MOLI_BIN") or os.path.join(_MOLI_HOME, "moli")
if not os.path.exists(MOLI_BIN):
    MOLI_BIN = shutil.which("moli") or MOLI_BIN

LINKS = [u for u in cfg_chain(["TOUR_LINKS", "LP_LINKS"], "")
         .replace(",", " ").split() if u]
if ONLY:
    LINKS = [u for u in LINKS if u.rsplit("/", 1)[-1] == ONLY]

# ── logs: the fleet log standard — [YYYY-MM-DD HH:MM:SS] [LEVEL] msg,
# plain by default; colour opt-in (--colour / TOUR_LOG_COLOUR=1) wraps
# ONLY the [LEVEL] token, message text stays plain so grep keeps working.
_LVL_COLOUR = {"INFO": "\033[0;36m", "OK": "\033[0;32m",
               "SKIP": "\033[2m", "WARN": "\033[1;33m",
               "ERROR": "\033[1;31m"}
_LVL_RST = "\033[0m"


def log(msg, level="INFO"):
    ts = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())
    tok = f"[{level}]"
    if COLOUR:
        tok = f"{_LVL_COLOUR[level]}{tok}{_LVL_RST}"
    print(f"[{ts}] {tok} {msg}", flush=True)


# ── shared verdict rules (both engines) ────────────────────────────────
def shell_markers(name):
    return ["Files", "Invite", "Console", "Shell",
            "Personal workspace", name]


def is_wall(text):
    """Logged-out wall: BOTH needles present (a single common word
    inside a project's own code must not trip it alone)."""
    return "Log in" in text and "Sign up" in text


def marker_hit(markers, text):
    if len(text) <= 200:
        return None
    return next((m for m in markers if m in text), None)


# ── shared popup dismissal (both engines) ─────────────────────────────
# A rendered shell is NOT a booted workspace: Replit parks blocking
# dialogs on the project page (the "Keep using Replit?" session dialog,
# the Starter-limit / upgrade upsell), and the workspace does not start
# until they are closed (fleet finding, user-verified 2026-11-07: the
# tour logged SHELL while the node stayed offline in the netmap,
# because nothing ever closed the popup). Both engines therefore run a
# dismissal pass during a stop. The SELECTION is a whitelist — a
# control is clickable only when it is provably a dismiss control:
POPUP_SAFE_TEXTS = ["×", "✕", "x", "X", "Close", "Dismiss",
                    "No thanks", "Not now", "Maybe later"]
# ...and a control is vetoed outright when its visible text names an
# affirmative action (an aria-label veto applies too, unless the label
# itself says close/dismiss — "Close upgrade dialog" stays clickable).
POPUP_NEVER_RE = "keep using|upgrade|subscribe|buy|pay|run|delete|confirm"
# A visible dialog still matching this after every dismissal attempt
# is a wall the tour cannot clear — logged as `popup-wall:` (WARN),
# observability only; it does not change the verdict.
POPUP_WALL_RE = "limit|upgrade|subscription|starter"
# Dialog containers both engines look inside — nothing outside a
# dialog is ever clicked.
POPUP_BOXES = ('[role="dialog"], [aria-modal="true"], dialog, '
               '[class*="modal" i]')


# ══ Lightpanda engine ═════════════════════════════════════════════════
# Registered as _LightpandaEngine in ENGINES (engine registry, above
# the config block); dispatched only through the registry.
CURRENT_SRV = None  # live lightpanda Popen, for signal cleanup


def convert_jar():
    """Cookie jar (browser-export or Playwright format) -> CDP cookie
    array file for the native --cookie loader. Returns the cookie
    count. Re-run every round so a re-imported jar is picked up
    without a tour restart."""
    raw = json.load(open(JAR))
    items = raw.get("cookies", raw) if isinstance(raw, dict) else raw
    out = []
    for c in items:
        if "name" not in c or "value" not in c:
            continue
        nc = {"name": c["name"], "value": c["value"],
              "domain": c.get("domain", ".replit.com"),
              "path": c.get("path", "/")}
        if c.get("expires"):
            try:
                nc["expires"] = float(c["expires"])
            except Exception:
                pass
        if c.get("secure") is not None:
            nc["secure"] = bool(c["secure"])
        if c.get("httpOnly") is not None:
            nc["httpOnly"] = bool(c["httpOnly"])
        out.append(nc)
    fd = os.open(ARRAY, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(out, f)
    return len(out)


_WB_DISABLED = False  # set when the engine refuses cookie read-back


def writeback_jar(cookies, name):
    """Merge cookies read back from a live session into the on-disk jar:
    freshest per (name, domain, path) wins, nothing is ever deleted, the
    write is atomic (tmp + replace, mode 600), and any error leaves the
    jar untouched. Paired with convert_jar() re-running every round,
    this turns the static jar into an evolving one — the session keeps
    what it earns (notably a cf_clearance) across stops, rounds and
    restarts, like a living browser profile does."""
    if not cookies:
        return
    try:
        raw = json.load(open(JAR))
        container = raw.get("cookies", raw) if isinstance(raw, dict) \
            else raw
        by_key = {}
        for c in container:
            if "name" in c:
                by_key[(c["name"], c.get("domain", ""),
                        c.get("path", "/"))] = c
        changed = 0
        for c in cookies:
            if "name" not in c or "value" not in c:
                continue
            key = (c["name"], c.get("domain", ""), c.get("path", "/"))
            new = {"name": c["name"], "value": c["value"],
                   "domain": c.get("domain", ".replit.com"),
                   "path": c.get("path", "/")}
            if c.get("expires") and float(c["expires"]) > 0:
                new["expires"] = float(c["expires"])
            for f in ("secure", "httpOnly", "sameSite"):
                if c.get(f) is not None:
                    new[f] = c[f]
            if by_key.get(key, {}).get("value") != new["value"]:
                changed += 1
            by_key[key] = new
        merged = list(by_key.values())
        out = dict(raw, cookies=merged) if isinstance(raw, dict) \
            and "cookies" in raw else merged
        tmp = JAR + ".wb-tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(out, f)
        os.replace(tmp, JAR)
        log(f"stop {name}: jar write-back: {len(merged)} cookies "
            f"({changed} changed)", "SKIP")
    except Exception as e:
        log(f"stop {name}: jar write-back failed ({type(e).__name__}: "
            f"{str(e)[:100]}); jar untouched", "WARN")


async def writeback_ctx(ctx, name):
    """Read the live context's cookies and merge them into the jar.
    If the engine refuses the read (Lightpanda's CDP surface is
    partial — Storage.setCookies already fails), disable write-back
    for this process and carry on: it must never break a tour."""
    global _WB_DISABLED
    if _WB_DISABLED:
        return
    try:
        cookies = await asyncio.wait_for(ctx.cookies(), 15)
    except Exception as e:
        _WB_DISABLED = True
        log(f"stop {name}: cookie read-back unsupported "
            f"({type(e).__name__}: {str(e)[:100]}); write-back "
            "disabled for this process", "WARN")
        return
    writeback_jar(cookies, name)


def rss_mb(pid):
    try:
        for line in open(f"/proc/{pid}/smaps_rollup"):
            if line.startswith("Rss:"):
                return int(line.split()[1]) // 1024
    except Exception:
        pass
    return 0


def lightpanda_pids():
    r = subprocess.run(["pgrep", "-f", "lightpanda serve"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return []
    return [int(x) for x in r.stdout.split() if x.strip().isdigit()]


def kill_leftovers(context):
    for pid in lightpanda_pids():
        log(f"leftover lightpanda pid={pid} killed ({context})", "WARN")
        try:
            os.kill(pid, signal.SIGKILL)
        except Exception:
            pass


def port_free(port):
    s = socket.socket()
    try:
        return s.connect_ex(("127.0.0.1", port)) != 0
    finally:
        s.close()


async def body_text(page):
    """Bounded page read: inner_text has its own 3s timeout AND the
    wait_for cap — a stuck challenge page must never wedge the poll
    loop (the ~100s hang this guard exists for)."""
    try:
        return await asyncio.wait_for(
            page.inner_text("body", timeout=3000), 10)
    except Exception:
        return ""


# One click per evaluation: find the first visible dialog holding a
# SAFE dismiss control and click it. Priority: an aria-label/title
# matching close|dismiss, then a control whose exact trimmed text is
# in the safe list (× / No thanks / ...). The never-regex vetoes a
# candidate whose visible text names an affirmative action, so an
# upsell's "Upgrade"/"Keep using" button can never be the click —
# when a dialog offers ONLY affirmative actions, nothing is clicked.
_LP_DISMISS_JS = """(() => {
  const safe = %s;
  const never = new RegExp(%s, 'i');
  const visible = (el) => !!(el.offsetWidth || el.offsetHeight ||
                             el.getClientRects().length);
  const boxes = [...document.querySelectorAll(%s)];
  for (const box of boxes) {
    if (!visible(box)) continue;
    const btns = [...box.querySelectorAll('button, [role="button"]')];
    const label = (b) => (b.getAttribute('aria-label') ||
                          b.getAttribute('title') || '');
    const text = (b) => (b.textContent || '').trim();
    const ok = (b) => {
      if (b.disabled || !visible(b)) return false;
      if (never.test(text(b))) return false;
      const lab = label(b);
      if (never.test(lab) && !/close|dismiss/i.test(lab)) return false;
      return true;
    };
    let ctl = btns.find((b) => ok(b) && /close|dismiss/i.test(label(b)));
    if (!ctl) ctl = btns.find((b) => ok(b) && safe.includes(text(b)));
    if (ctl) {
      const dlg = (box.innerText || '').replace(/\\s+/g, ' ')
                    .trim().slice(0, 60);
      const via = label(ctl) || text(ctl);
      ctl.click();
      return {clicked: via, dialog: dlg};
    }
  }
  return {clicked: null};
})()""" % (json.dumps(POPUP_SAFE_TEXTS),
           json.dumps(POPUP_NEVER_RE),
           json.dumps(POPUP_BOXES))

# A wall the tour cannot clear: a still-visible dialog whose text
# names the limit/upsell family. Returns its first 60 chars or null.
_LP_WALL_JS = """(() => {
  const wall = new RegExp(%s, 'i');
  const visible = (el) => !!(el.offsetWidth || el.offsetHeight ||
                             el.getClientRects().length);
  const boxes = [...document.querySelectorAll(%s)];
  for (const box of boxes) {
    if (!visible(box)) continue;
    const t = (box.innerText || '').replace(/\\s+/g, ' ').trim();
    if (wall.test(t)) return t.slice(0, 60);
  }
  return null;
})()""" % (json.dumps(POPUP_WALL_RE), json.dumps(POPUP_BOXES))


async def lp_dismiss_popups(page, name):
    """Dismiss blocking popups on the stop's page (the shared
    whitelist above): up to 3 clicks per invocation — stacked dialogs
    are real — with a short settle after each. Logs every dismissal,
    and a `popup-wall:` WARN when a limit/upsell dialog is still
    standing afterwards. Never raises: a failed dismissal must not
    kill a tour. Returns the number of dialogs dismissed."""
    dismissed = 0
    for _ in range(3):
        try:
            r = await asyncio.wait_for(page.evaluate(_LP_DISMISS_JS), 10)
        except Exception:
            break
        if not isinstance(r, dict) or not r.get("clicked"):
            break
        dismissed += 1
        log(f"stop {name}: popup dismissed via {r['clicked']!r}: "
            f"{r.get('dialog', '')!r}", "SKIP")
        await asyncio.sleep(0.7)
    try:
        wall = await asyncio.wait_for(page.evaluate(_LP_WALL_JS), 10)
    except Exception:
        wall = None
    if wall:
        log(f"stop {name}: popup-wall: {wall}", "WARN")
    return dismissed


async def run_stop_lightpanda(idx, url):
    """One Lightpanda tour stop.
    Returns (verdict, time_to_shell_s, rss_peak_mb, popups_dismissed)."""
    global CURRENT_SRV
    name = url.rsplit("/", 1)[-1]
    port = BASE_PORT + idx
    t0 = time.time()
    rss_peak = 0
    popups = 0
    verdict, shell_at = "UNKNOWN", None

    kill_leftovers(f"pre-stop {name}")
    for _ in range(20):
        if port_free(port):
            break
        await asyncio.sleep(0.5)

    os.makedirs(LOG_DIR, exist_ok=True)
    srvlog = open(os.path.join(LOG_DIR, f"lp-server-{name}.log"), "ab")
    srv = subprocess.Popen(
        [BIN, "serve", "--host", "127.0.0.1", "--port", str(port),
         "--cookie", ARRAY],
        stdout=srvlog, stderr=srvlog)
    CURRENT_SRV = srv
    log(f"stop {name}: server pid={srv.pid} port={port} url={url}")
    try:
        up = False
        for _ in range(30):
            try:
                with urllib.request.urlopen(
                        f"http://127.0.0.1:{port}/json/version",
                        timeout=2) as r:
                    r.read()
                up = True
                break
            except Exception:
                await asyncio.sleep(0.5)
        if not up:
            log(f"stop {name}: server HTTP never came up", "ERROR")
            return "ERROR", None, rss_peak, popups

        from playwright.async_api import async_playwright
        async with async_playwright() as p:
            browser = await asyncio.wait_for(
                p.chromium.connect_over_cdp(f"http://127.0.0.1:{port}"), 30)
            ctx = browser.contexts[0] if browser.contexts \
                else await browser.new_context()
            page = await ctx.new_page()  # default CDP page is non-navigable
            try:
                await asyncio.wait_for(
                    page.goto(url, wait_until="domcontentloaded"), 60)
            except Exception as e:
                log(f"stop {name}: goto exc {type(e).__name__} "
                    f"{str(e)[:120]} (continuing to poll)", "WARN")

            markers = shell_markers(name)
            deadline = time.time() + POLL
            last_title = None
            while time.time() < deadline:
                try:
                    title = await asyncio.wait_for(page.title(), 10)
                except Exception:
                    title = "?"
                if title != last_title:
                    log(f"stop {name}: title -> {title!r}", "SKIP")
                    last_title = title
                rss_peak = max(rss_peak, rss_mb(srv.pid))
                text = await body_text(page)
                if is_wall(text):
                    # confirm once, 5s later (camofox --fail-text discipline)
                    await asyncio.sleep(5)
                    text2 = await body_text(page)
                    if is_wall(text2):
                        verdict = "LOGGED-OUT-WALL"
                        log(f"stop {name}: wall confirmed "
                            f"(text len={len(text2)})", "WARN")
                        break
                    continue
                hit = marker_hit(markers, text)
                if hit:
                    verdict, shell_at = "SHELL", time.time() - t0
                    log(f"stop {name}: SHELL marker={hit!r} "
                        f"textlen={len(text)} tts={shell_at:.1f}s", "OK")
                    break
                await asyncio.sleep(5)
            else:
                if last_title and "Just a moment" in last_title:
                    verdict = "CF-STALL"
                log(f"stop {name}: poll deadline, verdict={verdict} "
                    f"last_title={last_title!r}", "WARN")

            if verdict == "SHELL":
                # Clear blocking popups BEFORE the dwell: the
                # workspace boots only once they are gone, so the
                # dwell should be spent booted, not walled. A second
                # pass runs before the post-hold sample — a popup can
                # also appear late.
                popups += await lp_dismiss_popups(page, name)
                log(f"stop {name}: holding dwell={DWELL}s", "SKIP")
                held = 0
                while held < DWELL:
                    step = min(20, DWELL - held)
                    await asyncio.sleep(step)
                    held += step
                    rss_peak = max(rss_peak, rss_mb(srv.pid))
                popups += await lp_dismiss_popups(page, name)
                text = await body_text(page)
                still = any(m in text for m in markers) \
                    and not is_wall(text)
                log(f"stop {name}: post-hold still-shell={still} "
                    f"textlen={len(text)} rss_peak={rss_peak}MB",
                    "OK" if still else "WARN")
                if WRITEBACK:
                    await writeback_ctx(ctx, name)
            try:
                await asyncio.wait_for(browser.close(), 15)
            except Exception as e:
                log(f"stop {name}: browser.close exc "
                    f"{type(e).__name__} {str(e)[:120]}", "WARN")
    except Exception as e:
        verdict = "ERROR"
        log(f"stop {name}: ERROR {type(e).__name__} {str(e)[:200]}",
            "ERROR")
    finally:
        srv.terminate()
        try:
            srv.wait(timeout=5)
        except Exception:
            srv.kill()
        CURRENT_SRV = None
        srvlog.close()
        kill_leftovers(f"post-stop {name}")
    tts = round(shell_at, 1) if shell_at else None
    return verdict, tts, rss_peak, popups


# ══ local Playwright engines (patchright / cloakbrowser) ═══════════
# A real local Chromium driven through Playwright — ONE persistent
# browser + context per tour process, created lazily at the first
# stop and reused by every stop and round: the camofox lesson
# applied to a local browser (a cold session pays the full CF price
# at stop 1; a warm one reuses its clearance). Cross-restart
# continuity is the jar's job — TOUR_JAR_WRITEBACK merges the live
# context's cookies back after every SHELL stop, exactly as the
# Lightpanda engine does. The engines differ only in the launcher:
# patchright = Playwright's own Chromium with the driver's CDP
# leaks patched; cloakbrowser = a Chromium build with source-level
# fingerprint patches behind a Playwright-shaped async API. Both
# launch a persistent context on the engine's profile dir.


class _PwSession:
    def __init__(self, key, ctx, pw, fragment, killable=True):
        self.key, self.ctx, self.pw, self.fragment = \
            key, ctx, pw, fragment
        # killable=False when the browser process is NOT the tour's
        # to kill (a resident server the tour only connected to) —
        # pw_kill_session then leaves it alone.
        self.killable = killable


PW_SESSION = None  # the live _PwSession, for run_stop + signal cleanup


def pw_cookies():
    """Cookie jar (browser-export or Playwright format) -> a
    Playwright add_cookies list. Returns the normalized cookies."""
    raw = json.load(open(JAR))
    items = raw.get("cookies", raw) if isinstance(raw, dict) else raw
    out = []
    for c in items:
        if "name" not in c or "value" not in c:
            continue
        nc = {"name": c["name"], "value": c["value"],
              "domain": c.get("domain", ".replit.com"),
              "path": c.get("path", "/")}
        if c.get("expires"):
            try:
                nc["expires"] = float(c["expires"])
            except Exception:
                pass
        for f in ("secure", "httpOnly"):
            if c.get(f) is not None:
                nc[f] = bool(c[f])
        if c.get("sameSite") in ("Strict", "Lax", "None"):
            nc["sameSite"] = c["sameSite"]
        out.append(nc)
    return out


def _pw_browser_env(engine):
    """The engine's nix lib closure (<engine home>/closure.txt,
    colon-separated dirs, produced at engine setup) as a
    browser-process env — or None when no closure file exists.

    The closure includes the store's glibc dir and is ONLY safe in
    the browser process: the browser's interpreter is patched to
    the matching store ld.so, while everything else in this tree
    (above all the Playwright driver Node, a foreign-interp binary)
    dies on the nix glibc with GLIBC_PRIVATE lookup errors. Hence
    Playwright's per-launch env, never the tour's own environment."""
    try:
        dirs = open(os.path.join(engine.HOME, "closure.txt")) \
            .read().strip()
    except Exception:
        return None
    if not dirs:
        return None
    cur = os.environ.get("LD_LIBRARY_PATH", "")
    return {"LD_LIBRARY_PATH": dirs + (":" + cur if cur else "")}


async def _pw_launch_patchright(engine):
    from patchright.async_api import async_playwright
    pw = await async_playwright().start()
    kw = {"headless": PW_HEADLESS}
    env = _pw_browser_env(engine)
    if env is not None:
        kw["env"] = env
    ctx = await pw.chromium.launch_persistent_context(
        engine.profile_dir(), **kw)
    return pw, ctx


async def _pw_launch_cloak(engine):
    import cloakbrowser as cloak
    fn = getattr(cloak, "launch_persistent_context_async", None)
    if fn is None:
        raise RuntimeError(
            "cloakbrowser exposes no launch_persistent_context_async "
            "in this version — the adapter needs its async API")
    # Pass optional kwargs only when this build's signature
    # accepts them — the package's API surface moves between
    # versions.
    import inspect
    params = inspect.signature(fn).parameters
    kw = {"headless": PW_HEADLESS}
    if "humanize" in params:
        kw["humanize"] = CLOAK_HUMANIZE
    env = _pw_browser_env(engine)
    if env is not None and "env" in params:
        kw["env"] = env
    ctx = await fn(engine.profile_dir(), **kw)
    return None, ctx


MOLI_SERVER_PROC = None  # the `moli serve` process THIS tour spawned


def _moli_cdp_alive():
    try:
        with urllib.request.urlopen(MOLI_CDP_URL + "/json/version",
                                    timeout=3) as r:
            return r.status == 200
    except Exception:
        return False


async def _pw_launch_moli(engine):
    """Moli: connect Playwright to the engine's CDP server
    (`moli serve`). The server IS the browser — a from-scratch Rust
    engine whose cookies/storage persist in its own SQLite
    partitions across restarts. When the endpoint is down and
    autostart is on, the tour spawns the server itself (the
    patchright/cloak shape: the tour owns its browser process);
    with TOUR_MOLI_AUTOSTART=0 a resident launcher owns it and a
    down endpoint fails the session launch, camofox-style."""
    global MOLI_SERVER_PROC
    if not _moli_cdp_alive():
        if not MOLI_AUTOSTART:
            raise RuntimeError(
                f"moli CDP endpoint {MOLI_CDP_URL} is down and "
                "TOUR_MOLI_AUTOSTART=0 — start the server "
                "(launch-moli) or enable autostart")
        if not os.path.exists(MOLI_BIN):
            raise RuntimeError(
                f"moli binary missing at {MOLI_BIN} — run: "
                "bash setup.sh --moli")
        from urllib.parse import urlparse
        port = urlparse(MOLI_CDP_URL).port or 9222
        os.makedirs(engine.HOME, exist_ok=True)
        logf = open(os.path.join(engine.HOME, "serve.log"), "ab")
        MOLI_SERVER_PROC = subprocess.Popen(
            [MOLI_BIN, "serve", "--host", "127.0.0.1",
             "--port", str(port)],
            stdout=logf, stderr=logf, start_new_session=True)
        for _ in range(30):
            if _moli_cdp_alive():
                break
            await asyncio.sleep(1)
        else:
            raise RuntimeError(
                f"moli serve did not come up on {MOLI_CDP_URL} "
                f"(log: {os.path.join(engine.HOME, 'serve.log')})")
        log(f"moli: spawned serve pid={MOLI_SERVER_PROC.pid} "
            f"on {MOLI_CDP_URL}")
    from playwright.async_api import async_playwright
    pw = await async_playwright().start()
    browser = await pw.chromium.connect_over_cdp(MOLI_CDP_URL)
    ctx = (browser.contexts[0] if browser.contexts
           else await browser.new_context())
    return pw, ctx


async def pw_ensure_session(engine):
    global PW_SESSION
    if PW_SESSION is not None and PW_SESSION.key == engine.KEY:
        return PW_SESSION
    pw, ctx = await globals()[engine.LAUNCH](engine)
    cookies = pw_cookies()
    if cookies:
        await ctx.add_cookies(cookies)
    PW_SESSION = _PwSession(engine.KEY, ctx, pw, engine.fragment(),
                            engine.session_killable())
    closure = _pw_browser_env(engine)
    log(f"{engine.KEY}: session up, injected {len(cookies)} cookies "
        f"from {JAR}" + (f"; nix closure applied to the browser "
        f"process ({len(closure['LD_LIBRARY_PATH'].split(':'))} "
        "dirs)" if closure else ""))
    return PW_SESSION


def pw_rss(fragment):
    try:
        r = subprocess.run(["pgrep", "-f", fragment],
                           capture_output=True, text=True)
        peak = 0
        for x in r.stdout.split():
            if x.strip().isdigit():
                peak = max(peak, rss_mb(int(x)))
        return peak
    except Exception:
        return 0


def pw_kill_session():
    if PW_SESSION is None or not PW_SESSION.killable:
        return
    try:
        r = subprocess.run(["pgrep", "-f", PW_SESSION.fragment],
                           capture_output=True, text=True)
        for x in r.stdout.split():
            if x.strip().isdigit():
                try:
                    os.kill(int(x), signal.SIGKILL)
                except Exception:
                    pass
    except Exception:
        pass


async def run_stop_pw(idx, url, sess):
    """One local-Playwright tour stop (patchright / cloakbrowser) —
    the Lightpanda stop's poll/dismiss/dwell discipline, on a fresh
    page of the process-wide persistent context.
    Returns (verdict, time_to_shell_s, rss_peak_mb, popups_dismissed)."""
    name = url.rsplit("/", 1)[-1]
    t0 = time.time()
    rss_peak = 0
    popups = 0
    verdict, shell_at = "UNKNOWN", None
    page = None
    try:
        page = await sess.ctx.new_page()
        try:
            await asyncio.wait_for(
                page.goto(url, wait_until="domcontentloaded"), 60)
        except Exception as e:
            log(f"stop {name}: goto exc {type(e).__name__} "
                f"{str(e)[:120]} (continuing to poll)", "WARN")
        markers = shell_markers(name)
        deadline = time.time() + POLL
        last_title = None
        while time.time() < deadline:
            try:
                title = await asyncio.wait_for(page.title(), 10)
            except Exception:
                title = "?"
            if title != last_title:
                log(f"stop {name}: title -> {title!r}", "SKIP")
                last_title = title
            rss_peak = max(rss_peak, pw_rss(sess.fragment))
            text = await body_text(page)
            if is_wall(text):
                await asyncio.sleep(5)
                text2 = await body_text(page)
                if is_wall(text2):
                    verdict = "LOGGED-OUT-WALL"
                    log(f"stop {name}: wall confirmed "
                        f"(text len={len(text2)})", "WARN")
                    break
                continue
            hit = marker_hit(markers, text)
            if hit:
                verdict, shell_at = "SHELL", time.time() - t0
                log(f"stop {name}: SHELL marker={hit!r} "
                    f"textlen={len(text)} tts={shell_at:.1f}s", "OK")
                break
            await asyncio.sleep(5)
        else:
            if last_title and "Just a moment" in last_title:
                verdict = "CF-STALL"
            log(f"stop {name}: poll deadline, verdict={verdict} "
                f"last_title={last_title!r}", "WARN")
        if verdict == "SHELL":
            popups += await lp_dismiss_popups(page, name)
            log(f"stop {name}: holding dwell={DWELL}s", "SKIP")
            held = 0
            while held < DWELL:
                step = min(20, DWELL - held)
                await asyncio.sleep(step)
                held += step
                rss_peak = max(rss_peak, pw_rss(sess.fragment))
            popups += await lp_dismiss_popups(page, name)
            text = await body_text(page)
            still = any(m in text for m in markers) \
                and not is_wall(text)
            log(f"stop {name}: post-hold still-shell={still} "
                f"textlen={len(text)} rss_peak={rss_peak}MB",
                "OK" if still else "WARN")
            if WRITEBACK:
                await writeback_ctx(sess.ctx, name)
    except Exception as e:
        verdict = "ERROR"
        log(f"stop {name}: ERROR {type(e).__name__} {str(e)[:200]}",
            "ERROR")
    finally:
        if page is not None:
            try:
                await asyncio.wait_for(page.close(), 10)
            except Exception:
                pass
    tts = round(shell_at, 1) if shell_at else None
    return verdict, tts, rss_peak, popups


# ══ Camofox engine ════════════════════════════════════════════════════
# Drives the camofox server's HTTP API through the client BELOW —
# self-contained since S5d. The client is the one the deleted
# camofox.py CLI used (cf_req / cf_convert / cf_dismiss_dialogs /
# cf_diagnose_timeout are that code, carried into the tour when the
# refresh-page-era CLI was removed): same requests, same key
# selection, same timeout diagnosis — no cross-tree import, so this
# engine works in any tree that carries tour.py alone. It follows the
# shared adapter pattern: prepare (health probe) → plant cookies
# (import at tour start) → open one session per stop → poll/sample →
# close the session. The server is a resident service owned by the
# caller: the tour checks its health and reports ERROR, it NEVER
# spawns it. Every request carries an explicit timeout — the sync
# equivalent of the Lightpanda side's asyncio.wait_for discipline.
# Registered as _CamofoxEngine in ENGINES (engine registry, above the
# config block); dispatched only through the registry.
CURRENT_CF = None  # (key, session) of the live stop, for signal cleanup

# Python's default trust path (capath only on Replit) does not include
# the Replit proxy root that curl trusts via the system bundle. Use
# the system bundle when it exists; verification stays on either way.
_CF_SSL_CTX = None
if os.path.exists("/etc/ssl/certs/ca-certificates.crt"):
    import ssl
    _CF_SSL_CTX = ssl.create_default_context(
        cafile="/etc/ssl/certs/ca-certificates.crt")
_CF_SAMESITE = {"no_restriction": "None", "lax": "Lax",
                "strict": "Strict", "unspecified": "Lax",
                "none": "None"}


def cf_req(key, method, path, body=None, timeout=300):
    """One bounded request to the camofox server. Returns the parsed
    JSON body, or {"_http_error": code, "_body": ...} /
    {"_error": str} — errors are VALUES, so callers decide what is
    fatal (the tour's call, never the client's)."""
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(
        CF_URL + path, data=data,
        headers={"Content-Type": "application/json",
                 "Authorization": f"Bearer {key or ''}"}, method=method)
    try:
        with urllib.request.urlopen(r, timeout=timeout,
                                    context=_CF_SSL_CTX) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return {"_http_error": e.code, "_body": e.read().decode()[:400]}
    except Exception as e:
        return {"_error": str(e)}


def cf_key():
    return CF_KEY


def cf_convert(c):
    """Browser-export cookie -> the server's import shape."""
    out = {"name": c["name"], "value": c["value"],
           "domain": c.get("domain", "").lstrip(".")}
    if c.get("path"):
        out["path"] = c["path"]
    if c.get("expirationDate"):
        out["expires"] = int(float(c["expirationDate"]))
    if c.get("httpOnly"):
        out["httpOnly"] = True
    if c.get("secure"):
        out["secure"] = True
    ss = c.get("sameSite")
    if ss:
        out["sameSite"] = _CF_SAMESITE.get(str(ss), "Lax")
    return out


def cf_diagnose_timeout():
    """Probe /health and report what a hung request actually means, so
    the operator reads a conclusion instead of running curl themselves.
    Three states:
      refused  -> server not running at all
      /health also hangs -> whole server stuck (event loop blocked)
      /health answers fast -> server alive but browser ops wedge (dead
                              juggler; /health lies: browserConnected
                              is a cached playwright flag, verified live)"""
    try:
        t0 = time.time()
        with urllib.request.urlopen(CF_URL + "/health", timeout=5,
                                    context=_CF_SSL_CTX) as resp:
            h = json.loads(resp.read())
        ms = int((time.time() - t0) * 1000)
        return (f"[camofox] diagnosis: server {CF_URL} answers /health "
                f"in {ms}ms (browserRunning={h.get('browserRunning')}, "
                f"activeSessions={h.get('activeSessions')}) but this "
                f"request hung -> the browser's page channel is wedged "
                f"(/health's flags are cached, not a real probe). Fix: "
                f"restart the server — kill the 'node server.js' "
                f"process and re-run the camofox launcher (or Stop/"
                f"re-run its workflow).")
    except urllib.error.HTTPError:
        return (f"[camofox] diagnosis: server {CF_URL} is up but "
                f"/health returned an HTTP error.")
    except (ConnectionRefusedError, OSError) as e:
        if isinstance(e, ConnectionRefusedError) \
                or "refused" in str(e).lower():
            return (f"[camofox] diagnosis: connection refused on "
                    f"{CF_URL} -> the server is NOT running. Start it: "
                    f"camofox  (or: bash setup.sh --camofox)")
        return (f"[camofox] diagnosis: {CF_URL} did not answer /health "
                f"({e}) -> the server process is alive but its event "
                f"loop is blocked; restart it (kill the node server, "
                f"re-run: camofox).")


# Generic modal dismissal. The MECHANISM is site-agnostic — find a
# visible dialog whose text mentions a caller-given needle, click ITS
# dismiss control — while the needle itself is caller data, so no
# site-specific strings live in this client. The dismiss control is
# the shared whitelist (see the popup-dismissal block above the
# Lightpanda engine): an aria-label/title matching close|dismiss, or
# an exact safe text (× / ✕ / "No thanks" / ...) — never a CTA like
# "Upgrade" or "Keep using", which the never-regex vetoes outright.
_CF_DISMISS_JS = """(() => {
  const needle = %s;
  const safe = %s;
  const never = new RegExp(%s, 'i');
  const visible = (el) => !!(el.offsetWidth || el.offsetHeight ||
                             el.getClientRects().length);
  const boxes = [...document.querySelectorAll(%s)];
  for (const box of boxes) {
    if (!visible(box)) continue;
    if (!(box.innerText || '').toLowerCase().includes(needle)) continue;
    const btns = [...box.querySelectorAll('button, [role="button"]')];
    const label = (b) => (b.getAttribute('aria-label') ||
                          b.getAttribute('title') || '');
    const text = (b) => (b.textContent || '').trim();
    const ok = (b) => {
      if (b.disabled || !visible(b)) return false;
      if (never.test(text(b))) return false;
      const lab = label(b);
      if (never.test(lab) && !/close|dismiss/i.test(lab)) return false;
      return true;
    };
    let close = btns.find((b) => ok(b) && /close|dismiss/i.test(label(b)));
    if (!close) close = btns.find((b) => ok(b) && safe.includes(text(b)));
    if (close) { close.click(); return 'dismissed'; }
    return 'found-no-close';
  }
  return 'not-found';
})()"""


def cf_dismiss_dialogs(key, user, tab, needles):
    """Best-effort: close dialogs matching each needle text. Never
    raises — a failed dismissal must not kill a tour; outcomes are
    logged so the log shows whether the box was actually closed.
    Returns the number of dialogs dismissed."""
    dismissed = 0
    for needle in needles:
        try:
            r = cf_req(key, "POST", f"/tabs/{tab}/evaluate",
                       {"userId": user,
                        "expression": _CF_DISMISS_JS % (
                            json.dumps(needle.lower()),
                            json.dumps(POPUP_SAFE_TEXTS),
                            json.dumps(POPUP_NEVER_RE),
                            json.dumps(POPUP_BOXES))},
                       timeout=30)
            outcome = r.get("result") if isinstance(r, dict) else None
            if outcome:
                if outcome == "dismissed":
                    dismissed += 1
                log(f"dismiss '{needle}': {outcome}", "SKIP")
            elif isinstance(r, dict) \
                    and ("_http_error" in r or "_error" in r):
                log(f"dismiss '{needle}': request failed {r}", "SKIP")
        except Exception as e:
            log(f"dismiss '{needle}': error {e}", "SKIP")
    return dismissed


def cf_health(key, timeout=5):
    """The /health dict when the server answers cleanly, else None."""
    h = cf_req(key, "GET", "/health", timeout=timeout)
    if isinstance(h, dict) and "_error" not in h and "_http_error" not in h:
        return h
    return None


def cf_import_cookies(key):
    """Import the jar into the tour's camofox user via the server's
    import path (POST /sessions/<user>/cookies, API key — that route
    checks CAMOFOX_API_KEY only). Returns (ok, detail) instead of
    exiting: whether a failed import is fatal is the tour's call, not
    the client's. Returns (True, count) or (False, reason)."""
    try:
        raw = json.load(open(JAR))
    except Exception as e:
        return False, f"jar unreadable: {e}"
    items = raw.get("cookies", raw) if isinstance(raw, dict) else raw
    norm = []
    for c in items:
        if "name" not in c or "value" not in c:
            continue
        c = dict(c)
        # cf_convert reads the browser-export `expirationDate`;
        # a Playwright-format jar carries the same instant as `expires`.
        if not c.get("expirationDate") and c.get("expires"):
            c["expirationDate"] = c["expires"]
        norm.append(c)
    api_key = CF_API_KEY or key
    r = cf_req(api_key, "POST", f"/sessions/{CF_USER}/cookies",
               {"cookies": [cf_convert(c) for c in norm]}, timeout=60)
    if isinstance(r, dict) and "_http_error" not in r and "_error" not in r:
        return True, r.get("count", len(norm))
    if isinstance(r, dict) and r.get("_error") == "timed out":
        return False, ("import timed out — "
                       + cf_diagnose_timeout())
    return False, f"import failed: {r}"


_TEXT_JS = "(() => (document.body && document.body.innerText || ''))()"
_TITLE_JS = "(() => document.title)()"


def cf_eval(key, tab, expr, timeout=30):
    """One bounded page read via the server's evaluate route; the
    result value, or None when the request itself failed."""
    r = cf_req(key, "POST", f"/tabs/{tab}/evaluate",
               {"userId": CF_USER, "expression": expr},
               timeout=timeout)
    if isinstance(r, dict) and "_error" not in r and "_http_error" not in r:
        return r.get("result")
    return None


def cf_page_text(key, tab):
    t = cf_eval(key, tab, _TEXT_JS)
    return t if isinstance(t, str) else ""


# Dialog-text needles for the camofox dismissal: the session dialog,
# plus the Starter-limit upsell (its text, seen live on fleet
# workspaces 2026-11-07 — an earlier list holding only the session
# needle never even searched for the upsell, and its x-only click set
# could not take the upsell's "No thanks" control).
CF_POPUP_NEEDLES = ["Keep using Replit?", "Starter limit"]


def run_stop_camofox(idx, url):
    """One camofox tour stop (sync; run in a thread by run_stop).
    Returns (verdict, time_to_shell_s, None, popups_dismissed) — no
    per-stop RSS on this engine: the server is a resident service,
    not a per-stop process."""
    global CURRENT_CF
    name = url.rsplit("/", 1)[-1]
    key = cf_key()
    session = f"{CF_SESSION}-{idx}"
    t0 = time.time()
    popups = 0
    verdict, shell_at = "UNKNOWN", None

    if cf_health(key) is None:
        log(f"stop {name}: camofox server unreachable at {CF_URL} "
            "— the tour never spawns it; start the camofox service",
            "ERROR")
        return "ERROR", None, None, popups
    r = cf_req(key, "POST", "/tabs",
               {"userId": CF_USER, "sessionKey": session, "url": url},
               timeout=60)
    if not isinstance(r, dict) or "_error" in r or "_http_error" in r \
            or not r.get("tabId"):
        log(f"stop {name}: open failed: {r}", "ERROR")
        return "ERROR", None, None, popups
    tab = r["tabId"]
    CURRENT_CF = (key, session)
    log(f"stop {name}: tab={tab[:8]} session={session} url={url}")
    try:
        markers = shell_markers(name)
        deadline = time.time() + POLL
        last_title = None
        while time.time() < deadline:
            title = cf_eval(key, tab, _TITLE_JS)
            if isinstance(title, str) and title != last_title:
                log(f"stop {name}: title -> {title!r}", "SKIP")
                last_title = title
            text = cf_page_text(key, tab)
            if is_wall(text):
                # confirm once, 5s later (the --fail-text discipline)
                time.sleep(5)
                text2 = cf_page_text(key, tab)
                if is_wall(text2):
                    verdict = "LOGGED-OUT-WALL"
                    log(f"stop {name}: wall confirmed "
                        f"(text len={len(text2)})", "WARN")
                    break
                continue
            hit = marker_hit(markers, text)
            if hit:
                verdict, shell_at = "SHELL", time.time() - t0
                log(f"stop {name}: SHELL marker={hit!r} "
                    f"textlen={len(text)} tts={shell_at:.1f}s", "OK")
                break
            time.sleep(5)
        else:
            if last_title and "Just a moment" in last_title:
                verdict = "CF-STALL"
            log(f"stop {name}: poll deadline, verdict={verdict} "
                f"last_title={last_title!r}", "WARN")

        if verdict == "SHELL":
            # Dismissal runs only after the page settles
            # (post-challenge), never at tab open — during the CF
            # challenge the page's dialogs do not exist yet. Same
            # timing as the lightpanda engine: dismiss now that the
            # shell is in (the workspace boots during the dwell
            # only if the way is clear), and once more before the
            # post-hold sample for late popups.
            popups += cf_dismiss_dialogs(key, CF_USER, tab,
                                         CF_POPUP_NEEDLES)
            log(f"stop {name}: holding dwell={DWELL}s", "SKIP")
            time.sleep(DWELL)
            popups += cf_dismiss_dialogs(key, CF_USER, tab,
                                         CF_POPUP_NEEDLES)
            text = cf_page_text(key, tab)
            still = any(m in text for m in markers) and not is_wall(text)
            log(f"stop {name}: post-hold still-shell={still} "
                f"textlen={len(text)}", "OK" if still else "WARN")
    except Exception as e:
        verdict = "ERROR"
        log(f"stop {name}: ERROR {type(e).__name__} {str(e)[:200]}",
            "ERROR")
    finally:
        # Session per stop, closed at teardown — tabs outlive their
        # client process on this server, so NOT closing leaks RAM.
        r = cf_req(key, "DELETE",
                   f"/tabs/group/{session}?userId={CF_USER}", timeout=30)
        if isinstance(r, dict) and ("_error" in r or "_http_error" in r):
            log(f"stop {name}: session close failed: {r}", "WARN")
        CURRENT_CF = None
    tts = round(shell_at, 1) if shell_at else None
    return verdict, tts, None, popups


async def run_stop(idx, url):
    # Registry dispatch — main() has already rejected an unknown
    # --browser, so ENGINE is the resolved adapter here.
    return await ENGINE.run_stop(idx, url)


# ── preflight + main loop (shared) ─────────────────────────────────────
def print_config():
    print(f"config: machine={MACHINE} (source: {MACHINE_SOURCE})",
          flush=True)
    for line in CONFIG_SOURCES:
        print(f"config: {line}", flush=True)
    print(f"config: resolved: browser={BROWSER} links={len(LINKS)} "
          f"dwell={DWELL}s gap={GAP}s breaker={BREAKER} poll={POLL}s "
          f"colour={COLOUR}", flush=True)
    if ENGINE is not None:
        print(ENGINE.config_line(), flush=True)


def check():
    """--check: config parse + engine preflight, no server spawn (the
    camofox server is only PROBED — it is never started from here),
    no tour. Exit code says whether a tour could run."""
    print_config()
    rc = 0
    if ENGINE is None:
        print(f"check: unknown browser {BROWSER!r} — "
              f"use --browser {'|'.join(ENGINES)}", flush=True)
        return 2
    if MACHINE not in ("muse", "repl"):
        print(f"check: unknown machine {MACHINE!r} — "
              "use --machine muse|repl", flush=True)
        return 2
    if not LINKS:
        print("check: TOUR_LINKS (fallback LP_LINKS) is empty — set it "
              f"in the system env or in {ENV_FILE} (see .env.example "
              "next to it)", flush=True)
        rc = 1
    if ENGINE.check():
        rc = 1
    print(f"check: {'OK' if rc == 0 else 'FAILED'}", flush=True)
    return rc


async def main():
    print_config()
    if ENGINE is None:
        log(f"FATAL: unknown browser {BROWSER!r} — "
            f"use --browser {'|'.join(ENGINES)}", "ERROR")
        sys.exit(2)
    if MACHINE not in ("muse", "repl"):
        log(f"FATAL: unknown machine {MACHINE!r} — "
            "use --machine muse|repl", "ERROR")
        sys.exit(2)
    if not LINKS:
        log("FATAL: TOUR_LINKS (fallback LP_LINKS) is empty — "
            "nothing to tour", "ERROR")
        sys.exit(2)
    cookies_note = ENGINE.prepare()
    log(f"tour start: browser={BROWSER} {len(LINKS)} stops "
        f"dwell={DWELL}s gap={GAP}s poll={POLL}s breaker={BREAKER}"
        f"{cookies_note}")
    fail_streak = 0
    rnd = 0
    while True:
        rnd += 1
        r0 = time.time()
        log(f"=== round {rnd} start ===")
        ENGINE.prepare_round(rnd)
        for idx, url in enumerate(LINKS):
            name = url.rsplit("/", 1)[-1]
            verdict, tts, rss_peak, popups = await run_stop(idx, url)
            ok = verdict == "SHELL"
            fail_streak = 0 if ok else fail_streak + 1
            rss = f"{rss_peak}MB" if rss_peak is not None else "n/a"
            log(f"stop={name} verdict={verdict} "
                f"time_to_shell={tts} dwell={DWELL}s rss_peak={rss} "
                f"popups_dismissed={popups} "
                f"fail_streak={fail_streak}",
                "OK" if ok else "WARN")
            if BREAKER and fail_streak >= BREAKER:
                log(f"*** tour ABORTED after {BREAKER} consecutive "
                    f"failed stops (last: {name} {verdict})", "ERROR")
                sys.exit(1)
            if GAP:
                await asyncio.sleep(GAP)
        log(f"=== round {rnd} complete in {time.time()-r0:.0f}s ===",
            "OK")
        if MAX_ROUNDS and rnd >= MAX_ROUNDS:
            log(f"MAX_ROUNDS={MAX_ROUNDS} reached, exiting")
            return


def _cleanup(signum, frame):
    # Every registered engine tears down its live stop (the inactive
    # engines' state is empty, so this is the old both-globals check,
    # generalised: a future engine gets signal cleanup for free).
    for eng in ENGINES.values():
        try:
            eng.teardown()
        except Exception:
            pass
    sys.exit(128 + signum)


if __name__ == "__main__":
    if "--check" in sys.argv:
        sys.exit(check())
    signal.signal(signal.SIGTERM, _cleanup)
    signal.signal(signal.SIGINT, _cleanup)
    asyncio.run(main())
