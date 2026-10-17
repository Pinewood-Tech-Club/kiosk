import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker from "../src";
import { ZXING_WASM_PATH } from "../src/giftcard-scanner";

const BASE = "https://booth.test";
const GAN = "7783320000001234";
const QR_TOKEN = "a12dc64b43d84644acfd4b9c313f62dd";
const configured = { ...env, SQUARE_ACCESS_TOKEN: "EAAA-static" } as Env;

let ipCounter = 0;
let squareStatus = 200;
let squareBody: unknown = {};

function mockSquare(status: number, body: unknown) {
  squareStatus = status;
  squareBody = body;
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL) => {
    const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url);
    if (url.pathname === "/v2/locations") return Response.json({ locations: [{ id: "LOC1", name: "Booth", status: "ACTIVE", capabilities: ["CREDIT_CARD_PROCESSING"] }] });
    return Response.json(squareBody, { status: squareStatus });
  });
}

const card = (overrides: Record<string, unknown> = {}) => ({
  gift_card: { id: "gftc:abc", state: "ACTIVE", balance_money: { amount: 1250, currency: "USD" }, gan: GAN, customer_ids: ["CUST1"], ...overrides },
});

async function send(path: string, init: RequestInit = {}, e: Env = configured) {
  const request = new Request(`${BASE}${path}`, init);
  const ctx = createExecutionContext();
  const response = await worker.fetch(request as Request<unknown, IncomingRequestCfProperties>, e, ctx);
  await waitOnExecutionContext(ctx);
  return response;
}

async function check(body: unknown, headers: Record<string, string> = {}, e: Env = configured) {
  const response = await send("/giftcard/balance", { method: "POST", headers: { "Content-Type": "application/json", "CF-Connecting-IP": `203.0.113.${ipCounter}`, ...headers }, body: JSON.stringify(body) }, e);
  return { status: response.status, body: (await response.json()) as any };
}

beforeEach(async () => {
  ipCounter++;
  await env.DB.batch(["giftcard_lookup_failures", "square_tokens", "square_cache"].map((t) => env.DB.prepare(`DELETE FROM ${t}`)));
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe("GET /giftcard", () => {
  it("serves the public page without auth, allowing the camera", async () => {
    const response = await send("/giftcard");
    expect(response.status).toBe(200);
    expect(response.headers.get("Content-Type")).toContain("text/html");
    expect(response.headers.get("Permissions-Policy")).toBe("camera=(self)");
    expect(await response.text()).toContain("Hold your gift card up to the camera");
  });

  it("turns on the simulated camera only for ?debug=1", async () => {
    expect(await (await send("/giftcard")).text()).toContain("const DEBUG = false;");
    expect(await (await send("/giftcard?debug=1")).text()).toContain("const DEBUG = true;");
  });

  it("shows the club picker as a scrollable list with no search box", async () => {
    const page = await (await send("/giftcard")).text();
    expect(page).toContain("Who should get your donation?");
    expect(page).not.toContain("All clubs");
    expect(page).not.toMatch(/<input[^>]*id="org"/);
  });

  it("counts every mouse and keyboard input as idle activity and never mentions touch", async () => {
    const page = await (await send("/giftcard")).text();
    for (const type of ["pointermove", "mousemove", "pointerdown", "pointerup", "mousedown", "mouseup", "click", "wheel", "scroll", "keydown"]) {
      expect(page).toContain(`"${type}"`);
    }
    expect(page).toContain("Move the mouse or press any key to keep going");
    const text = page.replace(/<style[\s\S]*?<\/style>|<script[\s\S]*?<\/script>/g, "");
    expect(text).not.toMatch(/\b(tap|tapping|touch)\b/i);
  });

  it("serves the scanner worker, its decoder wasm and confetti", async () => {
    for (const path of ["/giftcard/scan-worker.js", "/giftcard/confetti.js"]) {
      const response = await send(path);
      expect(response.status).toBe(200);
      expect(response.headers.get("Content-Type")).toContain("javascript");
    }
    expect(await (await send("/giftcard/scan-worker.js")).text()).toContain(ZXING_WASM_PATH);
    const wasm = await send(ZXING_WASM_PATH);
    expect(wasm.status).toBe(200);
    expect(wasm.headers.get("Content-Type")).toBe("application/wasm");
    expect(WebAssembly.validate(new Uint8Array(await wasm.arrayBuffer()))).toBe(true);
  });

  it("passes uppercase barcodes and canonical balance QR codes to the lookup", async () => {
    const script = (await (await send("/giftcard")).text()).match(/function extractGan\(raw\) \{[\s\S]*?\n\}/)![0];
    const extractGan = new Function(`${script}\nreturn extractGan;`)() as (raw: string) => string | null;
    const canonical = `https://app.squareup.com/gift/balance/${QR_TOKEN}`;
    expect(extractGan("SQGC://7782737320193309")).toBe("7782737320193309");
    expect(extractGan(`sqgc://${GAN}`)).toBe(GAN);
    expect(extractGan(canonical)).toBe(canonical);
    expect(extractGan(`HTTP://APP.SQUAREUP.COM/GIFT/BALANCE/${QR_TOKEN.toUpperCase()}/?x=1`)).toBe(canonical);
    expect(extractGan(`https://squareup.com/gift/balance/${QR_TOKEN}#a`)).toBe(canonical);
    expect(extractGan(`https://app.squareup.com/gift/balance/${QR_TOKEN}0`)).toBeNull();
    expect(extractGan(`https://evil.example/gift/balance/${QR_TOKEN}`)).toBeNull();
    expect(extractGan(`https://app.squareup.com.evil.example/gift/balance/${QR_TOKEN}`)).toBeNull();
  });

  it("gives debug mode the same org list as the live page", async () => {
    const orgsOf = async (path: string) => (await (await send(path)).text()).match(/const ORGS_INIT = (.*);/)![1];
    expect(await orgsOf("/giftcard?debug=1")).toBe(await orgsOf("/giftcard"));
  });
});

describe("POST /giftcard/balance", () => {
  it("returns only the balance and state", async () => {
    mockSquare(200, card());
    const result = await check({ gan: GAN });
    expect(result.status).toBe(200);
    expect(result.body).toEqual({ balanceCents: 1250, state: "ACTIVE" });
  });

  it("needs no credentials of the caller", async () => {
    mockSquare(200, card());
    expect((await check({ gan: GAN }, { Authorization: "" })).status).toBe(200);
  });

  it("rejects malformed numbers without calling Square", async () => {
    mockSquare(200, card());
    const result = await check({ gan: "12ab" });
    expect(result.status).toBe(400);
    expect(vi.mocked(fetch).mock.calls.some(([input]) => String(input).includes("from-gan"))).toBe(false);
  });

  it("looks up the card behind a Square balance QR code by its gift card id", async () => {
    mockSquare(200, card({ id: `gftc:${QR_TOKEN}` }));
    const result = await check({ gan: `https://app.squareup.com/gift/balance/${QR_TOKEN}` });
    expect(result.status).toBe(200);
    expect(result.body).toEqual({ balanceCents: 1250, state: "ACTIVE" });
    const calls = vi.mocked(fetch).mock.calls.filter(([input]) => String(input).includes("/v2/gift-cards"));
    expect(calls).toHaveLength(1);
    expect(new URL(String(calls[0][0])).pathname).toBe(`/v2/gift-cards/gftc:${QR_TOKEN}`);
    expect(calls[0][1]?.method).toBe("GET");
  });

  it("answers 404 for a QR code whose card Square doesn't know", async () => {
    mockSquare(404, { errors: [{ code: "NOT_FOUND", category: "INVALID_REQUEST_ERROR" }] });
    const result = await check({ gan: `https://app.squareup.com/gift/balance/${QR_TOKEN}` });
    expect(result.status).toBe(404);
    expect(result.body.error.code).toBe("giftcard_not_found");
  });

  it("rejects other QR links without calling Square", async () => {
    mockSquare(200, card());
    for (const gan of [`https://evil.example/gift/balance/${QR_TOKEN}`, `https://app.squareup.com/gift/balance/${QR_TOKEN.slice(2)}`, `https://example.com/${GAN}`]) {
      const result = await check({ gan });
      expect(result.status).toBe(400);
      expect(result.body.error.code).toBe("invalid_gan");
    }
    expect(vi.mocked(fetch).mock.calls.some(([input]) => String(input).includes("/v2/gift-cards"))).toBe(false);
  });

  it("answers 404 for an unknown card", async () => {
    mockSquare(404, { errors: [{ code: "NOT_FOUND", category: "INVALID_REQUEST_ERROR" }] });
    const result = await check({ gan: GAN });
    expect(result.status).toBe(404);
    expect(result.body.error.code).toBe("giftcard_not_found");
  });

  it("never rate-limits the supervised kiosk, even after many misses", async () => {
    mockSquare(404, { errors: [{ code: "NOT_FOUND", category: "INVALID_REQUEST_ERROR" }] });
    for (let i = 0; i < 12; i++) expect((await check({ gan: GAN })).status).toBe(404);
    mockSquare(200, card());
    expect((await check({ gan: GAN })).status).toBe(200);
    const { n } = (await env.DB.prepare("SELECT COUNT(*) AS n FROM giftcard_lookup_failures").first<{ n: number }>())!;
    expect(n).toBe(0);
  });

  it("refuses cross-origin posts", async () => {
    mockSquare(200, card());
    expect((await check({ gan: GAN }, { Origin: "https://evil.example" })).status).toBe(403);
    expect((await check({ gan: GAN }, { Origin: BASE })).status).toBe(200);
  });

  it("answers 503 when Square is not connected", async () => {
    const result = await check({ gan: GAN }, {}, { ...env, SQUARE_ACCESS_TOKEN: "", SQUARE_APPLICATION_ID: "", SQUARE_APPLICATION_SECRET: "" } as Env);
    expect(result.status).toBe(503);
  });
});
