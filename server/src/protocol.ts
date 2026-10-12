import { TOPPING_TITLES } from "./pricing";
import type { HelpReason, KioskHealth, OrderStatus, SupplyKind } from "./schema";

export type Role = "kiosk" | "staff";

export interface FlavorState {
  id: string;
  name: string;
  soldOut: boolean;
}

export interface SupplyState {
  kind: SupplyKind;
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

export interface KioskEntry {
  id: string;
  name: string;
  customName: string | null;
  reportedName: string | null;
  tag: string;
  open: boolean;
  openChangedAt: number | null;
  openChangedBy: string | null;
  debug: boolean;
  connected: boolean;
  online: boolean;
  lastSeenAt: number | null;
  firstSeenAt: number;
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
  kioskId: string | null;
}

export interface OrderItem {
  vessel: string;
  flavors: string[];
  toppings: string[];
}

export interface OrderSummary {
  id: string;
  orderNumber: number | null;
  orderRef: string | null;
  kioskId: string | null;
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

export interface KioskOpen {
  open: boolean;
  changedAt: number | null;
  changedBy: string | null;
}

export interface BoothState {
  rev: number;
  kiosks: KioskEntry[];
  kioskOpen: KioskOpen;
  flavors: FlavorState[];
  supplies: SupplyState[];
  kiosk: KioskState;
  alerts: Alert[];
  orders: OrderSummary[];
  serverTime: number;
}

export type Change =
  | { kind: "flavors"; flavors: FlavorState[] }
  | { kind: "supplies"; supplies: SupplyState[] }
  | { kind: "alert"; alert: Alert }
  | { kind: "kiosk"; kiosk: KioskState }
  | { kind: "kiosks"; kiosks: KioskEntry[] }
  | { kind: "order"; order: OrderSummary }
  | { kind: "kioskOpen"; kioskOpen: KioskOpen };

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

const HELP_TITLES: Record<HelpReason, string> = {
  button: "Customer needs help",
  payment_failed: "Payment didn't go through",
  no_reader: "No card reader ready for checkout",
  idle: "Customer may be stuck",
};

export function helpTitle(reason: HelpReason, kioskName: string): string {
  return `${HELP_TITLES[reason]} at ${kioskName}`;
}

export function kioskTag(device: string): string {
  return device.replace(/[^A-Za-z0-9]/g, "").slice(0, 4).toUpperCase() || "0000";
}

export function defaultKioskName(device: string): string {
  return `Kiosk ${kioskTag(device)}`;
}

export const DEFAULT_FLAVORS = [
  { id: "vanilla", name: "Vanilla" },
  { id: "chocolate", name: "Chocolate" },
  { id: "cookies", name: "Cookies & Cream" },
];

export interface SupplyItem {
  id: string;
  name: string;
  plural?: boolean;
}

export const VESSELS: SupplyItem[] = [
  { id: "cup", name: "Cups", plural: true },
  { id: "cone", name: "Waffle cones", plural: true },
];

const PLURAL_TOPPINGS = new Set(["gummies", "mms", "sprinkles"]);

export const TOPPINGS: SupplyItem[] = Object.entries(TOPPING_TITLES).map(([id, name]) => ({ id, name, plural: PLURAL_TOPPINGS.has(id) }));
