import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import worker from "../src";
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

async function signIn(): Promise<string> {
  const response = await call("/dashboard/login", {
    method: "POST",
    headers: { Origin: BASE, "Content-Type": "application/x-www-form-urlencoded" },
    body: "pin=2468",
  });
  return response.headers.get("Set-Cookie")!.split(";")[0];
}

describe("dashboard page", () => {
  it("shows only the sign-in form without a session", async () => {
    const response = await call("/dashboard");
    expect(response.status).toBe(200);
    expect(response.text).toContain('name="pin"');
    expect(response.text).not.toContain("WebSocket");
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect(response.headers.get("Referrer-Policy")).toBe("same-origin");
  });

  it("serves a self-contained live page to a signed-in session", async () => {
    const cookie = await signIn();
    const response = await call("/dashboard", { headers: { Cookie: cookie } });
    expect(response.status).toBe(200);
    expect(response.text).toContain("new WebSocket");
    expect(response.text).toContain('id="orders"');
    expect(response.text).toContain('id="soldout"');
    expect(response.text).not.toMatch(/(src|href)="https?:/);
    const csp = response.headers.get("Content-Security-Policy")!;
    const nonce = /script-src 'nonce-([^']+)'/.exec(csp)![1];
    expect(response.text).toContain(`<script nonce="${nonce}">`);
    expect(csp).toContain("connect-src 'self'");
    const second = await call("/dashboard", { headers: { Cookie: cookie } });
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
  });
});
