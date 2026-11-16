// fleet-beacon — Cloudflare Worker: fleet liveness sink (Beacon-to-CF).
// Nodes POST their beacon JSON directly here (no muse-hop in the path).
// Stores the latest beacon per node in D1 (free tier: 100k rows/day;
// 131 nodes x 288/day ~37k writes/day fits; KV free 1k/day does not).
//
// POST /beacon  {node, ignition, ts, uptime_s, tour_alive, camofox_ok,
//                 disk_pct, last_verdict, backlog?} -> {"ok":true}
// GET  /report  -> {"generated_at", "nodes": [latest beacon per node]}
// GET  /health  -> {"ok":true}
//
// D1 binding: DB (database fleet-beacons). Schema: schema.sql.
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/health") {
      return json({ ok: true });
    }
    if (request.method === "GET" && url.pathname === "/report") {
      const { results } = await env.DB.prepare(
        "SELECT node, ignition, ts, uptime_s, tour_alive, camofox_ok, disk_pct, last_verdict, received_at FROM beacons ORDER BY node"
      ).all();
      return json({ generated_at: new Date().toISOString(), nodes: results || [] });
    }
    if (request.method === "POST" && (url.pathname === "/beacon" || url.pathname.startsWith("/beacon/"))) {
      let b;
      try { b = await request.json(); } catch { return json({ ok: false, error: "bad json" }, 400); }
      if (!b || typeof b.node !== "string" || !b.node) {
        return json({ ok: false, error: "node required" }, 400);
      }
      const received = new Date().toISOString();
      await env.DB.prepare(
        `INSERT INTO beacons (node, ignition, ts, uptime_s, tour_alive, camofox_ok, disk_pct, last_verdict, received_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
         ON CONFLICT(node) DO UPDATE SET
           ignition=excluded.ignition, ts=excluded.ts, uptime_s=excluded.uptime_s,
           tour_alive=excluded.tour_alive, camofox_ok=excluded.camofox_ok,
           disk_pct=excluded.disk_pct, last_verdict=excluded.last_verdict,
           received_at=excluded.received_at`
      ).bind(
        b.node,
        str(b.ignition), str(b.ts),
        num(b.uptime_s), bool(b.tour_alive), bool(b.camofox_ok), num(b.disk_pct),
        str(b.last_verdict), received
      ).run();
      return json({ ok: true });
    }
    return json({ ok: false, error: "not found" }, 404);
  },
};

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json" },
  });
}
function str(v) { return typeof v === "string" ? v.slice(0, 500) : ""; }
function num(v) { const n = Number(v); return Number.isFinite(n) ? Math.trunc(n) : 0; }
function bool(v) { return v === true || v === 1 || v === "true" ? 1 : 0; }
