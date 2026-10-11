// Live end-to-end check of a deployed booth.
//   set -a; . ~/.config/techclub-icecream/secrets.env; set +a
//   node scripts/smoke.mjs [--offline]                                   # production
//   BOOTH_URL=https://techclub-icecream-staging.adamxu.workers.dev BOOTH_TOKEN=$STAGING_BOOTH_TOKEN \
//     STAFF_TOKEN=$STAGING_STAFF_TOKEN node scripts/smoke.mjs            # staging
import { randomUUID } from "node:crypto";
import WebSocket from "ws";

const base = (process.env.BOOTH_URL ?? "https://techclub-icecream.adamxu.workers.dev").replace(/\/$/, "");
const kioskToken = process.env.BOOTH_TOKEN;
const staffToken = process.env.STAFF_TOKEN;
const waitForOffline = process.argv.includes("--offline");
if (!kioskToken || !staffToken) {
  console.error("Set BOOTH_TOKEN and STAFF_TOKEN");
  process.exit(2);
}

const run = Date.now().toString(36);
const kioskDevice = `smoke-${run}-kiosk`;
const staffDevice = `smoke-${run}-staff`;
let failures = 0;

function check(name, ok, detail = "") {
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? `  (${detail})` : ""}`);
  if (!ok) failures++;
}

async function http(path, { token, device, body, method = body ? "POST" : "GET" } = {}) {
  const headers = { "Content-Type": "application/json" };
  if (token) headers.Authorization = `Bearer ${token}`;
  if (device) headers["X-Booth-Device"] = device;
  const response = await fetch(base + path, { method, headers, body: body ? JSON.stringify(body) : undefined });
  let json = null;
  try {
    json = await response.json();
  } catch {}
  return { status: response.status, json };
}

function socket(token, device) {
  const ws = new WebSocket(base.replace(/^http/, "ws") + "/v1/ws", { headers: { Authorization: `Bearer ${token}`, "X-Booth-Device": device } });
  const inbox = [];
  const waiters = [];
  let rev = null;
  ws.on("message", (data) => {
    const message = JSON.parse(data.toString());
    if (message.type === "snapshot") rev = message.state.rev;
    if (message.type === "patch") {
      if (rev !== null && message.rev !== rev + 1 && message.rev > rev) check("patches arrive in rev order", false, `${rev} then ${message.rev}`);
      rev = Math.max(rev ?? 0, message.rev);
    }
    const index = waiters.findIndex((w) => w.match(message));
    if (index >= 0) waiters.splice(index, 1)[0].resolve(message);
    else inbox.push(message);
  });
  const opened = new Promise((resolve, reject) => {
    ws.once("open", resolve);
    ws.once("unexpected-response", (_req, res) => reject(new Error(`HTTP ${res.statusCode}`)));
    ws.once("error", reject);
  });
  return {
    ws,
    opened,
    get rev() { return rev; },
    send: (message) => ws.send(JSON.stringify(message)),
    next(type, where = () => true, timeout = 8000) {
      const match = (m) => m.type === type && where(m);
      const index = inbox.findIndex(match);
      if (index >= 0) return Promise.resolve(inbox.splice(index, 1)[0]);
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error(`timed out waiting for ${type}`)), timeout);
        waiters.push({ match, resolve: (m) => { clearTimeout(timer); resolve(m); } });
      });
    },
  };
}

async function step(name, fn) {
  try {
    await fn();
  } catch (error) {
    check(name, false, error.message);
  }
}

const alertPatch = (where) => (m) => m.change.kind === "alert" && where(m.change.alert);

await step("health", async () => {
  const shallow = await http("/v1/health");
  check("health endpoint", shallow.status === 200 && shallow.json.protocol === 1);
  const deep = await http("/v1/health?deep=1", { token: staffToken, device: staffDevice });
  check("deep health (D1 and hub)", deep.status === 200 && deep.json.checks?.d1 && deep.json.checks?.hub, JSON.stringify(deep.json?.checks));
  check("no staff page any more", (await http("/")).status === 404);
});

await step("auth", async () => {
  check("state without a token is 401", (await http("/v1/state", { device: "x" })).status === 401);
  check("wrong token is 401", (await http("/v1/state", { token: "nope", device: "x" })).status === 401);
  check("staff can't post events (403)", (await http("/v1/events", { token: staffToken, device: staffDevice, body: { events: [] } })).status === 403);
  const missingDevice = await http("/v1/state", { token: kioskToken });
  check("missing device header is 400", missingDevice.status === 400 && missingDevice.json?.error?.code === "bad_request");
  const bad = socket("nope", "x");
  check("websocket with a wrong token is refused", await bad.opened.then(() => false, (e) => e.message === "HTTP 401"));
});

const kiosk = socket(kioskToken, kioskDevice);
const staff = socket(staffToken, staffDevice);

await step("websockets", async () => {
  await Promise.all([kiosk.opened, staff.opened]);
  const snapshot = await kiosk.next("snapshot");
  check("kiosk got a snapshot", Array.isArray(snapshot.state.flavors), `rev ${snapshot.state.rev}`);
  await staff.next("snapshot");
  check("staff got a snapshot", true);
});

await step("heartbeat", async () => {
  kiosk.send({ type: "heartbeat", t: Date.now(), screen: "attract" });
  const pong = await kiosk.next("pong");
  check("heartbeat answered with pong", typeof pong.rev === "number" && pong.t !== null);
});

await step("health event", async () => {
  const event = {
    id: randomUUID(), seq: 1, type: "health", at: new Date().toISOString(),
    health: {
      appVersion: `smoke ${run}`, environment: "Sandbox", authorized: true, authorizationState: "authorized",
      readers: [{ name: "Smoke reader", state: "ready", batteryPercent: 77, isCharging: false }], readerReady: true,
      catalog: { ok: true, status: "Catalog OK", error: null }, deviceBattery: { percent: 88, charging: true },
      simulatePayment: true, screen: "attract", lastError: null, lastErrorAt: null,
    },
  };
  const r = await http("/v1/events", { token: kioskToken, device: kioskDevice, body: { events: [event] } });
  check("health stored", r.json?.results?.[0]?.status === "ok", JSON.stringify(r.json?.results));
  const k = await staff.next("patch", (m) => m.change.kind === "kiosk" && m.change.kiosk.health?.appVersion === `smoke ${run}`);
  check("staff got the health patch", k.change.kiosk.health.readers[0].batteryPercent === 77);
  const stale = await http("/v1/events", { token: kioskToken, device: kioskDevice, body: { events: [{ ...event, id: randomUUID() }] } });
  check("a replayed seq is stale", stale.json?.results?.[0]?.status === "stale");
});

await step("help", async () => {
  const id = randomUUID();
  const help = { id, seq: 2, type: "help", reason: "button", message: "Smoke test: please ignore", at: new Date().toISOString() };
  const r = await http("/v1/events", { token: kioskToken, device: kioskDevice, body: { events: [help] } });
  const alertId = r.json?.results?.[0]?.alertId;
  check("help stored", r.json?.results?.[0]?.status === "ok" && !!alertId);
  const alert = await staff.next("patch", alertPatch((a) => a.id === alertId));
  check("staff got the help alert", alert.change.alert.severity === "urgent", alert.change.alert.title);
  const again = await http("/v1/events", { token: kioskToken, device: kioskDevice, body: { events: [help] } });
  check("help retry is a duplicate", again.json?.results?.[0]?.status === "duplicate" && again.json.results[0].alertId === alertId);
  const ackID = randomUUID();
  staff.send({ type: "action", action: { id: ackID, type: "ack", alertId, by: "Smoke test" } });
  check("ack result", (await staff.next("result", (m) => m.id === ackID)).status === "ok");
  const acked = await kiosk.next("patch", alertPatch((a) => a.id === alertId && a.ackedAt));
  check("ack reached the kiosk", acked.change.alert.ackedBy === "Smoke test");
});

await step("sold out", async () => {
  for (const soldOut of [true, false]) {
    const id = randomUUID();
    staff.send({ type: "action", action: { id, type: "setSoldOut", flavor: "cookies", soldOut, by: "Smoke test" } });
    check(`setSoldOut ${soldOut} result`, (await staff.next("result", (m) => m.id === id)).status === "ok");
    const patch = await kiosk.next("patch", (m) => m.change.kind === "flavors" && m.change.flavors.find((f) => f.id === "cookies")?.soldOut === soldOut);
    check(`kiosk saw cookies soldOut=${soldOut}`, !!patch);
  }
  const viaHttp = await http("/v1/actions", { token: staffToken, device: staffDevice, body: { actions: [{ id: randomUUID(), type: "setSoldOut", flavor: "cookies", soldOut: false }] } });
  check("setSoldOut over HTTP", viaHttp.json?.results?.[0]?.status === "ok");
});

await step("logs", async () => {
  const lines = [
    { id: `smoke-${run}-0`, ts: new Date().toISOString(), level: "info", message: "Smoke test log line" },
    { id: `smoke-${run}-1`, ts: new Date().toISOString(), level: "error", message: "Smoke test error line", context: { run } },
  ];
  const first = await http("/v1/logs", { token: kioskToken, device: kioskDevice, body: { appVersion: `smoke ${run}`, lines } });
  check("logs stored", first.json?.stored === 2, JSON.stringify(first.json));
  const again = await http("/v1/logs", { token: kioskToken, device: kioskDevice, body: { lines } });
  check("log retry deduplicated", again.json?.duplicates === 2, JSON.stringify(again.json));
});

await step("orders", async () => {
  const order = {
    id: randomUUID(), orderNumber: 0, squareOrderId: `SIM-${run}`, squarePaymentId: `SIM-${run}`, customerName: "Smoke Test",
    totalCents: 700, subtotalCents: 700, taxCents: 0, card: "Simulated", simulated: true, paidAt: new Date().toISOString(),
    appVersion: `smoke ${run}`, items: [{ vessel: "cup", flavors: ["vanilla", "chocolate"] }],
  };
  const r = await http("/v1/orders", { token: kioskToken, device: kioskDevice, body: { orders: [order] } });
  check("order stored", r.json?.results?.[0]?.status === "ok", JSON.stringify(r.json));
  const twice = await http("/v1/orders", { token: kioskToken, device: kioskDevice, body: { orders: [order, { ...order, id: randomUUID() }] } });
  check("order retry and same payment are duplicates", twice.json?.results?.every((x) => x.status === "duplicate"), JSON.stringify(twice.json));
  const listed = await http("/v1/orders", { token: staffToken, device: staffDevice });
  check("order listed for staff", listed.json?.orders?.filter((o) => o.square_payment_id === `SIM-${run}`).length === 1);
});

if (waitForOffline) {
  await step("offline", async () => {
    kiosk.ws.close();
    const started = Date.now();
    const alert = await staff.next("patch", alertPatch((a) => a.kind === "offline" && !a.resolvedAt), 60_000);
    check("Kiosk offline raised after contact stopped", true, `${Math.round((Date.now() - started) / 1000)} s after disconnect`);
    const id = randomUUID();
    staff.send({ type: "action", action: { id, type: "ack", alertId: alert.change.alert.id, by: "Smoke test" } });
    await staff.next("result", (m) => m.id === id);
  });
}

kiosk.ws.close();
staff.ws.close();
console.log(failures === 0 ? "\nAll checks passed" : `\n${failures} check(s) failed`);
process.exit(failures === 0 ? 0 : 1);
