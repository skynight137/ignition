#!/usr/bin/env python3
"""wake-push.py — PROTOTYPE: on wake, push buffered beacon + log tails to muse-hop.

Runs once (not a loop). Gathers the node's buffered beacon lines and the
recent tails of the incident-relevant logs, and POSTs them as one wake
report to the payload-store (:8099) with curl through the tailscaled SOCKS5
proxy on localhost:1055 (the node cannot dial 100.x directly — userspace
tailscale, no TUN; plain curl to the tailnet IP times out. The join starts
tailscaled with --socks5-server=localhost:1055, so curl --socks5-hostname
reaches the store).
Best-effort: one attempt, exit 1 on failure, no retry, no buffering (the
logs stay on the node; the periodic beacon loop keeps running).

Prototype scope: run manually on repl-0 (simulated wake). The boot trigger
is trigger B: beacon-loop.sh runs this script once on its first post after
(re)start (WAKE_PUSH=0 skips it).

Interpreter: /repl/tools/bin/python3 (the default Replit python3 — bare
`python3` is not on the PATH in a non-interactive shell, and the tour's
venv python is not the canonical one).

Usage: /repl/tools/bin/python3 wake-push.py [node-name]
Env: STORE_HOST (default 100.113.127.73), STORE_PORT (8099),
     WAKE_PROXY (default localhost:1055).
"""
import json
import os
import subprocess
import sys
from datetime import datetime

WS = os.path.expanduser("~/workspace")
NODE = sys.argv[1] if len(sys.argv) > 1 else ""
if not NODE:
    try:
        with open(os.path.join(WS, ".replit")) as f:
            for line in f:
                if line.startswith("TAILSCALE_NODE_NAME"):
                    NODE = line.split('"')[1]
                    break
    except OSError:
        pass
    NODE = NODE or os.uname().nodename
HOST = os.environ.get("STORE_HOST", "100.113.127.73")
PORT = os.environ.get("STORE_PORT", "8099")
PROXY = os.environ.get("WAKE_PROXY", "localhost:1055")

LINE_CAP = 500  # truncate absurdly long log lines (camofox log)


def tail_lines(path, n):
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        return []
    text = data.decode("utf-8", "replace")
    lines = [ln[:LINE_CAP] for ln in text.splitlines()]
    return lines[-n:] if n > 0 else lines


def main():
    buffered = []
    buf_path = os.path.join(WS, ".config/beacon/buffer.jsonl")
    try:
        with open(buf_path) as f:
            buffered = [ln.rstrip("\n") for ln in f if ln.strip()]
    except OSError:
        pass
    buffered = buffered[-5:]  # complete lines only, newest
    # Live tour evidence: the workflow logs are what the tour actually
    # writes on every node (tour-manual.log is stale on workflow-born
    # tours — repl-0's stops Nov 12 while its tour runs). Take the last
    # verdict lines from the newest workflow-log files.
    verdicts = []
    wl_dir = os.path.join(WS, ".local/state/workflow-logs")
    try:
        wfiles = []
        for root, _dirs, names in os.walk(wl_dir):
            for nm in names:
                if nm.endswith(".shell.exec.0"):
                    wfiles.append(os.path.join(root, nm))
        wfiles.sort(key=lambda p: os.path.getmtime(p), reverse=True)
        for fp in wfiles[:3]:
            try:
                with open(fp, "rb") as f:
                    text = f.read().decode("utf-8", "replace")
                for ln in text.splitlines():
                    if "verdict=" in ln:
                        verdicts.append(ln[:LINE_CAP])
            except OSError:
                pass
        verdicts = verdicts[-5:]
    except OSError:
        pass
    try:
        uptime_s = int(float(open("/proc/uptime").read().split()[0]))
    except (OSError, ValueError, IndexError):
        uptime_s = 0
    # Bracket pattern: never self-match this script's own cmdline.
    tour_alive = subprocess.run(
        ["pgrep", "-f", "[t]our.py"], capture_output=True).returncode == 0
    report = {
        "node": NODE,
        "ts": datetime.now().strftime("%Y-%m-%dT%H:%M:%S%z"),
        "kind": "wake-push",
        "uptime_s": uptime_s,
        "tour_alive": tour_alive,
        "buffered_beacon": buffered,
        "workflow_verdicts": verdicts,
        "tour_log": tail_lines(os.path.join(WS, ".local/state/tour-manual.log"), 40),
        "beacon_log": tail_lines(os.path.join(WS, ".local/state/beacon.log"), 15),
        "crash_shim_log": tail_lines(os.path.join(WS, ".local/state/crash-shim.log"), 10),
        "camofox_log": tail_lines(os.path.join(WS, "logs/camofox-browser.log"), 20),
    }
    body = json.dumps(report).encode("utf-8")
    url = f"http://{HOST}:{PORT}/wake-report/{NODE}"
    cmd = ["curl", "-s", "-m", "30", "--socks5-hostname", PROXY,
           "-X", "POST", "-H", "Content-Type: application/json",
           "--data-binary", "@-", url, "-w", "\n%{http_code}"]
    try:
        proc = subprocess.run(cmd, input=body, capture_output=True, timeout=40)
    except (subprocess.TimeoutExpired, OSError) as e:
        print(f"wake-push: {NODE} failed ({e})", file=sys.stderr)
        return 1
    out = proc.stdout.decode("utf-8", "replace").strip().splitlines()
    code = out[-1] if out else ""
    if proc.returncode == 0 and code == "200":
        print(f"wake-push: {NODE} ok ({len(body)} B)")
        return 0
    print(f"wake-push: {NODE} failed (curl rc={proc.returncode} "
          f"http={code or 'none'})", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
