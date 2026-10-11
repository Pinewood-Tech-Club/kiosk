import * as z from "zod";
import type { ApiError, ItemResult, Role } from "./protocol";
import {
  ActionsBody,
  DeviceId,
  EventsBody,
  LogLine,
  LogsBody,
  Order,
  OrdersBody,
  PROTOCOL_VERSION,
  describe,
  parseTimestamp,
} from "./schema";

export { Booth } from "./booth";

const SERVICE = "techclub-icecream";
const D1_CHUNK = 50;

class HttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly headers: Record<string, string> = {},
  ) {
    super(message);
  }

  get retryable(): boolean {
    return this.status === 429 || this.status >= 500;
  }
}

function json(data: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return Response.json(data, { status, headers: { "Cache-Control": "no-store", ...headers } });
}

function errorResponse(error: HttpError): Response {
  const body: { error: ApiError } = { error: { code: error.code, message: error.message, retryable: error.retryable } };
  return json(body, error.status, error.headers);
}

async function safeEqual(a: string, b: string): Promise<boolean> {
  const encoder = new TextEncoder();
  const [x, y] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(a)),
    crypto.subtle.digest("SHA-256", encoder.encode(b)),
  ]);
  return crypto.subtle.timingSafeEqual(x, y);
}

interface Client {
  role: Role;
  device: string;
}

async function authenticate(request: Request, env: Env, allowed: Role[]): Promise<Client> {
  const header = request.headers.get("Authorization") ?? "";
  if (!header.startsWith("Bearer ")) throw new HttpError(401, "unauthorized", "Send Authorization: Bearer <token>");
  const token = header.slice(7).trim();
  let role: Role | null = null;
  if (env.BOOTH_TOKEN && (await safeEqual(token, env.BOOTH_TOKEN))) role = "kiosk";
  else if (env.STAFF_TOKEN && (await safeEqual(token, env.STAFF_TOKEN))) role = "staff";
  if (!role) throw new HttpError(401, "unauthorized", "Unknown token");
  if (!allowed.includes(role)) throw new HttpError(403, "forbidden", `The ${role} role can't use this route`);

  const device = DeviceId.safeParse(request.headers.get("X-Booth-Device"));
  if (!device.success) throw new HttpError(400, "bad_request", "Send X-Booth-Device: 1 to 64 of A-Z a-z 0-9 . _ -");

  const { success } = await env.CLIENT_LIMITER.limit({ key: `${role}:${device.data}` });
  if (!success) throw new HttpError(429, "rate_limited", "Too many requests from this device", { "Retry-After": "30" });
  return { role, device: device.data };
}

async function readBody<T extends z.ZodType>(request: Request, schema: T, maxBytes: number): Promise<z.infer<T>> {
  const declared = Number(request.headers.get("Content-Length") ?? "0");
  if (declared > maxBytes) throw new HttpError(413, "too_large", `Body over ${maxBytes} bytes`);
  const text = await request.text();
  if (text.length > maxBytes) throw new HttpError(413, "too_large", `Body over ${maxBytes} bytes`);
  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch {
    throw new HttpError(400, "bad_request", "Body is not JSON");
  }
  const parsed = schema.safeParse(raw);
  if (!parsed.success) throw new HttpError(400, "bad_request", describe(parsed.error));
  return parsed.data;
}

async function withRetry<T>(label: string, attempt: () => Promise<T>, tries = 3): Promise<T> {
  let lastError: unknown;
  for (let i = 0; i < tries; i++) {
    try {
      return await attempt();
    } catch (error) {
      lastError = error;
      console.warn({ event: "retry", label, attempt: i + 1, error: String(error) });
      if (i < tries - 1) await new Promise((r) => setTimeout(r, 150 * 3 ** i));
    }
  }
  console.error({ event: "gave-up", label, error: String(lastError) });
  throw new HttpError(503, "unavailable", `${label} is unavailable, retry later`);
}

function hub(env: Env) {
  return env.BOOTH.getByName("booth");
}

async function callHub<T>(label: string, call: () => Promise<T>): Promise<T> {
  try {
    return await call();
  } catch (error) {
    console.error({ event: "hub-failed", label, error: String(error) });
    throw new HttpError(503, "unavailable", "The booth hub is unavailable, retry later");
  }
}

function noteKioskContact(env: Env, ctx: ExecutionContext) {
  ctx.waitUntil(hub(env).noteKioskContact().catch((error) => console.warn({ event: "contact-failed", error: String(error) })));
}

async function ingestLogs(request: Request, env: Env, client: Client): Promise<Response> {
  const body = await readBody(request, LogsBody, 1024 * 1024);
  const now = Date.now();
  const statement = env.DB.prepare(
    "INSERT OR IGNORE INTO logs (id, device, app_version, ts, level, message, context, received_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
  );
  const rows: D1PreparedStatement[] = [];
  let rejected = 0;
  for (const item of body.lines) {
    const parsed = LogLine.safeParse(item);
    if (!parsed.success) {
      rejected++;
      continue;
    }
    const line = parsed.data;
    const ts = parseTimestamp(line.ts, now);
    const context = line.context ? JSON.stringify(line.context).slice(0, 8 * 1024) : null;
    rows.push(statement.bind(line.id, client.device, body.appVersion ?? null, ts, line.level, line.message, context, now));
    const entry = { source: "kiosk", device: client.device, appVersion: body.appVersion, ts: new Date(ts).toISOString(), level: line.level, message: line.message, context: line.context };
    if (line.level === "error") console.error(entry);
    else if (line.level === "warn") console.warn(entry);
    else console.log(entry);
  }
  let stored = 0;
  for (let i = 0; i < rows.length; i += D1_CHUNK) {
    const chunk = rows.slice(i, i + D1_CHUNK);
    const results = await withRetry("D1", () => env.DB.batch(chunk));
    stored += results.reduce((sum, r) => sum + (r.meta.changes ?? 0), 0);
  }
  return json({ accepted: rows.length, stored, duplicates: rows.length - stored, rejected });
}

async function ingestOrders(request: Request, env: Env, client: Client): Promise<Response> {
  const body = await readBody(request, OrdersBody, 512 * 1024);
  const now = Date.now();
  const statement = env.DB.prepare(
    `INSERT OR IGNORE INTO orders (id, order_number, square_order_id, square_payment_id, customer_name, total_cents,
       subtotal_cents, tax_cents, card, simulated, items, lines, paid_at, device, app_version, received_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  );
  const results: ItemResult[] = [];
  const pending: { index: number; statement: D1PreparedStatement }[] = [];
  for (const item of body.orders) {
    const parsed = Order.safeParse(item);
    if (!parsed.success) {
      const id = typeof (item as { id?: unknown })?.id === "string" ? String((item as { id: string }).id).slice(0, 64) : "";
      results.push({ id, status: "rejected", error: { code: "bad_request", message: describe(parsed.error) } });
      continue;
    }
    const o = parsed.data;
    results.push({ id: o.id, status: "ok" });
    pending.push({
      index: results.length - 1,
      statement: statement.bind(
        o.id, o.orderNumber ?? null, o.squareOrderId ?? null, o.squarePaymentId || null, o.customerName ?? null, o.totalCents,
        o.subtotalCents ?? null, o.taxCents ?? null, o.card ?? null, o.simulated ? 1 : 0, JSON.stringify(o.items),
        o.lines ? JSON.stringify(o.lines) : null, parseTimestamp(o.paidAt, now), client.device, o.appVersion ?? null, now,
      ),
    });
  }
  for (let i = 0; i < pending.length; i += D1_CHUNK) {
    const chunk = pending.slice(i, i + D1_CHUNK);
    const outcomes = await withRetry("D1", () => env.DB.batch(chunk.map((p) => p.statement)));
    outcomes.forEach((outcome, j) => {
      if ((outcome.meta.changes ?? 0) === 0) results[chunk[j].index].status = "duplicate";
    });
  }
  for (const result of results) {
    console.log({ event: "order", id: result.id, status: result.status, device: client.device });
  }
  return json({ results });
}

async function listOrders(url: URL, env: Env): Promise<Response> {
  const since = Number(url.searchParams.get("since") ?? "0") || 0;
  const limit = Math.min(Math.max(Number(url.searchParams.get("limit") ?? "500") || 500, 1), 2000);
  const { results } = await withRetry("D1", () =>
    env.DB.prepare(
      `SELECT id, order_number, square_order_id, square_payment_id, customer_name, total_cents, subtotal_cents, tax_cents,
              card, simulated, items, lines, paid_at, device
       FROM orders WHERE paid_at >= ? ORDER BY paid_at DESC LIMIT ?`,
    )
      .bind(since, limit)
      .all<{ simulated: number; total_cents: number; items: string; lines: string | null }>(),
  );
  const orders = results.map((r) => ({ ...r, items: JSON.parse(r.items), lines: r.lines ? JSON.parse(r.lines) : null }));
  const real = orders.filter((o) => !o.simulated);
  return json({ count: real.length, totalCents: real.reduce((sum, o) => sum + o.total_cents, 0), orders });
}

async function connect(request: Request, env: Env): Promise<Response> {
  if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
    throw new HttpError(426, "upgrade_required", "Open this route as a websocket");
  }
  const client = await authenticate(request, env, ["kiosk", "staff"]);
  const headers = new Headers({ Upgrade: "websocket", "X-Booth-Role": client.role, "X-Booth-Device": client.device });
  return callHub("connect", () => hub(env).fetch("https://booth/ws", { headers }));
}

async function health(request: Request, url: URL, env: Env): Promise<Response> {
  const base = { ok: true, service: SERVICE, protocol: PROTOCOL_VERSION, time: Date.now() };
  if (url.searchParams.get("deep") !== "1") return json(base);
  await authenticate(request, env, ["kiosk", "staff"]);
  const [d1, booth] = await Promise.allSettled([env.DB.prepare("SELECT 1 AS one").first(), hub(env).check()]);
  const checks = { d1: d1.status === "fulfilled", hub: booth.status === "fulfilled" };
  const ok = checks.d1 && checks.hub;
  return json({ ...base, ok, checks }, ok ? 200 : 503);
}

async function route(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const url = new URL(request.url);
  const { pathname } = url;
  const method = request.method;

  if (pathname === "/v1/health" && method === "GET") return health(request, url, env);
  if (pathname === "/v1/ws" && method === "GET") return connect(request, env);
  if (pathname === "/v1/state" && method === "GET") {
    await authenticate(request, env, ["kiosk", "staff"]);
    return json(await callHub("state", () => hub(env).getState()));
  }
  if (pathname === "/v1/events" && method === "POST") {
    const client = await authenticate(request, env, ["kiosk"]);
    const body = await readBody(request, EventsBody, 256 * 1024);
    return json(await callHub("events", () => hub(env).ingestEvents(client.device, body.events)));
  }
  if (pathname === "/v1/actions" && method === "POST") {
    const client = await authenticate(request, env, ["staff"]);
    const body = await readBody(request, ActionsBody, 64 * 1024);
    return json(await callHub("actions", () => hub(env).applyActions(client.device, body.actions)));
  }
  if (pathname === "/v1/logs" && method === "POST") {
    const client = await authenticate(request, env, ["kiosk"]);
    const response = await ingestLogs(request, env, client);
    noteKioskContact(env, ctx);
    return response;
  }
  if (pathname === "/v1/orders" && method === "POST") {
    const client = await authenticate(request, env, ["kiosk"]);
    const response = await ingestOrders(request, env, client);
    noteKioskContact(env, ctx);
    return response;
  }
  if (pathname === "/v1/orders" && method === "GET") {
    await authenticate(request, env, ["staff"]);
    return listOrders(url, env);
  }
  throw new HttpError(404, "not_found", `No route for ${method} ${pathname}`);
}

export default {
  async fetch(request, env, ctx): Promise<Response> {
    try {
      return await route(request, env, ctx);
    } catch (error) {
      if (error instanceof HttpError) return errorResponse(error);
      console.error({ event: "unhandled", path: new URL(request.url).pathname, error: String(error), stack: (error as Error)?.stack });
      return errorResponse(new HttpError(500, "internal", "Internal error, retry later"));
    }
  },

  async scheduled(_controller, env): Promise<void> {
    const days = Number(env.LOG_RETENTION_DAYS) || 30;
    const cutoff = Date.now() - days * 24 * 60 * 60 * 1000;
    try {
      const result = await withRetry("D1", () => env.DB.prepare("DELETE FROM logs WHERE ts < ?").bind(cutoff).run());
      console.log({ event: "log-retention", deleted: result.meta.changes, cutoff: new Date(cutoff).toISOString() });
    } catch (error) {
      console.error({ event: "log-retention-failed", error: String(error) });
    }
  },
} satisfies ExportedHandler<Env>;
