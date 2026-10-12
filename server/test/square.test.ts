import { createExecutionContext, createScheduledController, waitOnExecutionContext } from "cloudflare:test";
import { env, exports } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker from "../src";
import { buildCatalog, clearCatalogMemory } from "../src/catalog";
import { REFRESH_AFTER_MS, STATE_TTL_MS } from "../src/oauth";
import { adHocLineItems, catalogLineItems, chargedLines, pricingMismatch, quote, scoopsTotal, type CartItem } from "../src/pricing";
import type { ServerMessage } from "../src/protocol";
import { itemPrices } from "../src/receipts";

const KIOSK = "test-kiosk-token";
const STAFF = "test-staff-token";
const BASE = "https://booth.test";
const DAY = 24 * 60 * 60_000;

interface SquareCall {
  path: string;
  body: any;
  authorization: string | null;
}

type Handler = (body: any) => { status?: number; body: unknown };

let calls: SquareCall[] = [];

const variations: Record<string, { name: string; cents: number }> = {
  V1: { name: "1 Scoop", cents: 400 },
  V2: { name: "2nd Scoop", cents: 300 },
  V3: { name: "3rd+ Scoop", cents: 200 },
  VC: { name: "Waffle Cone", cents: 150 },
  VT: { name: "Topping", cents: 50 },
};

function catalogItems(only = Object.keys(variations)) {
  return only.map((id) => ({
    id: `I-${id}`,
    item_data: {
      name: variations[id].name,
      variations: [{ id, item_variation_data: { pricing_type: "FIXED_PRICING", price_money: { amount: variations[id].cents, currency: "USD" } } }],
    },
  }));
}

function echoOrder(body: any) {
  const order = body.order;
  const lineItems = order.line_items.map((item: any) => {
    const base = item.catalog_object_id ? variations[item.catalog_object_id].cents : item.base_price_money.amount;
    const modifiers = (item.modifiers ?? []).reduce((sum: number, m: any) => sum + m.base_price_money.amount * Number(m.quantity ?? "1"), 0);
    return {
      name: item.catalog_object_id ? variations[item.catalog_object_id].name : item.name,
      note: item.note,
      quantity: item.quantity,
      base_price_money: { amount: base },
      total_money: { amount: base + modifiers },
      modifiers: item.modifiers,
    };
  });
  const total = lineItems.reduce((sum: number, l: any) => sum + l.total_money.amount, 0);
  return { body: { order: { id: `SQ-${body.idempotency_key}`, total_money: { amount: total }, total_tax_money: { amount: 0 }, line_items: lineItems } } };
}

const defaultHandlers: Record<string, Handler> = {
  "/oauth2/token": (body) => {
    if (body.grant_type === "authorization_code" && body.code === "good-code") {
      return { body: { access_token: "EAAA-access-1", refresh_token: "EQAA-refresh-1", expires_at: new Date(Date.now() + 30 * DAY).toISOString(), merchant_id: "M1" } };
    }
    if (body.grant_type === "refresh_token" && body.refresh_token === "EQAA-refresh-1") {
      return { body: { access_token: "EAAA-access-2", refresh_token: "EQAA-refresh-1", expires_at: new Date(Date.now() + 30 * DAY).toISOString(), merchant_id: "M1" } };
    }
    return { status: 401, body: { message: "bad grant", type: "service.unauthorized" } };
  },
  "/oauth2/revoke": () => ({ body: { success: true } }),
  "/v2/locations": () => ({
    body: {
      locations: [
        { id: "LOC0", name: "Closed", status: "INACTIVE", capabilities: [] },
        { id: "LOC1", name: "Booth", business_name: "Tech Club", status: "ACTIVE", capabilities: ["CREDIT_CARD_PROCESSING"] },
      ],
    },
  }),
  "/v2/catalog/search": () => ({ body: { objects: [{ id: "CAT", type: "CATEGORY", category_data: { name: "TC" } }] } }),
  "/v2/catalog/search-catalog-items": () => ({ body: { items: catalogItems() } }),
  "/v2/orders": echoOrder,
};

function mockSquare(overrides: Record<string, Handler> = {}) {
  const handlers = { ...defaultHandlers, ...overrides };
  calls = [];
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url);
    if (!url.hostname.endsWith("squareup.com") && !url.hostname.endsWith("squareupsandbox.com")) throw new Error(`Unexpected fetch ${url}`);
    const body = init?.body ? JSON.parse(String(init.body)) : undefined;
    calls.push({ path: url.pathname, body, authorization: new Headers(init?.headers).get("Authorization") });
    const handler = handlers[url.pathname];
    if (!handler) return Response.json({ errors: [{ code: "NOT_FOUND", detail: "no mock" }] }, { status: 404 });
    const result = handler(body);
    return Response.json(result.body, { status: result.status ?? 200 });
  });
}

const callsTo = (path: string) => calls.filter((c) => c.path === path);

async function call(path: string, init: RequestInit & { token?: string; device?: string; json?: unknown } = {}, environment: Env = env) {
  const headers = new Headers(init.headers);
  if (init.token) headers.set("Authorization", `Bearer ${init.token}`);
  if (init.token || init.device) headers.set("X-Booth-Device", init.device ?? "test-device");
  if (init.json !== undefined) headers.set("Content-Type", "application/json");
  const request = new Request(`${BASE}${path}`, {
    method: init.method ?? (init.json !== undefined ? "POST" : "GET"),
    headers,
    body: init.json !== undefined ? JSON.stringify(init.json) : init.body,
    redirect: "manual",
  });
  const ctx = createExecutionContext();
  const response = await worker.fetch(request as Request<unknown, IncomingRequestCfProperties>, environment, ctx);
  await waitOnExecutionContext(ctx);
  const text = await response.text();
  let body: any = text;
  try {
    body = JSON.parse(text);
  } catch {}
  return { status: response.status, body, headers: response.headers };
}

async function connectSquare() {
  const started = await call("/v1/square/oauth/start", { method: "POST", token: STAFF });
  expect(started.status).toBe(200);
  const state = new URL(started.body.url).searchParams.get("state")!;
  const callback = await call(`/v1/square/oauth/callback?code=good-code&response_type=code&state=${state}`);
  expect(callback.status).toBe(200);
  return state;
}

const randomReceipt = () => crypto.randomUUID().replace(/-/g, "").slice(0, 22);

function cart(overrides: Record<string, unknown> = {}) {
  return {
    id: crypto.randomUUID(),
    receiptToken: randomReceipt(),
    orderNumber: 12,
    customerName: "Alex",
    sourceName: "Tech Club Ice Cream Kiosk",
    quotedCents: 1100,
    items: [
      { vessel: "cone", flavors: ["vanilla", "chocolate"], toppings: ["whip"] },
      { vessel: "cup", flavors: ["cookies"] },
    ],
    ...overrides,
  };
}

beforeEach(async () => {
  clearCatalogMemory();
  await env.DB.batch(["square_tokens", "oauth_states", "square_cache", "checkouts"].map((t) => env.DB.prepare(`DELETE FROM ${t}`)));
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe("pricing", () => {
  const item = (vessel: "cup" | "cone", flavors: string[], toppings: string[] = []): CartItem => ({ vessel, flavors, toppings });

  it("prices scoops by their position in the whole order, like the app", () => {
    expect([1, 2, 3, 4, 5].map(scoopsTotal)).toEqual([400, 700, 900, 1100, 1300]);
    expect(quote([item("cup", ["vanilla"])]).totalCents).toBe(400);
    expect(quote([item("cone", ["vanilla", "chocolate"])]).totalCents).toBe(850);
    const q = quote([item("cone", ["vanilla", "chocolate"], ["whip"]), item("cup", ["cookies", "cookies", "vanilla"], ["gummies", "mms"])]);
    expect(q.lines.map((l) => l.scoopShareCents)).toEqual([700, 600]);
    expect(q.lines.map((l) => l.totalCents)).toEqual([900, 700]);
    expect(q.totalCents).toBe(1600);
    expect(q.scoopCount).toBe(5);
  });

  it("builds catalog lines, ad-hoc lines and receipt lines that agree", () => {
    const catalog = buildCatalog("TC", catalogItems());
    expect(pricingMismatch(catalog)).toBeNull();
    const q = quote([item("cone", ["vanilla", "chocolate"], ["sprinkles"]), item("cup", ["cookies"])]);
    expect(catalogLineItems(q, catalog)).toEqual([
      { catalog_object_id: "V1", quantity: "1", note: "#1 Waffle Cone: Vanilla" },
      { catalog_object_id: "V2", quantity: "1", note: "#1 Waffle Cone: Chocolate" },
      { catalog_object_id: "VC", quantity: "1", note: "#1" },
      { catalog_object_id: "VT", quantity: "1", note: "#1 Waffle Cone: Sprinkles" },
      { catalog_object_id: "V3", quantity: "1", note: "#2 Cup: Cookies & Cream" },
    ]);
    expect(chargedLines(q).map((l) => [l.title, l.detail, l.cents])).toEqual([
      ["1 Scoop", "#1 Waffle Cone: Vanilla", 400],
      ["2nd Scoop", "#1 Waffle Cone: Chocolate", 300],
      ["Waffle Cone", "#1", 150],
      ["Topping", "#1 Waffle Cone: Sprinkles", 50],
      ["3rd+ Scoop", "#2 Cup: Cookies & Cream", 200],
    ]);
    const adHoc = adHocLineItems(q);
    const adHocTotal = adHoc.reduce((sum, line: any) => sum + line.base_price_money.amount + line.modifiers.reduce((s: number, m: any) => s + m.base_price_money.amount, 0), 0);
    expect(adHocTotal).toBe(q.totalCents);
  });

  it("bills both syrups on one item as separate toppings, by name", () => {
    const catalog = buildCatalog("TC", catalogItems());
    const q = quote([item("cup", ["vanilla"], ["chocolate", "caramel", "gummies"])]);
    expect(q.totalCents).toBe(550);
    expect(catalogLineItems(q, catalog).filter((l) => l.catalog_object_id === "VT").map((l) => l.note)).toEqual([
      "#1 Cup: Chocolate Syrup", "#1 Cup: Caramel Syrup", "#1 Cup: Gummy Bears",
    ]);
    expect(chargedLines(q).filter((l) => l.title === "Topping").map((l) => [l.detail, l.cents])).toEqual([
      ["#1 Cup: Chocolate Syrup", 50], ["#1 Cup: Caramel Syrup", 50], ["#1 Cup: Gummy Bears", 50],
    ]);
  });

  it("rejects catalogs that are incomplete or priced differently", () => {
    expect(() => buildCatalog("TC", catalogItems(["V1", "V2", "V3", "VC"]))).toThrow(/missing item\(s\): Topping/);
    const expensive = buildCatalog("TC", catalogItems().map((i) => (i.id === "I-V3" ? { ...i, item_data: { ...i.item_data, variations: [{ ...i.item_data.variations[0], item_variation_data: { pricing_type: "FIXED_PRICING", price_money: { amount: 250 } } }] } } : i)));
    expect(pricingMismatch(expensive)).toMatch(/3 scoops/);
  });
});

describe("Square OAuth", () => {
  it("reports not configured cleanly instead of failing", async () => {
    const bare = { ...env, SQUARE_APPLICATION_ID: undefined, SQUARE_APPLICATION_SECRET: undefined, SQUARE_ACCESS_TOKEN: undefined } as Env;
    const start = await call("/v1/square/oauth/start", { method: "POST", token: STAFF }, bare);
    expect(start.status).toBe(503);
    expect(start.body.error).toMatchObject({ code: "not_configured", retryable: false });
    const credentials = await call("/v1/square/credentials", { token: KIOSK }, bare);
    expect(credentials.status).toBe(503);
    expect(credentials.body.error.code).toBe("not_configured");
    const status = await call("/v1/square/status", { token: STAFF }, bare);
    expect(status.body).toMatchObject({ oauthConfigured: false, connected: false, source: null, staticTokenConfigured: false });
    const checkout = await call("/v1/checkout", { token: KIOSK, json: cart() }, bare);
    expect(checkout.status).toBe(503);
    expect(checkout.body.error.code).toBe("not_configured");
  });

  it("only lets staff start the flow and builds the authorize URL", async () => {
    expect((await call("/v1/square/oauth/start", { method: "POST" })).status).toBe(401);
    expect((await call("/v1/square/oauth/start", { method: "POST", token: KIOSK })).status).toBe(403);
    const started = await call("/v1/square/oauth/start", { method: "POST", token: STAFF });
    const url = new URL(started.body.url);
    expect(url.origin + url.pathname).toBe("https://connect.squareup.com/oauth2/authorize");
    expect(url.searchParams.get("client_id")).toBe("sq0idp-test-app");
    expect(url.searchParams.get("scope")).toContain("PAYMENTS_WRITE_IN_PERSON");
    expect(url.searchParams.get("session")).toBe("false");
    expect(url.searchParams.get("state")!.length).toBeGreaterThanOrEqual(32);
    expect(started.body.redirectUrl).toBe(`${BASE}/v1/square/oauth/callback`);
    const redirect = await call("/v1/square/oauth/start", { token: STAFF });
    expect(redirect.status).toBe(302);
    expect(redirect.headers.get("Location")).toMatch(/^https:\/\/connect\.squareup\.com\/oauth2\/authorize\?/);
  });

  it("accepts each state once, before it expires, and stores the token encrypted", async () => {
    mockSquare();
    expect((await call("/v1/square/oauth/callback?code=good-code&state=made-up")).status).toBe(400);
    const state = await connectSquare();
    const replay = await call(`/v1/square/oauth/callback?code=good-code&state=${state}`);
    expect(replay.status).toBe(400);
    expect(replay.body).toContain("expired or was already used");
    expect(callsTo("/oauth2/token")).toHaveLength(1);
    expect(callsTo("/oauth2/token")[0].body).toMatchObject({ client_id: "sq0idp-test-app", client_secret: "sq0csp-test-secret", grant_type: "authorization_code" });

    const row = await env.DB.prepare("SELECT * FROM square_tokens").first<Record<string, unknown>>();
    expect(row).toMatchObject({ environment: "production", merchant_id: "M1", location_id: "LOC1" });
    expect(String(row!.access_token)).not.toContain("EAAA-access-1");
    expect(String(row!.refresh_token)).not.toContain("EQAA-refresh-1");

    const old = await call("/v1/square/oauth/start", { method: "POST", token: STAFF });
    const oldState = new URL(old.body.url).searchParams.get("state")!;
    await env.DB.prepare("UPDATE oauth_states SET expires_at = ? WHERE state = ?").bind(Date.now() - 1, oldState).run();
    expect((await call(`/v1/square/oauth/callback?code=good-code&state=${oldState}`)).status).toBe(400);
    expect(STATE_TTL_MS).toBeLessThanOrEqual(15 * 60_000);
  });

  it("shows a friendly page when the seller declines", async () => {
    mockSquare();
    const started = await call("/v1/square/oauth/start", { method: "POST", token: STAFF });
    const state = new URL(started.body.url).searchParams.get("state")!;
    const denied = await call(`/v1/square/oauth/callback?error=access_denied&error_description=user_denied&state=${state}`);
    expect(denied.status).toBe(400);
    expect(denied.headers.get("Content-Type")).toContain("text/html");
    expect(denied.body).toContain("user_denied");
    expect(calls).toHaveLength(0);
  });

  it("hands the kiosk the OAuth token, falling back to the static token", async () => {
    mockSquare();
    expect((await call("/v1/square/credentials", { token: STAFF })).status).toBe(403);
    const staticEnv = { ...env, SQUARE_ACCESS_TOKEN: "EAAA-static" } as Env;
    const fallback = await call("/v1/square/credentials", { token: KIOSK }, staticEnv);
    expect(fallback.body).toMatchObject({ accessToken: "EAAA-static", locationId: "LOC1", source: "static", environment: "production", expiresAt: null });

    await connectSquare();
    const credentials = await call("/v1/square/credentials", { token: KIOSK }, staticEnv);
    expect(credentials.body).toMatchObject({ accessToken: "EAAA-access-1", locationId: "LOC1", merchantId: "M1", source: "oauth", applicationId: "sq0idp-test-app" });
    expect(credentials.body.expiresAt).toBeGreaterThan(Date.now() + 29 * DAY);
    expect(credentials.body.fetchAgainAt).toBeLessThanOrEqual(Date.now() + 30 * 60_000);

    const status = await call("/v1/square/status?verify=1", { token: STAFF });
    expect(status.body).toMatchObject({ connected: true, source: "oauth", verified: { ok: true }, oauth: { merchantId: "M1", readable: true, stale: false } });
  });

  it("refreshes on schedule once a token is six days old, and records failures", async () => {
    mockSquare();
    await connectSquare();
    await worker.scheduled(createScheduledController({ cron: "17 9 * * *" }), env, createExecutionContext());
    expect(callsTo("/oauth2/token")).toHaveLength(1);

    await env.DB.prepare("UPDATE square_tokens SET refreshed_at = ?").bind(Date.now() - REFRESH_AFTER_MS - 1000).run();
    const ctx = createExecutionContext();
    await worker.scheduled(createScheduledController({ cron: "17 9 * * *" }), env, ctx);
    await waitOnExecutionContext(ctx);
    expect(callsTo("/oauth2/token").map((c) => c.body.grant_type)).toEqual(["authorization_code", "refresh_token"]);
    expect((await call("/v1/square/credentials", { token: KIOSK })).body.accessToken).toBe("EAAA-access-2");

    mockSquare({ "/oauth2/token": () => ({ status: 500, body: { errors: [{ code: "INTERNAL_SERVER_ERROR", detail: "boom" }] } }) });
    const failed = await call("/v1/square/refresh", { method: "POST", token: STAFF });
    expect(failed.status).toBe(502);
    expect(failed.body.status).toBe("failed");
    const status = await call("/v1/square/status", { token: STAFF });
    expect(status.body.oauth.lastRefreshError).toContain("boom");
    expect((await call("/v1/square/credentials", { token: KIOSK })).body.accessToken).toBe("EAAA-access-2");
  });

  it("refreshes in the background when the kiosk fetches a due token", async () => {
    mockSquare();
    await connectSquare();
    await env.DB.prepare("UPDATE square_tokens SET refreshed_at = ?").bind(Date.now() - 7 * DAY).run();
    const first = await call("/v1/square/credentials", { token: KIOSK });
    expect(first.body.accessToken).toBe("EAAA-access-1");
    expect(callsTo("/oauth2/token").at(-1)!.body.grant_type).toBe("refresh_token");
    expect((await call("/v1/square/credentials", { token: KIOSK })).body.accessToken).toBe("EAAA-access-2");
  });

  it("revokes with the application secret and forgets the token", async () => {
    mockSquare();
    await connectSquare();
    const revoked = await call("/v1/square/revoke", { method: "POST", token: STAFF });
    expect(revoked.body).toMatchObject({ revoked: true, squareRevoked: true });
    const revoke = callsTo("/oauth2/revoke")[0];
    expect(revoke.authorization).toBe("Client sq0csp-test-secret");
    expect(revoke.body).toEqual({ client_id: "sq0idp-test-app", access_token: "EAAA-access-1" });
    expect((await call("/v1/square/credentials", { token: KIOSK })).status).toBe(503);
  });
});

describe("checkout", () => {
  it("creates one Square order per checkout id and replays it", async () => {
    mockSquare();
    await connectSquare();
    const body = cart();
    const first = await call("/v1/checkout", { token: KIOSK, json: body });
    expect(first.status).toBe(200);
    expect(first.body).toMatchObject({
      id: body.id, status: "created", squareOrderId: `SQ-${body.id}`, locationId: "LOC1", referenceId: "kiosk-0012",
      totalCents: 1100, subtotalCents: 1100, expectedSubtotalCents: 1100, priceMatches: true, usedCatalog: true, receiptToken: body.receiptToken,
    });
    expect(first.body.lines.map((l: any) => l.title)).toEqual(["1 Scoop", "2nd Scoop", "Waffle Cone", "Topping", "3rd+ Scoop"]);
    const created = callsTo("/v2/orders")[0].body;
    expect(created.idempotency_key).toBe(body.id);
    expect(created.order).toMatchObject({ location_id: "LOC1", ticket_name: "Alex", reference_id: "kiosk-0012", metadata: { checkout_id: body.id } });
    expect(callsTo("/v2/orders")[0].authorization).toBe("Bearer EAAA-access-1");

    const again = await call("/v1/checkout", { token: KIOSK, json: body });
    expect(again.body).toMatchObject({ status: "duplicate", squareOrderId: first.body.squareOrderId, totalCents: 1100 });
    expect(callsTo("/v2/orders")).toHaveLength(1);

    const changed = await call("/v1/checkout", { token: KIOSK, json: { ...body, items: [{ vessel: "cup", flavors: ["vanilla"] }] } });
    expect(changed.status).toBe(409);
    expect(changed.body.error.code).toBe("conflict");
  });

  it("uses the kiosk's order reference so orders from different kiosks never share one", async () => {
    mockSquare();
    await connectSquare();
    const a = await call("/v1/checkout", { token: KIOSK, json: cart({ orderRef: "3F2A-12" }) });
    const b = await call("/v1/checkout", { token: KIOSK, json: cart({ orderRef: "9C01-12" }) });
    expect([a.body.referenceId, b.body.referenceId]).toEqual(["kiosk-3F2A-12", "kiosk-9C01-12"]);
    expect(callsTo("/v2/orders").map((c) => c.body.order.reference_id)).toEqual(["kiosk-3F2A-12", "kiosk-9C01-12"]);
    expect((await call("/v1/checkout", { token: KIOSK, json: cart({ orderRef: "bad ref!" }) })).status).toBe(400);
  });

  it("reuses the catalog between checkouts", async () => {
    mockSquare();
    await connectSquare();
    await call("/v1/checkout", { token: KIOSK, json: cart() });
    await call("/v1/checkout", { token: KIOSK, json: cart() });
    clearCatalogMemory();
    await call("/v1/checkout", { token: KIOSK, json: cart() });
    expect(callsTo("/v2/catalog/search-catalog-items")).toHaveLength(1);
    expect(callsTo("/v2/orders")).toHaveLength(3);
  });

  it("falls back to ad-hoc lines when the catalog is incomplete", async () => {
    mockSquare({ "/v2/catalog/search-catalog-items": () => ({ body: { items: catalogItems(["V1", "V2", "V3", "VC"]) } }) });
    await connectSquare();
    const result = await call("/v1/checkout", { token: KIOSK, json: cart() });
    expect(result.body).toMatchObject({ usedCatalog: false, totalCents: 1100, priceMatches: true });
    expect(result.body.catalogError).toMatch(/Topping/);
    expect(callsTo("/v2/orders")[0].body.order.line_items[0].name).toBe("Ice cream, 2 scoops");
  });

  it("refuses mismatched locations and maps Square failures to retryable or not", async () => {
    mockSquare();
    await connectSquare();
    const mismatch = await call("/v1/checkout", { token: KIOSK, json: cart({ locationId: "OTHER" }) });
    expect(mismatch.status).toBe(409);
    expect(mismatch.body.error.code).toBe("location_mismatch");

    mockSquare({ "/v2/orders": () => ({ status: 503, body: { errors: [{ code: "SERVICE_UNAVAILABLE" }] } }) });
    const down = await call("/v1/checkout", { token: KIOSK, json: cart() });
    expect(down.status).toBe(503);
    expect(down.body.error.retryable).toBe(true);

    mockSquare({ "/v2/orders": () => ({ status: 401, body: { errors: [{ code: "UNAUTHORIZED", detail: "nope" }] } }) });
    const unauthorized = await call("/v1/checkout", { token: KIOSK, json: cart() });
    expect(unauthorized.status).toBe(502);
    expect(unauthorized.body.error).toMatchObject({ code: "square_unauthorized", retryable: false });
  });

  it("takes a cart whose flavor, cone and topping sold out after they were added", async () => {
    mockSquare();
    await connectSquare();
    const out = (soldOut: boolean) => [
      { id: crypto.randomUUID(), type: "setSupply", kind: "flavor", item: "vanilla", soldOut },
      { id: crypto.randomUUID(), type: "setSupply", kind: "vessel", item: "cone", soldOut },
      { id: crypto.randomUUID(), type: "setSupply", kind: "vessel", item: "cup", soldOut },
      { id: crypto.randomUUID(), type: "setSupply", kind: "topping", item: "gummies", soldOut },
    ];
    const marked = await call("/v1/actions", { token: STAFF, json: { actions: out(true) } });
    expect(marked.body.results.every((r: { status: string }) => r.status === "ok")).toBe(true);
    const body = cart({ items: [{ vessel: "cone", flavors: ["vanilla"], toppings: ["gummies"] }, { vessel: "cup", flavors: ["vanilla"] }] });
    const result = await call("/v1/checkout", { token: KIOSK, json: body });
    expect(result.status).toBe(200);
    expect(result.body).toMatchObject({ status: "created", priceMatches: true });
    await call("/v1/actions", { token: STAFF, json: { actions: out(false) } });
  });

  it("validates the cart", async () => {
    mockSquare();
    await connectSquare();
    const cases = [
      cart({ items: [] }),
      cart({ items: [{ vessel: "bowl", flavors: ["vanilla"] }] }),
      cart({ items: [{ vessel: "cup", flavors: [] }] }),
      cart({ items: [{ vessel: "cup", flavors: ["a", "b", "c", "d"] }] }),
      cart({ receiptToken: "short" }),
      cart({ customerName: "" }),
    ];
    for (const body of cases) expect((await call("/v1/checkout", { token: KIOSK, json: body })).status).toBe(400);
    expect(callsTo("/v2/orders")).toHaveLength(0);
  });
});

describe("receipts", () => {
  it("renders the receipt page, a pending page for unsynced tokens, and 404 for malformed ones", async () => {
    mockSquare({
      "/v2/payments/PAY1abcdefghij": () => ({ body: { payment: { id: "PAY1abcdefghij", receipt_url: "https://squareup.com/receipt/preview/PAY1" } } }),
    });
    await connectSquare();
    const body = cart();
    const unknown = await call(`/r/${randomReceipt()}`);
    expect(unknown.status).toBe(200);
    expect(unknown.body).toContain("Your receipt will appear shortly");
    expect(unknown.body).toContain('http-equiv="refresh"');
    expect(unknown.headers.get("X-Robots-Tag")).toContain("noindex");
    expect(unknown.body).toContain('name="robots" content="noindex');

    const bad = await call("/r/not-a-token!");
    expect(bad.status).toBe(404);
    expect(bad.body).toContain("Receipt not found");
    expect((await call("/r/short")).status).toBe(404);

    await call("/v1/checkout", { token: KIOSK, json: body });
    const pending = await call(`/r/${body.receiptToken}`);
    expect(pending.status).toBe(200);
    expect(pending.body).toContain("Your receipt will appear shortly");

    const paidAt = Date.UTC(2026, 11, 5, 21, 2, 0);
    await call("/v1/orders", {
      token: KIOSK,
      json: {
        orders: [{
          id: body.id, orderNumber: 12, customerName: "Alex <b>", totalCents: 1100, subtotalCents: 1100, taxCents: 0,
          squarePaymentId: "PAY1abcdefghij", card: "Visa 4242", receiptToken: body.receiptToken, items: body.items, orderRef: "3F2A-12",
          paidAt: new Date(paidAt).toISOString(),
        }],
      },
    });
    const paid = await call(`/r/${body.receiptToken}`);
    expect(paid.status).toBe(200);
    expect(paid.headers.get("X-Robots-Tag")).toContain("noindex");
    expect(paid.body).not.toContain('http-equiv="refresh"');
    expect(paid.body).toContain("Tech Club Ice Cream");
    expect(paid.body).toContain("Order 3F2A-12");
    expect(paid.body).toContain("Alex &lt;b&gt;");
    expect(paid.body).toContain("Waffle Cone");
    expect(paid.body).toContain("Vanilla, Chocolate");
    expect(paid.body).toContain("Whipped Cream");
    expect(paid.body).toContain("$11.00");
    expect(paid.body).toContain("Visa 4242");
    expect(paid.body).toContain("December 5, 2026 at 1:02");
    expect(paid.body).toContain("https://squareup.com/receipt/preview/PAY1");
  });

  it("renders the receipt without a Square link when Square can't be reached", async () => {
    mockSquare();
    const id = `rc-${crypto.randomUUID()}`;
    const receiptToken = randomReceipt();
    await call("/v1/orders", {
      token: KIOSK,
      json: { orders: [{ id, totalCents: 400, squarePaymentId: `P-${id}`, receiptToken, items: [{ vessel: "cup", flavors: ["cookies"] }], paidAt: new Date().toISOString() }] },
    });
    const page = await call(`/r/${receiptToken}`);
    expect(page.status).toBe(200);
    expect(page.body).toContain("Cookies &amp; Cream");
    expect(page.body).toContain("$4.00");
    expect(page.body).not.toContain("View Square receipt");
  });

  it("marks canceled orders and skips the Square lookup for ids that aren't Square payments", async () => {
    mockSquare();
    await connectSquare();
    const id = `cx-${crypto.randomUUID()}`;
    const receiptToken = randomReceipt();
    await call("/v1/orders", {
      token: KIOSK,
      json: { orders: [{ id, totalCents: 400, squarePaymentId: "\u2014", receiptToken, items: [{ vessel: "cup", flavors: ["cookies"] }], paidAt: new Date().toISOString() }] },
    });
    expect((await call(`/r/${receiptToken}`)).body).not.toContain("This order was canceled");
    await call("/v1/actions", { token: STAFF, json: { actions: [{ id: `a-${id}`, type: "setOrderStatus", orderId: id, status: "canceled" }] } });
    const page = await call(`/r/${receiptToken}`);
    expect(page.body).toContain("This order was canceled");
    expect(calls.filter((c) => c.path.startsWith("/v2/payments"))).toHaveLength(0);
  });

  it("shows the refreshing page instead of a JSON error when the database is down", async () => {
    const broken = { ...env, DB: { prepare: () => { throw new Error("D1 down"); } } } as unknown as Env;
    const page = await call(`/r/${randomReceipt()}`, {}, broken);
    expect(page.status).toBe(503);
    expect(page.body).toContain("Your receipt will appear shortly");
    expect(page.body).toContain('http-equiv="refresh"');
    expect(page.headers.get("X-Robots-Tag")).toContain("noindex");
  });

  it("uses Square's per-item amounts only when they add up to the subtotal", () => {
    const items = [{ vessel: "cone", flavors: ["vanilla"], toppings: [] }, { vessel: "cup", flavors: ["chocolate"], toppings: [] }];
    const tagged = [
      { title: "1 Scoop", detail: "#1 Cone: Vanilla", cents: 400 },
      { title: "Waffle Cone", detail: "#1", cents: 150 },
      { title: "2nd Scoop", detail: "#2 Cup: Chocolate", cents: 300 },
    ];
    expect(itemPrices(items, tagged, 850)).toEqual([550, 300]);
    expect(itemPrices(items, tagged, 900)).toEqual(quote(items as CartItem[]).lines.map((l) => l.totalCents));
    expect(itemPrices(items, [{ title: "Scoop", detail: "Vanilla", cents: 850 }], 850)).toEqual(quote(items as CartItem[]).lines.map((l) => l.totalCents));
  });
});

describe("dashboard and staff sessions", () => {

  it("signs staff in with the PIN and keeps the cookie same-origin", async () => {
    const login = (pin: string, origin = BASE) =>
      call("/dashboard/login", { method: "POST", headers: { Origin: origin, "Content-Type": "application/x-www-form-urlencoded" }, body: `pin=${pin}` });
    expect((await call("/staff/scooper")).body).toContain('name="pin"');
    expect((await login("1111")).status).toBe(401);
    expect((await login("2468", "https://evil.test")).status).toBe(403);
    const ok = await login("2468");
    expect(ok.status).toBe(303);
    const setCookie = ok.headers.get("Set-Cookie")!;
    expect(setCookie).toMatch(/HttpOnly; Secure; SameSite=Strict/);
    const cookie = setCookie.split(";")[0];
    expect((await call("/staff/scooper", { headers: { Cookie: cookie } })).body).toContain('id="make"');
    expect((await call("/v1/stats", { headers: { Cookie: cookie } })).status).toBe(200);
    expect((await call("/v1/square/refresh", { method: "POST", headers: { Cookie: cookie } })).status).toBe(403);
    expect((await call("/v1/events", { method: "POST", headers: { Cookie: cookie, Origin: BASE }, body: "{}" })).status).toBe(403);
  });

  it("issues bearer sessions for the staff iPad", async () => {
    expect((await call("/v1/staff/session", { json: { pin: "0000" } })).status).toBe(401);
    const session = await call("/v1/staff/session", { json: { pin: "2468" } });
    expect(session.body.token).toMatch(/^st1\./);
    expect((await call("/v1/stats", { token: session.body.token })).status).toBe(200);
    expect((await call("/v1/orders", { token: session.body.token, json: { orders: [] } })).status).toBe(403);
    const forged = session.body.token.slice(0, -2) + (session.body.token.endsWith("A") ? "BB" : "AA");
    expect((await call("/v1/stats", { token: forged })).status).toBe(401);
  });
});

describe("order feed and stats", () => {
  it("pushes new paid orders to staff and tracks their status", async () => {
    const response = await exports.default.fetch(`${BASE}/v1/ws`, {
      headers: { Upgrade: "websocket", Authorization: `Bearer ${STAFF}`, "X-Booth-Device": "feed-staff" },
    });
    const ws = response.webSocket!;
    const inbox: ServerMessage[] = [];
    ws.addEventListener("message", (event) => {
      inbox.push(JSON.parse(event.data as string));
    });
    ws.accept();
    const waitFor = async (match: (m: ServerMessage) => boolean) => {
      for (let i = 0; i < 100; i++) {
        const found = inbox.find(match);
        if (found) return found;
        await new Promise((r) => setTimeout(r, 20));
      }
      throw new Error("timed out");
    };
    const snapshot = await waitFor((m) => m.type === "snapshot");
    expect(snapshot.type === "snapshot" && Array.isArray(snapshot.state.orders)).toBe(true);

    const id = `feed-${crypto.randomUUID()}`;
    const order = {
      id, orderNumber: 7, orderRef: "FEED-7", customerName: "Sam", totalCents: 950, paidAt: new Date().toISOString(),
      items: [{ vessel: "cone", flavors: ["vanilla", "chocolate"], toppings: ["sprinkles"] }],
    };
    const posted = await call("/v1/orders", { token: KIOSK, device: "feed-kiosk", json: { orders: [order] } });
    expect(posted.body.results[0].status).toBe("ok");
    const patch = await waitFor((m) => m.type === "patch" && m.change.kind === "order" && m.change.order.id === id);
    expect(patch.type === "patch" && patch.change.kind === "order" && patch.change.order).toMatchObject({
      id, orderNumber: 7, orderRef: "FEED-7", kioskId: "feed-kiosk", customerName: "Sam", status: "paid", items: [{ vessel: "cone", toppings: ["sprinkles"] }],
    });
    expect(await env.DB.prepare("SELECT order_ref, device FROM orders WHERE id = ?").bind(id).first()).toEqual({ order_ref: "FEED-7", device: "feed-kiosk" });

    await call("/v1/orders", { token: KIOSK, device: "feed-kiosk", json: { orders: [order] } });
    const actions = await call("/v1/actions", { token: STAFF, json: { actions: [{ id: `a-${id}`, type: "setOrderStatus", orderId: id, status: "ready", by: "Maya" }] } });
    expect(actions.body.results[0].status).toBe("ok");
    await waitFor((m) => m.type === "patch" && m.change.kind === "order" && m.change.order.id === id && m.change.order.status === "ready");
    const orderPatches = inbox.filter((m) => m.type === "patch" && m.change.kind === "order" && m.change.order.id === id);
    expect(orderPatches).toHaveLength(2);
    const row = await env.DB.prepare("SELECT status, status_by FROM orders WHERE id = ?").bind(id).first();
    expect(row).toEqual({ status: "ready", status_by: "Maya" });
    const missing = await call("/v1/actions", { token: STAFF, json: { actions: [{ id: `b-${id}`, type: "setOrderStatus", orderId: "nope", status: "ready" }] } });
    expect(missing.body.results[0]).toMatchObject({ status: "rejected", error: { code: "not_found" } });
    ws.close();
  });

  it("summarizes real orders", async () => {
    const since = Date.now() + 1000 * DAY;
    const at = (minutes: number) => new Date(since + minutes * 60_000).toISOString();
    const orders = [
      { id: `st-${crypto.randomUUID()}`, totalCents: 1100, taxCents: 0, paidAt: at(5), items: [{ vessel: "cone", flavors: ["vanilla", "chocolate"], toppings: ["whip"] }, { vessel: "cup", flavors: ["vanilla"] }] },
      { id: `st-${crypto.randomUUID()}`, totalCents: 400, paidAt: at(70), items: [{ vessel: "cup", flavors: ["cookies"] }] },
      { id: `st-${crypto.randomUUID()}`, totalCents: 400, simulated: true, paidAt: at(80), items: [{ vessel: "cup", flavors: ["cookies"] }] },
    ];
    await call("/v1/orders", { token: KIOSK, json: { orders } });
    const stats = await call(`/v1/stats?since=${since}&until=${since + DAY}`, { token: STAFF });
    expect(stats.body).toMatchObject({
      orders: 2, simulatedOrders: 1, totalCents: 1500, averageCents: 750, items: 3, scoops: 4, cones: 1, cups: 2, toppings: 1,
      flavors: { vanilla: 2, chocolate: 1, cookies: 1 }, toppingCounts: { whip: 1 }, statuses: { paid: 2 },
    });
    expect(stats.body.byHour.reduce((sum: number, h: any) => sum + h.orders, 0)).toBe(2);
    expect((await call("/v1/stats", { token: KIOSK })).status).toBe(403);
  });
});
