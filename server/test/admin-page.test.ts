import { exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { routes } from "../src/admin";

const KIOSK = "test-kiosk-token";
const BASE = "https://booth.test";

async function page() {
  const response = await exports.default.fetch(`${BASE}/staff/admin`);
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
  it("is served without a session and opens on the PIN lock screen with no admin data", async () => {
    const device = `adminpage-${crypto.randomUUID().slice(0, 8)}`;
    await exports.default.fetch(`${BASE}/v1/orders`, {
      method: "POST",
      headers: { Authorization: `Bearer ${KIOSK}`, "X-Booth-Device": device, "Content-Type": "application/json" },
      body: JSON.stringify({
        orders: [{ id: `o-${device}`, customerName: "Zanzibar Quill", totalCents: 400, paidAt: Date.now(), items: [{ vessel: "cup", flavors: ["vanilla"] }] }],
      }),
    });
    const { response, text } = await page();
    expect(response.status).toBe(200);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect(text).toContain('id="lockForm"');
    expect(text).toContain('type="password"');
    expect(text).toContain("Enter the staff PIN to open the admin tools.");
    expect(text).toMatch(/<main class="signin" id="lock">/);
    expect(text).toMatch(/<div class="sv" id="app" hidden>/);
    expect(text).not.toContain("Zanzibar Quill");
    expect(text).not.toContain(device);
    expect(text).not.toMatch(/ad1\.[A-Za-z0-9_-]{8,}/);
  });

  it("ships a script that parses, keeps the token in memory only and uses every admin route", async () => {
    const { script } = await page();
    expect(() => new Function(script)).not.toThrow();
    expect(script).not.toContain("localStorage");
    expect(script).not.toContain("sessionStorage");
    expect(script).not.toContain("document.cookie");
    expect(script).toContain("X-Booth-Admin-Token");
    expect(script).toContain('"admin_required"');
    const adminRoutes = routes.filter((r) => String(r.path).includes("v1\\/admin") || String(r.path).startsWith("/v1/admin"));
    expect(adminRoutes.length).toBeGreaterThan(10);
    for (const route of adminRoutes) {
      for (const part of routeParts(route.path)) expect(script, `${route.method} ${String(route.path)}`).toContain(part);
    }
  });

  it("has no em dash and no emoji", async () => {
    const { text } = await page();
    expect(text).not.toContain(String.fromCodePoint(0x2014));
    expect(text).not.toMatch(/\p{Extended_Pictographic}/u);
  });
});
