CREATE TABLE admin_events (
  id TEXT PRIMARY KEY,
  at INTEGER NOT NULL,
  action TEXT NOT NULL,
  by TEXT,
  detail TEXT
);

CREATE INDEX admin_events_at ON admin_events (at);
CREATE INDEX logs_device_ts ON logs (device, ts);
