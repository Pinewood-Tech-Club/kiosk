import { cookie, escapeHtml, html, HttpError, type Route } from "./http";
import { checkStaffSecret, clearedSessionCookie, createStaffSession, readStaffSession, sessionCookie, STAFF_COOKIE } from "./session";

function page(title: string, body: string): string {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex"><title>${escapeHtml(title)}</title>
<style>body{font:17px/1.5 system-ui,sans-serif;background:#000;color:#f5f5f5;margin:0;padding:3rem}input,button{font:inherit;padding:.5rem .8rem}</style>
</head><body><main><h1>${escapeHtml(title)}</h1>${body}</main></body></html>`;
}

function loginPage(message: string | null, status = 200): Response {
  const error = message ? `<p role="alert">${escapeHtml(message)}</p>` : "";
  return html(
    page(
      "Booth dashboard",
      `${error}<form method="post" action="/dashboard/login"><label>Staff PIN <input name="pin" type="password" autocomplete="current-password" required autofocus></label> <button>Sign in</button></form>`,
    ),
    status,
  );
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
      return html(
        page("Booth dashboard", `<p>Coming soon.</p><form method="post" action="/dashboard/logout"><button>Sign out</button></form>`),
      );
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
