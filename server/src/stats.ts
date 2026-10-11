import { authenticate, json, withRetry, type Route } from "./http";

const HOUR_MS = 60 * 60_000;
const RECENT_MS = 15 * 60_000;

export interface StatsSummary {
  since: number;
  until: number;
  generatedAt: number;
  orders: number;
  simulatedOrders: number;
  canceledOrders: number;
  totalCents: number;
  subtotalCents: number;
  taxCents: number;
  averageCents: number;
  items: number;
  scoops: number;
  cups: number;
  cones: number;
  toppings: number;
  flavors: Record<string, number>;
  toppingCounts: Record<string, number>;
  statuses: Record<string, number>;
  byHour: { hour: number; orders: number; totalCents: number }[];
  last15Min: { orders: number; totalCents: number };
}

interface Row {
  total_cents: number;
  subtotal_cents: number | null;
  tax_cents: number | null;
  simulated: number;
  items: string;
  paid_at: number;
  status: string | null;
}

/** Real (not simulated) orders paid in [since, until). Simulated orders only count in `simulatedOrders`; canceled ones only in `canceledOrders` and `statuses`. */
export async function summarize(env: Env, since: number, until: number, now = Date.now()): Promise<StatsSummary> {
  const { results } = await withRetry("D1", () =>
    env.DB.prepare("SELECT total_cents, subtotal_cents, tax_cents, simulated, items, paid_at, status FROM orders WHERE paid_at >= ? AND paid_at < ?")
      .bind(since, until)
      .all<Row>(),
  );
  const summary: StatsSummary = {
    since, until, generatedAt: now, orders: 0, simulatedOrders: 0, canceledOrders: 0, totalCents: 0, subtotalCents: 0, taxCents: 0, averageCents: 0,
    items: 0, scoops: 0, cups: 0, cones: 0, toppings: 0, flavors: {}, toppingCounts: {}, statuses: {}, byHour: [], last15Min: { orders: 0, totalCents: 0 },
  };
  const hours = new Map<number, { orders: number; totalCents: number }>();
  for (const row of results) {
    if (row.simulated) {
      summary.simulatedOrders++;
      continue;
    }
    const status = row.status ?? "paid";
    summary.statuses[status] = (summary.statuses[status] ?? 0) + 1;
    if (status === "canceled") {
      summary.canceledOrders++;
      continue;
    }
    summary.orders++;
    summary.totalCents += row.total_cents;
    summary.taxCents += row.tax_cents ?? 0;
    summary.subtotalCents += row.subtotal_cents ?? row.total_cents - (row.tax_cents ?? 0);
    let items: { vessel?: string; flavors?: string[]; toppings?: string[] }[] = [];
    try {
      items = JSON.parse(row.items);
    } catch {}
    for (const item of items) {
      summary.items++;
      if (item.vessel === "cone") summary.cones++;
      else summary.cups++;
      for (const flavor of item.flavors ?? []) {
        summary.scoops++;
        summary.flavors[flavor] = (summary.flavors[flavor] ?? 0) + 1;
      }
      for (const topping of item.toppings ?? []) {
        summary.toppings++;
        summary.toppingCounts[topping] = (summary.toppingCounts[topping] ?? 0) + 1;
      }
    }
    if (row.paid_at >= now - RECENT_MS && row.paid_at <= now) {
      summary.last15Min.orders++;
      summary.last15Min.totalCents += row.total_cents;
    }
    const hour = Math.floor(row.paid_at / HOUR_MS) * HOUR_MS;
    const bucket = hours.get(hour) ?? { orders: 0, totalCents: 0 };
    bucket.orders++;
    bucket.totalCents += row.total_cents;
    hours.set(hour, bucket);
  }
  summary.averageCents = summary.orders > 0 ? Math.round(summary.totalCents / summary.orders) : 0;
  summary.byHour = [...hours.entries()].sort((a, b) => a[0] - b[0]).map(([hour, b]) => ({ hour, ...b }));
  return summary;
}

export const routes: Route[] = [
  {
    method: "GET",
    path: "/v1/stats",
    async handle({ request, env, url }) {
      await authenticate(request, env, ["staff"]);
      const now = Date.now();
      const until = Number(url.searchParams.get("until")) || now + 1;
      const since = Number(url.searchParams.get("since")) || until - 24 * HOUR_MS;
      return json(await summarize(env, since, until, now));
    },
  },
];
