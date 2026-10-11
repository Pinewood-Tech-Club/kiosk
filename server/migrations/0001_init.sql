CREATE TABLE logs (
  id TEXT PRIMARY KEY,
  device TEXT NOT NULL,
  app_version TEXT,
  ts INTEGER NOT NULL,
  level TEXT NOT NULL CHECK (level IN ('debug', 'info', 'warn', 'error')),
  message TEXT NOT NULL,
  context TEXT,
  received_at INTEGER NOT NULL
) WITHOUT ROWID;

CREATE INDEX logs_ts ON logs (ts);
CREATE INDEX logs_level_ts ON logs (level, ts);

CREATE TABLE orders (
  id TEXT PRIMARY KEY,
  order_number INTEGER,
  square_order_id TEXT,
  square_payment_id TEXT,
  customer_name TEXT,
  total_cents INTEGER NOT NULL,
  subtotal_cents INTEGER,
  tax_cents INTEGER,
  card TEXT,
  simulated INTEGER NOT NULL DEFAULT 0,
  items TEXT NOT NULL,
  lines TEXT,
  paid_at INTEGER NOT NULL,
  device TEXT,
  app_version TEXT,
  received_at INTEGER NOT NULL
);

CREATE INDEX orders_paid_at ON orders (paid_at);
CREATE INDEX orders_square_order ON orders (square_order_id);
