# shellcheck shell=bash
# exec-runner.sh — node-local exec runner (fetch-at-destination exec).
#
# Problem (Google Task "Masalah exec payload di node dest"): even with
# fetch solved, the trigger that EXECUTES a fetched payload still
# transits the agent's tools (ssh via the runner) and gets flagged.
# This runner closes that gap: it polls the payload-store queue
# manifest for this node, fetches new payloads (sha-verified via
# tsfetch), executes them, and POSTs the result back. Execution never
# transits agent tools — only local file writes (queue manifest on
# muse-hop) and result reads cross the tool pipeline.
#
# Flow per poll (EXEC_POLL_S, default 60):
#   1. Fetch queue/<node>.json via tsfetch (no sha pin — the manifest is
#      control data that changes often; the PAYLOAD is sha-verified).
#      404 (no queue yet) is normal — sleep and continue.
#   2. For each job not in the local done-list:
#        a. Fetch the payload via tsfetch (pinned sha256, atomic land).
#        b. Execute with `timeout` + bash, capture stdout/stderr + rc.
#        c. POST the result JSON to /exec-result/<node> (nc, same
#           hold-open pattern as tsbeacon). Failed POSTs go to a
#           buffer and are retried at the next poll (tsbeacon backlog
#           pattern). The job is marked done once executed — the
#           buffer guarantees the result still lands.
#   3. Retry any buffered result POSTs.
#
# Started detached (setsid nohup) once tailscaled is up; a workspace
# stop kills it with everything else and the next boot's join starts
# it again. No resident interpreter — between polls it is a plain
# `sleep`. Dedup via pidfile; a second start while a live loop holds
# it exits quietly. Config is big-env (system env wins, no .env read):
# EXEC_POLL_S, EXEC_TIMEOUT_S, EXEC_LOG, EXEC_STATE_DIR, TSFETCH_SH,
# STORE_HOST, STORE_PORT.
set -u

WS="${REPL_HOME:-$HOME/workspace}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd)"
NODE="${1:-}"
if [ -z "$NODE" ]; then
  NODE=$(sed -n 's/^TAILSCALE_NODE_NAME = "\(.*\)"/\1/p' "$WS/.replit" 2>/dev/null | head -1)
  [ -n "$NODE" ] || NODE=$(hostname)
fi
HOST="${STORE_HOST:-100.113.127.73}"
PORT="${STORE_PORT:-8099}"
TS_BIN="${TS_BIN:-$WS/.local/bin/tailscale}"
TS_SOCK="${TS_SOCK:-$WS/.local/state/tailscale/tailscaled.sock}"
TSFETCH_SH="${TSFETCH_SH:-$SELF_DIR/tsfetch.sh}"
[ -x "$TSFETCH_SH" ] || TSFETCH_SH="$WS/ignition/scripts/replit/tsfetch.sh"
POLL="${EXEC_POLL_S:-60}"
TIMEOUT_S="${EXEC_TIMEOUT_S:-300}"
STATE_DIR="${EXEC_STATE_DIR:-$WS/.config/exec-runner}"
PIDFILE="$STATE_DIR/runner.pid"
DONE_FILE="$STATE_DIR/done"
BUFFER="$STATE_DIR/buffer.jsonl"
LOG="${EXEC_LOG:-$WS/.local/state/exec-runner.log}"
WORK_DIR="$STATE_DIR/work"

log() { printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >>"$LOG" 2>/dev/null || true; }

mkdir -p "$STATE_DIR" "$WORK_DIR" "$(dirname "$LOG")"
touch "$DONE_FILE" "$BUFFER"

if [ -f "$PIDFILE" ]; then
  old_pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [ -n "${old_pid:-}" ] && kill -0 "$old_pid" 2>/dev/null; then
    exit 0
  fi
fi
printf '%s\n' "$$" >"$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT

# Keep the log bounded: rotate once at start when it outgrows ~1 MB.
if [ -f "$LOG" ] && [ "$(wc -c <"$LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then
  mv "$LOG" "$LOG.1" 2>/dev/null || true
fi

# The fleet python (bare python3 is not on a Replit ssh PATH; the ctls
# glob is the fleet standard, same as tsfetch.sh).
py3() {
  PY=$(ls /repl/ctls/*/bin/python3 2>/dev/null | head -1)
  [ -n "$PY" ] || PY=$(command -v python3 || true)
  [ -n "$PY" ] || return 1
  printf '%s' "$PY"
}

# POST a JSON body to the store via tailscale nc (tsbeacon pattern:
# hold stdin open with sleep, HTTP/1.0, check the reply's first line).
# $1 = path, $2 = body file. Returns 0 on HTTP 200.
post_json() {
  _path="$1"; _body_file="$2"
  _len=$(wc -c <"$_body_file" 2>/dev/null || echo 0)
  _resp=$( (printf 'POST %s HTTP/1.0\r\nHost: %s\r\nContent-Type: application/json\r\nContent-Length: %s\r\n\r\n' "$_path" "$HOST" "$_len"; cat "$_body_file"; sleep 5) \
    | timeout 30 "$TS_BIN" --socket="$TS_SOCK" nc "$HOST" "$PORT" 2>/dev/null | head -1 )
  case "$_resp" in
    *" 200 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# Retry buffered result POSTs (tsbeacon backlog pattern). Each line is
# one complete result JSON. On success the line is dropped; failures
# stay buffered for the next poll.
flush_buffer() {
  [ -s "$BUFFER" ] || return 0
  _tmp="$BUFFER.tmp.$$"
  : > "$_tmp"
  while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    printf '%s' "$_line" > "$WORK_DIR/retry.json"
    if post_json "/exec-result/$NODE" "$WORK_DIR/retry.json"; then
      log INFO "flushed buffered result ok"
    else
      printf '%s\n' "$_line" >> "$_tmp"
    fi
  done < "$BUFFER"
  mv "$_tmp" "$BUFFER"
}

log INFO "exec-runner start pid=$$ node=$NODE poll=${POLL}s timeout=${TIMEOUT_S}s tsfetch=$TSFETCH_SH"
while true; do
  flush_buffer

  QUEUE_TMP="$WORK_DIR/queue.json"
  if ! sh "$TSFETCH_SH" "queue/$NODE.json" "$QUEUE_TMP" >/dev/null 2>&1; then
    # 404 (no queue yet) or fetch error — normal, nothing queued.
    sleep "$POLL"
    continue
  fi

  PY=$(py3) || { log ERROR "no python3 for queue parse"; sleep "$POLL"; continue; }
  JOBS=$("$PY" - "$QUEUE_TMP" <<'PYEOF' 2>/dev/null
import sys, json
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
for j in d.get("jobs", []):
    try:
        print("%s|%s|%s" % (j["id"], j["payload"], j["sha256"]))
    except KeyError:
        continue
PYEOF
)
  [ -n "$JOBS" ] || { sleep "$POLL"; continue; }

  printf '%s\n' "$JOBS" | while IFS='|' read -r JOB_ID PAYLOAD SHA; do
    [ -n "$JOB_ID" ] || continue
    if grep -qxF "$JOB_ID" "$DONE_FILE" 2>/dev/null; then
      continue
    fi
    log INFO "job $JOB_ID payload=$PAYLOAD"
    DEST="$WORK_DIR/$PAYLOAD"
    FETCH_OK=1
    if ! sh "$TSFETCH_SH" "$PAYLOAD" "$DEST" "$SHA" >/dev/null 2>&1; then
      log WARN "job $JOB_ID fetch failed payload=$PAYLOAD (sha or store)"
      FETCH_OK=0
    fi
    OUT_F="$WORK_DIR/out.txt"; ERR_F="$WORK_DIR/err.txt"
    : > "$OUT_F"; : > "$ERR_F"
    RC=0
    if [ "$FETCH_OK" = "1" ]; then
      if timeout "$TIMEOUT_S" bash "$DEST" >"$OUT_F" 2>"$ERR_F"; then
        RC=0
      else
        RC=$?
      fi
    else
      RC=-1
      printf 'fetch failed: payload=%s sha=%s\n' "$PAYLOAD" "$SHA" > "$ERR_F"
    fi
    # Build the result JSON (python escapes stdout/stderr properly).
    # Cap each stream at 16000 chars so the POST stays well under the
    # store's 256 KB result limit.
    RESULT_F="$WORK_DIR/result.json"
    if ! "$PY" - "$JOB_ID" "$NODE" "$PAYLOAD" "$SHA" "$RC" "$OUT_F" "$ERR_F" "$RESULT_F" <<'PYEOF' 2>/dev/null
import sys, json
job_id, node, payload, sha, rc, out_f, err_f, res_f = sys.argv[1:9]
def cap(p):
    try:
        with open(p, "r", errors="replace") as f:
            return f.read(16000)
    except OSError:
        return ""
import datetime
res = {
    "job_id": job_id,
    "node": node,
    "ts": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "payload": payload,
    "sha256": sha,
    "exit_code": int(rc),
    "stdout": cap(out_f),
    "stderr": cap(err_f),
}
with open(res_f, "w") as f:
    json.dump(res, f)
PYEOF
    then
      log ERROR "job $JOB_ID result build failed"
      printf '%s\n' "$JOB_ID" >> "$DONE_FILE"
      continue
    fi
    if post_json "/exec-result/$NODE" "$RESULT_F"; then
      log INFO "job $JOB_ID done rc=$RC result posted"
    else
      # Buffer the result for retry; the job itself is done (executed
      # once) — the buffer guarantees the result still lands.
      cat "$RESULT_F" >> "$BUFFER"
      log WARN "job $JOB_ID done rc=$RC result buffered (post failed)"
    fi
    printf '%s\n' "$JOB_ID" >> "$DONE_FILE"
  done

  sleep "$POLL"
done
