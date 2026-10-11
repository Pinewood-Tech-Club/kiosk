import { DurableObject } from "cloudflare:workers";
import {
  DEFAULT_FLAVORS,
  HELP_TITLES,
  parseClientMessage,
  type Alert,
  type AlertKind,
  type BoothState,
  type ClientMessage,
  type Flavor,
  type HelpReason,
  type KioskHealth,
  type KioskState,
  type Role,
  type ServerMessage,
  type Severity,
} from "./protocol";

export const OFFLINE_AFTER_MS = 30_000;
export const HEALTH_GRACE_MS = 20_000;
export const HELP_MERGE_MS = 2 * 60_000;
export const LOW_BATTERY_PERCENT = 20;
const RECENT_ALERTS_MS = 3 * 60 * 60_000;
const ALERT_RETENTION_MS = 7 * 24 * 60 * 60_000;

interface Attachment {
  role: Role;
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
  client_id: string | null;
  [column: string]: SqlStorageValue;
}

const EMPTY_KIOSK: KioskState = {
  connected: false,
  online: false,
  lastHeartbeatAt: null,
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

export function healthConditions(health: KioskHealth | null): Map<string, Condition> {
  const conditions = new Map<string, Condition>();
  if (!health) return conditions;
  const squareConfigured = health.environment !== undefined && health.environment !== "No credentials";
  const realPayments = squareConfigured && health.simulatePayment !== true;
  if (squareConfigured && health.authorized === false) {
    conditions.set("health:auth", {
      title: "Square isn't authorized",
      detail: `Authorization: ${health.authorizationState ?? "not authorized"}. Card payments will fail.`,
    });
  }
  if (realPayments && health.readerReady === false) {
    const readers = health.readers ?? [];
    conditions.set("health:reader", {
      title: "No card reader ready",
      detail: readers.length === 0
        ? "No reader is paired with the kiosk."
        : readers.map((r) => `${r.name}: ${r.state}`).join(", "),
    });
  }
  const lowReader = (health.readers ?? []).find(
    (r) => typeof r.batteryPercent === "number" && r.batteryPercent <= LOW_BATTERY_PERCENT && r.isCharging !== true,
  );
  if (lowReader) {
    conditions.set("health:reader-battery", {
      title: `Card reader battery low (${lowReader.batteryPercent}%)`,
      detail: `${lowReader.name} needs charging.`,
    });
  }
  const ipad = health.deviceBattery;
  if (ipad && ipad.percent >= 0 && ipad.percent <= LOW_BATTERY_PERCENT && !ipad.charging) {
    conditions.set("health:ipad-battery", {
      title: `Kiosk iPad battery low (${ipad.percent}%)`,
      detail: "Plug the kiosk iPad in.",
    });
  }
  if (health.catalog && health.catalog.ok === false) {
    conditions.set("health:catalog", {
      title: "Square catalog error",
      detail: health.catalog.error ?? health.catalog.status ?? "Orders fall back to ad-hoc line items.",
    });
  }
  return conditions;
}

export class Booth extends DurableObject<Env> {
  private sql: SqlStorage;

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
          resolved_at INTEGER,
          client_id TEXT UNIQUE
        );
        CREATE INDEX IF NOT EXISTS alerts_key ON alerts (key, resolved_at);
        CREATE INDEX IF NOT EXISTS alerts_updated ON alerts (updated_at);
      `);
    });
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async fetch(request: Request): Promise<Response> {
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("Expected a websocket upgrade", { status: 426 });
    }
    const role = request.headers.get("X-Booth-Role");
    if (role !== "kiosk" && role !== "staff") {
      return new Response("Missing role", { status: 400 });
    }
    const now = Date.now();
    const { 0: client, 1: server } = new WebSocketPair();

    if (role === "kiosk") {
      for (const old of this.ctx.getWebSockets("kiosk")) {
        try {
          old.close(4000, "Replaced by a newer kiosk connection");
        } catch {}
      }
    }
    this.ctx.acceptWebSocket(server, [role]);
    server.serializeAttachment({ role, connectedAt: now } satisfies Attachment);

    this.pruneAlerts(now);
    if (role === "kiosk") {
      // Restart the health grace periods: a relaunching app briefly reports no reader, and that must not
      // count against the time it was away.
      this.putMeta("conditions", {});
      this.setKiosk({ ...this.kiosk(), connected: true });
      this.broadcastKiosk();
    }
    this.send(server, { type: "snapshot", state: this.state(now) });

    const headers = new Headers();
    const protocols = request.headers.get("Sec-WebSocket-Protocol");
    if (protocols?.split(",").some((p) => p.trim() === "booth.v1")) {
      headers.set("Sec-WebSocket-Protocol", "booth.v1");
    }
    return new Response(null, { status: 101, webSocket: client, headers });
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const attachment = ws.deserializeAttachment() as Attachment | null;
    if (!attachment) return;
    if (typeof message !== "string") {
      this.send(ws, { type: "error", message: "Binary messages aren't supported" });
      return;
    }
    const parsed = parseClientMessage(message, attachment.role);
    if (typeof parsed === "string") {
      this.send(ws, { type: "error", message: parsed });
      return;
    }
    await this.handle(parsed, ws);
  }

  async webSocketClose(ws: WebSocket): Promise<void> {
    this.socketGone(ws);
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    this.socketGone(ws);
  }

  async alarm(): Promise<void> {
    await this.evaluate(Date.now());
  }

  async getState(): Promise<BoothState> {
    return this.state(Date.now());
  }

  async handle(message: ClientMessage, ws: WebSocket | null, now = Date.now()): Promise<void> {
    switch (message.type) {
      case "heartbeat":
        this.heartbeat(now, message.screen);
        if (ws) this.send(ws, { type: "pong", at: now });
        await this.evaluate(now);
        break;
      case "health":
        this.recordHealth(message.health, now);
        await this.evaluate(now);
        break;
      case "help": {
        const alert = this.help(message.id, message.reason, message.message, now);
        if (ws) this.send(ws, { type: "helpReceived", id: message.id, alertId: alert.id });
        break;
      }
      case "ack":
        this.ack(message.id, message.by ?? null, now);
        break;
      case "setSoldOut": {
        const error = this.setSoldOut(message.flavor, message.soldOut, message.by ?? null, now);
        if (error && ws) this.send(ws, { type: "error", message: error });
        break;
      }
    }
  }

  private heartbeat(now: number, screen: string | undefined) {
    const kiosk = this.kiosk();
    const wasOffline = !kiosk.online;
    this.setKiosk({ ...kiosk, online: true, connected: true, lastHeartbeatAt: now, screen: screen ?? kiosk.screen });
    if (wasOffline) {
      for (const row of this.unresolved("offline")) {
        this.updateAlert(row.id, { resolved_at: now, detail: `Back online after ${formatDuration(now - row.created_at)}.` }, now);
      }
    }
    this.broadcastKiosk();
  }

  private recordHealth(health: KioskHealth, now: number) {
    if (health.flavors) this.setFlavors(health.flavors);
    this.setKiosk({ ...this.kiosk(), connected: true, health, healthAt: now, screen: health.screen ?? this.kiosk().screen });
    this.broadcastKiosk();
  }

  private help(clientID: string, reason: HelpReason, message: string | undefined, now: number): Alert {
    const existing = this.sql.exec<AlertRow>("SELECT * FROM alerts WHERE client_id = ?", clientID).toArray()[0];
    if (existing) return toAlert(existing);
    const key = `help:${reason}`;
    const detail = message?.trim() || "From the kiosk.";
    const recent = this.sql
      .exec<AlertRow>(
        "SELECT * FROM alerts WHERE key = ? AND acked_at IS NULL AND resolved_at IS NULL AND updated_at > ? ORDER BY updated_at DESC LIMIT 1",
        key,
        now - HELP_MERGE_MS,
      )
      .toArray()[0];
    if (recent) {
      return this.updateAlert(recent.id, { count: recent.count + 1, detail }, now);
    }
    return this.createAlert({ key, kind: "help", severity: "urgent", title: HELP_TITLES[reason], detail, clientID }, now);
  }

  private ack(id: string, by: string | null, now: number) {
    const row = this.sql.exec<AlertRow>("SELECT * FROM alerts WHERE id = ?", id).toArray()[0];
    if (!row || row.acked_at !== null) return;
    this.updateAlert(id, { acked_at: now, acked_by: by }, now);
  }

  private setSoldOut(flavorID: string, soldOut: boolean, by: string | null, now: number): string | null {
    const flavor = this.flavors().find((f) => f.id === flavorID);
    if (!flavor) return `Unknown flavor ${flavorID}`;
    const map = this.soldOutMap();
    if ((map[flavorID] ?? false) === soldOut) return null;
    map[flavorID] = soldOut;
    this.putMeta("soldOut", map);
    this.broadcast({ type: "soldOut", soldOut: this.soldOutFor(this.flavors()), flavor: flavorID, value: soldOut, by });

    const key = `soldout:${flavorID}`;
    const title = soldOut ? `${flavor.name} is sold out` : `${flavor.name} is back`;
    const detail = `${soldOut ? "Greyed out" : "Available again"} on the kiosk${by ? `, set by ${by}` : ""}.`;
    for (const row of this.unresolved(key)) {
      this.updateAlert(row.id, { resolved_at: now }, now);
    }
    this.createAlert({ key, kind: "soldout", severity: "info", title, detail }, now);
    return null;
  }

  async evaluate(now: number): Promise<void> {
    const kiosk = this.kiosk();
    const deadlines: number[] = [];

    if (kiosk.lastHeartbeatAt !== null) {
      const silentFor = now - kiosk.lastHeartbeatAt;
      if (kiosk.online && silentFor >= OFFLINE_AFTER_MS) {
        this.setKiosk({ ...kiosk, online: false });
        this.broadcastKiosk();
        if (this.unresolved("offline").length === 0) {
          this.createAlert({
            key: "offline",
            kind: "offline",
            severity: "urgent",
            title: "Kiosk offline",
            detail: `No heartbeat for ${Math.round(silentFor / 1000)} s. Check the iPad, its Wi-Fi and the app.`,
          }, now);
        }
      } else if (kiosk.online) {
        deadlines.push(kiosk.lastHeartbeatAt + OFFLINE_AFTER_MS);
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

  private socketGone(ws: WebSocket) {
    const attachment = ws.deserializeAttachment() as Attachment | null;
    if (attachment?.role !== "kiosk") return;
    const others = this.ctx.getWebSockets("kiosk").filter((s) => s !== ws && s.readyState === WebSocket.OPEN);
    if (others.length === 0) {
      this.setKiosk({ ...this.kiosk(), connected: false });
      this.broadcastKiosk();
    }
  }

  private state(now: number): BoothState {
    const flavors = this.flavors();
    const soldOut = this.soldOutFor(flavors);
    const alerts = this.sql
      .exec<AlertRow>(
        `SELECT * FROM alerts
         WHERE (acked_at IS NULL AND resolved_at IS NULL) OR updated_at > ?
         ORDER BY created_at DESC LIMIT 60`,
        now - RECENT_ALERTS_MS,
      )
      .toArray()
      .map(toAlert);
    return {
      flavors: flavors.map((f) => ({ ...f, soldOut: soldOut[f.id] })),
      soldOut,
      kiosk: this.kiosk(),
      alerts,
      serverTime: now,
    };
  }

  private createAlert(
    input: { key: string; kind: AlertKind; severity: Severity; title: string; detail: string; clientID?: string },
    now: number,
  ): Alert {
    const row = this.sql
      .exec<AlertRow>(
        `INSERT INTO alerts (id, key, kind, severity, title, detail, count, created_at, updated_at, client_id)
         VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?, ?) RETURNING *`,
        crypto.randomUUID(),
        input.key,
        input.kind,
        input.severity,
        input.title,
        input.detail,
        now,
        now,
        input.clientID ?? null,
      )
      .one();
    const alert = toAlert(row);
    console.log({ event: "alert", alert });
    this.broadcast({ type: "alert", alert });
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
    this.broadcast({ type: "alert", alert });
    return alert;
  }

  private unresolved(key: string): AlertRow[] {
    return this.sql.exec<AlertRow>("SELECT * FROM alerts WHERE key = ? AND resolved_at IS NULL", key).toArray();
  }

  private pruneAlerts(now: number) {
    this.sql.exec(
      "DELETE FROM alerts WHERE created_at < ? AND (acked_at IS NOT NULL OR resolved_at IS NOT NULL)",
      now - ALERT_RETENTION_MS,
    );
  }

  private kiosk(): KioskState {
    return { ...EMPTY_KIOSK, ...this.getMeta<KioskState>("kiosk") };
  }

  private setKiosk(kiosk: KioskState) {
    this.putMeta("kiosk", kiosk);
  }

  private flavors(): Flavor[] {
    return this.getMeta<Flavor[]>("flavors") ?? DEFAULT_FLAVORS;
  }

  private setFlavors(flavors: Flavor[]) {
    const current = this.flavors();
    if (JSON.stringify(current) === JSON.stringify(flavors)) return;
    this.putMeta("flavors", flavors);
    this.broadcast({ type: "snapshot", state: this.state(Date.now()) });
  }

  private soldOutMap(): Record<string, boolean> {
    return this.getMeta<Record<string, boolean>>("soldOut") ?? {};
  }

  private soldOutFor(flavors: Flavor[]): Record<string, boolean> {
    const map = this.soldOutMap();
    return Object.fromEntries(flavors.map((f) => [f.id, map[f.id] ?? false]));
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

  private broadcastKiosk() {
    this.broadcast({ type: "kiosk", kiosk: this.kiosk() });
  }

  private broadcast(message: ServerMessage) {
    const json = JSON.stringify(message);
    for (const ws of this.ctx.getWebSockets()) {
      try {
        ws.send(json);
      } catch {}
    }
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
