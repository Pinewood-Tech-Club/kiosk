import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import worker from "../src";
import { createStaffSession } from "../src/session";
import { STAFF_ROLES } from "../src/staff-roles";
import { summarize } from "../src/stats";

const KIOSK = "test-kiosk-token";
const STAFF = "test-staff-token";
const BASE = "https://booth.test";
const DAY = 24 * 60 * 60_000;

async function call(path: string, init: RequestInit = {}) {
  const ctx = createExecutionContext();
  const response = await worker.fetch(new Request(`${BASE}${path}`, { redirect: "manual", ...init }) as Request<unknown, IncomingRequestCfProperties>, env, ctx);
  await waitOnExecutionContext(ctx);
  const text = response.status === 101 ? "" : await response.text();
  return { status: response.status, text, headers: response.headers, webSocket: (response as any).webSocket as WebSocket | null };
}

let session: string | null = null;

async function signIn(): Promise<string> {
  if (session) return session;
  const response = await call("/dashboard/login", {
    method: "POST",
    headers: { Origin: BASE, "Content-Type": "application/x-www-form-urlencoded" },
    body: "pin=2468",
  });
  session = response.headers.get("Set-Cookie")!.split(";")[0];
  return session;
}

describe("dashboard page", () => {
  it("sends /dashboard to the page picker and asks for the PIN without a session", async () => {
    const legacy = await call("/dashboard");
    expect(legacy.status).toBe(303);
    expect(legacy.headers.get("Location")).toBe("/staff");
    const picker = await call("/staff");
    expect(picker.text).toContain('name="pin"');
    expect(picker.text).not.toContain("/staff/scooper");
    const response = await call("/staff/scooper");
    expect(response.status).toBe(200);
    expect(response.text).toContain('name="pin"');
    expect(response.text).toContain('inputmode="numeric"');
    expect(response.text).toContain('name="next" value="/staff/scooper"');
    expect(response.text).not.toContain("WebSocket");
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect(response.headers.get("Referrer-Policy")).toBe("same-origin");
  });

  it("lists every role page on the picker and refuses unknown roles", async () => {
    const cookie = await signIn();
    const picker = await call("/staff", { headers: { Cookie: cookie } });
    expect(picker.status).toBe(200);
    for (const id of Object.keys(STAFF_ROLES)) expect(picker.text).toContain(`href="/staff/${id}"`);
    const unknown = await call("/staff/nope", { headers: { Cookie: cookie } });
    expect(unknown.status).toBe(404);
    expect(unknown.text).toContain("There is no");
  });

  it("returns to the page the PIN was asked on, and only to staff pages", async () => {
    const login = (next: string) => call("/dashboard/login", {
      method: "POST",
      headers: { Origin: BASE, "Content-Type": "application/x-www-form-urlencoded" },
      body: `pin=2468&next=${encodeURIComponent(next)}`,
    });
    expect((await login("/staff/organizer")).headers.get("Location")).toBe("/staff/organizer");
    expect((await login("https://evil.test/")).headers.get("Location")).toBe("/staff");
    expect((await login("//evil.test/staff")).headers.get("Location")).toBe("/staff");
  });

  it("shows each role only its own sections", async () => {
    const cookie = await signIn();
    const page = async (id: string) => (await call(`/staff/${id}`, { headers: { Cookie: cookie } })).text;
    const scooper = await page("scooper");
    for (const id of ["make", "soldout", "kiosks", "kioskSheet", "exitStaff", "alerts", "confirm"]) expect(scooper).toContain(`id="${id}"`);
    for (const id of ["tOrders", "feed", "handoff", "openCard", "health"]) expect(scooper).not.toContain(`id="${id}"`);
    expect(scooper).toMatch(/class="navbtn app-only" id="exitStaff"/);
    expect(scooper).toContain('data-alerts="quiet"');
    const toppings = await page("toppings");
    for (const id of ["handoff", "alerts", "kiosks", "kioskSheet", "exitStaff", "soldout", "confirm"]) expect(toppings).toContain(`id="${id}"`);
    expect(toppings).toContain('data-alerts="front"');
    expect(toppings).not.toContain('id="make"');
    const organizer = await page("organizer");
    for (const id of ["tOrders", "feed", "alerts", "kiosks"]) expect(organizer).toContain(`id="${id}"`);
    expect(organizer).toContain('data-kind="display"');
    for (const id of ["confirm", "kioskSheet", "exitStaff"]) expect(organizer).not.toContain(`id="${id}"`);
    expect(organizer).not.toContain("Sign out");
    expect(scooper).toContain('data-supply="flavor" data-mode="edit"');
    expect(scooper).toContain('data-supply="vessel" data-mode="edit"');
    expect(scooper).toContain('data-supply="topping" data-mode="compact"');
    expect(scooper).toContain("Set on the Toppings iPad");
    expect(toppings).toContain('data-supply="topping" data-mode="edit"');
    expect(toppings).toContain('data-supply="flavor,vessel" data-mode="compact"');
    expect(toppings).toContain("<h2>Flavors, cups and cones</h2>");
    expect(toppings).toContain("Set on the Scooper iPad.");
    expect(toppings).not.toContain('data-supply="flavor" data-mode="edit"');
    for (const kind of ["flavor", "vessel", "topping"]) expect(organizer).toContain(`data-supply="${kind}" data-mode="list"`);
    expect(organizer).not.toContain('data-mode="edit"');
    const board = await page("board");
    expect(board).toContain('id="boardMaking"');
    expect(board).not.toContain('id="alerts"');
  });

  it("serves a self-contained live page to a signed-in session", async () => {
    const cookie = await signIn();
    const response = await call("/staff/scooper", { headers: { Cookie: cookie } });
    expect(response.status).toBe(200);
    expect(response.text).toContain("new WebSocket");
    expect(response.text).toContain('id="make"');
    expect(response.text).toContain('id="soldout"');
    expect(response.text).toContain("setOrderStatus");
    expect(response.text).toContain("booth.outbox.v1");
    expect(response.text).toContain("viewport-fit=cover");
    expect(response.text).not.toMatch(/\u2014/);
    expect(response.text).not.toMatch(/(src|href)="https?:/);
    const csp = response.headers.get("Content-Security-Policy")!;
    const nonce = /script-src 'nonce-([^']+)'/.exec(csp)![1];
    expect(response.text).toContain(`<script nonce="${nonce}">`);
    expect(csp).toContain("connect-src 'self' wss://booth.test");
    expect(csp).toContain("media-src blob:");
    const second = await call("/staff/scooper", { headers: { Cookie: cookie } });
    expect(second.headers.get("Content-Security-Policy")).not.toBe(csp);
  });

  it("rejects a wrong PIN and a login from another origin", async () => {
    const wrong = await call("/dashboard/login", {
      method: "POST",
      headers: { Origin: BASE, "Content-Type": "application/x-www-form-urlencoded" },
      body: "pin=0000",
    });
    expect(wrong.status).toBe(401);
    expect(wrong.headers.get("Set-Cookie")).toBeNull();
    const foreign = await call("/dashboard/login", {
      method: "POST",
      headers: { Origin: "https://evil.test", "Content-Type": "application/x-www-form-urlencoded" },
      body: "pin=2468",
    });
    expect(foreign.status).toBe(403);
  });

  it("lets the session cookie read state, open the live socket and send actions only from the same origin", async () => {
    const cookie = await signIn();
    expect((await call("/v1/state", { headers: { Cookie: cookie } })).status).toBe(200);
    expect((await call("/v1/state")).status).toBe(401);
    const action = JSON.stringify({ actions: [{ id: `dash-${crypto.randomUUID()}`, type: "setSoldOut", flavor: "vanilla", soldOut: false, by: "Dashboard" }] });
    const post = (headers: Record<string, string>) => call("/v1/actions", { method: "POST", headers: { Cookie: cookie, "Content-Type": "application/json", ...headers }, body: action });
    expect((await post({})).status).toBe(403);
    expect((await post({ Origin: "https://evil.test" })).status).toBe(403);
    expect((await post({ Origin: BASE })).status).toBe(200);
    const ws = await call("/v1/ws", { headers: { Cookie: cookie, Upgrade: "websocket" } });
    expect(ws.status).toBe(101);
    ws.webSocket?.accept();
    ws.webSocket?.close();
  });
});

describe("session renewal", () => {
  it("renews a session cookie only when it is close to expiring", async () => {
    const renew = (cookieHeader: string, origin = BASE) => call("/dashboard/renew", { method: "POST", headers: { Cookie: cookieHeader, Origin: origin } });
    const fresh = await createStaffSession(env);
    const kept = await renew(`booth_staff=${fresh.token}`);
    expect(kept.status).toBe(204);
    expect(kept.headers.get("Set-Cookie")).toBeNull();
    const old = await createStaffSession(env, Date.now() - 30 * 60 * 60_000);
    const renewed = await renew(`booth_staff=${old.token}`);
    expect(renewed.status).toBe(204);
    expect(renewed.headers.get("Set-Cookie")).toMatch(/^booth_staff=st1\./);
    expect((await renew(`booth_staff=${old.token}`, "https://evil.test")).status).toBe(403);
    expect((await renew("booth_staff=nope")).status).toBe(401);
  });
});

describe("dashboard offline queue", () => {
  it("dedupes a resent action from the same browser device and applies queued changes in order", async () => {
    const cookie = await signIn();
    const device = `web-${crypto.randomUUID().slice(0, 12)}`;
    const headers = { Cookie: cookie, Origin: BASE, "Content-Type": "application/json", "X-Booth-Device": device };
    const first = { id: crypto.randomUUID(), type: "setSoldOut", flavor: "vanilla", soldOut: true, by: "Dashboard" };
    const second = { id: crypto.randomUUID(), type: "setSoldOut", flavor: "vanilla", soldOut: false, by: "Dashboard" };
    const send = (actions: unknown[]) => call("/v1/actions", { method: "POST", headers, body: JSON.stringify({ actions }) }).then((r) => JSON.parse(r.text));
    const sent = await send([first, second]);
    expect(sent.results.map((r: { status: string }) => r.status)).toEqual(["ok", "ok"]);
    const resent = await send([first, second]);
    expect(resent.results.map((r: { status: string }) => r.status)).toEqual(["duplicate", "duplicate"]);
    const state = JSON.parse((await call("/v1/state", { headers: { Cookie: cookie } })).text);
    expect(state.flavors.find((f: { id: string }) => f.id === "vanilla")?.soldOut ?? false).toBe(false);
  });

  it("rejects a status change for an order that isn't in the feed without failing the batch", async () => {
    const cookie = await signIn();
    const headers = { Cookie: cookie, Origin: BASE, "Content-Type": "application/json", "X-Booth-Device": "web-status-check" };
    const actions = [
      { id: crypto.randomUUID(), type: "setOrderStatus", orderId: "no-such-order", status: "ready", by: "Dashboard" },
      { id: crypto.randomUUID(), type: "ack", alertId: "no-such-alert", by: "Dashboard" },
    ];
    const response = await call("/v1/actions", { method: "POST", headers, body: JSON.stringify({ actions }) });
    expect(response.status).toBe(200);
    const body = JSON.parse(response.text);
    expect(body.results[0]).toMatchObject({ status: "rejected", error: { code: "not_found" } });
    expect(body.results).toHaveLength(2);
  });
});

describe("stats endpoint", () => {
  it("requires the staff role", async () => {
    expect((await call("/v1/stats")).status).toBe(401);
    expect((await call("/v1/stats", { headers: { Authorization: `Bearer ${KIOSK}`, "X-Booth-Device": "k" } })).status).toBe(403);
    expect((await call("/v1/stats", { headers: { Authorization: `Bearer ${STAFF}`, "X-Booth-Device": "s" } })).status).toBe(200);
    const cookie = await signIn();
    expect((await call("/v1/stats", { headers: { Cookie: cookie } })).status).toBe(200);
  });

  it("counts the last 15 minutes and leaves out simulated orders", async () => {
    const base = Date.now() + 2000 * DAY;
    const at = (minutes: number) => new Date(base + minutes * 60_000).toISOString();
    const items = [{ vessel: "cup", flavors: ["vanilla"] }];
    const orders = [
      { id: `q-${crypto.randomUUID()}`, totalCents: 400, paidAt: at(-3), items },
      { id: `q-${crypto.randomUUID()}`, totalCents: 500, paidAt: at(-14), items },
      { id: `q-${crypto.randomUUID()}`, totalCents: 700, paidAt: at(-16), items },
      { id: `q-${crypto.randomUUID()}`, totalCents: 900, simulated: true, paidAt: at(-1), items },
    ];
    const posted = await call("/v1/orders", {
      method: "POST",
      headers: { Authorization: `Bearer ${KIOSK}`, "X-Booth-Device": "k", "Content-Type": "application/json" },
      body: JSON.stringify({ orders }),
    });
    expect(posted.status).toBe(200);
    const stats = await summarize(env, base - DAY, base + DAY, base);
    expect(stats).toMatchObject({ orders: 3, simulatedOrders: 1, totalCents: 1600, last15Min: { orders: 2, totalCents: 900 } });

    await env.DB.prepare("UPDATE orders SET status = 'canceled' WHERE id = ?").bind(orders[0].id).run();
    const after = await summarize(env, base - DAY, base + DAY, base);
    expect(after).toMatchObject({
      orders: 2, canceledOrders: 1, totalCents: 1200, scoops: 2, last15Min: { orders: 1, totalCents: 500 }, statuses: { paid: 2, canceled: 1 },
    });
    expect(after.byHour.reduce((sum, h) => sum + h.orders, 0)).toBe(2);
  });
});
