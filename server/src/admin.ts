import * as z from "zod";
import { adminBody, adminScript, adminStyle } from "./admin-page";
import { catalogReport, type CatalogReport } from "./catalog";
import { staffPage } from "./dashboard";
import { callHub, HttpError, hub, json, readBody, withRetry, type Route, type RouteContext } from "./http";
import { resolveCredentials, refreshToken, squareStatus, startAuthorization, type SquareCredentials } from "./oauth";
import type { ItemResult } from "./protocol";
import {
  AdminByBody,
  AdminControlBody,
  AdminDebugBody,
  AdminOrderStatusBody,
  AdminResetBody,
  AdminSessionBody,
  DeviceId,
} from "./schema";
import { checkStaffSecret, newSessionId, signSession, verifySession, type SessionPayload } from "./session";
import { listLocations, squareEnvironment, type SquareEnvironment } from "./square";
import { summarize } from "./stats";

export const ADMIN_IDLE_MS = 15 * 60_000;
export const ADMIN_MAX_MS = 4 * 60 * 60_000;
export const ADMIN_TOKEN_HEADER = "X-Booth-Admin-Token";
const ADMIN_PREFIX = "ad1";
const ADMIN_LABEL = "booth-admin-session";
const RENEW_AFTER_MS = 60_000;
const LEVELS = ["debug", "info", "warn", "error"] as const;
const TEST_ORDERS = "(simulated = 1 OR device LIKE 'smoke-%' OR device LIKE 'chaos-%')";
const TEST_CHECKOUTS = "(device LIKE 'smoke-%' OR device LIKE 'chaos-%')";
const OPEN_HOLDS = "(SELECT checkout_id FROM giftcard_payments WHERE status IN ('pending', 'approved'))";

export interface AdminSession {
  token: string;
  expiresAt: number;
}

interface AdminClient {
  payload: SessionPayload;
  device: string;
  renewed: AdminSession | null;
}

type AdminContext = RouteContext & { admin: AdminClient };

export async function createAdminSession(env: Env, now = Date.now(), previous?: SessionPayload): Promise<AdminSession> {
  const since = previous?.iat ?? now;
  const payload: SessionPayload = { sid: previous?.sid ?? newSessionId(), iat: since, exp: Math.min(now + ADMIN_IDLE_MS, since + ADMIN_MAX_MS) };
  return { token: await signSession(env, ADMIN_PREFIX, ADMIN_LABEL, payload), expiresAt: payload.exp };
}

/** Only an admin token counts, never a staff session or STAFF_TOKEN. The page keeps it in memory, not a cookie, so every visit asks for the PIN. */
export async function authenticateAdmin(request: Request, env: Env, now = Date.now()): Promise<AdminClient> {
  const header = request.headers.get("Authorization") ?? "";
  const token = header.startsWith("Bearer ") ? header.slice(7).trim() : "";
  const payload = token ? await verifySession(token, env, ADMIN_PREFIX, ADMIN_LABEL, now) : null;
  if (!payload) throw new HttpError(401, "admin_required", "Enter the staff PIN to use the admin tools");
  const { success } = await env.CLIENT_LIMITER.limit({ key: `admin:${payload.sid}` });
  if (!success) throw new HttpError(429, "rate_limited", "Too many requests", { "Retry-After": "30" });
  const renewable = payload.exp - now < ADMIN_IDLE_MS - RENEW_AFTER_MS && payload.exp < payload.iat + ADMIN_MAX_MS;
  return { payload, device: `admin-${payload.sid}`, renewed: renewable ? await createAdminSession(env, now, payload) : null };
}

function adminRoute(method: Route["method"], path: Route["path"], handle: (c: AdminContext) => Promise<Response>): Route {
  return {
    method,
    path,
    async handle(c) {
      const admin = await authenticateAdmin(c.request, c.env);
      const response = await handle({ ...c, admin });
      const headers = new Headers(response.headers);
      headers.set("X-Booth-Admin-Expires", String(admin.renewed?.expiresAt ?? admin.payload.exp));
      if (admin.renewed) headers.set(ADMIN_TOKEN_HEADER, admin.renewed.token);
      return new Response(response.body, { status: response.status, headers });
    },
  };
}

function actor(by: string | undefined): string {
  return by?.trim() || "Admin";
}

function kioskParam(raw: string): string {
  const parsed = DeviceId.safeParse(raw);
  if (!parsed.success) throw new HttpError(400, "bad_request", "Bad kiosk id");
  return parsed.data;
}

async function hubAction(env: Env, device: string, action: Record<string, unknown>): Promise<ItemResult> {
  const { results } = await callHub("actions", () => hub(env).applyActions(device, [{ id: crypto.randomUUID(), ...action }]));
  return results[0];
}

function actionResponse(result: ItemResult): Response {
  if (result.status === "rejected") {
    const status = result.error?.code === "not_found" ? 404 : 400;
    throw new HttpError(status, result.error?.code ?? "bad_request", result.error?.message ?? "Rejected");
  }
  return json({ status: result.status });
}

async function count(env: Env, sql: string): Promise<number> {
  const row = await withRetry("D1", () => env.DB.prepare(sql).first<{ n: number }>());
  return row?.n ?? 0;
}

async function audit(env: Env, action: string, by: string, detail: unknown, now = Date.now()) {
  await env.DB.prepare("INSERT INTO admin_events (id, at, action, by, detail) VALUES (?, ?, ?, ?, ?)")
    .bind(crypto.randomUUID(), now, action, by, JSON.stringify(detail))
    .run()
    .catch((error) => console.error({ event: "admin-audit-failed", action, error: String(error) }));
}

export async function resetPreview(env: Env) {
  const [orders, testOrders, checkouts, logs, giftCardRecords, giftCardHolds, hubCounts] = await Promise.all([
    count(env, "SELECT COUNT(*) AS n FROM orders"),
    count(env, `SELECT COUNT(*) AS n FROM orders WHERE ${TEST_ORDERS}`),
    count(env, `SELECT COUNT(*) AS n FROM checkouts WHERE id NOT IN ${OPEN_HOLDS}`),
    count(env, "SELECT COUNT(*) AS n FROM logs"),
    count(env, "SELECT COUNT(*) AS n FROM giftcard_payments WHERE status IN ('completed', 'canceled')"),
    count(env, "SELECT COUNT(*) AS n FROM giftcard_payments WHERE status IN ('pending', 'approved')"),
    callHub("counts", () => hub(env).counts()),
  ]);
  const epoch = await callHub("epoch", () => hub(env).currentEpoch());
  return {
    epoch,
    erase: {
      orders,
      testOrders,
      checkouts,
      logs,
      giftCardRecords,
      alerts: hubCounts.alerts,
      kiosks: hubCounts.kiosks,
      feedOrders: hubCounts.orders,
      soldOut: hubCounts.soldOut,
      processedIds: hubCounts.processed,
      assistSessions: hubCounts.sessions,
    },
    keep: { giftCardHolds },
  };
}

export async function resetEverything(env: Env, by: string, now = Date.now()) {
  const hubReset = await callHub("reset", () => hub(env).reset(by));
  const results = await withRetry("D1", () =>
    env.DB.batch([
      env.DB.prepare("DELETE FROM orders"),
      env.DB.prepare(`DELETE FROM checkouts WHERE id NOT IN ${OPEN_HOLDS}`),
      env.DB.prepare("DELETE FROM giftcard_payments WHERE status IN ('completed', 'canceled')"),
      env.DB.prepare("DELETE FROM giftcard_lookup_failures"),
      env.DB.prepare("DELETE FROM logs"),
    ]),
  );
  const [orders, checkouts, giftCardRecords, , logs] = results.map((r) => r.meta.changes ?? 0);
  const erased = { ...hubReset.erased, d1: { orders, checkouts, giftCardRecords, logs } };
  const message = `Booth reset by ${by}: epoch ${hubReset.epoch}; erased ${orders} orders, ${checkouts} checkouts, ${logs} log lines, ${hubReset.erased.alerts} alerts, ${hubReset.erased.kiosks} kiosks`;
  await env.DB.prepare("INSERT OR IGNORE INTO logs (id, device, app_version, ts, level, message, context, received_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)")
    .bind(`reset-${hubReset.epoch}-${now}`, "booth-admin", null, now, "warn", message, JSON.stringify({ epoch: hubReset.epoch, by, erased }), now)
    .run()
    .catch((error) => console.error({ event: "reset-log-failed", error: String(error) }));
  await audit(env, "reset", by, { epoch: hubReset.epoch, erased }, now);
  console.warn({ event: "booth-reset", by, epoch: hubReset.epoch, erased });
  return { epoch: hubReset.epoch, resetAt: hubReset.resetAt, erased };
}

async function backup(env: Env, now = Date.now()) {
  const [{ results: orders }, hubData, stats] = await Promise.all([
    withRetry("D1", () => env.DB.prepare("SELECT * FROM orders ORDER BY paid_at DESC").all<Record<string, unknown> & { items: string; lines: string | null }>()),
    callHub("backup", () => hub(env).backup()),
    summarize(env, 0, now + 1, now),
  ]);
  return {
    service: "techclub-icecream",
    exportedAt: now,
    squareEnvironment: squareEnvironment(env),
    epoch: hubData.epoch,
    orders: orders.map((o) => ({ ...o, items: parseJson(o.items, []), lines: parseJson(o.lines, null) })),
    kiosks: hubData.kiosks,
    alerts: hubData.alerts,
    orderFeed: hubData.orders,
    supplies: hubData.supplies,
    stats,
  };
}

function parseJson<T>(text: string | null, fallback: T): T {
  if (!text) return fallback;
  try {
    return JSON.parse(text) as T;
  } catch {
    return fallback;
  }
}

function likePattern(text: string): string {
  return `%${text.replace(/[\\%_]/g, (c) => `\\${c}`)}%`;
}

async function searchLogs(env: Env, url: URL) {
  const params = url.searchParams;
  const device = params.get("device") || null;
  const level = (LEVELS as readonly string[]).includes(params.get("level") ?? "") ? params.get("level")! : "debug";
  const levels = LEVELS.slice(LEVELS.indexOf(level as (typeof LEVELS)[number]));
  const since = Number(params.get("since")) || 0;
  const until = Number(params.get("until")) || null;
  const text = params.get("q")?.trim() || null;
  const limit = Math.min(Math.max(Number(params.get("limit")) || 100, 1), 200);
  const cursor = /^(\d+):(.+)$/.exec(params.get("before") ?? "");
  const { results } = await withRetry("D1", () =>
    env.DB.prepare(
      `SELECT id, device, app_version, ts, level, message, context, received_at FROM logs
       WHERE (?1 IS NULL OR device = ?1) AND level IN (${levels.map((_, i) => `?${8 + i}`).join(", ")}) AND ts >= ?2 AND (?3 IS NULL OR ts < ?3)
         AND (?4 IS NULL OR message LIKE ?4 ESCAPE '\\' OR context LIKE ?4 ESCAPE '\\')
         AND (?5 IS NULL OR ts < ?5 OR (ts = ?5 AND id < ?6))
       ORDER BY ts DESC, id DESC LIMIT ?7`,
    )
      .bind(device, since, until, text ? likePattern(text) : null, cursor ? Number(cursor[1]) : null, cursor ? cursor[2] : null, limit + 1, ...levels)
      .all<{ id: string; ts: number; context: string | null }>(),
  );
  const page = results.slice(0, limit).map((r) => ({ ...r, context: parseJson(r.context, null) }));
  const last = page[page.length - 1];
  const devices = cursor
    ? null
    : (await withRetry("D1", () =>
        env.DB.prepare("SELECT device, COUNT(*) AS lines, MAX(ts) AS lastTs FROM logs GROUP BY device ORDER BY lastTs DESC").all<{ device: string; lines: number; lastTs: number }>(),
      )).results;
  return { lines: page, next: results.length > limit && last ? `${last.ts}:${last.id}` : null, devices };
}

function squareDashboardUrl(environment: SquareEnvironment, paymentId: string | null): string {
  const host = environment === "sandbox" ? "https://squareupsandbox.com" : "https://squareup.com";
  return paymentId ? `${host}/dashboard/sales/transactions/${encodeURIComponent(paymentId)}` : `${host}/dashboard/sales/transactions`;
}

const ORDER_COLUMNS = `id, order_number, order_ref, customer_name, total_cents, subtotal_cents, tax_cents, card, simulated, paid_at, received_at,
  device, app_version, status, status_at, status_by, receipt_token, square_order_id, square_payment_id, gift_card_payment_id, gift_card_cents, gift_card_last4, items, lines`;

interface OrderRow {
  id: string;
  receipt_token: string | null;
  square_payment_id: string | null;
  items: string;
  lines: string | null;
  [column: string]: unknown;
}

function orderView(env: Env, row: OrderRow) {
  return {
    ...row,
    items: parseJson(row.items, []),
    lines: parseJson(row.lines, null),
    receiptUrl: row.receipt_token ? `/r/${row.receipt_token}` : null,
    squareUrl: squareDashboardUrl(squareEnvironment(env), row.square_payment_id),
  };
}

function searchTerm(raw: string): { text: string; token: string; number: number | null } {
  let text = raw.trim();
  const receipt = /\/r\/([A-Za-z0-9_-]{22,64})/.exec(text);
  const token = receipt ? receipt[1] : text.replace(/^(order|kiosk)[\s#:-]*/i, "").replace(/^#/, "");
  if (receipt) text = receipt[1];
  const number = /^\d{1,9}$/.test(token) ? Number(token) : null;
  return { text, token, number };
}

async function searchOrders(env: Env, url: URL) {
  const raw = url.searchParams.get("q") ?? "";
  const limit = Math.min(Math.max(Number(url.searchParams.get("limit")) || 50, 1), 100);
  const { text, token, number } = searchTerm(raw);
  const query = text
    ? env.DB.prepare(
        `SELECT ${ORDER_COLUMNS} FROM orders
         WHERE customer_name LIKE ?1 ESCAPE '\\' OR receipt_token = ?2 OR order_ref = ?2 COLLATE NOCASE OR id = ?2
           OR square_order_id = ?2 OR square_payment_id = ?2 OR gift_card_payment_id = ?2 OR (?3 IS NOT NULL AND order_number = ?3)
         ORDER BY paid_at DESC LIMIT ?4`,
      ).bind(likePattern(text), token, number, limit)
    : env.DB.prepare(`SELECT ${ORDER_COLUMNS} FROM orders ORDER BY paid_at DESC LIMIT ?1`).bind(limit);
  const { results } = await withRetry("D1", () => query.all<OrderRow>());
  return { query: raw, orders: results.map((r) => orderView(env, r)) };
}

async function orderDetail(env: Env, id: string) {
  const row = await withRetry("D1", () => env.DB.prepare(`SELECT ${ORDER_COLUMNS} FROM orders WHERE id = ?`).bind(id).first<OrderRow>());
  if (!row) throw new HttpError(404, "not_found", "No such order");
  const [checkout, giftCards] = await Promise.all([
    withRetry("D1", () =>
      env.DB.prepare("SELECT id, device, environment, location_id, square_order_id, total_cents, tax_cents, used_catalog, created_at, completed_at FROM checkouts WHERE id = ?")
        .bind(id)
        .first(),
    ),
    withRetry("D1", () =>
      env.DB.prepare("SELECT payment_id, gan_last4, approved_cents, status, created_at, updated_at FROM giftcard_payments WHERE checkout_id = ? ORDER BY created_at")
        .bind(id)
        .all(),
    ),
  ]);
  return { order: orderView(env, row), checkout, giftCards: giftCards.results };
}

async function setOrderStatus(env: Env, admin: AdminClient, id: string, status: string, by: string) {
  const result = await hubAction(env, admin.device, { type: "setOrderStatus", orderId: id, status, by });
  if (result.status !== "rejected") return { status, via: "hub" };
  if (result.error?.code !== "not_found") throw new HttpError(400, result.error?.code ?? "bad_request", result.error?.message ?? "Rejected");
  const updated = await withRetry("D1", () =>
    env.DB.prepare("UPDATE orders SET status = ?, status_at = ?, status_by = ? WHERE id = ?").bind(status, Date.now(), by, id).run(),
  );
  if ((updated.meta.changes ?? 0) === 0) throw new HttpError(404, "not_found", "No such order");
  return { status, via: "d1" };
}

interface Check {
  id: string;
  name: string;
  ok: boolean;
  detail: string;
  ms: number;
}

async function timed(id: string, name: string, run: () => Promise<string>): Promise<Check> {
  const started = Date.now();
  try {
    const detail = await run();
    return { id, name, ok: true, detail, ms: Date.now() - started };
  } catch (error) {
    return { id, name, ok: false, detail: error instanceof Error ? error.message : String(error), ms: Date.now() - started };
  }
}

async function credentialsOrThrow(env: Env): Promise<SquareCredentials> {
  const credentials = await resolveCredentials(env);
  if (!credentials) throw new Error("Square isn't connected: no OAuth token and no SQUARE_ACCESS_TOKEN");
  return credentials;
}

async function selfTest(env: Env) {
  const checks = await Promise.all([
    timed("d1", "Database (D1)", async () => {
      const n = await count(env, "SELECT COUNT(*) AS n FROM orders");
      return `Reachable, ${n} order${n === 1 ? "" : "s"} stored`;
    }),
    timed("hub", "Live hub", async () => {
      const { rev } = await hub(env).check();
      return `Reachable, revision ${rev}`;
    }),
    timed("square", "Square API", async () => {
      const credentials = await credentialsOrThrow(env);
      const locations = await listLocations(credentials.environment, credentials.accessToken);
      const location = locations.find((l) => l.id === credentials.locationId);
      if (!location) throw new Error(`Location ${credentials.locationId} isn't on this Square account`);
      return `${credentials.environment === "sandbox" ? "Sandbox" : "Production"}, ${location.name || location.id} (${credentials.source === "oauth" ? "OAuth" : "static token"})`;
    }),
    timed("catalog", "Square catalog", async () => {
      const report = await catalogReport(env, await credentialsOrThrow(env));
      if (report.error) throw new Error(report.error);
      const bad = report.items.filter((i) => !i.ok);
      if (bad.length) throw new Error(bad.map((i) => `${i.name}: ${i.problem}`).join("; "));
      return `Category "${report.categoryName}" has all ${report.items.length} items at the expected prices`;
    }),
  ]);
  return { ok: checks.every((c) => c.ok), checks, at: Date.now() };
}

async function squareCheck(env: Env, origin: string) {
  const status = await squareStatus(env, origin, false);
  const credentials = await resolveCredentials(env).catch(() => null);
  let location: { id: string; name: string; status: string } | null = null;
  let reachable: { ok: boolean; error: string | null } | null = null;
  let catalog: CatalogReport | null = null;
  if (credentials) {
    const [locations, report] = await Promise.all([
      listLocations(credentials.environment, credentials.accessToken).then(
        (list) => ({ list, error: null as string | null }),
        (error: unknown) => ({ list: [], error: error instanceof Error ? error.message : String(error) }),
      ),
      catalogReport(env, credentials),
    ]);
    const found = locations.list.find((l) => l.id === credentials.locationId);
    location = found ? { id: found.id, name: found.name, status: found.status } : { id: credentials.locationId, name: "", status: "" };
    reachable = locations.error ? { ok: false, error: locations.error } : found ? { ok: true, error: null } : { ok: false, error: `Location ${credentials.locationId} not found for this token` };
    catalog = report;
  }
  return { ...status, location, reachable, catalog, expiresAt: credentials?.expiresAt ?? null, merchantId: credentials?.merchantId ?? null };
}

async function cleanupPreview(env: Env) {
  const [testOrders, testCheckouts, state] = await Promise.all([
    count(env, `SELECT COUNT(*) AS n FROM orders WHERE ${TEST_ORDERS}`),
    count(env, `SELECT COUNT(*) AS n FROM checkouts WHERE ${TEST_CHECKOUTS} AND id NOT IN ${OPEN_HOLDS}`),
    callHub("counts", () => hub(env).counts()),
  ]);
  return { testOrders, testCheckouts, openAlerts: state.openAlerts };
}

async function deleteTestOrders(env: Env, by: string) {
  const { results } = await withRetry("D1", () => env.DB.prepare(`SELECT id FROM orders WHERE ${TEST_ORDERS} LIMIT 5000`).all<{ id: string }>());
  const ids = results.map((r) => r.id);
  let orders = 0;
  for (let i = 0; i < ids.length; i += 50) {
    const chunk = ids.slice(i, i + 50);
    const outcome = await withRetry("D1", () =>
      env.DB.prepare(`DELETE FROM orders WHERE ${TEST_ORDERS} AND id IN (${chunk.map(() => "?").join(", ")})`).bind(...chunk).run(),
    );
    orders += outcome.meta.changes ?? 0;
  }
  const checkouts = await withRetry("D1", () => env.DB.prepare(`DELETE FROM checkouts WHERE ${TEST_CHECKOUTS} AND id NOT IN ${OPEN_HOLDS}`).run());
  const feed = ids.length ? await callHub("orders", () => hub(env).dropOrders(ids)) : { removed: 0 };
  const outcome = { orders, checkouts: checkouts.meta.changes ?? 0, feedOrders: feed.removed };
  await audit(env, "delete-test-orders", by, outcome);
  return outcome;
}

async function bodyOrEmpty<T extends z.ZodType>(request: Request, schema: T): Promise<z.infer<T>> {
  const text = await request.text();
  return readBody(new Request(request.url, { method: "POST", body: text.trim() || "{}" }), schema, 4 * 1024);
}

export const routes: Route[] = [
  {
    method: "GET",
    path: "/staff/admin",
    async handle({ url }) {
      return staffPage(url, "Admin", adminBody(), 200, adminScript(), adminStyle());
    },
  },
  {
    method: "POST",
    path: "/v1/admin/session",
    async handle({ request, env }) {
      const body = await readBody(request, AdminSessionBody, 4 * 1024);
      await checkStaffSecret(request, env, body.pin);
      return json(await createAdminSession(env));
    },
  },
  adminRoute("GET", "/v1/admin/state", async ({ env, admin }) => {
    const state = await callHub("state", () => hub(env).getState("staff"));
    return json({ ...state, admin: { expiresAt: admin.renewed?.expiresAt ?? admin.payload.exp } });
  }),
  adminRoute("POST", /^\/v1\/admin\/kiosks\/([^/]+)\/control$/, async ({ request, env, params }) => {
    const kiosk = kioskParam(params[0]);
    const body = await readBody(request, AdminControlBody, 4 * 1024);
    const sent = await callHub("control", () => hub(env).control(kiosk, body.op, actor(body.by)));
    if (!sent.relayed) throw new HttpError(409, "kiosk_offline", "That kiosk isn't connected", {}, false);
    return json(sent);
  }),
  adminRoute("POST", /^\/v1\/admin\/kiosks\/([^/]+)\/debug$/, async ({ request, env, params, admin }) => {
    const body = await readBody(request, AdminDebugBody, 4 * 1024);
    return actionResponse(await hubAction(env, admin.device, { type: "setKioskDebug", kiosk: kioskParam(params[0]), debug: body.debug, by: actor(body.by) }));
  }),
  adminRoute("POST", /^\/v1\/admin\/kiosks\/([^/]+)\/forget$/, async ({ request, env, params, admin }) => {
    const body = await bodyOrEmpty(request, AdminByBody);
    return actionResponse(await hubAction(env, admin.device, { type: "removeKiosk", kiosk: kioskParam(params[0]), by: actor(body.by) }));
  }),
  adminRoute("GET", "/v1/admin/logs", async ({ env, url }) => json(await searchLogs(env, url))),
  adminRoute("GET", "/v1/admin/square", async ({ env, url }) => json(await squareCheck(env, url.origin))),
  adminRoute("POST", "/v1/admin/square/refresh", async ({ env }) => {
    const outcome = await refreshToken(env, { force: true });
    return json(outcome, outcome.status === "failed" ? 502 : 200);
  }),
  adminRoute("POST", "/v1/admin/square/connect", async ({ env, url, admin }) => json(await startAuthorization(env, url.origin, admin.device))),
  adminRoute("GET", "/v1/admin/orders", async ({ env, url }) => json(await searchOrders(env, url))),
  adminRoute("GET", /^\/v1\/admin\/orders\/([A-Za-z0-9._:-]{1,64})$/, async ({ env, params }) => json(await orderDetail(env, params[0]))),
  adminRoute("POST", /^\/v1\/admin\/orders\/([A-Za-z0-9._:-]{1,64})\/status$/, async ({ request, env, params, admin }) => {
    const body = await readBody(request, AdminOrderStatusBody, 4 * 1024);
    return json(await setOrderStatus(env, admin, params[0], body.status, actor(body.by)));
  }),
  adminRoute("POST", "/v1/admin/selftest", async ({ env }) => json(await selfTest(env))),
  adminRoute("GET", "/v1/admin/cleanup", async ({ env }) => json(await cleanupPreview(env))),
  adminRoute("POST", "/v1/admin/cleanup/test-orders", async ({ request, env }) => {
    const body = await bodyOrEmpty(request, AdminByBody);
    return json(await deleteTestOrders(env, actor(body.by)));
  }),
  adminRoute("POST", "/v1/admin/alerts/ack-all", async ({ request, env }) => {
    const body = await bodyOrEmpty(request, AdminByBody);
    const by = actor(body.by);
    const outcome = await callHub("ack", () => hub(env).ackAll(by));
    await audit(env, "ack-all", by, outcome);
    return json(outcome);
  }),
  adminRoute("GET", "/v1/admin/backup", async ({ env }) => {
    const data = await backup(env);
    const stamp = new Date(data.exportedAt).toISOString().replace(/[:.]/g, "-");
    return json(data, 200, { "Content-Disposition": `attachment; filename="booth-backup-${stamp}.json"` });
  }),
  adminRoute("GET", "/v1/admin/reset", async ({ env }) => json(await resetPreview(env))),
  adminRoute("POST", "/v1/admin/reset", async ({ request, env }) => {
    const body = await readBody(request, AdminResetBody, 4 * 1024);
    return json(await resetEverything(env, actor(body.by)));
  }),
];
