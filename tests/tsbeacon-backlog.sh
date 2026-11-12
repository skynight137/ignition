#!/bin/bash
# tests/tsbeacon-backlog.sh — regression test for the tsbeacon backlog bug
# (repl-110, 2026-11-12): `head -c 4000` cut the backlog mid-line, the
# truncated fragment made every later post invalid JSON (CC 400), and the
# failed body was buffered again, so the loop never recovered.
#
# Runs tsbeacon.sh against a local stub CC over plain TCP (no tailnet):
#   1. a poisoned buffer recovers (first post 400, retry without backlog 200)
#   2. CC down buffers one small valid backlog-less body
#   3. a healthy backlog ships as complete lines
#   4. the buffer is pruned to the newest 10 lines
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BEACON="$ROOT/scripts/replit/tsbeacon.sh"
TMP="$(mktemp -d)"
STUB_PID=""
trap '[ -n "$STUB_PID" ] && kill $STUB_PID 2>/dev/null; rm -rf "$TMP"' EXIT

command -v nc >/dev/null 2>&1 || { echo "SKIP: nc not available"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available"; exit 0; }

FAILURES=0
check() {
  desc="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "PASS: $desc"; else echo "FAIL: $desc"; FAILURES=$((FAILURES+1)); fi
}

# --- fake workspace -------------------------------------------------------
mkdir -p "$TMP/home/workspace/.local/state/workflow-logs/round1"
mkdir -p "$TMP/home/workspace/.config/beacon"
printf 'verdict=SHELL repl-119 2026-11-12T16:22:02Z\n' > "$TMP/home/workspace/.local/state/workflow-logs/round1/round1.shell.exec.0"
printf 'TAILSCALE_NODE_NAME = "test-node"\n' > "$TMP/home/workspace/.replit"

# --- test transport: plain nc in place of `tailscale nc` ------------------
cat > "$TMP/tsbin" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do
  case "$1" in
    --socket=*) shift ;;
    nc) shift; break ;;
    *) shift ;;
  esac
done
exec nc "$@"
EOF
chmod +x "$TMP/tsbin"

# --- stub CC: 200 for valid JSON, 400 otherwise; logs every request -------
cat > "$TMP/stub.py" <<'EOF'
import json, socket, sys
tmpdir = sys.argv[1]
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0))
srv.listen(8)
srv.settimeout(1.0)
with open(tmpdir + "/port", "w") as f:
    f.write(str(srv.getsockname()[1]))

def read_request(conn):
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = conn.recv(4096)
        if not chunk:
            return None
        buf += chunk
    head, rest = buf.split(b"\r\n\r\n", 1)
    length = 0
    for line in head.split(b"\r\n")[1:]:
        k, _, v = line.partition(b":")
        if k.strip().lower() == b"content-length":
            length = int(v.strip())
    while len(rest) < length:
        chunk = conn.recv(4096)
        if not chunk:
            break
        rest += chunk
    return rest[:length]

while True:
    try:
        conn, _ = srv.accept()
    except socket.timeout:
        continue
    try:
        conn.settimeout(5)
        body = read_request(conn)
        if body is None:
            conn.close()
            continue
        try:
            parsed = json.loads(body.decode("utf-8"))
            status = 200
        except Exception:
            parsed, status = None, 400
        with open(tmpdir + "/requests.jsonl", "a") as f:
            f.write(json.dumps({"status": status, "body": parsed}) + "\n")
        reason = b"OK" if status == 200 else b"Bad Request"
        conn.sendall(b"HTTP/1.0 %d %s\r\nContent-Length: 2\r\n\r\n{}" % (status, reason))
    except Exception:
        pass
    finally:
        conn.close()
EOF

python3 "$TMP/stub.py" "$TMP" &
STUB_PID=$!
for _ in $(seq 1 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
PORT="$(cat "$TMP/port")"

# one valid backlog-less body, used to seed buffers
VALID='{"node":"test-node","ts":"2026-11-12T00:00:00+0700","uptime_s":1,"tour_alive":true,"camofox_ok":true,"disk_pct":1,"last_verdict":"","backlog":[]}'

run_beacon() { # run_beacon <buffer-file> ; sets RC
  HOME="$TMP/home" STORE_HOST=127.0.0.1 STORE_PORT="$PORT" \
    TS_BIN="$TMP/tsbin" TS_SOCK=/nonexistent BEACON_BUFFER="$1" \
    bash "$BEACON" test-node >"$TMP/out.txt" 2>&1
  RC=$?
}

# --- case 1: poisoned buffer recovers -------------------------------------
BUF1="$TMP/buffer1.jsonl"
printf '%s\n' "$(printf '%s' "$VALID" | head -c 120)" "$VALID" > "$BUF1"
: > "$TMP/requests.jsonl"
run_beacon "$BUF1"
check "1: poisoned buffer: run succeeds" test "$RC" -eq 0
check "1: poisoned buffer: buffer cleared" test ! -s "$BUF1"
check "1: poisoned buffer: stub saw 2 requests" test "$(grep -c . "$TMP/requests.jsonl")" -eq 2
check "1: poisoned buffer: first request 400" python3 -c 'import json,sys; rs=[json.loads(l) for l in open(sys.argv[1])]; assert rs[0]["status"]==400' "$TMP/requests.jsonl"
check "1: poisoned buffer: retry 200 with empty backlog" python3 -c 'import json,sys; rs=[json.loads(l) for l in open(sys.argv[1])]; assert rs[1]["status"]==200 and rs[1]["body"]["backlog"]==[]' "$TMP/requests.jsonl"

# --- case 3: healthy backlog ships as complete lines ----------------------
BUF3="$TMP/buffer3.jsonl"
printf '%s\n%s\n%s\n' "$VALID" "$VALID" "$VALID" > "$BUF3"
: > "$TMP/requests.jsonl"
run_beacon "$BUF3"
check "3: healthy backlog: run succeeds" test "$RC" -eq 0
check "3: healthy backlog: buffer cleared" test ! -s "$BUF3"
check "3: healthy backlog: one request, 200" python3 -c 'import json,sys; rs=[json.loads(l) for l in open(sys.argv[1])]; assert len(rs)==1 and rs[0]["status"]==200' "$TMP/requests.jsonl"
check "3: healthy backlog: 3 complete entries shipped" python3 -c 'import json,sys; rs=[json.loads(l) for l in open(sys.argv[1])]; assert len(rs[0]["body"]["backlog"])==3' "$TMP/requests.jsonl"

# --- stub down from here: the CC is unreachable ---------------------------
kill "$STUB_PID"; STUB_PID=""

# --- case 2: CC down buffers one small valid body -------------------------
BUF2="$TMP/buffer2.jsonl"
run_beacon "$BUF2"
check "2: CC down: run fails" test "$RC" -ne 0
check "2: CC down: exactly 1 buffered line" test "$(grep -c . "$BUF2")" -eq 1
check "2: CC down: buffered line is valid JSON with empty backlog" python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["backlog"]==[] and d["node"]=="test-node"' "$BUF2"
check "2: CC down: buffered line is small (<1000 B)" test "$(wc -c < "$BUF2" | tr -d ' ')" -lt 1000

# --- case 4: buffer pruned to newest 10 lines ----------------------------
BUF4="$TMP/buffer4.jsonl"
for _ in $(seq 1 12); do printf '%s\n' "$VALID" >> "$BUF4"; done
run_beacon "$BUF4"
check "4: prune: run fails (CC down)" test "$RC" -ne 0
check "4: prune: buffer kept at 10 lines" test "$(grep -c . "$BUF4")" -eq 10
check "4: prune: newest line is valid JSON with empty backlog" python3 -c 'import json,sys; lines=open(sys.argv[1]).read().splitlines(); d=json.loads(lines[-1]); assert d["backlog"]==[]' "$BUF4"

echo "tsbeacon-backlog: $FAILURES failure(s)"
exit "$FAILURES"
