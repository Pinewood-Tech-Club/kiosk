import { escapeHtml, html, withRetry, type Route } from "./http";
import { ReceiptToken } from "./schema";

export interface ReceiptRecord {
  source: "order" | "checkout";
  id: string;
  orderNumber: number | null;
  customerName: string | null;
  totalCents: number;
  paid: boolean;
}

/** A paid order if the kiosk has uploaded it, else the checkout the token was sent with (created, maybe not yet paid). */
export async function findReceipt(env: Env, token: string): Promise<ReceiptRecord | null> {
  const order = await withRetry("D1", () =>
    env.DB.prepare("SELECT id, order_number, customer_name, total_cents FROM orders WHERE receipt_token = ?")
      .bind(token)
      .first<{ id: string; order_number: number | null; customer_name: string | null; total_cents: number }>(),
  );
  if (order) {
    return { source: "order", id: order.id, orderNumber: order.order_number, customerName: order.customer_name, totalCents: order.total_cents, paid: true };
  }
  const checkout = await withRetry("D1", () =>
    env.DB.prepare("SELECT id, order_number, customer_name, total_cents FROM checkouts WHERE receipt_token = ?")
      .bind(token)
      .first<{ id: string; order_number: number | null; customer_name: string | null; total_cents: number }>(),
  );
  if (checkout) {
    return { source: "checkout", id: checkout.id, orderNumber: checkout.order_number, customerName: checkout.customer_name, totalCents: checkout.total_cents, paid: false };
  }
  return null;
}

function page(title: string, body: string): string {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex"><title>${escapeHtml(title)}</title>
<style>body{font:17px/1.5 system-ui,sans-serif;background:#000;color:#f5f5f5;display:grid;place-items:center;min-height:100vh;margin:0}main{max-width:30rem;padding:2rem}</style>
</head><body><main><h1>${escapeHtml(title)}</h1>${body}</main></body></html>`;
}

export const routes: Route[] = [
  {
    method: "GET",
    path: /^\/r\/([^/]+)$/,
    async handle({ env, params }) {
      const token = ReceiptToken.safeParse(params[0]);
      const record = token.success ? await findReceipt(env, token.data) : null;
      if (!record) return html(page("Receipt not found", "<p>Check the link on your receipt, or ask at the booth.</p>"), 404);
      const label = record.orderNumber !== null ? `Order #${record.orderNumber}` : "Your order";
      const status = record.paid ? "Paid" : "Payment pending";
      return html(page(label, `<p>${escapeHtml(status)}. The full receipt is coming soon.</p>`));
    },
  },
];
