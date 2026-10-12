import type { SquareCredentials } from "./oauth";
import { pricingMismatch, scoopCents, TOPPING_CENTS, WAFFLE_CONE_CENTS, type Catalog, type CatalogEntry } from "./pricing";
import { squareRequest } from "./square";

export const CATALOG_FRESH_MS = 10 * 60_000;
export const CATALOG_STALE_MS = 24 * 60 * 60_000;
export const REQUIRED_ITEMS = ["1 Scoop", "2nd Scoop", "3rd+ Scoop", "Waffle Cone", "Topping"];

export type CatalogResult = { catalog: Catalog; error: null } | { catalog: null; error: string };

const memory = new Map<string, { catalog: Catalog; fetchedAt: number }>();

export function buildCatalog(categoryName: string, items: Record<string, unknown>[]): Catalog {
  const byName = new Map<string, CatalogEntry>();
  for (const object of items) {
    const data = object.item_data as Record<string, unknown> | undefined;
    if (!data || typeof data.name !== "string" || data.is_archived === true || !Array.isArray(data.variations)) continue;
    const name = data.name;
    const sellable: CatalogEntry[] = [];
    for (const variation of data.variations as Record<string, unknown>[]) {
      const v = variation.item_variation_data as Record<string, unknown> | undefined;
      const price = (v?.price_money as { amount?: unknown } | undefined)?.amount;
      if (typeof variation.id !== "string" || v?.pricing_type !== "FIXED_PRICING" || v.sellable === false || typeof price !== "number") continue;
      sellable.push({ variationId: variation.id, itemName: name, cents: price });
    }
    if (sellable.length > 1) throw new Error(`Catalog item "${name}" has ${sellable.length} sellable variations; expected exactly one`);
    if (sellable.length === 1) byName.set(name.toLowerCase(), sellable[0]);
  }
  const missing = REQUIRED_ITEMS.filter((n) => !byName.has(n.toLowerCase()));
  if (missing.length > 0) throw new Error(`Category "${categoryName}" is missing item(s): ${missing.join(", ")}`);
  const get = (n: string) => byName.get(n.toLowerCase())!;
  return {
    categoryName,
    firstScoop: get("1 Scoop"),
    secondScoop: get("2nd Scoop"),
    additionalScoop: get("3rd+ Scoop"),
    waffleCone: get("Waffle Cone"),
    topping: get("Topping"),
  };
}

async function fetchCategoryItems(credentials: SquareCredentials, categoryName: string): Promise<Record<string, unknown>[]> {
  const { environment, accessToken } = credentials;
  const categories: Record<string, unknown>[] = [];
  let cursor: string | undefined;
  do {
    const body: { objects?: Record<string, unknown>[]; cursor?: string } = await squareRequest(environment, "/v2/catalog/search", {
      bearer: accessToken,
      body: { object_types: ["CATEGORY"], ...(cursor ? { cursor } : {}) },
    });
    categories.push(...(body.objects ?? []));
    cursor = body.cursor || undefined;
  } while (cursor);
  const wanted = categoryName.trim().toLowerCase();
  const category = categories.find((c) => ((c.category_data as { name?: string } | undefined)?.name ?? "").trim().toLowerCase() === wanted);
  if (!category || typeof category.id !== "string") throw new Error(`Catalog category "${categoryName}" not found`);

  const items: Record<string, unknown>[] = [];
  cursor = undefined;
  do {
    const body: { items?: Record<string, unknown>[]; cursor?: string } = await squareRequest(environment, "/v2/catalog/search-catalog-items", {
      bearer: accessToken,
      body: { category_ids: [category.id], limit: 100, ...(cursor ? { cursor } : {}) },
    });
    items.push(...(body.items ?? []));
    cursor = body.cursor || undefined;
  } while (cursor);
  return items;
}

export async function fetchCatalog(credentials: SquareCredentials, categoryName: string): Promise<Catalog> {
  return buildCatalog(categoryName, await fetchCategoryItems(credentials, categoryName));
}

export const EXPECTED_PRICES: Record<string, number> = {
  "1 Scoop": scoopCents(1),
  "2nd Scoop": scoopCents(2),
  "3rd+ Scoop": scoopCents(3),
  "Waffle Cone": WAFFLE_CONE_CENTS,
  Topping: TOPPING_CENTS,
};

export interface CatalogItemCheck {
  name: string;
  expectedCents: number;
  foundCents: number | null;
  ok: boolean;
  problem: string | null;
}

export interface CatalogReport {
  categoryName: string;
  ok: boolean;
  error: string | null;
  items: CatalogItemCheck[];
  extras: string[];
}

export function checkCatalogItems(categoryName: string, items: Record<string, unknown>[]): CatalogReport {
  const byName = new Map<string, { name: string; prices: (number | null)[] }>();
  for (const object of items) {
    const data = object.item_data as Record<string, unknown> | undefined;
    if (!data || typeof data.name !== "string" || data.is_archived === true) continue;
    const variations = Array.isArray(data.variations) ? (data.variations as Record<string, unknown>[]) : [];
    const prices = variations
      .map((v) => v.item_variation_data as Record<string, unknown> | undefined)
      .filter((v) => v?.sellable !== false)
      .map((v) => {
        const amount = (v?.price_money as { amount?: unknown } | undefined)?.amount;
        return v?.pricing_type === "FIXED_PRICING" && typeof amount === "number" ? amount : null;
      });
    byName.set(data.name.toLowerCase(), { name: data.name, prices });
  }
  const checks = REQUIRED_ITEMS.map((name): CatalogItemCheck => {
    const expectedCents = EXPECTED_PRICES[name];
    const found = byName.get(name.toLowerCase());
    if (!found) return { name, expectedCents, foundCents: null, ok: false, problem: "Missing from the category" };
    if (found.prices.length !== 1) {
      return { name, expectedCents, foundCents: found.prices[0] ?? null, ok: false, problem: `Has ${found.prices.length} sellable variations, needs exactly one` };
    }
    const cents = found.prices[0];
    if (cents === null) return { name, expectedCents, foundCents: null, ok: false, problem: "Variable price, needs a fixed price" };
    if (cents !== expectedCents) return { name, expectedCents, foundCents: cents, ok: false, problem: "Wrong price" };
    return { name, expectedCents, foundCents: cents, ok: true, problem: null };
  });
  const required = new Set(REQUIRED_ITEMS.map((n) => n.toLowerCase()));
  const extras = [...byName.entries()].filter(([key]) => !required.has(key)).map(([, v]) => v.name);
  return { categoryName, ok: checks.every((c) => c.ok), error: null, items: checks, extras };
}

/** Always asks Square, bypassing the cache, so a fix made in the Square dashboard shows up at once. */
export async function catalogReport(env: Env, credentials: SquareCredentials): Promise<CatalogReport> {
  const categoryName = env.SQUARE_CATEGORY_NAME?.trim() ?? "";
  const empty = (error: string): CatalogReport => ({
    categoryName,
    ok: false,
    error,
    items: REQUIRED_ITEMS.map((name) => ({ name, expectedCents: EXPECTED_PRICES[name], foundCents: null, ok: false, problem: null })),
    extras: [],
  });
  if (!categoryName) return empty("SQUARE_CATEGORY_NAME isn't set");
  try {
    return checkCatalogItems(categoryName, await fetchCategoryItems(credentials, categoryName));
  } catch (error) {
    return empty(error instanceof Error ? error.message : String(error));
  }
}

function cacheKey(credentials: SquareCredentials, categoryName: string): string {
  return `catalog:${credentials.environment}:${credentials.merchantId ?? credentials.source}:${categoryName.trim().toLowerCase()}`;
}

async function readStored(env: Env, key: string): Promise<{ catalog: Catalog; fetchedAt: number } | null> {
  try {
    const row = await env.DB.prepare("SELECT value, fetched_at FROM square_cache WHERE key = ?").bind(key).first<{ value: string; fetched_at: number }>();
    return row ? { catalog: JSON.parse(row.value) as Catalog, fetchedAt: row.fetched_at } : null;
  } catch {
    return null;
  }
}

/**
 * Memory, then D1, then Square. A fresh copy is used as is; a stale one (under a day old) is used when Square fails.
 * A catalog whose prices don't match the kiosk's is reported as an error, so orders fall back to ad-hoc lines like the app.
 */
export async function loadCatalog(env: Env, credentials: SquareCredentials, now = Date.now()): Promise<CatalogResult> {
  const categoryName = env.SQUARE_CATEGORY_NAME?.trim();
  if (!categoryName) return { catalog: null, error: "SQUARE_CATEGORY_NAME isn't set" };
  const key = cacheKey(credentials, categoryName);
  let cached = memory.get(key) ?? null;
  if (!cached || now - cached.fetchedAt > CATALOG_FRESH_MS) {
    const stored = await readStored(env, key);
    if (stored && (!cached || stored.fetchedAt > cached.fetchedAt)) cached = stored;
  }
  if (cached && now - cached.fetchedAt <= CATALOG_FRESH_MS) {
    memory.set(key, cached);
    return checked(cached.catalog);
  }
  try {
    const catalog = await fetchCatalog(credentials, categoryName);
    memory.set(key, { catalog, fetchedAt: now });
    await env.DB.prepare("INSERT OR REPLACE INTO square_cache (key, value, fetched_at) VALUES (?, ?, ?)")
      .bind(key, JSON.stringify(catalog), now)
      .run()
      .catch((error) => console.warn({ event: "catalog-cache-write-failed", error: String(error) }));
    return checked(catalog);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.warn({ event: "catalog-fetch-failed", error: message, stale: cached ? now - cached.fetchedAt : null });
    if (cached && now - cached.fetchedAt <= CATALOG_STALE_MS) return checked(cached.catalog);
    return { catalog: null, error: message };
  }
}

function checked(catalog: Catalog): CatalogResult {
  const mismatch = pricingMismatch(catalog);
  return mismatch ? { catalog: null, error: `Catalog prices don't match kiosk pricing (${mismatch})` } : { catalog, error: null };
}

export function clearCatalogMemory() {
  memory.clear();
}
