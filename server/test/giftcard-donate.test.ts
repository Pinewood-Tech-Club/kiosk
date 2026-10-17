import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker from "../src";
import { refreshDonationOrgs, setFeatured, storedDonationOrgs } from "../src/giftcard-donate";

const BASE = "https://booth.test";
const GAN = "7783320000001234";
const configured = { ...env, SQUARE_ACCESS_TOKEN: "EAAA-static" } as Env;

const category = (id: string, name: string) => ({ type: "CATEGORY", id, category_data: { name } });
const donation = (itemId: string, variationId: string, categoryId: string | null, pricing = "VARIABLE_PRICING") => ({
  type: "ITEM",
  id: itemId,
  item_data: {
    name: "Donation",
    reporting_category: categoryId ? { id: categoryId } : undefined,
    variations: [{ type: "ITEM_VARIATION", id: variationId, item_variation_data: { pricing_type: pricing, sellable: true } }],
  },
});

let catalog: unknown[] = [];
let balance = 2000;
let paymentError: { status: number; code: string } | null = null;
let orderTotal: ((amount: number) => number) | null = null;
const calls: { method: string; path: string; body: any }[] = [];
const paid = new Set<string>();

function mockSquare() {
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url);
    const method = init?.method ?? "GET";
    const body = init?.body ? JSON.parse(String(init.body)) : null;
    calls.push({ method, path: url.pathname, body });
    if (url.pathname === "/v2/locations") return Response.json({ locations: [{ id: "LOC1", name: "Booth", status: "ACTIVE", capabilities: ["CREDIT_CARD_PROCESSING"] }] });
    if (url.pathname === "/v2/catalog/list") {
      const page = url.searchParams.get("cursor") === "p2" ? catalog.slice(2) : catalog.slice(0, 2);
      return Response.json({ objects: page, ...(url.searchParams.get("cursor") ? {} : { cursor: catalog.length > 2 ? "p2" : "" }) });
    }
    if (url.pathname === "/v2/gift-cards/from-gan") return Response.json({ gift_card: { id: "gftc:abc", state: "ACTIVE", balance_money: { amount: balance, currency: "USD" }, gan: GAN } });
    if (url.pathname === "/v2/orders" && method === "POST") {
      const amount = body.order.line_items[0].base_price_money.amount;
      return Response.json({ order: { id: `ORDER-${body.idempotency_key}`, version: 1, total_money: { amount: orderTotal ? orderTotal(amount) : amount, currency: "USD" } } });
    }
    if (url.pathname.startsWith("/v2/orders/") && method === "PUT") return Response.json({ order: { id: url.pathname.split("/").pop(), state: "CANCELED" } });
    if (url.pathname === "/v2/payments" && method === "POST") {
      if (paymentError) return Response.json({ errors: [{ code: paymentError.code, category: "PAYMENT_METHOD_ERROR" }] }, { status: paymentError.status });
      if (!paid.has(body.idempotency_key)) balance -= body.amount_money.amount;
      paid.add(body.idempotency_key);
      return Response.json({ payment: { id: `PAY-${body.idempotency_key}`, status: "COMPLETED", amount_money: body.amount_money } });
    }
    return Response.json({ errors: [{ code: "NOT_FOUND" }] }, { status: 404 });
  });
}

async function send(path: string, init: RequestInit = {}) {
  const ctx = createExecutionContext();
  const response = await worker.fetch(new Request(`${BASE}${path}`, init) as Request<unknown, IncomingRequestCfProperties>, configured, ctx);
  await waitOnExecutionContext(ctx);
  return response;
}

async function donate(body: Record<string, unknown>, headers: Record<string, string> = {}) {
  const response = await send("/giftcard/donate", { method: "POST", headers: { "Content-Type": "application/json", ...headers }, body: JSON.stringify(body) });
  return { status: response.status, body: (await response.json()) as any };
}

const request = (overrides: Record<string, unknown> = {}) => ({ gan: GAN, variationId: "VAR-TECH", amountCents: 500, idempotencyKey: crypto.randomUUID(), ...overrides });
const squareCalls = (path: string, method = "POST") => calls.filter((c) => c.path === path && c.method === method);

beforeEach(async () => {
  await env.DB.batch(["giftcard_donations", "square_cache", "giftcard_lookup_failures"].map((t) => env.DB.prepare(`DELETE FROM ${t}`)));
  catalog = [category("C1", "Tech Club"), category("C2", "Math Club"), donation("I1", "VAR-TECH", "C1"), donation("I2", "VAR-MATH", "C2")];
  balance = 2000;
  paymentError = null;
  orderTotal = null;
  calls.length = 0;
  paid.clear();
  mockSquare();
  await refreshDonationOrgs(configured, "test");
  calls.length = 0;
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe("donation organizations", () => {
  it("stores every Donation item with a variable price, named by its reporting category", async () => {
    catalog = [
      category("C1", "Tech Club"),
      category("C2", "Robotics"),
      donation("I1", "VAR-TECH", "C1"),
      donation("I2", "VAR-ROBO", "C2"),
      donation("I3", "VAR-ROBO2", "C2"),
      donation("I4", "VAR-FIXED", "C1", "FIXED_PRICING"),
      donation("I5", "VAR-NOCAT", null),
      { type: "ITEM", id: "I6", item_data: { name: "Donation Box", variations: [{ id: "VAR-BOX", item_variation_data: { pricing_type: "VARIABLE_PRICING" } }] } },
    ];
    const list = await refreshDonationOrgs(configured, "test");
    expect(list.orgs.map((o) => o.name)).toEqual(["Robotics", "Robotics", "Tech Club"]);
    expect(list.duplicates).toEqual(["Robotics"]);
    expect(list.skipped.map((s) => s.itemId).sort()).toEqual(["I4", "I5"]);
  });

  it("keeps the featured order across refreshes and reports featured orgs that vanished", async () => {
    await setFeatured(configured, ["VAR-MATH", "VAR-TECH"]);
    catalog = [category("C1", "Tech Club"), donation("I1", "VAR-TECH", "C1")];
    const list = await refreshDonationOrgs(configured, "test");
    expect(list.droppedFeatured).toEqual([{ id: "VAR-MATH", name: "Math Club" }]);
    const response = await send("/giftcard/orgs");
    expect(await response.json()).toEqual({ orgs: [{ id: "VAR-TECH", name: "Tech Club" }], featured: ["VAR-TECH"] });
  });

  it("refuses to feature an org that isn't in the stored list", async () => {
    await expect(setFeatured(configured, ["VAR-NOPE"])).rejects.toThrow(/Not in the stored list/);
  });

  it("inlines the stored list into the page so the picker opens without loading", async () => {
    await setFeatured(configured, ["VAR-MATH"]);
    const page = await (await send("/giftcard")).text();
    expect(page).toContain('const ORGS_INIT = {"orgs":[{"id":"VAR-MATH","name":"Math Club"},{"id":"VAR-TECH","name":"Tech Club"}],"featured":["VAR-MATH"]};');
    expect(squareCalls("/v2/catalog/list", "GET")).toHaveLength(0);
  });
});

describe("POST /giftcard/donate", () => {
  it("creates an order for the donation item at the given price and pays it from the gift card", async () => {
    const result = await donate(request({ gan: `sqgc://7783 3200 0000 1234`, amountCents: 750 }));
    expect(result.status).toBe(200);
    expect(result.body).toEqual({ ok: true, balanceCents: 1250 });
    const [order] = squareCalls("/v2/orders");
    expect(order.body.order.location_id).toBe("LOC1");
    expect(order.body.order.line_items).toEqual([{ catalog_object_id: "VAR-TECH", quantity: "1", base_price_money: { amount: 750, currency: "USD" } }]);
    const [payment] = squareCalls("/v2/payments");
    expect(payment.body).toMatchObject({ source_id: "gftc:abc", amount_money: { amount: 750, currency: "USD" }, order_id: order.body.idempotency_key && `ORDER-${order.body.idempotency_key}`, autocomplete: true });
    const row = await env.DB.prepare("SELECT status, gan_last4, org_name FROM giftcard_donations").first();
    expect(row).toEqual({ status: "completed", gan_last4: "1234", org_name: "Tech Club" });
  });

  it("rejects an amount above the balance before creating anything", async () => {
    const result = await donate(request({ amountCents: 2001 }));
    expect(result.status).toBe(409);
    expect(result.body.error.code).toBe("insufficient_balance");
    expect(squareCalls("/v2/orders")).toHaveLength(0);
    expect(squareCalls("/v2/payments")).toHaveLength(0);
  });

  it("rejects a variation that isn't a stored Donation item", async () => {
    const result = await donate(request({ variationId: "VAR-SCOOP" }));
    expect(result.status).toBe(400);
    expect(result.body.error.code).toBe("unknown_organization");
    expect(calls.some((c) => c.path.startsWith("/v2/orders") || c.path.startsWith("/v2/gift-cards"))).toBe(false);
  });

  it("rejects malformed requests", async () => {
    expect((await donate(request({ amountCents: 0 }))).status).toBe(400);
    expect((await donate(request({ amountCents: 1.5 }))).status).toBe(400);
    expect((await donate(request({ idempotencyKey: "short" }))).status).toBe(400);
    expect((await donate(request({ gan: "12ab" }))).status).toBe(400);
    expect(squareCalls("/v2/payments")).toHaveLength(0);
  });

  it("charges once when the same confirm is sent twice", async () => {
    const body = request({ amountCents: 2000 });
    const first = await donate(body);
    const second = await donate(body);
    expect(first.status).toBe(200);
    expect(second.body).toEqual(first.body);
    expect(squareCalls("/v2/payments")).toHaveLength(1);
    expect(squareCalls("/v2/orders")).toHaveLength(1);
    expect(balance).toBe(0);
  });

  it("refuses to reuse an idempotency key for a different donation", async () => {
    const body = request();
    await donate(body);
    const result = await donate({ ...body, amountCents: 600 });
    expect(result.status).toBe(409);
    expect(result.body.error.code).toBe("conflict");
  });

  it("cancels the order and moves no money when the gift card payment is declined", async () => {
    paymentError = { status: 400, code: "GIFT_CARD_AVAILABLE_AMOUNT" };
    const body = request();
    const result = await donate(body);
    expect(result.status).toBe(409);
    expect(result.body.error.code).toBe("insufficient_balance");
    const [cancel] = squareCalls(`/v2/orders/ORDER-gd-${calls.find((c) => c.path === "/v2/orders")!.body.idempotency_key.slice(3)}`, "PUT");
    expect(cancel.body.order.state).toBe("CANCELED");
    expect(balance).toBe(2000);
    expect((await env.DB.prepare("SELECT status FROM giftcard_donations").first())!.status).toBe("failed");
    paymentError = null;
    const again = await donate(body);
    expect(again.status).toBe(409);
    expect(again.body.error.code).toBe("donation_failed");
    expect(squareCalls("/v2/payments")).toHaveLength(1);
  });

  it("never pays an order whose total differs from the amount", async () => {
    orderTotal = (amount) => amount + 45;
    const result = await donate(request());
    expect(result.status).toBe(502);
    expect(squareCalls("/v2/payments")).toHaveLength(0);
    expect(calls.some((c) => c.method === "PUT" && c.body.order.state === "CANCELED")).toBe(true);
  });

  it("answers unconfirmed when Square can't be reached for the payment, and a retry with the key settles it", async () => {
    paymentError = { status: 503, code: "SERVICE_UNAVAILABLE" };
    const body = request();
    const first = await donate(body);
    expect(first.status).toBe(503);
    expect(first.body.error.code).toBe("donation_unconfirmed");
    paymentError = null;
    const second = await donate(body);
    expect(second.status).toBe(200);
    expect(second.body).toEqual({ ok: true, balanceCents: 1500 });
  });

  it("refuses cross-origin posts", async () => {
    expect((await donate(request(), { Origin: "https://evil.example" })).status).toBe(403);
  });

  it("is not rate limited", async () => {
    for (let i = 0; i < 12; i++) expect((await donate(request({ amountCents: 100 }))).status).toBe(200);
  });

  it("exposes the stored list after a refresh", async () => {
    expect((await storedDonationOrgs(configured))!.orgs).toHaveLength(2);
  });
});
