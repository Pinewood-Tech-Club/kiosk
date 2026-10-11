import type { Role } from "./protocol";

export { Booth } from "./booth";

const MAX_LOG_BODY = 1024 * 1024;
const MAX_LOG_LINES = 500;
const MAX_MESSAGE = 8 * 1024;
const MAX_CONTEXT = 8 * 1024;
const D1_BATCH = 100;
const LEVELS = new Set(["debug", "info", "warn", "error"]);
const SUBPROTOCOL = "booth.v1";

type Level = "debug" | "info" | "warn" | "error";

function json(data: unknown, status = 200): Response {
  return Response.json(data, { status, headers: { "Cache-Control": "no-store" } });
}

function problem(status: number, message: string): Response {
  return json({ error: message }, status);
}

async function safeEqual(a: string, b: string): Promise<boolean> {
  const encoder = new TextEncoder();
  const [x, y] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(a)),
    crypto.subtle.digest("SHA-256", encoder.encode(b)),
  ]);
  return crypto.subtle.timingSafeEqual(x, y);
}

function decodeBase64Url(value: string): string | null {
  try {
    const base64 = value.replace(/-/g, "+").replace(/_/g, "/");
    const bytes = Uint8Array.from(atob(base64 + "=".repeat((4 - (base64.length % 4)) % 4)), (c) => c.charCodeAt(0));
    return new TextDecoder().decode(bytes);
  } catch {
    return null;
  }
}

/** Browsers can't set headers on a websocket, so the staff page sends its PIN as a `pin.<base64url>` subprotocol. */
function presentedPin(request: Request): string | null {
  const header = request.headers.get("Authorization");
  if (header?.startsWith("PIN ")) return header.slice(4).trim();
  const protocols = request.headers.get("Sec-WebSocket-Protocol");
  const encoded = protocols?.split(",").map((p) => p.trim()).find((p) => p.startsWith("pin."));
  return encoded ? decodeBase64Url(encoded.slice(4)) : null;
}

type AuthResult = { role: Role } | { error: Response };

async function authenticate(request: Request, env: Env, allowed: Role[]): Promise<AuthResult> {
  const header = request.headers.get("Authorization");
  if (allowed.includes("kiosk") && header?.startsWith("Bearer ")) {
    if (!env.BOOTH_TOKEN) return { error: problem(503, "BOOTH_TOKEN is not configured") };
    if (await safeEqual(header.slice(7).trim(), env.BOOTH_TOKEN)) return { role: "kiosk" };
    return { error: problem(401, "Bad kiosk token") };
  }
  const pin = allowed.includes("staff") ? presentedPin(request) : null;
  if (pin !== null) {
    const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
    const { success } = await env.PIN_LIMITER.limit({ key: `pin:${ip}` });
    if (!success) return { error: problem(429, "Too many PIN attempts. Wait a minute.") };
    if (!env.STAFF_PIN) return { error: problem(503, "STAFF_PIN is not configured") };
    if (await safeEqual(pin, env.STAFF_PIN)) return { role: "staff" };
    return { error: problem(401, "Wrong PIN") };
  }
  return { error: problem(401, "Missing credentials") };
}

function booth(env: Env) {
  return env.BOOTH.getByName("booth");
}

async function readJson(request: Request, maxBytes: number): Promise<unknown | Response> {
  const length = Number(request.headers.get("Content-Length") ?? "0");
  if (length > maxBytes) return problem(413, "Body too large");
  const text = await request.text();
  if (text.length > maxBytes) return problem(413, "Body too large");
  try {
    return JSON.parse(text);
  } catch {
    return problem(400, "Body is not JSON");
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function str(value: unknown, max: number): string | null {
  return typeof value === "string" ? value.slice(0, max) : null;
}

function int(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? Math.round(value) : null;
}

function timestamp(value: unknown, fallback: number): number {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string") {
    const parsed = Date.parse(value);
    if (!Number.isNaN(parsed)) return parsed;
  }
  return fallback;
}

async function ingestLogs(request: Request, env: Env): Promise<Response> {
  const body = await readJson(request, MAX_LOG_BODY);
  if (body instanceof Response) return body;
  if (!isRecord(body) || !Array.isArray(body.lines)) return problem(400, "Expected { lines: [...] }");
  if (body.lines.length > MAX_LOG_LINES) return problem(413, `At most ${MAX_LOG_LINES} lines per request`);

  const now = Date.now();
  const device = str(body.device, 64) ?? "unknown";
  const appVersion = str(body.appVersion, 40);
  const statement = env.DB.prepare(
    "INSERT OR IGNORE INTO logs (id, device, app_version, ts, level, message, context, received_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
  );
  const rows: D1PreparedStatement[] = [];
  let rejected = 0;
  for (const line of body.lines) {
    const id = isRecord(line) ? str(line.id, 128) : null;
    const message = isRecord(line) ? str(line.message, MAX_MESSAGE) : null;
    if (!isRecord(line) || !id || message === null) {
      rejected++;
      continue;
    }
    const level = (LEVELS.has(line.level as string) ? line.level : "info") as Level;
    const ts = timestamp(line.ts, now);
    const context = isRecord(line.context) ? JSON.stringify(line.context).slice(0, MAX_CONTEXT) : null;
    rows.push(statement.bind(id, device, appVersion, ts, level, message, context, now));
    const entry = { source: "kiosk", device, appVersion, ts: new Date(ts).toISOString(), level, message, context: line.context };
    if (level === "error") console.error(entry);
    else if (level === "warn") console.warn(entry);
    else console.log(entry);
  }

  let stored = 0;
  for (let i = 0; i < rows.length; i += D1_BATCH) {
    const results = await env.DB.batch(rows.slice(i, i + D1_BATCH));
    stored += results.reduce((sum, r) => sum + (r.meta.changes ?? 0), 0);
  }
  return json({ accepted: rows.length, stored, duplicates: rows.length - stored, rejected });
}

async function ingestOrder(request: Request, env: Env): Promise<Response> {
  const body = await readJson(request, 64 * 1024);
  if (body instanceof Response) return body;
  if (!isRecord(body)) return problem(400, "Expected an order object");
  const id = str(body.id, 64);
  const totalCents = int(body.totalCents);
  if (!id || totalCents === null || !Array.isArray(body.items)) {
    return problem(400, "Order needs id, totalCents and items");
  }
  const now = Date.now();
  const paidAt = timestamp(body.paidAt, now);
  const result = await env.DB.prepare(
    `INSERT OR IGNORE INTO orders (id, order_number, square_order_id, square_payment_id, customer_name, total_cents,
       subtotal_cents, tax_cents, card, simulated, items, lines, paid_at, device, app_version, received_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  )
    .bind(
      id,
      int(body.orderNumber),
      str(body.squareOrderId, 64),
      str(body.squarePaymentId, 64),
      str(body.customerName, 80),
      totalCents,
      int(body.subtotalCents),
      int(body.taxCents),
      str(body.card, 64),
      body.simulated === true ? 1 : 0,
      JSON.stringify(body.items).slice(0, 32 * 1024),
      Array.isArray(body.lines) ? JSON.stringify(body.lines).slice(0, 32 * 1024) : null,
      paidAt,
      str(body.device, 64),
      str(body.appVersion, 40),
      now,
    )
    .run();
  const duplicate = (result.meta.changes ?? 0) === 0;
  console.log({
    event: "order",
    id,
    orderNumber: int(body.orderNumber),
    totalCents,
    squareOrderId: str(body.squareOrderId, 64),
    simulated: body.simulated === true,
    duplicate,
  });
  return json({ ok: true, duplicate });
}

async function listOrders(url: URL, env: Env): Promise<Response> {
  const since = Number(url.searchParams.get("since") ?? "0") || 0;
  const { results } = await env.DB.prepare(
    `SELECT id, order_number, square_order_id, square_payment_id, customer_name, total_cents, subtotal_cents, tax_cents,
            card, simulated, items, lines, paid_at
     FROM orders WHERE paid_at >= ? ORDER BY paid_at DESC LIMIT 500`,
  )
    .bind(since)
    .all<{ simulated: number; total_cents: number; items: string; lines: string | null }>();
  const orders = results.map((r) => ({
    ...r,
    items: JSON.parse(r.items),
    lines: r.lines ? JSON.parse(r.lines) : null,
  }));
  const real = orders.filter((o) => !o.simulated);
  return json({
    count: real.length,
    totalCents: real.reduce((sum, o) => sum + o.total_cents, 0),
    orders,
  });
}

async function connect(request: Request, env: Env): Promise<Response> {
  if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
    return problem(426, "Expected a websocket upgrade");
  }
  const auth = await authenticate(request, env, ["kiosk", "staff"]);
  if ("error" in auth) return auth.error;
  const headers = new Headers({ Upgrade: "websocket", "X-Booth-Role": auth.role });
  if (request.headers.get("Sec-WebSocket-Protocol")?.includes(SUBPROTOCOL)) {
    headers.set("Sec-WebSocket-Protocol", SUBPROTOCOL);
  }
  return booth(env).fetch("https://booth/ws", { headers });
}

async function route(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const { pathname } = url;
  const method = request.method;

  if (pathname === "/v1/health" && method === "GET") return json({ ok: true });
  if (pathname === "/v1/ws") return connect(request, env);

  if (pathname === "/v1/staff/login" && method === "POST") {
    const auth = await authenticate(request, env, ["staff"]);
    return "error" in auth ? auth.error : json({ ok: true });
  }
  if (pathname === "/v1/state" && method === "GET") {
    const auth = await authenticate(request, env, ["kiosk", "staff"]);
    return "error" in auth ? auth.error : json(await booth(env).getState());
  }
  if (pathname === "/v1/logs" && method === "POST") {
    const auth = await authenticate(request, env, ["kiosk"]);
    return "error" in auth ? auth.error : ingestLogs(request, env);
  }
  if (pathname === "/v1/orders" && method === "POST") {
    const auth = await authenticate(request, env, ["kiosk"]);
    return "error" in auth ? auth.error : ingestOrder(request, env);
  }
  if (pathname === "/v1/orders" && method === "GET") {
    const auth = await authenticate(request, env, ["staff"]);
    return "error" in auth ? auth.error : listOrders(url, env);
  }
  return problem(404, "Not found");
}

export default {
  async fetch(request, env): Promise<Response> {
    try {
      return await route(request, env);
    } catch (error) {
      console.error({ event: "unhandled", path: new URL(request.url).pathname, error: String(error) });
      return problem(500, "Internal error");
    }
  },

  async scheduled(_controller, env): Promise<void> {
    const days = Number(env.LOG_RETENTION_DAYS) || 30;
    const cutoff = Date.now() - days * 24 * 60 * 60 * 1000;
    const result = await env.DB.prepare("DELETE FROM logs WHERE ts < ?").bind(cutoff).run();
    console.log({ event: "log-retention", deleted: result.meta.changes, cutoff: new Date(cutoff).toISOString() });
  },
} satisfies ExportedHandler<Env>;
