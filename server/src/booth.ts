import { DurableObject } from "cloudflare:workers";
import {
  DEFAULT_FLAVORS,
  TOPPINGS,
  VESSELS,
  defaultKioskName,
  helpTitle,
  kioskTag,
  type Alert,
  type AlertKind,
  type ApiError,
  type BoothState,
  type Change,
  type FlavorState,
  type ItemResult,
  type KioskControl,
  type KioskEntry,
  type KioskSessionState,
  type KioskState,
  type OrderSummary,
  type KioskOpen,
  type Role,
  type ServerMessage,
  type Severity,
  type SupplyItem,
  type SupplyState,
} from "./protocol";
import {
  Action,
  AssistCommand,
  ClientMessage,
  Event,
  KioskSession,
  describe,
  type ControlOp,
  type HelpReason,
  type KioskHealth,
  type OrderStatus,
  type SupplyKind,
} from "./schema";

export const OFFLINE_AFTER_MS = 30_000;
export const HEALTH_GRACE_MS = 45_000;
export const HELP_MERGE_MS = 2 * 60_000;
export const LOW_BATTERY_PERCENT = 20;
export const MAX_FRAME_BYTES = 64 * 1024;
export const FLOOD_LIMIT = 60;
export const FLOOD_WINDOW_MS = 10_000;
export const RELAY_MEMORY = 500;
const RECENT_ALERTS_MS = 3 * 60 * 60_000;
export const MAX_SNAPSHOT_ALERTS = 60;
const RETENTION_MS = 7 * 24 * 60 * 60_000;
export const OPEN_ORDER_STATUSES: OrderStatus[] = ["paid", "preparing", "ready"];
const RECENT_ORDERS_MS = 3 * 60 * 60_000;
const MAX_FEED_ORDERS = 100;
export const MAX_KIOSKS = 20;
export const ASSIST_TTL_MS = 30_000;
const SCHEMA_VERSION = 2;
const RESET_META_KEYS = ["soldOut", "conditions", "healthSeq"];
const RESET_TABLES = ["alerts", "processed", "orders_feed", "kiosks", "sessions"] as const;

export interface HubCounts {
  alerts: number;
  openAlerts: number;
  orders: number;
  kiosks: number;
  processed: number;
  sessions: number;
  soldOut: number;
}

export interface HubReset {
  epoch: number;
  resetAt: number;
  rev: number;
  erased: HubCounts;
}

interface Attachment {
  role: Role;
  device: string;
  connectedAt: number;
  assist?: { kiosk: string; by: string | null; at: number };
}

interface Condition {
  title: string;
  detail: string;
}

interface AlertRow {
  id: string;
  key: string;
  kind: AlertKind;
  severity: Severity;
  title: string;
  detail: string;
  count: number;
  created_at: number;
  updated_at: number;
  acked_at: number | null;
  acked_by: string | null;
  resolved_at: number | null;
  kiosk_id: string | null;
  [column: string]: SqlStorageValue;
}

type Conditions = Record<string, Record<string, number>>;

const EMPTY_KIOSK: KioskState = {
  connected: false,
  online: false,
  lastSeenAt: null,
  screen: null,
  health: null,
  healthAt: null,
};

function toAlert(row: AlertRow): Alert {
  return {
    id: row.id,
    key: row.key,
    kind: row.kind,
    severity: row.severity,
    title: row.title,
    detail: row.detail,
    count: row.count,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    ackedAt: row.acked_at,
    ackedBy: row.acked_by,
    resolvedAt: row.resolved_at,
    kioskId: row.kiosk_id ?? null,
  };
}

function cleanName(raw: string | null | undefined): string | null {
  const name = (raw ?? "").replace(/\s+/g, " ").trim().slice(0, 40);
  return name || null;
}

function displayName(entry: Pick<KioskEntry, "id" | "customName" | "reportedName">): string {
  return entry.customName ?? entry.reportedName ?? defaultKioskName(entry.id);
}

function legacyKiosk(entry: KioskEntry | undefined): KioskState {
  if (!entry) return { ...EMPTY_KIOSK };
  const { connected, online, lastSeenAt, screen, health, healthAt } = entry;
  return { connected, online, lastSeenAt, screen, health, healthAt };
}

function rejected(id: string, code: string, message: string): ItemResult {
  return { id, status: "rejected", error: { code, message } };
}

function itemId(value: unknown): string {
  const raw = typeof value === "object" && value !== null ? (value as { id?: unknown }).id : undefined;
  return typeof raw === "string" ? raw.slice(0, 64) : "";
}

export function healthConditions(health: KioskHealth | null): Map<string, Condition> {
  const conditions = new Map<string, Condition>();
  if (!health) return conditions;
  const squareConfigured = health.environment !== "" && health.environment !== "No credentials";
  if (squareConfigured && !health.authorized) {
    conditions.set("health:auth", {
      title: "Square isn't authorized",
      detail: `Authorization: ${health.authorizationState || "not authorized"}. Card payments will fail.`,
    });
  }
  if (squareConfigured && !health.simulatePayment && !health.readerReady) {
    conditions.set("health:reader", {
      title: "No card reader ready",
      detail: health.readers.length === 0
        ? "No reader is paired with the kiosk."
        : health.readers.map((r) => `${r.name}: ${r.state}`).join(", "),
    });
  }
  const lowReader = health.readers.find(
    (r) => r.batteryPercent !== null && r.batteryPercent >= 0 && r.batteryPercent <= LOW_BATTERY_PERCENT && r.isCharging !== true,
  );
  if (lowReader) {
    conditions.set("health:reader-battery", {
      title: `Card reader battery low (${Math.round(lowReader.batteryPercent ?? 0)}%)`,
      detail: `${lowReader.name} needs charging.`,
    });
  }
  const ipad = health.deviceBattery;
  if (ipad && ipad.percent >= 0 && ipad.percent <= LOW_BATTERY_PERCENT && !ipad.charging) {
    conditions.set("health:ipad-battery", {
      title: `iPad battery low (${Math.round(ipad.percent)}%)`,
      detail: "Plug the kiosk iPad in.",
    });
  }
  if (!health.catalog.ok) {
    conditions.set("health:catalog", {
      title: "Square catalog error",
      detail: health.catalog.error || health.catalog.status || "Orders fall back to ad-hoc line items.",
    });
  }
  return conditions;
}

/**
 * The real-time hub. Everything it knows lives in SQLite storage, so eviction or hibernation loses nothing;
 * the only in-memory state is the per-socket flood counter.
 */
export class Booth extends DurableObject<Env> {
  private sql: SqlStorage;
  private flood = new Map<WebSocket, { start: number; count: number }>();
  private relayed = new Map<WebSocket, { ids: Set<string>; order: string[] }>();
  /** Patches wait here until their storage writes are committed, so a rolled-back write is never broadcast. */
  private outgoing: string[] = [];
  private pendingStatuses = new Map<string, OrderSummary>();

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    ctx.blockConcurrencyWhile(async () => {
      this.sql.exec(`
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS alerts (
          id TEXT PRIMARY KEY,
          key TEXT NOT NULL,
          kind TEXT NOT NULL,
          severity TEXT NOT NULL,
          title TEXT NOT NULL,
          detail TEXT NOT NULL,
          count INTEGER NOT NULL DEFAULT 1,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          acked_at INTEGER,
          acked_by TEXT,
          resolved_at INTEGER
        );
        CREATE INDEX IF NOT EXISTS alerts_key ON alerts (key, resolved_at);
        CREATE INDEX IF NOT EXISTS alerts_updated ON alerts (updated_at);
        CREATE TABLE IF NOT EXISTS processed (
          device TEXT NOT NULL,
          id TEXT NOT NULL,
          result TEXT NOT NULL,
          at INTEGER NOT NULL,
          PRIMARY KEY (device, id)
        ) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS processed_at ON processed (at);
        CREATE TABLE IF NOT EXISTS orders_feed (
          id TEXT PRIMARY KEY,
          data TEXT NOT NULL,
          status TEXT NOT NULL,
          paid_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS orders_feed_paid ON orders_feed (paid_at);
        CREATE TABLE IF NOT EXISTS kiosks (
          id TEXT PRIMARY KEY,
          data TEXT NOT NULL,
          first_seen INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS sessions (kiosk TEXT PRIMARY KEY, data TEXT NOT NULL);
      `);
      if ((this.getMeta<number>("schema") ?? 1) < SCHEMA_VERSION) this.migrate(Date.now());
    });
  }

  /** Version 2 keeps one entry per kiosk device. The single-kiosk state and its alerts can't be attributed to a device. */
  private migrate(now: number) {
    this.transaction(() => {
      this.sql.exec("ALTER TABLE alerts ADD COLUMN kiosk_id TEXT");
      for (const row of this.sql.exec<AlertRow>("SELECT * FROM alerts WHERE kind IN ('offline', 'health') AND resolved_at IS NULL").toArray()) {
        this.updateAlert(row.id, { resolved_at: now }, now);
      }
      for (const key of ["kiosk", "kioskOpen", "conditions"]) this.sql.exec("DELETE FROM meta WHERE key = ?", key);
      this.putMeta("schema", SCHEMA_VERSION);
    });
  }

  // MARK: Connections

  async fetch(request: Request): Promise<Response> {
    const role = request.headers.get("X-Booth-Role");
    const device = request.headers.get("X-Booth-Device");
    if ((role !== "kiosk" && role !== "staff") || !device || request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("Bad hub request", { status: 400 });
    }
    const now = Date.now();
    const { 0: client, 1: server } = new WebSocketPair();
    this.ctx.acceptWebSocket(server, [role, `device:${device}`]);
    server.serializeAttachment({ role, device, connectedAt: now } satisfies Attachment);

    this.prune(now);
    if (role === "kiosk") {
      // Restart the health grace periods: a relaunching app briefly reports no reader, and that must not
      // count against the time it was away.
      const conditions = this.getMeta<Conditions>("conditions") ?? {};
      delete conditions[device];
      this.putMeta("conditions", conditions);
      this.kioskContact(device, now, { connected: true });
      await this.evaluate(now);
    }
    this.flushPatches();
    this.send(server, { type: "snapshot", state: this.state(now, role) });
    if (role === "kiosk") this.send(server, this.assistMessage(device, now));
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    try {
      await this.onMessage(ws, message);
      this.flushPatches();
    } catch (error) {
      this.flushPatches();
      console.error({ event: "hub-message-failed", error: String(error) });
      this.send(ws, { type: "error", error: { code: "internal", message: "The hub couldn't handle that message", retryable: true } });
    }
  }

  async webSocketClose(ws: WebSocket): Promise<void> {
    this.socketGone(ws);
    this.flushPatches();
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    this.socketGone(ws);
    this.flushPatches();
  }

  async alarm(): Promise<void> {
    try {
      await this.evaluate(Date.now());
    } finally {
      this.flushPatches();
    }
  }

  private async onMessage(ws: WebSocket, message: string | ArrayBuffer) {
    const attachment = ws.deserializeAttachment() as Attachment | null;
    if (!attachment) return;
    const now = Date.now();
    if (this.flooding(ws, now)) {
      this.send(ws, { type: "error", error: { code: "rate_limited", message: "Too many messages", retryable: true } });
      ws.close(1008, "Too many messages");
      return;
    }
    if (typeof message !== "string" || message.length > MAX_FRAME_BYTES) {
      this.send(ws, { type: "error", error: { code: "bad_request", message: "Send JSON text frames under 64 KB" } });
      return;
    }
    let raw: unknown;
    try {
      raw = JSON.parse(message);
    } catch {
      this.send(ws, { type: "error", error: { code: "bad_request", message: "Message is not JSON" } });
      return;
    }
    const parsed = ClientMessage.safeParse(raw);
    if (!parsed.success) {
      this.send(ws, { type: "error", error: { code: "bad_request", message: describe(parsed.error) } });
      return;
    }
    const msg = parsed.data;
    const { role, device } = attachment;
    switch (msg.type) {
      case "heartbeat":
      case "ping":
        if (role === "kiosk") {
          this.kioskContact(device, now, {
            connected: true,
            screen: msg.type === "heartbeat" ? msg.screen : undefined,
            name: msg.type === "heartbeat" ? msg.name : undefined,
          });
          await this.evaluate(now);
        }
        this.send(ws, {
          type: "pong",
          t: msg.t ?? null,
          rev: this.rev(),
          serverTime: now,
          kioskLastSeenAt: role === "kiosk" ? this.kioskEntry(device)?.lastSeenAt ?? null : this.lastKioskContact(),
        });
        break;
      case "sync":
        this.send(ws, { type: "snapshot", state: this.state(now, role) });
        break;
      case "event": {
        if (role !== "kiosk") {
          this.send(ws, { type: "result", ...rejected(itemId(msg.event), "forbidden", "Only the kiosk sends events") });
          return;
        }
        const { results } = await this.ingestEvents(device, [msg.event], now);
        this.send(ws, { type: "result", ...results[0] });
        break;
      }
      case "action": {
        if (role !== "staff") {
          this.send(ws, { type: "result", ...rejected(itemId(msg.action), "forbidden", "Only staff send actions") });
          return;
        }
        const { results } = await this.applyActions(device, [msg.action], now);
        this.send(ws, { type: "result", ...results[0] });
        break;
      }
      case "session":
        if (role !== "kiosk") {
          this.send(ws, { type: "error", error: { code: "forbidden", message: "Only a kiosk publishes its session" } });
          return;
        }
        this.storeSession(ws, device, msg.session, now);
        break;
      case "assist":
        if (role !== "staff") {
          this.send(ws, { type: "error", error: { code: "forbidden", message: "Only staff assist a kiosk" } });
          return;
        }
        this.setAssist(ws, attachment, msg.kiosk, msg.by ?? null, now);
        break;
      case "command":
        this.relayCommands(ws, role, [msg.command]);
        break;
      case "commands":
        this.relayCommands(ws, role, msg.commands);
        break;
    }
  }

  private storeSession(ws: WebSocket, device: string, raw: unknown, now: number) {
    const parsed = KioskSession.safeParse(raw);
    if (!parsed.success) {
      this.send(ws, { type: "error", error: { code: "bad_request", message: `session: ${describe(parsed.error)}` } });
      return;
    }
    const session: KioskSessionState = { ...parsed.data, kiosk: device, updatedAt: now };
    this.sql.exec(
      "INSERT INTO sessions (kiosk, data) VALUES (?, ?) ON CONFLICT (kiosk) DO UPDATE SET data = excluded.data",
      device,
      JSON.stringify(session),
    );
    this.toStaff({ type: "session", kiosk: device, session });
  }

  private dropSession(device: string) {
    const existed = this.sql.exec("DELETE FROM sessions WHERE kiosk = ? RETURNING kiosk", device).toArray().length > 0;
    if (existed) this.toStaff({ type: "session", kiosk: device, session: null });
  }

  private sessions(): KioskSessionState[] {
    return this.sql
      .exec<{ kiosk: string; data: string }>("SELECT kiosk, data FROM sessions ORDER BY kiosk")
      .toArray()
      .filter((row) => this.kioskSockets(row.kiosk).length > 0)
      .map((row) => JSON.parse(row.data) as KioskSessionState);
  }

  private setAssist(ws: WebSocket, attachment: Attachment, kiosk: string | null, by: string | null, now: number) {
    const previous = attachment.assist?.kiosk ?? null;
    const next: Attachment = { role: attachment.role, device: attachment.device, connectedAt: attachment.connectedAt };
    if (kiosk) next.assist = { kiosk, by, at: now };
    ws.serializeAttachment(next);
    if (previous && previous !== kiosk) this.notifyAssist(previous, now);
    if (kiosk) this.notifyAssist(kiosk, now);
  }

  private assistMessage(kiosk: string, now: number, except?: WebSocket): ServerMessage {
    const helpers = this.ctx
      .getWebSockets("staff")
      .filter((s) => s !== except && s.readyState === WebSocket.OPEN)
      .map((s) => (s.deserializeAttachment() as Attachment | null)?.assist)
      .filter((a): a is NonNullable<Attachment["assist"]> => !!a && a.kiosk === kiosk && now - a.at < ASSIST_TTL_MS);
    return { type: "assist", active: helpers.length > 0, by: helpers[0]?.by ?? null, expiresIn: ASSIST_TTL_MS };
  }

  private notifyAssist(kiosk: string, now: number, except?: WebSocket) {
    const message = this.assistMessage(kiosk, now, except);
    for (const socket of this.kioskSockets(kiosk)) this.send(socket, message);
  }

  private relayCommands(ws: WebSocket, role: Role, batch: unknown[]) {
    if (role !== "staff") {
      for (const raw of batch) this.send(ws, { type: "result", ...rejected(itemId(raw), "forbidden", "Only staff send assist commands") });
      return;
    }
    for (const raw of batch) {
      const parsed = AssistCommand.safeParse(raw);
      if (!parsed.success) {
        this.send(ws, { type: "result", ...rejected(itemId(raw), "bad_request", describe(parsed.error)) });
        continue;
      }
      const command = parsed.data;
      const targets = this.kioskSockets(command.kiosk);
      if (targets.length === 0) {
        const name = this.kioskEntry(command.kiosk)?.name ?? "That kiosk";
        this.send(ws, { type: "result", ...rejected(command.id, "kiosk_offline", `${name} isn't connected`) });
        continue;
      }
      let relayed = false;
      for (const socket of targets) {
        if (this.alreadyRelayed(socket, command.id)) continue;
        this.send(socket, { type: "command", command });
        relayed = true;
      }
      this.send(ws, { type: "result", id: command.id, status: relayed ? "ok" : "duplicate" });
    }
  }

  private alreadyRelayed(socket: WebSocket, id: string): boolean {
    let memory = this.relayed.get(socket);
    if (!memory) {
      memory = { ids: new Set(), order: [] };
      this.relayed.set(socket, memory);
    }
    if (memory.ids.has(id)) return true;
    memory.ids.add(id);
    memory.order.push(id);
    if (memory.order.length > RELAY_MEMORY) memory.ids.delete(memory.order.shift()!);
    return false;
  }

  private kioskSockets(device: string, except?: WebSocket): WebSocket[] {
    return this.ctx
      .getWebSockets(`device:${device}`)
      .filter((s) => s !== except && s.readyState === WebSocket.OPEN && (s.deserializeAttachment() as Attachment | null)?.role === "kiosk");
  }

  private toStaff(message: ServerMessage) {
    const json = JSON.stringify(message);
    for (const socket of this.ctx.getWebSockets("staff")) {
      try {
        socket.send(json);
      } catch {}
    }
  }

  private flooding(ws: WebSocket, now: number): boolean {
    const window = this.flood.get(ws);
    if (!window || now - window.start > FLOOD_WINDOW_MS) {
      this.flood.set(ws, { start: now, count: 1 });
      return false;
    }
    window.count++;
    return window.count > FLOOD_LIMIT;
  }

  private socketGone(ws: WebSocket) {
    this.flood.delete(ws);
    this.relayed.delete(ws);
    const attachment = ws.deserializeAttachment() as Attachment | null;
    if (attachment?.role === "staff" && attachment.assist) this.notifyAssist(attachment.assist.kiosk, Date.now(), ws);
    if (attachment?.role !== "kiosk") return;
    const others = this.kioskSockets(attachment.device, ws);
    if (others.length > 0) return;
    this.dropSession(attachment.device);
    const entry = this.kioskEntry(attachment.device);
    if (entry?.connected) {
      this.putKiosk({ ...entry, connected: false });
      this.commitKiosks();
    }
  }

  // MARK: RPC

  async getState(role: Role = "staff"): Promise<BoothState> {
    return this.state(Date.now(), role);
  }

  async check(): Promise<{ ok: true; rev: number }> {
    return { ok: true, rev: this.rev() };
  }

  /** Any authenticated kiosk upload proves the kiosk is alive, even when its websocket can't connect. */
  async noteKioskContact(device: string): Promise<void> {
    const now = Date.now();
    try {
      this.kioskContact(device, now, {});
      await this.evaluate(now);
    } finally {
      this.flushPatches();
    }
  }

  async ingestEvents(device: string, items: unknown[], now = Date.now()): Promise<{ results: ItemResult[]; rev: number }> {
    try {
      return await this.ingest(device, items, now);
    } finally {
      this.flushPatches();
    }
  }

  async applyActions(device: string, items: unknown[], now = Date.now()): Promise<{ results: ItemResult[]; rev: number }> {
    try {
      return this.apply(device, items, now);
    } finally {
      this.flushPatches();
      await this.persistOrderStatuses();
    }
  }

  /**
   * Adds newly paid orders to the staff feed. Orders already in the feed are left alone, so retries are harmless.
   * Orders stamped with an epoch from before the last reset are refused and returned as stale.
   */
  async recordOrders(orders: OrderSummary[], epochs: Record<string, number> = {}): Promise<{ added: number; rev: number; stale: string[] }> {
    try {
      let added = 0;
      const epoch = this.epoch();
      const stale: string[] = [];
      this.transaction(() => {
        for (const order of orders) {
          if (epochs[order.id] !== undefined && epochs[order.id] < epoch) {
            stale.push(order.id);
            continue;
          }
          const exists = this.sql.exec("SELECT 1 FROM orders_feed WHERE id = ?", order.id).toArray().length > 0;
          if (exists) continue;
          this.sql.exec(
            "INSERT INTO orders_feed (id, data, status, paid_at, updated_at) VALUES (?, ?, ?, ?, ?)",
            order.id, JSON.stringify(order), order.status, order.paidAt, order.statusAt,
          );
          this.commit({ kind: "order", order });
          added++;
        }
      });
      return { added, rev: this.rev(), stale };
    } finally {
      this.flushPatches();
    }
  }

  async currentEpoch(): Promise<number> {
    return this.epoch();
  }

  async counts(): Promise<HubCounts> {
    const count = (sql: string) => this.sql.exec<{ n: number }>(sql).one().n;
    return {
      alerts: count("SELECT COUNT(*) AS n FROM alerts"),
      openAlerts: count("SELECT COUNT(*) AS n FROM alerts WHERE acked_at IS NULL AND resolved_at IS NULL"),
      orders: count("SELECT COUNT(*) AS n FROM orders_feed"),
      kiosks: count("SELECT COUNT(*) AS n FROM kiosks"),
      processed: count("SELECT COUNT(*) AS n FROM processed"),
      sessions: count("SELECT COUNT(*) AS n FROM sessions"),
      soldOut: Object.values(this.getMeta<Record<string, boolean>>("soldOut") ?? {}).filter(Boolean).length,
    };
  }

  /** Everything staff would lose in a reset, for the admin backup. */
  async backup(): Promise<{ epoch: number; rev: number; kiosks: KioskEntry[]; alerts: Alert[]; orders: OrderSummary[]; supplies: SupplyState[] }> {
    return {
      epoch: this.epoch(),
      rev: this.rev(),
      kiosks: this.kiosks(),
      alerts: this.sql.exec<AlertRow>("SELECT * FROM alerts ORDER BY created_at DESC, rowid DESC").toArray().map(toAlert),
      orders: this.sql.exec<{ data: string }>("SELECT data FROM orders_feed ORDER BY paid_at DESC").toArray().map((row) => JSON.parse(row.data) as OrderSummary),
      supplies: this.supplies(),
    };
  }

  /**
   * Erases the hub's alerts, kiosk registry, order feed, sold-out map, processed ids and assist state, and bumps the
   * epoch so items a kiosk queued before the reset are refused. Kiosks still connected get a fresh entry, and every
   * socket gets a new snapshot carrying the epoch; the revision keeps counting up so no client mistakes it for stale.
   */
  async reset(by: string | null): Promise<HubReset> {
    const now = Date.now();
    this.flushPatches();
    const erased = await this.counts();
    const epoch = this.epoch() + 1;
    this.transaction(() => {
      for (const table of RESET_TABLES) this.sql.exec(`DELETE FROM ${table}`);
      for (const key of RESET_META_KEYS) this.sql.exec("DELETE FROM meta WHERE key = ?", key);
      this.putMeta("epoch", epoch);
      this.putMeta("resetAt", now);
      this.putMeta("resetBy", by);
      this.putMeta("rev", this.rev() + 1);
    });
    this.pendingStatuses.clear();
    for (const ws of this.ctx.getWebSockets("staff")) {
      const attachment = ws.deserializeAttachment() as Attachment | null;
      if (attachment?.assist) ws.serializeAttachment({ role: attachment.role, device: attachment.device, connectedAt: attachment.connectedAt });
    }
    const connected = new Set(
      this.ctx.getWebSockets("kiosk")
        .filter((ws) => ws.readyState === WebSocket.OPEN)
        .map((ws) => (ws.deserializeAttachment() as Attachment | null)?.device)
        .filter((d): d is string => !!d),
    );
    for (const device of connected) this.kioskContact(device, now, { connected: true });
    await this.evaluate(now);
    this.resnapshot(now);
    console.log({ event: "hub-reset", epoch, by, erased });
    return { epoch, resetAt: now, rev: this.rev(), erased };
  }

  async control(kiosk: string, op: ControlOp, by: string | null): Promise<{ id: string; relayed: boolean }> {
    const control: KioskControl = { id: crypto.randomUUID(), op, by };
    const targets = this.kioskSockets(kiosk);
    for (const socket of targets) this.send(socket, { type: "control", control });
    return { id: control.id, relayed: targets.length > 0 };
  }

  async ackAll(by: string | null): Promise<{ acknowledged: number; rev: number }> {
    const now = Date.now();
    try {
      const open = this.sql.exec<AlertRow>("SELECT * FROM alerts WHERE acked_at IS NULL AND resolved_at IS NULL").toArray();
      this.transaction(() => {
        for (const row of open) this.updateAlert(row.id, { acked_at: now, acked_by: by }, now);
      });
      return { acknowledged: open.length, rev: this.rev() };
    } finally {
      this.flushPatches();
    }
  }

  /** The order feed has no removal patch, so after dropping orders every client gets a fresh snapshot. */
  async dropOrders(ids: string[]): Promise<{ removed: number; rev: number }> {
    let removed = 0;
    this.transaction(() => {
      for (const id of ids) removed += this.sql.exec("DELETE FROM orders_feed WHERE id = ? RETURNING id", id).toArray().length;
      if (removed > 0) this.putMeta("rev", this.rev() + 1);
    });
    if (removed > 0) this.resnapshot(Date.now());
    return { removed, rev: this.rev() };
  }

  private resnapshot(now: number) {
    this.outgoing = [];
    for (const ws of this.ctx.getWebSockets()) {
      const attachment = ws.deserializeAttachment() as Attachment | null;
      if (!attachment) continue;
      this.send(ws, { type: "snapshot", state: this.state(now, attachment.role) });
      if (attachment.role === "kiosk") this.send(ws, this.assistMessage(attachment.device, now));
    }
  }

  private async ingest(device: string, items: unknown[], now: number): Promise<{ results: ItemResult[]; rev: number }> {
    const results: ItemResult[] = [];
    const epoch = this.epoch();
    this.kioskContact(device, now, {});
    for (const item of items) {
      const parsed = Event.safeParse(item);
      if (!parsed.success) {
        results.push(rejected(itemId(item), "bad_request", describe(parsed.error)));
        continue;
      }
      const event = parsed.data;
      if (event.epoch !== undefined && event.epoch < epoch) {
        results.push({ id: event.id, status: "stale" });
        continue;
      }
      const previous = this.processed(device, event.id);
      if (previous) {
        results.push({ ...previous, status: previous.status === "ok" ? "duplicate" : previous.status });
        continue;
      }
      const result = this.transaction(() => {
        const outcome = event.type === "help"
          ? this.help(device, event.reason, event.message, now)
          : this.health(device, event.seq, event.health, now);
        const stored: ItemResult = { id: event.id, ...outcome };
        this.sql.exec("INSERT INTO processed (device, id, result, at) VALUES (?, ?, ?, ?)", device, event.id, JSON.stringify(stored), now);
        return stored;
      });
      results.push(result);
    }
    await this.evaluate(now);
    return { results, rev: this.rev() };
  }

  private apply(device: string, items: unknown[], now: number): { results: ItemResult[]; rev: number } {
    const results: ItemResult[] = [];
    for (const item of items) {
      const parsed = Action.safeParse(item);
      if (!parsed.success) {
        results.push(rejected(itemId(item), "bad_request", describe(parsed.error)));
        continue;
      }
      const action = parsed.data;
      const previous = this.processed(device, action.id);
      if (previous) {
        results.push({ ...previous, status: previous.status === "ok" ? "duplicate" : previous.status });
        continue;
      }
      const result = this.transaction(() => {
        const by = action.by ?? null;
        let error: ApiError | null;
        switch (action.type) {
          case "ack": error = this.ack(action.alertId, by, now); break;
          case "setSoldOut": error = this.setSupply("flavor", action.flavor, action.soldOut, by, now); break;
          case "setSupply": error = this.setSupply(action.kind, action.item, action.soldOut, by, now); break;
          case "setKioskOpen": error = this.setKioskOpen(action.kiosk ?? null, action.open, by, now); break;
          case "renameKiosk": error = this.renameKiosk(action.kiosk, action.name, now); break;
          case "setKioskDebug": error = this.setKioskDebug(action.kiosk, action.debug); break;
          case "removeKiosk": error = this.removeKiosk(action.kiosk, now); break;
          case "setOrderStatus": error = this.setOrderStatus(action.orderId, action.status, by, now); break;
        }
        const stored: ItemResult = error ? { id: action.id, status: "rejected", error } : { id: action.id, status: "ok" };
        this.sql.exec("INSERT INTO processed (device, id, result, at) VALUES (?, ?, ?, ?)", device, action.id, JSON.stringify(stored), now);
        return stored;
      });
      results.push(result);
    }
    return { results, rev: this.rev() };
  }

  private processed(device: string, id: string): ItemResult | null {
    const row = this.sql.exec<{ result: string }>("SELECT result FROM processed WHERE device = ? AND id = ?", device, id).toArray()[0];
    return row ? (JSON.parse(row.result) as ItemResult) : null;
  }

  // MARK: State changes

  private help(device: string, reason: HelpReason, message: string | undefined, now: number): Omit<ItemResult, "id"> {
    const key = `help:${reason}:${device}`;
    const name = this.kioskEntry(device)?.name ?? defaultKioskName(device);
    const detail = message?.trim() || `From ${name}.`;
    const recent = this.sql
      .exec<AlertRow>(
        "SELECT * FROM alerts WHERE key = ? AND acked_at IS NULL AND resolved_at IS NULL AND updated_at > ? ORDER BY updated_at DESC LIMIT 1",
        key,
        now - HELP_MERGE_MS,
      )
      .toArray()[0];
    const alert = recent
      ? this.updateAlert(recent.id, { count: recent.count + 1, detail }, now)
      : this.createAlert({ key, kind: "help", severity: "urgent", title: helpTitle(reason, name), detail, kioskId: device }, now);
    return { status: "ok", alertId: alert.id };
  }

  private health(device: string, seq: number, health: KioskHealth, now: number): Omit<ItemResult, "id"> {
    const seqs = this.getMeta<Record<string, number>>("healthSeq") ?? {};
    if (seqs[device] !== undefined && seq <= seqs[device]) return { status: "stale" };
    seqs[device] = seq;
    this.putMeta("healthSeq", seqs);
    if (health.flavors) this.setFlavorList(health.flavors);
    const entry = this.kioskEntry(device) ?? this.newKiosk(device, now);
    const reportedName = health.kioskName !== undefined ? cleanName(health.kioskName) : entry.reportedName;
    const next: KioskEntry = { ...entry, health, healthAt: now, screen: health.screen || entry.screen, reportedName };
    next.name = displayName(next);
    this.putKiosk(next);
    this.commitKiosks();
    if (next.name !== entry.name) this.retitleAlerts(device, entry.name, next.name, now);
    return { status: "ok" };
  }

  private ack(alertID: string, by: string | null, now: number): ApiError | null {
    const row = this.sql.exec<AlertRow>("SELECT * FROM alerts WHERE id = ?", alertID).toArray()[0];
    if (!row) return { code: "not_found", message: "No such alert" };
    if (row.acked_at === null) this.updateAlert(alertID, { acked_at: now, acked_by: by }, now);
    return null;
  }

  private setSupply(kind: SupplyKind, itemID: string, soldOut: boolean, by: string | null, now: number): ApiError | null {
    const item = this.supplyList(kind).find((i) => i.id === itemID);
    if (!item) return { code: "not_found", message: `Unknown ${kind} ${itemID}` };
    const key = soldOutKey(kind, itemID);
    const map = this.getMeta<Record<string, boolean>>("soldOut") ?? {};
    if ((map[key] ?? false) === soldOut) return null;
    map[key] = soldOut;
    this.putMeta("soldOut", map);
    if (kind === "flavor") this.commit({ kind: "flavors", flavors: this.flavors() });
    const supplies = this.supplies();
    this.commit({ kind: "supplies", supplies });

    const alertKey = `soldout:${key}`;
    for (const row of this.unresolved(alertKey)) this.updateAlert(row.id, { resolved_at: now }, now);
    const verb = item.plural ? "are" : "is";
    const allOut = (k: SupplyKind) => {
      const list = supplies.filter((s) => s.kind === k);
      return kind === k && soldOut && list.length > 0 && list.every((s) => s.soldOut);
    };
    const noVessels = allOut("vessel");
    const noFlavors = allOut("flavor");
    const setBy = by ? `, set by ${by}` : "";
    this.createAlert({
      key: alertKey,
      kind: "soldout",
      severity: noVessels || noFlavors ? "warning" : "info",
      title: `${item.name} ${verb} ${soldOut ? "sold out" : "back"}`,
      detail: noFlavors
        ? `Every flavor is sold out, so the kiosks show Closed until one is back${setBy}.`
        : noVessels
          ? `No cups or cones left, so the kiosks show Closed until one is back${setBy}.`
          : `${soldOut ? "Greyed out" : "Available again"} on the kiosks${setBy}.`,
    }, now);
    return null;
  }

  private setOrderStatus(orderID: string, status: OrderStatus, by: string | null, now: number): ApiError | null {
    const row = this.sql.exec<{ data: string }>("SELECT data FROM orders_feed WHERE id = ?", orderID).toArray()[0];
    if (!row) return { code: "not_found", message: "No such order in the feed" };
    const current = JSON.parse(row.data) as OrderSummary;
    if (current.status === status) return null;
    const order: OrderSummary = { ...current, status, statusAt: now, statusBy: by };
    this.sql.exec("UPDATE orders_feed SET data = ?, status = ?, updated_at = ? WHERE id = ?", JSON.stringify(order), status, now, orderID);
    this.pendingStatuses.set(orderID, order);
    this.commit({ kind: "order", order });
    return null;
  }

  /** D1 holds the permanent order record; the hub's copy is what staff see live, so D1 is updated best-effort. */
  private async persistOrderStatuses() {
    const pending = [...this.pendingStatuses.values()];
    this.pendingStatuses.clear();
    for (const order of pending) {
      try {
        await this.env.DB.prepare("UPDATE orders SET status = ?, status_at = ?, status_by = ? WHERE id = ?")
          .bind(order.status, order.statusAt, order.statusBy, order.id)
          .run();
      } catch (error) {
        console.warn({ event: "order-status-d1-failed", id: order.id, error: String(error) });
      }
    }
  }

  private newKiosk(device: string, now: number): KioskEntry {
    return {
      id: device, name: defaultKioskName(device), customName: null, reportedName: null, tag: kioskTag(device),
      open: true, openChangedAt: null, openChangedBy: null, debug: false,
      connected: false, online: false, lastSeenAt: null, firstSeenAt: now, screen: null, health: null, healthAt: null,
    };
  }

  private kioskContact(device: string, now: number, update: { connected?: boolean; screen?: string; name?: string }) {
    const existing = this.kioskEntry(device);
    const kiosk = existing ?? this.newKiosk(device, now);
    const reportedName = update.name !== undefined ? cleanName(update.name) : kiosk.reportedName;
    const next: KioskEntry = {
      ...kiosk,
      lastSeenAt: now,
      online: true,
      connected: update.connected ?? kiosk.connected,
      screen: update.screen ?? kiosk.screen,
      reportedName,
    };
    next.name = displayName(next);
    this.putKiosk(next);
    const visible = !existing || next.online !== kiosk.online || next.connected !== kiosk.connected || next.screen !== kiosk.screen || next.name !== kiosk.name;
    if (!existing) this.pruneKiosks(now);
    if (visible) this.commitKiosks();
    if (existing && next.name !== kiosk.name) this.retitleAlerts(device, kiosk.name, next.name, now);
    if (!kiosk.online) {
      for (const row of this.unresolved(`offline:${device}`)) {
        this.updateAlert(row.id, { resolved_at: now, detail: `Back online after ${formatDuration(now - row.created_at)}.` }, now);
      }
    }
  }

  async evaluate(now: number): Promise<void> {
    const deadlines: number[] = [];
    const stored = this.getMeta<Conditions>("conditions") ?? {};
    const pending: Conditions = {};
    let changed = false;

    for (const kiosk of this.kiosks()) {
      let entry = kiosk;
      if (entry.lastSeenAt !== null && entry.online) {
        const silentFor = now - entry.lastSeenAt;
        if (silentFor >= OFFLINE_AFTER_MS) {
          entry = { ...entry, online: false };
          this.putKiosk(entry);
          changed = true;
          if (this.unresolved(`offline:${entry.id}`).length === 0) {
            this.createAlert({
              key: `offline:${entry.id}`,
              kind: "offline",
              severity: entry.open ? "urgent" : "warning",
              title: `${entry.name} is offline`,
              detail: `No contact for ${Math.round(silentFor / 1000)} s. Check the iPad, its Wi-Fi and the app.`,
              kioskId: entry.id,
            }, now);
          }
        } else {
          deadlines.push(entry.lastSeenAt + OFFLINE_AFTER_MS);
        }
      }

      const conditions = new Map([...healthConditions(entry.health)].map(([key, c]) => [
        `${key}:${entry.id}`,
        { title: `${c.title} at ${entry.name}`, detail: c.detail },
      ]));
      for (const row of this.sql.exec<AlertRow>("SELECT * FROM alerts WHERE kind = 'health' AND kiosk_id = ? AND resolved_at IS NULL", entry.id).toArray()) {
        if (!conditions.has(row.key)) this.updateAlert(row.id, { resolved_at: now }, now);
      }
      const since: Record<string, number> = {};
      for (const [key, condition] of conditions) {
        since[key] = stored[entry.id]?.[key] ?? now;
        const open = this.unresolved(key)[0];
        if (open) {
          if (open.title !== condition.title || open.detail !== condition.detail) {
            this.updateAlert(open.id, { title: condition.title, detail: condition.detail }, now, false);
          }
        } else if (entry.online && now - since[key] >= HEALTH_GRACE_MS) {
          this.createAlert({ key, kind: "health", severity: "warning", ...condition, kioskId: entry.id }, now);
        } else if (entry.online) {
          deadlines.push(since[key] + HEALTH_GRACE_MS);
        }
      }
      if (conditions.size > 0) pending[entry.id] = since;
    }
    if (changed) this.commitKiosks();
    this.putMeta("conditions", pending);

    if (deadlines.length > 0) {
      await this.ctx.storage.setAlarm(Math.max(Math.min(...deadlines), now + 1000));
    } else {
      await this.ctx.storage.deleteAlarm();
    }
  }

  private setKioskOpen(device: string | null, open: boolean, by: string | null, now: number): ApiError | null {
    const targets = device === null ? this.kiosks() : [this.kioskEntry(device)].filter((k): k is KioskEntry => k !== null);
    if (device !== null && targets.length === 0) return { code: "not_found", message: "No such kiosk" };
    const before = this.legacyOpen();
    let changed = false;
    for (const kiosk of targets) {
      if (kiosk.open === open) continue;
      this.putKiosk({ ...kiosk, open, openChangedAt: now, openChangedBy: by });
      changed = true;
    }
    if (!changed) return null;
    this.commitKiosks();
    const after = this.legacyOpen();
    if (after.open !== before.open) this.commit({ kind: "kioskOpen", kioskOpen: after });
    return null;
  }

  private renameKiosk(device: string, name: string, now: number): ApiError | null {
    const kiosk = this.kioskEntry(device);
    if (!kiosk) return { code: "not_found", message: "No such kiosk" };
    const next = { ...kiosk, customName: cleanName(name) };
    next.name = displayName(next);
    if (next.customName === kiosk.customName && next.name === kiosk.name) return null;
    this.putKiosk(next);
    this.commitKiosks();
    if (next.name !== kiosk.name) this.retitleAlerts(device, kiosk.name, next.name, now);
    return null;
  }

  private setKioskDebug(device: string, debug: boolean): ApiError | null {
    const kiosk = this.kioskEntry(device);
    if (!kiosk) return { code: "not_found", message: "No such kiosk" };
    if (kiosk.debug === debug) return null;
    this.putKiosk({ ...kiosk, debug });
    this.commitKiosks();
    return null;
  }

  private removeKiosk(device: string, now: number): ApiError | null {
    if (!this.kioskEntry(device)) return null;
    const before = this.legacyOpen();
    this.forgetKiosk(device, now);
    this.commitKiosks();
    const after = this.legacyOpen();
    if (after.open !== before.open) this.commit({ kind: "kioskOpen", kioskOpen: after });
    return null;
  }

  private forgetKiosk(device: string, now: number) {
    this.sql.exec("DELETE FROM kiosks WHERE id = ?", device);
    this.sql.exec("DELETE FROM sessions WHERE kiosk = ?", device);
    for (const row of this.sql.exec<AlertRow>("SELECT * FROM alerts WHERE kiosk_id = ? AND resolved_at IS NULL", device).toArray()) {
      this.updateAlert(row.id, { resolved_at: now }, now);
    }
    const conditions = this.getMeta<Conditions>("conditions") ?? {};
    delete conditions[device];
    this.putMeta("conditions", conditions);
  }

  private pruneKiosks(now: number) {
    const all = this.kiosks();
    const excess = all.length - MAX_KIOSKS;
    if (excess <= 0) return;
    const victims = all.filter((k) => !k.online).sort((a, b) => (a.lastSeenAt ?? 0) - (b.lastSeenAt ?? 0)).slice(0, excess);
    for (const kiosk of victims) this.forgetKiosk(kiosk.id, now);
  }

  private retitleAlerts(device: string, from: string, to: string, now: number) {
    for (const row of this.sql.exec<AlertRow>("SELECT * FROM alerts WHERE kiosk_id = ? AND resolved_at IS NULL", device).toArray()) {
      const title = row.title.endsWith(` at ${from}`)
        ? row.title.slice(0, -from.length) + to
        : row.title.startsWith(`${from} is `)
          ? to + row.title.slice(from.length)
          : row.title;
      if (title !== row.title) this.updateAlert(row.id, { title }, now, false);
    }
  }

  // MARK: Storage

  private state(now: number, role: Role = "staff"): BoothState {
    const alerts = this.sql
      .exec<AlertRow>(
        `SELECT * FROM alerts
         WHERE (acked_at IS NULL AND resolved_at IS NULL) OR updated_at > ?
         ORDER BY created_at DESC, rowid DESC LIMIT ?`,
        now - RECENT_ALERTS_MS,
        MAX_SNAPSHOT_ALERTS,
      )
      .toArray()
      .map(toAlert);
    const orders = this.sql
      .exec<{ data: string }>(
        `SELECT data FROM orders_feed
         WHERE status IN (${OPEN_ORDER_STATUSES.map(() => "?").join(", ")}) OR updated_at > ?
         ORDER BY paid_at DESC LIMIT ?`,
        ...OPEN_ORDER_STATUSES,
        now - RECENT_ORDERS_MS,
        MAX_FEED_ORDERS,
      )
      .toArray()
      .map((row) => JSON.parse(row.data) as OrderSummary);
    const kiosks = this.kiosks();
    const latest = kiosks.reduce<KioskEntry | undefined>((best, k) => ((k.lastSeenAt ?? -1) > (best?.lastSeenAt ?? -1) ? k : best), undefined);
    return {
      rev: this.rev(),
      epoch: this.epoch(),
      resetAt: this.getMeta<number>("resetAt"),
      ...(role === "staff" ? { sessions: this.sessions() } : {}),
      kiosks,
      kioskOpen: this.legacyOpen(),
      flavors: this.flavors(),
      supplies: this.supplies(),
      kiosk: legacyKiosk(latest),
      alerts,
      orders,
      serverTime: now,
    };
  }

  private rev(): number {
    return this.getMeta<number>("rev") ?? 0;
  }

  private epoch(): number {
    return this.getMeta<number>("epoch") ?? 0;
  }

  /** Every visible change bumps the revision by one and is broadcast as one patch carrying it. */
  private commit(change: Change) {
    const rev = this.rev() + 1;
    this.putMeta("rev", rev);
    this.outgoing.push(JSON.stringify({ type: "patch", rev, change } satisfies ServerMessage));
  }

  private transaction<T>(body: () => T): T {
    const mark = this.outgoing.length;
    try {
      return this.ctx.storage.transactionSync(body);
    } catch (error) {
      this.outgoing.length = mark;
      throw error;
    }
  }

  private flushPatches() {
    const messages = this.outgoing;
    this.outgoing = [];
    for (const json of messages) {
      for (const ws of this.ctx.getWebSockets()) {
        try {
          ws.send(json);
        } catch {}
      }
    }
  }

  private createAlert(
    input: { key: string; kind: AlertKind; severity: Severity; title: string; detail: string; kioskId?: string },
    now: number,
  ): Alert {
    const row = this.sql
      .exec<AlertRow>(
        `INSERT INTO alerts (id, key, kind, severity, title, detail, count, created_at, updated_at, kiosk_id)
         VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?, ?) RETURNING *`,
        crypto.randomUUID(),
        input.key,
        input.kind,
        input.severity,
        input.title,
        input.detail,
        now,
        now,
        input.kioskId ?? null,
      )
      .one();
    const alert = toAlert(row);
    console.log({ event: "alert", alert });
    this.commit({ kind: "alert", alert });
    return alert;
  }

  private updateAlert(
    id: string,
    changes: Partial<Pick<AlertRow, "count" | "detail" | "title" | "acked_at" | "acked_by" | "resolved_at">>,
    now: number,
    touch = true,
  ): Alert {
    const columns = Object.keys(changes);
    const assignments = [...columns.map((c) => `${c} = ?`), ...(touch ? ["updated_at = ?"] : [])].join(", ");
    const values = [...Object.values(changes), ...(touch ? [now] : [])] as SqlStorageValue[];
    const row = this.sql.exec<AlertRow>(`UPDATE alerts SET ${assignments} WHERE id = ? RETURNING *`, ...values, id).one();
    const alert = toAlert(row);
    this.commit({ kind: "alert", alert });
    return alert;
  }

  private unresolved(key: string): AlertRow[] {
    return this.sql.exec<AlertRow>("SELECT * FROM alerts WHERE key = ? AND resolved_at IS NULL", key).toArray();
  }

  private prune(now: number) {
    this.sql.exec("DELETE FROM alerts WHERE created_at < ? AND (acked_at IS NOT NULL OR resolved_at IS NOT NULL)", now - RETENTION_MS);
    this.sql.exec("DELETE FROM processed WHERE at < ?", now - RETENTION_MS);
    this.sql.exec("DELETE FROM orders_feed WHERE paid_at < ? AND updated_at < ?", now - RETENTION_MS, now - RETENTION_MS);
    for (const row of this.sql.exec<{ kiosk: string }>("SELECT kiosk FROM sessions").toArray()) {
      if (this.kioskSockets(row.kiosk).length === 0) this.sql.exec("DELETE FROM sessions WHERE kiosk = ?", row.kiosk);
    }
    const forgotten = this.kiosks().filter((k) => !k.online && (k.lastSeenAt ?? k.firstSeenAt) < now - RETENTION_MS);
    for (const kiosk of forgotten) this.forgetKiosk(kiosk.id, now);
    if (forgotten.length > 0) this.commitKiosks();
  }

  private kiosks(): KioskEntry[] {
    return this.sql
      .exec<{ data: string }>("SELECT data FROM kiosks ORDER BY first_seen, id")
      .toArray()
      .map((row) => JSON.parse(row.data) as KioskEntry);
  }

  private kioskEntry(device: string): KioskEntry | null {
    const row = this.sql.exec<{ data: string }>("SELECT data FROM kiosks WHERE id = ?", device).toArray()[0];
    return row ? (JSON.parse(row.data) as KioskEntry) : null;
  }

  private putKiosk(entry: KioskEntry) {
    this.sql.exec(
      "INSERT INTO kiosks (id, data, first_seen) VALUES (?, ?, ?) ON CONFLICT (id) DO UPDATE SET data = excluded.data",
      entry.id,
      JSON.stringify(entry),
      entry.firstSeenAt,
    );
  }

  private commitKiosks() {
    this.commit({ kind: "kiosks", kiosks: this.kiosks() });
  }

  private lastKioskContact(): number | null {
    const seen = this.kiosks().map((k) => k.lastSeenAt).filter((t): t is number => t !== null);
    return seen.length > 0 ? Math.max(...seen) : null;
  }

  /** For clients that predate the kiosk registry: open unless every kiosk is closed. */
  private legacyOpen(): KioskOpen {
    const kiosks = this.kiosks();
    const last = kiosks.reduce<KioskEntry | undefined>((best, k) => ((k.openChangedAt ?? -1) > (best?.openChangedAt ?? -1) ? k : best), undefined);
    return {
      open: kiosks.length === 0 || kiosks.some((k) => k.open),
      changedAt: last?.openChangedAt ?? null,
      changedBy: last?.openChangedBy ?? null,
    };
  }

  private flavorList(): { id: string; name: string }[] {
    return this.getMeta<{ id: string; name: string }[]>("flavors") ?? DEFAULT_FLAVORS;
  }

  private flavors(): FlavorState[] {
    return this.supplies().filter((s) => s.kind === "flavor").map(({ id, name, soldOut }) => ({ id, name, soldOut }));
  }

  private supplyList(kind: SupplyKind): SupplyItem[] {
    if (kind === "vessel") return VESSELS;
    if (kind === "topping") return TOPPINGS;
    return this.flavorList();
  }

  private supplies(): SupplyState[] {
    const soldOut = this.getMeta<Record<string, boolean>>("soldOut") ?? {};
    return (["flavor", "vessel", "topping"] as const).flatMap((kind) =>
      this.supplyList(kind).map((item) => ({ kind, id: item.id, name: item.name, soldOut: soldOut[soldOutKey(kind, item.id)] ?? false })),
    );
  }

  private setFlavorList(list: { id: string; name: string }[]) {
    if (JSON.stringify(this.flavorList()) === JSON.stringify(list)) return;
    this.putMeta("flavors", list);
    this.commit({ kind: "flavors", flavors: this.flavors() });
    this.commit({ kind: "supplies", supplies: this.supplies() });
  }

  private getMeta<T>(key: string): T | null {
    const row = this.sql.exec<{ value: string }>("SELECT value FROM meta WHERE key = ?", key).toArray()[0];
    return row ? (JSON.parse(row.value) as T) : null;
  }

  private putMeta(key: string, value: unknown) {
    this.sql.exec(
      "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
      key,
      JSON.stringify(value),
    );
  }

  private send(ws: WebSocket, message: ServerMessage) {
    try {
      ws.send(JSON.stringify(message));
    } catch {}
  }
}

/** Flavors keep the bare ids they were stored under before vessels and toppings could sell out. */
function soldOutKey(kind: SupplyKind, id: string): string {
  return kind === "flavor" ? id : `${kind}:${id}`;
}

function formatDuration(ms: number): string {
  const seconds = Math.round(ms / 1000);
  if (seconds < 90) return `${seconds} s`;
  return `${Math.round(seconds / 60)} min`;
}
