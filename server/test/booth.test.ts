import { createExecutionContext, createScheduledController, evictDurableObject, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { env, exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import worker from "../src";
import { Booth, FLOOD_LIMIT, HEALTH_GRACE_MS, OFFLINE_AFTER_MS, healthConditions } from "../src/booth";
import type { Alert, BoothState, Change, ItemResult, ServerMessage } from "../src/protocol";
import { KioskHealth } from "../src/schema";

const KIOSK = "test-kiosk-token";
const STAFF = "test-staff-token";
const BASE = "https://booth.test";

type Msg<T extends ServerMessage["type"]> = Extract<ServerMessage, { type: T }>;

let deviceCounter = 0;
const newDevice = (prefix: string) => `${prefix}-${++deviceCounter}-${crypto.randomUUID().slice(0, 8)}`;

function headers(token: string, device: string, extra: Record<string, string> = {}) {
  return { Authorization: `Bearer ${token}`, "X-Booth-Device": device, ...extra };
}

/** A client that follows PROTOCOL.md's reconciliation rules, so tests can check convergence. */
class Client {
  inbox: ServerMessage[] = [];
  state: BoothState | null = null;
  syncs = 0;
  dropNextPatches = 0;
  private waiters: { match: (m: ServerMessage) => boolean; resolve: (m: ServerMessage) => void }[] = [];

  constructor(readonly ws: WebSocket) {
    ws.addEventListener("message", (event) => this.receive(event.data as string));
    ws.accept();
  }

  receive(data: string) {
    const message = JSON.parse(data) as ServerMessage;
    this.reconcile(message);
    this.inbox.push(message);
    this.waiters = this.waiters.filter((w) => {
      if (!w.match(message)) return true;
      w.resolve(message);
      return false;
    });
  }

  private reconcile(message: ServerMessage) {
    if (message.type === "snapshot") {
      this.state = structuredClone(message.state);
    } else if (message.type === "patch" && this.state) {
      if (this.dropNextPatches > 0) {
        this.dropNextPatches--;
        return;
      }
      if (message.rev <= this.state.rev) return;
      if (message.rev > this.state.rev + 1) {
        this.sync();
        return;
      }
      applyChange(this.state, message.change);
      this.state.rev = message.rev;
    } else if (message.type === "pong" && this.state && message.rev > this.state.rev) {
      this.sync();
    }
  }

  sync() {
    this.syncs++;
    this.send({ type: "sync" });
  }

  send(message: unknown) {
    this.ws.send(typeof message === "string" ? message : JSON.stringify(message));
  }

  next<T extends ServerMessage["type"]>(type: T, where: (m: Msg<T>) => boolean = () => true, timeout = 2000): Promise<Msg<T>> {
    const match = (m: ServerMessage) => m.type === type && where(m as Msg<T>);
    const index = this.inbox.findIndex(match);
    if (index >= 0) return Promise.resolve(this.inbox.splice(index, 1)[0] as Msg<T>);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`Timed out waiting for ${type}`)), timeout);
      this.waiters.push({
        match,
        resolve: (m) => {
          clearTimeout(timer);
          this.inbox.splice(this.inbox.indexOf(m), 1);
          resolve(m as Msg<T>);
        },
      });
    });
  }

  async settle() {
    this.send({ type: "ping", t: Date.now() });
    await this.next("pong");
    await new Promise((r) => setTimeout(r, 30));
  }
}

function applyChange(state: BoothState, change: Change) {
  if (change.kind === "flavors") state.flavors = change.flavors;
  if (change.kind === "kiosk") state.kiosk = change.kiosk;
  if (change.kind === "alert") {
    const index = state.alerts.findIndex((a) => a.id === change.alert.id);
    if (index >= 0) state.alerts[index] = change.alert;
    else state.alerts.unshift(change.alert);
  }
}

async function open(token: string, device: string): Promise<Client> {
  const response = await exports.default.fetch(`${BASE}/v1/ws`, { headers: headers(token, device, { Upgrade: "websocket" }) });
  expect(response.status).toBe(101);
  const client = new Client(response.webSocket!);
  await client.next("snapshot");
  return client;
}

async function post(path: string, token: string, device: string, body: unknown) {
  const response = await exports.default.fetch(`${BASE}${path}`, {
    method: "POST",
    headers: headers(token, device, { "Content-Type": "application/json" }),
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
  return { status: response.status, body: (await response.json()) as any };
}

async function serverState(): Promise<BoothState> {
  const response = await exports.default.fetch(`${BASE}/v1/state`, { headers: headers(STAFF, "observer") });
  return (await response.json()) as BoothState;
}

function comparable(state: BoothState) {
  const alerts = [...state.alerts].sort((a, b) => a.id.localeCompare(b.id));
  return { rev: state.rev, flavors: state.flavors, alerts, health: state.kiosk.health, online: state.kiosk.online };
}

const healthy = KioskHealth.parse({
  appVersion: "0.1 (1)",
  environment: "Sandbox",
  authorized: true,
  authorizationState: "authorized",
  readers: [{ name: "Reader 1", state: "ready", batteryPercent: 80, isCharging: false }],
  readerReady: true,
  catalog: { ok: true, status: "Catalog OK", error: null },
  deviceBattery: { percent: 90, charging: true },
  screen: "attract",
});

const help = (id: string, seq: number, reason = "button") => ({ id, seq, type: "help", reason, message: `help ${id}` });
const healthEvent = (id: string, seq: number, overrides: Record<string, unknown> = {}) => ({
  id, seq, type: "health", health: { ...healthy, ...overrides },
});
const setSoldOut = (id: string, flavor: string, soldOut: boolean) => ({ id, type: "setSoldOut", flavor, soldOut, by: "Test" });

describe("HTTP hygiene", () => {
  it("rejects bad credentials, roles and devices with structured errors", async () => {
    const cases: [RequestInit, number, string][] = [
      [{}, 401, "unauthorized"],
      [{ headers: { Authorization: "Bearer nope", "X-Booth-Device": "d" } }, 401, "unauthorized"],
      [{ headers: headers(STAFF, "d"), body: "{}" }, 403, "forbidden"],
      [{ headers: { Authorization: `Bearer ${KIOSK}` }, body: "{}" }, 400, "bad_request"],
      [{ headers: headers(KIOSK, "bad device!"), body: "{}" }, 400, "bad_request"],
    ];
    for (const [init, status, code] of cases) {
      const response = await exports.default.fetch(`${BASE}/v1/events`, { method: "POST", ...init });
      expect(response.status).toBe(status);
      const body = (await response.json()) as { error: { code: string; retryable: boolean } };
      expect(body.error.code).toBe(code);
      expect(body.error.retryable).toBe(false);
    }
    expect((await exports.default.fetch(`${BASE}/v1/nothing`)).status).toBe(404);
    expect((await exports.default.fetch(`${BASE}/events`, { method: "POST", headers: headers(KIOSK, "d") })).status).toBe(404);
    const socket = await exports.default.fetch(`${BASE}/v1/ws`, { headers: { Upgrade: "websocket", Authorization: "Bearer nope", "X-Booth-Device": "d" } });
    expect(socket.status).toBe(401);
  });

  it("rejects malformed and oversized bodies", async () => {
    const device = newDevice("k");
    expect((await post("/v1/events", KIOSK, device, "{not json")).body.error.code).toBe("bad_request");
    expect((await post("/v1/events", KIOSK, device, { events: [] })).status).toBe(400);
    expect((await post("/v1/events", KIOSK, device, { events: "x" })).status).toBe(400);
    const big = await post("/v1/events", KIOSK, device, { events: [help("big", 1)], pad: "x".repeat(300 * 1024) });
    expect(big.status).toBe(413);
    expect(big.body.error.code).toBe("too_large");
    const lines = Array.from({ length: 501 }, (_, i) => ({ id: `${i}`, message: "m" }));
    expect((await post("/v1/logs", KIOSK, device, { lines })).status).toBe(400);
  });

  it("answers health checks, deep ones only with a token", async () => {
    const shallow = await exports.default.fetch(`${BASE}/v1/health`);
    expect(await shallow.json()).toMatchObject({ ok: true, protocol: 1 });
    expect((await exports.default.fetch(`${BASE}/v1/health?deep=1`)).status).toBe(401);
    const deep = await exports.default.fetch(`${BASE}/v1/health?deep=1`, { headers: headers(STAFF, "d") });
    expect(await deep.json()).toMatchObject({ ok: true, checks: { d1: true, hub: true } });
  });
});

describe("events", () => {
  it("dedupes help by id and merges repeats into one alert", async () => {
    const device = newDevice("k");
    const first = await post("/v1/events", KIOSK, device, { events: [help("h1", 1)] });
    expect(first.body.results[0]).toMatchObject({ id: "h1", status: "ok" });
    const alertId = first.body.results[0].alertId;

    const replay = await post("/v1/events", KIOSK, device, { events: [help("h1", 1)] });
    expect(replay.body.results[0]).toEqual({ id: "h1", status: "duplicate", alertId });

    const repeat = await post("/v1/events", KIOSK, device, { events: [help("h2", 2)] });
    expect(repeat.body.results[0].alertId).toBe(alertId);
    expect((await serverState()).alerts.find((a) => a.id === alertId)!.count).toBe(2);

    const otherDevice = await post("/v1/events", KIOSK, newDevice("k"), { events: [help("h1", 1)] });
    expect(otherDevice.body.results[0].status).toBe("ok");
  });

  it("drops stale or replayed health snapshots by seq and rejects bad items alone", async () => {
    const device = newDevice("k");
    const results = (await post("/v1/events", KIOSK, device, {
      events: [
        healthEvent("a", 5, { appVersion: "five" }),
        healthEvent("b", 3, { appVersion: "three" }),
        healthEvent("c", 5, { appVersion: "five again" }),
        healthEvent("d", 6, { appVersion: "six" }),
        { id: "e", seq: 7, type: "health", health: { readers: "nope" } },
        { id: "f", type: "mystery" },
      ],
    })).body.results as ItemResult[];
    expect(results.map((r) => r.status)).toEqual(["ok", "stale", "stale", "ok", "rejected", "rejected"]);
    expect((await serverState()).kiosk.health?.appVersion).toBe("six");
  });

  it("orders and times out on the server clock, not the client's", async () => {
    const device = newDevice("k");
    const before = Date.now();
    const result = await post("/v1/events", KIOSK, device, { events: [{ ...help("skew", 1, "no_reader"), at: "1999-01-01T00:00:00Z" }] });
    const alert = (await serverState()).alerts.find((a) => a.id === result.body.results[0].alertId)!;
    expect(alert.createdAt).toBeGreaterThanOrEqual(before);
  });
});

describe("hub", () => {
  it("broadcasts one patch per change with consecutive revs", async () => {
    const kiosk = await open(KIOSK, newDevice("k"));
    const staff = await open(STAFF, newDevice("s"));
    const startRev = staff.state!.rev;

    staff.send({ type: "action", action: setSoldOut("a1", "chocolate", true) });
    expect((await staff.next("result", (m) => m.id === "a1")).status).toBe("ok");
    await kiosk.settle();
    expect(kiosk.state!.flavors.find((f) => f.id === "chocolate")!.soldOut).toBe(true);

    staff.send({ type: "action", action: setSoldOut("a1", "chocolate", true) });
    expect((await staff.next("result", (m) => m.id === "a1")).status).toBe("duplicate");

    staff.send({ type: "action", action: setSoldOut("a2", "chocolate", false) });
    await staff.next("result", (m) => m.id === "a2");
    await staff.settle();
    await kiosk.settle();

    const revs = staff.inbox.filter((m): m is Msg<"patch"> => m.type === "patch").map((m) => m.rev);
    expect(revs.length).toBeGreaterThan(0);
    expect(revs).toEqual(revs.map((_, i) => startRev + 1 + i));
    const truth = comparable(await serverState());
    expect(comparable(staff.state!)).toEqual(truth);
    expect(comparable(kiosk.state!)).toEqual(truth);
  });

  it("reconciles after missed patches and ignores stale ones", async () => {
    const staff = await open(STAFF, newDevice("s"));
    const kiosk = await open(KIOSK, newDevice("k"));
    kiosk.dropNextPatches = 3;
    for (const [i, flavor] of ["vanilla", "cookies", "vanilla"].entries()) {
      staff.send({ type: "action", action: setSoldOut(`r${i}`, flavor, i !== 2) });
      await staff.next("result", (m) => m.id === `r${i}`);
    }
    await kiosk.settle();
    await kiosk.settle();
    expect(kiosk.syncs).toBeGreaterThan(0);
    expect(comparable(kiosk.state!)).toEqual(comparable(await serverState()));

    const before = structuredClone(kiosk.state!);
    kiosk.receive(JSON.stringify({ type: "patch", rev: 1, change: { kind: "flavors", flavors: [] } }));
    kiosk.receive(JSON.stringify({ type: "patch", rev: before.rev, change: { kind: "flavors", flavors: [] } }));
    expect(kiosk.state).toEqual(before);
  });

  it("answers acks, rejects unknown ids and forbids role mix-ups", async () => {
    const device = newDevice("k");
    const alertId = (await post("/v1/events", KIOSK, device, { events: [help("ack-me", 1, "idle")] })).body.results[0].alertId;
    const acked = await post("/v1/actions", STAFF, newDevice("s"), {
      actions: [
        { id: "x1", type: "ack", alertId, by: "Maya" },
        { id: "x2", type: "ack", alertId, by: "Sam" },
        { id: "x3", type: "ack", alertId: "nope" },
        { id: "x4", type: "setSoldOut", flavor: "pistachio", soldOut: true },
        { id: "x5", type: "launch" },
      ],
    });
    expect(acked.body.results.map((r: ItemResult) => r.status)).toEqual(["ok", "ok", "rejected", "rejected", "rejected"]);
    expect((await serverState()).alerts.find((a) => a.id === alertId)!.ackedBy).toBe("Maya");

    const kiosk = await open(KIOSK, newDevice("k"));
    kiosk.send({ type: "action", action: setSoldOut("y1", "vanilla", true) });
    expect((await kiosk.next("result")).error?.code).toBe("forbidden");
    expect((await post("/v1/actions", KIOSK, device, { actions: [setSoldOut("y2", "vanilla", true)] })).status).toBe(403);
  });

  it("survives malformed frames and closes floods", async () => {
    const staff = await open(STAFF, newDevice("s"));
    staff.send("{nope");
    expect((await staff.next("error")).error.code).toBe("bad_request");
    staff.send({ type: "teleport" });
    expect((await staff.next("error")).error.code).toBe("bad_request");
    staff.send({ type: "ping", t: 1, pad: "x".repeat(70 * 1024) });
    expect((await staff.next("error")).error.message).toMatch(/64 KB/);
    await staff.settle();

    const flooder = await open(STAFF, newDevice("s"));
    const closed = new Promise<number>((resolve) => flooder.ws.addEventListener("close", (e) => resolve(e.code)));
    for (let i = 0; i < FLOOD_LIMIT + 5; i++) flooder.send({ type: "ping" });
    expect(await closed).toBe(1008);
  });

  it("raises Kiosk offline from the alarm and resolves it on the next contact", async () => {
    const staff = await open(STAFF, newDevice("s"));
    const kiosk = await open(KIOSK, newDevice("k"));
    kiosk.send({ type: "heartbeat", t: Date.now(), screen: "attract" });
    await kiosk.next("pong");

    const stub = env.BOOTH.getByName("booth");
    await runInDurableObject(stub, (_booth: Booth, state) => {
      const row = state.storage.sql.exec<{ value: string }>("SELECT value FROM meta WHERE key = 'kiosk'").one();
      const value = JSON.parse(row.value);
      value.lastSeenAt = Date.now() - OFFLINE_AFTER_MS - 1000;
      state.storage.sql.exec("UPDATE meta SET value = ? WHERE key = 'kiosk'", JSON.stringify(value));
    });
    expect(await runDurableObjectAlarm(stub)).toBe(true);
    const isOffline = (m: Msg<"patch">) => m.change.kind === "alert" && m.change.alert.kind === "offline";
    const offline = await staff.next("patch", (m) => isOffline(m) && !(m.change as { alert: Alert }).alert.resolvedAt);
    expect((offline.change as { alert: Alert }).alert.title).toBe("Kiosk offline");

    await post("/v1/logs", KIOSK, newDevice("k"), { lines: [{ id: `contact-${Date.now()}`, message: "hi" }] });
    await staff.next("patch", (m) => isOffline(m) && (m.change as { alert: Alert }).alert.resolvedAt !== null, 4000);
    await staff.settle();
    expect(comparable(staff.state!)).toEqual(comparable(await serverState()));
  });

  it("waits out the health grace period before alerting and clears on recovery", async () => {
    const stub = env.BOOTH.getByName("booth");
    const device = newDevice("k");
    const t0 = Date.now();
    await stub.ingestEvents(device, [healthEvent("g1", 1, { readerReady: false, readers: [] })], t0);
    const open = () => serverState().then((s) => s.alerts.filter((a) => a.key === "health:reader" && !a.resolvedAt));
    expect(await open()).toEqual([]);
    await stub.ingestEvents(device, [healthEvent("g2", 2, { readerReady: false, readers: [] })], t0 + HEALTH_GRACE_MS - 1000);
    expect(await open()).toEqual([]);
    await runInDurableObject(stub, (booth: Booth) => booth.evaluate(t0 + HEALTH_GRACE_MS + 1));
    expect((await open()).map((a) => a.title)).toEqual(["No card reader ready"]);
    await stub.ingestEvents(device, [healthEvent("g3", 3)], t0 + HEALTH_GRACE_MS + 2);
    expect(await open()).toEqual([]);
  });

  it("keeps state, dedupe records and hibernated sockets across eviction", async () => {
    const stub = env.BOOTH.getByName("booth");
    const device = newDevice("k");
    const staff = await open(STAFF, newDevice("s"));
    const first = await post("/v1/events", KIOSK, device, { events: [help("evict-1", 1)] });
    staff.send({ type: "action", action: setSoldOut("evict-a", "cookies", true) });
    await staff.next("result", (m) => m.id === "evict-a");
    const before = await serverState();

    await evictDurableObject(stub);

    expect(comparable(await serverState())).toEqual(comparable(before));
    const replay = await post("/v1/events", KIOSK, device, { events: [help("evict-1", 1)] });
    expect(replay.body.results[0]).toMatchObject({ status: "duplicate", alertId: first.body.results[0].alertId });

    staff.send({ type: "action", action: setSoldOut("evict-b", "cookies", false) });
    expect((await staff.next("result", (m) => m.id === "evict-b")).status).toBe("ok");
    await staff.settle();
    expect(comparable(staff.state!)).toEqual(comparable(await serverState()));
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
      catalog: { ok: false, status: "", error: "Category TC not found" },
    });
    expect([...bad.keys()].sort()).toEqual(["health:auth", "health:catalog", "health:ipad-battery", "health:reader", "health:reader-battery"]);
  });
});

describe("logs and orders", () => {
  it("stores log lines once and counts rejects", async () => {
    const device = newDevice("k");
    const lines = [
      { id: `${device}-0`, ts: "2026-10-11T10:00:00.000-07:00", level: "info", message: "Authorized" },
      { id: `${device}-11`, ts: "2026-10-11T10:00:01.500-07:00", level: "error", message: "Payment failed (3)", context: { code: 3 } },
      { id: `${device}-40`, ts: "nonsense", level: "loud", message: "Odd line" },
      { message: "no id" },
    ];
    expect((await post("/v1/logs", KIOSK, device, { appVersion: "0.1 (1)", lines })).body).toEqual({ accepted: 3, stored: 3, duplicates: 0, rejected: 1 });
    expect((await post("/v1/logs", KIOSK, device, { lines })).body).toMatchObject({ stored: 0, duplicates: 3 });
    const rows = await env.DB.prepare("SELECT id, level, ts FROM logs WHERE device = ? ORDER BY id").bind(device).all<{ id: string; level: string; ts: number }>();
    expect(rows.results.map((r) => r.level)).toEqual(["info", "error", "info"]);
    expect(rows.results[0].ts).toBe(Date.parse("2026-10-11T17:00:00.000Z"));
  });

  it("stores each order once, by id and by Square payment id", async () => {
    const device = newDevice("k");
    const order = (id: string, payment: string | null, extra: Record<string, unknown> = {}) => ({
      id, orderNumber: 1, squarePaymentId: payment, totalCents: 900, simulated: false, paidAt: "2026-10-11T18:00:00Z",
      items: [{ vessel: "cone", flavors: ["vanilla"] }], ...extra,
    });
    const first = await post("/v1/orders", KIOSK, device, { orders: [order("o1", "PAY-1"), order("o2", null), order("bad", null, { totalCents: -5 })] });
    expect(first.body.results.map((r: ItemResult) => r.status)).toEqual(["ok", "ok", "rejected"]);
    const again = await post("/v1/orders", KIOSK, device, { orders: [order("o1", "PAY-1"), order("o3", "PAY-1"), order("o2", null)] });
    expect(again.body.results.map((r: ItemResult) => r.status)).toEqual(["duplicate", "duplicate", "duplicate"]);

    const listed = await exports.default.fetch(`${BASE}/v1/orders`, { headers: headers(STAFF, "s") });
    const body = (await listed.json()) as { orders: { id: string }[] };
    expect(body.orders.filter((o) => ["o1", "o2", "o3"].includes(o.id)).map((o) => o.id).sort()).toEqual(["o1", "o2"]);
  });

  it("drops logs past the retention window", async () => {
    const old = Date.now() - 31 * 24 * 60 * 60 * 1000;
    await env.DB.prepare("INSERT INTO logs (id, device, ts, level, message, received_at) VALUES ('old', 'd', ?, 'info', 'old', ?), ('new', 'd', ?, 'info', 'new', ?)")
      .bind(old, old, Date.now(), Date.now())
      .run();
    await worker.scheduled(createScheduledController({ cron: "17 9 * * *" }), env, createExecutionContext());
    const ids = (await env.DB.prepare("SELECT id FROM logs WHERE id IN ('old', 'new')").all<{ id: string }>()).results.map((r) => r.id);
    expect(ids).toEqual(["new"]);
  });
});
