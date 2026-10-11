import * as z from "zod";
import { base64url, clientIp, fromBase64url, HttpError, json, readBody, safeEqual, type Route } from "./http";

export const STAFF_COOKIE = "booth_staff";
export const SESSION_TTL_MS = 72 * 60 * 60_000;
const PREFIX = "st1";

interface SessionPayload {
  sid: string;
  iat: number;
  exp: number;
}

async function sessionKey(env: Env): Promise<CryptoKey | null> {
  if (!env.STAFF_TOKEN) return null;
  const material = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`booth-staff-session\n${env.STAFF_TOKEN}`));
  return crypto.subtle.importKey("raw", material, { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]);
}

export async function createStaffSession(env: Env, now = Date.now()): Promise<{ token: string; expiresAt: number }> {
  const key = await sessionKey(env);
  if (!key) throw new HttpError(503, "not_configured", "STAFF_TOKEN isn't set", {}, false);
  const payload: SessionPayload = { sid: base64url(crypto.getRandomValues(new Uint8Array(9))), iat: now, exp: now + SESSION_TTL_MS };
  const body = base64url(new TextEncoder().encode(JSON.stringify(payload)));
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${PREFIX}.${body}`));
  return { token: `${PREFIX}.${body}.${base64url(signature)}`, expiresAt: payload.exp };
}

export async function readStaffSession(token: string, env: Env, now = Date.now()): Promise<SessionPayload | null> {
  const parts = token.split(".");
  if (parts.length !== 3 || parts[0] !== PREFIX) return null;
  const key = await sessionKey(env);
  if (!key) return null;
  try {
    const valid = await crypto.subtle.verify("HMAC", key, fromBase64url(parts[2]), new TextEncoder().encode(`${PREFIX}.${parts[1]}`));
    if (!valid) return null;
    const payload = JSON.parse(new TextDecoder().decode(fromBase64url(parts[1]))) as SessionPayload;
    if (typeof payload.exp !== "number" || payload.exp <= now || typeof payload.sid !== "string") return null;
    return payload;
  } catch {
    return null;
  }
}

/** The staff PIN (`STAFF_PIN`) or the staff token itself. Attempts are rate limited per IP. */
export async function checkStaffSecret(request: Request, env: Env, secret: string): Promise<void> {
  const { success } = await env.LOGIN_LIMITER.limit({ key: `login:${clientIp(request)}` });
  if (!success) throw new HttpError(429, "rate_limited", "Too many attempts, wait a minute", { "Retry-After": "60" });
  const candidates = [env.STAFF_PIN, env.STAFF_TOKEN].filter((s): s is string => !!s && s.length > 0);
  for (const candidate of candidates) {
    if (await safeEqual(secret, candidate)) return;
  }
  throw new HttpError(401, "unauthorized", "Wrong PIN");
}

export function sessionCookie(token: string, expiresAt: number): string {
  return `${STAFF_COOKIE}=${token}; Path=/; Expires=${new Date(expiresAt).toUTCString()}; HttpOnly; Secure; SameSite=Strict`;
}

export function clearedSessionCookie(): string {
  return `${STAFF_COOKIE}=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Strict`;
}

const SessionBody = z.object({ pin: z.string().min(1).max(256) });

export const routes: Route[] = [
  {
    method: "POST",
    path: "/v1/staff/session",
    async handle({ request, env }) {
      const body = await readBody(request, SessionBody, 4 * 1024);
      await checkStaffSecret(request, env, body.pin);
      return json(await createStaffSession(env));
    },
  },
];
