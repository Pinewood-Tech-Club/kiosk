CREATE TABLE giftcard_payments_new (
  payment_id TEXT,
  checkout_id TEXT NOT NULL,
  device TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  gan_last4 TEXT NOT NULL,
  approved_cents INTEGER NOT NULL,
  status TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  card_id TEXT
);

INSERT INTO giftcard_payments_new (payment_id, checkout_id, device, idempotency_key, gan_last4, approved_cents, status, created_at, updated_at)
  SELECT payment_id, checkout_id, device, idempotency_key, gan_last4, approved_cents, status, created_at, updated_at FROM giftcard_payments;

DROP TABLE giftcard_payments;
ALTER TABLE giftcard_payments_new RENAME TO giftcard_payments;

CREATE UNIQUE INDEX giftcard_payments_payment ON giftcard_payments (payment_id);
CREATE UNIQUE INDEX giftcard_payments_idempotency ON giftcard_payments (idempotency_key);
CREATE INDEX giftcard_payments_checkout ON giftcard_payments (checkout_id);
CREATE INDEX giftcard_payments_status ON giftcard_payments (status, created_at);
