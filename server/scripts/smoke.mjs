// Live end-to-end check of a deployed booth.
// Usage: BOOTH_URL=https://... BOOTH_TOKEN=... STAFF_PIN=... node scripts/smoke.mjs [--offline]
import WebSocket from "ws";

const base = (process.env.BOOTH_URL ?? "https://techclub-icecream.adamxu.workers.dev").replace(/\/$/, "");
const token = process.env.BOOTH_TOKEN;
const pin = process.env.STAFF_PIN;
const waitForOffline = process.argv.includes("--offline");
if (!token || !pin) {
  console.error("Set BOOTH_TOKEN and STAFF_PIN");
  process.exit(2);
}

const run = Date.now().toString(36);
let failures = 0;

function check(name, ok, detail = "") {
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? `  (${detail})` : ""}`);
  if (!ok) failures++;
}

async function http(path, init = {}) {
  const response = await fetch(base + path, init);
  const text = await response.text();
  let body = text;
  try {
    body = JSON.parse(text);
  } catch {}
  return { status: response.status, headers: response.headers, body };
}

function socket(headers, protocols) {
  const url = base.replace(/^http/, "ws") + "/v1/ws";
  const ws = new WebSocket(url, protocols, { headers });
  const inbox = [];
  const waiters = [];
  ws.on("message", (data) => {
    const text = data.toString();
    if (text === "pong") return;
    const message = JSON.parse(text);
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
    send: (message) => ws.send(JSON.stringify(message)),
    next(type, where = () => true, timeout = 5000) {
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

const kioskAuth = { Authorization: `Bearer ${token}` };
const pinAuth = { Authorization: `PIN ${pin}` };
const pinProtocol = `pin.${Buffer.from(pin).toString("base64url")}`;

await step("health endpoint", async () => {
  const r = await http("/v1/health");
  check("health endpoint", r.status === 200 && r.body.ok === true);
});

await step("staff page", async () => {
  const r = await http("/");
  check("staff page served", r.status === 200 && String(r.body).includes("Booth staff"), `status ${r.status}`);
  check("staff page has a CSP", (r.headers.get("content-security-policy") ?? "").includes("default-src 'self'"));
});

await step("auth", async () => {
  check("state without credentials is 401", (await http("/v1/state")).status === 401);
  check("state with a wrong token is 401", (await http("/v1/state", { headers: { Authorization: "Bearer nope" } })).status === 401);
  check("login with a wrong PIN is 401", (await http("/v1/staff/login", { method: "POST", headers: { Authorization: "PIN 0" } })).status === 401);
  check("login with the PIN is 200", (await http("/v1/staff/login", { method: "POST", headers: pinAuth })).status === 200);
  const bad = socket({ Authorization: "Bearer nope" });
  check("websocket with a wrong token is refused", await bad.opened.then(() => false, (e) => e.message === "HTTP 401"));
});

const kiosk = socket(kioskAuth);
const staff = socket({}, ["booth.v1", pinProtocol]);

await step("websockets", async () => {
  await Promise.all([kiosk.opened, staff.opened]);
  check("staff subprotocol echoed", staff.ws.protocol === "booth.v1", staff.ws.protocol);
  const snapshot = await kiosk.next("snapshot");
  check("kiosk got a snapshot", typeof snapshot.state.soldOut === "object", JSON.stringify(snapshot.state.soldOut));
  await staff.next("snapshot");
  check("staff got a snapshot", true);
});

await step("heartbeat", async () => {
  kiosk.send({ type: "heartbeat", at: new Date().toISOString(), screen: "attract" });
  const pong = await kiosk.next("pong");
  check("heartbeat answered with pong", typeof pong.at === "number");
  const k = await staff.next("kiosk", (m) => m.kiosk.online && m.kiosk.screen === "attract");
  check("staff sees the kiosk online", k.kiosk.online);
});

await step("health", async () => {
  kiosk.send({
    type: "health",
    health: {
      appVersion: `smoke ${run}`, environment: "Sandbox", authorized: true, authorizationState: "authorized",
      readers: [{ name: "Smoke reader", state: "ready", batteryPercent: 77, isCharging: false }], readerReady: true,
      catalog: { ok: true, status: "Catalog OK" }, deviceBattery: { percent: 88, charging: true }, simulatePayment: true,
      screen: "attract", lastError: null,
      flavors: [{ id: "vanilla", name: "Vanilla" }, { id: "chocolate", name: "Chocolate" }, { id: "cookies", name: "Cookies & Cream" }],
    },
  });
  const k = await staff.next("kiosk", (m) => m.kiosk.health?.appVersion === `smoke ${run}`);
  check("staff sees the health snapshot", k.kiosk.health.readers[0].batteryPercent === 77);
});

await step("help", async () => {
  const id = `smoke-${run}`;
  kiosk.send({ type: "help", id, reason: "button", message: "Smoke test: please ignore", at: new Date().toISOString() });
  const alert = await staff.next("alert", (m) => m.alert.kind === "help" && m.alert.detail.includes("Smoke test"));
  check("staff got the help alert", alert.alert.severity === "urgent", alert.alert.title);
  const received = await kiosk.next("helpReceived", (m) => m.id === id);
  check("kiosk got helpReceived", received.alertId === alert.alert.id);
  staff.send({ type: "ack", id: alert.alert.id, by: "Smoke test" });
  const acked = await kiosk.next("alert", (m) => m.alert.id === alert.alert.id && m.alert.ackedAt);
  check("ack reached the kiosk", acked.alert.ackedBy === "Smoke test");
});

await step("sold out", async () => {
  staff.send({ type: "setSoldOut", flavor: "cookies", soldOut: true, by: "Smoke test" });
  const on = await kiosk.next("soldOut", (m) => m.flavor === "cookies");
  check("kiosk got cookies sold out", on.soldOut.cookies === true);
  const info = await staff.next("alert", (m) => m.alert.kind === "soldout" && m.alert.resolvedAt === null);
  check("staff got the sold-out notice", info.alert.title.includes("sold out"), info.alert.title);
  staff.send({ type: "setSoldOut", flavor: "cookies", soldOut: false, by: "Smoke test" });
  const off = await kiosk.next("soldOut", (m) => m.flavor === "cookies");
  check("kiosk got cookies back", off.soldOut.cookies === false);
});

await step("logs", async () => {
  const lines = [
    { id: `smoke-${run}-0`, ts: new Date().toISOString(), level: "info", message: "Smoke test log line" },
    { id: `smoke-${run}-1`, ts: new Date().toISOString(), level: "error", message: "Smoke test error line", context: { run } },
  ];
  const post = () => http("/v1/logs", {
    method: "POST",
    headers: { ...kioskAuth, "Content-Type": "application/json" },
    body: JSON.stringify({ device: "smoke-test", appVersion: `smoke ${run}`, lines }),
  });
  const first = await post();
  check("logs stored", first.status === 200 && first.body.stored === 2, JSON.stringify(first.body));
  const again = await post();
  check("log retry deduplicated", again.body.duplicates === 2, JSON.stringify(again.body));
});

await step("orders", async () => {
  const order = {
    id: `smoke-${run}`, orderNumber: 0, squareOrderId: `SIM-${run}`, squarePaymentId: `SIM-${run}`, customerName: "Smoke Test",
    totalCents: 700, subtotalCents: 700, taxCents: 0, card: "Simulated", simulated: true, paidAt: new Date().toISOString(),
    items: [{ vessel: "cup", flavors: ["vanilla", "chocolate"] }], lines: [], device: "smoke-test", appVersion: `smoke ${run}`,
  };
  const r = await http("/v1/orders", { method: "POST", headers: { ...kioskAuth, "Content-Type": "application/json" }, body: JSON.stringify(order) });
  check("order stored", r.status === 200 && r.body.duplicate === false, JSON.stringify(r.body));
  const listed = await http("/v1/orders", { headers: pinAuth });
  check("order listed for staff", listed.body.orders?.some((o) => o.id === order.id));
});

if (waitForOffline) {
  await step("offline", async () => {
    kiosk.ws.close();
    const started = Date.now();
    const alert = await staff.next("alert", (m) => m.alert.kind === "offline" && !m.alert.resolvedAt, 60_000);
    check("Kiosk offline raised after heartbeats stopped", true, `${Math.round((Date.now() - started) / 1000)} s after disconnect`);
    staff.send({ type: "ack", id: alert.alert.id, by: "Smoke test" });
    await staff.next("alert", (m) => m.alert.id === alert.alert.id && m.alert.ackedAt);
  });
}

kiosk.ws.close();
staff.ws.close();
console.log(failures === 0 ? "\nAll checks passed" : `\n${failures} check(s) failed`);
process.exit(failures === 0 ? 0 : 1);
