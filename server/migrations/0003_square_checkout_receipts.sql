CREATE TABLE square_tokens (
  environment TEXT PRIMARY KEY,
  application_id TEXT NOT NULL,
  merchant_id TEXT NOT NULL,
  location_id TEXT,
  access_token TEXT NOT NULL,
  refresh_token TEXT,
  expires_at INTEGER,
  scopes TEXT NOT NULL,
  obtained_at INTEGER NOT NULL,
  refreshed_at INTEGER NOT NULL,
  refresh_attempted_at INTEGER,
  refresh_error TEXT
);

CREATE TABLE oauth_states (
  state TEXT PRIMARY KEY,
  environment TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  used_at INTEGER,
  created_by TEXT
) WITHOUT ROWID;

CREATE INDEX oauth_states_created ON oauth_states (created_at);

CREATE TABLE square_cache (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  fetched_at INTEGER NOT NULL
) WITHOUT ROWID;

CREATE TABLE checkouts (
  id TEXT PRIMARY KEY,
  device TEXT NOT NULL,
  request_hash TEXT NOT NULL,
  receipt_token TEXT,
  order_number INTEGER,
  customer_name TEXT,
  environment TEXT NOT NULL,
  location_id TEXT NOT NULL,
  square_order_id TEXT NOT NULL,
  total_cents INTEGER NOT NULL,
  tax_cents INTEGER NOT NULL,
  expected_cents INTEGER NOT NULL,
  used_catalog INTEGER NOT NULL,
  items TEXT NOT NULL,
  response TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE UNIQUE INDEX checkouts_receipt_token ON checkouts (receipt_token) WHERE receipt_token IS NOT NULL;
CREATE INDEX checkouts_created ON checkouts (created_at);
CREATE INDEX checkouts_square_order ON checkouts (square_order_id);

ALTER TABLE orders ADD COLUMN receipt_token TEXT;
ALTER TABLE orders ADD COLUMN status TEXT NOT NULL DEFAULT 'paid';
ALTER TABLE orders ADD COLUMN status_at INTEGER;
ALTER TABLE orders ADD COLUMN status_by TEXT;

CREATE UNIQUE INDEX orders_receipt_token ON orders (receipt_token) WHERE receipt_token IS NOT NULL;
CREATE INDEX orders_status ON orders (status, paid_at);
