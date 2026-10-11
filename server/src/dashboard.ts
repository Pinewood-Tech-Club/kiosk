import { dashboardBody, dashboardScript, loginBody, shell } from "./dashboard-page";
import { cookie, html, HttpError, randomToken, type Route } from "./http";
import { checkStaffSecret, clearedSessionCookie, createStaffSession, readStaffSession, sessionCookie, STAFF_COOKIE } from "./session";

function csp(nonce: string): Record<string, string> {
  return {
    "Content-Security-Policy": `default-src 'none'; script-src 'nonce-${nonce}'; style-src 'nonce-${nonce}'; style-src-attr 'unsafe-inline'; connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'`,
  };
}

function loginPage(message: string | null, status = 200): Response {
  const nonce = randomToken(12);
  return html(shell("Booth dashboard", loginBody(message), nonce), status, csp(nonce));
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
    async handle({ request, env }) {
      if (!(await staffSessionFromCookie(request, env))) return loginPage(null);
      const nonce = randomToken(12);
      return html(shell("Booth dashboard", dashboardBody(), nonce, dashboardScript()), 200, csp(nonce));
    },
  },
  {
    method: "POST",
    path: "/dashboard/login",
    async handle({ request, env }) {
      if (!sameOrigin(request)) return loginPage("Sign in from the dashboard page.", 403);
      const form = await request.formData().catch(() => null);
      const pin = form?.get("pin");
      if (typeof pin !== "string" || pin.length === 0 || pin.length > 256) return loginPage("Enter the staff PIN.", 400);
      try {
        await checkStaffSecret(request, env, pin);
      } catch (error) {
        if (error instanceof HttpError) return loginPage(error.status === 429 ? "Too many attempts. Wait a minute." : "Wrong PIN.", error.status);
        throw error;
      }
      const session = await createStaffSession(env);
      return new Response(null, {
        status: 303,
        headers: { Location: "/dashboard", "Set-Cookie": sessionCookie(session.token, session.expiresAt), "Cache-Control": "no-store" },
      });
    },
  },
  {
    method: "POST",
    path: "/dashboard/logout",
    async handle({ request }) {
      if (!sameOrigin(request)) return loginPage(null, 403);
      return new Response(null, { status: 303, headers: { Location: "/dashboard", "Set-Cookie": clearedSessionCookie(), "Cache-Control": "no-store" } });
    },
  },
];
