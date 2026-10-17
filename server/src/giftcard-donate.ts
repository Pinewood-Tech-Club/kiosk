import { HttpError, json, readBody, withRetry, type Route } from "./http";
import { credentialsFor, lookupCard } from "./giftcards";
import type { SquareCredentials } from "./oauth";
import { GiftCardDonateBody } from "./schema";
import { SquareError, squareRequest } from "./square";

export interface DonationOrg {
  id: string;
  name: string;
}

interface DonationRow {
  idempotency_key: string;
  gan_last4: string;
  variation_id: string;
  amount_cents: number;
  status: "pending" | "completed" | "failed";
  balance_after_cents: number | null;
}

interface CatalogObject {
  id?: string;
  type?: string;
  is_deleted?: boolean;
  present_at_all_locations?: boolean;
  present_at_location_ids?: string[];
  absent_at_location_ids?: string[];
  category_data?: { name?: string };
  item_data?: {
    name?: string;
    is_archived?: boolean;
    reporting_category?: { id?: string };
    categories?: { id?: string }[];
    variations?: (CatalogObject & { item_variation_data?: { pricing_type?: string; sellable?: boolean } })[];
  };
}

interface SquareOrder {
  id?: string;
  version?: number;
  total_money?: { amount?: number };
}

interface SquarePayment {
  id?: string;
  status?: string;
  amount_money?: { amount?: number };
}

const ORGS_KEY = "donation-orgs";
const FEATURED_KEY = "donation-featured";

export interface DonationOrgList {
  environment: string;
  locationId: string;
  orgs: DonationOrg[];
  duplicates: string[];
  skipped: { itemId: string; reason: string }[];
  droppedFeatured: DonationOrg[];
  refreshedAt: number;
  refreshedBy: string;
}

function presentAt(object: CatalogObject, locationId: string): boolean {
  if (object.present_at_all_locations === false) return (object.present_at_location_ids ?? []).includes(locationId);
  return !(object.absent_at_location_ids ?? []).includes(locationId);
}

export function buildDonationOrgs(objects: CatalogObject[], locationId: string): Pick<DonationOrgList, "orgs" | "duplicates" | "skipped"> {
  const categories = new Map<string, string>();
  for (const o of objects) if (o.type === "CATEGORY" && o.id && o.category_data?.name?.trim()) categories.set(o.id, o.category_data.name.trim());
  const byId = new Map<string, DonationOrg>();
  const skipped: { itemId: string; reason: string }[] = [];
  for (const o of objects) {
    const item = o.item_data;
    if (o.type !== "ITEM" || !item || item.name?.trim() !== "Donation" || item.is_archived || o.is_deleted) continue;
    const itemId = o.id ?? "";
    if (!presentAt(o, locationId)) {
      skipped.push({ itemId, reason: "Not sold at this location" });
      continue;
    }
    const variation = (item.variations ?? []).find(
      (v) => v.id && !v.is_deleted && v.item_variation_data?.pricing_type === "VARIABLE_PRICING" && v.item_variation_data.sellable !== false && presentAt(v, locationId),
    );
    if (!variation?.id) {
      skipped.push({ itemId, reason: "No variable-price variation" });
      continue;
    }
    const categoryId = item.reporting_category?.id ?? item.categories?.[0]?.id;
    const name = categoryId ? categories.get(categoryId) : undefined;
    if (!name) {
      skipped.push({ itemId, reason: "No reporting category" });
      continue;
    }
    byId.set(variation.id, { id: variation.id, name });
  }
  const orgs = [...byId.values()].sort((a, b) => a.name.localeCompare(b.name, "en", { sensitivity: "base" }) || a.id.localeCompare(b.id));
  const counts = new Map<string, number>();
  for (const org of orgs) counts.set(org.name.toLowerCase(), (counts.get(org.name.toLowerCase()) ?? 0) + 1);
  const duplicates = [...new Set(orgs.filter((o) => counts.get(o.name.toLowerCase())! > 1).map((o) => o.name))];
  return { orgs, duplicates, skipped };
}

async function listCatalog(credentials: SquareCredentials): Promise<CatalogObject[]> {
  const objects: CatalogObject[] = [];
  let cursor: string | undefined;
  do {
    const query = new URLSearchParams({ types: "ITEM,CATEGORY" });
    if (cursor) query.set("cursor", cursor);
    const body: { objects?: CatalogObject[]; cursor?: string } = await squareRequest(credentials.environment, `/v2/catalog/list?${query}`, {
      bearer: credentials.accessToken,
      timeoutMs: 15_000,
    });
    objects.push(...(body.objects ?? []));
    cursor = body.cursor || undefined;
  } while (cursor);
  return objects;
}

export async function refreshDonationOrgs(env: Env, by: string, now = Date.now()): Promise<DonationOrgList> {
  const credentials = await credentialsFor(env);
  let objects: CatalogObject[];
  try {
    objects = await listCatalog(credentials);
  } catch (error) {
    if (error instanceof SquareError) throw new HttpError(502, "square_rejected", error.message, {}, false);
    throw error;
  }
  const built = buildDonationOrgs(objects, credentials.locationId);
  const [previous, featured] = await Promise.all([storedDonationOrgs(env), storedFeatured(env)]);
  const kept = new Set(built.orgs.map((o) => o.id));
  const names = new Map((previous?.orgs ?? []).map((o) => [o.id, o.name]));
  const list: DonationOrgList = {
    environment: credentials.environment,
    locationId: credentials.locationId,
    ...built,
    droppedFeatured: featured.filter((id) => !kept.has(id)).map((id) => ({ id, name: names.get(id) ?? id })),
    refreshedAt: now,
    refreshedBy: by,
  };
  await withRetry("D1", () =>
    env.DB.batch([
      env.DB.prepare("INSERT OR REPLACE INTO square_cache (key, value, fetched_at) VALUES (?, ?, ?)").bind(ORGS_KEY, JSON.stringify(list), now),
      env.DB.prepare("INSERT OR REPLACE INTO square_cache (key, value, fetched_at) VALUES (?, ?, ?)").bind(FEATURED_KEY, JSON.stringify(featured.filter((id) => kept.has(id))), now),
    ]),
  );
  console.log({ event: "donation-orgs-refreshed", by, orgs: list.orgs.length, duplicates: list.duplicates.length, skipped: list.skipped.length });
  return list;
}

async function cached<T>(env: Env, key: string): Promise<T | null> {
  const row = await withRetry("D1", () => env.DB.prepare("SELECT value FROM square_cache WHERE key = ?").bind(key).first<{ value: string }>());
  if (!row) return null;
  try {
    return JSON.parse(row.value) as T;
  } catch {
    return null;
  }
}

export async function storedFeatured(env: Env): Promise<string[]> {
  const ids = await cached<unknown>(env, FEATURED_KEY);
  return Array.isArray(ids) ? ids.filter((id): id is string => typeof id === "string") : [];
}

export async function setFeatured(env: Env, ids: string[], now = Date.now()): Promise<string[]> {
  const list = await storedDonationOrgs(env);
  const known = new Set((list?.orgs ?? []).map((o) => o.id));
  const unknown = ids.filter((id) => !known.has(id));
  if (unknown.length) throw new HttpError(400, "unknown_organization", `Not in the stored list: ${unknown.join(", ")}`);
  const featured = [...new Set(ids)];
  await withRetry("D1", () =>
    env.DB.prepare("INSERT OR REPLACE INTO square_cache (key, value, fetched_at) VALUES (?, ?, ?)").bind(FEATURED_KEY, JSON.stringify(featured), now).run(),
  );
  return featured;
}

export async function donationCatalog(env: Env): Promise<{ orgs: DonationOrg[]; featured: string[] }> {
  const [list, featured] = await Promise.all([storedDonationOrgs(env), storedFeatured(env)]);
  const orgs = list?.orgs ?? [];
  const known = new Set(orgs.map((o) => o.id));
  return { orgs, featured: featured.filter((id) => known.has(id)) };
}

export async function storedDonationOrgs(env: Env): Promise<DonationOrgList | null> {
  const list = await cached<DonationOrgList>(env, ORGS_KEY);
  return list ? { ...list, droppedFeatured: list.droppedFeatured ?? [] } : null;
}

function refuseCrossOrigin(request: Request): void {
  const origin = request.headers.get("Origin");
  if (origin && origin !== new URL(request.url).origin) throw new HttpError(403, "forbidden", "Cross-origin request refused");
}

function unavailable(event: string, context: Record<string, unknown>, error: unknown): never {
  if (error instanceof SquareError) {
    console.error({ event, ...context, status: error.status, codes: error.codes, error: error.message });
    throw new HttpError(503, "unavailable", "Square is unavailable, retry later");
  }
  throw error;
}

async function orgs(env: Env): Promise<Response> {
  return json(await donationCatalog(env));
}

async function setRow(env: Env, key: string, fields: Partial<Record<"status" | "order_id" | "payment_id" | "balance_after_cents", string | number>>, now: number): Promise<void> {
  const names = Object.keys(fields);
  await withRetry("D1", () =>
    env.DB.prepare(`UPDATE giftcard_donations SET ${names.map((n) => `${n} = ?`).join(", ")}, updated_at = ? WHERE idempotency_key = ?`)
      .bind(...names.map((n) => fields[n as keyof typeof fields]!), now, key)
      .run(),
  );
}

async function cancelOrder(credentials: SquareCredentials, order: SquareOrder, key: string): Promise<void> {
  if (!order.id || order.version === undefined) return;
  try {
    await squareRequest(credentials.environment, `/v2/orders/${encodeURIComponent(order.id)}`, {
      method: "PUT",
      bearer: credentials.accessToken,
      body: { idempotency_key: `gd-cancel-${key}`, order: { location_id: credentials.locationId, version: order.version, state: "CANCELED" } },
    });
  } catch (error) {
    console.warn({ event: "donation-order-cancel-failed", orderId: order.id, error: String(error) });
  }
}

async function createPayment(credentials: SquareCredentials, key: string, cardId: string, order: SquareOrder, cents: number): Promise<SquarePayment | undefined> {
  const request = () =>
    squareRequest<{ payment?: SquarePayment }>(credentials.environment, "/v2/payments", {
      bearer: credentials.accessToken,
      body: {
        idempotency_key: `gd-${key}`,
        source_id: cardId,
        amount_money: { amount: cents, currency: "USD" },
        order_id: order.id,
        location_id: credentials.locationId,
        autocomplete: true,
        reference_id: "giftcard-donation",
      },
    });
  try {
    return (await request()).payment;
  } catch (error) {
    if (!(error instanceof SquareError) || !error.isTransient) throw error;
    await new Promise((resolve) => setTimeout(resolve, 400));
    return (await request()).payment;
  }
}

async function donate(request: Request, env: Env, now = Date.now()): Promise<Response> {
  refuseCrossOrigin(request);
  const body = await readBody(request, GiftCardDonateBody, 1024);
  const key = body.idempotencyKey;

  const existing = await withRetry("D1", () =>
    env.DB.prepare("SELECT idempotency_key, gan_last4, variation_id, amount_cents, status, balance_after_cents FROM giftcard_donations WHERE idempotency_key = ?")
      .bind(key)
      .first<DonationRow>(),
  );
  const last4 = body.gan.replace(/\D/g, "").slice(-4);
  if (existing && (existing.variation_id !== body.variationId || existing.amount_cents !== body.amountCents || existing.gan_last4 !== last4)) {
    throw new HttpError(409, "conflict", "This idempotency key was used for a different donation");
  }
  if (existing?.status === "completed") return json({ ok: true, balanceCents: existing.balance_after_cents ?? 0 });
  if (existing?.status === "failed") throw new HttpError(409, "donation_failed", "This donation already failed, start a new one", {}, false);

  const credentials = await credentialsFor(env);
  const list = await storedDonationOrgs(env);
  const usable = list && list.environment === credentials.environment && list.locationId === credentials.locationId;
  const org = usable ? list.orgs.find((o) => o.id === body.variationId) : undefined;
  if (!org) throw new HttpError(400, "unknown_organization", "That organization isn't taking donations here");

  const card = await lookupCard(env, credentials, "giftcard-web", body.gan, now, false);
  if (card.state !== "ACTIVE") throw new HttpError(409, "giftcard_inactive", "This gift card is not active");
  const replay = existing?.status === "pending";
  if (!replay && body.amountCents > card.balanceCents) throw new HttpError(409, "insufficient_balance", "The gift card balance is lower than that amount");

  if (!existing) {
    await withRetry("D1", () =>
      env.DB.prepare(
        `INSERT OR IGNORE INTO giftcard_donations (idempotency_key, gan_last4, variation_id, org_name, amount_cents, status, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, 'pending', ?, ?)`,
      )
        .bind(key, card.last4, org.id, org.name, body.amountCents, now, now)
        .run(),
    );
  }
  const context = { last4: card.last4, org: org.name, amountCents: body.amountCents };
  const failed = async (order: SquareOrder | null, code: string, message: string, status = 502): Promise<never> => {
    if (order) await cancelOrder(credentials, order, key);
    await setRow(env, key, { status: "failed" }, now);
    throw new HttpError(status, code, message, {}, false);
  };

  let order: SquareOrder | undefined;
  try {
    order = (
      await squareRequest<{ order?: SquareOrder }>(credentials.environment, "/v2/orders", {
        bearer: credentials.accessToken,
        body: {
          idempotency_key: `gd-${key}`,
          order: {
            location_id: credentials.locationId,
            reference_id: "giftcard-donation",
            source: { name: "Gift card kiosk" },
            line_items: [{ catalog_object_id: org.id, quantity: "1", base_price_money: { amount: body.amountCents, currency: "USD" } }],
          },
        },
      })
    ).order;
  } catch (error) {
    if (error instanceof SquareError && !error.isTransient) {
      console.error({ event: "donation-order-failed", ...context, status: error.status, codes: error.codes, error: error.message });
      return failed(null, "donation_failed", "Square refused the donation order");
    }
    return unavailable("donation-order-failed", context, error);
  }
  if (!order?.id) return failed(null, "donation_failed", "Unexpected order response");
  await setRow(env, key, { order_id: order.id }, now);
  if (order.total_money?.amount !== body.amountCents) {
    console.error({ event: "donation-total-mismatch", ...context, orderId: order.id, total: order.total_money?.amount });
    return failed(order, "donation_failed", "The donation order total doesn't match the amount");
  }

  let payment: SquarePayment | undefined;
  try {
    payment = await createPayment(credentials, key, card.id, order, body.amountCents);
  } catch (error) {
    if (error instanceof SquareError && !error.isTransient) {
      console.error({ event: "donation-payment-failed", ...context, orderId: order.id, status: error.status, codes: error.codes, error: error.message });
      const short = error.codes.some((c) => c === "INSUFFICIENT_FUNDS" || c === "GIFT_CARD_AVAILABLE_AMOUNT");
      return failed(order, short ? "insufficient_balance" : "donation_failed", short ? "The gift card balance is lower than that amount" : "Square declined the gift card payment", short ? 409 : 502);
    }
    console.error({ event: "donation-payment-unconfirmed", ...context, orderId: order.id, error: String(error) });
    throw new HttpError(503, "donation_unconfirmed", "Couldn't confirm the donation, retry with the same key");
  }
  if (!payment?.id || payment.status === "FAILED" || payment.status === "CANCELED") {
    console.error({ event: "donation-payment-declined", ...context, orderId: order.id, status: payment?.status });
    return failed(order, "donation_failed", "Square declined the gift card payment");
  }
  const charged = payment.amount_money?.amount ?? body.amountCents;
  await setRow(env, key, { payment_id: payment.id }, now);

  let balanceAfter = card.balanceCents - charged;
  try {
    const after = await lookupCard(env, credentials, "giftcard-web", body.gan, now, false);
    balanceAfter = replay ? after.balanceCents : Math.min(after.balanceCents, balanceAfter);
  } catch {}
  balanceAfter = Math.max(0, balanceAfter);
  await setRow(env, key, { status: "completed", balance_after_cents: balanceAfter }, now);
  console.log({ event: "donation", ...context, orderId: order.id, paymentId: payment.id, balanceAfter });
  return json({ ok: true, balanceCents: balanceAfter });
}

export const routes: Route[] = [
  {
    method: "GET",
    path: "/giftcard/orgs",
    async handle({ env }) {
      return orgs(env);
    },
  },
  {
    method: "POST",
    path: "/giftcard/donate",
    async handle({ request, env }) {
      return donate(request, env);
    },
  },
];
