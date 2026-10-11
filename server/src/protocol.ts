export type Role = "kiosk" | "staff";

export interface Flavor {
  id: string;
  name: string;
}

export interface ReaderHealth {
  name: string;
  model?: string;
  state: string;
  batteryPercent?: number | null;
  isCharging?: boolean | null;
}

export interface KioskHealth {
  appVersion?: string;
  environment?: string;
  authorized?: boolean;
  authorizationState?: string;
  readers?: ReaderHealth[];
  readerReady?: boolean;
  catalog?: { ok: boolean; status?: string; error?: string | null };
  deviceBattery?: { percent: number; charging: boolean } | null;
  simulatePayment?: boolean;
  screen?: string;
  lastError?: string | null;
  lastErrorAt?: string | null;
  flavors?: Flavor[];
}

export interface KioskState {
  connected: boolean;
  online: boolean;
  lastHeartbeatAt: number | null;
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

export interface BoothState {
  flavors: (Flavor & { soldOut: boolean })[];
  soldOut: Record<string, boolean>;
  kiosk: KioskState;
  alerts: Alert[];
  serverTime: number;
}

export type HelpReason = "button" | "payment_failed" | "no_reader" | "idle";

export type ClientMessage =
  | { type: "heartbeat"; at?: string; screen?: string }
  | { type: "health"; health: KioskHealth }
  | { type: "help"; id: string; reason: HelpReason; message?: string; at?: string }
  | { type: "ack"; id: string; by?: string }
  | { type: "setSoldOut"; flavor: string; soldOut: boolean; by?: string };

export type ServerMessage =
  | { type: "snapshot"; state: BoothState }
  | { type: "soldOut"; soldOut: Record<string, boolean>; flavor: string; value: boolean; by: string | null }
  | { type: "alert"; alert: Alert }
  | { type: "kiosk"; kiosk: KioskState }
  | { type: "helpReceived"; id: string; alertId: string }
  | { type: "pong"; at: number }
  | { type: "error"; message: string };

export const HELP_TITLES: Record<HelpReason, string> = {
  button: "Customer needs help",
  payment_failed: "Payment didn't go through",
  no_reader: "No card reader ready at checkout",
  idle: "Customer may be stuck",
};

export const DEFAULT_FLAVORS: Flavor[] = [
  { id: "vanilla", name: "Vanilla" },
  { id: "chocolate", name: "Chocolate" },
  { id: "cookies", name: "Cookies & Cream" },
];

const FLAVOR_ID = /^[a-z0-9_-]{1,32}$/;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function str(value: unknown, max: number): string | undefined {
  return typeof value === "string" ? value.slice(0, max) : undefined;
}

export function parseFlavors(value: unknown): Flavor[] | undefined {
  if (!Array.isArray(value)) return undefined;
  const flavors = value
    .filter(isRecord)
    .map((f) => ({ id: str(f.id, 32) ?? "", name: str(f.name, 64) ?? "" }))
    .filter((f) => FLAVOR_ID.test(f.id) && f.name.length > 0)
    .slice(0, 24);
  return flavors.length > 0 ? flavors : undefined;
}

function parseHealth(value: unknown): KioskHealth | undefined {
  if (!isRecord(value)) return undefined;
  const readers = Array.isArray(value.readers)
    ? value.readers.filter(isRecord).slice(0, 8).map((r) => ({
        name: str(r.name, 80) ?? "Reader",
        model: str(r.model, 80),
        state: str(r.state, 40) ?? "unknown",
        batteryPercent: typeof r.batteryPercent === "number" ? r.batteryPercent : null,
        isCharging: typeof r.isCharging === "boolean" ? r.isCharging : null,
      }))
    : undefined;
  const catalog = isRecord(value.catalog)
    ? { ok: value.catalog.ok !== false, status: str(value.catalog.status, 80), error: str(value.catalog.error, 300) ?? null }
    : undefined;
  const battery = isRecord(value.deviceBattery) && typeof value.deviceBattery.percent === "number"
    ? { percent: value.deviceBattery.percent, charging: value.deviceBattery.charging === true }
    : null;
  return {
    appVersion: str(value.appVersion, 40),
    environment: str(value.environment, 40),
    authorized: typeof value.authorized === "boolean" ? value.authorized : undefined,
    authorizationState: str(value.authorizationState, 40),
    readers,
    readerReady: typeof value.readerReady === "boolean" ? value.readerReady : undefined,
    catalog,
    deviceBattery: battery,
    simulatePayment: typeof value.simulatePayment === "boolean" ? value.simulatePayment : undefined,
    screen: str(value.screen, 40),
    lastError: str(value.lastError, 500) ?? null,
    lastErrorAt: str(value.lastErrorAt, 40) ?? null,
    flavors: parseFlavors(value.flavors),
  };
}

const HELP_REASONS = new Set<HelpReason>(["button", "payment_failed", "no_reader", "idle"]);

export function parseClientMessage(raw: string, role: Role): ClientMessage | string {
  let data: unknown;
  try {
    data = JSON.parse(raw);
  } catch {
    return "Message is not JSON";
  }
  if (!isRecord(data) || typeof data.type !== "string") return "Message needs a type";
  const kioskOnly = (type: string) => `Only the kiosk can send ${type}`;
  const staffOnly = (type: string) => `Only staff can send ${type}`;
  switch (data.type) {
    case "heartbeat":
      if (role !== "kiosk") return kioskOnly("heartbeat");
      return { type: "heartbeat", at: str(data.at, 40), screen: str(data.screen, 40) };
    case "health": {
      if (role !== "kiosk") return kioskOnly("health");
      const health = parseHealth(data.health);
      return health ? { type: "health", health } : "health needs a health object";
    }
    case "help": {
      if (role !== "kiosk") return kioskOnly("help");
      const reason = data.reason as HelpReason;
      const id = str(data.id, 64);
      if (!id || !HELP_REASONS.has(reason)) return "help needs an id and a known reason";
      return { type: "help", id, reason, message: str(data.message, 500), at: str(data.at, 40) };
    }
    case "ack": {
      if (role !== "staff") return staffOnly("ack");
      const id = str(data.id, 64);
      return id ? { type: "ack", id, by: str(data.by, 40) } : "ack needs an id";
    }
    case "setSoldOut": {
      if (role !== "staff") return staffOnly("setSoldOut");
      const flavor = str(data.flavor, 32);
      if (!flavor || typeof data.soldOut !== "boolean") return "setSoldOut needs a flavor and soldOut";
      return { type: "setSoldOut", flavor, soldOut: data.soldOut, by: str(data.by, 40) };
    }
    default:
      return `Unknown message type ${data.type.slice(0, 40)}`;
  }
}
