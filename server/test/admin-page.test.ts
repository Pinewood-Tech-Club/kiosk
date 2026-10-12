import { exports } from "cloudflare:workers";
import { beforeAll, describe, expect, it } from "vitest";
import { routes } from "../src/admin";
import { newKey, OWNER, serveKeys, signToken, type TestKey } from "./access-helpers";

const BASE = "https://booth.test";

let key: TestKey;

beforeAll(async () => {
  key = await newKey("page-test-key");
  serveKeys(key);
});

async function page() {
  const response = await exports.default.fetch(`${BASE}/staff/admin`, { headers: { "Cf-Access-Jwt-Assertion": await signToken(key) } });
  const text = await response.text();
  const script = /<script nonce="[^"]+">([\s\S]*)<\/script>/.exec(text)![1];
  return { response, text, script };
}

function routeParts(path: string | RegExp): string[] {
  if (typeof path === "string") return [path];
  return path.source
    .replace(/^\^|\$$/g, "")
    .split(/\([^)]*\)(?:\{[^}]*\})?/)
    .map((part) => part.replace(/\\\//g, "/"))
    .filter((part) => part.length > 1);
}

describe("admin page", () => {
  it("opens straight on the app with the signed-in email and a sign-out link, and no PIN or token handling", async () => {
    const { response, text } = await page();
    expect(response.status).toBe(200);
    expect(text).toMatch(/<div class="sv" id="app">/);
    expect(text).toContain(`<b id="who">${OWNER}</b>`);
    expect(text).toContain('<a class="srow" href="/cdn-cgi/access/logout">');
    expect(text).toMatch(/<main class="signin" id="expired" hidden>/);
    expect(text).not.toMatch(/\bPIN\b/);
    expect(text).not.toContain('id="lock"');
  });

  it("ships a script that parses, uses the Access cookie and every admin route, and handles an ended session", async () => {
    const { script } = await page();
    expect(() => new Function(script)).not.toThrow();
    expect(script).not.toContain("localStorage");
    expect(script).not.toContain("sessionStorage");
    expect(script).not.toContain("document.cookie");
    expect(script).not.toContain("Authorization");
    expect(script).not.toContain("X-Booth-Admin");
    expect(script).not.toContain("/v1/admin/session");
    expect(script).toContain('credentials:"same-origin"');
    expect(script).toContain('redirect:"manual"');
    expect(script).toContain("opaqueredirect");
    const adminRoutes = routes.filter((r) => String(r.path).includes("v1\\/admin") || String(r.path).startsWith("/v1/admin"));
    expect(adminRoutes.length).toBeGreaterThan(10);
    for (const route of adminRoutes) {
      for (const part of routeParts(route.path)) expect(script, `${route.method} ${String(route.path)}`).toContain(part);
    }
  });

  it("puts one Debug tools switch on each kiosk's header row, not in its controls", async () => {
    const { script } = await page();
    const header = /var head='<div class="kh">[^;]*;/.exec(script)![0];
    expect(header).toContain('data-debug="');
    expect(header).toContain("Debug tools");
    expect(script.match(/data-debug="/g)).toHaveLength(1);
    expect(script).not.toContain("Shows the debug bar on this kiosk");
  });

  it("only looks up element ids that exist in the page", async () => {
    const { text, script } = await page();
    const ids = new Set([...text.matchAll(/\sid="([^"]+)"/g)].map((m) => m[1]));
    const wanted = [...script.matchAll(/\$\("([A-Za-z0-9-]+)"\)/g)].map((m) => m[1]);
    expect(wanted.length).toBeGreaterThan(20);
    expect(wanted.filter((id) => !ids.has(id))).toEqual([]);
  });

  it("keeps both reset confirmations", async () => {
    const { text } = await page();
    expect(text).toContain('id="reset1"');
    expect(text).toContain("Type RESET to confirm");
    expect(text).toContain('id="r2Go"');
  });

  it("has no em dash and no emoji", async () => {
    const { text } = await page();
    expect(text).not.toContain(String.fromCodePoint(0x2014));
    expect(text).not.toMatch(/\p{Extended_Pictographic}/u);
  });
});
