import { createExecutionContext, createScheduledController, evictDurableObject, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { env, exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import worker from "../src";
import { ASSIST_TTL_MS, Booth, FLOOD_LIMIT, HEALTH_GRACE_MS, MAX_SNAPSHOT_ALERTS, OFFLINE_AFTER_MS, healthConditions } from "../src/booth";
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
      const timer = setTimeout(() => reject(new Error(`Timed out waiting for ${type}; inbox ${JSON.stringify(this.inbox.map((m) => m.type))}`)), timeout);
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
  if (change.kind === "supplies") state.supplies = change.supplies;
  if (change.kind === "kiosk") state.kiosk = change.kiosk;
  if (change.kind === "kioskOpen") state.kioskOpen = change.kioskOpen;
  if (change.kind === "kiosks") state.kiosks = change.kiosks;
  if (change.kind === "alert") {
    const index = state.alerts.findIndex((a) => a.id === change.alert.id);
    if (index >= 0) state.alerts[index] = change.alert;
    else state.alerts.unshift(change.alert);
    state.alerts = state.alerts.sort((a, b) => b.createdAt - a.createdAt).slice(0, MAX_SNAPSHOT_ALERTS);
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
  const kiosks = state.kiosks.map(({ id, name, open, debug, online, connected, health }) => ({ id, name, open, debug, online, connected, health }));
  return { rev: state.rev, kioskOpen: state.kioskOpen, flavors: state.flavors, supplies: state.supplies, alerts, kiosks };
}

const kioskIn = (state: BoothState, device: string) => state.kiosks.find((k) => k.id === device);

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
const setSupply = (id: string, kind: string, item: string, soldOut: boolean) => ({ id, type: "setSupply", kind, item, soldOut, by: "Test" });
const supplyOut = (state: BoothState, kind: string, id: string) => state.supplies.find((s) => s.kind === kind && s.id === id)?.soldOut;

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
    expect(kioskIn(await serverState(), device)?.health?.appVersion).toBe("six");
  });

  it("orders and times out on the server clock, not the client's", async () => {
    const device = newDevice("k");
    const before = Date.now();
    const result = await post("/v1/events", KIOSK, device, { events: [{ ...help("skew", 1, "no_reader"), at: "1999-01-01T00:00:00Z" }] });
    const alert = (await serverState()).alerts.find((a) => a.id === result.body.results[0].alertId)!;
    expect(alert.createdAt).toBeGreaterThanOrEqual(before);
  });
});

const setKioskOpen = (id: string, open: boolean) => ({ id, type: "setKioskOpen", open, by: "Test" });

describe("kiosk open flag", () => {
  it("defaults to open, closes and reopens idempotently and converges on every client", async () => {
    const kiosk = await open(KIOSK, newDevice("k"));
    const staff = await open(STAFF, newDevice("s"));
    const before = await serverState();
    if (!before.kioskOpen.open) {
      staff.send({ type: "action", action: setKioskOpen("reset-open", true) });
      await staff.next("result", (m) => m.id === "reset-open");
    }
    expect((await serverState()).kioskOpen.open).toBe(true);

    const device = newDevice("web");
    const close = setKioskOpen(`close-${device}`, false);
    const first = await post("/v1/actions", STAFF, device, { actions: [close] });
    expect(first.body.results[0].status).toBe("ok");
    const replay = await post("/v1/actions", STAFF, device, { actions: [close] });
    expect(replay.body.results[0].status).toBe("duplicate");
    const same = await post("/v1/actions", STAFF, device, { actions: [setKioskOpen(`close-again-${device}`, false)] });
    expect(same.body.results[0].status).toBe("ok");
    expect(same.body.rev).toBe(first.body.rev);

    await kiosk.settle();
    await staff.settle();
    const closed = await serverState();
    expect(closed.kioskOpen).toMatchObject({ open: false, changedBy: "Test" });
    expect(kiosk.state!.kioskOpen.open).toBe(false);
    expect(comparable(kiosk.state!)).toEqual(comparable(closed));

    kiosk.dropNextPatches = 1;
    const reopen = await post("/v1/actions", STAFF, device, { actions: [setKioskOpen(`reopen-${device}`, true), setSoldOut(`after-${device}`, "vanilla", true)] });
    expect(reopen.body.results.map((r: { status: string }) => r.status)).toEqual(["ok", "ok"]);
    await kiosk.settle();
    await kiosk.settle();
    await staff.settle();
    const truth = comparable(await serverState());
    expect(truth.kioskOpen.open).toBe(true);
    expect(comparable(kiosk.state!)).toEqual(truth);
    expect(comparable(staff.state!)).toEqual(truth);
    await post("/v1/actions", STAFF, device, { actions: [setSoldOut(`undo-${device}`, "vanilla", false)] });
  });

  it("rejects a malformed open action without failing the batch", async () => {
    const response = await post("/v1/actions", STAFF, newDevice("s"), { actions: [{ id: "bad-open", type: "setKioskOpen", open: "yes" }, setKioskOpen("fine-open", true)] });
    expect(response.body.results[0].status).toBe("rejected");
    expect(response.body.results[1].status).toBe("ok");
  });
});

const act = (device: string, actions: Record<string, unknown>[]) =>
  post("/v1/actions", STAFF, device, { actions: actions.map((a) => ({ id: crypto.randomUUID(), by: "Test", ...a })) });

describe("kiosk registry", () => {
  it("keeps one entry per kiosk device with a placeholder, reported and staff-given name", async () => {
    const staff = await open(STAFF, newDevice("s"));
    const first = `A1B2C3D4-${crypto.randomUUID().slice(0, 8)}`;
    const second = newDevice("k");
    const kiosk = await open(KIOSK, first);
    const other = await open(KIOSK, second);
    other.send({ type: "heartbeat", t: Date.now(), screen: "builder", name: "  Adam's   iPad " });
    await other.next("pong");
    let state = await serverState();
    expect(kioskIn(state, first)).toMatchObject({ name: "Kiosk A1B2", tag: "A1B2", open: true, debug: false, connected: true, online: true, customName: null });
    expect(kioskIn(state, second)).toMatchObject({ name: "Adam's iPad", reportedName: "Adam's iPad", screen: "builder" });
    expect(state.kiosks.findIndex((k) => k.id === first)).toBeLessThan(state.kiosks.findIndex((k) => k.id === second));

    const device = newDevice("web");
    expect((await act(device, [{ type: "renameKiosk", kiosk: second, name: "Front table" }])).body.results[0].status).toBe("ok");
    other.send({ type: "heartbeat", t: Date.now(), screen: "builder", name: "Adam's iPad" });
    await other.next("pong");
    expect(kioskIn(await serverState(), second)).toMatchObject({ name: "Front table", customName: "Front table", reportedName: "Adam's iPad" });
    await act(device, [{ type: "renameKiosk", kiosk: second, name: "" }]);
    expect(kioskIn(await serverState(), second)?.name).toBe("Adam's iPad");
    expect((await act(device, [{ type: "renameKiosk", kiosk: "nobody", name: "X" }])).body.results[0].error.code).toBe("not_found");

    await kiosk.settle();
    await staff.settle();
    state = await serverState();
    expect(comparable(staff.state!)).toEqual(comparable(state));
    expect(comparable(kiosk.state!)).toEqual(comparable(state));
  });

  it("opens and closes kiosks one at a time or all together, keeping the legacy flag for old clients", async () => {
    const one = newDevice("k");
    const two = newDevice("k");
    const kiosk = await open(KIOSK, one);
    await open(KIOSK, two);
    const device = newDevice("web");
    await act(device, [{ type: "setKioskOpen", open: true }]);

    expect((await act(device, [{ type: "setKioskOpen", kiosk: one, open: false }])).body.results[0].status).toBe("ok");
    let state = await serverState();
    expect(kioskIn(state, one)).toMatchObject({ open: false, openChangedBy: "Test" });
    expect(kioskIn(state, two)?.open).toBe(true);
    expect(state.kioskOpen.open).toBe(true);
    await kiosk.settle();
    expect(kioskIn(kiosk.state!, one)?.open).toBe(false);

    await act(`${device}-all`, [{ type: "setKioskOpen", open: false }]);
    state = await serverState();
    expect(state.kiosks.every((k) => !k.open)).toBe(true);
    expect(state.kioskOpen.open).toBe(false);

    await act(`${device}-again`, [{ type: "setKioskOpen", open: true }]);
    state = await serverState();
    expect(state.kiosks.every((k) => k.open)).toBe(true);
    expect(state.kioskOpen.open).toBe(true);
    expect((await act(device, [{ type: "setKioskOpen", kiosk: "nobody", open: false }])).body.results[0].error.code).toBe("not_found");
    await kiosk.settle();
    expect(comparable(kiosk.state!)).toEqual(comparable(await serverState()));
  });

  it("switches a kiosk's debug tools without touching the others", async () => {
    const one = newDevice("k");
    const two = newDevice("k");
    const kiosk = await open(KIOSK, one);
    await open(KIOSK, two);
    const device = newDevice("web");
    await act(device, [{ type: "setKioskDebug", kiosk: one, debug: true }]);
    await kiosk.next("patch", (m) => m.change.kind === "kiosks" && m.change.kiosks.find((k) => k.id === one)?.debug === true);
    const state = await serverState();
    expect(kioskIn(state, one)?.debug).toBe(true);
    expect(kioskIn(state, two)?.debug).toBe(false);
    const before = state.rev;
    expect((await act(`${device}-same`, [{ type: "setKioskDebug", kiosk: one, debug: true }])).body.rev).toBe(before);
    await act(`${device}-off`, [{ type: "setKioskDebug", kiosk: one, debug: false }]);
    expect(kioskIn(await serverState(), one)?.debug).toBe(false);
  });

  it("names the kiosk in help alerts, renames open ones and resolves them when the kiosk is removed", async () => {
    const device = `F00D${crypto.randomUUID().slice(0, 8)}`;
    const alertId = (await post("/v1/events", KIOSK, device, { events: [help(`${device}-h`, 1)] })).body.results[0].alertId;
    let alert = (await serverState()).alerts.find((a) => a.id === alertId)!;
    expect(alert).toMatchObject({ title: "Customer needs help at Kiosk F00D", key: `help:button:${device}`, kioskId: device });

    const other = newDevice("k");
    const otherAlert = (await post("/v1/events", KIOSK, other, { events: [help(`${other}-h`, 1)] })).body.results[0].alertId;
    expect(otherAlert).not.toBe(alertId);

    const staff = newDevice("web");
    await act(staff, [{ type: "renameKiosk", kiosk: device, name: "Adam's iPad" }]);
    alert = (await serverState()).alerts.find((a) => a.id === alertId)!;
    expect(alert.title).toBe("Customer needs help at Adam's iPad");

    expect((await act(`${staff}-rm`, [{ type: "removeKiosk", kiosk: device }])).body.results[0].status).toBe("ok");
    const state = await serverState();
    expect(kioskIn(state, device)).toBeUndefined();
    expect(state.alerts.find((a) => a.id === alertId)?.resolvedAt).not.toBeNull();
    expect(state.alerts.find((a) => a.id === otherAlert)?.resolvedAt).toBeNull();
    expect((await act(`${staff}-rm2`, [{ type: "removeKiosk", kiosk: device }])).body.results[0].status).toBe("ok");
  });

  it("raises a closed kiosk's offline alert as a warning, not urgent", async () => {
    const device = newDevice("k");
    await post("/v1/logs", KIOSK, device, { lines: [{ id: `closed-${device}`, message: "hi" }] });
    await new Promise((r) => setTimeout(r, 50));
    await act(newDevice("web"), [{ type: "setKioskOpen", kiosk: device, open: false }]);
    const stub = env.BOOTH.getByName("booth");
    await runInDurableObject(stub, (booth: Booth) => booth.evaluate(Date.now() + OFFLINE_AFTER_MS + 1000));
    const offline = (await serverState()).alerts.find((a) => a.key === `offline:${device}` && !a.resolvedAt);
    expect(offline?.severity).toBe("warning");
    await act(newDevice("web"), [{ type: "removeKiosk", kiosk: device }, { type: "setKioskOpen", open: true }]);
  });
});

describe("supplies", () => {
  it("lists flavors, cups and cones and toppings, all available to start", async () => {
    const state = await serverState();
    expect(state.supplies.map((s) => `${s.kind}:${s.id}`)).toEqual([
      ...state.flavors.map((f) => `flavor:${f.id}`),
      "vessel:cup", "vessel:cone",
      "topping:whip", "topping:chocolate", "topping:gummies", "topping:mms", "topping:sprinkles",
    ]);
    expect(state.supplies.filter((s) => s.kind === "topping").map((s) => s.name)).toEqual(["Whipped Cream", "Chocolate Syrup", "Gummy Bears", "M&M's", "Sprinkles"]);
    expect(state.supplies.filter((s) => s.kind === "vessel").map((s) => s.name)).toEqual(["Cups", "Waffle cones"]);
    expect(state.supplies.every((s) => !s.soldOut)).toBe(true);
  });

  it("sells a cone or topping out on every kiosk without touching the flavors patch old apps follow", async () => {
    const kioskA = await open(KIOSK, newDevice("k"));
    const kioskB = await open(KIOSK, newDevice("k"));
    const staff = await open(STAFF, newDevice("s"));
    const startRev = staff.state!.rev;

    staff.send({ type: "action", action: setSupply("cone-out", "vessel", "cone", true) });
    expect((await staff.next("result", (m) => m.id === "cone-out")).status).toBe("ok");
    staff.send({ type: "action", action: setSupply("chocolate-topping-out", "topping", "chocolate", true) });
    expect((await staff.next("result", (m) => m.id === "chocolate-topping-out")).status).toBe("ok");
    for (const client of [kioskA, kioskB, staff]) await client.settle();

    for (const client of [kioskA, kioskB]) {
      expect(supplyOut(client.state!, "vessel", "cone")).toBe(true);
      expect(supplyOut(client.state!, "topping", "chocolate")).toBe(true);
      expect(supplyOut(client.state!, "flavor", "chocolate")).toBe(false);
      expect(client.state!.flavors.find((f) => f.id === "chocolate")!.soldOut).toBe(false);
    }
    const patches = staff.inbox.filter((m): m is Msg<"patch"> => m.type === "patch" && m.rev > startRev);
    expect(patches.some((m) => m.change.kind === "flavors")).toBe(false);
    expect(patches.filter((m) => m.change.kind === "supplies")).toHaveLength(2);

    const alerts = (await serverState()).alerts.filter((a) => a.kind === "soldout" && !a.resolvedAt);
    expect(alerts.find((a) => a.key === "soldout:vessel:cone")).toMatchObject({ title: "Waffle cones are sold out", severity: "info" });
    expect(alerts.find((a) => a.key === "soldout:topping:chocolate")).toMatchObject({ title: "Chocolate Syrup is sold out", severity: "info" });

    staff.send({ type: "action", action: setSupply("cone-back", "vessel", "cone", false) });
    staff.send({ type: "action", action: setSupply("chocolate-topping-back", "topping", "chocolate", false) });
    await staff.next("result", (m) => m.id === "chocolate-topping-back");
    for (const client of [kioskA, kioskB, staff]) await client.settle();
    const truth = comparable(await serverState());
    expect(truth.supplies.every((s) => !s.soldOut)).toBe(true);
    for (const client of [kioskA, kioskB, staff]) expect(comparable(client.state!)).toEqual(truth);
  });

  it("warns when cups and cones are both out", async () => {
    const device = newDevice("web");
    await post("/v1/actions", STAFF, device, { actions: [setSupply(`cup-${device}`, "vessel", "cup", true), setSupply(`cone-${device}`, "vessel", "cone", true)] });
    const state = await serverState();
    const cone = state.alerts.find((a) => a.key === "soldout:vessel:cone" && !a.resolvedAt)!;
    expect(cone).toMatchObject({ severity: "warning", title: "Waffle cones are sold out" });
    expect(cone.detail).toMatch(/^No cups or cones left, so the kiosks show Closed/);
    expect(state.alerts.find((a) => a.key === "soldout:vessel:cup" && !a.resolvedAt)?.severity).toBe("info");
    await post("/v1/actions", STAFF, device, { actions: [setSupply(`cup-back-${device}`, "vessel", "cup", false), setSupply(`cone-back-${device}`, "vessel", "cone", false)] });
    expect((await serverState()).alerts.find((a) => a.key === "soldout:vessel:cone" && !a.resolvedAt)).toMatchObject({ title: "Waffle cones are back", severity: "info" });
  });

  it("keeps the legacy flavor action and the flavors list in step with supplies", async () => {
    const staff = await open(STAFF, newDevice("s"));
    const startRev = staff.state!.rev;
    staff.send({ type: "action", action: setSoldOut("legacy-out", "cookies", true) });
    await staff.next("result", (m) => m.id === "legacy-out");
    await staff.settle();
    const kinds = staff.inbox.filter((m): m is Msg<"patch"> => m.type === "patch" && m.rev > startRev).map((m) => m.change.kind);
    expect(kinds.slice(0, 2)).toEqual(["flavors", "supplies"]);
    expect(supplyOut(staff.state!, "flavor", "cookies")).toBe(true);

    staff.send({ type: "action", action: setSupply("new-back", "flavor", "cookies", false) });
    await staff.next("result", (m) => m.id === "new-back");
    await staff.settle();
    const state = await serverState();
    expect(state.flavors.find((f) => f.id === "cookies")!.soldOut).toBe(false);
    expect(supplyOut(state, "flavor", "cookies")).toBe(false);
    expect(comparable(staff.state!)).toEqual(comparable(state));
  });

  it("rejects unknown kinds and items without failing the batch, and is idempotent", async () => {
    const device = newDevice("web");
    const response = await post("/v1/actions", STAFF, device, {
      actions: [
        setSupply(`napkins-${device}`, "napkin", "paper", true),
        setSupply(`pistachio-${device}`, "topping", "pistachio", true),
        setSupply(`bowl-${device}`, "vessel", "bowl", true),
        setSupply(`sprinkles-${device}`, "topping", "sprinkles", true),
        setSupply(`sprinkles-again-${device}`, "topping", "sprinkles", true),
      ],
    });
    expect(response.body.results.map((r: ItemResult) => r.status)).toEqual(["rejected", "rejected", "rejected", "ok", "ok"]);
    expect(response.body.results[0].error.code).toBe("bad_request");
    expect(response.body.results[1].error.code).toBe("not_found");
    const state = await serverState();
    expect(state.alerts.filter((a) => a.key === "soldout:topping:sprinkles" && !a.resolvedAt)).toHaveLength(1);
    const replay = await post("/v1/actions", STAFF, device, { actions: [setSupply(`sprinkles-${device}`, "topping", "sprinkles", true)] });
    expect(replay.body.results[0].status).toBe("duplicate");
    await post("/v1/actions", STAFF, device, { actions: [setSupply(`sprinkles-back-${device}`, "topping", "sprinkles", false)] });
    expect(supplyOut(await serverState(), "topping", "sprinkles")).toBe(false);
  });

  it("converges when two staff pages toggle everything while a kiosk misses patches", async () => {
    const scooper = await open(STAFF, newDevice("s"));
    const toppings = await open(STAFF, newDevice("s"));
    const kiosk = await open(KIOSK, newDevice("k"));
    const scooperItems: [string, string][] = [["flavor", "vanilla"], ["flavor", "chocolate"], ["vessel", "cup"], ["vessel", "cone"]];
    const toppingItems: [string, string][] = [["topping", "whip"], ["topping", "gummies"], ["topping", "mms"]];
    const intended = new Map<string, boolean>();
    kiosk.dropNextPatches = 4;
    for (let i = 0; i < 24; i++) {
      const [client, items] = i % 2 === 0 ? [scooper, scooperItems] : [toppings, toppingItems];
      const [kind, item] = items[(i * 7) % items.length];
      const soldOut = !(intended.get(`${kind}:${item}`) ?? false);
      intended.set(`${kind}:${item}`, soldOut);
      client.send({ type: "action", action: setSupply(`burst-${i}-${kiosk.state!.rev}`, kind, item, soldOut) });
      await client.next("result", (m) => m.id.startsWith(`burst-${i}-`));
    }
    for (const client of [scooper, toppings, kiosk]) {
      await client.settle();
      await client.settle();
    }
    const truth = await serverState();
    for (const [key, soldOut] of intended) {
      const [kind, item] = key.split(":");
      expect(supplyOut(truth, kind, item)).toBe(soldOut);
    }
    expect(kiosk.syncs).toBeGreaterThan(0);
    for (const client of [scooper, toppings, kiosk]) expect(comparable(client.state!)).toEqual(comparable(truth));

    const device = newDevice("web");
    await post("/v1/actions", STAFF, device, {
      actions: [...intended].filter(([, out]) => out).map(([key], i) => {
        const [kind, item] = key.split(":");
        return setSupply(`burst-reset-${i}-${device}`, kind, item, false);
      }),
    });
    expect((await serverState()).supplies.every((s) => !s.soldOut)).toBe(true);
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

  it("raises an offline alert per kiosk from the alarm and resolves it on that kiosk's next contact", async () => {
    const staff = await open(STAFF, newDevice("s"));
    const device = newDevice("k");
    const other = newDevice("k");
    const kiosk = await open(KIOSK, device);
    const second = await open(KIOSK, other);
    kiosk.send({ type: "heartbeat", t: Date.now(), screen: "attract", name: "Front iPad" });
    await kiosk.next("pong");
    second.send({ type: "heartbeat", t: Date.now(), screen: "builder" });
    await second.next("pong");

    const stub = env.BOOTH.getByName("booth");
    await runInDurableObject(stub, (_booth: Booth, state) => {
      const row = state.storage.sql.exec<{ data: string }>("SELECT data FROM kiosks WHERE id = ?", device).one();
      const value = JSON.parse(row.data);
      value.lastSeenAt = Date.now() - OFFLINE_AFTER_MS - 1000;
      state.storage.sql.exec("UPDATE kiosks SET data = ? WHERE id = ?", JSON.stringify(value), device);
    });
    expect(await runDurableObjectAlarm(stub)).toBe(true);
    const isOffline = (m: Msg<"patch">) => m.change.kind === "alert" && m.change.alert.kind === "offline" && m.change.alert.kioskId === device;
    const offline = await staff.next("patch", (m) => isOffline(m) && !(m.change as { alert: Alert }).alert.resolvedAt);
    expect((offline.change as { alert: Alert }).alert).toMatchObject({ title: "Front iPad is offline", severity: "urgent", key: `offline:${device}` });
    const truth = await serverState();
    expect(kioskIn(truth, device)?.online).toBe(false);
    expect(kioskIn(truth, other)?.online).toBe(true);
    expect(truth.alerts.filter((a) => a.kind === "offline" && a.kioskId === other && !a.resolvedAt)).toEqual([]);

    await post("/v1/logs", KIOSK, other, { lines: [{ id: `contact-${other}`, message: "hi" }] });
    await new Promise((r) => setTimeout(r, 50));
    expect((await serverState()).alerts.find((a) => a.id === (offline.change as { alert: Alert }).alert.id)?.resolvedAt).toBeNull();
    await post("/v1/logs", KIOSK, device, { lines: [{ id: `contact-${device}`, message: "hi" }] });
    await staff.next("patch", (m) => isOffline(m) && (m.change as { alert: Alert }).alert.resolvedAt !== null, 4000);
    await staff.settle();
    expect(comparable(staff.state!)).toEqual(comparable(await serverState()));
  });

  it("waits out the health grace period before alerting and clears on recovery", async () => {
    const stub = env.BOOTH.getByName("booth");
    const device = newDevice("k");
    const t0 = Date.now();
    await stub.ingestEvents(device, [healthEvent("g1", 1, { readerReady: false, readers: [], kioskName: "Side iPad" })], t0);
    const open = () => serverState().then((s) => s.alerts.filter((a) => a.key === `health:reader:${device}` && !a.resolvedAt));
    expect(await open()).toEqual([]);
    await stub.ingestEvents(device, [healthEvent("g2", 2, { readerReady: false, readers: [] })], t0 + HEALTH_GRACE_MS - 1000);
    expect(await open()).toEqual([]);
    await runInDurableObject(stub, (booth: Booth) => booth.evaluate(t0 + HEALTH_GRACE_MS + 1));
    expect((await open()).map((a) => [a.title, a.kioskId])).toEqual([["No card reader ready at Side iPad", device]]);
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

describe("assist", () => {
  const cart = (overrides: Record<string, unknown> = {}) => ({
    screen: "builder",
    step: "flavors",
    editing: false,
    items: [
      { id: "item-1", vessel: "cone", flavors: ["vanilla"], toppings: ["whip"], cents: 600, current: false, inOrder: true },
      { id: "item-2", vessel: "cup", flavors: [], toppings: [], cents: 0, current: true, inOrder: false },
    ],
    customerName: "Alex",
    totalCents: 600,
    paying: false,
    orderingOpen: true,
    assisted: false,
    maxScoops: 3,
    results: [],
    ...overrides,
  });
  const command = (id: string, kiosk: string, fields: Record<string, unknown>) => ({ id, kiosk, by: "Toppings iPad", ...fields });
  const closed = async (client: Client) => {
    client.ws.close(1000, "done");
    await new Promise((r) => setTimeout(r, 50));
  };
  const kioskState = async (device: string) =>
    (await (await exports.default.fetch(`${BASE}/v1/state`, { headers: headers(KIOSK, device) })).json()) as BoothState;

  it("relays a kiosk's live session to staff only, without touching the revision, and drops it when the kiosk leaves", async () => {
    const staff = await open(STAFF, newDevice("s"));
    const device = newDevice("k");
    const kiosk = await open(KIOSK, device);
    await staff.settle();
    const rev = (await serverState()).rev;

    kiosk.send({ type: "session", session: cart() });
    const live = await staff.next("session", (m) => m.kiosk === device);
    expect(live.session).toMatchObject({ kiosk: device, customerName: "Alex", totalCents: 600, screen: "builder", step: "flavors" });
    expect(live.session!.items.map((i) => [i.id, i.vessel, i.flavors, i.toppings, i.current])).toEqual([
      ["item-1", "cone", ["vanilla"], ["whip"], false],
      ["item-2", "cup", [], [], true],
    ]);
    kiosk.send({ type: "session", session: cart({ screen: "name", step: null, customerName: "Alexandra" }) });
    await staff.next("session", (m) => m.kiosk === device && m.session?.customerName === "Alexandra");

    const truth = await serverState();
    expect(truth.rev).toBe(rev);
    expect(truth.sessions?.find((x) => x.kiosk === device)).toMatchObject({ screen: "name", customerName: "Alexandra" });
    expect((await kioskState(device)).sessions).toBeUndefined();
    expect(kiosk.inbox.filter((m) => m.type === "session")).toEqual([]);

    kiosk.send({ type: "session", session: { ...cart(), items: "lots" } });
    expect((await kiosk.next("error")).error.code).toBe("bad_request");
    staff.send({ type: "session", session: cart() });
    expect((await staff.next("error")).error.code).toBe("forbidden");

    const fresh = await open(STAFF, newDevice("s"));
    expect(fresh.state!.sessions?.find((x) => x.kiosk === device)?.customerName).toBe("Alexandra");

    await closed(kiosk);
    expect((await staff.next("session", (m) => m.kiosk === device)).session).toBeNull();
    expect((await serverState()).sessions?.find((x) => x.kiosk === device)).toBeUndefined();
  });

  it("tells the kiosk while any staff page is assisting it, and stops when the last one leaves", async () => {
    const device = newDevice("k");
    const other = newDevice("k");
    const toppings = await open(STAFF, newDevice("s"));
    toppings.send({ type: "assist", kiosk: device, by: "Toppings iPad" });
    await toppings.settle();

    const kiosk = await open(KIOSK, device);
    const bystander = await open(KIOSK, other);
    expect(await kiosk.next("assist")).toMatchObject({ active: true, by: "Toppings iPad", expiresIn: ASSIST_TTL_MS });
    expect((await bystander.next("assist")).active).toBe(false);

    const scooper = await open(STAFF, newDevice("s"));
    scooper.send({ type: "assist", kiosk: device, by: "Scooper iPad" });
    expect((await kiosk.next("assist")).active).toBe(true);
    toppings.send({ type: "assist", kiosk: null });
    expect((await kiosk.next("assist")).active).toBe(true);
    await closed(scooper);
    expect(await kiosk.next("assist")).toMatchObject({ active: false, by: null });

    toppings.send({ type: "assist", kiosk: device, by: "Toppings iPad" });
    expect((await kiosk.next("assist")).active).toBe(true);
    toppings.send({ type: "assist", kiosk: other, by: "Toppings iPad" });
    expect((await kiosk.next("assist")).active).toBe(false);
    expect((await bystander.next("assist")).active).toBe(true);
    toppings.send({ type: "assist", kiosk: null });
    expect((await bystander.next("assist")).active).toBe(false);

    kiosk.send({ type: "assist", kiosk: other });
    expect((await kiosk.next("error")).error.code).toBe("forbidden");
  });

  it("relays commands with their ids to the kiosk, and refuses them for a kiosk that isn't connected", async () => {
    const staff = await open(STAFF, newDevice("s"));
    const device = newDevice("k");
    const kiosk = await open(KIOSK, device);

    const add = command("c-1", device, { op: "addScoop", item: "item-2", flavor: "vanilla" });
    staff.send({ type: "command", command: add });
    expect(await staff.next("result", (m) => m.id === "c-1")).toMatchObject({ status: "ok" });
    expect((await kiosk.next("command")).command).toEqual(add);
    staff.send({ type: "command", command: add });
    expect((await kiosk.next("command")).command.id).toBe("c-1");
    await staff.next("result", (m) => m.id === "c-1");

    for (const op of [
      { op: "removeScoop", item: "item-1", flavor: "vanilla" },
      { op: "setVessel", item: "item-1", vessel: "cone" },
      { op: "setTopping", item: "item-1", topping: "sprinkles", on: true },
      { op: "addItem" },
      { op: "removeItem", item: "item-1" },
      { op: "setName", name: "Sam" },
      { op: "navigate", to: "summary" },
      { op: "startOver" },
    ]) {
      const id = `c-${op.op}`;
      staff.send({ type: "command", command: command(id, device, op) });
      expect((await staff.next("result", (m) => m.id === id)).status).toBe("ok");
      expect((await kiosk.next("command")).command).toMatchObject(op);
    }

    const bad = [
      command("b-1", device, { op: "launch" }),
      command("b-2", device, { op: "setVessel", item: "item-1", vessel: "bowl" }),
      command("b-3", device, { op: "navigate", to: "payment" }),
      command("b-4", device, { op: "addScoop", item: "", flavor: "vanilla" }),
    ];
    for (const c of bad) {
      staff.send({ type: "command", command: c });
      expect((await staff.next("result", (m) => m.id === c.id)).error?.code).toBe("bad_request");
    }

    staff.send({ type: "command", command: command("o-1", newDevice("k"), { op: "startOver" }) });
    expect((await staff.next("result", (m) => m.id === "o-1")).error?.code).toBe("kiosk_offline");
    kiosk.send({ type: "command", command: command("f-1", device, { op: "startOver" }) });
    expect((await kiosk.next("result", (m) => m.id === "f-1")).error?.code).toBe("forbidden");

    await closed(kiosk);
    staff.send({ type: "command", command: command("o-2", device, { op: "startOver" }) });
    const offline = await staff.next("result", (m) => m.id === "o-2");
    expect(offline).toMatchObject({ status: "rejected", error: { code: "kiosk_offline" } });
    expect(offline.error?.message).toMatch(/isn't connected/);
  });

  it("converges every staff page on the kiosk's latest session, across eviction", async () => {
    const stub = env.BOOTH.getByName("booth");
    const device = newDevice("k");
    const kiosk = await open(KIOSK, device);
    expect((await kiosk.next("assist")).active).toBe(false);
    const first = await open(STAFF, newDevice("s"));
    const second = await open(STAFF, newDevice("s"));
    second.send({ type: "assist", kiosk: device, by: "Toppings iPad" });
    expect((await kiosk.next("assist")).active).toBe(true);

    for (let i = 1; i <= 8; i++) {
      kiosk.send({ type: "session", session: cart({ totalCents: i * 100, results: [{ id: `r-${i}`, status: i % 2 ? "applied" : "rejected", message: "3 scoops max" }] }) });
    }
    await first.next("session", (m) => m.session?.totalCents === 800);
    await second.next("session", (m) => m.session?.totalCents === 800);

    await evictDurableObject(stub);

    const after = await serverState();
    expect(after.sessions?.find((x) => x.kiosk === device)).toMatchObject({ totalCents: 800, results: [{ id: "r-8", status: "rejected" }] });
    first.sync();
    const snapshot = await first.next("snapshot");
    expect(snapshot.state.sessions?.find((x) => x.kiosk === device)?.totalCents).toBe(800);
    await closed(second);
    expect((await kiosk.next("assist")).active).toBe(false);
  });
});

describe("hub storage upgrade", () => {
  it("drops the single-kiosk state and closes its unattributable alerts", async () => {
    const stub = env.BOOTH.getByName("booth");
    const legacyId = crypto.randomUUID();
    await runInDurableObject(stub, (_booth: Booth, state) => {
      const sql = state.storage.sql;
      sql.exec("ALTER TABLE alerts DROP COLUMN kiosk_id");
      sql.exec(
        "INSERT INTO alerts (id, key, kind, severity, title, detail, count, created_at, updated_at) VALUES (?, 'offline', 'offline', 'urgent', 'Kiosk offline', 'x', 1, ?, ?)",
        legacyId, Date.now(), Date.now(),
      );
      sql.exec("INSERT INTO meta (key, value) VALUES ('kioskOpen', ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value", JSON.stringify({ open: false, changedAt: 1, changedBy: "Old" }));
      sql.exec("UPDATE meta SET value = '1' WHERE key = 'schema'");
    });
    await evictDurableObject(stub);
    const state = await serverState();
    expect(state.alerts.find((a) => a.id === legacyId)?.resolvedAt).not.toBeNull();
    expect(state.alerts.find((a) => a.id === legacyId)?.kioskId).toBeNull();
    expect(state.kioskOpen.open).toBe(true);
    const device = newDevice("k");
    const alertId = (await post("/v1/events", KIOSK, device, { events: [help(`${device}-up`, 1)] })).body.results[0].alertId;
    expect((await serverState()).alerts.find((a) => a.id === alertId)?.kioskId).toBe(device);
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
