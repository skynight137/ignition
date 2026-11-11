#!/usr/bin/env node
/**
 * llm-wiki server: one Node.js process (stdlib only, no npm install) that
 *   - serves the Model Context Protocol over Streamable HTTP at  POST /mcp
 *   - reverse-proxies the desktop app's REST API (everything else) so the same
 *     public port serves both agents (MCP) and scripts (curl).
 *
 * Env (all optional):
 *   LLM_WIKI_PORT           listen port                     (default 8080)
 *   LLM_WIKI_BIND_HOST      bind address                    (default 0.0.0.0)
 *   LLM_WIKI_UPSTREAM       app API base, no /api/v1 suffix (default http://127.0.0.1:19828)
 *   LLM_WIKI_CLIP_UPSTREAM  clip server base                (default http://127.0.0.1:19827)
 *   LLM_WIKI_API_TOKEN      shared token; requests from non-loopback clients must present it
 *   LLM_WIKI_PROJECT        project root used by llm_wiki_set_project
 *
 * Auth rule (public instance): every request must present the shared token.
 *   `Authorization: Bearer <token>` or `x-llm-wiki-token: <token>`.
 * A loopback-only instance may set LLM_WIKI_TRUST_LOOPBACK=1 to skip the token for
 * same-machine clients; that flag is refused on a non-loopback bind.
 */
'use strict';

const http = require('http');
const net = require('net');

const PORT = Number(process.env.LLM_WIKI_PORT || 8080);
const BIND = process.env.LLM_WIKI_BIND_HOST || '0.0.0.0';
const UPSTREAM = (process.env.LLM_WIKI_UPSTREAM || 'http://127.0.0.1:19828').replace(/\/+$/, '');
const CLIP = (process.env.LLM_WIKI_CLIP_UPSTREAM || 'http://127.0.0.1:19827').replace(/\/+$/, '');
const TOKEN = (process.env.LLM_WIKI_API_TOKEN || '').trim();
// Optional second, read-only token: same header, but only read tools / GETs.
// One is enough (a shared "guest" key), and it keeps the full token out of
// clients that only need to read the wiki.
const READONLY_TOKEN = (process.env.LLM_WIKI_READONLY_TOKEN || '').trim();
const READ_ONLY_TOOLS = new Set([
  'llm_wiki_status',
  'llm_wiki_projects',
  'llm_wiki_files',
  'llm_wiki_read_file',
  'llm_wiki_search',
  'llm_wiki_graph',
  'llm_wiki_reviews',
]);
const TRUST_LOOPBACK = process.env.LLM_WIKI_TRUST_LOOPBACK === '1';
const DEFAULT_PROJECT = process.env.LLM_WIKI_PROJECT || process.cwd();
const PROTOCOL_VERSION = '2025-06-18';

const isLoopback = (addr) =>
  addr === '127.0.0.1' || addr === '::1' || addr === '::ffff:127.0.0.1' || addr.startsWith('127.');

const BIND_IS_LOOPBACK = ['127.0.0.1', '::1', 'localhost'].includes(BIND);
if (TRUST_LOOPBACK && !BIND_IS_LOOPBACK) {
  console.error(`refusing LLM_WIKI_TRUST_LOOPBACK=1 on bind ${BIND}: it would expose an unauthenticated endpoint`);
  process.exit(1);
}

function presentedToken(req) {
  const h = req.headers['x-llm-wiki-token'];
  if (typeof h === 'string' && h.trim()) return h.trim();
  const a = req.headers['authorization'];
  if (typeof a === 'string' && a.startsWith('Bearer ')) return a.slice(7).trim();
  return '';
}

function authorized(req) {
  const fromLoopback = isLoopback(req.socket.remoteAddress || '');
  if (fromLoopback && (TRUST_LOOPBACK || !TOKEN)) return true;
  if (!TOKEN) return false;
  return presentedToken(req) === TOKEN;
}

/** 'full' (write allowed) | 'ro' (read-only token) | null (reject). */
function authMode(req) {
  const fromLoopback = isLoopback(req.socket.remoteAddress || '');
  if (fromLoopback && (TRUST_LOOPBACK || !TOKEN)) return 'full';
  if (!TOKEN) return null;
  const presented = presentedToken(req);
  if (presented === TOKEN) return 'full';
  if (READONLY_TOKEN && presented === READONLY_TOKEN) return 'ro';
  return null;
}

// Reads are allowed for the read-only token: GET/HEAD everywhere, plus the two
// POST endpoints that only query (search, graph). Everything else is denied.
function readOnlyRestAllowed(method, path) {
  if (method === 'GET' || method === 'HEAD') return true;
  if (method !== 'POST') return false;
  return /\/api\/v1\/projects\/[^/]+\/(search|graph)$/.test(path);
}

/** Minimal HTTP client returning {status, headers, body(Buffer)}. */
function request(url, { method = 'GET', headers = {}, body = null, timeout = 600000 } = {}) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const req = http.request(
      {
        hostname: u.hostname,
        port: u.port || 80,
        path: u.pathname + u.search,
        method,
        headers,
        timeout,
      },
      (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => resolve({ status: res.statusCode || 0, headers: res.headers, body: Buffer.concat(chunks) }));
      }
    );
    req.on('timeout', () => req.destroy(new Error('upstream timeout')));
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

async function api(method, path, jsonBody) {
  const headers = { Accept: 'application/json' };
  if (TOKEN) headers['x-llm-wiki-token'] = TOKEN;
  let body = null;
  if (jsonBody !== undefined) {
    body = Buffer.from(JSON.stringify(jsonBody));
    headers['Content-Type'] = 'application/json';
    headers['Content-Length'] = String(body.length);
  }
  const res = await request(`${UPSTREAM}${path}`, { method, headers, body });
  const text = res.body.toString('utf8');
  let parsed = null;
  try {
    parsed = text ? JSON.parse(text) : null;
  } catch {
    parsed = null;
  }
  if (res.status >= 400) {
    const msg = parsed && parsed.error ? parsed.error : text.slice(0, 200) || `HTTP ${res.status}`;
    throw new Error(`LLM Wiki API ${res.status}: ${msg}`);
  }
  return parsed === null ? text : parsed;
}

const q = (o) => new URLSearchParams(o).toString();

/* ---------------------------------------------------------------- MCP tools */

const TOOLS = [
  {
    name: 'llm_wiki_status',
    description: 'Check whether the LLM Wiki API is reachable and which project is active.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
    handler: async () => {
      const health = await api('GET', '/api/v1/health');
      const projects = await api('GET', '/api/v1/projects');
      return { health, currentProject: projects.currentProject ?? null, projects: projects.projects ?? [] };
    },
  },
  {
    name: 'llm_wiki_projects',
    description: 'List known LLM Wiki projects and the current one.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
    handler: () => api('GET', '/api/v1/projects'),
  },
  {
    name: 'llm_wiki_set_project',
    description: 'Pin this session to a project directory. Use the absolute path of the project root.',
    inputSchema: {
      type: 'object',
      properties: { path: { type: 'string', description: 'Absolute project root, e.g. /srv/wiki' } },
      required: ['path'],
      additionalProperties: false,
    },
    handler: async ({ path }) => {
      const body = Buffer.from(JSON.stringify({ path: path || DEFAULT_PROJECT }));
      const res = await request(`${CLIP}/project`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Content-Length': String(body.length) },
        body,
      });
      if (res.status >= 400) throw new Error(`clip server ${res.status}: ${res.body.toString('utf8').slice(0, 200)}`);
      return api('GET', '/api/v1/projects');
    },
  },
  {
    name: 'llm_wiki_files',
    description: 'List files of a project (root: wiki | sources | all).',
    inputSchema: {
      type: 'object',
      properties: {
        project: { type: 'string', description: 'Project id or "current" (default)' },
        root: { type: 'string', enum: ['wiki', 'sources', 'all'] },
        recursive: { type: 'boolean' },
      },
      additionalProperties: false,
    },
    handler: ({ project = 'current', root, recursive }) =>
      api('GET', `/api/v1/projects/${encodeURIComponent(project)}/files?${q({
        ...(root ? { root } : {}),
        ...(recursive === undefined ? {} : { recursive: String(recursive) }),
      })}`),
  },
  {
    name: 'llm_wiki_read_file',
    description: 'Read a text file from a project (e.g. wiki/queries/note.md).',
    inputSchema: {
      type: 'object',
      properties: {
        path: { type: 'string' },
        project: { type: 'string', description: 'Project id or "current" (default)' },
      },
      required: ['path'],
      additionalProperties: false,
    },
    handler: ({ path, project = 'current' }) =>
      api('GET', `/api/v1/projects/${encodeURIComponent(project)}/files/content?${q({ path })}`),
  },
  {
    name: 'llm_wiki_write_page',
    description:
      'Create or overwrite a Markdown page under wiki/ of the project. Existing files need allowOverwrite=true.',
    inputSchema: {
      type: 'object',
      properties: {
        path: { type: 'string', description: 'Project-relative path, must be wiki/**.md' },
        content: { type: 'string' },
        allowOverwrite: { type: 'boolean' },
        project: { type: 'string' },
      },
      required: ['path', 'content'],
      additionalProperties: false,
    },
    handler: ({ path, content, allowOverwrite = false, project = 'current' }) =>
      api('POST', `/api/v1/projects/${encodeURIComponent(project)}/pages/write`, {
        path,
        content,
        allowOverwrite,
      }),
  },
  {
    name: 'llm_wiki_search',
    description: 'Search a project (keyword + vector + knowledge-graph candidates).',
    inputSchema: {
      type: 'object',
      properties: { query: { type: 'string' }, project: { type: 'string' }, limit: { type: 'number' } },
      required: ['query'],
      additionalProperties: false,
    },
    handler: ({ query, project = 'current', limit }) =>
      api('POST', `/api/v1/projects/${encodeURIComponent(project)}/search`, {
        query,
        ...(limit === undefined ? {} : { limit }),
      }),
  },
  {
    name: 'llm_wiki_graph',
    description: 'Query the project knowledge graph.',
    inputSchema: {
      type: 'object',
      properties: { project: { type: 'string' }, query: { type: 'string' } },
      additionalProperties: false,
    },
    handler: ({ project = 'current', query }) =>
      api('GET', `/api/v1/projects/${encodeURIComponent(project)}/graph${query ? `?${q({ query })}` : ''}`),
  },
  {
    name: 'llm_wiki_rescan_sources',
    description: 'Trigger a rescan of the project sources folder.',
    inputSchema: {
      type: 'object',
      properties: { project: { type: 'string' } },
      additionalProperties: false,
    },
    handler: ({ project = 'current' }) =>
      api('POST', `/api/v1/projects/${encodeURIComponent(project)}/sources/rescan`),
  },
  {
    name: 'llm_wiki_embed_page',
    description: 'Create or replace the vector index for one existing Markdown page.',
    inputSchema: {
      type: 'object',
      properties: { path: { type: 'string' }, project: { type: 'string' } },
      required: ['path'],
      additionalProperties: false,
    },
    handler: ({ path, project = 'current' }) =>
      api('POST', `/api/v1/projects/${encodeURIComponent(project)}/pages/embed`, { path }),
  },
  {
    name: 'llm_wiki_reviews',
    description: 'List review items of a project (defaults to unresolved).',
    inputSchema: {
      type: 'object',
      properties: { project: { type: 'string' }, status: { type: 'string' } },
      additionalProperties: false,
    },
    handler: ({ project = 'current', status }) =>
      api('GET', `/api/v1/projects/${encodeURIComponent(project)}/reviews${status ? `?${q({ status })}` : ''}`),
  },
  {
    name: 'llm_wiki_chat',
    description: 'Ask the LLM Wiki backend agent a question about the project.',
    inputSchema: {
      type: 'object',
      properties: { message: { type: 'string' }, project: { type: 'string' }, sessionId: { type: 'string' } },
      required: ['message'],
      additionalProperties: false,
    },
    handler: ({ message, project = 'current', sessionId }) =>
      api('POST', `/api/v1/projects/${encodeURIComponent(project)}/chat`, {
        message,
        ...(sessionId ? { sessionId } : {}),
      }),
  },
];

const toolByName = new Map(TOOLS.map((t) => [t.name, t]));

async function handleRpc(msg, opts = {}) {
  const { id, method, params } = msg || {};
  const reply = (result) => ({ jsonrpc: '2.0', id, result });
  const failure = (code, message) => ({ jsonrpc: '2.0', id, error: { code, message } });

  switch (method) {
    case 'initialize':
      return reply({
        protocolVersion: (params && params.protocolVersion) || PROTOCOL_VERSION,
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: 'llm-wiki', version: '1.0.0' },
        instructions:
          'Shared knowledge base. Read first: wiki/index.md, wiki/SCHEMA.md. Write lessons under wiki/**.md; raw sources stay in raw/sources/.',
      });
    case 'notifications/initialized':
    case 'notifications/cancelled':
      return null;
    case 'ping':
      return reply({});
    case 'tools/list':
      return reply({
        tools: TOOLS.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })),
      });
    case 'tools/call': {
      const name = params && params.name;
      const args = (params  && params.arguments) || {};
      if (opts.readOnly && !READ_ONLY_TOOLS.has(name)) {
        return failure(-32003, `Read-only token: tool '${name}' is not allowed (write/act tools need the full token)`);
      }
      const tool = toolByName.get(name);
      if (!tool) return failure(-32602, `Unknown tool: ${name}`);
      try {
        const result = await tool.handler(args);
        const text = typeof result === 'string' ? result : JSON.stringify(result, null, 2);
        return reply({ content: [{ type: 'text', text }], isError: false });
      } catch (err) {
        return reply({ content: [{ type: 'text', text: `MCP error: ${err.message}` }], isError: true });
      }
    }
    default:
      return failure(-32601, `Method not found: ${method}`);
  }
}

/* ------------------------------------------------------------------ HTTP glue */

function sendJson(res, status, payload) {
  const body = Buffer.from(JSON.stringify(payload));
  res.writeHead(status, {
    'Content-Type': 'application/json',
    'Content-Length': body.length,
    'Access-Control-Allow-Origin': '*',
  });
  res.end(body);
}

function readBody(req, limit = 32 * 1024 * 1024) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > limit) {
        reject(new Error('body too large'));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

async function serveMcp(req, res, pathPrefix, opts = {}) {
  if (req.method === 'GET' || req.method === 'DELETE') {
    // The streamable transport allows a GET/event-stream channel; this server is
    // request/response only, and MCP clients treat 405 as "no server push".
    res.writeHead(405, { Allow: 'POST', 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ jsonrpc: '2.0', error: { code: -32000, message: 'POST only' }, id: null }));
    return;
  }
  if (req.method !== 'POST') {
    sendJson(res, 405, { jsonrpc: '2.0', error: { code: -32000, message: 'POST only' }, id: null });
    return;
  }
  await pathPrefix;
  let payload;
  try {
    payload = JSON.parse((await readBody(req)).toString('utf8') || 'null');
  } catch (err) {
    sendJson(res, 400, { jsonrpc: '2.0', error: { code: -32700, message: `Parse error: ${err.message}` }, id: null });
    return;
  }
  const batch = Array.isArray(payload);
  const messages = batch ? payload : [payload];
  const out = [];
  for (const m of messages) {
    const r = await handleRpc(m, opts);
    if (r !== null) out.push(r);
  }
  if (out.length === 0) {
    res.writeHead(202, { 'Content-Length': 0 });
    res.end();
    return;
  }
  sendJson(res, 200, batch ? out : out[0]);
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const path = url.pathname;

  if (path === '/' && req.method === 'GET') {
    const body = Buffer.from(
      [
        'llm-wiki server',
        '',
        `MCP (streamable HTTP): POST /mcp   [Authorization: Bearer <token> when not on loopback]`,
        `REST passthrough:      ${UPSTREAM}/api/v1/...  (same auth)`,
        '',
        'Read me first: wiki/index.md and wiki/SCHEMA.md',
        '',
      ].join('\n')
    );
    res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8', 'Content-Length': body.length });
    res.end(body);
    return;
  }

  if (path === '/health') {
    try {
      const up = await api('GET', '/api/v1/health');
      sendJson(res, 200, { ok: true, server: 'llm-wiki', upstream: UPSTREAM, upstreamHealth: up, protocolVersion: PROTOCOL_VERSION });
    } catch (err) {
      sendJson(res, 503, { ok: false, server: 'llm-wiki', upstream: UPSTREAM, error: err.message });
    }
    return;
  }

  if (path === '/mcp' || path === '/mcp/') {
    const mode = authMode(req);
    if (!mode) {
      sendJson(res, 401, { jsonrpc: '2.0', error: { code: -32001, message: 'Unauthorized' }, id: null });
      return;
    }
    await serveMcp(req, res, Promise.resolve(), { readOnly: mode === 'ro' });
    return;
  }

  // Everything else: transparent REST passthrough to the desktop app.
  const restMode = authMode(req);
  if (!restMode) {
    sendJson(res, 401, { error: 'Unauthorized' });
    return;
  }
  if (restMode === 'ro' && !readOnlyRestAllowed(req.method, path)) {
    sendJson(res, 403, { error: 'Read-only token: this endpoint needs the full token' });
    return;
  }
  try {
    const body = await readBody(req);
    const headers = {};
    for (const [k, v] of Object.entries(req.headers)) {
      if (['host', 'connection', 'content-length', 'accept-encoding'].includes(k)) continue;
      headers[k] = v;
    }
    if (TOKEN) headers['x-llm-wiki-token'] = TOKEN;
    if (body.length) {
      headers['content-length'] = String(body.length);
      headers['content-type'] = req.headers['content-type'] || 'application/json';
    }
    const upstreamRes = await request(`${UPSTREAM}${path}${url.search}`, {
      method: req.method,
      headers,
      body: body.length ? body : null,
    });
    const outHeaders = {};
    for (const [k, v] of Object.entries(upstreamRes.headers)) {
      if (['connection', 'content-length', 'transfer-encoding'].includes(k.toLowerCase())) continue;
      outHeaders[k] = v;
    }
    outHeaders['content-length'] = String(upstreamRes.body.length);
    outHeaders['access-control-allow-origin'] = '*';
    res.writeHead(upstreamRes.status, outHeaders);
    res.end(upstreamRes.body);
  } catch (err) {
    sendJson(res, 502, { error: `upstream error: ${err.message}` });
  }
});

server.listen(PORT, BIND, async () => {
  console.error(`llm-wiki server on ${BIND}:${PORT} -> upstream ${UPSTREAM} (mcp at /mcp, token ${TOKEN ? 'set' : 'unset'})`);
  try {
    await api('GET', '/api/v1/health');
    console.error('upstream API reachable');
  } catch (err) {
    console.error(`upstream API not reachable yet: ${err.message}`);
  }
});

for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => {
    server.close(() => process.exit(0));
  });
}
