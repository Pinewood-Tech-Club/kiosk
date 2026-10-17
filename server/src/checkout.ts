import { loadCatalog, loadTaxIds } from "./catalog";
import { authenticate, HttpError, json, noteKioskContact, readBody, sha256, withRetry, type Route } from "./http";
import { resolveCredentials } from "./oauth";
import { adHocLineItems, catalogLineItems, donationLineItem, quote, type CartItem, type ReceiptLine } from "./pricing";
import { CheckoutBody } from "./schema";
import { squareRequest, SquareError } from "./square";

export interface CheckoutResponse {
  id: string;
  status: "created" | "duplicate";
  squareOrderId: string;
  locationId: string;
  environment: string;
  referenceId: string;
  totalCents: number;
  taxCents: number;
  subtotalCents: number;
  donationCents: number;
  expectedSubtotalCents: number;
  priceMatches: boolean;
  usedCatalog: boolean;
  catalogError: string | null;
  lines: ReceiptLine[];
  receiptToken: string;
}

interface SquareOrder {
  id?: string;
  total_money?: { amount?: number };
  total_tax_money?: { amount?: number };
  line_items?: {
    name?: string;
    note?: string;
    quantity?: string;
    base_price_money?: { amount?: number };
    total_money?: { amount?: number };
    modifiers?: { name?: string }[];
  }[];
}

function receiptLines(order: SquareOrder): ReceiptLine[] {
  return (order.line_items ?? []).map((item) => ({
    title: item.name ?? "Item",
    detail: item.note ?? (item.modifiers ?? []).map((m) => m.name ?? "").filter(Boolean).join(", "),
    quantity: Number(item.quantity ?? "1") || 1,
    baseCents: item.base_price_money?.amount ?? 0,
    cents: item.total_money?.amount ?? 0,
  }));
}

export function referenceId(orderNumber: number | undefined, orderRef?: string): string {
  if (orderRef) return `kiosk-${orderRef}`;
  return orderNumber === undefined ? "kiosk" : `kiosk-${String(orderNumber).padStart(4, "0")}`;
}

function canonical(body: CheckoutBody): string {
  return JSON.stringify({
    items: body.items.map((i) => ({ vessel: i.vessel, flavors: i.flavors, toppings: i.toppings })),
    customerName: body.customerName,
    orderNumber: body.orderNumber ?? null,
    receiptToken: body.receiptToken,
    ...(body.orderRef ? { orderRef: body.orderRef } : {}),
    ...(body.donationCents ? { donationCents: body.donationCents } : {}),
  });
}

interface StoredCheckout {
  request_hash: string;
  response: string;
}

async function existing(env: Env, id: string): Promise<StoredCheckout | null> {
  return withRetry("D1", () => env.DB.prepare("SELECT request_hash, response FROM checkouts WHERE id = ?").bind(id).first<StoredCheckout>());
}

function replay(stored: StoredCheckout, hash: string): CheckoutResponse {
  if (stored.request_hash !== hash) throw new HttpError(409, "conflict", "This checkout id was already used for a different cart");
  return { ...(JSON.parse(stored.response) as CheckoutResponse), status: "duplicate" };
}

export async function checkout(env: Env, device: string, body: CheckoutBody, now = Date.now()): Promise<CheckoutResponse> {
  const hash = await sha256(canonical(body));
  const previous = await existing(env, body.id);
  if (previous) return replay(previous, hash);

  const credentials = await resolveCredentials(env, now);
  if (!credentials) throw new HttpError(503, "not_configured", "No Square credentials on the server", {}, false);
  if (body.locationId && body.locationId !== credentials.locationId) {
    throw new HttpError(409, "location_mismatch", `The kiosk is authorized for ${body.locationId}, the server for ${credentials.locationId}`);
  }

  const items: CartItem[] = body.items;
  const q = quote(items);
  const donationCents = body.donationCents ?? 0;
  const expectedCents = q.totalCents + donationCents;
  if (body.quotedCents !== undefined && body.quotedCents !== expectedCents) {
    console.warn({ event: "checkout-quote-differs", id: body.id, kiosk: body.quotedCents, server: expectedCents });
  }
  const { catalog, error: catalogError } = await loadCatalog(env, credentials, now);
  const lineItems = catalog ? catalogLineItems(q, catalog) : adHocLineItems(q);
  if (donationCents > 0) lineItems.push(donationLineItem(donationCents, await loadTaxIds(credentials, now)));
  const ref = referenceId(body.orderNumber, body.orderRef);

  let order: SquareOrder;
  try {
    const response = await squareRequest<{ order?: SquareOrder }>(credentials.environment, "/v2/orders", {
      bearer: credentials.accessToken,
      body: {
        idempotency_key: body.id,
        order: {
          location_id: credentials.locationId,
          reference_id: ref,
          ticket_name: body.customerName,
          source: { name: body.sourceName ?? "Kiosk" },
          metadata: { checkout_id: body.id },
          pricing_options: { auto_apply_taxes: true },
          line_items: lineItems,
          fulfillments: [
            {
              type: "PICKUP",
              state: "PROPOSED",
              pickup_details: { recipient: { display_name: body.customerName }, schedule_type: "ASAP", prep_time_duration: "PT5M" },
            },
          ],
        },
      },
    });
    order = response.order ?? {};
  } catch (error) {
    if (error instanceof SquareError) {
      console.error({ event: "checkout-square-failed", id: body.id, status: error.status, codes: error.codes, error: error.message });
      if (error.isTransient) throw new HttpError(503, "unavailable", "Square is unavailable, retry later");
      throw new HttpError(502, error.isAuth ? "square_unauthorized" : "square_rejected", error.message, {}, false);
    }
    throw error;
  }
  if (!order.id || typeof order.total_money?.amount !== "number") {
    throw new HttpError(502, "square_rejected", "Unexpected CreateOrder response", {}, false);
  }

  const totalCents = order.total_money.amount;
  const taxCents = order.total_tax_money?.amount ?? 0;
  const result: CheckoutResponse = {
    id: body.id,
    status: "created",
    squareOrderId: order.id,
    locationId: credentials.locationId,
    environment: credentials.environment,
    referenceId: ref,
    totalCents,
    taxCents,
    subtotalCents: totalCents - taxCents,
    donationCents,
    expectedSubtotalCents: expectedCents,
    priceMatches: totalCents - taxCents === expectedCents,
    usedCatalog: catalog !== null,
    catalogError,
    lines: receiptLines(order),
    receiptToken: body.receiptToken,
  };
  if (!result.priceMatches) {
    console.warn({ event: "checkout-price-mismatch", id: body.id, square: result.subtotalCents, expected: expectedCents });
  }

  const insert = await withRetry("D1", () =>
    env.DB.prepare(
      `INSERT OR IGNORE INTO checkouts (id, device, request_hash, receipt_token, order_number, customer_name, environment, location_id,
         square_order_id, total_cents, tax_cents, expected_cents, used_catalog, items, response, created_at, order_ref)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    )
      .bind(
        body.id, device, hash, body.receiptToken, body.orderNumber ?? null, body.customerName, credentials.environment,
        credentials.locationId, order.id, totalCents, taxCents, expectedCents, catalog ? 1 : 0, JSON.stringify(items),
        JSON.stringify(result), now, body.orderRef ?? null,
      )
      .run(),
  );
  if ((insert.meta.changes ?? 0) === 0) {
    const raced = await existing(env, body.id);
    if (raced) return replay(raced, hash);
    throw new HttpError(409, "conflict", "This receipt token was already used by another checkout");
  }
  console.log({ event: "checkout", id: body.id, squareOrderId: order.id, totalCents, donationCents, usedCatalog: catalog !== null, device });
  return result;
}

export const routes: Route[] = [
  {
    method: "POST",
    path: "/v1/checkout",
    async handle({ request, env, ctx }) {
      const client = await authenticate(request, env, ["kiosk"]);
      const body = await readBody(request, CheckoutBody, 64 * 1024);
      const result = await checkout(env, client.device, body);
      noteKioskContact(env, ctx, client.device);
      return json(result);
    },
  },
];
