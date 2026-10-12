import { authenticate, base64url, escapeHtml, fromBase64url, html, HttpError, json, randomToken, withRetry, type Route } from "./http";
import { listLocations, pickLocation, squareBaseUrl, squareEnvironment, squareRequest, type SquareEnvironment } from "./square";

export const OAUTH_SCOPES = [
  "MERCHANT_PROFILE_READ",
  "PAYMENTS_READ",
  "PAYMENTS_WRITE",
  "PAYMENTS_WRITE_IN_PERSON",
  "ORDERS_READ",
  "ORDERS_WRITE",
  "ITEMS_READ",
  "GIFTCARDS_READ",
];
export const STATE_TTL_MS = 10 * 60_000;
/** Square asks for a refresh every 7 days or less; the daily cron refreshes once a token is 6 days old. */
export const REFRESH_AFTER_MS = 6 * 24 * 60 * 60_000;
export const REFRESH_BEFORE_EXPIRY_MS = 21 * 24 * 60 * 60_000;
export const STALE_AFTER_MS = 8 * 24 * 60 * 60_000;
const DAY_MS = 24 * 60 * 60_000;

export interface SquareCredentials {
  accessToken: string;
  locationId: string;
  merchantId: string | null;
  expiresAt: number | null;
  environment: SquareEnvironment;
  applicationId: string | null;
  source: "oauth" | "static";
  refreshedAt: number | null;
}

interface TokenRow {
  environment: string;
  application_id: string;
  merchant_id: string;
  location_id: string | null;
  access_token: string;
  refresh_token: string | null;
  expires_at: number | null;
  scopes: string;
  obtained_at: number;
  refreshed_at: number;
  refresh_attempted_at: number | null;
  refresh_error: string | null;
}

interface StoredToken extends Omit<TokenRow, "access_token" | "refresh_token"> {
  accessToken: string;
  refreshToken: string | null;
}

interface ObtainTokenResponse {
  access_token?: string;
  refresh_token?: string;
  expires_at?: string;
  merchant_id?: string;
}

export function oauthConfigured(env: Env): boolean {
  return !!env.SQUARE_APPLICATION_ID?.trim() && !!env.SQUARE_APPLICATION_SECRET?.trim();
}

function requireOAuth(env: Env): { applicationId: string; secret: string } {
  if (!oauthConfigured(env)) {
    throw new HttpError(503, "not_configured", "Square OAuth isn't configured: set SQUARE_APPLICATION_ID and SQUARE_APPLICATION_SECRET", {}, false);
  }
  return { applicationId: env.SQUARE_APPLICATION_ID!.trim(), secret: env.SQUARE_APPLICATION_SECRET!.trim() };
}

export function callbackUrl(origin: string): string {
  return `${origin}/v1/square/oauth/callback`;
}

async function tokenKey(env: Env): Promise<CryptoKey> {
  const secret = env.SQUARE_APPLICATION_SECRET?.trim();
  if (!secret) throw new Error("SQUARE_APPLICATION_SECRET isn't set");
  const material = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), "HKDF", false, ["deriveKey"]);
  return crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: new TextEncoder().encode("techclub-icecream"), info: new TextEncoder().encode("square-token-v1") },
    material,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
}

export async function sealToken(env: Env, plain: string): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const sealed = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, await tokenKey(env), new TextEncoder().encode(plain));
  return `v1.${base64url(iv)}.${base64url(sealed)}`;
}

export async function openToken(env: Env, sealed: string): Promise<string> {
  const [version, iv, data] = sealed.split(".");
  if (version !== "v1" || !iv || !data) throw new Error("Unknown token format");
  const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: fromBase64url(iv) }, await tokenKey(env), fromBase64url(data));
  return new TextDecoder().decode(plain);
}

async function loadToken(env: Env, environment: SquareEnvironment): Promise<StoredToken | null> {
  const row = await env.DB.prepare("SELECT * FROM square_tokens WHERE environment = ?").bind(environment).first<TokenRow>();
  if (!row) return null;
  try {
    const { access_token, refresh_token, ...rest } = row;
    return { ...rest, accessToken: await openToken(env, access_token), refreshToken: refresh_token ? await openToken(env, refresh_token) : null };
  } catch (error) {
    console.error({ event: "square-token-unreadable", environment, error: String(error) });
    return null;
  }
}

async function saveToken(env: Env, environment: SquareEnvironment, token: Omit<StoredToken, "environment">): Promise<void> {
  await env.DB.prepare(
    `INSERT INTO square_tokens (environment, application_id, merchant_id, location_id, access_token, refresh_token, expires_at, scopes,
       obtained_at, refreshed_at, refresh_attempted_at, refresh_error)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT (environment) DO UPDATE SET application_id = excluded.application_id, merchant_id = excluded.merchant_id,
       location_id = excluded.location_id, access_token = excluded.access_token, refresh_token = excluded.refresh_token,
       expires_at = excluded.expires_at, scopes = excluded.scopes, obtained_at = excluded.obtained_at, refreshed_at = excluded.refreshed_at,
       refresh_attempted_at = excluded.refresh_attempted_at, refresh_error = excluded.refresh_error`,
  )
    .bind(
      environment,
      token.application_id,
      token.merchant_id,
      token.location_id,
      await sealToken(env, token.accessToken),
      token.refreshToken ? await sealToken(env, token.refreshToken) : null,
      token.expires_at,
      token.scopes,
      token.obtained_at,
      token.refreshed_at,
      token.refresh_attempted_at,
      token.refresh_error,
    )
    .run();
}

function parseExpiry(value: string | undefined): number | null {
  if (!value) return null;
  const parsed = Date.parse(value);
  return Number.isNaN(parsed) ? null : parsed;
}

async function staticLocation(env: Env, environment: SquareEnvironment, accessToken: string): Promise<string | null> {
  const configured = env.SQUARE_LOCATION_ID?.trim();
  if (configured) return configured;
  const key = `static-location:${environment}`;
  const cached = await env.DB.prepare("SELECT value FROM square_cache WHERE key = ?").bind(key).first<{ value: string }>();
  if (cached) return cached.value;
  const location = pickLocation(await listLocations(environment, accessToken), undefined);
  if (!location) return null;
  await env.DB.prepare("INSERT OR REPLACE INTO square_cache (key, value, fetched_at) VALUES (?, ?, ?)").bind(key, location.id, Date.now()).run();
  return location.id;
}

/** The OAuth token when one is stored and unexpired, else the static `SQUARE_ACCESS_TOKEN` fallback, else null. */
export async function resolveCredentials(env: Env, now = Date.now()): Promise<SquareCredentials | null> {
  const environment = squareEnvironment(env);
  const stored = await loadToken(env, environment);
  if (stored && stored.location_id && (stored.expires_at === null || stored.expires_at > now + 60_000)) {
    return {
      accessToken: stored.accessToken,
      locationId: stored.location_id,
      merchantId: stored.merchant_id,
      expiresAt: stored.expires_at,
      environment,
      applicationId: stored.application_id,
      source: "oauth",
      refreshedAt: stored.refreshed_at,
    };
  }
  const fallback = env.SQUARE_ACCESS_TOKEN?.trim();
  if (!fallback) return null;
  let locationId: string | null;
  try {
    locationId = await staticLocation(env, environment, fallback);
  } catch (error) {
    console.error({ event: "square-static-location-failed", error: String(error) });
    return null;
  }
  if (!locationId) return null;
  return {
    accessToken: fallback,
    locationId,
    merchantId: null,
    expiresAt: null,
    environment,
    applicationId: env.SQUARE_APPLICATION_ID?.trim() || null,
    source: "static",
    refreshedAt: null,
  };
}

export async function giftCardsUsable(env: Env, now = Date.now()): Promise<boolean> {
  const row = await env.DB.prepare("SELECT scopes, location_id, expires_at FROM square_tokens WHERE environment = ?")
    .bind(squareEnvironment(env))
    .first<{ scopes: string; location_id: string | null; expires_at: number | null }>()
    .catch(() => null);
  if (row?.location_id && (row.expires_at === null || row.expires_at > now + 60_000)) return row.scopes.split(/[\s,]+/).includes("GIFTCARDS_READ");
  return !!env.SQUARE_ACCESS_TOKEN?.trim();
}

export function refreshDue(token: { refreshed_at: number; expires_at: number | null }, now: number): boolean {
  if (now - token.refreshed_at >= REFRESH_AFTER_MS) return true;
  return token.expires_at !== null && token.expires_at - now <= REFRESH_BEFORE_EXPIRY_MS;
}

export async function startAuthorization(env: Env, origin: string, by: string, now = Date.now()) {
  const { applicationId } = requireOAuth(env);
  const environment = squareEnvironment(env);
  const state = randomToken(24);
  const expiresAt = now + STATE_TTL_MS;
  await withRetry("D1", () =>
    env.DB.prepare("INSERT INTO oauth_states (state, environment, created_at, expires_at, created_by) VALUES (?, ?, ?, ?, ?)")
      .bind(state, environment, now, expiresAt, by)
      .run(),
  );
  const params = new URLSearchParams({ client_id: applicationId, scope: OAUTH_SCOPES.join(" "), session: "false", state });
  return { url: `${squareBaseUrl(environment)}/oauth2/authorize?${params}`, environment, expiresAt, redirectUrl: callbackUrl(origin) };
}

type CallbackOutcome = { ok: true; merchantId: string; locationId: string; locationName: string; expiresAt: number | null } | { ok: false; status: number; message: string };

export async function completeAuthorization(env: Env, params: URLSearchParams, now = Date.now()): Promise<CallbackOutcome> {
  const state = params.get("state") ?? "";
  if (!state) return { ok: false, status: 400, message: "The link is missing its state. Start the connection again." };
  const claimed = await env.DB.prepare(
    "UPDATE oauth_states SET used_at = ? WHERE state = ? AND used_at IS NULL AND expires_at > ? RETURNING environment",
  )
    .bind(now, state, now)
    .first<{ environment: string }>();
  if (!claimed) return { ok: false, status: 400, message: "This authorization link expired or was already used. Start the connection again." };

  const environment = squareEnvironment(env);
  if (claimed.environment !== environment) return { ok: false, status: 400, message: "This link was made for a different Square environment." };
  const error = params.get("error");
  if (error) {
    const description = params.get("error_description") ?? error;
    return { ok: false, status: 400, message: `Square didn't authorize the booth (${description}).` };
  }
  const code = params.get("code");
  if (!code) return { ok: false, status: 400, message: "Square didn't send an authorization code." };

  let oauth: { applicationId: string; secret: string };
  try {
    oauth = requireOAuth(env);
  } catch {
    return { ok: false, status: 503, message: "Square OAuth isn't configured on the server." };
  }
  try {
    const token = await squareRequest<ObtainTokenResponse>(environment, "/oauth2/token", {
      body: { client_id: oauth.applicationId, client_secret: oauth.secret, code, grant_type: "authorization_code" },
    });
    if (!token.access_token || !token.merchant_id) return { ok: false, status: 502, message: "Square's token response was incomplete." };
    const location = pickLocation(await listLocations(environment, token.access_token), env.SQUARE_LOCATION_ID);
    if (!location) {
      return { ok: false, status: 400, message: "The Square account has no active location the kiosk can use (check SQUARE_LOCATION_ID)." };
    }
    const expiresAt = parseExpiry(token.expires_at);
    await saveToken(env, environment, {
      application_id: oauth.applicationId,
      merchant_id: token.merchant_id,
      location_id: location.id,
      accessToken: token.access_token,
      refreshToken: token.refresh_token ?? null,
      expires_at: expiresAt,
      scopes: OAUTH_SCOPES.join(" "),
      obtained_at: now,
      refreshed_at: now,
      refresh_attempted_at: null,
      refresh_error: null,
    });
    console.log({ event: "square-connected", environment, merchantId: token.merchant_id, locationId: location.id });
    return { ok: true, merchantId: token.merchant_id, locationId: location.id, locationName: location.businessName ?? location.name, expiresAt };
  } catch (error) {
    console.error({ event: "square-oauth-failed", error: String(error) });
    return { ok: false, status: 502, message: `Square refused the authorization: ${error instanceof Error ? error.message : String(error)}` };
  }
}

export type RefreshOutcome =
  | { status: "refreshed"; expiresAt: number | null }
  | { status: "skipped"; reason: string }
  | { status: "failed"; error: string };

export async function refreshToken(env: Env, options: { force?: boolean; now?: number } = {}): Promise<RefreshOutcome> {
  const now = options.now ?? Date.now();
  if (!oauthConfigured(env)) return { status: "skipped", reason: "OAuth not configured" };
  const environment = squareEnvironment(env);
  const stored = await loadToken(env, environment);
  if (!stored) return { status: "skipped", reason: "No stored token" };
  if (!stored.refreshToken) return { status: "skipped", reason: "Token has no refresh token" };
  if (!options.force && !refreshDue(stored, now)) return { status: "skipped", reason: "Not due" };

  const { applicationId, secret } = requireOAuth(env);
  try {
    const token = await squareRequest<ObtainTokenResponse>(environment, "/oauth2/token", {
      body: { client_id: applicationId, client_secret: secret, grant_type: "refresh_token", refresh_token: stored.refreshToken },
    });
    if (!token.access_token) throw new Error("Square's refresh response had no access token");
    const expiresAt = parseExpiry(token.expires_at);
    const { environment: _, ...rest } = stored;
    await saveToken(env, environment, {
      ...rest,
      accessToken: token.access_token,
      refreshToken: token.refresh_token ?? stored.refreshToken,
      expires_at: expiresAt,
      refreshed_at: now,
      refresh_attempted_at: now,
      refresh_error: null,
    });
    console.log({ event: "square-token-refreshed", environment, expiresAt: expiresAt && new Date(expiresAt).toISOString() });
    return { status: "refreshed", expiresAt };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    await env.DB.prepare("UPDATE square_tokens SET refresh_attempted_at = ?, refresh_error = ? WHERE environment = ?")
      .bind(now, message.slice(0, 500), environment)
      .run();
    console.error({ event: "square-token-refresh-failed", environment, error: message });
    return { status: "failed", error: message };
  }
}

export async function revokeToken(env: Env): Promise<{ revoked: boolean; squareRevoked: boolean; error: string | null }> {
  const environment = squareEnvironment(env);
  const stored = await loadToken(env, environment);
  const exists = await env.DB.prepare("SELECT 1 AS one FROM square_tokens WHERE environment = ?").bind(environment).first();
  if (!exists) return { revoked: false, squareRevoked: false, error: null };
  let squareRevoked = false;
  let error: string | null = null;
  if (stored && oauthConfigured(env)) {
    const { applicationId, secret } = requireOAuth(env);
    try {
      await squareRequest(environment, "/oauth2/revoke", {
        authorization: `Client ${secret}`,
        body: { client_id: applicationId, access_token: stored.accessToken },
      });
      squareRevoked = true;
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
      console.error({ event: "square-revoke-failed", error });
    }
  }
  await env.DB.prepare("DELETE FROM square_tokens WHERE environment = ?").bind(environment).run();
  console.log({ event: "square-disconnected", environment, squareRevoked });
  return { revoked: true, squareRevoked, error };
}

export async function squareStatus(env: Env, origin: string, verify: boolean, now = Date.now()) {
  const environment = squareEnvironment(env);
  const stored = oauthConfigured(env) ? await loadToken(env, environment) : null;
  const row = await env.DB.prepare(
    "SELECT merchant_id, location_id, expires_at, obtained_at, refreshed_at, refresh_attempted_at, refresh_error FROM square_tokens WHERE environment = ?",
  )
    .bind(environment)
    .first<Pick<TokenRow, "merchant_id" | "location_id" | "expires_at" | "obtained_at" | "refreshed_at" | "refresh_attempted_at" | "refresh_error">>();
  const credentials = await resolveCredentials(env, now);
  let verified: { ok: boolean; error: string | null } | null = null;
  if (verify && credentials) {
    try {
      const locations = await listLocations(environment, credentials.accessToken);
      verified = locations.some((l) => l.id === credentials.locationId)
        ? { ok: true, error: null }
        : { ok: false, error: `Location ${credentials.locationId} not found for this token` };
    } catch (error) {
      verified = { ok: false, error: error instanceof Error ? error.message : String(error) };
    }
  }
  return {
    environment,
    applicationId: env.SQUARE_APPLICATION_ID?.trim() || null,
    oauthConfigured: oauthConfigured(env),
    staticTokenConfigured: !!env.SQUARE_ACCESS_TOKEN?.trim(),
    redirectUrl: callbackUrl(origin),
    source: credentials?.source ?? null,
    connected: credentials !== null,
    locationId: credentials?.locationId ?? null,
    oauth: row
      ? {
          merchantId: row.merchant_id,
          locationId: row.location_id,
          readable: stored !== null,
          expiresAt: row.expires_at,
          obtainedAt: row.obtained_at,
          refreshedAt: row.refreshed_at,
          refreshDueAt: Math.min(row.refreshed_at + REFRESH_AFTER_MS, (row.expires_at ?? Infinity) - REFRESH_BEFORE_EXPIRY_MS),
          stale: now - row.refreshed_at > STALE_AFTER_MS,
          lastRefreshAttemptAt: row.refresh_attempted_at,
          lastRefreshError: row.refresh_error,
        }
      : null,
    verified,
  };
}

function page(title: string, message: string, ok: boolean): string {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escapeHtml(title)}</title><style>body{font:17px/1.5 system-ui,sans-serif;background:#000;color:#f5f5f5;display:grid;place-items:center;min-height:100vh;margin:0}
main{max-width:34rem;padding:2rem}h1{font-size:1.6rem;color:${ok ? "#7ee2a8" : "#ff8a80"}}</style></head>
<body><main><h1>${escapeHtml(title)}</h1><p>${escapeHtml(message)}</p></main></body></html>`;
}

export const routes: Route[] = [
  {
    method: "POST",
    path: "/v1/square/oauth/start",
    async handle({ request, env, url }) {
      const client = await authenticate(request, env, ["staff"]);
      return json(await startAuthorization(env, url.origin, client.device));
    },
  },
  {
    method: "GET",
    path: "/v1/square/oauth/start",
    async handle({ request, env, url }) {
      const client = await authenticate(request, env, ["staff"]);
      const started = await startAuthorization(env, url.origin, client.device);
      return new Response(null, { status: 302, headers: { Location: started.url, "Cache-Control": "no-store" } });
    },
  },
  {
    method: "GET",
    path: "/v1/square/oauth/callback",
    async handle({ env, url }) {
      const outcome = await completeAuthorization(env, url.searchParams);
      if (!outcome.ok) return html(page("Square wasn't connected", outcome.message, false), outcome.status);
      const expiry = outcome.expiresAt ? ` The token is good until ${new Date(outcome.expiresAt).toUTCString()} and renews itself weekly.` : "";
      return html(page("Square is connected", `The booth now takes payments for ${outcome.locationName} (location ${outcome.locationId}).${expiry} You can close this page.`, true));
    },
  },
  {
    method: "GET",
    path: "/v1/square/status",
    async handle({ request, env, url }) {
      await authenticate(request, env, ["staff"]);
      return json(await squareStatus(env, url.origin, url.searchParams.get("verify") === "1"));
    },
  },
  {
    method: "POST",
    path: "/v1/square/refresh",
    async handle({ request, env }) {
      await authenticate(request, env, ["staff"]);
      const outcome = await refreshToken(env, { force: true });
      return json(outcome, outcome.status === "failed" ? 502 : 200);
    },
  },
  {
    method: "POST",
    path: "/v1/square/revoke",
    async handle({ request, env }) {
      await authenticate(request, env, ["staff"]);
      return json(await revokeToken(env));
    },
  },
  {
    method: "GET",
    path: "/v1/square/credentials",
    async handle({ request, env, ctx }) {
      await authenticate(request, env, ["kiosk"]);
      const credentials = await resolveCredentials(env);
      if (!credentials) {
        throw new HttpError(503, "not_configured", "No Square credentials: connect Square with OAuth or set SQUARE_ACCESS_TOKEN", {}, false);
      }
      if (credentials.source === "oauth" && credentials.refreshedAt !== null &&
          refreshDue({ refreshed_at: credentials.refreshedAt, expires_at: credentials.expiresAt }, Date.now())) {
        ctx.waitUntil(refreshToken(env).catch((error) => console.error({ event: "square-refresh-background-failed", error: String(error) })));
      }
      const { refreshedAt: _, ...body } = credentials;
      return json({ ...body, fetchAgainAt: Math.min(Date.now() + 30 * 60_000, (credentials.expiresAt ?? Infinity) - DAY_MS) });
    },
  },
];
