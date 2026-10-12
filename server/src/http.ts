import * as z from "zod";
import type { ApiError, Role } from "./protocol";
import { DeviceId, describe } from "./schema";
import { readStaffSession, STAFF_COOKIE } from "./session";

export class HttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly headers: Record<string, string> = {},
    private readonly retryableOverride?: boolean,
  ) {
    super(message);
  }

  get retryable(): boolean {
    return this.retryableOverride ?? (this.status === 429 || this.status >= 500);
  }
}

export interface RouteContext {
  request: Request;
  env: Env;
  ctx: ExecutionContext;
  url: URL;
  params: string[];
}

export interface Route {
  method: "GET" | "POST" | "PUT" | "DELETE";
  path: string | RegExp;
  handle: (c: RouteContext) => Promise<Response>;
}

export function match(routes: Route[], method: string, pathname: string): { route: Route; params: string[] } | null {
  for (const route of routes) {
    if (route.method !== method) continue;
    if (typeof route.path === "string") {
      if (route.path === pathname) return { route, params: [] };
      continue;
    }
    const found = route.path.exec(pathname);
    if (found) return { route, params: found.slice(1).map((p) => decodeURIComponent(p)) };
  }
  return null;
}

export function json(data: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return Response.json(data, { status, headers: { "Cache-Control": "no-store", ...headers } });
}

export function html(body: string, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(body, {
    status,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
      "Referrer-Policy": "no-referrer",
      "X-Frame-Options": "DENY",
      ...headers,
    },
  });
}

export function escapeHtml(text: string): string {
  return text.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
}

export function errorResponse(error: HttpError): Response {
  const body: { error: ApiError } = { error: { code: error.code, message: error.message, retryable: error.retryable } };
  return json(body, error.status, error.headers);
}

export async function safeEqual(a: string, b: string): Promise<boolean> {
  const encoder = new TextEncoder();
  const [x, y] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(a)),
    crypto.subtle.digest("SHA-256", encoder.encode(b)),
  ]);
  return crypto.subtle.timingSafeEqual(x, y);
}

export interface Client {
  role: Role;
  device: string;
  via: "token" | "session";
}

export function cookie(request: Request, name: string): string | null {
  const header = request.headers.get("Cookie");
  if (!header) return null;
  for (const part of header.split(";")) {
    const [key, ...rest] = part.trim().split("=");
    if (key === name) return rest.join("=");
  }
  return null;
}

async function roleForBearer(token: string, env: Env): Promise<{ role: Role; via: Client["via"]; sessionId?: string } | null> {
  if (env.BOOTH_TOKEN && (await safeEqual(token, env.BOOTH_TOKEN))) return { role: "kiosk", via: "token" };
  if (env.STAFF_TOKEN && (await safeEqual(token, env.STAFF_TOKEN))) return { role: "staff", via: "token" };
  const session = await readStaffSession(token, env);
  if (session) return { role: "staff", via: "session", sessionId: session.sid };
  return null;
}

/**
 * Bearer tokens work everywhere. A staff session cookie (the dashboard) is only accepted for the staff role, and for
 * anything but GET only from the same origin, so another site can't ride the cookie.
 */
export async function authenticate(request: Request, env: Env, allowed: Role[]): Promise<Client> {
  const header = request.headers.get("Authorization") ?? "";
  let found: Awaited<ReturnType<typeof roleForBearer>> = null;
  if (header.startsWith("Bearer ")) {
    found = await roleForBearer(header.slice(7).trim(), env);
    if (!found) throw new HttpError(401, "unauthorized", "Unknown token");
  } else {
    const sessionCookie = cookie(request, STAFF_COOKIE);
    const session = sessionCookie ? await readStaffSession(sessionCookie, env) : null;
    if (!session) throw new HttpError(401, "unauthorized", "Send Authorization: Bearer <token>");
    if (request.method !== "GET" && request.method !== "HEAD") {
      const origin = request.headers.get("Origin");
      if (!origin || origin !== new URL(request.url).origin) throw new HttpError(403, "forbidden", "Cross-origin request refused");
    }
    found = { role: "staff", via: "session", sessionId: session.sid };
  }
  if (!allowed.includes(found.role)) throw new HttpError(403, "forbidden", `The ${found.role} role can't use this route`);

  let deviceHeader = request.headers.get("X-Booth-Device");
  if (!deviceHeader && found.via === "session" && found.sessionId) deviceHeader = `web-${found.sessionId}`;
  const device = DeviceId.safeParse(deviceHeader);
  if (!device.success) throw new HttpError(400, "bad_request", "Send X-Booth-Device: 1 to 64 of A-Z a-z 0-9 . _ -");

  const { success } = await env.CLIENT_LIMITER.limit({ key: `${found.role}:${device.data}` });
  if (!success) throw new HttpError(429, "rate_limited", "Too many requests from this device", { "Retry-After": "30" });
  return { role: found.role, device: device.data, via: found.via };
}

export async function readBody<T extends z.ZodType>(request: Request, schema: T, maxBytes: number): Promise<z.infer<T>> {
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

export async function withRetry<T>(label: string, attempt: () => Promise<T>, tries = 3): Promise<T> {
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

export function hub(env: Env) {
  return env.BOOTH.getByName("booth");
}

export async function callHub<T>(label: string, call: () => Promise<T>): Promise<T> {
  try {
    return await call();
  } catch (error) {
    console.error({ event: "hub-failed", label, error: String(error) });
    throw new HttpError(503, "unavailable", "The booth hub is unavailable, retry later");
  }
}

export function noteKioskContact(env: Env, ctx: ExecutionContext, device: string) {
  ctx.waitUntil(hub(env).noteKioskContact(device).catch((error) => console.warn({ event: "contact-failed", error: String(error) })));
}

export function randomToken(bytes = 16): string {
  return base64url(crypto.getRandomValues(new Uint8Array(bytes)));
}

export function base64url(data: ArrayBuffer | Uint8Array): string {
  const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function fromBase64url(text: string): Uint8Array {
  const padded = text.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (text.length % 4)) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

export async function sha256(text: string): Promise<string> {
  return base64url(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
}

export function clientIp(request: Request): string {
  return request.headers.get("CF-Connecting-IP") ?? "unknown";
}
