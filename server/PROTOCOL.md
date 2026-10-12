# Booth protocol, version 1

The booth backend is an HTTP API plus one websocket hub. Two kinds of client use it:

- **kiosk**: a customer-facing iPad (the booth plans for up to 3). Each one is told apart by its `X-Booth-Device` id. It reports heartbeats, health, help requests, log lines and paid orders, reads the sold-out map and its own entry in the kiosk registry (open/closed, debug tools), and while connected publishes its live session and applies staff assist commands.
- **staff**: the staff web pages (on the booth iPads, inside the app's staff role, and on laptops) and scripts holding `STAFF_TOKEN`. It reads alerts, the kiosk registry, the sold-out map and the order feed, acknowledges alerts, marks flavors, cups and cones and toppings sold out or back, closes and reopens kiosks one at a time or all together, renames kiosks, switches their debug tools, moves orders through their statuses, and assists a customer at a kiosk (sees its live order and sends it commands).

It also owns the Square connection: the OAuth flow, token storage and refresh, and Square order creation for the kiosk.

Base URL: `https://kiosk.jamboree.techclub.pw`. Every API path is under `/v1/`. A breaking change gets a new prefix (`/v2/`) and both are served until every client has moved. Browser-facing paths outside `/v1/`: `/r/<token>` (receipts), `/staff` and `/staff/<role>` (staff pages, with `/dashboard/login`, `/dashboard/logout`, `/dashboard/renew`, and `/dashboard` redirecting to `/staff`) and the OAuth callback page.

Everything below marked *(added)* was added to protocol 1 without breaking older clients: new fields are optional for senders and ignorable for readers, and clients ignore unknown `Change` kinds (they still advance `rev`).

The kiosk must work fully without the backend. Nothing in ordering or payment waits for, or fails because of, a booth call; booth features degrade silently.

## Auth

Every route except `GET /v1/health`, `POST /v1/staff/session`, the OAuth callback and the browser pages (`/r/...`, `/staff...`, `/dashboard...`) needs, including the websocket:

| Header | Value |
| --- | --- |
| `Authorization` | `Bearer <token>`. The kiosk token (`BOOTH_TOKEN`) gives the `kiosk` role; the staff token (`STAFF_TOKEN`) or a staff session token gives the `staff` role. |
| `X-Booth-Device` | A stable id for this install (1 to 64 of `A-Z a-z 0-9 . _ -`), generated once and persisted. Used for rate limits, ordering and dedupe. |

A missing or wrong token is `401`. A valid token used on a route its role can't use is `403`. Rate limits are per role and device; over the limit is `429` with `Retry-After`.

**Staff sessions** *(added)*. Staff can sign in with the staff PIN (`STAFF_PIN`, or the staff token itself) instead of holding `STAFF_TOKEN`:

- `POST /v1/staff/session` (no auth) with `{ "pin": "..." }` returns `{ "token": "st1....", "expiresAt": <ms> }`. The token is a bearer token for the `staff` role, valid 72 hours, signed with a key derived from `STAFF_TOKEN` (rotating `STAFF_TOKEN` signs everyone out). The staff app trades `STAFF_TOKEN` for one and puts it in its web view's cookie store as `booth_staff`. Wrong PIN is `401`; more than 10 attempts a minute from one IP is `429`.
- The staff pages get the same token as an `HttpOnly; Secure; SameSite=Strict` cookie named `booth_staff` from `POST /dashboard/login` (form fields `pin` and `next`). The cookie is accepted on `/v1/` routes for the `staff` role only; any non-GET request authenticated by cookie must carry an `Origin` header equal to the server's origin. Without `X-Booth-Device`, a cookie client's device is `web-<session id>`.

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
  sessions?: KioskSession[];      // (added) staff only: the live session of every connected kiosk; not revisioned, see Assist
  kiosks: KioskEntry[];           // (added) every kiosk the hub knows, oldest first; absent from older servers
  kioskOpen: KioskOpen;           // (added, deprecated) open unless every kiosk is closed; use kiosks[].open
  flavors: { id: string; name: string; soldOut: boolean }[]; // order is display order; the flavor rows of supplies
  supplies: Supply[];             // (added) flavors, then vessels, then toppings, in display order; absent from older servers
  kiosk: KioskState;              // deprecated: the most recently heard kiosk, in snapshots only (never patched)
  alerts: Alert[];                // open alerts, plus closed ones from the last 3 hours (newest first, at most 60)
  orders: OrderSummary[];         // (added) open orders, plus ones changed in the last 3 hours (newest paid first, at most 100)
  serverTime: number;
}

interface Supply {                // (added)
  kind: "flavor" | "vessel" | "topping";
  id: string;                     // flavor ids from the kiosk; vessels "cup", "cone"; toppings "whip", "chocolate", "gummies", "mms", "sprinkles"
  name: string;                   // "Vanilla", "Cups", "Waffle cones", "Whipped Cream", "Chocolate Syrup", "Gummy Bears", "M&M's", "Sprinkles"
  soldOut: boolean;               // booth-wide: every kiosk follows it
}

interface KioskEntry {            // (added)
  id: string;                     // the kiosk's X-Booth-Device
  name: string;                   // what staff see: customName, else reportedName, else "Kiosk " + tag
  customName: string | null;      // set by staff (renameKiosk); wins over the kiosk's own name
  reportedName: string | null;    // the kiosk's configured name (KIOSK_NAME), from heartbeats and health
  tag: string;                    // first 4 letters and digits of id, upper-cased ("3F2A"); prefixes the kiosk's order references
  open: boolean;                  // false: Begin Order is off on this kiosk; a customer mid-order can still finish
  openChangedAt: number | null;   // server ms of the last open/close, null if never changed
  openChangedBy: string | null;
  debug: boolean;                 // staff turned on this kiosk's debug bar
  connected: boolean;             // a websocket from this kiosk is open
  online: boolean;                // heard from within the last 30 s
  lastSeenAt: number | null;      // server ms of the last contact (heartbeat, event or upload)
  firstSeenAt: number;
  screen: string | null;
  health: KioskHealth | null;
  healthAt: number | null;
}

interface KioskState {            // the old single-kiosk shape, kept for old clients
  connected: boolean; online: boolean; lastSeenAt: number | null; screen: string | null;
  health: KioskHealth | null; healthAt: number | null;
}

interface KioskOpen {             // (added, deprecated)
  open: boolean;
  changedAt: number | null;       // the latest change to any kiosk
  changedBy: string | null;
}

interface OrderSummary {          // (added)
  id: string;                     // the kiosk's checkout id
  orderNumber: number | null;     // per kiosk; two kiosks can both have order 12
  orderRef: string | null;        // (added) unique across kiosks: "<tag>-<orderNumber>", e.g. "3F2A-12"
  kioskId: string | null;         // (added) the kiosk that took it (its X-Booth-Device)
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
  key: string;                    // "help:button:<kiosk>", "offline:<kiosk>", "health:reader:<kiosk>", "soldout:chocolate", ...
  kind: "help" | "offline" | "health" | "soldout";
  severity: "urgent" | "warning" | "info";
  title: string;
  detail: string;
  count: number;                  // repeats merged into this alert
  createdAt: number;
  updatedAt: number;
  ackedAt: number | null;
  ackedBy: string | null;
  resolvedAt: number | null;      // closed by the server (condition cleared, kiosk back online or removed, superseded)
  kioskId: string | null;         // (added) the kiosk a help, offline or health alert is about
}
```

**Kiosk registry** *(added)*. A kiosk enters the registry on its first contact (websocket, event or upload) and stays until staff remove it (`removeKiosk`) or it has been silent for 7 days; past 20 entries, the least recently heard offline ones are dropped. A new kiosk is open, has debug tools off and is called `Kiosk <tag>` until it reports a name (`name` in heartbeats, `kioskName` in health) or staff rename it. iOS doesn't let an app read the device's own name, so the kiosk's name comes from its `KIOSK_NAME` setting or from staff. Hub storage from before the registry is upgraded once: its single kiosk state is dropped and its open offline and health alerts are resolved, since they can't be attributed to a device.

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
| `help` (urgent) | A kiosk help event, titled with the kiosk's name ("Customer needs help at Front iPad"). Another help with the same reason from the same kiosk within 2 min of an open one bumps `count` instead. | When acknowledged, or the kiosk is removed. |
| `offline` (urgent; warning while that kiosk is closed) | No contact from a kiosk for 30 s (checked by a Durable Object alarm): "Front iPad is offline". | Resolved by that kiosk's next contact, or its removal. |
| `health` (warning) | A health problem on one kiosk that lasts 45 s: Square not authorized, no reader ready (real payments only), reader or iPad battery at or under 20 % and not charging, catalog error. Titled "... at <kiosk name>". | Resolved when the condition clears, or the kiosk is removed. |

Every alert about a kiosk carries its `kioskId`, and renaming a kiosk retitles its open alerts.
| `soldout` (info; warning when cups and cones are both out) | A flavor, vessel or topping is marked sold out or back ("Waffle cones are sold out", "Gummy Bears are back"). Keyed `soldout:<flavor id>` for flavors and `soldout:<kind>:<id>` otherwise. | Superseded by the next change to that item. |

## WebSocket: `GET /v1/ws`

Open with the auth headers above. The server sends a `snapshot` immediately, then a `patch` for every change.

Server to client:

```jsonc
{ "type": "snapshot", "state": BoothState }
{ "type": "patch", "rev": 42, "change": Change }
{ "type": "pong", "t": 1791700000000, "rev": 42, "serverTime": 1791700000123, "kioskLastSeenAt": 1791699995000 }   // a kiosk gets its own last contact; staff the latest of any kiosk
{ "type": "result", "id": "<event or action id>", "status": "ok" | "duplicate" | "stale" | "rejected", "alertId": "...", "error": {...} }
{ "type": "error", "error": { "code": "bad_request", "message": "..." } }
{ "type": "session", "kiosk": "<device id>", "session": KioskSession | null }   // (added) staff only; null when the kiosk disconnects
{ "type": "assist", "active": true, "by": "Toppings iPad", "expiresIn": 30000 }  // (added) kiosk only; on connect and whenever staff assisting it change
{ "type": "command", "command": AssistCommand }                                 // (added) kiosk only; relayed from staff
```

`Change` is one of:

```jsonc
{ "kind": "flavors", "flavors": [{ "id": "vanilla", "name": "Vanilla", "soldOut": false }] }   // the whole list; only when a flavor changes
{ "kind": "supplies", "supplies": Supply[] }                                                 // (added) the whole list, after every sold-out change
{ "kind": "alert", "alert": Alert }                                                          // insert or replace by id
{ "kind": "kiosks", "kiosks": KioskEntry[] }                                                 // (added) the whole registry
{ "kind": "order", "order": OrderSummary }                                                   // (added) insert or replace by id
{ "kind": "kioskOpen", "kioskOpen": KioskOpen }                                              // (added, deprecated) when the aggregate flag changes
{ "kind": "kiosk", "kiosk": KioskState }                                                     // no longer sent; old servers only
```

Client rules, which make every client converge on the hub's state:

1. On `snapshot`, replace local state and set `rev` from it.
2. On `patch`: ignore it if `rev` is at or below the local rev (stale or duplicate). Apply it if it is exactly local rev + 1. If it is further ahead, a patch was missed: send `{"type":"sync"}` and wait for the snapshot.
3. On `pong`, if its `rev` is ahead of the local rev, send `sync`.
4. Persist what the app needs while offline (the kiosk keeps what is sold out and its own entry's `open` and `debug` flags), and keep using it until a snapshot arrives. A kiosk finds its entry by its own device id; if `kiosks` is missing (an older server) it falls back to `kioskOpen`, and if its entry is missing it keeps what it had.

Client to server:

```jsonc
{ "type": "heartbeat", "t": 1791700000000, "screen": "builder", "name": "Front iPad" }   // kiosk, every 10 s; name (added) optional; answered with pong
{ "type": "ping", "t": 1791700000000 }                              // any role; answered with pong
{ "type": "sync" }                                                  // answered with a snapshot
{ "type": "event", "event": Event }                                 // kiosk; answered with result
{ "type": "action", "action": Action }                              // staff; answered with result
{ "type": "session", "session": KioskSession }                      // (added) kiosk; relayed to staff, no reply (error if invalid)
{ "type": "assist", "kiosk": "<device id>" | null, "by": "Toppings iPad" }   // (added) staff; which kiosk this page is assisting, every 10 s while open
{ "type": "command", "command": AssistCommand }                     // (added) staff; answered with result (relayed, or rejected)
```

Liveness: clients send `heartbeat` or `ping` every 10 s and treat 25 s without any message from the server as a dead socket: close it and reconnect. Reconnect with backoff (1 s doubling to 30 s, with jitter), and at once when the app returns to the foreground or the network path comes back. The server treats 30 s without kiosk contact as offline. Text frames over 64 KB are rejected, and a socket that floods (more than 60 messages in 10 s) gets an error and is closed with code 1008.

## Assist *(added)*

A staff member at one of the booth iPads can follow and change the order of the customer standing at a kiosk. The kiosk is authoritative: staff send commands, the kiosk applies them through its own ordering model (pricing, the three-scoop limit and sold out all hold, and the customer sees the change on screen), and staff only ever display what the kiosk publishes. Assist needs live sockets on both sides; nothing is queued, and ordering and payment never depend on it.

**Session.** While its socket is open the kiosk sends its session whenever it changes, at most 4 times a second (a socket is closed past 60 messages in 10 s), and again after every reconnect. The hub keeps the latest one in its Durable Object storage only while that kiosk has an open socket (never in D1, never in `rev`), sends it to every staff socket as `{"type":"session"}`, includes it in staff snapshots and `GET /v1/state` for staff as `sessions`, and sends `session: null` once the kiosk's last socket closes. Kiosk sockets never receive sessions.

```ts
interface KioskSession {
  kiosk: string;                  // set by the hub: the kiosk's X-Booth-Device
  updatedAt: number;              // set by the hub: server ms when it arrived
  screen: string;                 // "attract" | "builder" | "summary" | "name" | "confirmation" | "roleSetup" | "staff"
  step: "vessel" | "flavors" | "toppings" | null;   // the builder step, on "builder" only
  editing: boolean;               // the item on screen is one taken back out of the order
  items: {
    id: string;                   // the kiosk's item id; commands name items by it
    vessel: "cup" | "cone"; flavors: string[]; toppings: string[];
    cents: number;                // what the kiosk charges for it, with scoops priced by position in the order
    current: boolean;             // the item at the center of the builder
    inOrder: boolean;             // false for the item being built while it has no choices yet (it isn't charged)
  }[];
  customerName: string;
  totalCents: number;             // the kiosk's own total
  paying: boolean;                // a payment is under way (Square's screen or the gift card flow); the kiosk refuses every command
  orderingOpen: boolean;          // false while this kiosk is closed or out of cups and cones
  assisted: boolean;              // the kiosk is showing "A staff member is helping you"
  maxScoops: number;              // per item, 3
  results: { id: string; status: "applied" | "duplicate" | "rejected"; message?: string }[];  // the last 20 commands
}
```

**Presence.** A staff page sends `{"type":"assist","kiosk":"<device id>","by":"Toppings iPad"}` when it opens assist and every 10 s while it stays open, and `"kiosk": null` when it closes. The hub remembers it on that socket (surviving hibernation) for 30 s. Whenever the set of staff assisting a kiosk changes, and when the kiosk connects, the kiosk gets `{"type":"assist","active":...,"expiresIn":30000}`; it shows its *assisting* note while active and hides it if no refresh arrives within `expiresIn` plus 5 s, so a staff iPad that drops off the network can't leave it up.

**Commands.** Staff send `{"type":"command","command":AssistCommand}`:

```jsonc
{ "id": "<uuid>", "kiosk": "<device id>", "by": "Toppings iPad", "op": "addScoop", "item": "<item id>", "flavor": "vanilla" }
{ ..., "op": "removeScoop", "item": "<item id>", "flavor": "vanilla" }
{ ..., "op": "setVessel", "item": "<item id>", "vessel": "cup" | "cone" }
{ ..., "op": "setTopping", "item": "<item id>", "topping": "whip", "on": true }
{ ..., "op": "addItem" }                                  // finishes the item on screen and starts a fresh one (from the review sheet: back to the builder)
{ ..., "op": "removeItem", "item": "<item id>" }          // the item being built is cleared instead
{ ..., "op": "setName", "name": "Alex" }                  // the kiosk keeps at most 24 characters
{ ..., "op": "navigate", "to": "builder" | "summary" | "name" }   // from the welcome screen, "builder" begins an order
{ ..., "op": "startOver" }                                // clears the order and returns to the welcome screen
```

The hub validates the shape and relays the command to every open socket of that kiosk, answering the staff socket with `result` `ok` (relayed), or `rejected` with `bad_request` or `kiosk_offline` ("Front table isn't connected"). It doesn't dedupe or store commands. The kiosk applies them one at a time in arrival order, the same way a customer's taps would: an item that isn't on screen is first taken back out of the tray (or the review sheet) and the builder moves to the step that edits it, so the customer sees each change happen. Its answer is in the `results` of its next session: `applied`, `rejected` with a plain reason ("3 scoops max", "Payment is in progress on the kiosk", "Chocolate is sold out"), or `duplicate` for an id it already applied (it remembers the last 500). Staff resend a command with the same id until it appears in `results`, so a resend never applies twice. Commands are relative ("add a vanilla scoop"), so simultaneous taps by the customer and staff both apply in the order the kiosk sees them and every page converges on the kiosk's next session.

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
  kioskName?: string;                                 // (added) the kiosk's configured name, at most 40 characters
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
{ "id": "...", "type": "setSoldOut", "flavor": "chocolate", "soldOut": true, "by": "Maya" }       // flavors only; same as setSupply with kind "flavor"
{ "id": "...", "type": "setSupply", "kind": "topping", "item": "gummies", "soldOut": true, "by": "Maya" }   // (added) kind flavor, vessel or topping
{ "id": "...", "type": "setOrderStatus", "orderId": "<checkout id>", "status": "ready", "by": "Maya" }   // (added)
{ "id": "...", "type": "setKioskOpen", "open": false, "kiosk": "<device id>", "by": "Maya" }          // (added); kiosk (added) optional, without it every kiosk
{ "id": "...", "type": "renameKiosk", "kiosk": "<device id>", "name": "Front iPad", "by": "Maya" }      // (added) "" goes back to the kiosk's own name
{ "id": "...", "type": "setKioskDebug", "kiosk": "<device id>", "debug": true, "by": "Maya" }          // (added) shows or hides that kiosk's debug bar
{ "id": "...", "type": "removeKiosk", "kiosk": "<device id>", "by": "Maya" }                          // (added) forgets it and resolves its alerts
```

Response `200`: `{ "results": [{ "id": "...", "status": "ok" | "duplicate" | "rejected", "error"?: {...} }], "rev": 43 }`. The same actions can be sent one at a time over the websocket (`{"type":"action"}`), answered with `result`.

Acking an already acknowledged alert is `ok` and changes nothing. `setSoldOut`, `setSupply`, `setOrderStatus`, `setKioskOpen`, `renameKiosk` and `setKioskDebug` are last-writer-wins in the order the hub receives them; setting the value something already has is `ok` and changes nothing (no patch). A kiosk is open until staff close it. A flavor change sends a `flavors` patch and then a `supplies` patch; a vessel or topping change sends only `supplies`. `setSupply` with an unknown kind is `rejected` with `bad_request`, with an item not in the list with `not_found`. Sold out only stops new choices on the kiosks: carts that already hold the item are still checked out and paid (`/v1/checkout` and `/v1/orders` never look at it), and while cups and cones are both out the kiosks show Closed. `setOrderStatus` for an order not in the feed, and `setKioskOpen` (with `kiosk`), `renameKiosk` or `setKioskDebug` for a kiosk not in the registry, are `rejected` with `not_found`. `removeKiosk` of an unknown kiosk is `ok`. Names are trimmed, runs of spaces collapsed and cut at 40 characters.

Clients that queue offline should keep only the newest unsent `setSoldOut`/`setSupply`/`setOrderStatus`/`setKioskOpen`/`renameKiosk`/`setKioskDebug` per item, order, kiosk flag or name (a `setKioskOpen` without `kiosk` also replaces unsent ones for single kiosks), and not send over the websocket while an HTTP batch is in flight, so an older change can't land after a newer one. The staff pages do both (see [Staff pages](#staff-pages-get-staffrole-added)).

## Logs: `POST /v1/logs` (kiosk)

```jsonc
{ "appVersion": "0.1 (1)", "lines": [{ "id": "<device>-<file>-<offset>", "ts": "2026-12-05T13:02:11.120-08:00",
  "level": "debug" | "info" | "warn" | "error", "message": "...", "context": { } }] }
```

1 to 500 lines, at most 1 MB; `message` is cut at 8 KB and `context` at 8 KB of JSON. Response: `{ "accepted": 3, "stored": 2, "duplicates": 1 }`. Lines are kept 30 days and also written to Workers Logs.

## Orders: `POST /v1/orders` (kiosk)

```jsonc
{ "orders": [{
  "id": "<checkout id>", "orderNumber": 12, "orderRef": "3F2A-12", "squareOrderId": "...", "squarePaymentId": "...", "customerName": "Alex",
  "totalCents": 900, "subtotalCents": 900, "taxCents": 0, "card": "Visa 1111", "simulated": false,
  "paidAt": "2026-12-05T13:02:11Z", "appVersion": "0.1 (1)",
  "receiptToken": "Qm9vdGhSZWNlaXB0VG9rZW4",                                     // (added) optional
  "giftCardPaymentId": "...", "giftCardCents": 500, "giftCardLast4": "1234",     // (added) optional, nullable: the gift card part of a split or gift-only order
  "items": [{ "vessel": "cone", "flavors": ["vanilla", "chocolate"], "toppings": ["sprinkles"] }],   // toppings (added) optional
  "lines": [{ "title": "1 Scoop", "detail": "#1 Waffle Cone: Vanilla", "cents": 400 }] }] }
```

1 to 50 orders. Response: `{ "results": [{ "id": "...", "status": "ok" | "duplicate" | "rejected" }] }`. An order is a duplicate if its `id`, its `squarePaymentId` or its `receiptToken` was stored before. Orders are never alerts. Every stored order (and a retried duplicate stored under the same `id`) is pushed into the hub's order feed, which ignores ones it already has; if the hub can't be reached the response is `503` and the kiosk's retry completes it.

`id` is the checkout id the kiosk generated when the customer pressed pay (the same id sent to `POST /v1/checkout`), so a receipt, a checkout and a paid order share one id.

`orderNumber` counts per kiosk, so two kiosks both have an order 12. `orderRef` *(added, optional, 1 to 24 of `A-Z a-z 0-9 -`)* is `<tag>-<orderNumber>`, made on the kiosk from its own device id without asking the server, so it is unique across kiosks; it is the Square reference id (`kiosk-3F2A-12`) and what the receipt shows. The hub's feed records the uploading device as `kioskId`. Customers are called by name, so staff pages show the name large and the number only in fine print.

For a split order `squarePaymentId` is the card reader's payment and `card` reads like `Visa 4242 + Gift card 1234`; for a gift-card-only order `squarePaymentId` is the gift card payment. `giftCardCents` is an integer >= 0. The receipt page shows both tenders when `giftCardCents` > 0.

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
| `GET /v1/square/oauth/start` | staff (cookie or bearer) | The same, as a `302` to Square, for opening in a signed-in browser. |
| `GET /v1/square/oauth/callback` | none (the `state` is the credential) | Square redirects here. Each `state` works once and expires after 10 minutes. Exchanges the code, picks the location (`SQUARE_LOCATION_ID` if set, else the first active location that takes cards), stores the tokens and shows a page saying what happened. |
| `GET /v1/square/status[?verify=1]` | staff | Configuration, active source, location, token expiry, last refresh and its error, `stale` (no refresh for 8 days). `verify=1` also calls Square to check the token. |
| `POST /v1/square/refresh` | staff | Refreshes now. `{ "status": "refreshed" \| "skipped" \| "failed", ... }`, `502` on failure. |
| `POST /v1/square/revoke` | staff | Revokes the token at Square and forgets it. The static fallback, if set, takes over. |

Scopes requested: `MERCHANT_PROFILE_READ PAYMENTS_READ PAYMENTS_WRITE PAYMENTS_WRITE_IN_PERSON ORDERS_READ ORDERS_WRITE ITEMS_READ`. Tokens are stored AES-GCM encrypted with a key derived from `SQUARE_APPLICATION_SECRET`. The daily cron refreshes a token once it is 6 days old (or within 21 days of expiry); a failed refresh keeps the old token, is logged as an error and shows in `status`.

## Checkout: `POST /v1/checkout` (kiosk) *(added)*

Creates the Square order for a cart, priced by the server, and returns what the Mobile Payments SDK needs.

```jsonc
{ "id": "<checkout id, a UUID>", "receiptToken": "<22 to 64 of A-Z a-z 0-9 _ ->", "orderNumber": 12, "orderRef": "3F2A-12", "customerName": "Alex",
  "sourceName": "Tech Club Ice Cream Kiosk", "locationId": "L...", "quotedCents": 1100,
  "items": [{ "vessel": "cone", "flavors": ["vanilla", "chocolate"], "toppings": ["whip"] }, { "vessel": "cup", "flavors": ["cookies"] }] }
```

1 to 20 items, 1 to 3 flavors and up to 10 toppings each. `orderRef` *(added)* is optional; with it the Square reference id is `kiosk-<orderRef>`, without it `kiosk-<orderNumber, 4 digits>`. `locationId` (the location the kiosk's SDK is authorized for) and `quotedCents` (what the kiosk showed) are optional checks: a different location is `409 location_mismatch`; a different quote is only logged, because Square's total is what gets charged.

```json
{ "id": "...", "status": "created", "squareOrderId": "...", "locationId": "L...", "environment": "sandbox", "referenceId": "kiosk-3F2A-12",
  "totalCents": 1100, "taxCents": 0, "subtotalCents": 1100, "expectedSubtotalCents": 1100, "priceMatches": true,
  "usedCatalog": true, "catalogError": null, "receiptToken": "...",
  "lines": [{ "title": "1 Scoop", "detail": "#1 Waffle Cone: Vanilla", "quantity": 1, "baseCents": 400, "cents": 400 }] }
```

Pricing is the app's: scoops by position in the whole order ($4, $3, then $2 each), $1.50 per waffle cone, $0.50 per topping. Line items reference the catalog category `SQUARE_CATEGORY_NAME` (*1 Scoop*, *2nd Scoop*, *3rd+ Scoop*, *Waffle Cone*, *Topping*, cached 10 minutes, a stale copy up to a day old is used if Square fails); if it's missing or priced differently the order uses ad-hoc line items, exactly as the app does, and `catalogError` says why. Taxes are auto-applied by Square.

Idempotent by `id`: a retry returns the stored result with `status: "duplicate"` and no second Square call; the same `id` with a different cart is `409 conflict`. The Square idempotency key is the checkout id, so concurrent retries also get one Square order. The kiosk's own fallback uses `<id>-device`, so a slow backend answer and a device-created order never collide (an abandoned unpaid Square order is harmless).

The kiosk calls this first with a 3.5 s budget and creates the order on the device on any failure or timeout, skipping the backend for a minute afterwards. It only uses it when its SDK token came from the backend, so the order and the payment belong to the same merchant.

## Gift cards *(added)*

All routes are kiosk-only, JSON, and fail with the usual error shape. Square needs the `GIFTCARDS_READ` OAuth scope, so a merchant connected before it was added must run the Square connect flow again. Gift card numbers (GANs) are normalized on the server: a leading `sqgc://` (any case) is stripped, then every non-digit is removed, and the result must be exactly 16 digits or the answer is `400 invalid_gan`. Only the last four digits are ever logged or stored.

`POST /v1/giftcards/lookup` with `{ "gan": "sqgc://7783320000001234" }` answers `{ "last4": "1234", "balanceCents": 500, "state": "ACTIVE" }`. Unknown card: `404 giftcard_not_found`. After 10 invalid or not-found lookups (lookups inside `charge` count too) from one device within 10 minutes: `429 rate_limited`.

`POST /v1/giftcards/charge` with `{ "checkoutId": "...", "gan": "...", "idempotencyKey": "<1 to 45 chars>" }` places a hold (an uncompleted Square payment with partial authorization, on the checkout's Square order and location) for the part of the checkout total not already held by earlier gift cards of the same checkout, and answers `{ "paymentId": "...", "approvedCents": 500, "remainingCents": 400, "last4": "1234" }` where `remainingCents` is the total minus every gift card hold on the checkout. The kiosk then takes `remainingCents` on the reader (same Square order id, not auto-completed) when it is above zero. Errors: `404 checkout_not_found` (unknown, or created by another device), `409 giftcard_inactive` (state is not `ACTIVE`), `409 giftcard_empty` (zero balance), `409 already_covered` (earlier holds already cover the total), `409 conflict` (the key was used for another checkout). The same `idempotencyKey` returns the stored answer without another Square call. The balance is only reserved, not spent, until `complete`.

`POST /v1/checkout/complete` with `{ "checkoutId": "...", "paymentIds": ["<1 to 3 payment ids>"], "idempotencyKey": "..." }` calls Square's PayOrder with those payments, then reads the order and requires `net_amount_due_money` to be 0 (falling back to the order's tenders covering its total). Answers `{ "status": "completed" }`; payments settle to `COMPLETED` within a few seconds, and the order itself stays open (it has a proposed pickup fulfillment). Errors: `409 amount_mismatch` (Square's `ORDER_TOTAL_MISMATCH`: the payments don't add up), `409 order_unpaid` (Square still shows an amount due). Retrying a completed checkout answers `completed` again.

`POST /v1/checkout/cancel` with `{ "checkoutId": "...", "paymentIds": ["..."] }` (`paymentIds` optional) cancels the listed payments and every gift card hold still `approved` for the checkout, tolerating payments Square says are already canceled or completed, and answers `{ "canceled": ["<payment ids>"] }`. Square gives the gift balance back asynchronously (minutes). `503 unavailable` if Square can't be reached; retry.

A cron every 10 minutes (`*/10 * * * *`) cancels gift card holds still `approved` 15 minutes after they were placed, so an abandoned checkout doesn't lock the customer's balance. State lives in D1 `giftcard_payments` (`approved`, `completed`, `canceled`).

## Receipts: `GET /r/<receiptToken>` *(added)*

Public, no auth: the token is the credential. The kiosk generates it (128 random bits, base64url) when the customer pays, so it can show a QR code even with the backend down, and sends it with the checkout and the paid order (`receipts.ts` looks in `orders`, then `checkouts`). The response is a mobile-friendly HTML page (`noindex` in a meta tag and `X-Robots-Tag`, `no-store`): event name, order reference (`Order 3F2A-12`, or the order number for orders without one), customer name, itemized lines (vessel, flavors, toppings, price), subtotal, tax, total, card, date and time in `America/Los_Angeles`, and a "View Square receipt" link when Square's payment has a `receipt_url` (looked up only for ids that look like Square payment ids, with a 2.5 s budget covering credentials too; the link is simply left out on failure). Per-item prices are Square's `#N`-tagged lines when they add up to the subtotal, else the app's pricing. An order a staff member set to `canceled` says "This order was canceled". A well-formed token that isn't an uploaded order yet (including one with only a checkout) gets `200` with "Your receipt will appear shortly" and a 10 s auto-refresh, since a kiosk may show the QR code while the backend was unreachable; if D1 can't be read the same page comes back with `503`. Only a malformed token gets `404`. The kiosk's URL is `Receipt.receiptURL` (`BOOTH_URL` + `/r/<token>`).

## Stats: `GET /v1/stats?since=<ms>&until=<ms>` (staff) *(added)*

Defaults to the last 24 hours. Counts real orders only: simulated ones are only counted in `simulatedOrders`, and orders staff set to `canceled` only in `canceledOrders` and `statuses` (they add nothing to money, items or `byHour`). `last15Min` compares the kiosk's `paidAt` with the server clock:

```json
{ "since": 0, "until": 0, "generatedAt": 0, "orders": 42, "simulatedOrders": 3, "canceledOrders": 1, "totalCents": 39100, "subtotalCents": 39100, "taxCents": 0,
  "averageCents": 931, "items": 51, "scoops": 88, "cups": 30, "cones": 21, "toppings": 17,
  "flavors": { "vanilla": 30 }, "toppingCounts": { "whip": 8 }, "statuses": { "paid": 2, "collected": 40, "canceled": 1 },
  "byHour": [{ "hour": 1796500800000, "orders": 12, "totalCents": 11200 }],
  "last15Min": { "orders": 4, "totalCents": 3800 } }
```

## Staff pages: `GET /staff/<role>` *(added)*

Self-contained pages (inline CSS, script and lucide SVG icons, a Noto Serif subset embedded as a `data:` font for customer names, no external requests, a per-request CSP nonce that also allows `media-src blob:` for the alert chime and `font-src data:`). They are styled as a light-mode iPadOS app whatever the device's appearance setting. The roles are listed in `src/staff-roles.ts`: `scooper` and `toppings` (iPads, interactive) and `organizer` and `board` (laptop displays, read-only). `GET /staff` lists them; `GET /dashboard` is a `303` to `/staff`; an unknown role is `404`. Without a session every page shows the PIN form, which posts `pin` and `next` (the page to return to, only `/staff` or `/staff/<role>`) to `POST /dashboard/login` and gets a `303` back with the session cookie; `POST /dashboard/logout` clears it. `POST /dashboard/renew` (cookie, same origin) answers `204`, with a fresh 72-hour cookie once the current one has under 48 hours left; pages call it every 30 minutes so an unattended display stays signed in. Pages send `Referrer-Policy: same-origin` so the browser sends the real `Origin` on the form post (with `no-referrer` Chrome sends `Origin: null` and the same-origin check refuses it).

Signed in, a page opens `GET /v1/ws` with the cookie and follows the client rules above (replace on `snapshot`, apply a patch only at rev + 1, `sync` on a gap or a `pong` ahead, ping every 10 s, reconnect after 25 s of silence with 1 s to 30 s backoff, and again when the tab becomes visible or the network returns). Actions go through `POST /v1/actions` with `X-Booth-Device: web-<random>`, generated once per browser and kept in `localStorage`, and `by` set to the page title (`Scooper iPad` in the app, `Scooper page` in a browser). Each action is first written to a `localStorage` queue with its id, sent oldest first in batches (never more than one batch in flight), and removed only on `ok`, `duplicate` or `rejected`; network errors, `429` and `5xx` keep it and retry with backoff. An unsent `setSoldOut`/`setSupply`, `setOrderStatus` or `setKioskOpen` is replaced by a newer one for the same item, order or flag, and items unsent for an hour are dropped with a notice. Because the device id is stable, a batch that reached the hub before the connection dropped is answered `duplicate` on resend. The organizer page refetches `GET /v1/stats?since=<local midnight>` after each order patch and every 30 s. A `401` from the API reloads the page, which shows the PIN form.

The staff app's web view identifies itself with `BoothStaffApp/1` in its user agent; pages then hide sign-out and the page switcher, play the alert chime and show *Exit staff mode*. After its confirmation the page posts `{ "type": "exitStaffMode" }` to the app's `boothApp` script message handler (`window.webkit.messageHandlers.boothApp`), and the app goes back to its role picker. In a browser the pages never play sound and have no exit control.

The iPad pages and the organizer display list every kiosk in a *Kiosks* section: name, open or closed, online or last heard, and a short health line. On the iPads a kiosk opens a sheet to rename it, close or reopen it, switch its debug tools, see its full health and remove it once it's offline; *Close all kiosks* and *Open all kiosks* act on every kiosk. Closing, reopening and removing ask first; renaming and debug tools don't. While cups and cones are both sold out every open kiosk is listed as *Closed* with "No cups or cones left".

**Assist** (both iPad roles, not the displays): *Assist* in the navigation bar opens the kiosk picker, or goes straight to the kiosk when only one is online; each kiosk's sheet has *Assist* too. Opening it asks first. It is a full-page view of the kiosk's live session: each item with cup or cone, scoop steppers, topping chips and the kiosk's price, the total, which screen the kiosk is on with *Building the order*, *Reviewing the order* and *Entering a name* to move it there, the name for pickup, *Add another item* and *Start over*. Removing an item and starting over ask first. Changes are commands sent over the socket and resent every 3 s until the kiosk answers (given up after 15 s with a notice); the view shows only what the kiosk reports, and a refused command shows the kiosk's reason. Everything is disabled, with a plain explanation, while the page or the kiosk is offline or the customer is paying, and after payment only *Start over* remains. Urgent alerts stay on top of the view. *Done* closes it, and the kiosk's note goes away.

Sold out is split by role. The scooper page switches flavors and *Cups and cones*; the toppings page switches *Toppings*. Each shows the other role's items read-only in a compact list of what is sold out ("All available" otherwise), with a note naming the page that sets them. Every switch, either direction, asks for confirmation first. The organizer display lists all three groups read-only. The split is in the pages (`owns` in `src/staff-roles.ts`); the hub accepts `setSupply` for any kind from any staff client.

## Other routes

- `GET /v1/state` (any role): the current `BoothState`.
- `GET /v1/health` (no auth): `{ "ok": true, "service": "techclub-icecream", "protocol": 1, "features": [...], "time": ... }`. `features` *(added)* lists additions a client can rely on (`square-oauth`, `square-credentials`, `checkout`, `receipt-tokens`, `order-feed`, `stats`, `staff-session`, `kiosk-registry`, `supplies`, `gift-cards`, `assist`). With a token, `?deep=1` also checks D1 and the hub.
