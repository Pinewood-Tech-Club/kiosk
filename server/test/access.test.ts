import { env, exports } from "cloudflare:workers";
import { beforeAll, describe, expect, it, vi } from "vitest";
import { accessConfig, accessTesting, verifyAccessJwt } from "../src/access";
import { authenticateAdmin } from "../src/admin";
import { createStaffSession } from "../src/session";
import { newKey, OWNER, SECOND, serveKeys, signToken, type TestKey } from "./access-helpers";

const BASE = "https://booth.test";
const STATE = `${BASE}/v1/admin/state`;

let key: TestKey;
let other: TestKey;

beforeAll(async () => {
  key = await newKey("key-one");
  other = await newKey("key-two");
});

const withHeader = (jwt: string) => ({ "Cf-Access-Jwt-Assertion": jwt });
const get = (url: string, headers: Record<string, string> = {}) => exports.default.fetch(url, { headers, redirect: "manual" });
const status = async (headers: Record<string, string>) => (await get(STATE, headers)).status;
const now = () => Math.floor(Date.now() / 1000);

describe("Cloudflare Access verification", () => {
  it("reads the test config from the bindings", () => {
    expect(accessConfig(env)).toEqual({
      teamDomain: "https://test-team.cloudflareaccess.com",
      aud: "test-aud-tag",
      emails: [OWNER, SECOND],
    });
  });

  it("accepts a valid token from the header or the CF_Authorization cookie", async () => {
    serveKeys(key);
    const jwt = await signToken(key);
    const header = await get(STATE, withHeader(jwt));
    expect(header.status).toBe(200);
    expect((await header.json<any>()).admin).toEqual({ email: OWNER });
    expect(await status({ Cookie: `theme=dark; CF_Authorization=${jwt}` })).toBe(200);
  });

  it("matches the email case-insensitively, accepts a string aud and a second admin", async () => {
    serveKeys(key);
    expect(await status(withHeader(await signToken(key, { email: "OWNER@Test.Example" })))).toBe(200);
    expect(await status(withHeader(await signToken(key, { email: SECOND, claims: { aud: "test-aud-tag" } })))).toBe(200);
    expect(await status(withHeader(await signToken(key, { claims: { aud: ["other", "test-aud-tag"] } })))).toBe(200);
  });

  it("refuses the wrong audience, issuer, lifetime, signature and algorithm with a structured 403", async () => {
    serveKeys(key);
    const refuse = async (jwt: string) => {
      const response = await get(STATE, withHeader(jwt));
      expect(response.status).toBe(403);
      const body = await response.json<any>();
      expect(body.error).toMatchObject({ code: "forbidden", retryable: false });
      expect(body.error.message).not.toMatch(/aud|iss|signature|kid|jwt/i);
    };
    await refuse(await signToken(key, { claims: { aud: ["someone-else"] } }));
    await refuse(await signToken(key, { claims: { aud: [] } }));
    await refuse(await signToken(key, { claims: { iss: "https://evil.cloudflareaccess.com" } }));
    await refuse(await signToken(key, { claims: { exp: now() - 120 } }));
    await refuse(await signToken(key, { claims: { exp: undefined } }));
    await refuse(await signToken(key, { claims: { nbf: now() + 300 } }));
    await refuse(await signToken(key, { header: { alg: "none" } }));
    await refuse(await signToken(key, { header: { alg: "HS256" } }));
    await refuse(await signToken(key, { email: null }));

    const good = await signToken(key);
    const [head, , signature] = good.split(".");
    const forgedBody = btoa(JSON.stringify({ aud: ["test-aud-tag"], iss: "https://test-team.cloudflareaccess.com", exp: now() + 3600, email: OWNER })).replace(/=+$/, "");
    await refuse(`${head}.${forgedBody}.${signature}`);
    const impostor = await newKey("key-one");
    await refuse(await signToken(impostor));
    await refuse("not.a.jwt");
    await refuse("garbage");
  });

  it("allows a little clock skew either way", async () => {
    serveKeys(key);
    expect(await status(withHeader(await signToken(key, { claims: { exp: now() - 30 } })))).toBe(200);
    expect(await status(withHeader(await signToken(key, { claims: { nbf: now() + 30 } })))).toBe(200);
  });

  it("refuses a valid token for an email that isn't on the allowlist", async () => {
    serveKeys(key);
    expect(await status(withHeader(await signToken(key, { email: "stranger@pinewood.edu" })))).toBe(403);
  });

  it("refuses a request with no token", async () => {
    serveKeys(key);
    const response = await get(STATE);
    expect(response.status).toBe(403);
    expect((await response.json<any>()).error.code).toBe("forbidden");
    expect(await status({ Cookie: "CF_Authorization=" })).toBe(403);
    expect(await status({ Cookie: "other=1" })).toBe(403);
  });

  it("fetches the certs once and caches them", async () => {
    const calls = serveKeys(key);
    const jwt = await signToken(key);
    for (let i = 0; i < 4; i++) expect(await status(withHeader(jwt))).toBe(200);
    expect(calls.count).toBe(1);
  });

  it("refetches the certs when it sees an unknown kid, so a rotated key works", async () => {
    const calls = { count: 0 };
    let published = [key];
    accessTesting.useFetcher(async () => (calls.count++, published.map((k) => k.jwk)), { refetchIntervalMs: 0 });
    expect(await status(withHeader(await signToken(key)))).toBe(200);
    const rotated = await signToken(other);
    expect(await status(withHeader(rotated))).toBe(403);
    published = [key, other];
    expect(await status(withHeader(rotated))).toBe(200);
    expect(calls.count).toBe(3);
  });

  it("rate limits refetches, so unknown kids can't make it hammer the certs endpoint", async () => {
    const calls = { count: 0 };
    accessTesting.useFetcher(async () => (calls.count++, [key.jwk]));
    expect(await status(withHeader(await signToken(key)))).toBe(200);
    for (let i = 0; i < 5; i++) expect(await status(withHeader(await signToken(other)))).toBe(403);
    expect(calls.count).toBe(1);
  });

  it("keeps using cached keys when a refresh fails, and denies when it never had any", async () => {
    accessTesting.useFetcher(async () => {
      throw new Error("certs are down");
    });
    expect(await status(withHeader(await signToken(key)))).toBe(403);

    let down = false;
    accessTesting.useFetcher(async () => {
      if (down) throw new Error("certs are down");
      return [key.jwk];
    }, { ttlMs: 0, refetchIntervalMs: 0 });
    const jwt = await signToken(key);
    expect(await status(withHeader(jwt))).toBe(200);
    down = true;
    expect(await status(withHeader(jwt))).toBe(200);
  });

  it("verifies claims directly", async () => {
    serveKeys(key);
    const config = accessConfig(env)!;
    expect(await verifyAccessJwt(await signToken(key), config)).toEqual({ email: OWNER });
    expect(await verifyAccessJwt(await signToken(key), config, Date.now() + 2 * 3600_000)).toBeNull();
    expect(await verifyAccessJwt(await signToken(key), config, Date.now() - 3600_000)).toBeNull();
  });
});

describe("admin routes only accept Access", () => {
  it("refuses a staff session, STAFF_TOKEN, the kiosk token, the PIN and the old admin token endpoint", async () => {
    serveKeys(key);
    const staffSession = (await createStaffSession(env)).token;
    for (const token of [env.STAFF_TOKEN, env.BOOTH_TOKEN, staffSession, "ad1.bogus.token"]) {
      const response = await get(STATE, { Authorization: `Bearer ${token}` });
      expect(response.status).toBe(403);
      expect((await response.json<any>()).error.code).toBe("forbidden");
    }
    const login = await exports.default.fetch(`${BASE}/dashboard/login`, {
      method: "POST",
      redirect: "manual",
      headers: { Origin: BASE, "Content-Type": "application/x-www-form-urlencoded" },
      body: `pin=${env.STAFF_PIN}`,
    });
    const cookie = login.headers.get("Set-Cookie")!.split(";")[0];
    expect(await status({ Cookie: cookie })).toBe(403);
    expect((await get(`${BASE}/staff/admin`, { Cookie: cookie })).status).toBe(403);

    for (const path of ["/v1/admin/logs", "/v1/admin/square", "/v1/admin/orders", "/v1/admin/cleanup", "/v1/admin/reset", "/v1/admin/backup"]) {
      expect((await get(`${BASE}${path}`, { Authorization: `Bearer ${env.STAFF_TOKEN}`, Cookie: cookie })).status, path).toBe(403);
    }
    for (const path of ["/v1/admin/selftest", "/v1/admin/reset", "/v1/admin/alerts/ack-all", "/v1/admin/cleanup/test-orders", "/v1/admin/square/refresh"]) {
      const post = await exports.default.fetch(`${BASE}${path}`, { method: "POST", headers: { Authorization: `Bearer ${env.STAFF_TOKEN}`, "Content-Type": "application/json" }, body: JSON.stringify({ confirm: "RESET" }) });
      expect(post.status, path).toBe(403);
    }

    const session = await exports.default.fetch(`${BASE}/v1/admin/session`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ pin: env.STAFF_PIN }) });
    expect(session.status).toBe(404);
  });

  it("still lets the staff token and a staff session use the staff routes", async () => {
    serveKeys(key);
    const staffSession = (await createStaffSession(env)).token;
    for (const token of [env.STAFF_TOKEN, staffSession]) {
      const response = await exports.default.fetch(`${BASE}/v1/state`, { headers: { Authorization: `Bearer ${token}`, "X-Booth-Device": "staff-check" } });
      expect(response.status).toBe(200);
    }
  });

  it("rate limits per admin email", async () => {
    serveKeys(key);
    const limit = vi.spyOn(env.CLIENT_LIMITER, "limit");
    const request = (jwt: string) => new Request(STATE, { headers: withHeader(jwt) });
    const first = await authenticateAdmin(request(await signToken(key, { email: "OWNER@test.example" })), env);
    expect(first.email).toBe(OWNER);
    expect(limit).toHaveBeenCalledWith({ key: `admin:${OWNER}` });
    await authenticateAdmin(request(await signToken(key, { email: SECOND })), env);
    expect(limit).toHaveBeenCalledWith({ key: `admin:${SECOND}` });

    limit.mockResolvedValueOnce({ success: false });
    await expect(authenticateAdmin(request(await signToken(key)), env)).rejects.toMatchObject({ status: 429, code: "rate_limited" });
    limit.mockRestore();
  });
});

describe("/staff/admin", () => {
  it("serves the admin app to a signed-in admin, with their email, a sign-out link and no PIN screen", async () => {
    serveKeys(key);
    const response = await get(`${BASE}/staff/admin`, withHeader(await signToken(key)));
    expect(response.status).toBe(200);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect(response.headers.get("Content-Security-Policy")).toContain("script-src 'nonce-");
    const text = await response.text();
    expect(text).toContain(OWNER);
    expect(text).toContain('href="/cdn-cgi/access/logout"');
    expect(text).not.toContain('type="password"');
    expect(text).not.toContain("lockForm");
    expect(text).not.toMatch(/ad1\.[A-Za-z0-9_-]{8,}/);
  });

  it("serves a small 403 page instead of the app without a valid admin token", async () => {
    serveKeys(key);
    const kiosk = `adminpage-${crypto.randomUUID().slice(0, 8)}`;
    await exports.default.fetch(`${BASE}/v1/orders`, {
      method: "POST",
      headers: { Authorization: `Bearer ${env.BOOTH_TOKEN}`, "X-Booth-Device": kiosk, "Content-Type": "application/json" },
      body: JSON.stringify({ orders: [{ id: `o-${kiosk}`, customerName: "Zanzibar Quill", totalCents: 400, paidAt: Date.now(), items: [{ vessel: "cup", flavors: ["vanilla"] }] }] }),
    });
    for (const headers of [{}, withHeader(await signToken(key, { email: "stranger@pinewood.edu" })), withHeader(await signToken(key, { claims: { aud: ["x"] } }))]) {
      const response = await get(`${BASE}/staff/admin`, headers);
      expect(response.status).toBe(403);
      expect(response.headers.get("Content-Type")).toContain("text/html");
      const text = await response.text();
      expect(text).toContain("No access");
      expect(text).not.toContain("/v1/admin/");
      expect(text).not.toContain("Zanzibar Quill");
      expect(text).not.toContain(kiosk);
    }
  });

  it("is listed on the staff picker", async () => {
    const login = await exports.default.fetch(`${BASE}/dashboard/login`, {
      method: "POST",
      redirect: "manual",
      headers: { Origin: BASE, "Content-Type": "application/x-www-form-urlencoded" },
      body: `pin=${env.STAFF_PIN}`,
    });
    const cookie = login.headers.get("Set-Cookie")!.split(";")[0];
    const picker = await (await get(`${BASE}/staff`, { Cookie: cookie })).text();
    expect(picker).toContain('href="/staff/admin"');
  });
});
