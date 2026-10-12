import { authenticate, HttpError, json, noteKioskContact, readBody, withRetry, type Route } from "./http";
import { resolveCredentials, type SquareCredentials } from "./oauth";
import { CheckoutCancelBody, CheckoutCompleteBody, GiftCardChargeBody, GiftCardLookupBody } from "./schema";
import { SquareError, squareRequest } from "./square";

export const SWEEP_CRON = "*/10 * * * *";

const LOOKUP_FAILURE_LIMIT = 10;
const LOOKUP_FAILURE_WINDOW_MS = 10 * 60_000;
const HOLD_TTL_MS = 15 * 60_000;
const SWEEP_BATCH = 50;

interface CheckoutRow {
  id: string;
  square_order_id: string;
  total_cents: number;
  location_id: string;
  completed_at: number | null;
}

interface GiftCardPaymentRow {
  payment_id: string;
  checkout_id: string;
  gan_last4: string;
  approved_cents: number;
  status: "approved" | "completed" | "canceled";
}

interface SquareGiftCard {
  id: string;
  state: string;
  balanceCents: number;
}

export function normalizeGan(input: string): string {
  const gan = input.trim().replace(/^sqgc:\/\//i, "").replace(/\D/g, "");
  if (!/^\d{16}$/.test(gan)) throw new HttpError(400, "invalid_gan", "A gift card number is 16 digits");
  return gan;
}

async function credentialsFor(env: Env): Promise<SquareCredentials> {
  const credentials = await resolveCredentials(env);
  if (!credentials) throw new HttpError(503, "not_configured", "No Square credentials on the server", {}, false);
  return credentials;
}

function squareFailure(event: string, context: Record<string, unknown>, error: unknown): never {
  if (error instanceof SquareError) {
    console.error({ event, ...context, status: error.status, codes: error.codes, error: error.message });
    if (error.isTransient) throw new HttpError(503, "unavailable", "Square is unavailable, retry later");
    throw new HttpError(502, error.isAuth ? "square_unauthorized" : "square_rejected", error.message, {}, false);
  }
  throw error;
}

async function recentLookupFailures(env: Env, device: string, now: number): Promise<number> {
  const row = await withRetry("D1", () =>
    env.DB.prepare("SELECT COUNT(*) AS n FROM giftcard_lookup_failures WHERE device = ? AND at > ?")
      .bind(device, now - LOOKUP_FAILURE_WINDOW_MS)
      .first<{ n: number }>(),
  );
  return row?.n ?? 0;
}

async function noteLookupFailure(env: Env, device: string, now: number): Promise<void> {
  await withRetry("D1", () =>
    env.DB.batch([
      env.DB.prepare("INSERT INTO giftcard_lookup_failures (device, at) VALUES (?, ?)").bind(device, now),
      env.DB.prepare("DELETE FROM giftcard_lookup_failures WHERE at < ?").bind(now - LOOKUP_FAILURE_WINDOW_MS),
    ]),
  );
}

async function lookupCard(env: Env, credentials: SquareCredentials, device: string, rawGan: string, now = Date.now()): Promise<SquareGiftCard & { last4: string }> {
  if ((await recentLookupFailures(env, device, now)) >= LOOKUP_FAILURE_LIMIT) {
    throw new HttpError(429, "rate_limited", "Too many failed gift card lookups, try again in a few minutes", { "Retry-After": "300" });
  }
  let gan: string;
  try {
    gan = normalizeGan(rawGan);
  } catch (error) {
    await noteLookupFailure(env, device, now);
    throw error;
  }
  const last4 = gan.slice(-4);
  try {
    const response = await squareRequest<{ gift_card?: { id?: string; state?: string; balance_money?: { amount?: number } } }>(
      credentials.environment,
      "/v2/gift-cards/from-gan",
      { bearer: credentials.accessToken, body: { gan } },
    );
    const card = response.gift_card;
    if (!card?.id) throw new HttpError(502, "square_rejected", "Unexpected gift card response", {}, false);
    return { id: card.id, state: card.state ?? "UNKNOWN", balanceCents: card.balance_money?.amount ?? 0, last4 };
  } catch (error) {
    if (error instanceof SquareError && error.status === 404) {
      await noteLookupFailure(env, device, now);
      console.warn({ event: "giftcard-not-found", device, last4 });
      throw new HttpError(404, "giftcard_not_found", "No gift card with that number");
    }
    return squareFailure("giftcard-lookup-failed", { device, last4 }, error);
  }
}

async function loadCheckout(env: Env, device: string, checkoutId: string): Promise<CheckoutRow> {
  const row = await withRetry("D1", () =>
    env.DB.prepare("SELECT id, square_order_id, total_cents, location_id, completed_at FROM checkouts WHERE id = ? AND device = ?")
      .bind(checkoutId, device)
      .first<CheckoutRow>(),
  );
  if (!row) throw new HttpError(404, "checkout_not_found", "No such checkout for this device");
  return row;
}

async function paymentsFor(env: Env, checkoutId: string): Promise<GiftCardPaymentRow[]> {
  const { results } = await withRetry("D1", () =>
    env.DB.prepare("SELECT payment_id, checkout_id, gan_last4, approved_cents, status FROM giftcard_payments WHERE checkout_id = ? ORDER BY created_at")
      .bind(checkoutId)
      .all<GiftCardPaymentRow>(),
  );
  return results;
}

const approvedCents = (rows: GiftCardPaymentRow[]) => rows.filter((r) => r.status !== "canceled").reduce((sum, r) => sum + r.approved_cents, 0);

async function lookup(env: Env, device: string, body: { gan: string }): Promise<Response> {
  const credentials = await credentialsFor(env);
  const card = await lookupCard(env, credentials, device, body.gan);
  return json({ last4: card.last4, balanceCents: card.balanceCents, state: card.state });
}

async function charge(env: Env, device: string, body: { checkoutId: string; gan: string; idempotencyKey: string }, now = Date.now()): Promise<Response> {
  const checkout = await loadCheckout(env, device, body.checkoutId);

  const replayed = await withRetry("D1", () =>
    env.DB.prepare("SELECT payment_id, checkout_id, gan_last4, approved_cents, status FROM giftcard_payments WHERE idempotency_key = ?")
      .bind(body.idempotencyKey)
      .first<GiftCardPaymentRow>(),
  );
  if (replayed) {
    if (replayed.checkout_id !== checkout.id) throw new HttpError(409, "conflict", "This idempotency key was used for a different checkout");
    const total = approvedCents(await paymentsFor(env, checkout.id));
    return json({ paymentId: replayed.payment_id, approvedCents: replayed.approved_cents, remainingCents: checkout.total_cents - total, last4: replayed.gan_last4 });
  }

  const credentials = await credentialsFor(env);
  const card = await lookupCard(env, credentials, device, body.gan, now);
  if (card.state !== "ACTIVE") throw new HttpError(409, "giftcard_inactive", "This gift card is not active");
  if (card.balanceCents <= 0) throw new HttpError(409, "giftcard_empty", "This gift card has no balance");

  const due = checkout.total_cents - approvedCents(await paymentsFor(env, checkout.id));
  if (due <= 0) throw new HttpError(409, "already_covered", "Gift cards already cover this checkout");

  let payment: { id?: string; status?: string; amount_money?: { amount?: number } } | undefined;
  try {
    const response = await squareRequest<{ payment?: typeof payment }>(credentials.environment, "/v2/payments", {
      bearer: credentials.accessToken,
      body: {
        idempotency_key: body.idempotencyKey,
        source_id: card.id,
        amount_money: { amount: due, currency: "USD" },
        order_id: checkout.square_order_id,
        location_id: checkout.location_id,
        autocomplete: false,
        accept_partial_authorization: true,
        reference_id: checkout.id.slice(0, 40),
      },
    });
    payment = response.payment;
  } catch (error) {
    return squareFailure("giftcard-charge-failed", { device, checkoutId: checkout.id, last4: card.last4 }, error);
  }
  const approved = payment?.amount_money?.amount ?? 0;
  if (!payment?.id || approved <= 0) throw new HttpError(502, "square_rejected", "Unexpected gift card payment response", {}, false);

  await withRetry("D1", () =>
    env.DB.prepare(
      `INSERT OR IGNORE INTO giftcard_payments (payment_id, checkout_id, device, idempotency_key, gan_last4, approved_cents, status, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, 'approved', ?, ?)`,
    )
      .bind(payment!.id, checkout.id, device, body.idempotencyKey, card.last4, approved, now, now)
      .run(),
  );
  console.log({ event: "giftcard-charge", device, checkoutId: checkout.id, last4: card.last4, approvedCents: approved });
  const total = approvedCents(await paymentsFor(env, checkout.id));
  return json({ paymentId: payment.id, approvedCents: approved, remainingCents: checkout.total_cents - total, last4: card.last4 });
}

interface SquareOrderState {
  total_money?: { amount?: number };
  net_amount_due_money?: { amount?: number };
  tenders?: { amount_money?: { amount?: number } }[];
}

async function orderIsPaid(credentials: SquareCredentials, orderId: string): Promise<boolean> {
  const { order } = await squareRequest<{ order?: SquareOrderState }>(credentials.environment, `/v2/orders/${encodeURIComponent(orderId)}`, {
    bearer: credentials.accessToken,
  });
  if (!order) return false;
  if (typeof order.net_amount_due_money?.amount === "number") return order.net_amount_due_money.amount === 0;
  const total = order.total_money?.amount;
  if (typeof total !== "number" || !order.tenders?.length) return false;
  return order.tenders.reduce((sum, t) => sum + (t.amount_money?.amount ?? 0), 0) >= total;
}

async function complete(env: Env, device: string, body: { checkoutId: string; paymentIds: string[]; idempotencyKey: string }, now = Date.now()): Promise<Response> {
  const checkout = await loadCheckout(env, device, body.checkoutId);
  if (checkout.completed_at !== null) return json({ status: "completed" });
  const credentials = await credentialsFor(env);

  try {
    await squareRequest(credentials.environment, `/v2/orders/${encodeURIComponent(checkout.square_order_id)}/pay`, {
      bearer: credentials.accessToken,
      body: { idempotency_key: body.idempotencyKey, payment_ids: body.paymentIds },
    });
  } catch (error) {
    if (error instanceof SquareError && error.codes.includes("ORDER_TOTAL_MISMATCH")) {
      throw new HttpError(409, "amount_mismatch", "The payments do not add up to the order total");
    }
    const alreadyPaid = error instanceof SquareError && !error.isTransient ? await orderIsPaid(credentials, checkout.square_order_id).catch(() => false) : false;
    if (!alreadyPaid) return squareFailure("checkout-complete-failed", { device, checkoutId: checkout.id }, error);
  }

  let paid: boolean;
  try {
    paid = await orderIsPaid(credentials, checkout.square_order_id);
  } catch (error) {
    return squareFailure("checkout-verify-failed", { device, checkoutId: checkout.id }, error);
  }
  if (!paid) throw new HttpError(409, "order_unpaid", "Square still shows an amount due on this order");

  const rows = await paymentsFor(env, checkout.id);
  await withRetry("D1", () =>
    env.DB.batch([
      env.DB.prepare("UPDATE checkouts SET completed_at = ? WHERE id = ?").bind(now, checkout.id),
      ...rows
        .filter((r) => r.status === "approved" && body.paymentIds.includes(r.payment_id))
        .map((r) => env.DB.prepare("UPDATE giftcard_payments SET status = 'completed', updated_at = ? WHERE payment_id = ?").bind(now, r.payment_id)),
    ]),
  );
  console.log({ event: "checkout-complete", device, checkoutId: checkout.id, payments: body.paymentIds.length });
  return json({ status: "completed" });
}

type CancelOutcome = "canceled" | "completed" | "failed" | "transient";

async function cancelPayment(credentials: SquareCredentials, paymentId: string): Promise<CancelOutcome> {
  const path = `/v2/payments/${encodeURIComponent(paymentId)}`;
  try {
    await squareRequest(credentials.environment, `${path}/cancel`, { bearer: credentials.accessToken, body: {} });
    return "canceled";
  } catch (error) {
    if (!(error instanceof SquareError)) throw error;
    if (error.isTransient) return "transient";
    try {
      const { payment } = await squareRequest<{ payment?: { status?: string } }>(credentials.environment, path, { bearer: credentials.accessToken });
      if (payment?.status === "CANCELED") return "canceled";
      if (payment?.status === "COMPLETED") return "completed";
    } catch {}
    console.warn({ event: "payment-cancel-refused", paymentId, status: error.status, codes: error.codes });
    return "failed";
  }
}

async function markPayments(env: Env, ids: string[], status: "canceled" | "completed", now: number): Promise<void> {
  if (ids.length === 0) return;
  await withRetry("D1", () =>
    env.DB.batch(
      ids.map((id) => env.DB.prepare("UPDATE giftcard_payments SET status = ?, updated_at = ? WHERE payment_id = ? AND status = 'approved'").bind(status, now, id)),
    ),
  );
}

async function cancelAll(env: Env, credentials: SquareCredentials, ids: string[], now: number): Promise<{ canceled: string[]; transient: boolean }> {
  const canceled: string[] = [];
  const completed: string[] = [];
  let transient = false;
  for (const id of ids) {
    const outcome = await cancelPayment(credentials, id);
    if (outcome === "canceled") canceled.push(id);
    else if (outcome === "completed") completed.push(id);
    else if (outcome === "transient") transient = true;
  }
  await markPayments(env, canceled, "canceled", now);
  await markPayments(env, completed, "completed", now);
  return { canceled, transient };
}

async function cancel(env: Env, device: string, body: { checkoutId: string; paymentIds?: string[] }, now = Date.now()): Promise<Response> {
  const checkout = await loadCheckout(env, device, body.checkoutId);
  const credentials = await credentialsFor(env);
  const held = (await paymentsFor(env, checkout.id)).filter((r) => r.status === "approved").map((r) => r.payment_id);
  const ids = [...new Set([...(body.paymentIds ?? []), ...held])];
  const { canceled, transient } = await cancelAll(env, credentials, ids, now);
  if (transient) throw new HttpError(503, "unavailable", "Square is unavailable, retry later");
  console.log({ event: "checkout-cancel", device, checkoutId: checkout.id, canceled: canceled.length });
  return json({ canceled });
}

export async function sweepStaleHolds(env: Env, now = Date.now()): Promise<number> {
  const { results } = await withRetry("D1", () =>
    env.DB.prepare("SELECT payment_id FROM giftcard_payments WHERE status = 'approved' AND created_at < ? ORDER BY created_at LIMIT ?")
      .bind(now - HOLD_TTL_MS, SWEEP_BATCH)
      .all<{ payment_id: string }>(),
  );
  if (results.length === 0) return 0;
  const credentials = await resolveCredentials(env, now);
  if (!credentials) {
    console.warn({ event: "giftcard-sweep-skipped", reason: "no credentials", stale: results.length });
    return 0;
  }
  const { canceled } = await cancelAll(env, credentials, results.map((r) => r.payment_id), now);
  console.log({ event: "giftcard-sweep", stale: results.length, canceled: canceled.length });
  return canceled.length;
}

export const routes: Route[] = [
  {
    method: "POST",
    path: "/v1/giftcards/lookup",
    async handle({ request, env }) {
      const client = await authenticate(request, env, ["kiosk"]);
      return lookup(env, client.device, await readBody(request, GiftCardLookupBody, 4 * 1024));
    },
  },
  {
    method: "POST",
    path: "/v1/giftcards/charge",
    async handle({ request, env, ctx }) {
      const client = await authenticate(request, env, ["kiosk"]);
      const response = await charge(env, client.device, await readBody(request, GiftCardChargeBody, 4 * 1024));
      noteKioskContact(env, ctx, client.device);
      return response;
    },
  },
  {
    method: "POST",
    path: "/v1/checkout/complete",
    async handle({ request, env, ctx }) {
      const client = await authenticate(request, env, ["kiosk"]);
      const response = await complete(env, client.device, await readBody(request, CheckoutCompleteBody, 4 * 1024));
      noteKioskContact(env, ctx, client.device);
      return response;
    },
  },
  {
    method: "POST",
    path: "/v1/checkout/cancel",
    async handle({ request, env }) {
      const client = await authenticate(request, env, ["kiosk"]);
      return cancel(env, client.device, await readBody(request, CheckoutCancelBody, 4 * 1024));
    },
  },
];
