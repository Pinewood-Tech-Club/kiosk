# Booth protocol, version 1

The booth backend is an HTTP API plus one websocket hub. It has no UI. Two kinds of client use it:

- **kiosk**: the customer-facing iPad. It reports heartbeats, health, help requests, log lines and paid orders, and reads the sold-out map.
- **staff**: an iPad running the same app in the staff role (for the toppings person). It reads alerts, kiosk health and the sold-out map, acknowledges alerts and toggles sold-out flavors.

Base URL: `https://techclub-icecream.adamxu.workers.dev`. Every path is under `/v1/`. A breaking change gets a new prefix (`/v2/`) and both are served until every client has moved.

The kiosk must work fully without the backend. Nothing in ordering or payment waits for, or fails because of, a booth call; booth features degrade silently.

## Auth

Every route except `GET /v1/health` and every websocket needs:

| Header | Value |
| --- | --- |
| `Authorization` | `Bearer <token>`. The kiosk token (`BOOTH_TOKEN`) gives the `kiosk` role, the staff token (`STAFF_TOKEN`) the `staff` role. |
| `X-Booth-Device` | A stable id for this install (1 to 64 of `A-Z a-z 0-9 . _ -`), generated once and persisted. Used for rate limits, ordering and dedupe. |

A missing or wrong token is `401`. A valid token used on a route its role can't use is `403`. Rate limits are per role and device; over the limit is `429` with `Retry-After`.

## Errors

Every non-2xx response has the same body:

```json
{ "error": { "code": "bad_request", "message": "events[0].reason: Invalid option", "retryable": false } }
```

| Status | `code` | Retry? |
| --- | --- | --- |
| 400 | `bad_request` (malformed JSON, failed validation) | No. Fix or drop the item. |
| 401 | `unauthorized` | No (until the token is fixed). Back off slowly. |
| 403 | `forbidden` | No. |
| 404 | `not_found` | No. |
| 413 | `too_large` | No. Send smaller batches. |
| 429 | `rate_limited` | Yes, after `Retry-After`. |
| 500, 503 | `internal`, `unavailable` (D1 or the hub failed) | Yes, with backoff. |

Network errors and timeouts are always retryable. Clients retry with exponential backoff and jitter (1 s doubling to a 60 s cap, times a random 0.5 to 1.5).

## Idempotency and ordering

- Every event, action, log line and order carries a client-generated `id` (a UUID, or another string unique for that device, at most 64 characters). The server stores each id it has processed and answers a replay with the original result (`duplicate`), so retries never double-count. Orders and log lines are unique keys in D1; events and actions are remembered by the hub for 7 days.
- Every kiosk event also carries `seq`, a per-device counter that only increases (persist it next to the device id; a new device id starts again at 1). Health snapshots are applied only if their `seq` is higher than the last applied one for that device, so a delayed or replayed snapshot can't overwrite a newer one (`stale`). Help requests are each their own alert and don't depend on order.
- Clients send queued items oldest first and stop at the first retryable failure, so a device's items arrive in order.
- Client clocks are informational only. The server orders, merges and times out on its own clock; client timestamps (`at`, `ts`, `paidAt`) are stored as reported and may be skewed.

## Hub state and revisions

The hub keeps one state document and a revision number `rev` that increases by exactly 1 with every change:

```ts
interface BoothState {
  rev: number;
  flavors: { id: string; name: string; soldOut: boolean }[]; // order is display order
  kiosk: {
    connected: boolean;           // a kiosk websocket is open
    online: boolean;              // heard from within the last 30 s
    lastSeenAt: number | null;    // server ms of the last kiosk contact (heartbeat, event or upload)
    screen: string | null;
    health: KioskHealth | null;
    healthAt: number | null;
  };
  alerts: Alert[];                // open alerts, plus closed ones from the last 3 hours (newest first, at most 60)
  serverTime: number;
}

interface Alert {
  id: string;
  key: string;                    // "help:button", "offline", "health:reader", "soldout:chocolate", ...
  kind: "help" | "offline" | "health" | "soldout";
  severity: "urgent" | "warning" | "info";
  title: string;
  detail: string;
  count: number;                  // repeats merged into this alert
  createdAt: number;
  updatedAt: number;
  ackedAt: number | null;
  ackedBy: string | null;
  resolvedAt: number | null;      // closed by the server (condition cleared, kiosk back online, superseded)
}
```

An alert is **open** while `ackedAt` and `resolvedAt` are both null.

Alerts the hub raises:

| `kind` | When | Closes |
| --- | --- | --- |
| `help` (urgent) | A kiosk help event. Another help with the same reason within 2 min of an open one bumps `count` instead. | When acknowledged. |
| `offline` (urgent) | No kiosk contact for 30 s (checked by a Durable Object alarm). | Resolved by the next kiosk contact. |
| `health` (warning) | A health problem that lasts 45 s: Square not authorized, no reader ready (real payments only), reader or iPad battery at or under 20 % and not charging, catalog error. | Resolved when the condition clears. |
| `soldout` (info) | A flavor is marked sold out or back. | Superseded by the next change to that flavor. |

## WebSocket: `GET /v1/ws`

Open with the auth headers above. The server sends a `snapshot` immediately, then a `patch` for every change.

Server to client:

```jsonc
{ "type": "snapshot", "state": BoothState }
{ "type": "patch", "rev": 42, "change": Change }
{ "type": "pong", "t": 1791700000000, "rev": 42, "serverTime": 1791700000123, "kioskLastSeenAt": 1791699995000 }
{ "type": "result", "id": "<event or action id>", "status": "ok" | "duplicate" | "stale" | "rejected", "alertId": "...", "error": {...} }
{ "type": "error", "error": { "code": "bad_request", "message": "..." } }
```

`Change` is one of:

```jsonc
{ "kind": "flavors", "flavors": [{ "id": "vanilla", "name": "Vanilla", "soldOut": false }] }   // the whole list
{ "kind": "alert", "alert": Alert }                                                          // insert or replace by id
{ "kind": "kiosk", "kiosk": KioskState }                                                     // the whole kiosk object
```

Client rules, which make every client converge on the hub's state:

1. On `snapshot`, replace local state and set `rev` from it.
2. On `patch`: ignore it if `rev` is at or below the local rev (stale or duplicate). Apply it if it is exactly local rev + 1. If it is further ahead, a patch was missed: send `{"type":"sync"}` and wait for the snapshot.
3. On `pong`, if its `rev` is ahead of the local rev, send `sync`.
4. Persist what the app needs while offline (the kiosk keeps the sold-out map), and keep using it until a snapshot arrives.

Client to server:

```jsonc
{ "type": "heartbeat", "t": 1791700000000, "screen": "builder" }   // kiosk, every 10 s; answered with pong
{ "type": "ping", "t": 1791700000000 }                              // any role; answered with pong
{ "type": "sync" }                                                  // answered with a snapshot
{ "type": "event", "event": Event }                                 // kiosk; answered with result
{ "type": "action", "action": Action }                              // staff; answered with result
```

Liveness: clients send `heartbeat` or `ping` every 10 s and treat 25 s without any message from the server as a dead socket: close it and reconnect. Reconnect with backoff (1 s doubling to 30 s, with jitter), and at once when the app returns to the foreground or the network path comes back. The server treats 30 s without kiosk contact as offline. Text frames over 64 KB are rejected, and a socket that floods (more than 60 messages in 10 s) gets an error and is closed with code 1008.

## Kiosk events: `POST /v1/events` (kiosk)

```jsonc
{ "events": [Event, ...] }        // 1 to 100 events, at most 256 KB
```

```jsonc
{ "id": "6F1C...", "seq": 17, "type": "help", "at": "2026-12-05T13:02:11.120-08:00",
  "reason": "button" | "payment_failed" | "no_reader" | "idle", "message": "Customer pressed the help button" }
{ "id": "7A2B...", "seq": 18, "type": "health", "at": "...", "health": KioskHealth }
```

```ts
interface KioskHealth {
  appVersion: string; environment: string;          // "Sandbox" | "Production" | "No credentials"
  authorized: boolean; authorizationState: string;
  readers: { name: string; model?: string; state: string; batteryPercent: number | null; isCharging: boolean | null }[];
  readerReady: boolean;
  catalog: { ok: boolean; status: string; error: string | null };
  deviceBattery: { percent: number; charging: boolean } | null;
  simulatePayment: boolean; screen: string;
  lastError: string | null; lastErrorAt: string | null;
  flavors?: { id: string; name: string }[];          // the kiosk's flavor list, in display order
}
```

Response `200`:

```json
{ "results": [{ "id": "6F1C...", "status": "ok", "alertId": "..." }, { "id": "7A2B...", "status": "stale" }], "rev": 42 }
```

Each item is `ok`, `duplicate` (already processed; same `alertId`), `stale` (an older health snapshot; dropped) or `rejected` (failed validation; carries `error`, don't retry it). A whole-request `400` means the envelope itself was bad.

## Staff actions: `POST /v1/actions` (staff)

```jsonc
{ "actions": [Action, ...] }      // 1 to 50
{ "id": "...", "type": "ack", "alertId": "...", "by": "Maya" }
{ "id": "...", "type": "setSoldOut", "flavor": "chocolate", "soldOut": true, "by": "Maya" }
```

Response `200`: `{ "results": [{ "id": "...", "status": "ok" | "duplicate" | "rejected", "error"?: {...} }], "rev": 43 }`. Acking an already acknowledged alert is `ok` and changes nothing. `setSoldOut` is last-writer-wins in the order the hub receives it.

## Logs: `POST /v1/logs` (kiosk)

```jsonc
{ "appVersion": "0.1 (1)", "lines": [{ "id": "<device>-<file>-<offset>", "ts": "2026-12-05T13:02:11.120-08:00",
  "level": "debug" | "info" | "warn" | "error", "message": "...", "context": { } }] }
```

1 to 500 lines, at most 1 MB; `message` is cut at 8 KB and `context` at 8 KB of JSON. Response: `{ "accepted": 3, "stored": 2, "duplicates": 1 }`. Lines are kept 30 days and also written to Workers Logs.

## Orders: `POST /v1/orders` (kiosk)

```jsonc
{ "orders": [{
  "id": "<uuid>", "orderNumber": 12, "squareOrderId": "...", "squarePaymentId": "...", "customerName": "Alex",
  "totalCents": 900, "subtotalCents": 900, "taxCents": 0, "card": "Visa 1111", "simulated": false,
  "paidAt": "2026-12-05T13:02:11Z", "appVersion": "0.1 (1)",
  "items": [{ "vessel": "cone", "flavors": ["vanilla", "chocolate"] }],
  "lines": [{ "title": "1 Scoop", "detail": "#1 Waffle Cone: Vanilla", "cents": 400 }] }] }
```

1 to 50 orders. Response: `{ "results": [{ "id": "...", "status": "ok" | "duplicate" | "rejected" }] }`. An order is a duplicate if its `id` or its `squarePaymentId` was stored before. Orders are never alerts.

`GET /v1/orders?since=<ms>&limit=<n>` (staff) lists orders paid since `since`, newest first, with the count and total of real (not simulated) orders.

## Other routes

- `GET /v1/state` (any role): the current `BoothState`.
- `GET /v1/health` (no auth): `{ "ok": true, "service": "techclub-icecream", "protocol": 1, "time": ... }`. With a token, `?deep=1` also checks D1 and the hub.
