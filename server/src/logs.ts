import { authenticate, json, noteKioskContact, readBody, withRetry, type Client, type Route } from "./http";
import { LogLine, LogsBody, parseTimestamp } from "./schema";

const D1_CHUNK = 50;

async function ingestLogs(request: Request, env: Env, client: Client): Promise<Response> {
  const body = await readBody(request, LogsBody, 1024 * 1024);
  const now = Date.now();
  const statement = env.DB.prepare(
    "INSERT OR IGNORE INTO logs (id, device, app_version, ts, level, message, context, received_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
  );
  const rows: D1PreparedStatement[] = [];
  let rejected = 0;
  for (const item of body.lines) {
    const parsed = LogLine.safeParse(item);
    if (!parsed.success) {
      rejected++;
      continue;
    }
    const line = parsed.data;
    const ts = parseTimestamp(line.ts, now);
    const context = line.context ? JSON.stringify(line.context).slice(0, 8 * 1024) : null;
    rows.push(statement.bind(line.id, client.device, body.appVersion ?? null, ts, line.level, line.message, context, now));
    const entry = { source: "kiosk", device: client.device, appVersion: body.appVersion, ts: new Date(ts).toISOString(), level: line.level, message: line.message, context: line.context };
    if (line.level === "error") console.error(entry);
    else if (line.level === "warn") console.warn(entry);
    else console.log(entry);
  }
  let stored = 0;
  for (let i = 0; i < rows.length; i += D1_CHUNK) {
    const chunk = rows.slice(i, i + D1_CHUNK);
    const results = await withRetry("D1", () => env.DB.batch(chunk));
    stored += results.reduce((sum, r) => sum + (r.meta.changes ?? 0), 0);
  }
  return json({ accepted: rows.length, stored, duplicates: rows.length - stored, rejected });
}

export async function pruneLogs(env: Env): Promise<void> {
  const days = Number(env.LOG_RETENTION_DAYS) || 30;
  const cutoff = Date.now() - days * 24 * 60 * 60 * 1000;
  try {
    const result = await withRetry("D1", () => env.DB.prepare("DELETE FROM logs WHERE ts < ?").bind(cutoff).run());
    console.log({ event: "log-retention", deleted: result.meta.changes, cutoff: new Date(cutoff).toISOString() });
  } catch (error) {
    console.error({ event: "log-retention-failed", error: String(error) });
  }
}

export const routes: Route[] = [
  {
    method: "POST",
    path: "/v1/logs",
    async handle({ request, env, ctx }) {
      const client = await authenticate(request, env, ["kiosk"]);
      const response = await ingestLogs(request, env, client);
      noteKioskContact(env, ctx);
      return response;
    },
  },
];
