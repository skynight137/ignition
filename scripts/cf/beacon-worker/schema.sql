CREATE TABLE IF NOT EXISTS beacons (
  node TEXT PRIMARY KEY,
  ignition TEXT,
  ts TEXT,
  uptime_s INTEGER,
  tour_alive INTEGER,
  camofox_ok INTEGER,
  disk_pct INTEGER,
  last_verdict TEXT,
  received_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_beacons_received ON beacons(received_at);
