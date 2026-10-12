// Live end-to-end check of a deployed booth.
//   set -a; . ~/.config/techclub-icecream/secrets.env; set +a
//   node scripts/smoke.mjs [--offline]                                   # production
//   BOOTH_URL=https://kiosk-staging.jamboree.techclub.pw BOOTH_TOKEN=$STAGING_BOOTH_TOKEN \
//     STAFF_TOKEN=$STAGING_STAFF_TOKEN node scripts/smoke.mjs --checkout # staging
// --checkout creates a real (unpaid) Square order through /v1/checkout; leave it off for production.
import { randomUUID } from "node:crypto";
import WebSocket from "ws";

const base = (process.env.BOOTH_URL ?? "https://kiosk.jamboree.techclub.pw").replace(/\/$/, "");
const kioskToken = process.env.BOOTH_TOKEN;
const staffToken = process.env.STAFF_TOKEN;
const waitForOffline = process.argv.includes("--offline");
const tryCheckout = process.argv.includes("--checkout");
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
  check("snapshot says whether the kiosk is open", typeof snapshot.state.kioskOpen?.open === "boolean", `open ${snapshot.state.kioskOpen?.open}`);
  await staff.next("snapshot");
  check("staff got a snapshot", true);
});

await step("heartbeat", async () => {
  kiosk.send({ type: "heartbeat", t: Date.now(), screen: "attract", name: "Smoke kiosk" });
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
  const mine = (m) => m.change.kiosks?.find((k) => k.id === kioskDevice);
  const k = await staff.next("patch", (m) => m.change.kind === "kiosks" && mine(m)?.health?.appVersion === `smoke ${run}`);
  check("staff got the health patch", mine(k).health.readers[0].batteryPercent === 77);
  const stale = await http("/v1/events", { token: kioskToken, device: kioskDevice, body: { events: [{ ...event, id: randomUUID() }] } });
  check("a replayed seq is stale", stale.json?.results?.[0]?.status === "stale");
});

const kioskEntry = async () => (await http("/v1/state", { token: staffToken, device: staffDevice })).json?.kiosks?.find((k) => k.id === kioskDevice);
const act = (action) => http("/v1/actions", { token: staffToken, device: staffDevice, body: { actions: [{ id: randomUUID(), by: "Smoke test", ...action }] } });

await step("kiosk registry", async () => {
  const entry = await kioskEntry();
  check("the kiosk is in the registry", !!entry && entry.name === "Smoke kiosk" && entry.online, entry ? `${entry.name}, tag ${entry.tag}` : "missing");
  await act({ type: "renameKiosk", kiosk: kioskDevice, name: `Smoke ${run}` });
  check("staff renamed it", (await kioskEntry())?.name === `Smoke ${run}`);
  await act({ type: "setKioskDebug", kiosk: kioskDevice, debug: true });
  const debug = await kiosk.next("patch", (m) => m.change.kind === "kiosks" && m.change.kiosks.find((k) => k.id === kioskDevice)?.debug === true);
  check("the kiosk saw its debug tools turned on", !!debug);
  await act({ type: "setKioskDebug", kiosk: kioskDevice, debug: false });
  const before = await http("/v1/state", { token: staffToken, device: staffDevice });
  const others = before.json.kiosks.filter((k) => k.id !== kioskDevice);
  await act({ type: "setKioskOpen", kiosk: kioskDevice, open: false });
  const closed = await http("/v1/state", { token: staffToken, device: staffDevice });
  const closedEntry = closed.json.kiosks.find((k) => k.id === kioskDevice);
  check("closing one kiosk leaves the others alone", closedEntry?.open === false && others.every((o) => closed.json.kiosks.find((k) => k.id === o.id)?.open === o.open));
  await act({ type: "setKioskOpen", kiosk: kioskDevice, open: true });
  check("reopened", (await kioskEntry())?.open === true);
});

await step("help", async () => {
  const id = randomUUID();
  const help = { id, seq: 2, type: "help", reason: "button", message: "Smoke test: please ignore", at: new Date().toISOString() };
  const r = await http("/v1/events", { token: kioskToken, device: kioskDevice, body: { events: [help] } });
  const alertId = r.json?.results?.[0]?.alertId;
  check("help stored", r.json?.results?.[0]?.status === "ok" && !!alertId);
  const alert = await staff.next("patch", alertPatch((a) => a.id === alertId));
  check("staff got the help alert, naming the kiosk", alert.change.alert.severity === "urgent" && alert.change.alert.kioskId === kioskDevice && alert.change.alert.title.endsWith(`at Smoke ${run}`), alert.change.alert.title);
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

const receiptToken = randomUUID().replace(/-/g, "").slice(0, 24);

await step("square", async () => {
  const status = await http("/v1/square/status", { token: staffToken, device: staffDevice });
  check("square status for staff", status.status === 200 && typeof status.json?.environment === "string", `${status.json?.environment}, source ${status.json?.source}`);
  check("square status refused to the kiosk", (await http("/v1/square/status", { token: kioskToken, device: kioskDevice })).status === 403);
  const credentials = await http("/v1/square/credentials", { token: kioskToken, device: kioskDevice });
  if (credentials.status === 503 && credentials.json?.error?.code === "not_configured") {
    console.log("SKIP  square credentials (not configured on this server)");
    return;
  }
  check("square credentials for the kiosk", credentials.status === 200 && !!credentials.json?.accessToken && !!credentials.json?.locationId, `${credentials.json?.source}, ${credentials.json?.locationId}`);
  if (!tryCheckout) return;
  const cart = {
    id: randomUUID(), receiptToken, orderNumber: 0, customerName: "Smoke Test", sourceName: "Smoke test", quotedCents: 1100,
    locationId: credentials.json.locationId,
    items: [{ vessel: "cone", flavors: ["vanilla", "chocolate"], toppings: ["sprinkles"] }, { vessel: "cup", flavors: ["cookies"] }],
  };
  const started = Date.now();
  const first = await http("/v1/checkout", { token: kioskToken, device: kioskDevice, body: cart });
  check("checkout created a Square order", first.status === 200 && first.json?.status === "created" && !!first.json?.squareOrderId,
    `${Date.now() - started} ms, ${first.json?.totalCents ?? JSON.stringify(first.json)} cents, catalog ${first.json?.usedCatalog}`);
  check("checkout priced like the kiosk", first.json?.expectedSubtotalCents === 1100 && first.json?.priceMatches === true, first.json?.catalogError ?? "");
  const again = await http("/v1/checkout", { token: kioskToken, device: kioskDevice, body: cart });
  check("checkout retry replays the same order", again.json?.status === "duplicate" && again.json?.squareOrderId === first.json?.squareOrderId);
  const receipt = await fetch(`${base}/r/${receiptToken}`);
  check("receipt page knows the checkout", receipt.status === 200);
});

await step("staff session and dashboard", async () => {
  const session = await http("/v1/staff/session", { body: { pin: staffToken } });
  check("staff session issued", session.status === 200 && session.json?.token?.startsWith("st1."));
  const stats = await http("/v1/stats", { token: session.json?.token, device: staffDevice });
  check("stats with a staff session", stats.status === 200 && typeof stats.json?.orders === "number", `${stats.json?.orders} orders in 24 h`);
  check("dashboard redirects to the staff page picker", (await fetch(`${base}/dashboard`, { redirect: "manual" })).headers.get("location") === "/staff");
  for (const page of ["scooper", "toppings", "organizer", "board"]) {
    const response = await fetch(`${base}/staff/${page}`, { headers: { Cookie: `booth_staff=${session.json?.token}` } });
    check(`staff page ${page} served`, response.status === 200 && (await response.text()).includes("new WebSocket"));
  }
});

await step("orders", async () => {
  const order = {
    id: randomUUID(), orderNumber: 0, squareOrderId: `SIM-${run}`, squarePaymentId: `SIM-${run}`, customerName: "Smoke Test",
    totalCents: 700, subtotalCents: 700, taxCents: 0, card: "Simulated", simulated: true, paidAt: new Date().toISOString(),
    appVersion: `smoke ${run}`, receiptToken, items: [{ vessel: "cup", flavors: ["vanilla", "chocolate"], toppings: ["whip"] }],
  };
  const r = await http("/v1/orders", { token: kioskToken, device: kioskDevice, body: { orders: [order] } });
  check("order stored", r.json?.results?.[0]?.status === "ok", JSON.stringify(r.json));
  const fed = await staff.next("patch", (m) => m.change.kind === "order" && m.change.order.id === order.id);
  check("staff got the order in the feed", fed.change.order.status === "paid" && fed.change.order.items[0].toppings[0] === "whip");
  const statusID = randomUUID();
  staff.send({ type: "action", action: { id: statusID, type: "setOrderStatus", orderId: order.id, status: "collected", by: "Smoke test" } });
  check("setOrderStatus result", (await staff.next("result", (m) => m.id === statusID)).status === "ok");
  const receipt = await fetch(`${base}/r/${receiptToken}`);
  check("receipt page knows the paid order", receipt.status === 200 && (await receipt.text()).includes("Paid"));
  const twice = await http("/v1/orders", { token: kioskToken, device: kioskDevice, body: { orders: [order, { ...order, id: randomUUID() }] } });
  check("order retry and same payment are duplicates", twice.json?.results?.every((x) => x.status === "duplicate"), JSON.stringify(twice.json));
  const listed = await http("/v1/orders", { token: staffToken, device: staffDevice });
  check("order listed for staff", listed.json?.orders?.filter((o) => o.square_payment_id === `SIM-${run}`).length === 1);
});

if (waitForOffline) {
  await step("offline", async () => {
    kiosk.ws.close();
    const started = Date.now();
    const alert = await staff.next("patch", alertPatch((a) => a.kind === "offline" && a.kioskId === kioskDevice && !a.resolvedAt), 60_000);
    check("offline alert raised for this kiosk after contact stopped", true, `${alert.change.alert.title}, ${Math.round((Date.now() - started) / 1000)} s after disconnect`);
    const id = randomUUID();
    staff.send({ type: "action", action: { id, type: "ack", alertId: alert.change.alert.id, by: "Smoke test" } });
    await staff.next("result", (m) => m.id === id);
  });
}

kiosk.ws.close();
await step("cleanup", async () => {
  const removed = await act({ type: "removeKiosk", kiosk: kioskDevice });
  check("smoke kiosk removed from the registry", removed.json?.results?.[0]?.status === "ok" && !(await kioskEntry()));
});
staff.ws.close();
console.log(failures === 0 ? "\nAll checks passed" : `\n${failures} check(s) failed`);
process.exit(failures === 0 ? 0 : 1);
