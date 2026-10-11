<img src="assets/icon.svg" width="64" height="64" alt="">

# kiosk

Self-order ice cream kiosk for the Tech Club fundraiser booth. SwiftUI + RealityKit on a single 13" iPad Pro (M4), portrait only, taking card payments with the [Square Mobile Payments SDK](https://developer.squareup.com/docs/mobile-payments-sdk) (2.6.0).

## Setup

1. Xcode 26.2 (iOS 26.2 SDK). Deployment target is iOS 26.0.
2. `cp Config/Local.xcconfig.example Config/Local.xcconfig` and fill in:
   - `DEVELOPMENT_TEAM` / `PRODUCT_BUNDLE_IDENTIFIER` for signing.
   - `SQUARE_APPLICATION_ID`, `SQUARE_ACCESS_TOKEN`, `SQUARE_LOCATION_ID` from the [Developer Console](https://developer.squareup.com/apps). A `sandbox-…` application ID puts the app in Sandbox mode.
   - `SQUARE_CATEGORY_NAME`: the catalog category holding the *1 Scoop*, *2nd Scoop*, *3rd+ Scoop* and *Waffle Cone* items (one fixed-price variation each). If it's missing or its prices don't match the kiosk's, orders fall back to ad-hoc line items and the debug bar shows the error.
   - `KIOSK_EVENT_NAME`, shown on the receipt screen.
3. `xcodegen generate` (the project is generated from `project.yml`; rerun after adding source files), open `Kiosk.xcodeproj`, pick the iPad, Run.

`Kiosk/Resources/3D/` is a folder reference, so new or updated 3D assets are bundled without regenerating the project (do a clean build if Xcode misses a change). The Metal morph kernel is compiled at launch, so the separate Metal toolchain download isn't needed.

## Flow

1. **Role setup** (every launch): pick *Kiosk*. Other roles are placeholders.
2. **Attract**: looping `loop.mp4`. *Begin Order* appears once every 3D asset is preloaded; tapping anywhere starts an order.
3. **Builder** (one RealityView behind the SwiftUI controls holds every 3D object):
   - *Vessel*: Cup (included) or Waffle Cone (+$1.50). Selecting flies the new vessel out of its icon while the old one spins back into its slot. Drag the item to orbit it; it eases back and resumes spinning.
   - *Flavors*: tap a flavor to fling a scoop onto the item (up to 3); each card shows what the next scoop costs. The card's minus button takes one of that flavor back off.
   - *Toppings*: placeholder, then *Add to Order* flies the item into the tray.
   - The step selector at the top jumps between steps that are already reachable.
   - Tray: a pinned *New item* slot, live 3D minis (drag to scroll), *View Order* with the live total, and start-over (with confirmation). Tapping a mini lifts it back out to edit. Leaving an edit keeps the changes: *Done*, *New item*, tapping another mini or *View Order* return the item to its slot. The minus badge on its empty slot removes it (after a confirmation); an item edited down to no scoops asks to be removed. *New item* outside an edit adds the item being built to the order and starts a fresh cup.
4. **Your order**: *View Order* grows the tray's glass into a sheet over the builder; each item's 3D model rides up from its tray slot into its row, with edit (pencil) and remove (trash) buttons. Below are the total and *Check Out*. *Keep ordering*, or pulling the sheet down, folds it back into the tray with the items riding back into their slots, revealing a fresh builder that was set up while the sheet covered it.
5. **Name**: the name becomes the Square order's ticket name and pickup recipient.
6. **Payment**: creates a Square order from the catalog (one line per scoop, priced by its position in the whole order, plus one line per waffle cone; taxes auto-applied by Square), then `startPayment` for Square's total. On failure the customer returns to their order and an alert explains what went wrong; a cancel just returns them to it.
7. **Confirmation**: an itemized receipt of what Square charged, a prompt to photograph it, and *New Order*. Returns to the attract screen after 10 s without a touch.

Pricing: scoops are priced by their position in the whole order: the first is $4, the second $3, and every one after that $2 (so 1 → $4, 2 → $7, 3 → $9). Waffle cones are $1.50 each.

## Debug bar

Top of the screen: Square environment, authorization, readers, *Mock Reader* (sandbox), *Readers* settings, *Log*, and a *Debug* menu:

- *Simulate payment success*: skips Square and shows a test receipt (on by default in the simulator).
- *Animation speed*: 0.5×, 0.25×, 0.1× slow motion for the 3D timeline.
- *Show 3D debug info*: frame-time stats (p50/p99/max frame time, CPU time of the per-frame update), alignment markers for the icons, and frame stats and hitches written to the log every 5 s.
- *Change role*, *Hide debug bar*. Triple-tap the top-left corner to bring the bar back.

The log is also written to `Documents/kiosk.log`.

## Launch arguments (testing)

Pass in the scheme or with `xcrun simctl launch <udid> com.adamxu.kiosk -kioskScreen builder …`:

| Argument | Effect |
| --- | --- |
| `-kioskRole kiosk` | Skip role setup. |
| `-kioskScreen attract\|builder\|summary\|name\|confirmation` | Open a screen directly. |
| `-kioskStep vessel\|flavors\|toppings` | Builder step (implies `builder`). |
| `-kioskCurrent "cone:vanilla,chocolate"` | Item being customized. |
| `-kioskItems "cup:cookies;cone:vanilla"` | Items already in the tray. |
| `-kioskName Alex` | Prefill the name. |
| `-kioskScript <name>` | Scripted taps: `vessel-to-cone`, `vessel-pingpong`, `bounce`, `scoops`, `scoops-rapid`, `back-swap`, `add-to-order`, `drag`, `tray-remove`, `remove-middle`, `edit`, `edit-scroll`, `edit-done`, `edit-new`, `edit-switch`, `edit-empty`, `fresh`, `summary`, `pull-down`, `press-hold`, `swap-continue`, `vessel-spam`, `demo`. |
| `-kioskScript stress\|stress-tray` | Rapid random taps (cup/cone, flavors, minus, steps; `stress-tray` adds New item, tray edits, deletes and the order sheet), then a check that the settled 3D scene matches the order. Results go to the log as `Stress:` lines. `-kioskSeed N` and `-kioskStressRounds N` make a run repeatable. |
| `-kioskAutoplay YES` | Same as `-kioskScript demo`: the whole flow through a simulated payment. |
| `-kioskSlowmo 0.25` | Slow motion. |
| `-kioskDebug3D YES` | 3D debug overlay and frame-stat logging. |
| `-kioskSimulatePayment YES\|NO` | Override simulated payments. |
| `-kioskHideDebugBar YES\|NO` | Override debug bar visibility. |
| `-kioskNoSquare YES` | Don't start Square at all (no permission prompts; useful for screenshots). |

Example: `xcrun simctl launch booted com.adamxu.kiosk -kioskCurrent cup -kioskStep flavors -kioskScript scoops -kioskSlowmo 0.25`

## Testing payments

- **Simulator**: Square's payment sheet opens but can't take a card; use *Simulate payment success*.
- **Sandbox on device**: tap **Mock Reader** in the debug bar, use the floating button to add a virtual reader, then pay and use the floater to tap/insert/swipe a test card.
- **Production**: use a production application ID and token, and register the app signature (bundle ID + team ID) under *Mobile Payments SDK* in the Developer Console first. Pair the contactless reader with **Readers**.

Square blocks payments while the screen is recorded or mirrored; the kiosk checks for that before creating the order.

## Not production-ready yet

- The access token is baked into the app bundle. Square requires OAuth (tokens expire every 30 days) for production. Move order creation and token handling to a small backend.
- `MockReaderUI` is linked into every build. Remove it from the target before shipping.
- Buyers must be offered a digital or printed receipt (EMV requirement). The confirmation screen shows an itemized receipt and suggests a photo; there are no email receipts yet.
- Lock the iPad to the app with Guided Access (Settings → Accessibility).
- The terms only allow attended use: the kiosk must be within staff line of sight and inaccessible outside business hours.

Fonts: Noto Serif (SIL Open Font License). Icons: Lucide (ISC). Licenses are in `Kiosk/Resources/Licenses/`.
