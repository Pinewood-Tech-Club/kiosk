import type { HelpReason, KioskHealth, OrderStatus } from "./schema";

export type Role = "kiosk" | "staff";

export interface FlavorState {
  id: string;
  name: string;
  soldOut: boolean;
}

export interface KioskState {
  connected: boolean;
  online: boolean;
  lastSeenAt: number | null;
  screen: string | null;
  health: KioskHealth | null;
  healthAt: number | null;
}

export type AlertKind = "help" | "offline" | "health" | "soldout";
export type Severity = "urgent" | "warning" | "info";

export interface Alert {
  id: string;
  key: string;
  kind: AlertKind;
  severity: Severity;
  title: string;
  detail: string;
  count: number;
  createdAt: number;
  updatedAt: number;
  ackedAt: number | null;
  ackedBy: string | null;
  resolvedAt: number | null;
}

export interface OrderItem {
  vessel: string;
  flavors: string[];
  toppings: string[];
}

export interface OrderSummary {
  id: string;
  orderNumber: number | null;
  customerName: string | null;
  items: OrderItem[];
  totalCents: number;
  simulated: boolean;
  paidAt: number;
  receivedAt: number;
  status: OrderStatus;
  statusAt: number;
  statusBy: string | null;
}

export interface BoothState {
  rev: number;
  flavors: FlavorState[];
  kiosk: KioskState;
  alerts: Alert[];
  orders: OrderSummary[];
  serverTime: number;
}

export type Change =
  | { kind: "flavors"; flavors: FlavorState[] }
  | { kind: "alert"; alert: Alert }
  | { kind: "kiosk"; kiosk: KioskState }
  | { kind: "order"; order: OrderSummary };

export interface ApiError {
  code: string;
  message: string;
  retryable?: boolean;
}

export type ItemStatus = "ok" | "duplicate" | "stale" | "rejected";

export interface ItemResult {
  id: string;
  status: ItemStatus;
  alertId?: string;
  error?: ApiError;
}

export type ServerMessage =
  | { type: "snapshot"; state: BoothState }
  | { type: "patch"; rev: number; change: Change }
  | { type: "pong"; t: number | null; rev: number; serverTime: number; kioskLastSeenAt: number | null }
  | ({ type: "result" } & ItemResult)
  | { type: "error"; error: ApiError };

export const HELP_TITLES: Record<HelpReason, string> = {
  button: "Customer needs help",
  payment_failed: "Payment didn't go through",
  no_reader: "No card reader ready at checkout",
  idle: "Customer may be stuck",
};

export const DEFAULT_FLAVORS = [
  { id: "vanilla", name: "Vanilla" },
  { id: "chocolate", name: "Chocolate" },
  { id: "cookies", name: "Cookies & Cream" },
];
