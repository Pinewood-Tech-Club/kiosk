<img src="assets/icon.svg" width="64" height="64" alt="">

# kiosk

Self-order ice cream kiosk for the Tech Club fundraiser booth. SwiftUI + RealityKit on a single 13" iPad Pro (M4), portrait only, taking card payments with the [Square Mobile Payments SDK](https://developer.squareup.com/docs/mobile-payments-sdk) (2.6.0).

## Setup

1. Xcode 26.2 (iOS 26.2 SDK). Deployment target is iOS 26.0.
2. `cp Config/Local.xcconfig.example Config/Local.xcconfig` and fill in:
   - `DEVELOPMENT_TEAM` / `PRODUCT_BUNDLE_IDENTIFIER` for signing.
   - `SQUARE_APPLICATION_ID` from the [Developer Console](https://developer.squareup.com/apps). A `sandbox-…` application ID puts the app in Sandbox mode.
   - `SQUARE_ACCESS_TOKEN`, `SQUARE_LOCATION_ID`: a dev fallback only. The kiosk gets its access token and location from the [backend](#square-oauth-and-checkout) and keeps the last ones in the Keychain; the bundled pair is used only until it has reached the backend once.
   - `SQUARE_CATEGORY_NAME`: the catalog category holding the *1 Scoop*, *2nd Scoop*, *3rd+ Scoop* and *Waffle Cone* items (one fixed-price variation each). If it's missing or its prices don't match the kiosk's, orders fall back to ad-hoc line items and the debug bar shows the error.
   - `KIOSK_EVENT_NAME`, shown on the receipt screen.
   - `BOOTH_URL` and `BOOTH_TOKEN` for the [backend](#backend). `BOOTH_URL` is a bare host (`techclub-icecream.adamxu.workers.dev`) because `//` starts a comment in an xcconfig. Leave them empty to run without the backend; the kiosk works the same either way (with the bundled Square token).
   - Staff iPad only: `KIOSK_ROLE = staff` skips role setup and opens the staff screen; `BOOTH_STAFF_TOKEN` is the staff token it connects with (a staff session from a PIN sign-in, kept in the Keychain, also works).
3. `xcodegen generate` (the project is generated from `project.yml`; rerun after adding source files), open `Kiosk.xcodeproj`, pick the iPad, Run.

`Kiosk/Resources/3D/` is a folder reference, so new or updated 3D assets are bundled without regenerating the project (do a clean build if Xcode misses a change). The Metal morph kernel is compiled at launch, so the separate Metal toolchain download isn't needed.

## Flow

1. **Role setup** (every launch, unless `KIOSK_ROLE` or `-kioskRole` picks one): *Start Kiosk* or *Staff*. Square and the kiosk's backend link start only when the kiosk role is chosen, so a staff iPad never reports itself as the kiosk; once the kiosk has started, switching this iPad to staff needs a relaunch. *Staff* opens the [staff screen](#staff-ipad).
2. **Attract**: looping `loop.mp4`. *Begin Order* appears once every 3D asset is preloaded; tapping anywhere starts an order.
3. **Builder** (one RealityView behind the SwiftUI controls holds every 3D object):
   - *Vessel*: Cup (included) or Waffle Cone (+$1.50). Selecting flies the new vessel out of its icon while the old one spins back into its slot. Drag the item to orbit it; it eases back and resumes spinning.
   - *Flavors*: tap a flavor to fling a scoop onto the item (up to 3); each card shows what the next scoop costs. The card's minus button takes one of that flavor back off.
   - *Toppings*: placeholder, then *Add to Order* flies the item into the tray.
   - The step selector at the top jumps between steps that are already reachable.
   - Tray: a pinned *New item* slot, live 3D minis (drag to scroll), *View Order* with the live total, and start-over (with confirmation). Tapping a mini lifts it back out to edit. Leaving an edit keeps the changes: *Done*, *New item*, tapping another mini or *View Order* return the item to its slot. The minus badge on its empty slot removes it (after a confirmation); an item edited down to no scoops asks to be removed. *New item* outside an edit adds the item being built to the order and starts a fresh cup.
4. **Your order**: *View Order* grows the tray's glass into a sheet over the builder; each item's 3D model rides up from its tray slot into its row, with edit (pencil) and remove (trash) buttons. Below are the total and *Check Out*. *Keep ordering*, or pulling the sheet down, folds it back into the tray with the items riding back into their slots, revealing a fresh builder that was set up while the sheet covered it.
5. **Name**: the name becomes the Square order's ticket name and pickup recipient.
6. **Payment**: generates a checkout id and an unguessable receipt token on the kiosk, asks the backend to create the Square order (3.5 s budget, then the kiosk does it itself, and skips the backend for a minute), or creates a Square order from the catalog on the device (one line per scoop, priced by its position in the whole order, plus one line per waffle cone; taxes auto-applied by Square), then `startPayment` for Square's total with Square's default payment screen. Once a card touches the reader, Square's own screens take over (PIN, processing, declines, low gift card balances, card read errors, with retry or cancel). On failure the customer returns to their order and an alert explains in plain words what happened and what to do (copy lives in `PaymentProblem.swift`; the technical error goes to the log); a cancel just returns them to it.
7. **Confirmation**: an itemized receipt of what Square charged, a QR code to the digital receipt page ("Scan for your receipt"), and *New Order*. Returns to the attract screen after 30 s without a touch (10 s when there is no QR code because BOOTH_URL is unset).

Pricing: scoops are priced by their position in the whole order: the first is $4, the second $3, and every one after that $2 (so 1 → $4, 2 → $7, 3 → $9). Waffle cones are $1.50 each.

## Debug bar

Top of the screen: Square environment, authorization, readers, *Mock Reader* (sandbox), *Readers* settings, *Log*, and a *Debug* menu:

- *Simulate payment success*: skips Square and shows a test receipt (on by default in the simulator).
- *Simulate error*: makes the next payment fail in a chosen way (declined, timeout, offline, no reader, screen shared, not authorized, and so on), or shows the attract screen's not-ready notice, so staff can see and demo each message. A red *Forcing* badge shows while one is set.
- *Animation speed*: 0.5×, 0.25×, 0.1× slow motion for the 3D timeline.
- *Show 3D debug info*: frame-time stats (p50/p99/max frame time, CPU time of the per-frame update), alignment markers for the icons, and frame stats and hitches written to the log every 5 s.
- *Change role*, *Hide debug bar*. Triple-tap the top-left corner to bring the bar back.

The log is also written to `Documents/kiosk.log`.

## Launch arguments (testing)

Pass in the scheme or with `xcrun simctl launch <udid> com.adamxu.kiosk -kioskScreen builder …`:

| Argument | Effect |
| --- | --- |
| `-kioskRole kiosk\|staff` | Skip role setup. |
| `-boothURL <url>`, `-boothToken <token>`, `-boothStaffToken <token>` | Override `BOOTH_URL`, `BOOTH_TOKEN`, `BOOTH_STAFF_TOKEN`. |
| `-kioskScreen attract\|builder\|summary\|name\|confirmation` | Open a screen directly. |
| `-kioskStep vessel\|flavors\|toppings` | Builder step (implies `builder`). |
| `-kioskCurrent "cone:vanilla,chocolate"` | Item being customized. |
| `-kioskItems "cup:cookies;cone:vanilla"` | Items already in the tray. |
| `-kioskName Alex` | Prefill the name. |
| `-kioskScript <name>` | Scripted taps: `vessel-to-cone`, `vessel-pingpong`, `bounce`, `scoops`, `scoops-rapid`, `back-swap`, `add-to-order`, `drag`, `tray-remove`, `remove-middle`, `vessel-new`, `edit`, `edit-scroll`, `edit-done`, `edit-new`, `edit-switch`, `edit-empty`, `fresh`, `summary`, `pay`, `pull-down`, `press-hold`, `swap-continue`, `vessel-spam`, `demo`. |
| `-kioskScript stress\|stress-tray` | Rapid random taps (cup/cone, flavors, minus, steps; `stress-tray` adds New item, tray edits, deletes and the order sheet), then a check that the settled 3D scene matches the order. Results go to the log as `Stress:` lines. `-kioskSeed N` and `-kioskStressRounds N` make a run repeatable. |
| `-kioskScript clip-tour\|clip-interrupts` | Every way a scoop meets a vessel (adds into each slot, cup and cone handovers with 1 to 3 scoops, top, middle and bottom removals), and the same motions cut short by the next tap. With any script, or `-kioskClipCheck YES`, every frame's scoop shapes are tested against every cup and cone: a scoop through a wall is logged as a `Clip:` line with its depth and motion, stress rounds report it as `CLIP`, and the run ends with a `Clip check:` summary. |
| `-kioskScript sheet-stress` | Thousands of randomized pull-down updates on the order sheet (slow oscillation, reversals, past the open position and below the tray, holds, flings, second-finger taps, cancellations), checking that the sheet tracks the finger, always comes to rest open or closed with its items on it, and that the main thread never stalls. Results go to the log as `SheetDrag:` lines; `-kioskSeed` and `-kioskStressRounds` (gestures) apply. `sheet-oscillate` is a slow, recordable version. |
| `-kioskAutoplay YES` | Same as `-kioskScript demo`: the whole flow through a simulated payment. |
| `-kioskSlowmo 0.25` | Slow motion. |
| `-kioskDebug3D YES` | 3D debug overlay and frame-stat logging. |
| `-kioskSimulatePayment YES\|NO` | Override simulated payments. |
| `-kioskHideDebugBar YES\|NO` | Override debug bar visibility. |
| `-kioskForceError <name>` | Same as *Simulate error*: `declined`, `timeout`, `offline`, `paymentOffline`, `notConfigured`, `notAuthorized`, `noReader`, `readerFailedToStart`, `screenShared`, `notFullScreen`, `unsupportedMode`, `locationPermission`, `orderRejected`, `alreadyInProgress`, `paidWithoutOrder`, `canceled`, `assets`. Pair with `-kioskScreen name -kioskScript pay` to fail a payment hands-free. |
| `-kioskNoSquare YES` | Don't start Square at all (no permission prompts; useful for screenshots). |

Example: `xcrun simctl launch booted com.adamxu.kiosk -kioskCurrent cup -kioskStep flavors -kioskScript scoops -kioskSlowmo 0.25`

## UI tests

`KioskUITests` pulls the order sheet with real touches in the simulator (to the bottom and held, back up, slow oscillation through the whole travel, flings, a second finger), then checks the sheet came to rest and the app still responds. Paths that hold and reverse within one touch use XCUIAutomation's private `XCPointerEventPath`, as WebDriverAgent does.

```sh
xcodebuild test -project Kiosk.xcodeproj -scheme Kiosk -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)'
```

`StaffUITests` drives the staff screen against a live booth and skips unless it's given one. It acknowledges an alert, round-trips a sold-out toggle, signs in with the PIN after a refused token, and (with a reverse proxy it can take down) makes a change offline, relaunches and checks the change reached the hub. It changes that booth's state, so point it at staging:

```sh
mitmdump --mode reverse:https://techclub-icecream-staging.adamxu.workers.dev --listen-port 8787   # optional, for the offline test
TEST_RUNNER_STAFF_BOOTH_URL=techclub-icecream-staging.adamxu.workers.dev TEST_RUNNER_STAFF_TOKEN=$STAGING_STAFF_TOKEN \
TEST_RUNNER_STAFF_PIN=$STAGING_STAFF_TOKEN TEST_RUNNER_STAFF_PROXY_URL=http://127.0.0.1:8787 \
TEST_RUNNER_STAFF_PROXY_DOWN_FLAG=/tmp/staff-proxy/down \
xcodebuild test -project Kiosk.xcodeproj -scheme Kiosk -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -only-testing:KioskUITests/StaffUITests
```

The offline test creates the flag file to mean "proxy down"; something has to stop the proxy while it exists (a loop that kills and restarts `mitmdump`).

## Staff iPad

A second iPad running this app in the staff role (`KIOSK_ROLE = staff`, or *Staff* at role setup) is the toppings person's screen at the counter. It connects to the hub with `BOOTH_STAFF_TOKEN`, or with a 72-hour session from the staff PIN, which it asks for when it has no token or the hub refuses the one it has. After a PIN sign-in the saved session is tried first on later launches, and when one token is refused it tries the other once before asking for the PIN again. It shows:

- **Connection**: *Live*, *Connecting*, or *Offline, reconnecting* with the time of the last update, so stale data is never shown as current.
- **Alerts**: open alerts, urgent first. Urgent ones are solid coral and the whole screen pulses a coral frame until each is acknowledged (*Got it*); info alerts are dismissed. The first two are full size, and three show before *Show more*.
- **Kiosk**: online or offline and when it was last seen, which screen it's on, the reader's state and battery, the kiosk iPad's battery, and whether Square is signed in. When the kiosk is offline its last health report is dimmed and labeled as possibly out of date.
- **Flavors**: one large toggle per flavor, available or sold out.
- **Recent orders**: the last eight orders from the feed, with each item's vessel, flavors and toppings, and its status.

Acknowledgements and sold-out toggles show at once and keep showing until the hub reflects them. Unsent ones are saved to disk, retried over the socket or `POST /v1/actions` until the hub answers (for up to 10 minutes, across relaunches), and keep their ids so retries are never applied twice. A newer change to the same flavor replaces an unsent older one, so a late retry can't undo it.

## Testing payments

- **Simulator**: the sandbox mock reader works here too: tap **Mock Reader**, add a *Contactless & Chip* reader, check out, then *Tap Card* or *Insert Card*. Or use *Simulate payment success*.
- **Sandbox on device**: tap **Mock Reader** in the debug bar, use the floating button to add a virtual reader, then pay and use the floater to tap/insert/swipe a test card.
- **Production**: use a production application ID and token, and register the app signature (bundle ID + team ID) under *Mobile Payments SDK* in the Developer Console first. Pair the contactless reader with **Readers**.

Square blocks payments while the screen is recorded or mirrored; the kiosk checks for that before creating the order.

## Backend

`server/` is a Cloudflare Worker (TypeScript, pnpm): an HTTP API, one websocket hub, the Square connection, and a few browser pages (receipts, the staff dashboard). The kiosk reports to it, and the toppings person uses another iPad running this app in the staff role. The wire protocol, including auth, versioning, ordering, idempotency and every route, is in [`server/PROTOCOL.md`](server/PROTOCOL.md).

Each feature lives in its own module and exports its routes; `src/index.ts` only concatenates the route tables:

| Module | Routes |
| --- | --- |
| `index.ts` | `/v1/health`, `/v1/ws`, `/v1/state`, `/v1/events`, `/v1/actions`; the cron |
| `booth.ts` | The hub Durable Object: alerts, sold out, kiosk health, order feed |
| `orders.ts`, `logs.ts` | `/v1/orders`, `/v1/logs` |
| `oauth.ts`, `square.ts`, `catalog.ts` | `/v1/square/*`: OAuth, status, refresh, revoke, kiosk credentials; Square HTTP; catalog cache |
| `checkout.ts`, `pricing.ts` | `/v1/checkout`: server-priced Square order creation |
| `receipts.ts` | `/r/<token>`, the public receipt page |
| `stats.ts` | `/v1/stats` |
| `dashboard.ts`, `session.ts` | `/dashboard` (live organizer view, `dashboard-page.ts` holds the HTML and script), PIN sign-in, staff sessions (`/v1/staff/session`) |
| `http.ts` | Errors, auth (bearer and cookie), body parsing, retries |

- Production: `https://techclub-icecream.adamxu.workers.dev/v1/` (account *Adam*; health check at `/v1/health`).
- Staging, for chaos tests: `https://techclub-icecream-staging.adamxu.workers.dev/v1/`, with its own D1 database, hub and tokens.

```
 kiosk iPad ──Bearer BOOTH_TOKEN──┐                       ┌── D1: logs (30 days), orders, checkouts, Square tokens
                                  ├─ Worker: auth, zod,   ┤
 staff iPad ──Bearer STAFF_TOKEN──┤  rate limits, routing ├── Workers Logs: every request and kiosk log line
 dashboard ──PIN session cookie───┘       │               └── Square: OAuth, catalog, CreateOrder
                                          ▼
                     Booth Durable Object (one instance, WebSocket Hibernation, SQLite):
                     sold-out map, flavors, kiosk health, alerts, order feed, revision counter, processed ids
```

- **Hub**: on connect a client gets a snapshot with the hub's revision, then one patch per change carrying the next revision. Clients ignore stale patches and resync when they see a gap, so every client converges after drops and reconnects. Everything lives in SQLite, so eviction or a redeploy loses nothing; a Durable Object alarm raises *Kiosk offline* after 30 s without kiosk contact.
- **Alerts for staff**: customer needs help (urgent), *Kiosk offline* (urgent, clears itself), kiosk health problems lasting 45 s (warning, clear themselves), sold-out changes (info). New paid orders are stored, not alerted; they go to staff as an order feed (`paid`, `preparing`, `ready`, `collected`, `canceled`).
- **Kiosk side** (`Kiosk/Sources/Booth/`): help requests, health snapshots, orders and log lines are written to a durable outbox on the iPad before any send, retried with backoff and jitter, and flushed in order when the network comes back. Every item has a client-generated id and the server dedupes, so retries never double-count. Ordering and Square payments never wait on the backend.

### Square OAuth and checkout

The Worker owns the Square connection. Square tokens expire after 30 days; the daily cron (09:17 UTC production, 09:47 UTC staging) refreshes once a token is 6 days old, and a kiosk credential fetch of a due token refreshes in the background too. The kiosk fetches its token and location from `GET /v1/square/credentials` at launch and every 30 minutes, caches them in the Keychain, and authorizes the Mobile Payments SDK with them; a new token is swapped in only while the attract screen shows. At checkout it asks `POST /v1/checkout` to create the Square order (priced by the server with the same rules and catalog) and falls back to creating it on the device.

Vars in `wrangler.jsonc`: `SQUARE_ENVIRONMENT` (`production` or `sandbox`; production uses `production`, staging `sandbox`), `SQUARE_LOCATION_ID` (empty: the first active location that takes cards), `SQUARE_CATEGORY_NAME` (`TC`). Optional secrets (not in `secrets.required`, so a deploy without them works and the Square routes answer `503 not_configured`):

| Secret | |
| --- | --- |
| `SQUARE_APPLICATION_ID` | The Square application ID for the Worker's environment. Must be the same application the kiosk build uses. |
| `SQUARE_APPLICATION_SECRET` | From the Developer Console's *OAuth* page. Enables the OAuth flow and encrypts stored tokens. |
| `SQUARE_ACCESS_TOKEN` | Static fallback token (staging and tests): served to the kiosk when no OAuth token is stored. |
| `STAFF_PIN` | Staff sign-in for the dashboard and the staff iPad. Without it only `STAFF_TOKEN` signs in. |

One-time connection (per environment):

1. In the Developer Console, open the application, pick *Production* (or *Sandbox* for staging), *OAuth*, and set the redirect URL to `https://techclub-icecream.adamxu.workers.dev/v1/square/oauth/callback` (staging: `https://techclub-icecream-staging.adamxu.workers.dev/v1/square/oauth/callback`).
2. `pnpm wrangler secret put SQUARE_APPLICATION_ID` and `pnpm wrangler secret put SQUARE_APPLICATION_SECRET` (add `--env staging` for staging).
3. `set -a; . ~/.config/techclub-icecream/secrets.env; set +a; pnpm square` opens Square's authorize page; sign in as the seller and allow. `pnpm square status`, `pnpm square refresh` and `pnpm square revoke` manage it afterwards (staging: prefix `BOOTH_URL=https://techclub-icecream-staging.adamxu.workers.dev STAFF_TOKEN=$STAGING_STAFF_TOKEN`).

Staging currently runs on the sandbox personal access token as `SQUARE_ACCESS_TOKEN` (source `static`), so checkout works there without the OAuth step.

Secrets are Worker secrets and never committed. The owner's copies are in `~/.config/techclub-icecream/secrets.env` (`BOOTH_TOKEN`, `STAFF_TOKEN`, and `STAGING_BOOTH_TOKEN` / `STAGING_STAFF_TOKEN` for staging). The kiosk's copy goes in `Config/Local.xcconfig` as `BOOTH_TOKEN`; `-boothURL` and `-boothToken` launch arguments override it for testing. To rotate one:

```sh
cd server
pnpm wrangler secret put BOOTH_TOKEN                  # add --env staging for staging
```

Develop, test and deploy:

```sh
cd server
pnpm install
pnpm test                  # Vitest in the Workers runtime: dedupe, ordering, convergence, auth, malformed input, alarm, eviction
pnpm typecheck
pnpm db:migrate            # apply server/migrations to production D1 (add --env staging for staging)
pnpm run deploy            # production; `pnpm wrangler deploy --env staging` for staging
set -a; . ~/.config/techclub-icecream/secrets.env; set +a
pnpm smoke --offline       # live end-to-end check of production (add --checkout on staging to create a real sandbox order)
pnpm chaos                 # staging: drops, half-open sockets, a redeploy, replays, clock skew, a long offline spell
```

`pnpm smoke` leaves a few rows tagged `smoke-...` in production D1 (simulated orders, excluded from totals). `scripts/chaos-proxy.mjs` also runs on its own as a local proxy for testing the iPad app against staging (`node scripts/chaos-proxy.mjs`, then launch the app with `-boothURL http://127.0.0.1:8790 -boothToken <staging token>` and drive the proxy with `curl -X POST localhost:8791/mode/down`, `/mode/up`, `/mode/blackhole`, `/kill`).

## Not production-ready yet

- Production needs the one-time Square OAuth connection above. Until then the kiosk uses the token baked into its bundle, which Square doesn't allow for production.
- `MockReaderUI` is linked into every build. Remove it from the target before shipping.
- Digital receipts (the EMV requirement that buyers are offered one): the confirmation screen shows a QR code to `/r/<token>`, a mobile receipt page with items, tax, total, card and a Square receipt link. The QR code needs the backend URL (`BOOTH_URL`); without it the screen falls back to suggesting a photo. If the backend is down at payment time, the page shows "your receipt will appear shortly" until the order uploads (the kiosk retries). Not yet tried on a physical iPad with a real card.
- Lock the iPad to the app with Guided Access (Settings → Accessibility).
- The terms only allow attended use: the kiosk must be within staff line of sight and inaccessible outside business hours.

Fonts: Noto Serif (SIL Open Font License). Icons: Lucide (ISC). Licenses are in `Kiosk/Resources/Licenses/`.
