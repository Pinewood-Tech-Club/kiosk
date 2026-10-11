import { escapeHtml, html, withRetry, type Route } from "./http";
import { resolveCredentials } from "./oauth";
import { flavorTitle, quote, toppingTitle, vesselTitle, type CartItem } from "./pricing";
import { ReceiptToken } from "./schema";
import { squareRequest } from "./square";

export const EVENT_NAME = "Tech Club Ice Cream";
export const EVENT_TIME_ZONE = "America/Los_Angeles";
const REFRESH_SECONDS = 10;
const NOINDEX = { "X-Robots-Tag": "noindex, nofollow" };

export interface ReceiptItemRecord {
  vessel: string;
  flavors: string[];
  toppings: string[];
}

export interface ReceiptLineRecord {
  title: string;
  detail: string;
  cents: number;
}

export interface ReceiptRecord {
  source: "order" | "checkout";
  id: string;
  orderNumber: number | null;
  customerName: string | null;
  totalCents: number;
  subtotalCents: number | null;
  taxCents: number | null;
  card: string | null;
  simulated: boolean;
  paidAt: number | null;
  squarePaymentId: string | null;
  items: ReceiptItemRecord[];
  lines: ReceiptLineRecord[];
  paid: boolean;
  canceled: boolean;
}

interface Row {
  id: string;
  order_number: number | null;
  customer_name: string | null;
  total_cents: number;
  subtotal_cents?: number | null;
  tax_cents: number | null;
  card?: string | null;
  simulated?: number;
  paid_at?: number;
  square_payment_id?: string | null;
  items: string;
  lines?: string | null;
  response?: string;
  status?: string | null;
}

function parse<T>(text: string | null | undefined, fallback: T): T {
  if (!text) return fallback;
  try {
    return JSON.parse(text) as T;
  } catch {
    return fallback;
  }
}

/** A paid order if the kiosk has uploaded it, else the checkout the token was sent with (created, maybe not yet paid). */
export async function findReceipt(env: Env, token: string): Promise<ReceiptRecord | null> {
  const order = await withRetry("D1", () =>
    env.DB.prepare(
      `SELECT id, order_number, customer_name, total_cents, subtotal_cents, tax_cents, card, simulated, paid_at, square_payment_id, items, lines, status
       FROM orders WHERE receipt_token = ?`,
    )
      .bind(token)
      .first<Row>(),
  );
  if (order) {
    return {
      source: "order",
      id: order.id,
      orderNumber: order.order_number,
      customerName: order.customer_name,
      totalCents: order.total_cents,
      subtotalCents: order.subtotal_cents ?? null,
      taxCents: order.tax_cents,
      card: order.card ?? null,
      simulated: order.simulated === 1,
      paidAt: order.paid_at ?? null,
      squarePaymentId: order.square_payment_id ?? null,
      items: parse(order.items, []),
      lines: parse(order.lines, []),
      paid: true,
      canceled: order.status === "canceled",
    };
  }
  const checkout = await withRetry("D1", () =>
    env.DB.prepare("SELECT id, order_number, customer_name, total_cents, tax_cents, items, response FROM checkouts WHERE receipt_token = ?")
      .bind(token)
      .first<Row>(),
  );
  if (checkout) {
    const response = parse<{ lines?: ReceiptLineRecord[] }>(checkout.response, {});
    return {
      source: "checkout",
      id: checkout.id,
      orderNumber: checkout.order_number,
      customerName: checkout.customer_name,
      totalCents: checkout.total_cents,
      subtotalCents: null,
      taxCents: checkout.tax_cents,
      card: null,
      simulated: false,
      paidAt: null,
      squarePaymentId: null,
      items: parse(checkout.items, []),
      lines: response.lines ?? [],
      paid: false,
      canceled: false,
    };
  }
  return null;
}

export const money = (cents: number) => `${cents < 0 ? "-" : ""}$${(Math.abs(cents) / 100).toFixed(2)}`;

export function formatEventTime(ms: number): string {
  return new Intl.DateTimeFormat("en-US", { timeZone: EVENT_TIME_ZONE, dateStyle: "long", timeStyle: "short" }).format(new Date(ms));
}

/** What Square charged per item (lines tagged "#N"), or the app's pricing when the lines don't add up to the subtotal. */
export function itemPrices(items: ReceiptItemRecord[], lines: ReceiptLineRecord[], subtotalCents: number): number[] {
  const tagged = new Array<number>(items.length).fill(0);
  let usable = lines.length > 0;
  for (const line of lines) {
    const number = Number(/^#(\d+)/.exec(line.detail)?.[1]);
    if (!number || number > items.length) {
      usable = false;
      break;
    }
    tagged[number - 1] += line.cents;
  }
  if (usable && tagged.reduce((a, b) => a + b, 0) === subtotalCents) return tagged;
  const cart: CartItem[] = items.map((i) => ({ vessel: i.vessel === "cone" ? "cone" : "cup", flavors: i.flavors, toppings: i.toppings ?? [] }));
  return quote(cart).lines.map((l) => l.totalCents);
}

const SQUARE_PAYMENT_ID = /^[A-Za-z0-9]{10,64}$/;
const SQUARE_LOOKUP_MS = 2500;

async function lookupSquareReceiptUrl(env: Env, paymentId: string): Promise<string | null> {
  const credentials = await resolveCredentials(env);
  if (!credentials) return null;
  const response = await squareRequest<{ payment?: { receipt_url?: string } }>(
    credentials.environment,
    `/v2/payments/${encodeURIComponent(paymentId)}`,
    { bearer: credentials.accessToken, timeoutMs: SQUARE_LOOKUP_MS },
  );
  const url = response.payment?.receipt_url;
  return url && url.startsWith("https://") ? url : null;
}

async function squareReceiptUrl(env: Env, paymentId: string): Promise<string | null> {
  if (!SQUARE_PAYMENT_ID.test(paymentId)) return null;
  let timer: ReturnType<typeof setTimeout> | null = null;
  const timeout = new Promise<null>((resolve) => {
    timer = setTimeout(() => resolve(null), SQUARE_LOOKUP_MS);
  });
  try {
    return await Promise.race([lookupSquareReceiptUrl(env, paymentId).catch(() => null), timeout]);
  } finally {
    clearTimeout(timer);
  }
}

const STYLE = `*{box-sizing:border-box}body{margin:0;background:#f4efe9;color:#1f1a17;font:16px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;-webkit-text-size-adjust:100%}
main{max-width:26rem;margin:0 auto;padding:1.25rem 1rem 3rem}
.card{background:#fff;border-radius:14px;padding:1.5rem 1.25rem;box-shadow:0 1px 3px rgba(0,0,0,.08)}
h1{font:600 1.5rem/1.2 Georgia,serif;margin:0;text-align:center}
.sub{text-align:center;color:#6b625b;font-size:.9rem;margin:.35rem 0 0}
.who{display:flex;justify-content:space-between;gap:1rem;margin-top:1.1rem;font:600 1.1rem Georgia,serif}
hr{border:0;border-top:1px dashed #cfc7bf;margin:1.1rem 0}
.item{display:flex;justify-content:space-between;gap:1rem;margin:0 0 .9rem}.item:last-child{margin-bottom:0}
.item b{font-weight:600}.item small{display:block;color:#6b625b}
.amt{white-space:nowrap;font-variant-numeric:tabular-nums}
.row{display:flex;justify-content:space-between;color:#6b625b}
.total{display:flex;justify-content:space-between;font:700 1.35rem Georgia,serif;margin-top:.4rem}
.meta{text-align:center;color:#6b625b;font-size:.85rem}
.test{text-align:center;color:#b3541e;font-weight:600;margin-top:.6rem}
.canceled{text-align:center;color:#b3261e;font-weight:700;margin:.8rem 0 0}
.center{text-align:center}
a.btn{display:block;margin-top:1rem;text-align:center;padding:.8rem;border-radius:10px;background:#1f1a17;color:#fff;text-decoration:none;font-weight:600}
p{margin:.6rem 0}`;

function page(title: string, body: string, refresh = false): string {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">${refresh ? `<meta http-equiv="refresh" content="${REFRESH_SECONDS}">` : ""}<title>${escapeHtml(title)}</title>
<style>${STYLE}</style></head><body><main>${body}</main></body></html>`;
}

function itemHtml(item: ReceiptItemRecord, index: number, cents: number): string {
  const scoops = `${item.flavors.length} scoop${item.flavors.length === 1 ? "" : "s"}: ${item.flavors.map(flavorTitle).join(", ")}`;
  const toppings = item.toppings?.length ? `<small>Toppings: ${escapeHtml(item.toppings.map(toppingTitle).join(", "))}</small>` : "";
  return `<div class="item"><div><b>Item ${index + 1}: ${escapeHtml(vesselTitle(item.vessel))}</b><small>${escapeHtml(scoops)}</small>${toppings}</div><div class="amt">${money(cents)}</div></div>`;
}

export function pendingPage(): string {
  return page(
    "Your receipt will appear shortly",
    `<div class="card"><h1>Your receipt will appear shortly</h1><p class="sub">${escapeHtml(EVENT_NAME)}</p>
<p class="center">We're still getting your order from the booth. This page refreshes on its own.</p></div>`,
    true,
  );
}

export function notFoundPage(): string {
  return page(
    "Receipt not found",
    `<div class="card"><h1>Receipt not found</h1><p class="center">Check the link on your receipt, or ask at the booth.</p></div>`,
  );
}

export function receiptPage(record: ReceiptRecord, squareUrl: string | null): string {
  const subtotal = record.subtotalCents ?? record.totalCents - (record.taxCents ?? 0);
  const prices = itemPrices(record.items, record.lines, subtotal);
  const label = record.orderNumber !== null ? `Order ${record.orderNumber}` : "Your order";
  return page(
    `${EVENT_NAME} receipt`,
    `<div class="card"><h1>${escapeHtml(EVENT_NAME)}</h1>
<p class="sub">${record.paidAt ? escapeHtml(formatEventTime(record.paidAt)) : ""}</p>
<div class="who"><span>${escapeHtml(label)}</span><span>${escapeHtml(record.customerName ?? "")}</span></div>
${record.canceled ? '<p class="canceled">This order was canceled</p>' : ""}<hr>
${record.items.map((item, i) => itemHtml(item, i, prices[i] ?? 0)).join("")}<hr>
<div class="row"><span>Subtotal</span><span class="amt">${money(subtotal)}</span></div>
<div class="row"><span>Tax</span><span class="amt">${money(record.taxCents ?? 0)}</span></div>
<div class="total"><span>Total</span><span class="amt">${money(record.totalCents)}</span></div><hr>
<p class="meta">${record.card ? `Paid by ${escapeHtml(record.card)}` : "Paid by card"}</p>
${record.simulated ? '<p class="test">Test mode: simulated payment</p>' : ""}
${squareUrl ? `<a class="btn" href="${escapeHtml(squareUrl)}" rel="noopener noreferrer">View Square receipt</a>` : ""}</div>
<p class="meta">Thank you for supporting Tech Club.</p>`,
  );
}

export const routes: Route[] = [
  {
    method: "GET",
    path: /^\/r\/([^/]+)$/,
    async handle({ env, params }) {
      const token = ReceiptToken.safeParse(params[0]);
      if (!token.success) return html(notFoundPage(), 404, NOINDEX);
      let record: ReceiptRecord | null;
      try {
        record = await findReceipt(env, token.data);
      } catch (error) {
        console.error({ event: "receipt-lookup-failed", error: String(error) });
        return html(pendingPage(), 503, NOINDEX);
      }
      if (!record || !record.paid) return html(pendingPage(), 200, NOINDEX);
      const squareUrl = record.squarePaymentId && !record.simulated ? await squareReceiptUrl(env, record.squarePaymentId) : null;
      return html(receiptPage(record, squareUrl), 200, NOINDEX);
    },
  },
];
