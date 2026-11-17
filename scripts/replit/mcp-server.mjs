#!/usr/bin/env node
// repl-mcp-server.mjs — per-node MCP server (Streamable HTTP) for remote command
// execution and read-only file access. Zero dependencies. Runs on ONE fleet node;
// Muse connects directly to it over the tailnet.
//
// Transport & trust model (read before changing):
// - Binds 127.0.0.1 ONLY, never 0.0.0.0 and never a public address. The node's tailscaled
//   (userspace networking) forwards inbound tailnet connections for the node's Tailscale IP
//   to the matching local port — proven on repl-110 (a probe listener on 127.0.0.1:16810 was
//   reachable from muse-hop through the tailnet SOCKS proxy). There is no tailscale0
//   interface on these nodes, so binding the Tailscale IP directly is impossible.
// - NO auth key. Access control is the Tailscale ACL: only tag:muse can dial this port
//   (tag:repl -> tag:repl is tcp:6800 only, so nodes cannot dial each other's MCP port).
// - Protocol: MCP Streamable HTTP, spec versions 2025-03-26 / 2025-06-18 / 2025-11-25.
//   The server answers initialize with the client's proposed version when supported.
//   Responses are plain application/json (no SSE) — the Muse client accepts that.
// - No-race property: every tools/call is an independent HTTP request carrying its own
//   JSON-RPC id; the response echoes that id and the exec result carries it in
//   structuredContent.requestId. No shared buffers, no slot matching. Concurrent execs
//   are independent child processes (capped, see MAX_CONCURRENT).
//
// v0.2.0 changes vs v0.1.0-pilot:
// - Sessions expire after 10 min idle (MCP_SESSION_IDLE_MS, default 600000), swept on
//   every request and by a 60 s timer; the client sends DELETE /mcp at the end of each
//   invocation. No more unbounded session leak (was: every invocation left a session
//   on the node forever).
// - Error codes aligned with the SDK Streamable HTTP reference (Everything's
//   transports/streamableHttp.ts): unknown session -32001 (was -32000); body too large
//   413 -32600 (was -32700); DELETE with no session 400/-32000, unknown session
//   404/-32001; a post-initialize request carrying an unsupported MCP-Protocol-Version
//   header gets 400/-32000. GET /mcp stays 405 (no SSE stream offered — deliberate).
// - Read-only filesystem tools: read_text_file, list_directory, get_file_info,
//   search_files. Allowed roots are ~/workspace and ~/skynight137/toolskit, resolved
//   via realpath at startup (a root that does not exist is dropped with a warning;
//   on a repl node ~/skynight137/toolskit does not exist, so only ~/workspace
//   remains — ~/workspace/ignition is inside it anyway). Every call re-validates
//   (prefix check + realpath re-check) so symlink escapes are refused. No write
//   tools in this version (P1, after review).
//
// Pilot: repl-110, port 16810. Port choice: not in the .replit platform port table
// (80, 3000, 3001, 3002, 3003, 4200, 5000, 5173, 6000, 6800, 8000, 8008, 8080, 8099,
// 9000) so the platform leaves it alone; distinct from the old forwarder range 16802-16804.
//
// Usage: node repl-mcp-server.mjs [--port 16810] [--host 127.0.0.1]
//   MCP_SESSION_IDLE_MS=600000 node repl-mcp-server.mjs   (session idle expiry)
// Logs: exec.log (one line per execution), fs.log (one line per fs call) and
// server.log (startup/errors) in logs/ next to this file.

import http from "node:http";
import { spawn } from "node:child_process";
import { appendFileSync, mkdirSync, realpathSync } from "node:fs";
import { readdir, readFile, lstat } from "node:fs/promises";
import { dirname, join, resolve, relative, sep, isAbsolute } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";
import os from "node:os";

const VERSION = "0.2.0";
const DEFAULT_PORT = 16810;
const DEFAULT_HOST = "127.0.0.1";
const PROTOCOLS = new Set(["2025-11-25", "2025-06-18", "2025-03-26"]);
const MAX_BODY = 1_048_576; // 1 MB request body cap
const MAX_CMD_LEN = 8192;
const MAX_OUTPUT = 1_048_576; // 1 MB per stream cap
const MAX_TIMEOUT_MS = 120_000;
const DEFAULT_TIMEOUT_MS = 30_000;
const MAX_CONCURRENT = 4;
const SESSION_IDLE_MS = parseInt(process.env.MCP_SESSION_IDLE_MS || "600000", 10) || 600000;
const FS_CALL_TIMEOUT_MS = 15_000; // per-call timeout, mirrors the official fs server
const FS_MAX_READ = 262_144; // 256 KiB of text per read_text_file response
const FS_MAX_FILE = 1_048_576; // refuse files larger than 1 MB (read via exec in chunks)
const FS_MAX_LINES = 1000; // head/tail line cap
const FS_MAX_WALK_ENTRIES = 100_000; // recursive walk cap, mirrors the official fs server
const FS_MAX_MATCHES = 1000; // search_files result cap

const HERE = dirname(fileURLToPath(import.meta.url));
const LOG_DIR = join(HERE, "logs");
mkdirSync(LOG_DIR, { recursive: true });
const EXEC_LOG = join(LOG_DIR, "exec.log");
const FS_LOG = join(LOG_DIR, "fs.log");
const SERVER_LOG = join(LOG_DIR, "server.log");

function ts() {
  return new Date().toISOString();
}
function logServer(msg) {
  const line = `[${ts()}] ${msg}\n`;
  process.stderr.write(line);
  try { appendFileSync(SERVER_LOG, line); } catch { /* log file is best-effort */ }
}
function logExec(entry) {
  try { appendFileSync(EXEC_LOG, JSON.stringify(entry) + "\n"); } catch { /* best-effort */ }
}
function logFs(entry) {
  try { appendFileSync(FS_LOG, JSON.stringify(entry) + "\n"); } catch { /* best-effort */ }
}

const args = process.argv.slice(2);
let PORT = DEFAULT_PORT;
let HOST = DEFAULT_HOST;
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--port" && args[i + 1]) PORT = parseInt(args[i + 1], 10) || DEFAULT_PORT;
  if (args[i] === "--host" && args[i + 1]) HOST = args[i + 1];
}
if (HOST !== "127.0.0.1" && HOST !== "::1") {
  console.error(`refusing non-loopback bind host ${HOST}`);
  process.exit(2);
}

// Filesystem allow-list (official pattern): startup allow-list resolved via
// realpath, both the original and the resolved form kept. A root that does
// not exist is dropped with a warning; the process exits if none is usable.
const HOME_DIR = os.homedir();
const FS_ROOTS = [];
for (const p of [join(HOME_DIR, "workspace"), join(HOME_DIR, "skynight137", "toolskit")]) {
  try {
    FS_ROOTS.push({ original: p, resolved: realpathSync(p) });
  } catch (err) {
    console.error(`fs root unusable, dropped: ${p} (${err.message})`);
  }
}
if (FS_ROOTS.length === 0) {
  console.error("no usable fs roots; refusing to start");
  process.exit(2);
}

function expandHome(p) {
  if (p === "~") return HOME_DIR;
  if (p.startsWith("~/")) return join(HOME_DIR, p.slice(2));
  return p;
}

// validatePath, per the official filesystem server: expand ~, resolve relative
// paths against the first allowed root, string prefix check, then realpath +
// re-check so a symlink pointing outside the allow-list is refused. For a
// not-yet-existing path the nearest existing ancestor is resolved instead.
function validatePath(requested) {
  if (typeof requested !== "string" || requested.trim() === "") {
    throw new Error("path must be a non-empty string");
  }
  let abs = expandHome(requested);
  if (!isAbsolute(abs)) abs = resolve(FS_ROOTS[0].resolved, abs);
  abs = resolve(abs);
  const within = (p) => FS_ROOTS.some((r) =>
    p === r.original || p === r.resolved ||
    p.startsWith(r.original + sep) || p.startsWith(r.resolved + sep));
  if (!within(abs)) throw new Error("path is outside the allowed directories");
  let real;
  try {
    real = realpathSync(abs);
  } catch (err) {
    if (err.code !== "ENOENT") throw err;
    let parent = dirname(abs);
    for (;;) {
      try {
        real = join(realpathSync(parent), relative(parent, abs));
        break;
      } catch (perr) {
        if (perr.code !== "ENOENT") throw perr;
        const up = dirname(parent);
        if (up === parent) throw err;
        parent = up;
      }
    }
  }
  if (!within(real)) throw new Error("path resolves outside the allowed directories (symlink escape)");
  return real;
}

const sessions = new Map(); // sessionId -> { createdAt, lastSeen }
let runningExecs = 0;

// Idle expiry: drop sessions idle longer than SESSION_IDLE_MS. Swept on every
// request and by a 60 s timer (unref'd so it never blocks shutdown).
function sweepSessions() {
  const now = Date.now();
  let expired = 0;
  for (const [sid, s] of sessions) {
    if (now - s.lastSeen > SESSION_IDLE_MS) { sessions.delete(sid); expired++; }
  }
  if (expired > 0) logServer(`session sweep: expired ${expired} idle session(s), ${sessions.size} remaining`);
}
setInterval(sweepSessions, 60_000).unref();

const EXEC_TOOL = {
  name: "exec",
  description:
    "Run a shell command on this node (bash -c) and return its stdout, stderr, exit code and timing as a structured result. The response is bound to this call's JSON-RPC request id, so concurrent calls cannot swap outputs.",
  inputSchema: {
    type: "object",
    properties: {
      command: { type: "string", description: "Shell command to run (bash -c). Max 8192 chars." },
      timeout_ms: {
        type: "integer",
        description: "Kill the command after this many ms. Default 30000, max 120000.",
        default: DEFAULT_TIMEOUT_MS,
      },
    },
    required: ["command"],
    additionalProperties: false,
  },
};

// Read-only filesystem tools. Every path argument carries the same rule as the
// official server: "Absolute, or relative to an allowed directory; it must
// resolve inside the allowed directories." No write tools in this version.
const FS_TOOLS = [
  {
    name: "read_text_file",
    description:
      "Read a text file inside the allowed directories (~/workspace, ~/skynight137/toolskit). Returns the file text (optionally only the first/last N lines) plus size and line counts. Refuses files over 1 MB and files containing NUL bytes.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Absolute path, or relative to ~/workspace. Must resolve inside the allowed directories." },
        head: { type: "integer", description: "Return only the first N lines (1..1000)." },
        tail: { type: "integer", description: "Return only the last N lines (1..1000)." },
      },
      required: ["path"],
      additionalProperties: false,
    },
  },
  {
    name: "list_directory",
    description:
      "List a directory inside the allowed directories. Returns entries sorted by name with type and file size.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Absolute path, or relative to ~/workspace. Must resolve inside the allowed directories." },
      },
      required: ["path"],
      additionalProperties: false,
    },
  },
  {
    name: "get_file_info",
    description:
      "Return size, type, permissions, timestamps and link count for a path inside the allowed directories. Symlinks are resolved first, so the info is about the resolved target.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Absolute path, or relative to ~/workspace. Must resolve inside the allowed directories." },
      },
      required: ["path"],
      additionalProperties: false,
    },
  },
  {
    name: "search_files",
    description:
      "Recursively search a directory inside the allowed directories for paths matching a glob. Returns matching paths only, never file content. The glob is matched against the path relative to the search directory and against the file name, so '*.md' finds .md files at any depth. Symlinked directories are never followed.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Directory to search. Absolute, or relative to ~/workspace. Must resolve inside the allowed directories." },
        pattern: { type: "string", description: "Glob, e.g. '*.md', '**/SUMMARY.md', 'server/*.mjs'." },
        excludePatterns: { type: "array", items: { type: "string" }, description: "Optional globs to exclude (matched the same way as pattern)." },
      },
      required: ["path", "pattern"],
      additionalProperties: false,
    },
  },
];
const FS_TOOL_NAMES = new Set(FS_TOOLS.map((t) => t.name));

function nodeIdentity() {
  return {
    hostname: os.hostname(),
    tailscaleIp: process.env.MCP_TAILSCALE_IP || null, // set by the start script when known
    bind: `${HOST}:${PORT}`,
    pid: process.pid,
    version: VERSION,
  };
}

function runExec(requestId, command, timeoutMs) {
  return new Promise((resolve) => {
    const started = Date.now();
    const child = spawn("bash", ["-c", command], { timeout: timeoutMs, killSignal: "SIGTERM" });
    let stdout = "";
    let stderr = "";
    let truncated = false;
    let timedOut = false;
    const cap = (chunk, which) => {
      const s = chunk.toString("utf8");
      if (which === "out") {
        if (stdout.length + s.length > MAX_OUTPUT) {
          stdout += s.slice(0, MAX_OUTPUT - stdout.length);
          truncated = true;
        } else stdout += s;
      } else {
        if (stderr.length + s.length > MAX_OUTPUT) {
          stderr += s.slice(0, MAX_OUTPUT - stderr.length);
          truncated = true;
        } else stderr += s;
      }
    };
    child.stdout.on("data", (c) => cap(c, "out"));
    child.stderr.on("data", (c) => cap(c, "err"));
    const killTimer = setTimeout(() => {
      timedOut = true;
      child.kill("SIGTERM");
      setTimeout(() => { try { child.kill("SIGKILL"); } catch { /* already dead */ } }, 2000);
    }, timeoutMs);
    child.on("error", (err) => {
      clearTimeout(killTimer);
      resolve({ error: `spawn failed: ${err.message}`, timedOut, truncated, durationMs: Date.now() - started });
    });
    child.on("close", (code, signal) => {
      clearTimeout(killTimer);
      const durationMs = Date.now() - started;
      resolve({
        command, stdout, stderr,
        exitCode: code, signal: signal || null,
        durationMs, timedOut, truncated,
      });
    });
  });
}

function jsonRpcResult(id, result) {
  return { jsonrpc: "2.0", id, result };
}
function jsonRpcError(id, code, message) {
  return { jsonrpc: "2.0", id, error: { code, message } };
}

// Race a promise against a timeout (fs calls are fast; the timeout bounds
// pathological walks and slow disks, mirroring the official 15 s fs timeout).
function withTimeout(promise, ms, what) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${what} timed out after ${ms}ms`)), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

function fsFail(tool, pathArg, err, started) {
  logFs({ ts: ts(), tool, path: typeof pathArg === "string" ? pathArg : null, ok: false, error: err.message, durationMs: Date.now() - started });
  return {
    content: [{ type: "text", text: `${tool} failed: ${err.message}` }],
    isError: true,
  };
}

async function fsReadText(args) {
  const started = Date.now();
  try {
    const path = args.path;
    if (typeof path !== "string" || path.trim() === "") throw new Error("arguments.path must be a non-empty string");
    const head = args.head;
    const tail = args.tail;
    if (head !== undefined && (!Number.isInteger(head) || head < 1 || head > FS_MAX_LINES)) throw new Error(`head must be an integer 1..${FS_MAX_LINES}`);
    if (tail !== undefined && (!Number.isInteger(tail) || tail < 1 || tail > FS_MAX_LINES)) throw new Error(`tail must be an integer 1..${FS_MAX_LINES}`);
    if (head !== undefined && tail !== undefined) throw new Error("specify head or tail, not both");
    const resolved = validatePath(path);
    const buf = await withTimeout(readFile(resolved), FS_CALL_TIMEOUT_MS, "read_text_file");
    if (buf.length > FS_MAX_FILE) throw new Error(`file too large (${buf.length} bytes > ${FS_MAX_FILE}); read it via exec in chunks`);
    if (buf.includes(0)) throw new Error("file appears to be binary (contains NUL); refusing text read");
    const text = buf.toString("utf8");
    let lines = text.split("\n");
    if (lines.length && lines[lines.length - 1] === "") lines.pop();
    let selected = lines;
    let truncated = false;
    if (head !== undefined) { selected = lines.slice(0, head); truncated = lines.length > head; }
    else if (tail !== undefined) { selected = lines.slice(-tail); truncated = lines.length > tail; }
    let content = selected.join("\n");
    if (content.length > FS_MAX_READ) { content = content.slice(0, FS_MAX_READ); truncated = true; }
    const result = { path: resolved, size: buf.length, lines: lines.length, returnedLines: selected.length, truncated, content };
    logFs({ ts: ts(), tool: "read_text_file", path: resolved, ok: true, durationMs: Date.now() - started });
    return { content: [{ type: "text", text: content }], structuredContent: result, isError: false };
  } catch (err) {
    return fsFail("read_text_file", args?.path, err, started);
  }
}

async function fsListDirectory(args) {
  const started = Date.now();
  try {
    const path = args.path;
    if (typeof path !== "string" || path.trim() === "") throw new Error("arguments.path must be a non-empty string");
    const resolved = validatePath(path);
    const dirents = await withTimeout(readdir(resolved, { withFileTypes: true }), FS_CALL_TIMEOUT_MS, "list_directory");
    const entries = [];
    for (const d of dirents) {
      let type = "other";
      let size = null;
      if (d.isDirectory()) type = "directory";
      else if (d.isFile()) type = "file";
      else if (d.isSymbolicLink()) type = "symlink";
      if (type === "file") {
        try { size = (await lstat(join(resolved, d.name))).size; } catch { size = null; }
      }
      entries.push({ name: d.name, type, size });
    }
    entries.sort((a, b) => a.name.localeCompare(b.name));
    const result = { path: resolved, entries };
    const text = entries.map((e) =>
      `[${e.type === "directory" ? "DIR" : e.type === "symlink" ? "LINK" : "FILE"}] ${e.name}${e.size !== null ? ` (${e.size} B)` : ""}`).join("\n");
    logFs({ ts: ts(), tool: "list_directory", path: resolved, ok: true, durationMs: Date.now() - started });
    return { content: [{ type: "text", text }], structuredContent: result, isError: false };
  } catch (err) {
    return fsFail("list_directory", args?.path, err, started);
  }
}

async function fsGetFileInfo(args) {
  const started = Date.now();
  try {
    const path = args.path;
    if (typeof path !== "string" || path.trim() === "") throw new Error("arguments.path must be a non-empty string");
    const resolved = validatePath(path);
    const st = await withTimeout(lstat(resolved), FS_CALL_TIMEOUT_MS, "get_file_info");
    const type = st.isDirectory() ? "directory" : st.isFile() ? "file" : st.isSymbolicLink() ? "symlink" : "other";
    const result = {
      path: resolved,
      type,
      size: st.size,
      mode: (st.mode & 0o777).toString(8),
      mtime: st.mtime.toISOString(),
      atime: st.atime.toISOString(),
      birthtime: st.birthtime.toISOString(),
      nlink: st.nlink,
      isSymbolicLink: st.isSymbolicLink(),
    };
    logFs({ ts: ts(), tool: "get_file_info", path: resolved, ok: true, durationMs: Date.now() - started });
    return { content: [{ type: "text", text: JSON.stringify(result) }], structuredContent: result, isError: false };
  } catch (err) {
    return fsFail("get_file_info", args?.path, err, started);
  }
}

// Minimal glob -> RegExp: * (no /), ** (any chars), **/ (optional dirs), ? (one non-/ char).
function globToRegExp(glob) {
  let re = "^";
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === "*") {
      if (glob[i + 1] === "*") {
        if (glob[i + 2] === "/") { re += "(?:.*/)?"; i += 2; }
        else { re += ".*"; i += 1; }
      } else re += "[^/]*";
    } else if (c === "?") re += "[^/]";
    else if ("+.^${}()|[]\\".includes(c)) re += "\\" + c;
    else re += c;
  }
  return new RegExp(re + "$");
}

async function fsSearchFiles(args) {
  const started = Date.now();
  try {
    const path = args.path;
    const pattern = args.pattern;
    if (typeof path !== "string" || path.trim() === "") throw new Error("arguments.path must be a non-empty string");
    if (typeof pattern !== "string" || pattern.trim() === "") throw new Error("arguments.pattern must be a non-empty string");
    const exclude = Array.isArray(args.excludePatterns) ? args.excludePatterns : [];
    for (const g of exclude) if (typeof g !== "string") throw new Error("excludePatterns must be strings");
    const resolved = validatePath(path);
    const st = await withTimeout(lstat(resolved), FS_CALL_TIMEOUT_MS, "search_files");
    if (!st.isDirectory()) throw new Error("path is not a directory");
    const matchRe = globToRegExp(pattern);
    const excludeRes = exclude.map((g) => globToRegExp(g));
    const excluded = (relPath, name) => excludeRes.some((rx) => rx.test(relPath) || rx.test(name));
    const matches = [];
    let walked = 0;
    let walkTruncated = false;
    const deadline = Date.now() + FS_CALL_TIMEOUT_MS;
    async function walk(dir, rel) {
      const dirents = await readdir(dir, { withFileTypes: true });
      for (const d of dirents) {
        if (matches.length >= FS_MAX_MATCHES || walked >= FS_MAX_WALK_ENTRIES) { walkTruncated = true; return; }
        if (Date.now() > deadline) throw new Error(`search timed out after ${FS_CALL_TIMEOUT_MS}ms`);
        walked++;
        const childRel = rel ? `${rel}/${d.name}` : d.name;
        if (d.isDirectory()) {
          if (excluded(childRel, d.name)) continue;
          await walk(join(dir, d.name), childRel);
          if (walkTruncated) return;
        } else {
          if (excluded(childRel, d.name)) continue;
          if (matchRe.test(childRel) || matchRe.test(d.name)) matches.push(childRel);
        }
      }
    }
    await walk(resolved, "");
    const result = { path: resolved, pattern, matches, count: matches.length, walked, truncated: walkTruncated };
    logFs({ ts: ts(), tool: "search_files", path: resolved, ok: true, durationMs: Date.now() - started });
    return { content: [{ type: "text", text: matches.length ? matches.join("\n") : "(no matches)" }], structuredContent: result, isError: false };
  } catch (err) {
    return fsFail("search_files", args?.path, err, started);
  }
}

const FS_HANDLERS = {
  read_text_file: fsReadText,
  list_directory: fsListDirectory,
  get_file_info: fsGetFileInfo,
  search_files: fsSearchFiles,
};

async function handleRpc(req, res, body) {
  sweepSessions();
  let msg;
  try {
    msg = JSON.parse(body);
  } catch {
    res.writeHead(400, { "Content-Type": "application/json" });
    res.end(JSON.stringify(jsonRpcError(null, -32700, "Parse error: body is not valid JSON")));
    return;
  }
  if (!msg || typeof msg !== "object" || msg.jsonrpc !== "2.0" || typeof msg.method !== "string") {
    res.writeHead(400, { "Content-Type": "application/json" });
    res.end(JSON.stringify(jsonRpcError(msg?.id ?? null, -32600, "Invalid Request")));
    return;
  }
  const isNotification = msg.id === undefined || msg.id === null;
  const id = msg.id;

  // Notifications: no response body, 202.
  if (isNotification) {
    if (msg.method === "notifications/initialized") {
      res.writeHead(202);
      res.end();
      return;
    }
    res.writeHead(202);
    res.end();
    return;
  }

  const sessionId = req.headers["mcp-session-id"];

  if (msg.method === "initialize") {
    const proposed = msg.params?.protocolVersion;
    const version = typeof proposed === "string" && PROTOCOLS.has(proposed) ? proposed : "2025-03-26";
    const sid = randomUUID();
    sessions.set(sid, { createdAt: Date.now(), lastSeen: Date.now() });
    res.writeHead(200, {
      "Content-Type": "application/json",
      "Mcp-Session-Id": sid,
    });
    res.end(JSON.stringify(jsonRpcResult(id, {
      protocolVersion: version,
      capabilities: { tools: {} },
      serverInfo: { name: "repl-mcp", version: VERSION },
    })));
    logServer(`initialize id=${id} protocol=${version} session=${sid.slice(0, 8)}`);
    return;
  }

  // Every other request needs a known session.
  if (!sessionId || !sessions.has(sessionId)) {
    res.writeHead(404, { "Content-Type": "application/json" });
    res.end(JSON.stringify(jsonRpcError(id, -32001, "Unknown or missing Mcp-Session-Id; initialize first")));
    return;
  }
  sessions.get(sessionId).lastSeen = Date.now();

  // The spec (2025-06-18+) says the server SHOULD validate the protocol
  // version header and answer 400 for an unsupported version. A missing
  // header is allowed (the SDK only rejects a present-but-unsupported one).
  const pv = req.headers["mcp-protocol-version"];
  if (typeof pv === "string" && !PROTOCOLS.has(pv)) {
    res.writeHead(400, { "Content-Type": "application/json" });
    res.end(JSON.stringify(jsonRpcError(id, -32000, `Unsupported MCP-Protocol-Version: ${pv}`)));
    return;
  }

  if (msg.method === "ping") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify(jsonRpcResult(id, {})));
    return;
  }

  if (msg.method === "tools/list") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify(jsonRpcResult(id, { tools: [EXEC_TOOL, ...FS_TOOLS] })));
    return;
  }

  if (msg.method === "tools/call") {
    const name = msg.params?.name;
    const args = msg.params?.arguments;

    if (FS_TOOL_NAMES.has(name)) {
      if (!args || typeof args !== "object" || Array.isArray(args)) {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify(jsonRpcResult(id, {
          content: [{ type: "text", text: `${name} failed: arguments must be a JSON object` }],
          isError: true,
        })));
        return;
      }
      const out = await FS_HANDLERS[name](args);
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify(jsonRpcResult(id, out)));
      return;
    }

    if (name !== "exec") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify(jsonRpcError(id, -32602, `Unknown tool: ${String(name)}`)));
      return;
    }
    if (!args || typeof args.command !== "string" || args.command.trim() === "") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify(jsonRpcResult(id, {
        content: [{ type: "text", text: "exec failed: arguments.command must be a non-empty string" }],
        isError: true,
      })));
      return;
    }
    if (args.command.length > MAX_CMD_LEN) {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify(jsonRpcResult(id, {
        content: [{ type: "text", text: `exec failed: command exceeds ${MAX_CMD_LEN} chars` }],
        isError: true,
      })));
      return;
    }
    let timeoutMs = DEFAULT_TIMEOUT_MS;
    if (args.timeout_ms !== undefined) {
      if (!Number.isInteger(args.timeout_ms) || args.timeout_ms < 100 || args.timeout_ms > MAX_TIMEOUT_MS) {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify(jsonRpcResult(id, {
          content: [{ type: "text", text: `exec failed: timeout_ms must be an integer 100..${MAX_TIMEOUT_MS}` }],
          isError: true,
        })));
        return;
      }
      timeoutMs = args.timeout_ms;
    }
    if (runningExecs >= MAX_CONCURRENT) {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify(jsonRpcError(id, -32000, `Too many concurrent executions (${MAX_CONCURRENT}); retry later`)));
      return;
    }
    runningExecs++;
    const started = Date.now();
    try {
      const out = await runExec(id, args.command, timeoutMs);
      const isToolError = out.error !== undefined || out.timedOut;
      const result = {
        requestId: id,
        node: nodeIdentity(),
        command: args.command,
        stdout: out.stdout ?? "",
        stderr: out.stderr ?? "",
        exitCode: out.exitCode ?? null,
        signal: out.signal ?? null,
        durationMs: out.durationMs,
        timedOut: out.timedOut,
        truncated: out.truncated,
        ...(out.error ? { error: out.error } : {}),
      };
      logExec({
        ts: ts(), requestId: id, command: args.command.slice(0, 500),
        exitCode: result.exitCode, durationMs: result.durationMs,
        timedOut: result.timedOut, truncated: result.truncated,
      });
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify(jsonRpcResult(id, {
        content: [{ type: "text", text: JSON.stringify(result) }],
        structuredContent: result,
        isError: isToolError,
      })));
      logServer(`exec id=${id} rc=${result.exitCode} ${result.durationMs}ms timedOut=${result.timedOut} (${Date.now() - started}ms wall)`);
    } finally {
      runningExecs--;
    }
    return;
  }

  res.writeHead(200, { "Content-Type": "application/json" });
  res.end(JSON.stringify(jsonRpcError(id, -32601, `Method not found: ${msg.method}`)));
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url || "/", `http://${req.headers.host || "127.0.0.1"}`);
  if (req.method === "GET" && url.pathname === "/health") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ status: "ok", node: nodeIdentity(), sessions: sessions.size, uptimeSec: Math.floor(process.uptime()) }));
    return;
  }
  if (url.pathname !== "/mcp") {
    res.writeHead(404, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "not found" }));
    return;
  }
  if (req.method === "GET") {
    // No server-initiated messages; SSE stream not offered.
    res.writeHead(405, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "GET /mcp not supported; use POST" }));
    return;
  }
  if (req.method === "DELETE") {
    const sid = req.headers["mcp-session-id"];
    if (!sid) {
      res.writeHead(400, { "Content-Type": "application/json" });
      res.end(JSON.stringify(jsonRpcError(null, -32000, "DELETE requires Mcp-Session-Id")));
      return;
    }
    if (!sessions.has(sid)) {
      res.writeHead(404, { "Content-Type": "application/json" });
      res.end(JSON.stringify(jsonRpcError(null, -32001, "Unknown Mcp-Session-Id")));
      return;
    }
    sessions.delete(sid);
    res.writeHead(204);
    res.end();
    logServer(`session closed ${sid.slice(0, 8)}, ${sessions.size} remaining`);
    return;
  }
  if (req.method !== "POST") {
    res.writeHead(405, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "method not allowed" }));
    return;
  }
  const chunks = [];
  let size = 0;
  let tooBig = false;
  req.on("data", (c) => {
    size += c.length;
    if (size > MAX_BODY) { tooBig = true; return; }
    chunks.push(c);
  });
  req.on("end", () => {
    if (tooBig) {
      res.writeHead(413, { "Content-Type": "application/json" });
      res.end(JSON.stringify(jsonRpcError(null, -32600, "Request body exceeds 1 MB")));
      return;
    }
    handleRpc(req, res, Buffer.concat(chunks).toString("utf8")).catch((err) => {
      logServer(`handler error: ${err?.message || err}`);
      if (!res.headersSent) {
        res.writeHead(500, { "Content-Type": "application/json" });
        res.end(JSON.stringify(jsonRpcError(null, -32603, "Internal error")));
      }
    });
  });
});

server.listen(PORT, HOST, () => {
  logServer(`repl-mcp ${VERSION} listening on ${HOST}:${PORT} pid=${process.pid} node=${os.hostname()} sessionIdleMs=${SESSION_IDLE_MS} fsRoots=${FS_ROOTS.map((r) => r.resolved).join(",")}`);
});

process.on("SIGTERM", () => {
  logServer("SIGTERM, shutting down");
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 3000).unref();
});
process.on("SIGINT", () => {
  logServer("SIGINT, shutting down");
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 3000).unref();
});
