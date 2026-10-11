// Chaos test for the booth backend. Runs a simulated kiosk (durable on-disk outbox, websocket with
// reconciliation) and a simulated staff client through a proxy that drops, refuses and black-holes traffic,
// redeploys the staging Worker mid-session, replays and duplicates sends, skews the kiosk clock, and holds the
// kiosk offline for a long stretch across a restart. Then checks that no order was lost or stored twice and that
// every client converged on the hub's state.
//
//   set -a; . ~/.config/techclub-icecream/secrets.env; set +a
//   node scripts/chaos.mjs            # against staging; --quick for a shorter run, --no-redeploy to skip the redeploy
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import WebSocket from "ws";
import { startProxy } from "./chaos-proxy.mjs";

const UPSTREAM = process.env.CHAOS_UPSTREAM ?? "https://kiosk-staging.jamboree.techclub.pw";
const KIOSK_TOKEN = process.env.STAGING_BOOTH_TOKEN;
const STAFF_TOKEN = process.env.STAGING_STAFF_TOKEN;
const QUICK = process.argv.includes("--quick");
const REDEPLOY = !process.argv.includes("--no-redeploy");
const PORT = 8790 + Math.floor(Math.random() * 100) * 2;
const PROXY = `http://127.0.0.1:${PORT}`;
const RUN = `chaos-${Date.now().toString(36)}`;
const DIR = join("/tmp", "booth-chaos", RUN);
const serverDir = join(dirname(fileURLToPath(import.meta.url)), "..");
if (!KIOSK_TOKEN || !STAFF_TOKEN) {
  console.error("Set STAGING_BOOTH_TOKEN and STAGING_STAFF_TOKEN");
  process.exit(2);
}
mkdirSync(DIR, { recursive: true });

const started = Date.now();
// Everything the kiosk ever created, kept outside the outbox (which forgets items once stored) for verification.
const ledger = { orders: [], lastHealth: null };
const kioskStats = { posts: 0, failures: 0, replays: 0, replayMismatches: 0, rejected: [], restarts: 0 };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (line) => console.log(`${((Date.now() - started) / 1000).toFixed(1).padStart(6)}s  ${line}`);
const jitter = (ms) => ms * (0.5 + Math.random());

function applyChange(state, change) {
  if (change.kind === "flavors") state.flavors = change.flavors;
  if (change.kind === "kiosk") state.kiosk = change.kiosk;
  if (change.kind === "alert") {
    const index = state.alerts.findIndex((a) => a.id === change.alert.id);
    if (index >= 0) state.alerts[index] = change.alert;
    else state.alerts.unshift(change.alert);
  }
}

function comparable(state) {
  return {
    rev: state.rev,
    flavors: state.flavors,
    alerts: [...state.alerts].sort((a, b) => a.id.localeCompare(b.id)),
    health: state.kiosk.health,
    online: state.kiosk.online,
  };
}

/** Websocket client that follows PROTOCOL.md: snapshot, patches by rev, sync on gaps, pings, reconnect with backoff. */
class Hub {
  constructor({ name, token, device, onState }) {
    Object.assign(this, { name, token, device, onState });
    this.state = null;
    this.stats = { connects: 0, drops: 0, syncs: 0, stalePatches: 0, gaps: 0 };
    this.failures = 0;
    this.stopped = false;
    this.results = new Map();
    this.connect();
  }

  connect() {
    if (this.stopped) return;
    const ws = new WebSocket(PROXY.replace("http", "ws") + "/v1/ws", {
      headers: { Authorization: `Bearer ${this.token}`, "X-Booth-Device": this.device },
      handshakeTimeout: 8000,
    });
    this.ws = ws;
    let lastInbound = Date.now();
    const ping = setInterval(() => {
      if (Date.now() - lastInbound > 6000) {
        this.stats.drops++;
        ws.terminate();
        return;
      }
      this.send(this.name === "kiosk" ? { type: "heartbeat", t: Date.now(), screen: "builder" } : { type: "ping", t: Date.now() });
    }, 2000);
    ws.on("open", () => {
      this.stats.connects++;
      this.openedAt = Date.now();
    });
    ws.on("message", (data) => {
      lastInbound = Date.now();
      let message;
      try {
        message = JSON.parse(data.toString());
      } catch {
        return;
      }
      this.receive(message);
    });
    const retry = () => {
      clearInterval(ping);
      if (this.ws !== ws || this.stopped) return;
      this.ws = null;
      if (this.openedAt && Date.now() - this.openedAt > 10_000) this.failures = 0;
      this.openedAt = null;
      const delay = jitter(Math.min(8000, 250 * 2 ** this.failures++));
      setTimeout(() => this.connect(), delay);
    };
    ws.on("close", retry);
    ws.on("error", () => ws.terminate());
  }

  receive(message) {
    if (message.type === "snapshot") {
      this.state = structuredClone(message.state);
    } else if (message.type === "patch" && this.state) {
      if (message.rev <= this.state.rev) {
        this.stats.stalePatches++;
      } else if (message.rev > this.state.rev + 1) {
        this.stats.gaps++;
        this.sync();
      } else {
        applyChange(this.state, message.change);
        this.state.rev = message.rev;
      }
    } else if (message.type === "pong" && this.state && message.rev > this.state.rev) {
      this.sync();
    } else if (message.type === "result") {
      this.results.set(message.id, message);
    }
  }

  sync() {
    this.stats.syncs++;
    this.send({ type: "sync" });
  }

  send(message) {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(message));
      return true;
    }
    return false;
  }

  get connected() {
    return this.ws?.readyState === WebSocket.OPEN;
  }

  stop() {
    this.stopped = true;
    this.ws?.terminate();
  }
}

async function api(path, { token, device, body, method = body ? "POST" : "GET", base = PROXY, timeout = 10_000 }) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeout);
  try {
    const response = await fetch(base + path, {
      method,
      headers: { Authorization: `Bearer ${token}`, "X-Booth-Device": device, "Content-Type": "application/json" },
      body: body ? JSON.stringify(body) : undefined,
      signal: controller.signal,
    });
    const text = await response.text();
    let json = null;
    try {
      json = JSON.parse(text);
    } catch {}
    return { status: response.status, json, retryAfter: Number(response.headers.get("retry-after")) || 0 };
  } catch (error) {
    return { status: 0, json: null, error: error.message };
  } finally {
    clearTimeout(timer);
  }
}

/** The simulated kiosk: everything goes to a file before any send, lanes flush oldest first with backoff. */
class Kiosk {
  constructor({ device, file }) {
    this.file = file;
    this.device = device;
    this.skewMs = 0;
    this.replays = 0;
    this.stats = kioskStats;
    try {
      this.box = JSON.parse(readFileSync(file, "utf8"));
    } catch {
      this.box = { device, seq: 0, events: [], orders: [] };
    }
    this.lanes = { events: { next: 0, failures: 0, busy: false }, orders: { next: 0, failures: 0, busy: false } };
    this.hub = new Hub({ name: "kiosk", token: KIOSK_TOKEN, device: this.box.device });
    this.timer = setInterval(() => this.flush(), 200);
  }

  save() {
    writeFileSync(this.file + ".tmp", JSON.stringify(this.box));
    renameSync(this.file + ".tmp", this.file);
  }

  now() {
    return new Date(Date.now() + this.skewMs).toISOString();
  }

  order(extra = {}) {
    const id = randomUUID();
    const order = {
      id, orderNumber: this.box.orders.length + 1, squareOrderId: `SQ-${id.slice(0, 8)}`, squarePaymentId: `PAY-${id}`,
      customerName: "Chaos", totalCents: 700, subtotalCents: 700, taxCents: 0, card: "Simulated", simulated: true,
      paidAt: this.now(), appVersion: RUN, items: [{ vessel: "cup", flavors: ["vanilla", "chocolate"] }], ...extra,
    };
    this.box.orders.push(order);
    this.save();
    ledger.orders.push(order);
    return order;
  }

  event(fields) {
    this.box.seq++;
    const event = { id: randomUUID(), seq: this.box.seq, at: this.now(), ...fields };
    if (event.type === "health") this.box.events = this.box.events.filter((e) => e.type !== "health");
    this.box.events.push(event);
    this.save();
    if (event.type === "health") ledger.lastHealth = event.health.appVersion;
    return event;
  }

  async flush() {
    await Promise.all([this.flushLane("events", "/v1/events", 50), this.flushLane("orders", "/v1/orders", 20)]);
  }

  async flushLane(lane, path, size) {
    const state = this.lanes[lane];
    if (state.busy || Date.now() < state.next || this.box[lane].length === 0) return;
    state.busy = true;
    try {
      const batch = this.box[lane].slice(0, size);
      const response = await api(path, { token: KIOSK_TOKEN, device: this.box.device, body: { [lane]: batch } });
      this.stats.posts++;
      if (response.status !== 200 || !response.json?.results) {
        this.stats.failures++;
        const retryable = response.status === 0 || response.status === 429 || response.status >= 500;
        if (!retryable) throw new Error(`${lane} got non-retryable ${response.status}: ${JSON.stringify(response.json)}`);
        const backoff = Math.max(response.retryAfter * 1000, jitter(Math.min(5000, 200 * 2 ** state.failures++)));
        state.next = Date.now() + backoff;
        return;
      }
      state.failures = 0;
      const done = new Set();
      for (const result of response.json.results) {
        if (result.status === "rejected") this.stats.rejected.push(result);
        done.add(result.id);
      }
      this.box[lane] = this.box[lane].filter((item) => !done.has(item.id));
      this.save();
      if (Math.random() < this.replays) {
        this.stats.replays++;
        const replay = await api(path, { token: KIOSK_TOKEN, device: this.box.device, body: { [lane]: batch } });
        if (replay.status === 200 && replay.json.results.some((r) => r.status === "ok")) this.stats.replayMismatches++;
      }
    } finally {
      state.busy = false;
    }
  }

  get pending() {
    return this.box.events.length + this.box.orders.length;
  }

  stop() {
    clearInterval(this.timer);
    this.hub.stop();
  }
}

class Staff {
  constructor() {
    this.device = `${RUN}-staff`;
    this.hub = new Hub({ name: "staff", token: STAFF_TOKEN, device: this.device });
    this.intended = {};
    this.pending = new Map();
    this.timer = setInterval(() => this.retry(), 1000);
    this.stats = { actions: 0, viaHttp: 0, rejected: 0 };
  }

  setSoldOut(flavor, soldOut) {
    const action = { id: randomUUID(), type: "setSoldOut", flavor, soldOut, by: "Chaos" };
    for (const [id, entry] of this.pending) {
      if (entry.action.flavor === flavor && !this.hub.results.has(id)) this.pending.delete(id);
    }
    this.intended[flavor] = soldOut;
    this.pending.set(action.id, { action, sentAt: 0 });
    this.stats.actions++;
    this.retry();
  }

  async retry() {
    for (const [id, entry] of this.pending) {
      const result = this.hub.results.get(id);
      if (result) {
        if (result.status === "rejected") this.stats.rejected++;
        this.pending.delete(id);
        continue;
      }
      if (Date.now() - entry.sentAt < 3000) continue;
      entry.sentAt = Date.now();
      if (!this.hub.send({ type: "action", action: entry.action })) {
        this.stats.viaHttp++;
        const response = await api("/v1/actions", { token: STAFF_TOKEN, device: this.device, body: { actions: [entry.action] } });
        if (response.status === 200) this.hub.results.set(id, response.json.results[0]);
      }
    }
  }

  stop() {
    clearInterval(this.timer);
    this.hub.stop();
  }
}

function redeploy() {
  return new Promise((resolve) => {
    log("redeploying staging Worker");
    const child = spawn("npx", ["wrangler", "deploy", "--env", "staging"], { cwd: serverDir, stdio: ["ignore", "pipe", "pipe"] });
    let output = "";
    child.stdout.on("data", (d) => (output += d));
    child.stderr.on("data", (d) => (output += d));
    child.on("close", (code) => {
      const version = output.match(/Current Version ID: (\S+)/)?.[1];
      log(`redeploy finished (exit ${code}, version ${version ?? "?"})`);
      resolve({ code, version });
    });
  });
}

async function steady(seconds, kiosk, staff, { orderEvery = 500, helpEvery = 5000, toggleEvery = 15000 } = {}) {
  const until = Date.now() + seconds * 1000;
  let lastHelp = 0;
  let lastHealth = 0;
  let lastToggle = Date.now();
  while (Date.now() < until) {
    kiosk.current.order();
    if (Date.now() - lastHelp > helpEvery) {
      lastHelp = Date.now();
      kiosk.current.event({ type: "help", reason: ["button", "idle", "payment_failed", "no_reader"][Math.floor(Math.random() * 4)], message: `chaos ${RUN}` });
    }
    if (Date.now() - lastHealth > 3000) {
      lastHealth = Date.now();
      kiosk.current.event({ type: "health", health: health(`${RUN} ${Date.now()}`) });
    }
    if (staff && Date.now() - lastToggle > toggleEvery) {
      lastToggle = Date.now();
      const flavor = ["vanilla", "chocolate", "cookies"][Math.floor(Math.random() * 3)];
      staff.setSoldOut(flavor, !staff.intended[flavor]);
    }
    await sleep(orderEvery);
  }
}

function health(version) {
  return {
    appVersion: version, environment: "Sandbox", authorized: true, authorizationState: "authorized",
    readers: [{ name: "Chaos reader", state: "ready", batteryPercent: 70, isCharging: false }], readerReady: true,
    catalog: { ok: true, status: "Catalog OK", error: null }, deviceBattery: { percent: 80, charging: true },
    simulatePayment: true, screen: "builder", lastError: null, lastErrorAt: null,
    flavors: [{ id: "vanilla", name: "Vanilla" }, { id: "chocolate", name: "Chocolate" }, { id: "cookies", name: "Cookies & Cream" }],
  };
}

async function waitFor(label, predicate, timeoutMs) {
  const until = Date.now() + timeoutMs;
  while (Date.now() < until) {
    if (await predicate()) return true;
    await sleep(500);
  }
  log(`timed out waiting for ${label}`);
  return false;
}

async function main() {
  log(`run ${RUN}: proxy ${PROXY} -> ${UPSTREAM}, outbox ${DIR}`);
  const proxy = startProxy({ upstream: UPSTREAM, port: PORT, log });
  const file = join(DIR, "outbox.json");
  const device = `${RUN}-kiosk`;
  const kiosk = { current: new Kiosk({ device, file }) };
  const staff = new Staff();
  const scale = QUICK ? 0.4 : 1;
  const phases = [];
  const phase = async (name, body) => {
    const t = Date.now();
    log(`--- ${name}`);
    await body();
    phases.push({ name, seconds: Math.round((Date.now() - t) / 1000) });
  };

  await phase("steady", () => steady(20 * scale, kiosk, staff));

  await phase("connection drops and half-open sockets", async () => {
    const until = Date.now() + 45_000 * scale;
    const traffic = steady(45 * scale, kiosk, staff, { toggleEvery: 6000 });
    while (Date.now() < until) {
      await sleep(jitter(4000));
      if (Math.random() < 0.3) {
        proxy.setMode("blackhole");
        await sleep(jitter(8000));
        proxy.kill();
        proxy.setMode("up");
      } else if (Math.random() < 0.5) {
        proxy.setMode("down");
        proxy.kill();
        await sleep(jitter(3000));
        proxy.setMode("up");
      } else {
        proxy.kill();
      }
    }
    proxy.setMode("up");
    await traffic;
  });

  if (REDEPLOY) {
    await phase("server redeploy mid-session", async () => {
      const deploying = redeploy();
      await steady(5, kiosk, staff);
      const result = await deploying;
      if (result.code !== 0) throw new Error("redeploy failed");
      await steady(10 * scale, kiosk, staff, { toggleEvery: 4000 });
    });
  }

  const duplicatePayment = randomUUID();
  await phase("duplicate sends", async () => {
    kiosk.current.replays = 0.5;
    const sent = kiosk.current.box.orders.length;
    for (let i = 0; i < 10; i++) {
      const order = kiosk.current.order();
      kiosk.current.box.orders.push(structuredClone(order));
    }
    kiosk.current.order({ squarePaymentId: `PAY-${duplicatePayment}` });
    kiosk.current.order({ squarePaymentId: `PAY-${duplicatePayment}` });
    kiosk.current.save();
    log(`queued ${kiosk.current.box.orders.length - sent} orders including in-queue duplicates`);
    await steady(10 * scale, kiosk, staff);
    kiosk.current.replays = 0;
  });

  await phase("clock skew", async () => {
    kiosk.current.skewMs = 3 * 60 * 60 * 1000;
    await steady(5 * scale, kiosk, staff);
    kiosk.current.skewMs = -2 * 24 * 60 * 60 * 1000;
    await steady(5 * scale, kiosk, staff);
    kiosk.current.skewMs = 0;
  });

  await phase("long offline with a restart", async () => {
    proxy.setMode("down");
    proxy.kill();
    await steady(60 * scale, kiosk, null, { orderEvery: 400 });
    log(`restarting the kiosk with ${kiosk.current.pending} items queued on disk`);
    const hubStats = kiosk.current.hub.stats;
    kiosk.current.stop();
    kiosk.current = new Kiosk({ device, file });
    kiosk.current.hub.stats = hubStats;
    kioskStats.restarts++;
    await steady(60 * scale, kiosk, null, { orderEvery: 400 });
    log(`back online with ${kiosk.current.pending} items queued`);
    proxy.setMode("up");
    await waitFor("the outbox to drain", () => kiosk.current.pending === 0, 180_000);
  });

  await phase("settle", async () => {
    await waitFor("staff actions", () => staff.pending.size === 0, 30_000);
    await sleep(4000);
    kiosk.current.hub.sync();
    staff.hub.sync();
    await sleep(3000);
  });

  // Verification goes straight to the Worker, around the proxy.
  const allOrders = new Map(ledger.orders.map((order) => [order.id, order]));
  const listed = await api(`/v1/orders?since=${started - 3 * 24 * 60 * 60 * 1000}&limit=2000`, { token: STAFF_TOKEN, device: "chaos-verify", base: UPSTREAM });
  const stored = (listed.json?.orders ?? []).filter((o) => o.device === device);
  const storedIds = stored.map((o) => o.id);
  const expectedIds = [...allOrders.keys()];
  const paymentIds = new Map();
  for (const order of allOrders.values()) {
    if (!paymentIds.has(order.squarePaymentId)) paymentIds.set(order.squarePaymentId, order.id);
  }
  const expectedStored = new Set(paymentIds.values());
  const missing = [...expectedStored].filter((id) => !storedIds.includes(id));
  const unexpected = storedIds.filter((id) => !expectedStored.has(id));
  const duplicated = storedIds.length - new Set(storedIds).size;
  const storedPayments = stored.map((o) => o.square_payment_id);
  const duplicatedPayments = storedPayments.length - new Set(storedPayments).size;

  const truth = (await api("/v1/state", { token: STAFF_TOKEN, device: "chaos-verify", base: UPSTREAM })).json;
  const kioskConverged = JSON.stringify(comparable(kiosk.current.hub.state)) === JSON.stringify(comparable(truth));
  const staffConverged = JSON.stringify(comparable(staff.hub.state)) === JSON.stringify(comparable(truth));
  const soldOutMatches = Object.entries(staff.intended).every(([flavor, value]) => truth.flavors.find((f) => f.id === flavor)?.soldOut === value);
  const lastHealth = ledger.lastHealth;

  const report = {
    run: RUN,
    phases,
    proxy: proxy.stats,
    orders: {
      created: expectedIds.length,
      uniquePayments: expectedStored.size,
      stored: stored.length,
      missing: missing.length,
      unexpected: unexpected.length,
      duplicatedIds: duplicated,
      duplicatedPayments,
    },
    kiosk: { ...kiosk.current.stats, hub: kiosk.current.hub.stats, outboxLeft: kiosk.current.pending },
    staff: { ...staff.stats, hub: staff.hub.stats, pending: staff.pending.size },
    convergence: { rev: truth.rev, kioskConverged, staffConverged, soldOutMatches, healthIsLatest: truth.kiosk.health?.appVersion === lastHealth },
  };
  const pass = missing.length === 0 && unexpected.length === 0 && duplicated === 0 && duplicatedPayments === 0
    && kioskConverged && staffConverged && soldOutMatches && report.convergence.healthIsLatest
    && kiosk.current.pending === 0 && kiosk.current.stats.rejected.length === 0 && kiosk.current.stats.replayMismatches === 0;
  console.log(JSON.stringify(report, null, 2));
  console.log(pass ? "\nCHAOS PASS: no lost or duplicated orders, all clients converged" : "\nCHAOS FAIL");
  writeFileSync(join(DIR, "report.json"), JSON.stringify({ ...report, pass }, null, 2));
  kiosk.current.stop();
  staff.stop();
  await proxy.close();
  process.exit(pass ? 0 : 1);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
