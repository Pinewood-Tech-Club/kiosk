CREATE TABLE giftcard_donations (
  idempotency_key TEXT PRIMARY KEY,
  gan_last4 TEXT NOT NULL,
  variation_id TEXT NOT NULL,
  org_name TEXT NOT NULL,
  amount_cents INTEGER NOT NULL,
  status TEXT NOT NULL,
  order_id TEXT,
  payment_id TEXT,
  balance_after_cents INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
