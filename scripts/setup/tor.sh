# shellcheck shell=bash
# Tor browser — the Tor daemon (expert bundle) + a headless-Chromium-over-CDP
# driving path, so a box can browse via Tor. Sourced by setup.sh.
#
# WHY: no VPN client can bring up a tunnel on a Muse VM (/dev/net/tun opens
# but TUNSETIFF is not permitted — ExpressVPN is blocked there), and the
# device-browser VPN route is rejected by the operator. Tor is the TUN-free
# alternative: the daemon is a userspace SOCKS5 proxy (127.0.0.1:9050) and a
# headless Chromium driven over CDP through it proves Tor egress
# (check.torproject.org). Verified on muse-hop 2026-11-13 (bootstrap 100%,
# Chromium via CDP through the proxy).
#
# DUAL-PROFILE lane: this module is sourced by BOTH profiles (repl and muse),
# so it uses ONLY core.sh helpers (step/ok/skip/warn/die/need_cmd/
# verify_sha256) plus plain shell. The common.sh wiring helpers
# (record_tool_env_vars / record_tool_path_dirs / wire_tool) exist only under
# the repl profile, so they are called guarded by `declare -F` — present
# under repl, a silent no-op under muse (whose env.sh already puts
# TOR_BIN_DIR on PATH; there is no managed block there to wire into).
#
# Layout (mirrors the camofox/lightpanda state root): everything lives under
# $TOR_HOME (persistent) —
#   bundle/           the extracted expert bundle, pristine (tor/, data/geoip,
#                     debug/, docs/) — never edited, re-extracted on upgrade
#   data/             tor's DataDirectory (keys, cached consensus) — 700
#   torrc             generated config (SocksPort, GeoIP, log file)
#   tor-browser-test.mjs  the CDP driver (Node 22+, built-in WebSocket)
#   .env.example      config template (TOR_SOCKS_PORT, TOR_CDP_PORT, TOR_CHROME)
#   logs/tor.log      the daemon log (bootstrap progress lives here)
#   chromium-profile/ the tor-browser Chromium profile dir
# The launcher shims live in $TOR_BIN_DIR (on PATH under both profiles):
#   tor               sets the bundled lib path, execs bundle/tor/tor
#   tor-browser       ensures tor is up + bootstrapped, launches headless
#                     Chromium via CDP through the SOCKS proxy, drives it
#                     to a URL and reports what the browser sees
#
# No keeper: the daemon is NOT started by install (there is no auto-start
# supervisor — it died on every redeploy and auto-start is not assumed).
# tor-browser starts it on demand and waits for bootstrap; `tor` alone just
# runs the daemon in the foreground. Re-running the installer is the repair
# path (re-extracts the bundle, regenerates torrc + shims, keeps data/).
#
# The release is the Tor Project's expert bundle, versioned by the Tor
# Browser release it ships in (16.0.1 ships tor 0.4.9.16 — the version
# proven on muse-hop). The archive publishes no .sha256 sidecar (only .asc
# signatures), so the size + SHA256 pins below were computed from the
# official downloads when the pin was made. They move WITH
# TOR_BROWSER_VERSION: bump the version without refreshing them and the
# install dies on the size check, loudly, by design.

# Version pin (Tor Browser release; the expert bundle is versioned by it).
TOR_BROWSER_VERSION="16.0.1"
TOR_RELEASE_BASE="https://archive.torproject.org/tor-package-archive/torbrowser"
TOR_VERSION="0.4.9.16"

# Tool home (persistent) + bin dir (on PATH under both profiles).
# TOR_BIN_DIR defaults to XDG_BIN_HOME when set (repl) and to ~/.local/bin
# otherwise (muse — the agent-installed binary location, on PATH via the
# muse profile's env.sh). TOR_HOME/TOR_BIN_DIR env vars override both
# (big-env precedence); the launcher shims bake the resolved values in.
TOR_HOME="${TOR_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/tor}"
TOR_BIN_DIR="${TOR_BIN_DIR:-${XDG_BIN_HOME:-$HOME/.local/bin}}"
TOR_SOCKS_PORT="${TOR_SOCKS_PORT:-9050}"
TOR_CDP_PORT="${TOR_CDP_PORT:-9222}"

tor_asset_name() {
  case "$(uname -m)" in
    x86_64|amd64)   echo "tor-expert-bundle-linux-x86_64-$TOR_BROWSER_VERSION.tar.gz" ;;
    aarch64|arm64)  echo "tor-expert-bundle-linux-aarch64-$TOR_BROWSER_VERSION.tar.gz" ;;
    *)              die "tor: unsupported arch $(uname -m) (expert bundle ships linux x86_64 + aarch64 only)" ;;
  esac
}

# Pinned size (bytes) + SHA256 of the official $TOR_BROWSER_VERSION asset.
tor_asset_size() {
  case "$(uname -m)" in
    x86_64|amd64)   echo "33731966" ;;
    aarch64|arm64)  echo "33412005" ;;
    *)              die "tor: unsupported arch $(uname -m)" ;;
  esac
}
tor_asset_sha256() {
  case "$(uname -m)" in
    x86_64|amd64)   echo "7039cb16060ab22e669852e55774d894b55f25ea8bd0ab7194d3478429a58725" ;;
    aarch64|arm64)  echo "67040520d44c87ccaaf5aa7df0dc1ff122eb938dbb600ae7722e8b6b75282a4b" ;;
    *)              die "tor: unsupported arch $(uname -m)" ;;
  esac
}

tor_write_env_example() {
  # A fill-in TEMPLATE for the tor config, dropped by setup next to the
  # real torrc in $TOR_HOME — refreshed on every --tor run (it is a
  # template, not user config; the torrc itself is generated, never
  # hand-edited).
  local f="$TOR_HOME/.env.example"
  mkdir -p "$(dirname "$f")" || return 0
  rm -f "$f"  # remove, then write (never follow a pre-existing symlink)
  cat > "$f" <<'EOF'
# tor config — environment overrides for the tor lane. Only the vars you
# set are used.
#
# Precedence ("big env" rule): a var already set in the system
# environment WINS; the torrc is generated at install time from these
# values, and tor-browser reads them at run time. Re-run `setup.sh --tor`
# after changing a value so the torrc is regenerated.
#
# Template written by setup.sh --tor; safe to regenerate, never read by
# tor itself (tor reads $TOR_HOME/torrc).

# SOCKS5 proxy port the daemon listens on (default 9050). tor-browser
# and the doctor's egress check use this same port.
# TOR_SOCKS_PORT=9050

# CDP port tor-browser's Chromium listens on (default 9222).
# TOR_CDP_PORT=9222

# Chromium binary tor-browser drives (default: auto-detect — the Replit
# store browser, then /opt/meta-chromium/chrome, then launch-hermes-chrome,
# then chromium/chromium-browser/google-chrome-stable on PATH).
# TOR_CHROME=/path/to/chrome
EOF
  ok "tor config template: $f (env overrides; re-run setup.sh --tor after changing a value)"
}

tor_write_torrc() {
  # The daemon config. Generated (never hand-edited) so the resolved
  # paths stay in sync with TOR_HOME; re-run --tor regenerates it.
  mkdir -p "$TOR_HOME/data" "$TOR_HOME/logs"
  chmod 700 "$TOR_HOME/data"
  # Write IN PLACE (no `rm -f` first): tor watches its torrc inode, and
  # unlinking it (rm + recreate) makes a running daemon exit with
  # "Catching signal TERM" — a re-run of setup.sh --tor killed the live
  # daemon that way. `cat >` truncates the same inode, which tor
  # tolerates (it only re-reads torrc on SIGHUP). The symlink risk here
  # is nil (TOR_HOME is installer-owned); the daemon-kill is real.
  cat > "$TOR_HOME/torrc" <<EOF
# Generated by setup.sh --tor (Tor Browser $TOR_BROWSER_VERSION, tor $TOR_VERSION).
# Re-run setup.sh --tor to regenerate; do not hand-edit.
DataDirectory $TOR_HOME/data
SocksPort 127.0.0.1:$TOR_SOCKS_PORT
GeoIPFile $TOR_HOME/bundle/data/geoip
GeoIPv6File $TOR_HOME/bundle/data/geoip6
Log notice file $TOR_HOME/logs/tor.log
# PID file: clean_tor kills ONLY this daemon (a blanket pkill -x tor
# would also kill a user's own tor on the same box — a test-root clean
# killed the muse-hop daemon that way).
PidFile $TOR_HOME/data/tor.pid
EOF
  ok "torrc: $TOR_HOME/torrc (SocksPort 127.0.0.1:$TOR_SOCKS_PORT)"
}

tor_write_webgl_policy() {
  # The Hatch build of Chromium (/opt/meta-chromium/chrome, the Muse VM
  # platform browser) REFUSES TO START without a WebGL allowed-domains
  # policy file + its SHA256 passed on the command line ("Hatch WebGL
  # domain policy is required for browser startup"). The file is a
  # version header + one domain per line; the SHA is computed at run
  # time by tor-browser and passed as --hatch-webgl-allowed-domains-sha256.
  # A stock Chromium (Replit store browser, hermes-chromium) ignores the
  # unknown --hatch-* switches, so the flags are passed unconditionally
  # when the file exists. Regenerated on every --tor run; extend the list
  # and re-run --tor to allow WebGL on more domains.
  local f="$TOR_HOME/hatch-webgl-domains.txt"
  rm -f "$f"  # remove, then write (never follow a pre-existing symlink)
  # Domains MUST be strictly sorted (the Hatch policy parser rejects
  # an unsorted list: "WebGL domain policy domains are not strictly
  # sorted"). Keep this list sorted when extending it.
  cat > "$f" <<EOF
hatch-webgl-allowed-domains-v1
example.com
torproject.org
EOF
  ok "tor WebGL policy: $f (Hatch Chromium requires it to start)"
}

tor_write_launcher() {
  # The `tor` command: a launcher shim in $TOR_BIN_DIR. The bundle binary
  # links libevent/libssl/libcrypto from its own tor/ dir, so the shim
  # sets LD_LIBRARY_PATH before execing it — a bare symlink would die
  # "libevent-2.1.so.7: cannot open shared object file". TOR_HOME is
  # baked in at install time (regenerated on re-run) but the env var
  # still wins at run time (big-env precedence).
  local f="$TOR_BIN_DIR/tor"
  mkdir -p "$TOR_BIN_DIR" || return 0
  # rm -f FIRST: a pre-existing symlink here (e.g. a manual install's
  # ~/.local/bin/tor -> bundle/tor/tor) must be REMOVED, not followed —
  # `cat >` through a symlink clobbers the target (the old bundle's tor
  # binary became this launcher script on muse-hop). Remove, then write.
  rm -f "$f"
  cat > "$f" <<EOF
#!/usr/bin/env bash
# Generated by setup.sh --tor (Tor Browser $TOR_BROWSER_VERSION, tor $TOR_VERSION).
# Re-run setup.sh --tor to refresh. Do not hand-edit.
set -uo pipefail
TOR_HOME="\${TOR_HOME:-$TOR_HOME}"
export LD_LIBRARY_PATH="\$TOR_HOME/bundle/tor\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "\$TOR_HOME/bundle/tor/tor" "\$@"
EOF
  chmod +x "$f"
  ok "tor launcher: $f"
}

tor_write_cdp_driver() {
  # The CDP driver (Node 22+, built-in fetch + WebSocket — no deps):
  # connects to a headless Chromium's CDP port, navigates to a URL,
  # reports what the browser sees (URL, title, first 500 chars of text).
  # Ported from the muse-hop proof (~/workspace/scripts/tor-browser-test.mjs).
  local f="$TOR_HOME/tor-browser-test.mjs"
  rm -f "$f"  # remove, then write (never follow a pre-existing symlink)
  cat > "$f" <<'EOF'
// tor-browser-test.mjs — drive a headless Chromium (CDP) and report what
// the browser sees. Written by setup.sh --tor into $TOR_HOME.
// Usage: node tor-browser-test.mjs <url> [timeoutMs]
const CDP = `http://127.0.0.1:${process.env.TOR_CDP_PORT || 9222}`;
const url = process.argv[2] || 'https://check.torproject.org/api/ip';
const timeoutMs = Number(process.argv[3] || 75000);

const list = await (await fetch(CDP + '/json/list')).json();
const page = list.find(t => t.type === 'page');
if (!page) { console.error('no page target'); process.exit(1); }
const ws = new WebSocket(page.webSocketDebuggerUrl);
let id = 0;
const pending = new Map();
const send = (method, params = {}) => new Promise((res, rej) => {
  const mid = ++id;
  pending.set(mid, { res, rej });
  ws.send(JSON.stringify({ id: mid, method, params }));
});
let loadResolve;
const loadPromise = new Promise(r => { loadResolve = r; });
ws.onmessage = ev => {
  const m = JSON.parse(ev.data);
  if (m.id && pending.has(m.id)) { pending.get(m.id).res(m.result); pending.delete(m.id); }
  if (m.method === 'Page.loadEventFired') loadResolve();
};
await new Promise(r => { ws.onopen = r; });
await send('Page.enable');
await send('Runtime.enable');
await send('Page.navigate', { url });
const loaded = await Promise.race([
  loadPromise.then(() => 'loaded'),
  new Promise(r => setTimeout(() => r('timeout'), timeoutMs)),
]);
const evalRes = await send('Runtime.evaluate', {
  expression: 'JSON.stringify({url: location.href, title: document.title, text: document.body ? document.body.innerText.slice(0, 500) : ""})',
  returnByValue: true,
});
console.log('load:', loaded);
console.log(evalRes?.result?.value ?? JSON.stringify(evalRes));
ws.close();
process.exit(0);
EOF
  ok "tor CDP driver: $f"
}

tor_write_browser_driver() {
  # `tor-browser` — the user-facing command: ensure the daemon is up +
  # bootstrapped, launch headless Chromium via CDP through the SOCKS
  # proxy, drive it to a URL and report. No keeper: the daemon is
  # started on demand here (and only here), never by the installer.
  local f="$TOR_BIN_DIR/tor-browser"
  mkdir -p "$TOR_BIN_DIR" || return 0
  # rm -f first (same reason as tor_write_launcher): a pre-existing
  # symlink must be removed, not followed.
  rm -f "$f"
  cat > "$f" <<EOF
#!/usr/bin/env bash
# Generated by setup.sh --tor (Tor Browser $TOR_BROWSER_VERSION, tor $TOR_VERSION).
# Re-run setup.sh --tor to refresh. Do not hand-edit.
# Usage: tor-browser [url] — default https://check.torproject.org/api/ip
#   tor-browser --check   — SOCKS-only egress check (no browser): curl the
#                           Tor IP API through the proxy and report IsTor.
#   TOR_CHROME=/path/to/chrome tor-browser <url> — override the Chromium.
set -uo pipefail
TOR_HOME="\${TOR_HOME:-$TOR_HOME}"
TOR_BIN_DIR="\${TOR_BIN_DIR:-$TOR_BIN_DIR}"
TOR_SOCKS_PORT="\${TOR_SOCKS_PORT:-$TOR_SOCKS_PORT}"
TOR_CDP_PORT="\${TOR_CDP_PORT:-$TOR_CDP_PORT}"
TORRC="\$TOR_HOME/torrc"
TORLOG="\$TOR_HOME/logs/tor.log"
DRIVER="\$TOR_HOME/tor-browser-test.mjs"
PROFILE="\$TOR_HOME/chromium-profile"
URL="\${1:-https://check.torproject.org/api/ip}"

# Chromium resolution (first hit wins): explicit override, the Replit
# store browser, the Muse VM platform browser, the Hermes Chrome lane,
# then a system chromium. A miss dies naming the remedy — a different
# chromium is a different environment, so there is no silent fallback.
tor_chrome_bin() {
  local c
  if [[ -n "\${TOR_CHROME:-}" && -x "\$TOR_CHROME" ]]; then printf '%s' "\$TOR_CHROME"; return 0; fi
  if [[ -n "\${REPLIT_PLAYWRIGHT_CHROMIUM_EXECUTABLE:-}" && -x "\$REPLIT_PLAYWRIGHT_CHROMIUM_EXECUTABLE" ]]; then
    printf '%s' "\$REPLIT_PLAYWRIGHT_CHROMIUM_EXECUTABLE"; return 0
  fi
  if [[ -x /opt/meta-chromium/chrome ]]; then printf '%s' /opt/meta-chromium/chrome; return 0; fi
  if command -v launch-hermes-chrome >/dev/null 2>&1; then printf '%s' launch-hermes-chrome; return 0; fi
  for c in chromium chromium-browser google-chrome-stable google-chrome; do
    command -v "\$c" >/dev/null 2>&1 && { printf '%s' "\$c"; return 0; }
  done
  return 1
}

tor_running() { pgrep -x tor >/dev/null 2>&1; }
tor_bootstrapped() { grep -q 'Bootstrapped 100%' "\$TORLOG" 2>/dev/null; }

# --check: SOCKS-only egress proof, no browser. curl through the proxy and
# report IsTor; exit non-zero when the proxy is down or the egress is not Tor.
if [[ "\$URL" == "--check" ]]; then
  if ! tor_running; then echo "tor-browser: daemon not running — start it with: tor-browser <url>" >&2; exit 1; fi
  resp="\$(curl -s --max-time 60 --socks5-hostname "127.0.0.1:\$TOR_SOCKS_PORT" https://check.torproject.org/api/ip 2>/dev/null || true)"
  if printf '%s' "\$resp" | grep -q '"IsTor":true'; then
    echo "Tor egress confirmed: \$resp"
    exit 0
  else
    echo "tor-browser: check.torproject.org did not confirm IsTor (resp: \${resp:-none}) — the daemon may still be bootstrapping" >&2
    exit 1
  fi
fi

# Ensure the daemon is up + bootstrapped (on-demand start, no keeper).
if ! tor_running; then
  [[ -f "\$TORRC" ]] || { echo "tor-browser: no torrc at \$TORRC — run 'setup.sh --tor' first" >&2; exit 1; }
  mkdir -p "\$TOR_HOME/logs"
  # Fresh log: a stale 'Bootstrapped 100%' line from a previous run
  # would make the wait below pass before THIS daemon is ready (the
  # browser then times out on the proxy: ERR_TIMED_OUT). Truncate so
  # only this run's lines are in the file.
  : > "\$TORLOG" 2>/dev/null || true
  # Absolute path to the launcher: plain 'tor' alone is NOT on PATH in every
  # context (a Muse VM's ~/.local/bin is on PATH only via env.sh, which
  # a bare exec may not source) — a bare 'tor' here died "No such file
  # or directory" while the script waited 5 min for a bootstrap that
  # never started.
  # (No backticks anywhere in this heredoc: an unquoted heredoc executes
  # backtick-quoted text as command substitution even inside a comment,
  # so a backticked word here would run as a command at write time.)
  setsid nohup "\$TOR_BIN_DIR/tor" -f "\$TORRC" >"\$TOR_HOME/logs/tor-start.log" 2>&1 < /dev/null &
  echo "tor started (pid \$!)"
fi
# Bootstrap is flaky on first run (relays refuse, then it catches on —
# muse-hop stuck at 10% for hours once, then bootstrapped clean). Wait
# up to 5 minutes, polling the log; a timeout names the log, not a guess.
for _ in \$(seq 1 60); do
  tor_bootstrapped && break
  sleep 5
done
if ! tor_bootstrapped; then
  echo "tor-browser: daemon did not bootstrap in 5 min — see \$TORLOG (last lines:)" >&2
  tail -5 "\$TORLOG" >&2 || true
  exit 1
fi
echo "tor bootstrapped: \$(grep 'Bootstrapped 100%' "\$TORLOG" | tail -1)"
# The log line proves the daemon *says* it bootstrapped; prove the proxy
# actually answers before launching Chrome (a stale log line once sent
# the browser into a proxy that was not ready yet: ERR_TIMED_OUT).
_ready=0
for _ in \$(seq 1 12); do
  if curl -s --max-time 10 --socks5-hostname "127.0.0.1:\$TOR_SOCKS_PORT" https://check.torproject.org/api/ip 2>/dev/null | grep -q '"IsTor":true'; then _ready=1; break; fi
  sleep 5
done
[[ "\$_ready" -eq 1 ]] || { echo "tor-browser: SOCKS proxy on 127.0.0.1:\$TOR_SOCKS_PORT did not confirm IsTor after bootstrap — see \$TORLOG" >&2; exit 1; }

CHROME="\$(tor_chrome_bin)" || { echo "tor-browser: no Chromium found — set TOR_CHROME, or on Replit the store browser, or run 'setup.sh --hermes-browser'" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "tor-browser: node is required for the CDP driver — run 'setup.sh --node' first" >&2; exit 1; }
mkdir -p "\$PROFILE"
# Hatch Chromium requires the WebGL policy file + its SHA256 (see
# tor_write_webgl_policy); a stock Chromium ignores the unknown switches.
# The SHA is computed here, at run time, so the file and the flag can
# never drift. No policy file (an older install) means no flags.
WEBGL_FLAGS=()
if [[ -f "\$TOR_HOME/hatch-webgl-domains.txt" ]]; then
  WEBGL_SHA="\$(sha256sum "\$TOR_HOME/hatch-webgl-domains.txt" | cut -d' ' -f1)"
  WEBGL_FLAGS=(--hatch-webgl-allowed-domains-file="\$TOR_HOME/hatch-webgl-domains.txt" --hatch-webgl-allowed-domains-sha256="\$WEBGL_SHA")
fi
setsid nohup "\$CHROME" --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage \\
  "\${WEBGL_FLAGS[@]}" \\
  --proxy-server="socks5://127.0.0.1:\$TOR_SOCKS_PORT" \\
  --remote-debugging-port="\$TOR_CDP_PORT" --remote-debugging-address=127.0.0.1 \\
  --user-data-dir="\$PROFILE" about:blank >"\$TOR_HOME/logs/chrome-cdp.log" 2>&1 < /dev/null &
CPID=\$!
trap 'kill \$CPID 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 1
  curl -s --max-time 2 "http://127.0.0.1:\$TOR_CDP_PORT/json/version" >/dev/null 2>&1 && break
done
curl -s --max-time 5 "http://127.0.0.1:\$TOR_CDP_PORT/json/version" >/dev/null 2>&1 \\
  || { echo "tor-browser: Chromium CDP did not answer on :\$TOR_CDP_PORT — see \$TOR_HOME/logs/chrome-cdp.log" >&2; exit 1; }
TOR_CDP_PORT="\$TOR_CDP_PORT" node "\$DRIVER" "\$URL" 75000
EOF
  chmod +x "$f"
  ok "tor-browser driver: $f"
}

install_tor() {
  step "Tor browser (expert bundle $TOR_BROWSER_VERSION, tor $TOR_VERSION + CDP driver)"
  need_cmd curl
  case "$(uname -m)" in
    x86_64|amd64|aarch64|arm64) ;;
    *) die "tor: unsupported arch $(uname -m) (expert bundle ships linux x86_64 + aarch64 only)" ;;
  esac
  mkdir -p "$TOR_BIN_DIR" "$TOR_HOME"

  local asset url tmp
  asset="$(tor_asset_name)"
  url="$TOR_RELEASE_BASE/$TOR_BROWSER_VERSION/$asset"
  tmp="${TMPDIR:-/tmp}/tor-expert-bundle.tar.gz"

  # Already at the pinned version: no download, no re-verify — only the
  # torrc/shims/driver below are re-asserted. Re-running an installer
  # is the repair path, so it must be cheap and quiet (tailscale shape).
  if [[ -x "$TOR_HOME/bundle/tor/tor" ]] \
     && [[ "$(LD_LIBRARY_PATH="$TOR_HOME/bundle/tor" "$TOR_HOME/bundle/tor/tor" --version 2>/dev/null | head -1 || true)" == "Tor version $TOR_VERSION"* ]]; then
    skip "tor $TOR_VERSION already installed ($TOR_HOME/bundle)"
  else
    echo "  Downloading $asset"
    curl -fsSL "$url" -o "$tmp" || die "tor download failed: $url"
    # Size first (cheap corruption catch), then the pinned SHA256 —
    # upstream publishes no .sha256 sidecar (only .asc signatures), so
    # the pin recorded in this module is the reference (see the header).
    local got_size want_size
    got_size="$(stat -c%s "$tmp" 2>/dev/null || echo 0)"
    want_size="$(tor_asset_size)"
    if [[ "$got_size" != "$want_size" ]]; then
      rm -f "$tmp"
      die "tor ($asset) size mismatch (got $got_size, expected $want_size for $TOR_BROWSER_VERSION) — download may be corrupt, or TOR_BROWSER_VERSION moved without refreshing the pins in scripts/setup/tor.sh"
    fi
    verify_sha256 "$tmp" "$(tor_asset_sha256)" "tor ($asset)"
    # The tarball is flat (data/ debug/ docs/ tor/ at the top level), so
    # it extracts straight into bundle/ — the pristine copy. User state
    # (data/, torrc, driver) lives beside it, never inside it.
    rm -rf "$TOR_HOME/bundle"
    mkdir -p "$TOR_HOME/bundle"
    tar -xzf "$tmp" -C "$TOR_HOME/bundle" || die "tor: extract failed"
    rm -f "$tmp"
    # The binary must actually run on this box (LD_LIBRARY_PATH is the
    # whole reason the launcher shim exists — verify the bundle, not the shim).
    local ver
    ver="$(LD_LIBRARY_PATH="$TOR_HOME/bundle/tor" "$TOR_HOME/bundle/tor/tor" --version 2>/dev/null | head -1 || true)"
    [[ "$ver" == "Tor version $TOR_VERSION"* ]] \
      || die "tor binary does not run as $TOR_VERSION (got '${ver:-nothing}') — wrong arch or a corrupt install"
    ok "tor installed: $TOR_HOME/bundle ($ver)"
  fi

  tor_write_torrc
  tor_write_webgl_policy
  tor_write_launcher
  tor_write_cdp_driver
  tor_write_browser_driver
  tor_write_env_example

  # Wiring (repl profile only — common.sh is not loaded under muse, and
  # there is no managed block there to wire into; the guards keep this
  # lane dual-profile). The shim bakes TOR_HOME in, so the daemon works
  # even where the var is never exported.
  if declare -F record_tool_env_vars >/dev/null 2>&1; then
    record_tool_env_vars TOR_HOME TOR_BIN_DIR
    record_tool_path_dirs "$TOR_BIN_DIR"
  fi
  if declare -F wire_tool >/dev/null 2>&1; then
    wire_tool tor TOR_HOME TOR_BIN_DIR -- "$TOR_BIN_DIR"
  fi

  ok "tor ready — check egress: tor-browser --check (starts the daemon on demand); browse: tor-browser https://check.torproject.org/api/ip"
}

clean_tor() {
  if ! _present "$TOR_HOME/bundle" "$TOR_BIN_DIR/tor" "$TOR_BIN_DIR/tor-browser"; then
    nothing_removed "Tor"; return 0
  fi
  step "Removing Tor browser"
  # Stop THIS TOR_HOME's daemon only. A blanket `pkill -x tor` would
  # also kill a user's own tor on the same box (a test-root clean killed
  # the muse-hop daemon that way) — so kill by the PID file tor wrote
  # (PidFile in torrc), verified to be a tor process, and fall back to
  # matching the torrc path in the command line. Never pkill -x tor.
  local _pid=""
  if [[ -f "$TOR_HOME/data/tor.pid" ]]; then
    _pid="$(cat "$TOR_HOME/data/tor.pid" 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  if [[ -n "$_pid" ]] && kill -0 "$_pid" 2>/dev/null && tr '\0' ' ' < "/proc/$_pid/cmdline" 2>/dev/null | grep -q "tor"; then
    kill "$_pid" 2>/dev/null || true
    sleep 1
  else
    local _p
    for _p in $(pgrep -f "tor -f $TOR_HOME/torrc" 2>/dev/null || true); do
      kill "$_p" 2>/dev/null || true
    done
    [[ -n "$(pgrep -f "tor -f $TOR_HOME/torrc" 2>/dev/null || true)" ]] && sleep 1 || true
  fi
  rm -f "$TOR_BIN_DIR/tor" "$TOR_BIN_DIR/tor-browser"
  rm -rf "$TOR_HOME/bundle" "$TOR_HOME/torrc" "$TOR_HOME/tor-browser-test.mjs"
  rm -rf "$TOR_HOME/chromium-profile" "$TOR_HOME/logs"
  # Operator data (the DataDirectory: keys + cached consensus, the
  # .env template, and the WebGL policy file) is user data — kept;
  # delete $TOR_HOME to wipe it.
  ok "Tor removed (bundle + shims + driver; DataDirectory + .env.example + WebGL policy kept in $TOR_HOME)"
}
