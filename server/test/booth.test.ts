import { createScheduledController, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { env, exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import worker from "../src";
import { Booth, HEALTH_GRACE_MS, OFFLINE_AFTER_MS, healthConditions } from "../src/booth";
import type { BoothState, KioskHealth, ServerMessage } from "../src/protocol";

const TOKEN = "test-kiosk-token";
const PIN = "246810";

function pinProtocol(pin: string) {
  return `pin.${btoa(pin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")}`;
}

class Client {
  messages: ServerMessage[] = [];
  private waiters: { match: (m: ServerMessage) => boolean; resolve: (m: ServerMessage) => void }[] = [];

  constructor(readonly ws: WebSocket, readonly response: Response) {
    ws.addEventListener("message", (event) => {
      const message = JSON.parse(event.data as string) as ServerMessage;
      this.messages.push(message);
      this.waiters = this.waiters.filter((w) => {
        if (!w.match(message)) return true;
        w.resolve(message);
        return false;
      });
    });
    ws.accept();
  }

  send(message: unknown) {
    this.ws.send(JSON.stringify(message));
  }

  next<T extends ServerMessage["type"]>(type: T, where: (m: Extract<ServerMessage, { type: T }>) => boolean = () => true) {
    const match = (m: ServerMessage) => m.type === type && where(m as Extract<ServerMessage, { type: T }>);
    const existing = this.messages.find(match);
    if (existing) {
      this.messages.splice(this.messages.indexOf(existing), 1);
      return Promise.resolve(existing as Extract<ServerMessage, { type: T }>);
    }
    return new Promise<Extract<ServerMessage, { type: T }>>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`Timed out waiting for ${type}`)), 2000);
      this.waiters.push({
        match,
        resolve: (m) => {
          clearTimeout(timer);
          this.messages.splice(this.messages.indexOf(m), 1);
          resolve(m as Extract<ServerMessage, { type: T }>);
        },
      });
    });
  }
}

async function open(headers: Record<string, string>): Promise<Client> {
  const response = await exports.default.fetch("https://booth.test/v1/ws", { headers: { Upgrade: "websocket", ...headers } });
  expect(response.status).toBe(101);
  return new Client(response.webSocket!, response);
}

const kiosk = () => open({ Authorization: `Bearer ${TOKEN}` });
const staff = () => open({ "Sec-WebSocket-Protocol": `booth.v1, ${pinProtocol(PIN)}` });

const healthy: KioskHealth = {
  appVersion: "0.1 (1)",
  environment: "Sandbox",
  authorized: true,
  readers: [{ name: "Reader 1", state: "ready", batteryPercent: 80, isCharging: false }],
  readerReady: true,
  catalog: { ok: true, status: "Catalog OK" },
  deviceBattery: { percent: 90, charging: true },
  simulatePayment: false,
};

describe("auth", () => {
  it("rejects missing, wrong and misplaced credentials", async () => {
    const upgrade = { Upgrade: "websocket" };
    const cases: [Record<string, string>, number][] = [
      [upgrade, 401],
      [{ ...upgrade, Authorization: "Bearer nope" }, 401],
      [{ ...upgrade, "Sec-WebSocket-Protocol": `booth.v1, ${pinProtocol("000000")}` }, 401],
      [{ ...upgrade, Authorization: "PIN 000000" }, 401],
    ];
    for (const [headers, status] of cases) {
      const response = await exports.default.fetch("https://booth.test/v1/ws", { headers });
      expect(response.status).toBe(status);
    }
    const staffPosting = await exports.default.fetch("https://booth.test/v1/logs", {
      method: "POST",
      headers: { Authorization: `PIN ${PIN}` },
      body: JSON.stringify({ lines: [] }),
    });
    expect(staffPosting.status).toBe(401);
  });

  it("checks the staff PIN", async () => {
    const ok = await exports.default.fetch("https://booth.test/v1/staff/login", { method: "POST", headers: { Authorization: `PIN ${PIN}` } });
    expect(ok.status).toBe(200);
    const bad = await exports.default.fetch("https://booth.test/v1/staff/login", { method: "POST", headers: { Authorization: "PIN 1" } });
    expect(bad.status).toBe(401);
  });

  it("returns 404 for unknown API paths", async () => {
    const response = await exports.default.fetch("https://booth.test/v1/nothing");
    expect(response.status).toBe(404);
  });
});

describe("booth hub", () => {
  it("sends snapshots and echoes the staff subprotocol", async () => {
    const k = await kiosk();
    const s = await staff();
    expect(s.response.headers.get("Sec-WebSocket-Protocol")).toBe("booth.v1");
    const snapshot = await k.next("snapshot");
    expect(snapshot.state.soldOut).toEqual({ vanilla: false, chocolate: false, cookies: false });
    const staffSnapshot = await s.next("snapshot");
    expect(staffSnapshot.state.kiosk.connected).toBe(true);
  });

  it("round-trips sold-out toggles from staff to the kiosk", async () => {
    const k = await kiosk();
    const s = await staff();
    await k.next("snapshot");
    await s.next("snapshot");

    s.send({ type: "setSoldOut", flavor: "chocolate", soldOut: true, by: "Maya" });
    const toKiosk = await k.next("soldOut");
    expect(toKiosk.soldOut).toEqual({ vanilla: false, chocolate: true, cookies: false });
    const alert = await s.next("alert", (m) => m.alert.kind === "soldout");
    expect(alert.alert).toMatchObject({ title: "Chocolate is sold out", severity: "info", resolvedAt: null });

    s.send({ type: "setSoldOut", flavor: "chocolate", soldOut: false });
    expect((await k.next("soldOut")).soldOut.chocolate).toBe(false);

    s.send({ type: "setSoldOut", flavor: "pistachio", soldOut: true });
    expect((await s.next("error")).message).toMatch(/Unknown flavor/);

    k.send({ type: "setSoldOut", flavor: "vanilla", soldOut: true });
    expect((await k.next("error")).message).toMatch(/Only staff/);

    const state = (await (await exports.default.fetch("https://booth.test/v1/state", { headers: { Authorization: `Bearer ${TOKEN}` } })).json()) as BoothState;
    expect(state.soldOut.chocolate).toBe(false);
  });

  it("raises help alerts, merges repeats, ignores retries and takes acks", async () => {
    const k = await kiosk();
    const s = await staff();
    await k.next("snapshot");
    await s.next("snapshot");

    k.send({ type: "help", id: "h1", reason: "button", message: "Tapped Need help" });
    const first = await s.next("alert", (m) => m.alert.kind === "help");
    expect(first.alert).toMatchObject({ title: "Customer needs help", severity: "urgent", count: 1 });
    expect((await k.next("helpReceived")).alertId).toBe(first.alert.id);

    k.send({ type: "help", id: "h1", reason: "button" });
    expect((await k.next("helpReceived")).alertId).toBe(first.alert.id);

    k.send({ type: "help", id: "h2", reason: "button" });
    const merged = await s.next("alert", (m) => m.alert.id === first.alert.id && m.alert.count === 2);
    expect(merged.alert.count).toBe(2);

    k.send({ type: "help", id: "h3", reason: "payment_failed", message: "Card declined" });
    const payment = await s.next("alert", (m) => m.alert.key === "help:payment_failed");
    expect(payment.alert.id).not.toBe(first.alert.id);

    s.send({ type: "ack", id: first.alert.id, by: "Maya" });
    const acked = await k.next("alert", (m) => m.alert.id === first.alert.id && m.alert.ackedAt !== null);
    expect(acked.alert.ackedBy).toBe("Maya");

    k.send({ type: "help", id: "h4", reason: "button" });
    const fresh = await s.next("alert", (m) => m.alert.key === "help:button" && m.alert.id !== first.alert.id);
    expect(fresh.alert.count).toBe(1);
  });

  it("raises Kiosk offline after heartbeats stop and resolves it when they resume", async () => {
    const k = await kiosk();
    const s = await staff();
    await s.next("snapshot");
    k.send({ type: "heartbeat", screen: "attract" });
    await k.next("pong");

    const stub = env.BOOTH.getByName("booth");
    await runInDurableObject(stub, (_instance: Booth, state) => {
      const row = state.storage.sql.exec<{ value: string }>("SELECT value FROM meta WHERE key = 'kiosk'").one();
      const kioskState = JSON.parse(row.value);
      kioskState.lastHeartbeatAt = Date.now() - OFFLINE_AFTER_MS - 1000;
      state.storage.sql.exec("UPDATE meta SET value = ? WHERE key = 'kiosk'", JSON.stringify(kioskState));
    });
    expect(await runDurableObjectAlarm(stub)).toBe(true);
    const offline = await s.next("alert", (m) => m.alert.kind === "offline");
    expect(offline.alert).toMatchObject({ title: "Kiosk offline", severity: "urgent", resolvedAt: null });
    expect((await s.next("kiosk", (m) => !m.kiosk.online)).kiosk.online).toBe(false);

    k.send({ type: "heartbeat", screen: "builder" });
    const back = await s.next("alert", (m) => m.alert.id === offline.alert.id && m.alert.resolvedAt !== null);
    expect(back.alert.detail).toMatch(/Back online/);
  });

  it("waits out a grace period before raising health alerts and clears them on recovery", async () => {
    const stub = env.BOOTH.getByName("booth");
    const t0 = Date.now();
    const alerts = await runInDurableObject(stub, async (booth: Booth, state) => {
      await booth.handle({ type: "heartbeat" }, null, t0);
      await booth.handle({ type: "health", health: { ...healthy, readerReady: false, readers: [] } }, null, t0);
      const before = state.storage.sql.exec("SELECT * FROM alerts WHERE kind = 'health'").toArray().length;
      const alarm = await state.storage.getAlarm();
      await booth.handle({ type: "heartbeat" }, null, t0 + HEALTH_GRACE_MS + 1);
      const raised = state.storage.sql.exec<{ title: string; resolved_at: number | null }>("SELECT title, resolved_at FROM alerts WHERE kind = 'health'").toArray();
      await booth.handle({ type: "health", health: healthy }, null, t0 + HEALTH_GRACE_MS + 2);
      const after = state.storage.sql.exec<{ resolved_at: number | null }>("SELECT resolved_at FROM alerts WHERE kind = 'health'").toArray();
      return { before, alarm, raised, after };
    });
    expect(alerts.before).toBe(0);
    expect(alerts.alarm).toBe(t0 + HEALTH_GRACE_MS);
    expect(alerts.raised).toEqual([{ title: "No card reader ready", resolved_at: null }]);
    expect(alerts.after[0].resolved_at).not.toBeNull();
  });
});

describe("health conditions", () => {
  it("flags only real problems", () => {
    expect([...healthConditions(healthy).keys()]).toEqual([]);
    expect([...healthConditions({ ...healthy, environment: "No credentials", authorized: false, readerReady: false }).keys()]).toEqual([]);
    expect([...healthConditions({ ...healthy, simulatePayment: true, readerReady: false }).keys()]).toEqual([]);
    const bad = healthConditions({
      ...healthy,
      authorized: false,
      readerReady: false,
      readers: [{ name: "R", state: "ready", batteryPercent: 9, isCharging: false }],
      deviceBattery: { percent: 15, charging: false },
      catalog: { ok: false, error: "Category TC not found" },
    });
    expect([...bad.keys()].sort()).toEqual(["health:auth", "health:catalog", "health:ipad-battery", "health:reader", "health:reader-battery"]);
    expect(bad.get("health:reader-battery")?.title).toBe("Card reader battery low (9%)");
  });
});

describe("logs and orders", () => {
  const post = (path: string, body: unknown, token = TOKEN) =>
    exports.default.fetch(`https://booth.test${path}`, {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });

  it("stores log lines idempotently", async () => {
    const lines = [
      { id: "dev-a-0", ts: "2026-10-11T10:00:00.000-07:00", level: "info", message: "Authorized" },
      { id: "dev-a-11", ts: "2026-10-11T10:00:01.500-07:00", level: "error", message: "Payment failed (3)", context: { code: 3 } },
      { id: "dev-a-40", ts: "nonsense", level: "loud", message: "Odd line" },
      { message: "no id" },
    ];
    const first = await post("/v1/logs", { device: "dev", appVersion: "0.1 (1)", lines });
    expect(await first.json()).toEqual({ accepted: 3, stored: 3, duplicates: 0, rejected: 1 });
    const again = await post("/v1/logs", { device: "dev", lines });
    expect(await again.json()).toMatchObject({ accepted: 3, stored: 0, duplicates: 3 });

    const rows = await env.DB.prepare("SELECT id, level, ts, context FROM logs ORDER BY id").all<{ id: string; level: string; ts: number; context: string | null }>();
    expect(rows.results.map((r) => [r.id, r.level])).toEqual([["dev-a-0", "info"], ["dev-a-11", "error"], ["dev-a-40", "info"]]);
    expect(rows.results[0].ts).toBe(Date.parse("2026-10-11T17:00:00.000Z"));
    expect(JSON.parse(rows.results[1].context!)).toEqual({ code: 3 });

    expect((await post("/v1/logs", { lines: [] }, "wrong")).status).toBe(401);
    expect((await post("/v1/logs", { lines: Array.from({ length: 501 }, (_, i) => ({ id: `x${i}`, message: "m" })) })).status).toBe(413);
  });

  it("stores orders once and lists them for staff", async () => {
    const order = {
      id: "order-1",
      orderNumber: 7,
      squareOrderId: "SQ-ORDER",
      squarePaymentId: "SQ-PAY",
      customerName: "Alex",
      totalCents: 900,
      subtotalCents: 900,
      taxCents: 0,
      card: "Visa 1111",
      simulated: false,
      paidAt: "2026-10-11T18:00:00Z",
      items: [{ vessel: "cone", flavors: ["vanilla", "chocolate"] }],
      lines: [{ title: "1 Scoop", detail: "#1 Waffle Cone: Vanilla", cents: 400 }],
    };
    expect(await (await post("/v1/orders", order)).json()).toEqual({ ok: true, duplicate: false });
    expect(await (await post("/v1/orders", order)).json()).toEqual({ ok: true, duplicate: true });
    expect((await post("/v1/orders", { id: "bad" })).status).toBe(400);

    const listed = await exports.default.fetch("https://booth.test/v1/orders", { headers: { Authorization: `PIN ${PIN}` } });
    const body = (await listed.json()) as { count: number; totalCents: number; orders: { items: unknown }[] };
    expect(body.count).toBe(1);
    expect(body.totalCents).toBe(900);
    expect(body.orders[0].items).toEqual(order.items);
  });

  it("drops logs past the retention window", async () => {
    const old = Date.now() - 31 * 24 * 60 * 60 * 1000;
    await env.DB.prepare("INSERT INTO logs (id, device, ts, level, message, received_at) VALUES ('old', 'd', ?, 'info', 'old', ?), ('new', 'd', ?, 'info', 'new', ?)")
      .bind(old, old, Date.now(), Date.now())
      .run();
    await worker.scheduled(createScheduledController({ cron: "17 9 * * *" }), env);
    const ids = (await env.DB.prepare("SELECT id FROM logs WHERE id IN ('old', 'new')").all<{ id: string }>()).results.map((r) => r.id);
    expect(ids).toEqual(["new"]);
  });
});

