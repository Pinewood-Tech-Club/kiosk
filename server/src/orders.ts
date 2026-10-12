import { authenticate, callHub, hub, json, noteKioskContact, readBody, withRetry, type Client, type Route } from "./http";
import type { ItemResult, OrderSummary } from "./protocol";
import { describe, Order, OrdersBody, parseTimestamp } from "./schema";

const D1_CHUNK = 50;

export function orderSummary(o: Order, receivedAt: number, device: string | null): OrderSummary {
  return {
    id: o.id,
    orderNumber: o.orderNumber ?? null,
    orderRef: o.orderRef ?? null,
    kioskId: device,
    customerName: o.customerName ?? null,
    items: o.items.map((i) => ({ vessel: i.vessel, flavors: i.flavors, toppings: i.toppings ?? [] })),
    totalCents: o.totalCents,
    simulated: o.simulated,
    paidAt: parseTimestamp(o.paidAt, receivedAt),
    receivedAt,
    status: "paid",
    statusAt: receivedAt,
    statusBy: null,
  };
}

/**
 * Stored in D1 first, then pushed to the hub's staff feed. Duplicates are pushed too (the hub ignores ones it has),
 * so a hub failure answered with 503 is healed by the kiosk's retry.
 */
async function ingestOrders(request: Request, env: Env, client: Client): Promise<Response> {
  const body = await readBody(request, OrdersBody, 512 * 1024);
  const now = Date.now();
  const statement = env.DB.prepare(
    `INSERT OR IGNORE INTO orders (id, order_number, square_order_id, square_payment_id, customer_name, total_cents,
       subtotal_cents, tax_cents, card, simulated, items, lines, paid_at, device, app_version, received_at, receipt_token, status, status_at, order_ref,
       gift_card_payment_id, gift_card_cents, gift_card_last4)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'paid', ?, ?, ?, ?, ?)`,
  );
  const results: ItemResult[] = [];
  const pending: { index: number; statement: D1PreparedStatement; order: Order }[] = [];
  const stamped = body.orders.some((o) => typeof (o as { epoch?: unknown })?.epoch === "number");
  const epoch = stamped ? await callHub("epoch", () => hub(env).currentEpoch()) : 0;
  for (const item of body.orders) {
    const parsed = Order.safeParse(item);
    if (!parsed.success) {
      const id = typeof (item as { id?: unknown })?.id === "string" ? String((item as { id: string }).id).slice(0, 64) : "";
      results.push({ id, status: "rejected", error: { code: "bad_request", message: describe(parsed.error) } });
      continue;
    }
    const o = parsed.data;
    if (o.epoch !== undefined && o.epoch < epoch) {
      console.warn({ event: "order-dropped-before-reset", device: client.device, epoch: o.epoch, current: epoch, order: o });
      results.push({ id: o.id, status: "stale" });
      continue;
    }
    results.push({ id: o.id, status: "ok" });
    pending.push({
      index: results.length - 1,
      order: o,
      statement: statement.bind(
        o.id, o.orderNumber ?? null, o.squareOrderId ?? null, o.squarePaymentId || null, o.customerName ?? null, o.totalCents,
        o.subtotalCents ?? null, o.taxCents ?? null, o.card ?? null, o.simulated ? 1 : 0, JSON.stringify(o.items),
        o.lines ? JSON.stringify(o.lines) : null, parseTimestamp(o.paidAt, now), client.device, o.appVersion ?? null, now,
        o.receiptToken ?? null, now, o.orderRef ?? null,
        o.giftCardPaymentId ?? null, o.giftCardCents ?? null, o.giftCardLast4 ?? null,
      ),
    });
  }
  for (let i = 0; i < pending.length; i += D1_CHUNK) {
    const chunk = pending.slice(i, i + D1_CHUNK);
    const outcomes = await withRetry("D1", () => env.DB.batch(chunk.map((p) => p.statement)));
    outcomes.forEach((outcome, j) => {
      if ((outcome.meta.changes ?? 0) === 0) results[chunk[j].index].status = "duplicate";
    });
  }
  const feed = await feedable(env, pending.map((p) => ({ order: p.order, duplicate: results[p.index].status === "duplicate" })));
  if (feed.length > 0) {
    const epochs = Object.fromEntries(feed.filter((o) => o.epoch !== undefined).map((o) => [o.id, o.epoch!]));
    const recorded = await callHub("orders", () => hub(env).recordOrders(feed.map((o) => orderSummary(o, now, client.device)), epochs));
    if (recorded.stale.length > 0) await dropRaced(env, recorded.stale, results, client.device);
  }
  for (const result of results) {
    console.log({ event: "order", id: result.id, status: result.status, device: client.device });
  }
  return json({ results });
}

/** A reset landed between the epoch check and the insert: the hub refused these, so they leave D1 too. */
async function dropRaced(env: Env, ids: string[], results: ItemResult[], device: string) {
  await withRetry("D1", () => env.DB.batch(ids.map((id) => env.DB.prepare("DELETE FROM orders WHERE id = ?").bind(id))));
  for (const result of results) if (ids.includes(result.id)) result.status = "stale";
  console.warn({ event: "orders-dropped-reset-race", device, ids });
}

/** New orders, plus duplicates stored under the same id (not ones that only share a Square payment id with another order). */
async function feedable(env: Env, candidates: { order: Order; duplicate: boolean }[]): Promise<Order[]> {
  const duplicates = candidates.filter((c) => c.duplicate).map((c) => c.order.id);
  const stored = new Set<string>();
  for (let i = 0; i < duplicates.length; i += D1_CHUNK) {
    const ids = duplicates.slice(i, i + D1_CHUNK);
    const { results } = await withRetry("D1", () =>
      env.DB.prepare(`SELECT id FROM orders WHERE id IN (${ids.map(() => "?").join(", ")})`).bind(...ids).all<{ id: string }>(),
    );
    for (const row of results) stored.add(row.id);
  }
  return candidates.filter((c) => !c.duplicate || stored.has(c.order.id)).map((c) => c.order);
}

async function listOrders(url: URL, env: Env): Promise<Response> {
  const since = Number(url.searchParams.get("since") ?? "0") || 0;
  const limit = Math.min(Math.max(Number(url.searchParams.get("limit") ?? "500") || 500, 1), 2000);
  const device = url.searchParams.get("device") || null;
  const { results } = await withRetry("D1", () =>
    env.DB.prepare(
      `SELECT id, order_number, square_order_id, square_payment_id, customer_name, total_cents, subtotal_cents, tax_cents,
              card, simulated, items, lines, paid_at, device, order_ref, status, status_at, status_by,
              gift_card_payment_id, gift_card_cents, gift_card_last4
       FROM orders WHERE paid_at >= ?1 AND (?2 IS NULL OR device = ?2) ORDER BY paid_at DESC LIMIT ?3`,
    )
      .bind(since, device, limit)
      .all<{ simulated: number; total_cents: number; items: string; lines: string | null }>(),
  );
  const orders = results.map((r) => ({ ...r, items: JSON.parse(r.items), lines: r.lines ? JSON.parse(r.lines) : null }));
  const real = orders.filter((o) => !o.simulated);
  return json({ count: real.length, totalCents: real.reduce((sum, o) => sum + o.total_cents, 0), orders });
}

export const routes: Route[] = [
  {
    method: "POST",
    path: "/v1/orders",
    async handle({ request, env, ctx }) {
      const client = await authenticate(request, env, ["kiosk"]);
      const response = await ingestOrders(request, env, client);
      noteKioskContact(env, ctx, client.device);
      return response;
    },
  },
  {
    method: "GET",
    path: "/v1/orders",
    async handle({ request, env, url }) {
      await authenticate(request, env, ["staff"]);
      return listOrders(url, env);
    },
  },
];
