import { env, exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { ADMIN_IDLE_MS, ADMIN_MAX_MS, ADMIN_TOKEN_HEADER, createAdminSession } from "../src/admin";
import { checkCatalogItems } from "../src/catalog";
import type { BoothState, ServerMessage } from "../src/protocol";
import { createStaffSession } from "../src/session";

const KIOSK = "test-kiosk-token";
const STAFF = "test-staff-token";
const BASE = "https://booth.test";

let counter = 0;
const newDevice = (prefix: string) => `${prefix}-${++counter}-${crypto.randomUUID().slice(0, 8)}`;

function headers(token: string, device: string, extra: Record<string, string> = {}) {
  return { Authorization: `Bearer ${token}`, "X-Booth-Device": device, ...extra };
}

async function request(path: string, init: { token?: string; device?: string; method?: string; body?: unknown; headers?: Record<string, string> } = {}) {
  const h: Record<string, string> = { ...(init.headers ?? {}) };
  if (init.token) h.Authorization = `Bearer ${init.token}`;
  if (init.device) h["X-Booth-Device"] = init.device;
  if (init.body !== undefined) h["Content-Type"] = "application/json";
  const response = await exports.default.fetch(`${BASE}${path}`, {
    method: init.method ?? (init.body === undefined ? "GET" : "POST"),
    headers: h,
    body: init.body === undefined ? undefined : typeof init.body === "string" ? init.body : JSON.stringify(init.body),
  });
  const text = await response.text();
  let body: any = null;
  try {
    body = JSON.parse(text);
  } catch {
    body = text;
  }
  return { status: response.status, body, headers: response.headers };
}

async function adminToken(): Promise<string> {
  return (await createAdminSession(env)).token;
}

const admin = async (path: string, init: { method?: string; body?: unknown } = {}) => request(path, { ...init, token: await adminToken() });

class Socket {
  inbox: ServerMessage[] = [];
  private waiters: { match: (m: ServerMessage) => boolean; resolve: (m: ServerMessage) => void }[] = [];

  constructor(readonly ws: WebSocket) {
    ws.addEventListener("message", (event) => {
      const message = JSON.parse(event.data as string) as ServerMessage;
      const waiter = this.waiters.find((w) => w.match(message));
      if (waiter) {
        this.waiters.splice(this.waiters.indexOf(waiter), 1);
        waiter.resolve(message);
      } else this.inbox.push(message);
    });
    ws.accept();
  }

  next<T extends ServerMessage["type"]>(type: T, where: (m: Extract<ServerMessage, { type: T }>) => boolean = () => true, timeout = 2000) {
    const match = (m: ServerMessage) => m.type === type && where(m as Extract<ServerMessage, { type: T }>);
    const index = this.inbox.findIndex(match);
    if (index >= 0) return Promise.resolve(this.inbox.splice(index, 1)[0] as Extract<ServerMessage, { type: T }>);
    return new Promise<Extract<ServerMessage, { type: T }>>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`Timed out waiting for ${type}`)), timeout);
      this.waiters.push({ match, resolve: (m) => { clearTimeout(timer); resolve(m as Extract<ServerMessage, { type: T }>); } });
    });
  }

  send(message: unknown) {
    this.ws.send(JSON.stringify(message));
  }

  close() {
    this.ws.close(1000, "done");
  }
}

async function connect(token: string, device: string): Promise<{ socket: Socket; snapshot: BoothState }> {
  const response = await exports.default.fetch(`${BASE}/v1/ws`, { headers: headers(token, device, { Upgrade: "websocket" }) });
  expect(response.status).toBe(101);
  const socket = new Socket(response.webSocket!);
  const snapshot = await socket.next("snapshot");
  return { socket, snapshot: snapshot.state };
}

async function state(): Promise<BoothState> {
  return (await request("/v1/state", { token: STAFF, device: "observer" })).body as BoothState;
}

const order = (id: string, extra: Record<string, unknown> = {}) => ({
  id, orderNumber: 7, orderRef: "TEST-7", squareOrderId: `SQO-${id}`, squarePaymentId: `PAY-${id}`, customerName: "Alex Rivera",
  totalCents: 900, subtotalCents: 900, taxCents: 0, card: "Visa 1111", simulated: false, paidAt: new Date().toISOString(),
  receiptToken: `${id.replace(/[^A-Za-z0-9]/g, "")}${"x".repeat(24)}`.slice(0, 40),
  items: [{ vessel: "cone", flavors: ["vanilla", "chocolate"], toppings: ["whip"] }],
  lines: [{ title: "1 Scoop", detail: "#1 Waffle Cone: Vanilla", cents: 400 }],
  ...extra,
});

const help = (id: string, extra: Record<string, unknown> = {}) => ({ id, seq: 1, type: "help", reason: "button", message: `help ${id}`, ...extra });

describe("admin sessions", () => {
  it("needs the PIN again: staff sessions, the staff token and kiosk tokens are refused", async () => {
    const staffSession = (await createStaffSession(env)).token;
    for (const token of [undefined, STAFF, KIOSK, staffSession, "ad1.bogus.token"]) {
      const response = await request("/v1/admin/state", { token });
      expect(response.status).toBe(401);
      expect(response.body.error.code).toBe("admin_required");
    }
    const login = await exports.default.fetch(`${BASE}/dashboard/login`, {
      method: "POST",
      redirect: "manual",
      headers: { Origin: BASE, "Content-Type": "application/x-www-form-urlencoded" },
      body: "pin=2468",
    });
    const cookie = login.headers.get("Set-Cookie")!.split(";")[0];
    expect((await request("/v1/admin/state", { headers: { Cookie: cookie } })).status).toBe(401);
    expect((await request("/v1/admin/session", { body: { pin: "0000" } })).status).toBe(401);
    expect((await request("/v1/admin/session", { body: {} })).status).toBe(400);
  });

  it("issues a 15 minute token that works on every admin route and slides while in use", async () => {
    const before = Date.now();
    const issued = await request("/v1/admin/session", { body: { pin: "2468" } });
    expect(issued.body.token).toMatch(/^ad1\./);
    expect(issued.body.expiresAt).toBeGreaterThanOrEqual(before + ADMIN_IDLE_MS);
    expect(issued.body.expiresAt).toBeLessThanOrEqual(Date.now() + ADMIN_IDLE_MS);
    const fresh = await request("/v1/admin/state", { token: issued.body.token });
    expect(fresh.status).toBe(200);
    expect(fresh.headers.get(ADMIN_TOKEN_HEADER)).toBeNull();

    const older = await createAdminSession(env, Date.now() - 5 * 60_000);
    const used = await request("/v1/admin/state", { token: older.token });
    expect(used.status).toBe(200);
    const renewed = used.headers.get(ADMIN_TOKEN_HEADER)!;
    expect(renewed).toMatch(/^ad1\./);
    expect(Number(used.headers.get("X-Booth-Admin-Expires"))).toBeGreaterThan(older.expiresAt + 4 * 60_000);
    expect((await request("/v1/admin/state", { token: renewed })).status).toBe(200);
  });

  it("refuses an expired token and caps sliding at four hours", async () => {
    const expired = await createAdminSession(env, Date.now() - ADMIN_IDLE_MS - 1000);
    expect((await request("/v1/admin/state", { token: expired.token })).status).toBe(401);
    const old = await createAdminSession(env, Date.now(), { sid: "s", iat: Date.now() - ADMIN_MAX_MS + 60_000, exp: Date.now() + 60_000 });
    expect(old.expiresAt).toBeLessThanOrEqual(Date.now() + 60_000);
    const used = await request("/v1/admin/state", { token: old.token });
    expect(used.status).toBe(200);
    expect(used.headers.get(ADMIN_TOKEN_HEADER)).toBeNull();
  });

  it("serves the admin page without a session and lists it on the picker", async () => {
    const page = await exports.default.fetch(`${BASE}/staff/admin`);
    expect(page.status).toBe(200);
    expect(page.headers.get("Content-Security-Policy")).toContain("script-src 'nonce-");
    const login = await exports.default.fetch(`${BASE}/dashboard/login`, {
      method: "POST",
      redirect: "manual",
      headers: { Origin: BASE, "Content-Type": "application/x-www-form-urlencoded" },
      body: "pin=2468",
    });
    const cookie = login.headers.get("Set-Cookie")!.split(";")[0];
    const picker = await (await exports.default.fetch(`${BASE}/staff`, { headers: { Cookie: cookie } })).text();
    expect(picker).toContain('href="/staff/admin"');
  });
});

describe("admin tools", () => {
  it("sends controls to a connected kiosk and refuses an offline one", async () => {
    const device = newDevice("k");
    const { socket } = await connect(KIOSK, device);
    const sent = await admin(`/v1/admin/kiosks/${device}/control`, { body: { op: "attract" } });
    expect(sent.status).toBe(200);
    const control = await socket.next("control");
    expect(control.control).toMatchObject({ id: sent.body.id, op: "attract", by: "Admin" });
    expect((await admin(`/v1/admin/kiosks/${device}/control`, { body: { op: "explode" } })).status).toBe(400);
    socket.close();
    await new Promise((r) => setTimeout(r, 50));
    const offline = await admin(`/v1/admin/kiosks/${device}/control`, { body: { op: "resync" } });
    expect(offline.status).toBe(409);
    expect(offline.body.error.code).toBe("kiosk_offline");
  });

  it("toggles a kiosk's debug tools and forgets it", async () => {
    const device = newDevice("k");
    await request("/v1/events", { token: KIOSK, device, body: { events: [help(`h-${device}`)] } });
    expect((await admin(`/v1/admin/kiosks/${device}/debug`, { body: { debug: true } })).status).toBe(200);
    expect((await state()).kiosks.find((k) => k.id === device)?.debug).toBe(true);
    expect((await admin(`/v1/admin/kiosks/${device}/forget`, { method: "POST" })).status).toBe(200);
    expect((await state()).kiosks.find((k) => k.id === device)).toBeUndefined();
    expect((await admin(`/v1/admin/kiosks/nobody-${device}/debug`, { body: { debug: true } })).status).toBe(404);
  });

  it("filters logs by kiosk, level, time and text, newest first, in pages", async () => {
    const a = newDevice("logs-a");
    const b = newDevice("logs-b");
    const base = Date.parse("2026-12-05T18:00:00Z");
    const line = (n: number, level: string, message: string) => ({ id: `${a}-${n}`, ts: new Date(base + n * 1000).toISOString(), level, message });
    await request("/v1/logs", {
      token: KIOSK,
      device: a,
      body: { lines: [line(1, "info", "Authorized"), line(2, "warn", "Reader slow"), line(3, "error", "Payment failed (3)"), line(4, "info", "Order 3F2A-1 paid"), line(5, "debug", "Frame stats")] },
    });
    await request("/v1/logs", { token: KIOSK, device: b, body: { lines: [{ id: `${b}-1`, ts: new Date(base + 2500).toISOString(), level: "error", message: "Other kiosk failed" }] } });
    const token = await adminToken();
    const get = async (query: string) => (await request(`/v1/admin/logs?${query}`, { token })).body;

    const mine = await get(`device=${a}&since=${base}`);
    expect(mine.lines.map((l: any) => l.message)).toEqual(["Frame stats", "Order 3F2A-1 paid", "Payment failed (3)", "Reader slow", "Authorized"]);
    expect(mine.devices.map((d: any) => d.device)).toEqual(expect.arrayContaining([a, b]));
    expect((await get(`device=${a}&level=warn`)).lines.map((l: any) => l.level)).toEqual(["error", "warn"]);
    expect((await get(`level=error&since=${base}&until=${base + 10_000}`)).lines.map((l: any) => l.message)).toEqual(["Payment failed (3)", "Other kiosk failed"]);
    expect((await get(`q=${encodeURIComponent("payment FAILED")}&device=${a}`)).lines).toHaveLength(1);
    expect((await get(`q=${encodeURIComponent("100%")}&device=${a}`)).lines).toHaveLength(0);
    expect((await get(`device=${a}&since=${base + 3000}&until=${base + 5000}`)).lines.map((l: any) => l.message)).toEqual(["Order 3F2A-1 paid", "Payment failed (3)"]);

    const first = await get(`device=${a}&limit=2`);
    expect(first.lines).toHaveLength(2);
    const second = await get(`device=${a}&limit=2&before=${encodeURIComponent(first.next)}`);
    const third = await get(`device=${a}&limit=2&before=${encodeURIComponent(second.next)}`);
    expect(second.devices).toBeNull();
    expect(third.next).toBeNull();
    expect([...first.lines, ...second.lines, ...third.lines].map((l: any) => l.id)).toEqual([5, 4, 3, 2, 1].map((n) => `${a}-${n}`));
  });

  it("finds orders by name, receipt token or link, reference and number, and changes their status", async () => {
    const device = newDevice("k");
    const id = `find-${crypto.randomUUID()}`;
    const o = order(id, { customerName: "Priya Natarajan", orderRef: "F1ND-41", orderNumber: 41 });
    expect((await request("/v1/orders", { token: KIOSK, device, body: { orders: [o] } })).body.results[0].status).toBe("ok");
    const token = await adminToken();
    const find = async (q: string) => (await request(`/v1/admin/orders?q=${encodeURIComponent(q)}`, { token })).body.orders.map((x: any) => x.id);
    expect(await find("natara")).toContain(id);
    expect(await find(o.receiptToken)).toEqual([id]);
    expect(await find(`https://kiosk.example/r/${o.receiptToken}`)).toEqual([id]);
    expect(await find("Order F1ND-41")).toEqual([id]);
    expect(await find("f1nd-41")).toEqual([id]);
    expect(await find(`PAY-${id}`)).toEqual([id]);
    expect(await find("41")).toContain(id);
    expect(await find("nobody at all")).toEqual([]);

    const detail = (await request(`/v1/admin/orders/${id}`, { token })).body;
    expect(detail.order).toMatchObject({ id, customer_name: "Priya Natarajan", square_payment_id: `PAY-${id}`, receiptUrl: `/r/${o.receiptToken}` });
    expect(detail.order.squareUrl).toBe(`https://squareup.com/dashboard/sales/transactions/PAY-${id}`);
    expect(detail.order.items[0].flavors).toEqual(["vanilla", "chocolate"]);
    expect((await request(`/v1/admin/orders/missing-order`, { token })).status).toBe(404);

    const changed = await request(`/v1/admin/orders/${id}/status`, { token, body: { status: "canceled" } });
    expect(changed.body).toEqual({ status: "canceled", via: "hub" });
    expect((await state()).orders.find((x) => x.id === id)?.status).toBe("canceled");
    const row = await env.DB.prepare("SELECT status, status_by FROM orders WHERE id = ?").bind(id).first<{ status: string; status_by: string }>();
    expect(row).toEqual({ status: "canceled", status_by: "Admin" });

    const old = `old-${crypto.randomUUID()}`;
    await env.DB.prepare("INSERT INTO orders (id, total_cents, items, paid_at, received_at, status) VALUES (?, 400, '[]', 1, 1, 'collected')").bind(old).run();
    expect((await request(`/v1/admin/orders/${old}/status`, { token, body: { status: "ready" } })).body).toEqual({ status: "ready", via: "d1" });
    expect((await request(`/v1/admin/orders/${old}/status`, { token, body: { status: "lost" } })).status).toBe(400);
  });

  it("deletes only test, simulated and smoke orders, and acknowledges every alert", async () => {
    const kiosk = newDevice("k");
    const real = `real-${crypto.randomUUID()}`;
    const sim = `sim-${crypto.randomUUID()}`;
    const smoke = `smoke-${crypto.randomUUID()}`;
    await request("/v1/orders", { token: KIOSK, device: kiosk, body: { orders: [order(real), order(sim, { simulated: true })] } });
    await request("/v1/orders", { token: KIOSK, device: "smoke-run-kiosk", body: { orders: [order(smoke)] } });
    const token = await adminToken();
    const preview = (await request("/v1/admin/cleanup", { token })).body;
    expect(preview.testOrders).toBeGreaterThanOrEqual(2);
    const removed = (await request("/v1/admin/cleanup/test-orders", { token, method: "POST" })).body;
    expect(removed.orders).toBe(preview.testOrders);
    const left = (await env.DB.prepare("SELECT id FROM orders WHERE id IN (?, ?, ?)").bind(real, sim, smoke).all<{ id: string }>()).results.map((r) => r.id);
    expect(left).toEqual([real]);
    const feed = (await state()).orders.map((o) => o.id);
    expect(feed).toContain(real);
    expect(feed).not.toContain(sim);
    expect(feed).not.toContain(smoke);

    await request("/v1/events", { token: KIOSK, device: kiosk, body: { events: [help(`h1-${kiosk}`), help(`h2-${kiosk}`, { reason: "idle", seq: 2 })] } });
    expect((await state()).alerts.filter((a) => !a.ackedAt && !a.resolvedAt).length).toBeGreaterThanOrEqual(2);
    const acked = (await request("/v1/admin/alerts/ack-all", { token, method: "POST", body: { by: "Owner" } })).body;
    expect(acked.acknowledged).toBeGreaterThanOrEqual(2);
    const after = await state();
    expect(after.alerts.filter((a) => !a.ackedAt && !a.resolvedAt)).toEqual([]);
    expect(after.alerts.find((a) => a.kioskId === kiosk)?.ackedBy).toBe("Owner");
  });

  it("self-tests D1 and the hub, and reports Square plainly when it isn't connected", async () => {
    const result = (await admin("/v1/admin/selftest", { method: "POST" })).body;
    const byId = Object.fromEntries(result.checks.map((c: any) => [c.id, c]));
    expect(byId.d1.ok).toBe(true);
    expect(byId.hub.ok).toBe(true);
    expect(byId.square).toMatchObject({ ok: false });
    expect(byId.square.detail).toMatch(/isn't connected/);
    expect(byId.catalog.ok).toBe(false);
    expect(result.ok).toBe(false);
    const square = (await admin("/v1/admin/square")).body;
    expect(square).toMatchObject({ connected: false, environment: "production", catalog: null });
  });

  it("checks the catalog category item by item against the kiosk's prices", () => {
    const item = (name: string, ...prices: (number | null)[]) => ({
      item_data: {
        name,
        variations: prices.map((amount, i) => ({
          id: `${name}-${i}`,
          item_variation_data: amount === null ? { pricing_type: "VARIABLE_PRICING" } : { pricing_type: "FIXED_PRICING", price_money: { amount, currency: "USD" } },
        })),
      },
    });
    const good = [item("1 Scoop", 400), item("2nd Scoop", 300), item("3rd+ Scoop", 200), item("Waffle Cone", 150), item("Topping", 50), item("Bottled Water", 200)];
    const ok = checkCatalogItems("TC", good);
    expect(ok.ok).toBe(true);
    expect(ok.extras).toEqual(["Bottled Water"]);
    const bad = checkCatalogItems("TC", [item("1 Scoop", 450), item("2nd scoop", 300, 300), item("Waffle Cone", null), item("Topping", 50)]);
    expect(bad.ok).toBe(false);
    expect(Object.fromEntries(bad.items.map((i) => [i.name, i.problem]))).toEqual({
      "1 Scoop": "Wrong price",
      "2nd Scoop": "Has 2 sellable variations, needs exactly one",
      "3rd+ Scoop": "Missing from the category",
      "Waffle Cone": "Variable price, needs a fixed price",
      Topping: null,
    });
    expect(bad.items.find((i) => i.name === "1 Scoop")).toMatchObject({ expectedCents: 400, foundCents: 450 });
  });

  it("exports a backup of orders, kiosks, alerts and stats", async () => {
    const response = await admin("/v1/admin/backup");
    expect(response.status).toBe(200);
    expect(response.headers.get("Content-Disposition")).toMatch(/^attachment; filename="booth-backup-.*\.json"$/);
    for (const key of ["orders", "kiosks", "alerts", "stats", "epoch", "exportedAt"]) expect(response.body).toHaveProperty(key);
    expect(Array.isArray(response.body.orders)).toBe(true);
  });
});

describe("reset everything", () => {
  it("erases booth state, keeps Square tokens and open gift card holds, and tells every client the new epoch", async () => {
    const kioskDevice = newDevice("k");
    const { socket: kiosk } = await connect(KIOSK, kioskDevice);
    const { socket: staff, snapshot: before } = await connect(STAFF, newDevice("s"));
    await request("/v1/events", { token: KIOSK, device: kioskDevice, body: { events: [help(`reset-h-${kioskDevice}`)] } });
    await request("/v1/orders", { token: KIOSK, device: kioskDevice, body: { orders: [order(`reset-o-${kioskDevice}`, { epoch: before.epoch })] } });
    await request("/v1/logs", { token: KIOSK, device: kioskDevice, body: { lines: [{ id: `reset-l-${kioskDevice}`, level: "info", message: "before reset" }] } });
    await request("/v1/actions", {
      token: STAFF,
      device: "reset-staff",
      body: {
        actions: [
          { id: crypto.randomUUID(), type: "renameKiosk", kiosk: kioskDevice, name: "Front table" },
          { id: crypto.randomUUID(), type: "setKioskOpen", kiosk: kioskDevice, open: false },
          { id: crypto.randomUUID(), type: "setKioskDebug", kiosk: kioskDevice, debug: true },
          { id: crypto.randomUUID(), type: "setSupply", kind: "topping", item: "gummies", soldOut: true },
        ],
      },
    });
    await env.DB.batch([
      env.DB.prepare("INSERT INTO checkouts (id, device, request_hash, environment, location_id, square_order_id, total_cents, tax_cents, expected_cents, used_catalog, items, response, created_at) VALUES ('hold-checkout', 'k', 'h', 'sandbox', 'L', 'SQ', 900, 0, 900, 1, '[]', '{}', 1), ('done-checkout', 'k', 'h', 'sandbox', 'L', 'SQ2', 900, 0, 900, 1, '[]', '{}', 1)"),
      env.DB.prepare("INSERT INTO giftcard_payments (payment_id, checkout_id, device, idempotency_key, gan_last4, approved_cents, status, created_at, updated_at) VALUES ('GC-HOLD', 'hold-checkout', 'k', 'key-hold', '1234', 500, 'approved', 1, 1), ('GC-DONE', 'done-checkout', 'k', 'key-done', '5678', 500, 'completed', 1, 1)"),
      env.DB.prepare("INSERT INTO square_tokens (environment, application_id, merchant_id, location_id, access_token, refresh_token, expires_at, scopes, obtained_at, refreshed_at) VALUES ('reset-test', 'app', 'M', 'L', 'sealed', 'sealed', NULL, '', 1, 1)"),
    ]);

    const token = await adminToken();
    const preview = (await request("/v1/admin/reset", { token })).body;
    expect(preview.epoch).toBe(before.epoch);
    expect(preview.erase.orders).toBeGreaterThanOrEqual(1);
    expect(preview.erase.alerts).toBeGreaterThanOrEqual(1);
    expect(preview.erase.kiosks).toBeGreaterThanOrEqual(1);
    expect(preview.erase.soldOut).toBeGreaterThanOrEqual(1);
    expect(preview.keep.giftCardHolds).toBe(1);

    expect((await request("/v1/admin/reset", { token, body: {} })).status).toBe(400);
    expect((await request("/v1/admin/reset", { token, body: { confirm: "reset" } })).status).toBe(400);
    expect((await request("/v1/admin/reset", { token: STAFF, body: { confirm: "RESET" } })).status).toBe(401);
    const done = await request("/v1/admin/reset", { token, body: { confirm: "RESET", by: "Owner" } });
    expect(done.status).toBe(200);
    expect(done.body.epoch).toBe(before.epoch + 1);

    const isNew = (m: { state: BoothState }) => m.state.epoch === before.epoch + 1;
    const kioskSnap = (await kiosk.next("snapshot", isNew)).state;
    const staffSnap = (await staff.next("snapshot", isNew)).state;
    expect(staffSnap.rev).toBeGreaterThan(before.rev);
    expect(staffSnap.resetAt).toBe(done.body.resetAt);
    for (const snap of [kioskSnap, staffSnap]) {
      expect(snap.alerts).toEqual([]);
      expect(snap.orders).toEqual([]);
      expect(snap.supplies.every((s) => !s.soldOut)).toBe(true);
      expect(snap.kiosks.map((k) => k.id)).toEqual([kioskDevice]);
      expect(snap.kiosks[0]).toMatchObject({ open: true, debug: false, customName: null, connected: true });
    }
    expect(staffSnap.sessions).toEqual([]);

    const remaining = async (sql: string) => (await env.DB.prepare(sql).all<{ id: string }>()).results.map((r) => r.id);
    expect(await remaining("SELECT id FROM orders")).toEqual([]);
    expect(await remaining("SELECT id FROM checkouts")).toEqual(["hold-checkout"]);
    expect(await remaining("SELECT payment_id AS id FROM giftcard_payments")).toEqual(["GC-HOLD"]);
    expect(await remaining("SELECT environment AS id FROM square_tokens WHERE environment = 'reset-test'")).toEqual(["reset-test"]);
    const logs = (await env.DB.prepare("SELECT device, level, message FROM logs").all<{ device: string; level: string; message: string }>()).results;
    expect(logs).toHaveLength(1);
    expect(logs[0]).toMatchObject({ device: "booth-admin", level: "warn" });
    expect(logs[0].message).toContain("Booth reset by Owner");
    const audit = await env.DB.prepare("SELECT action, by FROM admin_events WHERE action = 'reset' ORDER BY at DESC").first();
    expect(audit).toEqual({ action: "reset", by: "Owner" });
    await env.DB.prepare("DELETE FROM square_tokens WHERE environment = 'reset-test'").run();

    kiosk.close();
    staff.close();
  });

  it("refuses items a stale kiosk queued before the reset, but takes new and unstamped ones", async () => {
    const start = (await state()).epoch;
    await admin("/v1/admin/reset", { body: { confirm: "RESET" } });
    const epoch = start + 1;
    const device = newDevice("stale");

    const events = await request("/v1/events", {
      token: KIOSK,
      device,
      body: { events: [help(`old-${device}`, { epoch: start }), help(`new-${device}`, { epoch, seq: 2 }), help(`legacy-${device}`, { seq: 3, reason: "idle" })] },
    });
    expect(events.body.results.map((r: any) => r.status)).toEqual(["stale", "ok", "ok"]);
    const replay = await request("/v1/events", { token: KIOSK, device, body: { events: [help(`old-${device}`, { epoch: start })] } });
    expect(replay.body.results[0].status).toBe("stale");
    const alerts = (await state()).alerts.filter((a) => a.kioskId === device);
    expect(alerts.map((a) => a.detail).sort()).toEqual([`help legacy-${device}`, `help new-${device}`]);

    const orders = await request("/v1/orders", {
      token: KIOSK,
      device,
      body: { orders: [order(`old-${device}`, { epoch: start }), order(`new-${device}`, { epoch }), order(`legacy-${device}`)] },
    });
    expect(orders.body.results.map((r: any) => r.status)).toEqual(["stale", "ok", "ok"]);
    const stored = (await env.DB.prepare("SELECT id FROM orders WHERE device = ? ORDER BY id").bind(device).all<{ id: string }>()).results.map((r) => r.id);
    expect(stored).toEqual([`legacy-${device}`, `new-${device}`]);
    const feed = (await state()).orders.map((o) => o.id);
    expect(feed).not.toContain(`old-${device}`);
    expect(feed).toContain(`new-${device}`);

    const oldLogs = await request("/v1/logs", { token: KIOSK, device, body: { epoch: start, lines: [{ id: `${device}-log-old`, level: "info", message: "old" }] } });
    expect(oldLogs.body).toMatchObject({ stored: 0, stale: 1 });
    const newLogs = await request("/v1/logs", { token: KIOSK, device, body: { epoch, lines: [{ id: `${device}-log-new`, level: "info", message: "new" }] } });
    expect(newLogs.body).toMatchObject({ stored: 1 });

    const raced = await env.BOOTH.getByName("booth").recordOrders(
      [{ id: "raced", orderNumber: 1, orderRef: null, kioskId: device, customerName: "R", items: [], totalCents: 1, simulated: false, paidAt: 1, receivedAt: 1, status: "paid", statusAt: 1, statusBy: null }],
      { raced: start },
    );
    expect(raced.stale).toEqual(["raced"]);
    expect((await state()).orders.map((o) => o.id)).not.toContain("raced");
  });

  it("gives a kiosk that was offline during the reset the new epoch and a fresh entry when it reconnects", async () => {
    const device = newDevice("away");
    const { socket } = await connect(KIOSK, device);
    await request("/v1/actions", { token: STAFF, device: "reset-staff", body: { actions: [{ id: crypto.randomUUID(), type: "renameKiosk", kiosk: device, name: "Side table" }] } });
    socket.close();
    await new Promise((r) => setTimeout(r, 50));
    const { epoch } = (await admin("/v1/admin/reset", { body: { confirm: "RESET" } })).body;
    expect((await state()).kiosks.find((k) => k.id === device)).toBeUndefined();
    const { socket: back, snapshot } = await connect(KIOSK, device);
    expect(snapshot.epoch).toBe(epoch);
    expect(snapshot.kiosks.find((k) => k.id === device)).toMatchObject({ name: expect.stringMatching(/^Kiosk /), customName: null, open: true });
    back.close();
  });
});
