CREATE TABLE giftcard_payments (
  payment_id TEXT PRIMARY KEY,
  checkout_id TEXT NOT NULL,
  device TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  gan_last4 TEXT NOT NULL,
  approved_cents INTEGER NOT NULL,
  status TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
) WITHOUT ROWID;

CREATE UNIQUE INDEX giftcard_payments_idempotency ON giftcard_payments (idempotency_key);
CREATE INDEX giftcard_payments_checkout ON giftcard_payments (checkout_id);
CREATE INDEX giftcard_payments_status ON giftcard_payments (status, created_at);

CREATE TABLE giftcard_lookup_failures (
  device TEXT NOT NULL,
  at INTEGER NOT NULL
);

CREATE INDEX giftcard_lookup_failures_device ON giftcard_lookup_failures (device, at);

ALTER TABLE checkouts ADD COLUMN completed_at INTEGER;
ALTER TABLE orders ADD COLUMN gift_card_payment_id TEXT;
ALTER TABLE orders ADD COLUMN gift_card_cents INTEGER;
ALTER TABLE orders ADD COLUMN gift_card_last4 TEXT;
