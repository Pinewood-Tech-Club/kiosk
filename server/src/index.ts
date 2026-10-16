import * as admin from "./admin";
import * as checkout from "./checkout";
import * as dashboard from "./dashboard";
import * as giftcardBalance from "./giftcard-balance";
import * as giftcards from "./giftcards";
import { authenticate, callHub, errorResponse, hub, HttpError, json, match, readBody, type Route } from "./http";
import * as logs from "./logs";
import * as oauth from "./oauth";
import * as orders from "./orders";
import * as receipts from "./receipts";
import { ActionsBody, EventsBody, PROTOCOL_VERSION } from "./schema";
import * as session from "./session";
import * as stats from "./stats";

export { Booth } from "./booth";

const SERVICE = "techclub-icecream";

export const FEATURES = ["square-oauth", "square-credentials", "checkout", "receipt-tokens", "order-feed", "stats", "staff-session", "kiosk-registry", "supplies", "gift-cards", "assist", "admin", "reset-epoch"];

const core: Route[] = [
  {
    method: "GET",
    path: "/v1/health",
    async handle({ request, env, url }) {
      const features = (await oauth.giftCardsUsable(env)) ? FEATURES : FEATURES.filter((f) => f !== "gift-cards");
      const base = { ok: true, service: SERVICE, protocol: PROTOCOL_VERSION, features, time: Date.now() };
      if (url.searchParams.get("deep") !== "1") return json(base);
      await authenticate(request, env, ["kiosk", "staff"]);
      const [d1, booth] = await Promise.allSettled([env.DB.prepare("SELECT 1 AS one").first(), hub(env).check()]);
      const checks = { d1: d1.status === "fulfilled", hub: booth.status === "fulfilled" };
      const ok = checks.d1 && checks.hub;
      return json({ ...base, ok, checks }, ok ? 200 : 503);
    },
  },
  {
    method: "GET",
    path: "/v1/ws",
    async handle({ request, env }) {
      if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
        throw new HttpError(426, "upgrade_required", "Open this route as a websocket");
      }
      const client = await authenticate(request, env, ["kiosk", "staff"]);
      const headers = new Headers({ Upgrade: "websocket", "X-Booth-Role": client.role, "X-Booth-Device": client.device });
      return callHub("connect", () => hub(env).fetch("https://booth/ws", { headers }));
    },
  },
  {
    method: "GET",
    path: "/v1/state",
    async handle({ request, env }) {
      const client = await authenticate(request, env, ["kiosk", "staff"]);
      return json(await callHub("state", () => hub(env).getState(client.role)));
    },
  },
  {
    method: "POST",
    path: "/v1/events",
    async handle({ request, env }) {
      const client = await authenticate(request, env, ["kiosk"]);
      const body = await readBody(request, EventsBody, 256 * 1024);
      return json(await callHub("events", () => hub(env).ingestEvents(client.device, body.events)));
    },
  },
  {
    method: "POST",
    path: "/v1/actions",
    async handle({ request, env }) {
      const client = await authenticate(request, env, ["staff"]);
      const body = await readBody(request, ActionsBody, 64 * 1024);
      return json(await callHub("actions", () => hub(env).applyActions(client.device, body.actions)));
    },
  },
];

export const routes: Route[] = [
  ...core,
  ...logs.routes,
  ...orders.routes,
  ...session.routes,
  ...oauth.routes,
  ...checkout.routes,
  ...giftcards.routes,
  ...stats.routes,
  ...receipts.routes,
  ...admin.routes,
  ...dashboard.routes,
  ...giftcardBalance.routes,
];

async function route(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const url = new URL(request.url);
  const found = match(routes, request.method, url.pathname);
  if (!found) throw new HttpError(404, "not_found", `No route for ${request.method} ${url.pathname}`);
  return found.route.handle({ request, env, ctx, url, params: found.params });
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

  async scheduled(controller, env, ctx): Promise<void> {
    if (controller.cron === giftcards.SWEEP_CRON) {
      await giftcards.sweepStaleHolds(env);
      return;
    }
    ctx.waitUntil(
      oauth.refreshToken(env).then(
        (outcome) => console.log({ event: "square-refresh-check", ...outcome }),
        (error) => console.error({ event: "square-refresh-check-failed", error: String(error) }),
      ),
    );
    await logs.pruneLogs(env);
  },
} satisfies ExportedHandler<Env>;
