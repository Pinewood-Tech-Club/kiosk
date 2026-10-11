# Booth protocol, version 1

The booth backend is an HTTP API plus one websocket hub. Two kinds of client use it:

- **kiosk**: the customer-facing iPad. It reports heartbeats, health, help requests, log lines and paid orders, and reads the sold-out map.
- **staff**: an iPad running the same app in the staff role (for the toppings person), and the web dashboard. It reads alerts, kiosk health, the sold-out map and the order feed, acknowledges alerts, toggles sold-out flavors and moves orders through their statuses.

It also owns the Square connection: the OAuth flow, token storage and refresh, and Square order creation for the kiosk.

Base URL: `https://kiosk.jamboree.techclub.pw`. Every API path is under `/v1/`. A breaking change gets a new prefix (`/v2/`) and both are served until every client has moved. Three browser-facing paths live outside `/v1/`: `/r/<token>` (receipts), `/dashboard` (staff dashboard) and the OAuth callback page.

Everything below marked *(added)* was added to protocol 1 without breaking older clients: new fields are optional for senders and ignorable for readers, and clients ignore unknown `Change` kinds (they still advance `rev`).

The kiosk must work fully without the backend. Nothing in ordering or payment waits for, or fails because of, a booth call; booth features degrade silently.

## Auth

Every route except `GET /v1/health`, `POST /v1/staff/session`, the OAuth callback and the browser pages (`/r/...`, `/dashboard`) needs, including the websocket:

| Header | Value |
| --- | --- |
| `Authorization` | `Bearer <token>`. The kiosk token (`BOOTH_TOKEN`) gives the `kiosk` role; the staff token (`STAFF_TOKEN`) or a staff session token gives the `staff` role. |
| `X-Booth-Device` | A stable id for this install (1 to 64 of `A-Z a-z 0-9 . _ -`), generated once and persisted. Used for rate limits, ordering and dedupe. |

A missing or wrong token is `401`. A valid token used on a route its role can't use is `403`. Rate limits are per role and device; over the limit is `429` with `Retry-After`.

**Staff sessions** *(added)*. Staff can sign in with the staff PIN (`STAFF_PIN`, or the staff token itself) instead of holding `STAFF_TOKEN`:

- `POST /v1/staff/session` (no auth) with `{ "pin": "..." }` returns `{ "token": "st1....", "expiresAt": <ms> }`. The token is a bearer token for the `staff` role, valid 72 hours, signed with a key derived from `STAFF_TOKEN` (rotating `STAFF_TOKEN` signs everyone out). The staff iPad keeps it in the Keychain. Wrong PIN is `401`; more than 10 attempts a minute from one IP is `429`.
- The dashboard gets the same token as an `HttpOnly; Secure; SameSite=Strict` cookie named `booth_staff` from `POST /dashboard/login` (form field `pin`). The cookie is accepted on `/v1/` routes for the `staff` role only; any non-GET request authenticated by cookie must carry an `Origin` header equal to the server's origin. Without `X-Booth-Device`, a cookie client's device is `web-<session id>`.

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
| 409 | `conflict` (an id reused with different content), `location_mismatch` (checkout for a location the server isn't using) *(added)* | No. |
| 413 | `too_large` | No. Send smaller batches. |
| 429 | `rate_limited` | Yes, after `Retry-After`. |
| 500, 503 | `internal`, `unavailable` (D1, the hub or Square failed) | Yes, with backoff. |
| 502 | `square_rejected`, `square_unauthorized` (Square refused the request or the token) *(added)* | No. |
| 503 | `not_configured` (Square isn't connected or OAuth secrets aren't set; `retryable: false`) *(added)* | Not soon. Use a fallback. |

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
  orders: OrderSummary[];         // (added) open orders, plus ones changed in the last 3 hours (newest paid first, at most 100)
  serverTime: number;
}

interface OrderSummary {          // (added)
  id: string;                     // the kiosk's checkout id
  orderNumber: number | null;
  customerName: string | null;
  items: { vessel: string; flavors: string[]; toppings: string[] }[];
  totalCents: number;
  simulated: boolean;
  paidAt: number;                 // kiosk clock (ms), consistent between that kiosk's orders
  receivedAt: number;             // server ms when the order was first stored
  status: OrderStatus;
  statusAt: number;
  statusBy: string | null;
}

type OrderStatus = "paid" | "preparing" | "ready" | "collected" | "canceled";

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

**Order lifecycle** *(added)*. A checkout (`POST /v1/checkout`) creates an unpaid Square order; it lives only in the `checkouts` table and never reaches staff. When the kiosk reports the order paid (`POST /v1/orders`), it enters the feed as `paid` and a `{ kind: "order" }` patch goes to every client. Staff then move it with `setOrderStatus`:

```
paid ──▶ preparing ──▶ ready ──▶ collected
  └──────────┴──────────┴──────▶ canceled
```

Open statuses are `paid`, `preparing` and `ready`. The hub accepts any status from any status (last writer wins, so a mistaken tap can be undone); the arrows are the intended flow. New paid orders are never alerts. The hub's copy is what staff see live; D1's `orders.status` is updated best-effort after each change and is what stats read.

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
{ "kind": "order", "order": OrderSummary }                                                   // (added) insert or replace by id
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
{ "id": "...", "type": "setOrderStatus", "orderId": "<checkout id>", "status": "ready", "by": "Maya" }   // (added)
```

Response `200`: `{ "results": [{ "id": "...", "status": "ok" | "duplicate" | "rejected", "error"?: {...} }], "rev": 43 }`. The same actions can be sent one at a time over the websocket (`{"type":"action"}`), answered with `result`.

Acking an already acknowledged alert is `ok` and changes nothing. `setSoldOut` and `setOrderStatus` are last-writer-wins in the order the hub receives them; setting the status an order already has is `ok` and changes nothing. `setOrderStatus` for an order not in the feed is `rejected` with `not_found`.

Clients that queue offline should keep only the newest unsent `setSoldOut`/`setOrderStatus` per flavor or order, and not send over the websocket while an HTTP batch is in flight, so an older change can't land after a newer one. The staff iPad does both and keeps unsent actions on disk for up to 10 minutes.

## Logs: `POST /v1/logs` (kiosk)

```jsonc
{ "appVersion": "0.1 (1)", "lines": [{ "id": "<device>-<file>-<offset>", "ts": "2026-12-05T13:02:11.120-08:00",
  "level": "debug" | "info" | "warn" | "error", "message": "...", "context": { } }] }
```

1 to 500 lines, at most 1 MB; `message` is cut at 8 KB and `context` at 8 KB of JSON. Response: `{ "accepted": 3, "stored": 2, "duplicates": 1 }`. Lines are kept 30 days and also written to Workers Logs.

## Orders: `POST /v1/orders` (kiosk)

```jsonc
{ "orders": [{
  "id": "<checkout id>", "orderNumber": 12, "squareOrderId": "...", "squarePaymentId": "...", "customerName": "Alex",
  "totalCents": 900, "subtotalCents": 900, "taxCents": 0, "card": "Visa 1111", "simulated": false,
  "paidAt": "2026-12-05T13:02:11Z", "appVersion": "0.1 (1)",
  "receiptToken": "Qm9vdGhSZWNlaXB0VG9rZW4",                                     // (added) optional
  "items": [{ "vessel": "cone", "flavors": ["vanilla", "chocolate"], "toppings": ["sprinkles"] }],   // toppings (added) optional
  "lines": [{ "title": "1 Scoop", "detail": "#1 Waffle Cone: Vanilla", "cents": 400 }] }] }
```

1 to 50 orders. Response: `{ "results": [{ "id": "...", "status": "ok" | "duplicate" | "rejected" }] }`. An order is a duplicate if its `id`, its `squarePaymentId` or its `receiptToken` was stored before. Orders are never alerts. Every stored order (and a retried duplicate stored under the same `id`) is pushed into the hub's order feed, which ignores ones it already has; if the hub can't be reached the response is `503` and the kiosk's retry completes it.

`id` is the checkout id the kiosk generated when the customer pressed pay (the same id sent to `POST /v1/checkout`), so a receipt, a checkout and a paid order share one id.

`GET /v1/orders?since=<ms>&limit=<n>` (staff) lists orders paid since `since`, newest first, with the count and total of real (not simulated) orders. Each row also has `status`, `status_at` and `status_by`.

## Square credentials: `GET /v1/square/credentials` (kiosk) *(added)*

```json
{ "accessToken": "EAAA...", "locationId": "L...", "merchantId": "M..." , "expiresAt": 1793000000000, "environment": "sandbox",
  "applicationId": "sandbox-sq0idb-...", "source": "oauth", "fetchAgainAt": 1791701800000 }
```

`source` is `oauth` (the token from the OAuth flow, refreshed by the server) or `static` (the `SQUARE_ACCESS_TOKEN` fallback secret, for staging and tests; `merchantId` and `expiresAt` are then null). `503 not_configured` when neither exists. The kiosk fetches at launch and then at `fetchAgainAt` (at most every 30 minutes), keeps the last answer in the Keychain and uses it whenever the backend is unreachable. It ignores credentials whose `environment` or `applicationId` don't match its own build, and swaps the SDK's token only while the attract screen is showing. A fetch of a token that is due for refresh triggers a background refresh.

## Square OAuth *(added)*

The server holds the Square application secret and does the code flow. One Square account is connected per Worker (keyed by environment).

| Route | Auth | |
| --- | --- | --- |
| `POST /v1/square/oauth/start` | staff | `{ "url": "<Square authorize URL>", "environment", "expiresAt", "redirectUrl" }`. Open `url` in a browser within 10 minutes. |
| `GET /v1/square/oauth/start` | staff (cookie or bearer) | The same, as a `302` to Square. For a dashboard button. |
| `GET /v1/square/oauth/callback` | none (the `state` is the credential) | Square redirects here. Each `state` works once and expires after 10 minutes. Exchanges the code, picks the location (`SQUARE_LOCATION_ID` if set, else the first active location that takes cards), stores the tokens and shows a page saying what happened. |
| `GET /v1/square/status[?verify=1]` | staff | Configuration, active source, location, token expiry, last refresh and its error, `stale` (no refresh for 8 days). `verify=1` also calls Square to check the token. |
| `POST /v1/square/refresh` | staff | Refreshes now. `{ "status": "refreshed" \| "skipped" \| "failed", ... }`, `502` on failure. |
| `POST /v1/square/revoke` | staff | Revokes the token at Square and forgets it. The static fallback, if set, takes over. |

Scopes requested: `MERCHANT_PROFILE_READ PAYMENTS_READ PAYMENTS_WRITE PAYMENTS_WRITE_IN_PERSON ORDERS_READ ORDERS_WRITE ITEMS_READ`. Tokens are stored AES-GCM encrypted with a key derived from `SQUARE_APPLICATION_SECRET`. The daily cron refreshes a token once it is 6 days old (or within 21 days of expiry); a failed refresh keeps the old token, is logged as an error and shows in `status`.

## Checkout: `POST /v1/checkout` (kiosk) *(added)*

Creates the Square order for a cart, priced by the server, and returns what the Mobile Payments SDK needs.

```jsonc
{ "id": "<checkout id, a UUID>", "receiptToken": "<22 to 64 of A-Z a-z 0-9 _ ->", "orderNumber": 12, "customerName": "Alex",
  "sourceName": "Tech Club Ice Cream Kiosk", "locationId": "L...", "quotedCents": 1100,
  "items": [{ "vessel": "cone", "flavors": ["vanilla", "chocolate"], "toppings": ["whip"] }, { "vessel": "cup", "flavors": ["cookies"] }] }
```

1 to 20 items, 1 to 3 flavors and up to 10 toppings each. `locationId` (the location the kiosk's SDK is authorized for) and `quotedCents` (what the kiosk showed) are optional checks: a different location is `409 location_mismatch`; a different quote is only logged, because Square's total is what gets charged.

```json
{ "id": "...", "status": "created", "squareOrderId": "...", "locationId": "L...", "environment": "sandbox", "referenceId": "kiosk-0012",
  "totalCents": 1100, "taxCents": 0, "subtotalCents": 1100, "expectedSubtotalCents": 1100, "priceMatches": true,
  "usedCatalog": true, "catalogError": null, "receiptToken": "...",
  "lines": [{ "title": "1 Scoop", "detail": "#1 Waffle Cone: Vanilla", "quantity": 1, "baseCents": 400, "cents": 400 }] }
```

Pricing is the app's: scoops by position in the whole order ($4, $3, then $2 each), $1.50 per waffle cone, $0.50 per topping. Line items reference the catalog category `SQUARE_CATEGORY_NAME` (*1 Scoop*, *2nd Scoop*, *3rd+ Scoop*, *Waffle Cone*, *Topping*, cached 10 minutes, a stale copy up to a day old is used if Square fails); if it's missing or priced differently the order uses ad-hoc line items, exactly as the app does, and `catalogError` says why. Taxes are auto-applied by Square.

Idempotent by `id`: a retry returns the stored result with `status: "duplicate"` and no second Square call; the same `id` with a different cart is `409 conflict`. The Square idempotency key is the checkout id, so concurrent retries also get one Square order. The kiosk's own fallback uses `<id>-device`, so a slow backend answer and a device-created order never collide (an abandoned unpaid Square order is harmless).

The kiosk calls this first with a 3.5 s budget and creates the order on the device on any failure or timeout, skipping the backend for a minute afterwards. It only uses it when its SDK token came from the backend, so the order and the payment belong to the same merchant.

## Receipts: `GET /r/<receiptToken>` *(added)*

Public, no auth: the token is the credential. The kiosk generates it (128 random bits, base64url) when the customer pays, so it can show a QR code even with the backend down, and sends it with the checkout and the paid order (`receipts.ts` looks in `orders`, then `checkouts`). The response is a mobile-friendly HTML page (`noindex` in a meta tag and `X-Robots-Tag`, `no-store`): event name, order number, customer name, itemized lines (vessel, flavors, toppings, price), subtotal, tax, total, card, date and time in `America/Los_Angeles`, and a "View Square receipt" link when Square's payment has a `receipt_url` (looked up only for ids that look like Square payment ids, with a 2.5 s budget covering credentials too; the link is simply left out on failure). Per-item prices are Square's `#N`-tagged lines when they add up to the subtotal, else the app's pricing. An order a staff member set to `canceled` says "This order was canceled". A well-formed token that isn't an uploaded order yet (including one with only a checkout) gets `200` with "Your receipt will appear shortly" and a 10 s auto-refresh, since a kiosk may show the QR code while the backend was unreachable; if D1 can't be read the same page comes back with `503`. Only a malformed token gets `404`. The kiosk's URL is `Receipt.receiptURL` (`BOOTH_URL` + `/r/<token>`).

## Stats: `GET /v1/stats?since=<ms>&until=<ms>` (staff) *(added)*

Defaults to the last 24 hours. Counts real orders only: simulated ones are only counted in `simulatedOrders`, and orders staff set to `canceled` only in `canceledOrders` and `statuses` (they add nothing to money, items or `byHour`). `last15Min` compares the kiosk's `paidAt` with the server clock:

```json
{ "since": 0, "until": 0, "generatedAt": 0, "orders": 42, "simulatedOrders": 3, "canceledOrders": 1, "totalCents": 39100, "subtotalCents": 39100, "taxCents": 0,
  "averageCents": 931, "items": 51, "scoops": 88, "cups": 30, "cones": 21, "toppings": 17,
  "flavors": { "vanilla": 30 }, "toppingCounts": { "whip": 8 }, "statuses": { "paid": 2, "collected": 40, "canceled": 1 },
  "byHour": [{ "hour": 1796500800000, "orders": 12, "totalCents": 11200 }],
  "last15Min": { "orders": 4, "totalCents": 3800 } }
```

## Dashboard: `GET /dashboard` *(added)*

A single self-contained page (inline CSS, script and lucide SVG icons, no external requests, a per-request CSP nonce) for the organizer laptop. Without a session it shows the PIN form (`POST /dashboard/login`, then a `303` back with the session cookie); `POST /dashboard/logout` clears it. Dashboard pages send `Referrer-Policy: same-origin` so the browser sends the real `Origin` on the form post (with `no-referrer` Chrome sends `Origin: null` and the same-origin check refuses it).

Signed in, the page opens `GET /v1/ws` with the cookie and follows the client rules above (replace on `snapshot`, apply a patch only at rev + 1, `sync` on a gap or a `pong` ahead, ping every 10 s, reconnect after 25 s of silence with 1 s to 30 s backoff, and again when the tab becomes visible or the network returns). It shows the order feed (real orders only), sold-out toggles and open alerts with acknowledge (sent as `POST /v1/actions` with `by: "Dashboard"`), and kiosk health, and refetches `GET /v1/stats?since=<local midnight>` after each order patch and every 30 s for the tiles and bars. A `401` or `403` from the API reloads the page, which shows the PIN form.

## Other routes

- `GET /v1/state` (any role): the current `BoothState`.
- `GET /v1/health` (no auth): `{ "ok": true, "service": "techclub-icecream", "protocol": 1, "features": [...], "time": ... }`. `features` *(added)* lists additions a client can rely on (`square-oauth`, `square-credentials`, `checkout`, `receipt-tokens`, `order-feed`, `stats`, `staff-session`). With a token, `?deep=1` also checks D1 and the hub.
