import { createExecutionContext, createScheduledController, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker, { FEATURES } from "../src";
import { balancePageToken, normalizeGan, parseGiftCardCode } from "../src/giftcards";
import { OAUTH_SCOPES } from "../src/oauth";
import { receiptPage, type ReceiptRecord } from "../src/receipts";

const KIOSK = "test-kiosk-token";
const BASE = "https://booth.test";
const GAN = "7783320000001234";
const configured = { ...env, SQUARE_ACCESS_TOKEN: "EAAA-static" } as Env;

interface SquareCall {
  method: string;
  path: string;
  body: any;
}

type Handler = (body: any, call: SquareCall) => { status?: number; body: unknown } | Promise<{ status?: number; body: unknown }>;

let calls: SquareCall[] = [];
let handlers: Record<string, Handler> = {};

const squareError = (status: number, code: string) => ({ status, body: { errors: [{ code, category: "INVALID_REQUEST_ERROR", detail: code }] } });

const card = (overrides: Record<string, unknown> = {}) => ({
  gift_card: { id: "gftc:abc", state: "ACTIVE", balance_money: { amount: 500, currency: "USD" }, gan: GAN, ...overrides },
});

function mockSquare(overrides: Record<string, Handler> = {}) {
  handlers = {
    "POST /v2/gift-cards/from-gan": () => ({ body: card() }),
    "GET /v2/locations": () => ({ body: { locations: [{ id: "LOC1", name: "Booth", status: "ACTIVE", capabilities: ["CREDIT_CARD_PROCESSING"] }] } }),
    "POST /v2/payments": (body) => ({ body: { payment: { id: "PAY-GIFT", status: "APPROVED", amount_money: { amount: Math.min(500, body.amount_money.amount) } } } }),
    "POST /v2/orders/ORDER-1/pay": () => ({ body: { order: { id: "ORDER-1" } } }),
    "GET /v2/orders/ORDER-1": () => ({ body: { order: { id: "ORDER-1", total_money: { amount: 900 }, net_amount_due_money: { amount: 0 } } } }),
    ...overrides,
  };
  calls = [];
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url);
    if (!url.hostname.endsWith("squareup.com") && !url.hostname.endsWith("squareupsandbox.com")) throw new Error(`Unexpected fetch ${url}`);
    const method = init?.method ?? "GET";
    const entry = { method, path: url.pathname, body: init?.body ? JSON.parse(String(init.body)) : undefined };
    calls.push(entry);
    const cancel = /^\/v2\/payments\/([^/]+)\/cancel$/.exec(url.pathname);
    const handler = handlers[`${method} ${url.pathname}`] ?? (cancel ? handlers["POST /v2/payments/:id/cancel"] : undefined);
    if (!handler) return Response.json({ errors: [{ code: "NOT_FOUND", detail: "no mock" }] }, { status: 404 });
    const result = await handler(entry.body, entry);
    return Response.json(result.body, { status: result.status ?? 200 });
  });
}

const callsTo = (method: string, path: string) => calls.filter((c) => c.method === method && c.path === path);

async function call(path: string, json: unknown, init: { device?: string; token?: string } = {}) {
  const request = new Request(`${BASE}${path}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${init.token ?? KIOSK}`, "X-Booth-Device": init.device ?? "kiosk-a", "Content-Type": "application/json" },
    body: JSON.stringify(json),
  });
  const ctx = createExecutionContext();
  const response = await worker.fetch(request as Request<unknown, IncomingRequestCfProperties>, configured, ctx);
  await waitOnExecutionContext(ctx);
  return { status: response.status, body: (await response.json()) as any };
}

async function seedCheckout(id = "chk-1", overrides: { device?: string; total?: number; orderId?: string } = {}) {
  await env.DB.prepare(
    `INSERT INTO checkouts (id, device, request_hash, environment, location_id, square_order_id, total_cents, tax_cents, expected_cents, used_catalog, items, response, created_at)
     VALUES (?, ?, 'h', 'production', 'LOC1', ?, ?, 0, ?, 1, '[]', '{}', ?)`,
  )
    .bind(id, overrides.device ?? "kiosk-a", overrides.orderId ?? "ORDER-1", overrides.total ?? 900, overrides.total ?? 900, Date.now())
    .run();
}

const giftRow = (paymentId: string) =>
  env.DB.prepare("SELECT status, approved_cents, gan_last4 FROM giftcard_payments WHERE payment_id = ?").bind(paymentId).first<{ status: string; approved_cents: number; gan_last4: string }>();

beforeEach(async () => {
  await env.DB.batch(["checkouts", "giftcard_payments", "giftcard_lookup_failures", "square_tokens", "square_cache"].map((t) => env.DB.prepare(`DELETE FROM ${t}`)));
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe("gift card basics", () => {
  it("advertises the feature and requests the scope", () => {
    expect(FEATURES).toContain("gift-cards");
    expect(OAUTH_SCOPES).toContain("GIFTCARDS_READ");
  });

  it("advertises gift-cards on health only when the credentials can use them", async () => {
    const features = async (overrides: Record<string, unknown>) => {
      const ctx = createExecutionContext();
      const response = await worker.fetch(new Request(`${BASE}/v1/health`) as Request<unknown, IncomingRequestCfProperties>, { ...env, SQUARE_ACCESS_TOKEN: "", ...overrides } as Env, ctx);
      await waitOnExecutionContext(ctx);
      return ((await response.json()) as any).features as string[];
    };
    const store = (scopes: string) =>
      env.DB.prepare(
        `INSERT INTO square_tokens (environment, application_id, merchant_id, location_id, access_token, refresh_token, expires_at, scopes, obtained_at, refreshed_at)
         VALUES (?, 'app', 'M1', 'LOC1', 'x', NULL, NULL, ?, 1, 1)`,
      ).bind(env.SQUARE_ENVIRONMENT || "production", scopes).run();
    expect(await features({})).not.toContain("gift-cards");
    expect(await features({ SQUARE_ACCESS_TOKEN: "EAAA-static" })).toContain("gift-cards");
    await store("ORDERS_WRITE PAYMENTS_WRITE");
    expect(await features({ SQUARE_ACCESS_TOKEN: "EAAA-static" })).not.toContain("gift-cards");
    await env.DB.prepare("DELETE FROM square_tokens").run();
    await store(OAUTH_SCOPES.join(" "));
    expect(await features({})).toContain("gift-cards");
  });

  it("normalizes scanned and typed numbers", () => {
    expect(normalizeGan(`sqgc://${GAN}`)).toBe(GAN);
    expect(normalizeGan(`SQGC://${GAN}`)).toBe(GAN);
    expect(normalizeGan("7783 3200 0000 1234")).toBe(GAN);
    expect(() => normalizeGan("1234")).toThrow(/16 digits/);
    expect(() => normalizeGan(`${GAN}9`)).toThrow();
  });

  it("reads the gift card token from a Square balance QR code", () => {
    const token = "a12dc64b43d84644acfd4b9c313f62dd";
    for (const url of [
      `https://app.squareup.com/gift/balance/${token}`,
      `HTTPS://APP.SQUAREUP.COM/GIFT/BALANCE/${token.toUpperCase()}`,
      `http://app.squareup.com/gift/balance/${token}/`,
      `https://squareup.com/gift/balance/${token}?utm_source=card#top`,
      `  https://www.squareup.com/gift/balance/${token}  `,
    ]) {
      expect(balancePageToken(url)).toBe(token);
      expect(parseGiftCardCode(url)).toEqual({ token });
    }
    for (const url of [
      `https://app.squareup.com/gift/balance/${token}0`,
      `https://app.squareup.com/gift/balance/${token.slice(1)}`,
      `https://app.squareup.com/gift/balance/${token.slice(1)}g`,
      `https://app.squareup.com/gift/balance/${token}/extra`,
      `https://app.squareup.com/gift/${token}`,
      `https://evil.example/gift/balance/${token}`,
      `https://app.squareup.com.evil.example/gift/balance/${token}`,
      `https://app.squareup.com@evil.example/gift/balance/${token}`,
      `ftp://app.squareup.com/gift/balance/${token}`,
    ]) {
      expect(balancePageToken(url)).toBeNull();
    }
    expect(() => parseGiftCardCode(`https://evil.example/gift/balance/${token}`)).toThrow(/QR code/);
    expect(() => parseGiftCardCode(`https://example.com/${GAN}`)).toThrow(/QR code/);
    expect(parseGiftCardCode(`SQGC://${GAN}`)).toEqual({ gan: GAN });
    expect(parseGiftCardCode(GAN)).toEqual({ gan: GAN });
  });
});

describe("POST /v1/giftcards/lookup", () => {
  it("returns the balance and state without the full number", async () => {
    mockSquare();
    const result = await call("/v1/giftcards/lookup", { gan: `sqgc://${GAN}` });
    expect(result.status).toBe(200);
    expect(result.body).toEqual({ last4: "1234", balanceCents: 500, state: "ACTIVE" });
    expect(callsTo("POST", "/v2/gift-cards/from-gan")[0].body).toEqual({ gan: GAN });
  });

  it("requires the kiosk role", async () => {
    mockSquare();
    expect((await call("/v1/giftcards/lookup", { gan: GAN }, { token: "test-staff-token" })).status).toBe(403);
  });

  it("answers invalid_gan and giftcard_not_found, then rate limits after 10 failures", async () => {
    mockSquare({ "POST /v2/gift-cards/from-gan": () => squareError(404, "NOT_FOUND") });
    const bad = await call("/v1/giftcards/lookup", { gan: "12" });
    expect(bad.status).toBe(400);
    expect(bad.body.error.code).toBe("invalid_gan");
    expect(callsTo("POST", "/v2/gift-cards/from-gan")).toHaveLength(0);
    const missing = await call("/v1/giftcards/lookup", { gan: GAN });
    expect(missing.status).toBe(404);
    expect(missing.body.error.code).toBe("giftcard_not_found");
    for (let i = 0; i < 8; i++) await call("/v1/giftcards/lookup", { gan: GAN });
    const limited = await call("/v1/giftcards/lookup", { gan: GAN });
    expect(limited.status).toBe(429);
    expect(limited.body.error).toMatchObject({ code: "rate_limited", retryable: true });
    const other = await call("/v1/giftcards/lookup", { gan: GAN }, { device: "kiosk-b" });
    expect(other.status).toBe(404);
  });

  it("ignores failures older than ten minutes", async () => {
    mockSquare();
    const old = Date.now() - 11 * 60_000;
    await env.DB.batch(Array.from({ length: 12 }, () => env.DB.prepare("INSERT INTO giftcard_lookup_failures (device, at) VALUES ('kiosk-a', ?)").bind(old)));
    expect((await call("/v1/giftcards/lookup", { gan: GAN })).status).toBe(200);
  });
});

describe("POST /v1/giftcards/charge", () => {
  it("records a pending row before calling Square and drops it when Square refuses", async () => {
    await seedCheckout();
    let during: unknown = null;
    mockSquare({
      "POST /v2/payments": async () => {
        during = await env.DB.prepare("SELECT status, payment_id, approved_cents, card_id FROM giftcard_payments WHERE idempotency_key = 'key-1'").first();
        return squareError(400, "INSUFFICIENT_FUNDS");
      },
    });
    const result = await call("/v1/giftcards/charge", { checkoutId: "chk-1", gan: GAN, idempotencyKey: "key-1" });
    expect(during).toEqual({ status: "pending", payment_id: null, approved_cents: 900, card_id: "gftc:abc" });
    expect(result.status).toBe(502);
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM giftcard_payments").first()).toEqual({ n: 0 });
  });

  it("resumes a pending row on replay with the same amount and key", async () => {
    await seedCheckout();
    await env.DB.prepare("INSERT INTO giftcard_payments (payment_id, checkout_id, device, idempotency_key, gan_last4, approved_cents, status, created_at, updated_at, card_id) VALUES (NULL, 'chk-1', 'kiosk-a', 'key-1', '1234', 900, 'pending', ?, ?, 'gftc:abc')").bind(Date.now(), Date.now()).run();
    mockSquare();
    const result = await call("/v1/giftcards/charge", { checkoutId: "chk-1", gan: GAN, idempotencyKey: "key-1" });
    expect(result.body).toEqual({ paymentId: "PAY-GIFT", approvedCents: 500, remainingCents: 400, last4: "1234" });
    expect(callsTo("POST", "/v2/payments")[0].body.amount_money.amount).toBe(900);
    expect((await giftRow("PAY-GIFT"))?.status).toBe("approved");
  });

  it("holds a partial amount and records it, replaying on the same key", async () => {
    mockSquare();
    await seedCheckout();
    const body = { checkoutId: "chk-1", gan: GAN, idempotencyKey: "key-1" };
    const first = await call("/v1/giftcards/charge", body);
    expect(first.status).toBe(200);
    expect(first.body).toEqual({ paymentId: "PAY-GIFT", approvedCents: 500, remainingCents: 400, last4: "1234" });
    expect(callsTo("POST", "/v2/payments")[0].body).toMatchObject({
      idempotency_key: "key-1", source_id: "gftc:abc", amount_money: { amount: 900, currency: "USD" }, order_id: "ORDER-1",
      location_id: "LOC1", autocomplete: false, accept_partial_authorization: true,
    });
    expect(await giftRow("PAY-GIFT")).toEqual({ status: "approved", approved_cents: 500, gan_last4: "1234" });

    const again = await call("/v1/giftcards/charge", body);
    expect(again.body).toEqual(first.body);
    expect(callsTo("POST", "/v2/payments")).toHaveLength(1);
    const reused = await call("/v1/giftcards/charge", { ...body, checkoutId: "chk-2" });
    expect(reused.status).toBe(404);
  });

  it("covers a small total completely", async () => {
    mockSquare();
    await seedCheckout("chk-1", { total: 300 });
    const result = await call("/v1/giftcards/charge", { checkoutId: "chk-1", gan: GAN, idempotencyKey: "key-1" });
    expect(result.body).toMatchObject({ approvedCents: 300, remainingCents: 0 });
  });

  it("charges only what a second card must still cover", async () => {
    let n = 0;
    mockSquare({
      "POST /v2/payments": (body) => ({ body: { payment: { id: `PAY-${++n}`, status: "APPROVED", amount_money: { amount: Math.min(500, body.amount_money.amount) } } } }),
    });
    await seedCheckout();
    await call("/v1/giftcards/charge", { checkoutId: "chk-1", gan: GAN, idempotencyKey: "key-1" });
    const second = await call("/v1/giftcards/charge", { checkoutId: "chk-1", gan: GAN, idempotencyKey: "key-2" });
    expect(callsTo("POST", "/v2/payments")[1].body.amount_money.amount).toBe(400);
    expect(second.body).toMatchObject({ approvedCents: 400, remainingCents: 0 });
    const third = await call("/v1/giftcards/charge", { checkoutId: "chk-1", gan: GAN, idempotencyKey: "key-3" });
    expect(third.body.error.code).toBe("already_covered");
  });

  it("rejects other devices' checkouts, inactive and empty cards", async () => {
    mockSquare();
    await seedCheckout();
    const body = { checkoutId: "chk-1", gan: GAN, idempotencyKey: "key-1" };
    const foreign = await call("/v1/giftcards/charge", body, { device: "kiosk-b" });
    expect(foreign.status).toBe(404);
    expect(foreign.body.error.code).toBe("checkout_not_found");

    mockSquare({ "POST /v2/gift-cards/from-gan": () => ({ body: card({ state: "BLOCKED" }) }) });
    const inactive = await call("/v1/giftcards/charge", body);
    expect(inactive.status).toBe(409);
    expect(inactive.body.error.code).toBe("giftcard_inactive");

    mockSquare({ "POST /v2/gift-cards/from-gan": () => ({ body: card({ balance_money: { amount: 0 } }) }) });
    const empty = await call("/v1/giftcards/charge", body);
    expect(empty.body.error.code).toBe("giftcard_empty");
    expect(callsTo("POST", "/v2/payments")).toHaveLength(0);
  });
});

describe("POST /v1/checkout/complete", () => {
  it("pays the order, verifies it and marks gift payments completed", async () => {
    mockSquare();
    await seedCheckout();
    await call("/v1/giftcards/charge", { checkoutId: "chk-1", gan: GAN, idempotencyKey: "key-1" });
    const body = { checkoutId: "chk-1", paymentIds: ["PAY-GIFT", "PAY-CARD"], idempotencyKey: "done-1" };
    const result = await call("/v1/checkout/complete", body);
    expect(result).toMatchObject({ status: 200, body: { status: "completed" } });
    expect(callsTo("POST", "/v2/orders/ORDER-1/pay")[0].body).toEqual({ idempotency_key: "done-1", payment_ids: ["PAY-GIFT", "PAY-CARD"] });
    expect((await giftRow("PAY-GIFT"))?.status).toBe("completed");
    const again = await call("/v1/checkout/complete", body);
    expect(again.body).toEqual({ status: "completed" });
    expect(callsTo("POST", "/v2/orders/ORDER-1/pay")).toHaveLength(1);
  });

  it("maps an underpayment to amount_mismatch", async () => {
    mockSquare({ "POST /v2/orders/ORDER-1/pay": () => squareError(400, "ORDER_TOTAL_MISMATCH") });
    await seedCheckout();
    const result = await call("/v1/checkout/complete", { checkoutId: "chk-1", paymentIds: ["PAY-GIFT"], idempotencyKey: "done-1" });
    expect(result.status).toBe(409);
    expect(result.body.error.code).toBe("amount_mismatch");
  });

  it("falls back to tenders when the order has no net amount due", async () => {
    mockSquare({ "GET /v2/orders/ORDER-1": () => ({ body: { order: { total_money: { amount: 900 }, tenders: [{ amount_money: { amount: 500 } }, { amount_money: { amount: 400 } }] } } }) });
    await seedCheckout();
    const ok = await call("/v1/checkout/complete", { checkoutId: "chk-1", paymentIds: ["A", "B"], idempotencyKey: "done-1" });
    expect(ok.body.status).toBe("completed");
  });

  it("refuses when Square still shows an amount due", async () => {
    mockSquare({ "GET /v2/orders/ORDER-1": () => ({ body: { order: { total_money: { amount: 900 }, net_amount_due_money: { amount: 400 } } } }) });
    await seedCheckout();
    const result = await call("/v1/checkout/complete", { checkoutId: "chk-1", paymentIds: ["A"], idempotencyKey: "done-1" });
    expect(result.status).toBe(409);
    expect(result.body.error.code).toBe("order_unpaid");
  });

  it("validates the payment id list", async () => {
    mockSquare();
    await seedCheckout();
    expect((await call("/v1/checkout/complete", { checkoutId: "chk-1", paymentIds: [], idempotencyKey: "k" })).status).toBe(400);
    expect((await call("/v1/checkout/complete", { checkoutId: "chk-1", paymentIds: ["a", "b", "c", "d"], idempotencyKey: "k" })).status).toBe(400);
  });
});

describe("POST /v1/checkout/cancel", () => {
  it("cancels listed payments and every held gift card payment", async () => {
    mockSquare({ "POST /v2/payments/:id/cancel": () => ({ body: { payment: { status: "CANCELED" } } }) });
    await seedCheckout();
    await call("/v1/giftcards/charge", { checkoutId: "chk-1", gan: GAN, idempotencyKey: "key-1" });
    const result = await call("/v1/checkout/cancel", { checkoutId: "chk-1", paymentIds: ["PAY-CARD"] });
    expect(result.status).toBe(200);
    expect(result.body.canceled.sort()).toEqual(["PAY-CARD", "PAY-GIFT"]);
    expect((await giftRow("PAY-GIFT"))?.status).toBe("canceled");
  });

  it("tolerates payments that are already canceled or completed", async () => {
    mockSquare({
      "POST /v2/payments/:id/cancel": () => squareError(400, "INVALID_PAYMENT_STATE"),
      "GET /v2/payments/PAY-OLD": () => ({ body: { payment: { status: "CANCELED" } } }),
      "GET /v2/payments/PAY-GIFT": () => ({ body: { payment: { status: "COMPLETED" } } }),
    });
    await seedCheckout();
    await call("/v1/giftcards/charge", { checkoutId: "chk-1", gan: GAN, idempotencyKey: "key-1" });
    const result = await call("/v1/checkout/cancel", { checkoutId: "chk-1", paymentIds: ["PAY-OLD"] });
    expect(result).toMatchObject({ status: 200, body: { canceled: ["PAY-OLD"] } });
    expect((await giftRow("PAY-GIFT"))?.status).toBe("completed");
  });

  it("is retryable when Square is down", async () => {
    mockSquare({ "POST /v2/payments/:id/cancel": () => squareError(503, "SERVICE_UNAVAILABLE") });
    await seedCheckout();
    await call("/v1/giftcards/charge", { checkoutId: "chk-1", gan: GAN, idempotencyKey: "key-1" });
    const result = await call("/v1/checkout/cancel", { checkoutId: "chk-1" });
    expect(result.status).toBe(503);
    expect((await giftRow("PAY-GIFT"))?.status).toBe("approved");
  });
});

describe("stale hold sweep", () => {
  async function scheduled(cron: string) {
    const ctx = createExecutionContext();
    await worker.scheduled(createScheduledController({ cron }), configured, ctx);
    await waitOnExecutionContext(ctx);
  }

  it("cancels holds older than 15 minutes on the frequent cron only", async () => {
    mockSquare({ "POST /v2/payments/:id/cancel": () => ({ body: { payment: { status: "CANCELED" } } }) });
    const insert = (id: string, status: string, age: number) =>
      env.DB.prepare("INSERT INTO giftcard_payments (payment_id, checkout_id, device, idempotency_key, gan_last4, approved_cents, status, created_at, updated_at, card_id) VALUES (?, 'chk-1', 'kiosk-a', ?, '1234', 100, ?, ?, ?, 'gftc:abc')").bind(id, `k-${id}`, status, Date.now() - age, Date.now() - age);
    await env.DB.batch([insert("OLD", "approved", 16 * 60_000), insert("NEW", "approved", 5 * 60_000), insert("DONE", "completed", 60 * 60_000)]);
    await scheduled("*/10 * * * *");
    expect(callsTo("POST", "/v2/payments/OLD/cancel")).toHaveLength(1);
    expect(calls.filter((c) => c.path.endsWith("/cancel"))).toHaveLength(1);
    expect((await giftRow("OLD"))?.status).toBe("canceled");
    expect((await giftRow("NEW"))?.status).toBe("approved");
  });

  it("settles stale pending rows by re-issuing the payment with its idempotency key", async () => {
    await seedCheckout();
    mockSquare({ "POST /v2/payments/:id/cancel": () => ({ body: { payment: { status: "CANCELED" } } }) });
    await env.DB.prepare("INSERT INTO giftcard_payments (payment_id, checkout_id, device, idempotency_key, gan_last4, approved_cents, status, created_at, updated_at, card_id) VALUES (NULL, 'chk-1', 'kiosk-a', 'k-PEND', '1234', 900, 'pending', ?, ?, 'gftc:abc')").bind(Date.now() - 20 * 60_000, Date.now() - 20 * 60_000).run();
    await scheduled("*/10 * * * *");
    expect(callsTo("POST", "/v2/payments")[0].body).toMatchObject({ idempotency_key: "k-PEND", source_id: "gftc:abc", amount_money: { amount: 900 } });
    expect(callsTo("POST", "/v2/payments/PAY-GIFT/cancel")).toHaveLength(1);
    const row = await env.DB.prepare("SELECT payment_id, status FROM giftcard_payments WHERE idempotency_key = 'k-PEND'").first();
    expect(row).toEqual({ payment_id: "PAY-GIFT", status: "canceled" });
  });

  it("marks a pending row dead when Square refuses the re-issued payment, and leaves it on outages", async () => {
    await seedCheckout();
    await env.DB.prepare("INSERT INTO giftcard_payments (payment_id, checkout_id, device, idempotency_key, gan_last4, approved_cents, status, created_at, updated_at, card_id) VALUES (NULL, 'chk-1', 'kiosk-a', 'k-PEND', '1234', 900, 'pending', ?, ?, 'gftc:abc')").bind(Date.now() - 20 * 60_000, Date.now() - 20 * 60_000).run();
    const state = () => env.DB.prepare("SELECT status FROM giftcard_payments WHERE idempotency_key = 'k-PEND'").first<{ status: string }>();
    mockSquare({ "POST /v2/payments": () => squareError(503, "SERVICE_UNAVAILABLE") });
    await scheduled("*/10 * * * *");
    expect((await state())?.status).toBe("pending");
    mockSquare({ "POST /v2/payments": () => squareError(400, "ORDER_CLOSED") });
    await scheduled("*/10 * * * *");
    expect((await state())?.status).toBe("canceled");
  });
});

describe("receipt tenders", () => {
  const record = (overrides: Partial<ReceiptRecord>): ReceiptRecord => ({
    source: "order", id: "o", orderNumber: 1, orderRef: null, customerName: "Alex", totalCents: 900, subtotalCents: 900, taxCents: 0,
    card: "Visa 4242 + Gift card 1234", simulated: false, paidAt: Date.now(), squarePaymentId: null, giftCardCents: 500, giftCardLast4: "1234",
    donationCents: 0, items: [{ vessel: "cup", flavors: ["vanilla"], toppings: [] }], lines: [], paid: true, canceled: false, ...overrides,
  });

  it("shows both tenders for a split payment", () => {
    const html = receiptPage(record({}), null);
    expect(html).toContain("Gift card ••1234");
    expect(html).toContain("$5.00");
    expect(html).toContain("Visa 4242");
    expect(html).toContain("$4.00");
  });

  it("shows only the gift card when it covers everything, and the plain line otherwise", () => {
    const only = receiptPage(record({ totalCents: 500, card: "Gift card 1234" }), null);
    expect(only).toContain("Gift card ••1234");
    expect(only).not.toContain("Paid by");
    expect(receiptPage(record({ giftCardCents: 0, giftCardLast4: null, card: "Visa 1111" }), null)).toContain("Paid by Visa 1111");
  });
});

describe("orders carry gift card fields", () => {
  it("stores them", async () => {
    const order = {
      id: "ord-gc-1", totalCents: 900, squarePaymentId: "PAY-CARD", card: "Visa 4242 + Gift card 1234", giftCardPaymentId: "PAY-GIFT", giftCardCents: 500, giftCardLast4: "1234",
      items: [{ vessel: "cup", flavors: ["vanilla"] }],
    };
    const result = await call("/v1/orders", { orders: [order] });
    expect(result.body.results[0].status).toBe("ok");
    const row = await env.DB.prepare("SELECT gift_card_payment_id, gift_card_cents, gift_card_last4 FROM orders WHERE id = 'ord-gc-1'").first();
    expect(row).toEqual({ gift_card_payment_id: "PAY-GIFT", gift_card_cents: 500, gift_card_last4: "1234" });
    const bad = await call("/v1/orders", { orders: [{ ...order, id: "ord-gc-2", giftCardCents: -1 }] });
    expect(bad.body.results[0].status).toBe("rejected");
  });
});
