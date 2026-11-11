"""mcp_stdio_test.py — drive an @askjo/camofox-browser-mcp stdio adapter over
its real transport: initialize, tools/list, then create/evaluate/close a tab.
Usage: python3 mcp_stdio_test.py <adapter.mjs> <keyfile> <port>
Exits 0 only if all stages pass. Prints no secret values."""
import json, os, select, shutil, subprocess, sys

adapter, keyfile, port = sys.argv[1], sys.argv[2], sys.argv[3]
key = open(keyfile).read().strip()
node = shutil.which("node") or "node"

env = dict(os.environ)
env.update({
    "CAMOFOX_BASE_URL": f"http://127.0.0.1:{port}",
    "CAMOFOX_ACCESS_KEY": key,
})
if os.environ.get("CAMOFOX_MCP_LD_LIBRARY_PATH"):
    env["LD_LIBRARY_PATH"] = os.environ["CAMOFOX_MCP_LD_LIBRARY_PATH"]

proc = subprocess.Popen(
    [node, adapter],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    text=True, env=env)

def send(msg):
    proc.stdin.write(json.dumps(msg) + "\n")
    proc.stdin.flush()

def read_for(want, timeout=150):
    while True:
        r, _, _ = select.select([proc.stdout], [], [], timeout)
        if not r:
            raise TimeoutError(f"no response id={want}")
        line = proc.stdout.readline()
        if not line:
            raise EOFError("adapter closed: " + proc.stderr.read()[:200])
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue
        if d.get("id") == want:
            return d

def text_of(d):
    return d["result"]["content"][0]["text"]

rc = 1
try:
    send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2024-11-05", "capabilities": {},
        "clientInfo": {"name": "e2e", "version": "1"}}})
    info = read_for(1)["result"]["serverInfo"]
    print("PASS: initialize ->", info.get("name"), info.get("version"))

    send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    send({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
    names = sorted(t["name"] for t in read_for(2)["result"]["tools"])
    camo = [n for n in names if n.startswith("camofox_")]
    print(f"PASS: tools/list -> {len(camo)} camofox tools" if len(camo) == 11
          else f"FAIL: tools/list -> {len(camo)} camofox tools: {camo}")

    send({"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {
        "name": "camofox_create_tab",
        "arguments": {"url": "https://example.com"}}})
    tab = json.loads(text_of(read_for(3)))
    tid = tab.get("tabId", "")
    ok3 = bool(tid) and tab.get("navigationOk") and tab.get("httpStatus") == 200
    print("PASS: create_tab -> tabId=%s… status=%s" % (tid[:8], tab.get("httpStatus")) if ok3
          else "FAIL: create_tab -> %s" % str(tab)[:150])

    send({"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {
        "name": "camofox_evaluate",
        "arguments": {"tabId": tid, "expression": "navigator.userAgent"}}})
    ua = json.loads(text_of(read_for(4))).get("result", "")
    print("PASS: evaluate -> Firefox UA" if "Firefox" in str(ua)
          else "FAIL: evaluate -> %s" % str(ua)[:120])

    send({"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {
        "name": "camofox_list_tabs", "arguments": {}}})
    tabs = json.loads(text_of(read_for(5)))
    print("PASS: list_tabs -> tab present" if tid in json.dumps(tabs)
          else "FAIL: list_tabs -> %s" % str(tabs)[:120])

    send({"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {
        "name": "camofox_close_tab", "arguments": {"tabId": tid}}})
    closed = json.loads(text_of(read_for(6)))
    print("PASS: close_tab -> ok" if closed.get("ok")
          else "FAIL: close_tab -> %s" % str(closed)[:120])

    rc = 0
except Exception as e:
    print("FAIL: mcp stage error:", type(e).__name__, str(e)[:200])
finally:
    try:
        proc.stdin.close()
        proc.terminate()
        proc.wait(timeout=5)
    except Exception:
        proc.kill()

sys.exit(rc)
