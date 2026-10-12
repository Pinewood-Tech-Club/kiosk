import { cookie, fromBase64url, HttpError } from "./http";

export const ACCESS_JWT_HEADER = "Cf-Access-Jwt-Assertion";
export const ACCESS_COOKIE = "CF_Authorization";

const CLOCK_SKEW_SECONDS = 60;
const KEY_TTL_MS = 10 * 60_000;
const REFETCH_INTERVAL_MS = 30_000;
const FETCH_TIMEOUT_MS = 5_000;

export interface AccessConfig {
  teamDomain: string;
  aud: string;
  emails: string[];
}

export interface AccessIdentity {
  email: string;
}

export interface AccessJwk extends JsonWebKey {
  kid: string;
}

export type KeyFetcher = (certsUrl: string) => Promise<AccessJwk[]>;

interface KeyCache {
  keys: Map<string, CryptoKey>;
  fetchedAt: number;
  attemptedAt: number;
}

const caches = new Map<string, KeyCache>();
const inflight = new Map<string, Promise<void>>();
let fetchKeys: KeyFetcher = defaultFetchKeys;
let timing = { ttlMs: KEY_TTL_MS, refetchIntervalMs: REFETCH_INTERVAL_MS };

export const accessTesting = {
  useFetcher(fetcher: KeyFetcher | null, options: Partial<typeof timing> = {}) {
    fetchKeys = fetcher ?? defaultFetchKeys;
    timing = { ttlMs: KEY_TTL_MS, refetchIntervalMs: REFETCH_INTERVAL_MS, ...options };
    caches.clear();
    inflight.clear();
  },
};

export function accessConfig(env: Env): AccessConfig | null {
  const teamDomain = (env.ACCESS_TEAM_DOMAIN ?? "").trim().replace(/\/+$/, "");
  const aud = (env.ACCESS_AUD ?? "").trim();
  const emails = (env.ADMIN_EMAILS ?? "")
    .split(",")
    .map((e) => e.trim().toLowerCase())
    .filter(Boolean);
  if (!teamDomain || !aud || !emails.length) return null;
  return { teamDomain, aud, emails };
}

async function defaultFetchKeys(certsUrl: string): Promise<AccessJwk[]> {
  const response = await fetch(certsUrl, { signal: AbortSignal.timeout(FETCH_TIMEOUT_MS), headers: { Accept: "application/json" } });
  if (!response.ok) throw new Error(`certs answered ${response.status}`);
  const body = (await response.json()) as { keys?: AccessJwk[] };
  return Array.isArray(body.keys) ? body.keys : [];
}

async function importKeys(jwks: AccessJwk[]): Promise<Map<string, CryptoKey>> {
  const keys = new Map<string, CryptoKey>();
  for (const jwk of jwks) {
    if (jwk.kty !== "RSA" || typeof jwk.kid !== "string" || (jwk.alg && jwk.alg !== "RS256")) continue;
    try {
      const { kid, n, e, kty } = jwk;
      keys.set(kid, await crypto.subtle.importKey("jwk", { kty, n, e, alg: "RS256", ext: true }, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]));
    } catch {
      continue;
    }
  }
  return keys;
}

function refresh(teamDomain: string, now: number): Promise<void> {
  const pending = inflight.get(teamDomain);
  if (pending) return pending;
  const previous = caches.get(teamDomain);
  const attemptedAt = now;
  const run = (async () => {
    try {
      const keys = await importKeys(await fetchKeys(`${teamDomain}/cdn-cgi/access/certs`));
      if (keys.size === 0) throw new Error("certs listed no usable keys");
      caches.set(teamDomain, { keys, fetchedAt: now, attemptedAt });
    } catch (error) {
      console.warn({ event: "access-certs-failed", error: String(error) });
      if (previous) caches.set(teamDomain, { ...previous, attemptedAt });
      else caches.set(teamDomain, { keys: new Map(), fetchedAt: 0, attemptedAt });
    }
  })().finally(() => inflight.delete(teamDomain));
  inflight.set(teamDomain, run);
  return run;
}

async function signingKey(teamDomain: string, kid: string, now: number): Promise<CryptoKey | null> {
  let cache = caches.get(teamDomain);
  if (!cache || now - cache.fetchedAt > timing.ttlMs) {
    if (!cache || now - cache.attemptedAt >= timing.refetchIntervalMs) await refresh(teamDomain, now);
    cache = caches.get(teamDomain);
  }
  const known = cache?.keys.get(kid);
  if (known) return known;
  if (cache && now - cache.attemptedAt >= timing.refetchIntervalMs) {
    await refresh(teamDomain, now);
    return caches.get(teamDomain)?.keys.get(kid) ?? null;
  }
  return null;
}

function decodeJson(part: string): Record<string, unknown> | null {
  try {
    const value: unknown = JSON.parse(new TextDecoder().decode(fromBase64url(part)));
    return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

export function accessToken(request: Request): string | null {
  return request.headers.get(ACCESS_JWT_HEADER)?.trim() || cookie(request, ACCESS_COOKIE) || null;
}

export async function verifyAccessJwt(token: string, config: AccessConfig, now = Date.now()): Promise<AccessIdentity | null> {
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  const header = decodeJson(parts[0]);
  const claims = decodeJson(parts[1]);
  if (!header || !claims || header.alg !== "RS256" || typeof header.kid !== "string") return null;

  const key = await signingKey(config.teamDomain, header.kid, now);
  if (!key) return null;
  try {
    const valid = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, fromBase64url(parts[2]), new TextEncoder().encode(`${parts[0]}.${parts[1]}`));
    if (!valid) return null;
  } catch {
    return null;
  }

  const seconds = Math.floor(now / 1000);
  const audience = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (!audience.includes(config.aud)) return null;
  if (typeof claims.iss !== "string" || claims.iss.replace(/\/+$/, "") !== config.teamDomain) return null;
  if (typeof claims.exp !== "number" || claims.exp + CLOCK_SKEW_SECONDS <= seconds) return null;
  if (claims.nbf !== undefined && (typeof claims.nbf !== "number" || claims.nbf - CLOCK_SKEW_SECONDS > seconds)) return null;
  if (typeof claims.email !== "string") return null;
  const email = claims.email.trim().toLowerCase();
  if (!config.emails.includes(email)) return null;
  return { email };
}

export async function requireAccess(request: Request, env: Env, now = Date.now()): Promise<AccessIdentity> {
  const config = accessConfig(env);
  if (!config) throw new HttpError(403, "forbidden", "Admin access isn't configured", {}, false);
  const token = accessToken(request);
  const identity = token ? await verifyAccessJwt(token, config, now) : null;
  if (!identity) throw new HttpError(403, "forbidden", "Sign in with an authorized admin account to use the admin tools", {}, false);
  return identity;
}
