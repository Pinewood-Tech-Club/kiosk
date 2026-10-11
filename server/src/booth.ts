import { DurableObject } from "cloudflare:workers";
import {
  DEFAULT_FLAVORS,
  HELP_TITLES,
  type Alert,
  type AlertKind,
  type ApiError,
  type BoothState,
  type Change,
  type FlavorState,
  type ItemResult,
  type KioskState,
  type Role,
  type ServerMessage,
  type Severity,
} from "./protocol";
import { Action, ClientMessage, Event, describe, type HelpReason, type KioskHealth } from "./schema";

export const OFFLINE_AFTER_MS = 30_000;
export const HEALTH_GRACE_MS = 45_000;
export const HELP_MERGE_MS = 2 * 60_000;
export const LOW_BATTERY_PERCENT = 20;
export const MAX_FRAME_BYTES = 64 * 1024;
export const FLOOD_LIMIT = 60;
export const FLOOD_WINDOW_MS = 10_000;
const RECENT_ALERTS_MS = 3 * 60 * 60_000;
const RETENTION_MS = 7 * 24 * 60 * 60_000;

interface Attachment {
  role: Role;
  device: string;
  connectedAt: number;
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
  [column: string]: SqlStorageValue;
}

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
  };
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
      title: `Kiosk iPad battery low (${Math.round(ipad.percent)}%)`,
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
  /** Patches wait here until their storage writes are committed, so a rolled-back write is never broadcast. */
  private outgoing: string[] = [];

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
      `);
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
      this.putMeta("conditions", {});
      this.kioskContact(now, { connected: true });
      await this.evaluate(now);
    }
    this.flushPatches();
    this.send(server, { type: "snapshot", state: this.state(now) });
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
          this.kioskContact(now, { connected: true, screen: msg.type === "heartbeat" ? msg.screen : undefined });
          await this.evaluate(now);
        }
        this.send(ws, {
          type: "pong",
          t: msg.t ?? null,
          rev: this.rev(),
          serverTime: now,
          kioskLastSeenAt: this.kiosk().lastSeenAt,
        });
        break;
      case "sync":
        this.send(ws, { type: "snapshot", state: this.state(now) });
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
    const attachment = ws.deserializeAttachment() as Attachment | null;
    if (attachment?.role !== "kiosk") return;
    const others = this.ctx.getWebSockets("kiosk").filter((s) => s !== ws && s.readyState === WebSocket.OPEN);
    if (others.length === 0 && this.kiosk().connected) {
      this.setKiosk({ ...this.kiosk(), connected: false });
    }
  }

  // MARK: RPC

  async getState(): Promise<BoothState> {
    return this.state(Date.now());
  }

  async check(): Promise<{ ok: true; rev: number }> {
    return { ok: true, rev: this.rev() };
  }

  /** Any authenticated kiosk upload proves the kiosk is alive, even when its websocket can't connect. */
  async noteKioskContact(): Promise<void> {
    const now = Date.now();
    try {
      this.kioskContact(now, {});
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
    }
  }

  private async ingest(device: string, items: unknown[], now: number): Promise<{ results: ItemResult[]; rev: number }> {
    const results: ItemResult[] = [];
    for (const item of items) {
      const parsed = Event.safeParse(item);
      if (!parsed.success) {
        results.push(rejected(itemId(item), "bad_request", describe(parsed.error)));
        continue;
      }
      const event = parsed.data;
      const previous = this.processed(device, event.id);
      if (previous) {
        results.push({ ...previous, status: previous.status === "ok" ? "duplicate" : previous.status });
        continue;
      }
      const result = this.transaction(() => {
        const outcome = event.type === "help"
          ? this.help(event.reason, event.message, now)
          : this.health(device, event.seq, event.health, now);
        const stored: ItemResult = { id: event.id, ...outcome };
        this.sql.exec("INSERT INTO processed (device, id, result, at) VALUES (?, ?, ?, ?)", device, event.id, JSON.stringify(stored), now);
        return stored;
      });
      results.push(result);
    }
    this.kioskContact(now, {});
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
        const error = action.type === "ack"
          ? this.ack(action.alertId, action.by ?? null, now)
          : this.setSoldOut(action.flavor, action.soldOut, action.by ?? null, now);
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

  private help(reason: HelpReason, message: string | undefined, now: number): Omit<ItemResult, "id"> {
    const key = `help:${reason}`;
    const detail = message?.trim() || "From the kiosk.";
    const recent = this.sql
      .exec<AlertRow>(
        "SELECT * FROM alerts WHERE key = ? AND acked_at IS NULL AND resolved_at IS NULL AND updated_at > ? ORDER BY updated_at DESC LIMIT 1",
        key,
        now - HELP_MERGE_MS,
      )
      .toArray()[0];
    const alert = recent
      ? this.updateAlert(recent.id, { count: recent.count + 1, detail }, now)
      : this.createAlert({ key, kind: "help", severity: "urgent", title: HELP_TITLES[reason], detail }, now);
    return { status: "ok", alertId: alert.id };
  }

  private health(device: string, seq: number, health: KioskHealth, now: number): Omit<ItemResult, "id"> {
    const seqs = this.getMeta<Record<string, number>>("healthSeq") ?? {};
    if (seqs[device] !== undefined && seq <= seqs[device]) return { status: "stale" };
    seqs[device] = seq;
    this.putMeta("healthSeq", seqs);
    if (health.flavors) this.setFlavorList(health.flavors);
    this.setKiosk({ ...this.kiosk(), health, healthAt: now, screen: health.screen || this.kiosk().screen });
    return { status: "ok" };
  }

  private ack(alertID: string, by: string | null, now: number): ApiError | null {
    const row = this.sql.exec<AlertRow>("SELECT * FROM alerts WHERE id = ?", alertID).toArray()[0];
    if (!row) return { code: "not_found", message: "No such alert" };
    if (row.acked_at === null) this.updateAlert(alertID, { acked_at: now, acked_by: by }, now);
    return null;
  }

  private setSoldOut(flavorID: string, soldOut: boolean, by: string | null, now: number): ApiError | null {
    const flavor = this.flavorList().find((f) => f.id === flavorID);
    if (!flavor) return { code: "not_found", message: `Unknown flavor ${flavorID}` };
    const map = this.getMeta<Record<string, boolean>>("soldOut") ?? {};
    if ((map[flavorID] ?? false) === soldOut) return null;
    map[flavorID] = soldOut;
    this.putMeta("soldOut", map);
    this.commit({ kind: "flavors", flavors: this.flavors() });

    const key = `soldout:${flavorID}`;
    for (const row of this.unresolved(key)) this.updateAlert(row.id, { resolved_at: now }, now);
    this.createAlert({
      key,
      kind: "soldout",
      severity: "info",
      title: soldOut ? `${flavor.name} is sold out` : `${flavor.name} is back`,
      detail: `${soldOut ? "Greyed out" : "Available again"} on the kiosk${by ? `, set by ${by}` : ""}.`,
    }, now);
    return null;
  }

  private kioskContact(now: number, update: { connected?: boolean; screen?: string }) {
    const kiosk = this.kiosk();
    const next: KioskState = {
      ...kiosk,
      lastSeenAt: now,
      online: true,
      connected: update.connected ?? kiosk.connected,
      screen: update.screen ?? kiosk.screen,
    };
    const visible = next.online !== kiosk.online || next.connected !== kiosk.connected || next.screen !== kiosk.screen;
    if (visible) {
      this.setKiosk(next);
    } else {
      this.putMeta("kiosk", next);
    }
    if (!kiosk.online) {
      for (const row of this.unresolved("offline")) {
        this.updateAlert(row.id, { resolved_at: now, detail: `Back online after ${formatDuration(now - row.created_at)}.` }, now);
      }
    }
  }

  /** Raises Kiosk offline and health alerts once their deadlines pass, then arms the alarm for the next one. */
  async evaluate(now: number): Promise<void> {
    const kiosk = this.kiosk();
    const deadlines: number[] = [];

    if (kiosk.lastSeenAt !== null && kiosk.online) {
      const silentFor = now - kiosk.lastSeenAt;
      if (silentFor >= OFFLINE_AFTER_MS) {
        this.setKiosk({ ...kiosk, online: false });
        if (this.unresolved("offline").length === 0) {
          this.createAlert({
            key: "offline",
            kind: "offline",
            severity: "urgent",
            title: "Kiosk offline",
            detail: `No contact for ${Math.round(silentFor / 1000)} s. Check the iPad, its Wi-Fi and the app.`,
          }, now);
        }
      } else {
        deadlines.push(kiosk.lastSeenAt + OFFLINE_AFTER_MS);
      }
    }

    const online = this.kiosk().online;
    const conditions = healthConditions(kiosk.health);
    const stored = this.getMeta<Record<string, number>>("conditions") ?? {};
    const pending: Record<string, number> = {};
    for (const row of this.sql.exec<AlertRow>("SELECT * FROM alerts WHERE kind = 'health' AND resolved_at IS NULL").toArray()) {
      if (!conditions.has(row.key)) this.updateAlert(row.id, { resolved_at: now }, now);
    }
    for (const [key, condition] of conditions) {
      pending[key] = stored[key] ?? now;
      const open = this.unresolved(key)[0];
      if (open) {
        if (open.title !== condition.title || open.detail !== condition.detail) {
          this.updateAlert(open.id, { title: condition.title, detail: condition.detail }, now, false);
        }
      } else if (online && now - pending[key] >= HEALTH_GRACE_MS) {
        this.createAlert({ key, kind: "health", severity: "warning", ...condition }, now);
      } else if (online) {
        deadlines.push(pending[key] + HEALTH_GRACE_MS);
      }
    }
    this.putMeta("conditions", pending);

    if (deadlines.length > 0) {
      await this.ctx.storage.setAlarm(Math.max(Math.min(...deadlines), now + 1000));
    } else {
      await this.ctx.storage.deleteAlarm();
    }
  }

  // MARK: Storage

  private state(now: number): BoothState {
    const alerts = this.sql
      .exec<AlertRow>(
        `SELECT * FROM alerts
         WHERE (acked_at IS NULL AND resolved_at IS NULL) OR updated_at > ?
         ORDER BY created_at DESC LIMIT 60`,
        now - RECENT_ALERTS_MS,
      )
      .toArray()
      .map(toAlert);
    return { rev: this.rev(), flavors: this.flavors(), kiosk: this.kiosk(), alerts, serverTime: now };
  }

  private rev(): number {
    return this.getMeta<number>("rev") ?? 0;
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

  private createAlert(input: { key: string; kind: AlertKind; severity: Severity; title: string; detail: string }, now: number): Alert {
    const row = this.sql
      .exec<AlertRow>(
        `INSERT INTO alerts (id, key, kind, severity, title, detail, count, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?) RETURNING *`,
        crypto.randomUUID(),
        input.key,
        input.kind,
        input.severity,
        input.title,
        input.detail,
        now,
        now,
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
  }

  private kiosk(): KioskState {
    const stored = { ...EMPTY_KIOSK, ...this.getMeta<Partial<KioskState>>("kiosk") };
    return {
      connected: stored.connected,
      online: stored.online,
      lastSeenAt: stored.lastSeenAt,
      screen: stored.screen,
      health: stored.health,
      healthAt: stored.healthAt,
    };
  }

  private setKiosk(kiosk: KioskState) {
    this.putMeta("kiosk", kiosk);
    this.commit({ kind: "kiosk", kiosk });
  }

  private flavorList(): { id: string; name: string }[] {
    return this.getMeta<{ id: string; name: string }[]>("flavors") ?? DEFAULT_FLAVORS;
  }

  private flavors(): FlavorState[] {
    const soldOut = this.getMeta<Record<string, boolean>>("soldOut") ?? {};
    return this.flavorList().map((f) => ({ ...f, soldOut: soldOut[f.id] ?? false }));
  }

  private setFlavorList(list: { id: string; name: string }[]) {
    if (JSON.stringify(this.flavorList()) === JSON.stringify(list)) return;
    this.putMeta("flavors", list);
    this.commit({ kind: "flavors", flavors: this.flavors() });
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

function formatDuration(ms: number): string {
  const seconds = Math.round(ms / 1000);
  if (seconds < 90) return `${seconds} s`;
  return `${Math.round(seconds / 60)} min`;
}
