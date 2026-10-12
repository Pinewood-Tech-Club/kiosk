import * as z from "zod";

export const PROTOCOL_VERSION = 1;

const id = z.string().min(1).max(64).regex(/^[A-Za-z0-9._:-]+$/, "use letters, digits, '.', '_', ':' or '-'");
const text = (max: number) => z.string().max(max * 4).transform((s) => s.slice(0, max));
const timestamp = z.union([z.string().max(64), z.number().finite()]).optional();

export const DeviceId = z.string().regex(/^[A-Za-z0-9._-]{1,64}$/);
export const FlavorId = z.string().regex(/^[a-z0-9_-]{1,32}$/);

export const ToppingId = z.string().regex(/^[a-z0-9_-]{1,32}$/);
export const SupplyId = z.string().regex(/^[a-z0-9_-]{1,32}$/);
export const SupplyKind = z.enum(["flavor", "vessel", "topping"]);
export type SupplyKind = z.infer<typeof SupplyKind>;
export const ReceiptToken = z.string().regex(/^[A-Za-z0-9_-]{22,64}$/, "22 to 64 of A-Z a-z 0-9 _ -");
export const OrderRef = z.string().regex(/^[A-Za-z0-9-]{1,24}$/, "1 to 24 of A-Z a-z 0-9 -");
export const KioskName = text(40);

export const ORDER_STATUSES = ["paid", "preparing", "ready", "collected", "canceled"] as const;
export const OrderStatus = z.enum(ORDER_STATUSES);
export type OrderStatus = z.infer<typeof OrderStatus>;

export const Flavor = z.object({ id: FlavorId, name: text(64).pipe(z.string().min(1)) });

export const KioskHealth = z.object({
  appVersion: text(40).default(""),
  environment: text(40).default(""),
  authorized: z.boolean().default(false),
  authorizationState: text(40).default(""),
  readers: z
    .array(
      z.object({
        name: text(80).default("Reader"),
        model: text(80).optional(),
        state: text(40).default("unknown"),
        batteryPercent: z.number().finite().min(-1).max(100).nullable().default(null),
        isCharging: z.boolean().nullable().default(null),
      }),
    )
    .max(8)
    .default([]),
  readerReady: z.boolean().default(false),
  catalog: z
    .object({ ok: z.boolean(), status: text(80).default(""), error: text(300).nullable().default(null) })
    .default({ ok: true, status: "", error: null }),
  deviceBattery: z.object({ percent: z.number().finite().min(-1).max(100), charging: z.boolean() }).nullable().default(null),
  simulatePayment: z.boolean().default(false),
  screen: text(40).default(""),
  lastError: text(500).nullable().default(null),
  lastErrorAt: text(64).nullable().default(null),
  flavors: z.array(Flavor).min(1).max(24).optional(),
  kioskName: KioskName.optional(),
});
export type KioskHealth = z.infer<typeof KioskHealth>;

export const HelpReason = z.enum(["button", "payment_failed", "no_reader", "idle"]);
export type HelpReason = z.infer<typeof HelpReason>;

const eventBase = { id, seq: z.number().int().min(0).max(Number.MAX_SAFE_INTEGER), at: timestamp };

export const Event = z.discriminatedUnion("type", [
  z.object({ ...eventBase, type: z.literal("help"), reason: HelpReason, message: text(500).optional() }),
  z.object({ ...eventBase, type: z.literal("health"), health: KioskHealth }),
]);
export type Event = z.infer<typeof Event>;

export const Action = z.discriminatedUnion("type", [
  z.object({ id, type: z.literal("ack"), alertId: z.string().min(1).max(64), by: text(40).optional() }),
  z.object({ id, type: z.literal("setSoldOut"), flavor: FlavorId, soldOut: z.boolean(), by: text(40).optional() }),
  z.object({ id, type: z.literal("setSupply"), kind: SupplyKind, item: SupplyId, soldOut: z.boolean(), by: text(40).optional() }),
  z.object({ id, type: z.literal("setOrderStatus"), orderId: id, status: OrderStatus, by: text(40).optional() }),
  z.object({ id, type: z.literal("setKioskOpen"), open: z.boolean(), kiosk: DeviceId.optional(), by: text(40).optional() }),
  z.object({ id, type: z.literal("renameKiosk"), kiosk: DeviceId, name: KioskName, by: text(40).optional() }),
  z.object({ id, type: z.literal("setKioskDebug"), kiosk: DeviceId, debug: z.boolean(), by: text(40).optional() }),
  z.object({ id, type: z.literal("removeKiosk"), kiosk: DeviceId, by: text(40).optional() }),
]);
export type Action = z.infer<typeof Action>;

/** Items are validated one by one so a single bad item is rejected without failing the batch. */
export const EventsBody = z.object({ events: z.array(z.unknown()).min(1).max(100) });
export const ActionsBody = z.object({ actions: z.array(z.unknown()).min(1).max(50) });

export const ClientMessage = z.discriminatedUnion("type", [
  z.object({ type: z.literal("heartbeat"), t: z.number().finite().optional(), screen: text(40).optional(), name: KioskName.optional() }),
  z.object({ type: z.literal("ping"), t: z.number().finite().optional() }),
  z.object({ type: z.literal("sync") }),
  z.object({ type: z.literal("event"), event: z.unknown() }),
  z.object({ type: z.literal("action"), action: z.unknown() }),
]);
export type ClientMessage = z.infer<typeof ClientMessage>;

export const LogLine = z.object({
  id: z.string().min(1).max(128),
  ts: timestamp,
  level: z.enum(["debug", "info", "warn", "error"]).catch("info"),
  message: z.string().max(64 * 1024).transform((s) => s.slice(0, 8 * 1024)),
  context: z.record(z.string(), z.unknown()).optional(),
});
export type LogLine = z.infer<typeof LogLine>;

export const LogsBody = z.object({
  appVersion: text(40).optional(),
  lines: z.array(z.unknown()).min(1).max(500),
});

export const Order = z.object({
  id,
  orderNumber: z.number().int().nullable().optional(),
  squareOrderId: text(64).nullable().optional(),
  squarePaymentId: text(64).nullable().optional(),
  customerName: text(80).nullable().optional(),
  totalCents: z.number().int().min(0).max(10_000_000),
  subtotalCents: z.number().int().nullable().optional(),
  taxCents: z.number().int().nullable().optional(),
  card: text(64).nullable().optional(),
  simulated: z.boolean().default(false),
  paidAt: timestamp,
  appVersion: text(40).optional(),
  receiptToken: ReceiptToken.nullable().optional(),
  orderRef: OrderRef.nullable().optional(),
  items: z
    .array(z.object({ vessel: text(20), flavors: z.array(text(32)).max(10), toppings: z.array(text(32)).max(20).optional() }))
    .min(1)
    .max(50),
  lines: z.array(z.object({ title: text(80), detail: text(200), cents: z.number().int() })).max(200).optional(),
});
export type Order = z.infer<typeof Order>;

export const CartItem = z.object({
  vessel: z.enum(["cup", "cone"]),
  flavors: z.array(FlavorId).min(1).max(3),
  toppings: z.array(ToppingId).max(10).default([]),
});

export const CheckoutBody = z.object({
  id,
  receiptToken: ReceiptToken,
  orderNumber: z.number().int().min(0).max(1_000_000_000).optional(),
  orderRef: OrderRef.optional(),
  customerName: text(80).pipe(z.string().min(1)),
  sourceName: text(80).optional(),
  locationId: z.string().max(64).optional(),
  quotedCents: z.number().int().min(0).max(10_000_000).optional(),
  items: z.array(CartItem).min(1).max(20),
});
export type CheckoutBody = z.infer<typeof CheckoutBody>;

export const OrdersBody = z.object({ orders: z.array(z.unknown()).min(1).max(50) });

export function describe(error: z.ZodError): string {
  return error.issues
    .slice(0, 3)
    .map((issue) => `${issue.path.join(".") || "body"}: ${issue.message}`)
    .join("; ");
}

export function parseTimestamp(value: string | number | undefined, fallback: number): number {
  if (typeof value === "number") return value;
  if (typeof value === "string") {
    const parsed = Date.parse(value);
    if (!Number.isNaN(parsed)) return parsed;
  }
  return fallback;
}
