#!/usr/bin/env node
// repl-mcp-server.mjs — per-node MCP server (Streamable HTTP) for remote command execution.
// Zero dependencies. Runs on ONE fleet node; Muse connects directly to it over the tailnet.
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
// Pilot: repl-110, port 16810. Port choice: not in the .replit platform port table
// (80, 3000, 3001, 3002, 3003, 4200, 5000, 5173, 6000, 6800, 8000, 8008, 8080, 8099,
// 9000) so the platform leaves it alone; distinct from the old forwarder range 16802-16804.
//
// Usage: node repl-mcp-server.mjs [--port 16810] [--host 127.0.0.1]
// Logs: exec.log (one line per execution) and server.log (startup/errors) in the
// same directory as this file, under logs/.

import http from "node:http";
import { spawn } from "node:child_process";
import { appendFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";
import os from "node:os";

const VERSION = "0.1.0-pilot";
const DEFAULT_PORT = 16810;
const DEFAULT_HOST = "127.0.0.1";
const PROTOCOLS = new Set(["2025-11-25", "2025-06-18", "2025-03-26"]);
const MAX_BODY = 1_048_576; // 1 MB request body cap
const MAX_CMD_LEN = 8192;
const MAX_OUTPUT = 1_048_576; // 1 MB per stream cap
const MAX_TIMEOUT_MS = 120_000;
const DEFAULT_TIMEOUT_MS = 30_000;
const MAX_CONCURRENT = 4;

const HERE = dirname(fileURLToPath(import.meta.url));
const LOG_DIR = join(HERE, "logs");
mkdirSync(LOG_DIR, { recursive: true });
const EXEC_LOG = join(LOG_DIR, "exec.log");
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

const sessions = new Map(); // sessionId -> { createdAt }
let runningExecs = 0;

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

async function handleRpc(req, res, body) {
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
    sessions.set(sid, { createdAt: Date.now() });
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
    res.end(JSON.stringify(jsonRpcError(id, -32000, "Unknown or missing Mcp-Session-Id; initialize first")));
    return;
  }

  if (msg.method === "ping") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify(jsonRpcResult(id, {})));
    return;
  }

  if (msg.method === "tools/list") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify(jsonRpcResult(id, { tools: [EXEC_TOOL] })));
    return;
  }

  if (msg.method === "tools/call") {
    const name = msg.params?.name;
    const args = msg.params?.arguments;
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
    res.end(JSON.stringify({ status: "ok", node: nodeIdentity(), uptimeSec: Math.floor(process.uptime()) }));
    return;
  }
  if (url.pathname !== "/mcp") {
    res.writeHead(404, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "not found" }));
    return;
  }
  if (req.method === "GET") {
    // No server-initiated messages in the pilot; SSE stream not offered.
    res.writeHead(405, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "GET /mcp not supported; use POST" }));
    return;
  }
  if (req.method === "DELETE") {
    const sid = req.headers["mcp-session-id"];
    if (sid) sessions.delete(sid);
    res.writeHead(204);
    res.end();
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
      res.end(JSON.stringify(jsonRpcError(null, -32700, "Request body exceeds 1 MB")));
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
  logServer(`repl-mcp ${VERSION} listening on ${HOST}:${PORT} pid=${process.pid} node=${os.hostname()}`);
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
