import { clientIp, html, HttpError, json, randomToken, readBody, type Route } from "./http";
import { credentialsFor, lookupCard } from "./giftcards";
import { giftCardBody, giftCardScript, giftCardShell } from "./giftcard-page";
import { GiftCardLookupBody } from "./schema";
import { ZXING_LIBRARY_JS } from "./zxing-lib";

function pageHeaders(nonce: string): Record<string, string> {
  return {
    "Content-Security-Policy": `default-src 'none'; script-src 'self' 'nonce-${nonce}'; style-src 'nonce-${nonce}'; style-src-attr 'unsafe-inline'; font-src data:; img-src data:; connect-src 'self'; media-src blob:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`,
    "Permissions-Policy": "camera=(self)",
  };
}

async function balance(request: Request, env: Env): Promise<Response> {
  const origin = request.headers.get("Origin");
  if (origin && origin !== new URL(request.url).origin) throw new HttpError(403, "forbidden", "Cross-origin request refused");
  const ip = clientIp(request);
  const { success } = await env.LOGIN_LIMITER.limit({ key: `giftcard:${ip}` });
  if (!success) throw new HttpError(429, "rate_limited", "Too many checks, wait a minute", { "Retry-After": "60" });
  const body = await readBody(request, GiftCardLookupBody, 1024);
  const card = await lookupCard(env, await credentialsFor(env), `giftcard-web:${ip}`, body.gan);
  return json({ balanceCents: card.balanceCents, state: card.state });
}

export const routes: Route[] = [
  {
    method: "GET",
    path: "/giftcard",
    async handle({ url }) {
      const nonce = randomToken(12);
      return html(giftCardShell(giftCardBody(), nonce, giftCardScript(url.searchParams.get("debug") === "1")), 200, pageHeaders(nonce));
    },
  },
  {
    method: "GET",
    path: "/giftcard/zxing.js",
    async handle() {
      return new Response(ZXING_LIBRARY_JS, {
        headers: { "Content-Type": "text/javascript; charset=utf-8", "Cache-Control": "public, max-age=86400", "X-Content-Type-Options": "nosniff" },
      });
    },
  },
  {
    method: "POST",
    path: "/giftcard/balance",
    async handle({ request, env }) {
      return balance(request, env);
    },
  },
];
