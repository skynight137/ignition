#!/usr/bin/env python3
"""crash-shim — loopback receiver for the camofox crash reporter.

The reporter's sendToRelay() does a plain fetch() to CAMOFOX_CRASH_REPORT_URL.
A Replit box CANNOT dial the tailnet directly (raw curl to 100.x times out;
MagicDNS doesn't resolve from the shell) — so the URL points here, at
127.0.0.1:18099, and this shim forwards each report to the CC on muse-hop
(payload-store POST /crash-report/<node>) over `tailscale nc`, the one
carrier proven to work from a box (same held-open-stdin pattern as
tsbeacon.sh). Reports spool to disk when muse-hop is down and are retried
every 60s, so a dark VM costs delay, not loss.

Env: SHIM_PORT (18099), SHIM_NODE (default TAILSCALE_NODE_NAME from
.replit, else hostname), STORE_HOST (100.113.127.73), STORE_PORT (8099),
TS_BIN, TS_SOCK (fleet join defaults). Started by crash-shim-loop.sh
(supervisor, spawned by the join lane); the camofox server's
CAMOFOX_CRASH_REPORT_URL (set in the camofox env snippet by setup.sh
--camofox) points at this shim. Design: heavenly-host
docs/camofox-collector-investigation.md.
"""
import json
import os
import subprocess
import threading
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

WS = os.environ.get("REPL_HOME") or os.path.expanduser("~/workspace")
PORT = int(os.environ.get("SHIM_PORT", "18099"))
HOST = os.environ.get("STORE_HOST", "100.113.127.73")
STORE_PORT = os.environ.get("STORE_PORT", "8099")
TS_BIN = os.environ.get("TS_BIN", os.path.join(WS, ".local/bin/tailscale"))
TS_SOCK = os.environ.get("TS_SOCK", os.path.join(WS, ".local/state/tailscale/tailscaled.sock"))
SPOOL = os.path.join(WS, ".config/crash-shim/spool.jsonl")
LOGF = os.path.join(WS, ".local/state/crash-shim.log")
MAX_BODY = 262144

NODE = os.environ.get("SHIM_NODE", "")
if not NODE:
    try:
        with open(os.path.join(WS, ".replit")) as f:
            for line in f:
                if line.startswith("TAILSCALE_NODE_NAME"):
                    NODE = line.split("=", 1)[1].strip().strip('"')
                    break
    except OSError:
        pass
NODE = NODE or os.uname().nodename

LOCK = threading.Lock()


def log(level, msg):
    line = f"[{datetime.now():%Y-%m-%d %H:%M:%S}] [{level}] {msg}"
    print(line, flush=True)
    try:
        with open(LOGF, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


def forward(node, body):
    """One report to the CC over tailscale nc. Returns True on HTTP 200."""
    req = (
        f"POST /crash-report/{node} HTTP/1.0\r\n"
        f"Host: {HOST}\r\n"
        "Content-Type: application/json\r\n"
        f"Content-Length: {len(body)}\r\n\r\n"
    ).encode() + body
    try:
        # Held-open stdin: tailscale nc tears the session down if stdin
        # closes instantly after the write (beacon/tsfetch lesson), so
        # keep it open 5s after the request bytes, then read the reply.
        p = subprocess.Popen(
            [TS_BIN, f"--socket={TS_SOCK}", "nc", HOST, STORE_PORT],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        p.stdin.write(req)
        p.stdin.flush()
        time.sleep(5)
        p.stdin.close()
        out = p.stdout.read()
        p.wait(timeout=10)
        return b" 200 " in out.split(b"\r\n", 1)[0]
    except Exception as e:
        log("WARN", f"forward failed: {type(e).__name__}")
        return False


def flush_spool():
    with LOCK:
        if not os.path.exists(SPOOL) or os.path.getsize(SPOOL) == 0:
            return
        with open(SPOOL) as f:
            lines = [ln.rstrip("\n") for ln in f if ln.strip()]
        kept = []
        for ln in lines:
            try:
                item = json.loads(ln)
                body = item["body"].encode() if isinstance(item.get("body"), str) else json.dumps(item["body"]).encode()
            except Exception:
                continue
            if forward(item.get("node", NODE), body):
                log("INFO", f"flushed spooled report ({len(body)} B)")
            else:
                kept.append(ln)
        with open(SPOOL, "w") as f:
            f.write("\n".join(kept) + ("\n" if kept else ""))


def retry_loop():
    while True:
        time.sleep(60)
        try:
            flush_spool()
        except Exception as e:
            log("WARN", f"retry loop: {type(e).__name__} {e}")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        try:
            n = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            n = 0
        if n <= 0 or n > MAX_BODY:
            self.send_error(400)
            return
        body = self.rfile.read(n)
        try:
            json.loads(body)
        except Exception:
            self.send_error(400)
            return
        os.makedirs(os.path.dirname(SPOOL), exist_ok=True)
        with LOCK:
            with open(SPOOL, "a") as f:
                f.write(json.dumps({"node": NODE, "ts": datetime.now().isoformat(), "body": body.decode("utf-8", "replace")}) + "\n")
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")
        log("INFO", f"received report ({n} B), forwarding")
        threading.Thread(target=flush_spool, daemon=True).start()


if __name__ == "__main__":
    os.makedirs(os.path.dirname(SPOOL), exist_ok=True)
    os.makedirs(os.path.dirname(LOGF), exist_ok=True)
    # Own pidfile: the supervisor loop reads it to tell a live shim from a
    # stale one (setsid forks, so the launcher cannot know the real pid).
    try:
        with open(os.path.join(os.path.dirname(SPOOL), "shim.pid"), "w") as f:
            f.write(str(os.getpid()))
    except OSError:
        pass
    threading.Thread(target=retry_loop, daemon=True).start()
    log("INFO", f"crash-shim up node={NODE} listen=127.0.0.1:{PORT} store={HOST}:{STORE_PORT}")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
