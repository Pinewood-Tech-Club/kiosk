import { dashboardBody, dashboardScript, loginBody, pickerBody, shell } from "./dashboard-page";
import { cookie, html, HttpError, randomToken, type Route } from "./http";
import { checkStaffSecret, clearedSessionCookie, createStaffSession, readStaffSession, sessionCookie, STAFF_COOKIE } from "./session";
import { staffRole } from "./staff-roles";

const RENEW_BELOW_MS = 48 * 60 * 60_000;

function csp(nonce: string, url: URL): Record<string, string> {
  const socket = `${url.protocol === "http:" ? "ws" : "wss"}://${url.host}`;
  return {
    "Referrer-Policy": "same-origin",
    "Content-Security-Policy": `default-src 'none'; script-src 'nonce-${nonce}'; style-src 'nonce-${nonce}'; style-src-attr 'unsafe-inline'; font-src data:; connect-src 'self' ${socket}; media-src blob:; form-action 'self'; base-uri 'none'; frame-ancestors 'none'`,
  };
}

function page(url: URL, title: string, body: string, status = 200, script = ""): Response {
  const nonce = randomToken(12);
  return html(shell(title, body, nonce, script), status, csp(nonce, url));
}

function loginPage(url: URL, message: string | null, status = 200, next = "/staff"): Response {
  return page(url, "Booth staff sign-in", loginBody(message, next), status);
}

function safeNext(raw: unknown): string {
  return typeof raw === "string" && /^\/staff(\/[a-z0-9-]{1,40})?$/.test(raw) ? raw : "/staff";
}

function redirect(location: string, headers: Record<string, string> = {}): Response {
  return new Response(null, { status: 303, headers: { Location: location, "Cache-Control": "no-store", ...headers } });
}

export async function staffSessionFromCookie(request: Request, env: Env) {
  const token = cookie(request, STAFF_COOKIE);
  return token ? readStaffSession(token, env) : null;
}

function sameOrigin(request: Request): boolean {
  return request.headers.get("Origin") === new URL(request.url).origin;
}

export const routes: Route[] = [
  {
    method: "GET",
    path: "/dashboard",
    async handle() {
      return redirect("/staff");
    },
  },
  {
    method: "GET",
    path: "/staff",
    async handle({ request, env, url }) {
      if (!(await staffSessionFromCookie(request, env))) return loginPage(url, null);
      return page(url, "Booth staff", pickerBody());
    },
  },
  {
    method: "GET",
    path: /^\/staff\/([A-Za-z0-9_-]{1,40})$/,
    async handle({ request, env, url, params }) {
      const role = staffRole(params[0]);
      const signedIn = await staffSessionFromCookie(request, env);
      if (!role) return signedIn ? page(url, "Booth staff", pickerBody(`There is no "${params[0]}" page.`), 404) : loginPage(url, null, 404);
      if (!signedIn) return loginPage(url, null, 200, url.pathname);
      return page(url, role.title, dashboardBody(params[0], role), 200, dashboardScript());
    },
  },
  {
    method: "POST",
    path: "/dashboard/login",
    async handle({ request, env, url }) {
      if (!sameOrigin(request)) return loginPage(url, "Sign in from the staff page.", 403);
      const form = await request.formData().catch(() => null);
      const pin = form?.get("pin");
      const next = safeNext(form?.get("next"));
      if (typeof pin !== "string" || pin.length === 0 || pin.length > 256) return loginPage(url, "Enter the staff PIN.", 400, next);
      try {
        await checkStaffSecret(request, env, pin);
      } catch (error) {
        if (error instanceof HttpError) return loginPage(url, error.status === 429 ? "Too many attempts. Wait a minute." : "Wrong PIN.", error.status, next);
        throw error;
      }
      const session = await createStaffSession(env);
      return redirect(next, { "Set-Cookie": sessionCookie(session.token, session.expiresAt) });
    },
  },
  {
    method: "POST",
    path: "/dashboard/renew",
    async handle({ request, env }) {
      if (!sameOrigin(request)) return new Response(null, { status: 403 });
      const current = await staffSessionFromCookie(request, env);
      if (!current) return new Response(null, { status: 401, headers: { "Cache-Control": "no-store" } });
      if (current.exp - Date.now() > RENEW_BELOW_MS) return new Response(null, { status: 204, headers: { "Cache-Control": "no-store" } });
      const session = await createStaffSession(env);
      return new Response(null, { status: 204, headers: { "Cache-Control": "no-store", "Set-Cookie": sessionCookie(session.token, session.expiresAt) } });
    },
  },
  {
    method: "POST",
    path: "/dashboard/logout",
    async handle({ request, url }) {
      if (!sameOrigin(request)) return loginPage(url, null, 403);
      return redirect("/staff", { "Set-Cookie": clearedSessionCookie() });
    },
  },
];
