<img src="assets/icon.svg" width="64" height="64" alt="">

# kiosk

Self-order ice cream kiosk for the Tech Club fundraiser booth. SwiftUI + RealityKit on 13" iPad Pros (M4), portrait only, one or more kiosks side by side (planned for up to 3), taking card payments with the [Square Mobile Payments SDK](https://developer.squareup.com/docs/mobile-payments-sdk) (2.6.0).

## Setup

1. Xcode 26.2 (iOS 26.2 SDK). Deployment target is iOS 26.0.
2. `cp Config/Local.xcconfig.example Config/Local.xcconfig` and fill in:
   - `DEVELOPMENT_TEAM` / `PRODUCT_BUNDLE_IDENTIFIER` for signing.
   - `SQUARE_APPLICATION_ID` from the [Developer Console](https://developer.squareup.com/apps). A `sandbox-…` application ID puts the app in Sandbox mode.
   - `SQUARE_ACCESS_TOKEN`, `SQUARE_LOCATION_ID`: a dev fallback only. The kiosk gets its access token and location from the [backend](#square-oauth-and-checkout) and keeps the last ones in the Keychain; the bundled pair is used only until it has reached the backend once.
   - `SQUARE_CATEGORY_NAME`: the catalog category holding the *1 Scoop*, *2nd Scoop*, *3rd+ Scoop*, *Waffle Cone* and *Topping* items (one fixed-price variation each). If it's missing or its prices don't match the kiosk's, orders fall back to ad-hoc line items and the debug bar shows the error.
   - `KIOSK_EVENT_NAME`, shown on the receipt screen.
   - `BOOTH_URL` and `BOOTH_TOKEN` for the [backend](#backend). `BOOTH_URL` is a bare host (`kiosk.jamboree.techclub.pw`) because `//` starts a comment in an xcconfig. Leave them empty to run without the backend; the kiosk works the same either way (with the bundled Square token).
   - Kiosk iPads, optional: `KIOSK_NAME`, the name staff see for this kiosk (for example `Front table`). iOS doesn't let apps read the iPad's own name, so without it a new kiosk shows up as *Kiosk 3F2A* (from its device id) until staff rename it on the [staff pages](#staff-pages); a staff rename wins over `KIOSK_NAME`.
   - Kiosk iPads: `KIOSK_STAFF_PIN`, the staff PIN that unlocks the [debug bar](#debug-bar) on the kiosk itself when the booth is unreachable.
   - Staff iPads only: `KIOSK_ROLE = staff` skips role setup and opens the [staff page](#staff-pages) `STAFF_PAGE` (`scooper` or `toppings`; empty means `scooper`). With `BOOTH_STAFF_TOKEN` set it signs in by itself; without it the page asks for the staff PIN.
3. `xcodegen generate` (the project is generated from `project.yml`; rerun after adding source files), open `Kiosk.xcodeproj`, pick the iPad, Run. Debug builds are compiled optimized (`-O`): the topping simulation is about 40 times slower without it.

`Kiosk/Resources/3D/` is a folder reference, so new or updated 3D assets are bundled without regenerating the project (do a clean build if Xcode misses a change). The Metal morph kernel is compiled at launch, so the separate Metal toolchain download isn't needed.

## Flow

1. **Role setup** (every launch, unless `KIOSK_ROLE` or `-kioskRole` picks one): *Start Kiosk* or *Staff*. Square and the kiosk's backend link start only when the kiosk role is chosen, so a staff iPad never reports itself as a kiosk. *Staff* opens the [staff page](#staff-pages); its *Exit staff mode* (after a confirmation) comes back here, and *Start Kiosk* then starts Square and the backend link without a relaunch. Once the kiosk has started, switching this iPad to staff needs a relaunch.
2. **Attract**: two columns of printed club photos (`Kiosk/Resources/AttractPhotos`, made from the originals by `swift Assets3D/pipeline/attract_photos.swift <photos dir>`) drift up the sides of the screen, and between them the builder's own stage (`StageAttract.swift`) plays an endless build: the toppings fly off the top and the scoops follow, new scoops are flung in from above and toppings tossed and poured on, and the cup drops out the bottom as a waffle cone rises in under the scoops (or the other way round), with a new random combination of 1 to 3 scoops and 1 to 3 toppings each time. It spins for a while between builds, as the builder's item does. *Begin Order* appears once every 3D asset is preloaded; tapping anywhere starts an order with a fresh cup, and coming back to the attract screen starts the build over. While staff have closed this kiosk (each kiosk opens and closes on its own, or all together), the attract scene keeps playing but *Begin Order* is a dimmed *Closed* button and taps do nothing; a customer already ordering is never interrupted. While cups and waffle cones are both sold out, or every flavor is, it shows *Closed* the same way, with "We're out of cups and cones for now" or "We're out of ice cream for now"; a customer mid-order can still finish and pay. The last known open/closed and sold-out state is kept across relaunches and while the backend is unreachable.
3. **Builder** (one RealityView behind the SwiftUI controls holds every 3D object):
   - *Vessel*: Cup (included) or Waffle Cone (+$1.50). A new item starts as a cup, or as a cone while cups are sold out. Selecting flies the new vessel out of its icon while the old one spins back into its slot. Drag the item to orbit it; it eases back and resumes spinning.
   - *Flavors*: tap a flavor to fling a scoop onto the item (up to 3); each card shows what the next scoop costs. The card's minus button takes one of that flavor back off.
   - Sold out (set by staff for every kiosk at once): that flavor, vessel or topping card is dimmed (its 3D icon too), says *Sold out* and can't be tapped. Anything already in the order stays and is paid for as usual, and a sold-out topping already on the item being built can still be tapped off.
   - *Toppings*: the same cards as the vessel and flavor steps, +$0.50 each, in one horizontal carousel (`ToppingCarousel`) that scrolls with momentum, snaps to cards, fades at the screen's sides and shows the next card peeking in, so more toppings only add cards. Each card shows a live 3D icon of its topping (a flat glyph from `ToppingGlyph` if the 3D scene isn't up). A native scroll view of invisible buttons takes the touches; the stage latches its offset once per frame and both the drawn cards and their 3D icons follow that one value, so the icons stay on their cards while scrolling. Tapping a card puts that topping on the item and outlines the card like the selected vessel; tapping it again takes it off. The item keeps its toppings in the order they were added, while the 3D toppings always stack in a fixed layer order (`Topping.stacked`: whip, then the syrups, under the pieces) over a height map of the settled scoops, and the item is framed lower to leave room for them. Gummy bears, M&M's and sprinkles (`CandyKinds.swift`, real size) are tossed from their card as one quick handful (all in the air within about 0.3 s, landed within about 1.2 s) and settled by a small rigid-body simulation (`ScatterLayer`, `ScatterPhysics`) that runs on a background task while they fly, each piece easing from its provisional arc into its recorded fall as soon as that is known: each kind lands on the ice cream and on the candy already there, always as the full serving (8 gummy bears, 8 M&M's, 72 sprinkles; `ScatterLayer.serving` can switch back to a serving that shrinks to fit the top in one loose layer). Pieces that find no room where they're tossed are laid flat on the scoops' shoulders down to about the cup's rim, or rest on lying pieces, but never up a heap, standing on end or on edge. Each layer logs how its pieces landed as a `Scatter:` line (`placed 8/8 (lies …, laid …, perches …, pressed …, lost …) in … ms`) and, for a tap, how long after it the last piece came to rest (`landed … ms after the tap`). Whipped cream (`WhipLayer`) is sprayed on as a fluffy rosette from an invisible dispenser, and chocolate and caramel syrup (`DrizzleLayer`, one `DrizzleStyle` each) are poured over the top in a zigzag with drips in about a second, from a stream that hangs straight down from just above the top of the screen (it passes behind the step's title, which is drawn over the 3D stage); their cards give a squish. A syrup runs two to four long, thin drips down the scoop, each ending in a small bead. Both syrups can go on one item: the second is drizzled across the first in fewer passes, in the order they were added, with both ribbons drawn a little thinner, and taking one off leaves the other and settles whatever rests on it. Syrup poured under candy waits a beat while the candy lifts onto it, so the stream lands beneath the pieces. Whipped cream added under other toppings swells up from beneath them instead of being sprayed over them (and sinks back when it's taken off), and every layer above moves straight to its finished place on the new surface with the same easing: syrup re-drapes and each piece keeps its place and way up, tipping with the surface and set down on it, with no physics while it moves. The same applies when syrup, a scoop or candy beneath changes. Candy sinks into whipped cream a little and stays where it lands on it, and tossed pieces stay under the step's title. Toppings stay on an item when its scoops are taken off (the step is blocked until it has a scoop again) and are restored when the item is lifted back out of the tray to edit. Then *Add to Order* flies the item into the tray.
   - The step selector at the top jumps between steps that are already reachable.
   - Tray: a pinned *New item* slot, live 3D minis (drag to scroll), *View Order* with the live total, and start-over (with confirmation). Tapping a mini lifts it back out to edit. Leaving an edit keeps the changes: *Done*, *New item*, tapping another mini or *View Order* return the item to its slot. The minus badge on its empty slot removes it (after a confirmation); an item edited down to no scoops asks to be removed. *New item* outside an edit adds the item being built to the order and starts a fresh cup.
4. **Your order**: *View Order* grows the tray's glass into a sheet over the builder; each item's 3D model rides up from its tray slot into its row, with edit (pencil) and remove (trash) buttons. Below are the total and *Check Out*. *Keep ordering*, or pulling the sheet down, folds it back into the tray with the items riding back into their slots, revealing a fresh builder that was set up while the sheet covered it.
5. **Name**: the name becomes the Square order's ticket name and pickup recipient.
6. **Payment**: generates a checkout id and an unguessable receipt token on the kiosk, asks the backend to create the Square order (3.5 s budget, then the kiosk does it itself, and skips the backend for a minute), or creates a Square order from the catalog on the device (one line per scoop, priced by its position within its cup or cone, plus one line per waffle cone and one per topping; taxes auto-applied by Square), then `startPayment` for Square's total with Square's default payment screen. Once a card touches the reader, Square's own screens take over (PIN, processing, declines, low gift card balances, card read errors, with retry or cancel). On failure the customer returns to their order and an alert explains in plain words what happened and what to do (copy lives in `PaymentProblem.swift`; the technical error goes to the log); a cancel just returns them to it.
7. **Confirmation**: an itemized receipt of what Square charged (the customer's name, with the order reference such as *Order 3F2A-12* in small type: order numbers count per kiosk, so the reference starts with the kiosk's tag), a QR code to the digital receipt page ("Scan for your receipt"), and *New Order*. Returns to the attract screen after 30 s without a touch (10 s when there is no QR code because BOOTH_URL is unset).

Pricing: each cup or cone is priced on its own, with no discount across items: its first scoop is $4, the second $3 and the third $2 (so 1 → $4, 2 → $7, 3 → $9 per item; two 3-scoop cups are $18). Waffle cones are $1.50 each, and toppings $0.50 each.

## Debug bar

Off on every kiosk by default. Staff turn it on per kiosk with the *Debug* switch on that kiosk's row on the [staff pages](#staff-pages) (also in its sheet, and on the admin page); the kiosk shows or hides it live and keeps the last setting across relaunches. Staff can also unlock it on the kiosk itself, whether or not the booth is reachable: on the attract screen, press and hold the top-left corner for 3 seconds and enter the staff PIN. The kiosk checks the PIN on the iPad first (`KIOSK_STAFF_PIN`, `-kioskStaffPin`, or the last PIN the booth accepted on this iPad, kept as a hash), so it works offline, and otherwise asks the booth (`POST /v1/staff/session`, the same PIN as the staff pages). That shows the bar until it is hidden or the app relaunches; it doesn't change the staff switch. To hide it, tap *Hide* at the end of the bar (or *Debug* > *Hide debug bar*); it stays hidden until staff switch Debug tools on again or someone unlocks it again. Set `KIOSK_STAFF_PIN` on every kiosk iPad so the corner works before the iPad has ever reached the booth. A kiosk with no booth configured at all shows the bar. For development, `-kioskHideDebugBar NO` shows it regardless.

Top of the screen: Square environment, authorization, readers, *Mock Reader* (sandbox), *Readers* settings, *Log*, and a *Debug* menu:

- *Simulate payment success*: skips Square and shows a test receipt (on by default in the simulator). With Square in Production this and *Simulate error* are hidden unless already on, so a customer can't get a free order from a debug bar left showing.
- *Simulate error*: makes the next payment fail in a chosen way (declined, timeout, offline, no reader, screen shared, not authorized, and so on), or shows the attract screen's not-ready notice, so staff can see and demo each message. A red *Forcing* badge shows while one is set.
- *Animation speed*: 0.5×, 0.25×, 0.1× slow motion for the 3D timeline.
- *Show 3D debug info*: frame-time stats (p50/p99/max frame time, CPU time of the per-frame update), alignment markers for the icons, and frame stats and hitches written to the log every 5 s.
- *Change role*, *Hide debug bar* (the same as the *Hide* button on the bar).

The log is also written to `Documents/kiosk.log`.

## Launch arguments (testing)

Pass in the scheme or with `xcrun simctl launch <udid> com.adamxu.kiosk -kioskScreen builder …`:

| Argument | Effect |
| --- | --- |
| `-kioskRole kiosk\|staff` | Skip role setup. |
| `-staffPage scooper\|toppings` | Override `STAFF_PAGE` (any role page name works). |
| `-boothURL <url>`, `-boothToken <token>`, `-boothStaffToken <token>` | Override `BOOTH_URL`, `BOOTH_TOKEN`, `BOOTH_STAFF_TOKEN`. |
| `-kioskScreen attract\|builder\|summary\|name\|confirmation` | Open a screen directly. |
| `-kioskStep vessel\|flavors\|toppings` | Builder step (implies `builder`). |
| `-kioskCurrent "cone:vanilla,chocolate+whip"` | Item being customized, in the item syntax below. |
| `-kioskItems "cup:cookies;cone:vanilla"` | Items already in the tray. Items are separated by `;`. Each is `vessel:flavor,flavor` followed by any toppings, each after a `+`, in the order they were added: `"cone:vanilla,chocolate+whip+gummies;cup:cookies+sprinkles"`. Toppings are `whip`, `chocolate`, `caramel`, `gummies`, `mms`, `sprinkles`. `-kioskCurrent` takes the same syntax for one item. |
| `-kioskToppings "whip+gummies"` | Toppings on the item being customized (on `-kioskCurrent`'s item, replacing its toppings, or on an empty cup). |
| `-kioskToppingsScroll sprinkles` | Scroll the toppings carousel to that topping's card (or as far as it goes). |
| `-kioskName "Front table"` | Override `KIOSK_NAME`, the kiosk's name on the staff pages. |
| `-kioskCustomerName Alex` | Prefill the customer's name. |
| `-kioskScript <name>` | Scripted taps: `vessel-to-cone`, `vessel-pingpong`, `bounce`, `scoops`, `scoops-rapid`, `back-swap`, `add-to-order`, `drag`, `tray-remove`, `remove-middle`, `vessel-new`, `edit`, `edit-scroll`, `edit-done`, `edit-new`, `edit-switch`, `edit-empty`, `fresh`, `summary`, `pay`, `pull-down`, `press-hold`, `swap-continue`, `vessel-spam`, `demo`. |
| `-kioskScript toppings\|toppings-tour\|toppings-candy\|toppings-syrups\|toppings-carousel\|toppings-whip\|toppings-retoss` | `toppings` taps topping cards on and off, adds the item to the order and lifts it back out, logging `toppings after edit ... restored` (or `MISMATCH`). `toppings-tour` (adds a vanilla scoop if the item has none) puts whip and syrup on and off under pieces, adds and removes a scoop under the toppings, swaps the vessel, adds the item to the order, edits it and opens the order sheet. Pair with `-kioskCurrent "cone:vanilla,chocolate,cookies"` to tour a 3-scoop cone. `toppings-candy` tosses gummy bears, M&M's and sprinkles on one after another, takes the M&M's back off, adds the item to the order and opens the order sheet. `toppings-syrups` pours chocolate, then caramel across it, tosses gummy bears on top, takes the chocolate out from under the caramel and pours it back over, sprays whipped cream under both, adds the item to the order and opens the order sheet. `toppings-carousel` scrolls the carousel to the middle and the end, tosses sprinkles and gummy bears from the scrolled cards and scrolls back. `toppings-whip` puts whip on and off under whatever the item has, then takes syrup off and back on under it and sprays whip under sprinkles still in the air: pair with `-kioskCurrent "cup:vanilla+chocolate+gummies+mms+sprinkles"`. `toppings-retoss` takes each candy on the item off and tosses it back on, to time tosses with everything else already on. Scripts scroll a card into view before tapping it. |
| `-kioskScript stress\|stress-tray` | Rapid random taps (cup/cone, flavors, minus, steps; `stress-tray` adds New item, tray edits, deletes and the order sheet), then a check that the settled 3D scene matches the order. Results go to the log as `Stress:` lines. `-kioskSeed N` and `-kioskStressRounds N` make a run repeatable. |
| `-kioskScript clip-tour\|clip-interrupts` | Every way a scoop meets a vessel (adds into each slot, cup and cone handovers with 1 to 3 scoops, top, middle and bottom removals), and the same motions cut short by the next tap. With any script, or `-kioskClipCheck YES`, every frame's scoop shapes are tested against every cup and cone: a scoop through a wall is logged as a `Clip:` line with its depth and motion, stress rounds report it as `CLIP`, and the run ends with a `Clip check:` summary. |
| `-kioskScript sheet-stress` | Thousands of randomized pull-down updates on the order sheet (slow oscillation, reversals, past the open position and below the tray, holds, flings, second-finger taps, cancellations), checking that the sheet tracks the finger, always comes to rest open or closed with its items on it, and that the main thread never stalls. Results go to the log as `SheetDrag:` lines; `-kioskSeed` and `-kioskStressRounds` (gestures) apply. `sheet-oscillate` is a slow, recordable version. |
| `-kioskScript attract-interrupts` | From the attract screen (`-kioskRole kiosk`), starts an order at a random moment of the attract scene, checks that the builder got a clean fresh cup with nothing left over from the scene, and goes back to the attract screen, round after round (`-kioskSeed`, `-kioskStressRounds`, 12 by default). Results go to the log as `AttractInterrupts:` lines. |
| `-kioskAutoplay YES` | Same as `-kioskScript demo`: the whole flow through a simulated payment. |
| `-kioskSlowmo 0.25` | Slow motion. |
| `-kioskDebug3D YES` | 3D debug overlay and frame-stat logging. |
| `-kioskSimulatePayment YES\|NO` | Override simulated payments. |
| `-kioskHideDebugBar YES\|NO` | Hide or show the debug bar whatever the staff pages say. |
| `-kioskStaffPin 1234` | Override `KIOSK_STAFF_PIN`, the PIN that unlocks the debug bar from the attract screen's top-left corner. |
| `-kioskForceError <name>` | Same as *Simulate error*: `declined`, `timeout`, `offline`, `paymentOffline`, `notConfigured`, `notAuthorized`, `noReader`, `readerFailedToStart`, `screenShared`, `notFullScreen`, `unsupportedMode`, `locationPermission`, `orderRejected`, `alreadyInProgress`, `paidWithoutOrder`, `canceled`, `assets`. Pair with `-kioskScreen name -kioskScript pay` to fail a payment hands-free. |
| `-kioskNoSquare YES` | Don't start Square at all (no permission prompts; useful for screenshots). |

Example: `xcrun simctl launch booted com.adamxu.kiosk -kioskCurrent cup -kioskStep flavors -kioskScript scoops -kioskSlowmo 0.25`

## UI tests

`KioskUITests` pulls the order sheet with real touches in the simulator (to the bottom and held, back up, slow oscillation through the whole travel, flings, a second finger), then checks the sheet came to rest and the app still responds. `ToppingsCarouselUITests` flings and drags the toppings carousel and checks that it rests on a card, reaches the last card, toggles a scrolled card, and that a drag starting on a card doesn't add it. Paths that hold and reverse within one touch use XCUIAutomation's private `XCPointerEventPath`, as WebDriverAgent does.

```sh
xcodebuild test -project Kiosk.xcodeproj -scheme Kiosk -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)'
```

`StaffUITests` launches the staff role against an unreachable booth and checks the native *Can't reach the booth* screen. The staff pages themselves are web pages, tested in `server/test` and in a browser (see [Staff pages](#staff-pages)).

`BoothRoleUITests` runs against a real booth (staging), and all but one test are skipped unless it gets one: exit staff mode, then *Start Kiosk*, and check the kiosk reaches the booth without a relaunch; switch a kiosk's debug tools and open/closed from the API and check the kiosk follows live and remembers both while the booth is unreachable; mark waffle cones sold out mid-order (the card says *Sold out* and can't be tapped, the cone already in the order stays in the total), then cups too (the attract screen shows *Closed* with the reason), then cones back (a new item starts as a cone); mark whipped cream and M&M's sold out on the toppings step (M&M's can't be added; the whipped cream already on the item can still be taken off, and then can't go back on); resend an assist command while the kiosk is still applying it (one scoop, not two); add a scoop through assist while the customer's *Remove item?* dialog for that emptied item is up (*Remove* keeps it). Each run removes its kiosk from the registry and leaves cups, cones and toppings available. `testStaffPinUnlocksTheDebugBarWithoutTheBooth` needs no booth: it holds the attract screen's corner, enters a wrong PIN and then the right one, and checks the debug bar shows and hides. `testStaffPinUnlocksTheDebugBarWithTheBooth` (also needs `TEST_RUNNER_BOOTH_TEST_STAFF_PIN`) unlocks a connected kiosk with the booth's PIN and then with the kiosk's own, hiding it with *Hide* each time.

```sh
TEST_RUNNER_BOOTH_TEST_URL=https://kiosk-staging.jamboree.techclub.pw TEST_RUNNER_BOOTH_TEST_STAFF_TOKEN=$STAGING_STAFF_TOKEN \
  TEST_RUNNER_BOOTH_TEST_KIOSK_TOKEN=$STAGING_BOOTH_TOKEN xcodebuild test -project Kiosk.xcodeproj -scheme Kiosk \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' -only-testing:KioskUITests/BoothRoleUITests
```

## Staff pages

All staff tooling is the web dashboard served by the backend. Two people work the booth, each with an iPad, and laptops show read-only status displays. Each role has its own page at `/staff/<role>`; `/staff` (and the old `/dashboard`) is a picker, which also lists the [admin page](#admin-page) separately. Pages are listed in `server/src/staff-roles.ts`: a role is a title, whether it is an iPad or a read-only display, how prominent alerts are, and its columns of sections, so adding one is a single entry there.

| Page | For | Shows |
| --- | --- | --- |
| `/staff/scooper` | Scooper + supplies iPad | Make list (oldest first; customer name and each cup or cone with its flavors in large type, toppings in small type) with *Start* (paid to preparing) and *Done* (to ready); the kiosks; sold-out switches for flavors, cups and waffle cones, with the toppings page's sold-out toppings read-only; alerts in a compact list without sound, help requests first. |
| `/staff/toppings` | Toppings + customer service iPad | A *Needs you* section on top with *Acknowledge all*: customer help requests first as large red bars with a chime, then payment and card reader problems (and offline kiosks) as large rows, then other notices in a compact list; orders ready to hand off and coming up, each item's toppings in large type; *Handed off* (to collected), *Cancel*, *Reopen* for finished ones; the kiosks; sold-out switches for toppings, with the scooper's sold-out flavors, cups and cones read-only. |
| `/staff/organizer` | Laptop display | Read-only: today's stats, the order feed, each kiosk's status, sold-out flavors, cups and cones and toppings, and open alerts. |
| `/staff/board` | Laptop display | Read-only: customer names of orders being made and ready for pickup, in large type, without order numbers. |
| `/staff/admin` | Owner, iPad or laptop | [Admin page](#admin-page): asks for the staff PIN every time it opens. |

Customers are called by name, so every page leads with the name; the per-kiosk order number is fine print, followed by the kiosk's name when there is more than one kiosk.

**Kiosks** (both iPads and the organizer display): one row per kiosk with its name, open or closed, online or when it was last heard, and a short health line (card reader, battery, *Debug tools on*). On the iPads each row has its own *Debug* switch for the kiosk's debug tools, and tapping the row opens the kiosk's sheet: rename it (a new kiosk is *Kiosk 3F2A* until renamed or given `KIOSK_NAME`), *Taking orders* to close or reopen it, *Debug tools* to show its debug bar, its full health, and *Remove kiosk* for an offline one that isn't a kiosk any more. Below the rows, *Close all kiosks* and *Open all kiosks*. Alerts name the kiosk they're about (*Customer needs help at Front table*, *Front table is offline*).

**Assist** (both iPads; the toppings iPad is the one meant for customer service): *Assist* in the navigation bar, or in a kiosk's sheet, opens a full-page view of the order on that kiosk, live. With more than one kiosk online it first asks which; opening it always asks for confirmation. Staff can change each item's cup or cone, add and remove scoops (up to 3, never a sold-out flavor) and toppings, add and remove items, set the name for pickup, move the kiosk to the builder, the order review or name entry, and *Start over* (with a confirmation, as for removing an item). The kiosk does the work: each change is a command it applies through its own ordering model, so the customer watches the 3D item change and prices and limits are the kiosk's. The view doesn't wait for it: every tap shows at once in a projected cart (the kiosk's last order plus the changes still on their way, priced by the same rules), so staff can tap several changes quickly. The kiosk plays them strictly in order at the pace of a person tapping, while the view says how many changes are still playing. If the kiosk refuses one (a flavor just sold out, a 4th scoop, the customer removed that item, payment started), that change and the ones that depended on it are dropped, the view snaps to what the kiosk has, and a short notice says what didn't happen and why. While the view is open the kiosk shows a small "A staff member is helping you" note at the top. Payment always stays on the kiosk on Square's screen: assist can't start it and is read-only while it runs. Assist needs both the staff iPad and the kiosk online and says plainly when either isn't. Protocol details are in [`server/PROTOCOL.md`](server/PROTOCOL.md#assist-added).

On the iPads the app's staff role is a full-screen web view of `BOOTH_URL/staff/STAFF_PAGE` (no browser chrome, zoom or pull-to-refresh, screen kept awake, sound allowed without a tap). *Exit staff mode* in its navigation bar (only in the app) asks for confirmation and returns the iPad to the role picker, so it can become a kiosk. With `BOOTH_STAFF_TOKEN` configured it trades the token for a staff session (`POST /v1/staff/session`) and puts it in the web view's cookie store as `booth_staff`, so nobody types the PIN. If the page can't load it shows a native *Can't reach the booth* screen with *Retry now* and retries with backoff. In a browser the pages ask for the staff PIN once.

Behavior shared by every page:

- **Confirmations**: anything customers can see asks first in a large in-page dialog that says what will happen: marking a flavor, cups, waffle cones or a topping sold out or available again (including that the kiosks show Closed once cups and cones are both out), closing or reopening a kiosk or all of them, removing a kiosk, and cancelling an order. Exit staff mode asks too. Acknowledging an alert, moving an order along, renaming a kiosk and its debug tools don't.
- **Offline-proof actions**: every change goes into a queue in `localStorage` with its own id and a per-browser device id (`X-Booth-Device`), shows at once, and is sent oldest first as soon as the booth is reachable, including after a reload or relaunch. A newer change to the same sold-out item, order, kiosk flag or kiosk name replaces an unsent older one. Unsent changes older than an hour are dropped with a notice.
- **Connection**: *Live*, *Connecting* or *Offline since 2:41 PM*, with a banner saying how many changes are waiting.
- **Sound**: new urgent alerts chime on the toppings page and repeat every 30 s until acknowledged, only in the app's web view. In a browser the pages are silent.
- **Undo**: status changes show a toast with *Undo* for a few seconds.
- **Unattended displays**: pages renew their session cookie (`POST /dashboard/renew`) every 30 minutes, so a display left running never falls back to the PIN prompt.

**Sold out** is split by who notices: the scooper switches flavors and cups and cones, the toppings iPad switches toppings, and each page shows the other's sold-out items read-only. It is booth-wide, so every kiosk follows it. With cups and cones both out the kiosks list as *Closed* (No cups or cones left) until one is back, and with every flavor out as *Closed* (Out of ice cream).

### Admin page

`/staff/admin` is for the owner, on an iPad or a laptop. It always opens on a lock screen asking for the staff PIN, even when the browser is signed in to the staff pages, and the admin session it gets lasts 15 minutes from the last action (4 hours at most) and lives only in the page, so a reload asks again; *Lock* ends it at once. In the staff app, open it with `STAFF_PAGE = admin` or `-staffPage admin`. Sections:

- **Kiosks**: per kiosk, app version, last seen, live connection, Square environment and authorization, card reader and its battery, iPad battery, outbox backlog, current screen, and whether a reset is still pending on it. Actions: send back to the welcome screen (cancels the customer's order, never a payment in progress; asks first), reload the Square catalog, force a resync, debug tools, forget the kiosk (asks first).
- **Logs**: the kiosk log lines stored in D1, by kiosk, level, time window and text, newest first, a page at a time.
- **Square**: connected or not, token source, environment, location, token expiry, the last refresh and its outcome, and a live check that the catalog category has every item at the kiosk's prices (1 Scoop $4, 2nd Scoop $3, 3rd+ Scoop $2, Waffle Cone $1.50, Topping $0.50). *Refresh token now* and *Connect Square*.
- **Orders**: search by customer name, receipt token or link, reference or Square payment id; details, the receipt, the Square payment id, and changing the status by hand. Refunds stay in the Square Dashboard (linked).
- **Self-test**: D1, the live hub, the Square API and the catalog, each green or red.
- **Cleanup**: delete test orders only (simulated, smoke and chaos), and acknowledge every alert.
- **Reset**: erases all orders, stats, alerts, the kiosk registry and names, sold-out and open/closed flags, the hub's processed-id memory, assist sessions, logs, checkouts and receipt links. It keeps the Square connection and tokens, open gift card holds (with their checkouts, so held balances are still released) and the admin audit trail; completed and canceled gift card records go, since Square keeps those payments. Two confirmations: a dialog listing exactly what will be erased with counts, then typing RESET. A backup (JSON of orders, kiosks, alerts and stats) downloads first by default. The reset bumps the booth's epoch: connected kiosks restart their order numbers at #1, clear their cached flags and drop queued items from before the reset right away, offline ones when they reconnect, and the server refuses anything a stale kiosk sends from before it. Do it only when no customer is paying. Details in [`server/PROTOCOL.md`](server/PROTOCOL.md#reset-added).

## Testing payments

- **Simulator**: the sandbox mock reader works here too: tap **Mock Reader**, add a *Contactless & Chip* reader, check out, then *Tap Card* or *Insert Card*. Or use *Simulate payment success*.
- **Sandbox on device**: tap **Mock Reader** in the debug bar, use the floating button to add a virtual reader, then pay and use the floater to tap/insert/swipe a test card.
- **Production**: use a production application ID and token, and register the app signature (bundle ID + team ID) under *Mobile Payments SDK* in the Developer Console first. Pair the contactless reader with **Readers**.

Square blocks payments while the screen is recorded or mirrored; the kiosk checks for that before creating the order.

## Backend

`server/` is a Cloudflare Worker (TypeScript, pnpm): an HTTP API, one websocket hub, the Square connection, and a few browser pages (receipts, the [staff pages](#staff-pages)). The kiosk reports to it; staff use the staff pages on iPads running this app in the staff role and on laptops. The wire protocol, including auth, versioning, ordering, idempotency and every route, is in [`server/PROTOCOL.md`](server/PROTOCOL.md).

Each feature lives in its own module and exports its routes; `src/index.ts` only concatenates the route tables:

| Module | Routes |
| --- | --- |
| `index.ts` | `/v1/health`, `/v1/ws`, `/v1/state`, `/v1/events`, `/v1/actions`; the cron |
| `booth.ts` | The hub Durable Object: alerts, sold out, the kiosk registry (each kiosk's name, open/closed, debug tools, health), order feed, assist relay (live kiosk sessions to staff, commands to the kiosk) |
| `orders.ts`, `logs.ts` | `/v1/orders`, `/v1/logs` |
| `oauth.ts`, `square.ts`, `catalog.ts` | `/v1/square/*`: OAuth, status, refresh, revoke, kiosk credentials; Square HTTP; catalog cache |
| `checkout.ts`, `pricing.ts` | `/v1/checkout`: server-priced Square order creation |
| `receipts.ts` | `/r/<token>`, the public receipt page |
| `stats.ts` | `/v1/stats` |
| `admin.ts`, `admin-page.ts` | `/staff/admin` and `/v1/admin/*`: admin sessions, kiosk diagnostics and controls, logs, Square check, order lookup, self-test, cleanup, backup and reset |
| `dashboard.ts`, `dashboard-page.ts`, `staff-roles.ts`, `session.ts` | `/staff` and `/staff/<role>` pages (shared shell and script in `dashboard-page.ts`, the role list in `staff-roles.ts`), PIN sign-in, session renewal, staff sessions (`/v1/staff/session`) |
| `http.ts` | Errors, auth (bearer and cookie), body parsing, retries |

- Production: `https://kiosk.jamboree.techclub.pw/v1/` (account *Pinewood Tech Club*; health check at `/v1/health`).
- Staging, for chaos tests: `https://kiosk-staging.jamboree.techclub.pw/v1/`, with its own D1 database, hub and tokens.

```
 kiosk iPad ──Bearer BOOTH_TOKEN──┐                       ┌── D1: logs (30 days), orders, checkouts, Square tokens
                                  ├─ Worker: auth, zod,   ┤
 staff pages ─staff session cookie┤  rate limits, routing ├── Workers Logs: every request and kiosk log line
 scripts ────Bearer STAFF_TOKEN───┘       │               └── Square: OAuth, catalog, CreateOrder
                                          ▼
                     Booth Durable Object (one instance, WebSocket Hibernation, SQLite):
                     kiosk registry, sold-out map, flavors, alerts, order feed, revision counter, processed ids
```

- **Hub**: on connect a client gets a snapshot with the hub's revision, then one patch per change carrying the next revision. Clients ignore stale patches and resync when they see a gap, so every client converges after drops and reconnects. Everything lives in SQLite, so eviction or a redeploy loses nothing; a Durable Object alarm raises *<kiosk> is offline* after 30 s without contact from that kiosk.
- **Kiosks**: each kiosk iPad (told apart by its `X-Booth-Device` id) has its own entry, created on first contact: name, open/closed, debug tools, online, screen and health. Staff remove an entry for an iPad that isn't a kiosk any more; entries silent for 7 days go by themselves.
- **Alerts for staff**, per kiosk and naming it: customer needs help (urgent), *<kiosk> is offline* (urgent, a warning while that kiosk is closed, clears itself), kiosk health problems lasting 45 s (warning, clear themselves); plus sold-out changes to flavors, cups and cones and toppings (info; a warning when cups and cones are both out, or every flavor is). New paid orders are stored, not alerted; they go to staff as an order feed (`paid`, `preparing`, `ready`, `collected`, `canceled`).
- **Kiosk side** (`Kiosk/Sources/Booth/`): help requests, health snapshots, orders and log lines are written to a durable outbox on the iPad before any send, retried with backoff and jitter, and flushed in order when the network comes back. Every item has a client-generated id and the server dedupes, so retries never double-count. Ordering and Square payments never wait on the backend. Assist (`BoothLink`, `BoothAssist.swift`, `AppModel+Assist.swift`) is the one live-only feature: the kiosk publishes its session over the socket while connected and plays staff commands from an in-memory queue (`AssistQueue`) in the order staff sent them, one at a time; nothing about it is stored. Admin controls (`attract`, `reloadCatalog`, `resync`) arrive the same way, are applied once per id, and report in the session's `results`; *attract* is refused while a payment is under way. Health also reports the kiosk's reset epoch and its outbox backlog (queued orders and help events).
- **Reset** (kiosk side): every queued order, event and log batch is stamped with the last reset epoch the kiosk has seen (unstamped until it has seen one). When a snapshot carries a higher epoch, before applying the rest of it the kiosk restarts its order numbers at #1, forgets its cached open, debug, name and sold-out state, drops queued items from before the reset (logging each dropped order's number, reference, total and checkout id to `kiosk.log`), stops uploading log lines written before it, forgets assist and control ids, and resends its session and health. A kiosk offline during the reset does all of this on reconnect. A customer mid-order or paying is never interrupted; the booth answers anything from an older epoch `stale` and the kiosk drops it.

### Square OAuth and checkout

The Worker owns the Square connection. Square tokens expire after 30 days; the daily cron (09:17 UTC production, 09:47 UTC staging) refreshes once a token is 6 days old, and a kiosk credential fetch of a due token refreshes in the background too. The kiosk fetches its token and location from `GET /v1/square/credentials` at launch and every 30 minutes, caches them in the Keychain, and authorizes the Mobile Payments SDK with them; a new token is swapped in only while the attract screen shows. At checkout it asks `POST /v1/checkout` to create the Square order (priced by the server with the same rules and catalog) and falls back to creating it on the device.

Vars in `wrangler.jsonc`: `SQUARE_ENVIRONMENT` (`production` or `sandbox`; production uses `production`, staging `sandbox`), `SQUARE_LOCATION_ID` (empty: the first active location that takes cards), `SQUARE_CATEGORY_NAME` (`TC`). Optional secrets (not in `secrets.required`, so a deploy without them works and the Square routes answer `503 not_configured`):

| Secret | |
| --- | --- |
| `SQUARE_APPLICATION_ID` | The Square application ID for the Worker's environment. Must be the same application the kiosk build uses. |
| `SQUARE_APPLICATION_SECRET` | From the Developer Console's *OAuth* page. Enables the OAuth flow and encrypts stored tokens. |
| `SQUARE_ACCESS_TOKEN` | Static fallback token (staging and tests): served to the kiosk when no OAuth token is stored. |
| `STAFF_PIN` | Staff sign-in for the staff pages in a browser. Without it only `STAFF_TOKEN` signs in. |

One-time connection (per environment):

1. In the Developer Console, open the application, pick *Production* (or *Sandbox* for staging), *OAuth*, and set the redirect URL to `https://kiosk.jamboree.techclub.pw/v1/square/oauth/callback` (staging: `https://kiosk-staging.jamboree.techclub.pw/v1/square/oauth/callback`).
2. `pnpm wrangler secret put SQUARE_APPLICATION_ID` and `pnpm wrangler secret put SQUARE_APPLICATION_SECRET` (add `--env staging` for staging).
3. `set -a; . ~/.config/techclub-icecream/secrets.env; set +a; pnpm square` opens Square's authorize page; sign in as the seller and allow. `pnpm square status`, `pnpm square refresh` and `pnpm square revoke` manage it afterwards (staging: prefix `BOOTH_URL=https://kiosk-staging.jamboree.techclub.pw STAFF_TOKEN=$STAGING_STAFF_TOKEN`).

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

Right after the 2026-10-11 production deploy that added the order feed, `POST /v1/orders` answered `503 unavailable` (hub call failed) for about three minutes, then recovered with no change; the order is already in D1 by then and the kiosk's retry completes it. If `pnpm smoke` fails only at *order stored* right after a deploy, wait a few minutes and run it again.

`pnpm smoke` leaves a few rows tagged `smoke-...` in production D1 (simulated orders, excluded from totals). `scripts/chaos-proxy.mjs` also runs on its own as a local proxy for testing the iPad app against staging (`node scripts/chaos-proxy.mjs`, then launch the app with `-boothURL http://127.0.0.1:8790 -boothToken <staging token>` and drive the proxy with `curl -X POST localhost:8791/mode/down`, `/mode/up`, `/mode/blackhole`, `/kill`).

## Not production-ready yet

- Production needs the one-time Square OAuth connection above. Until then the kiosk uses the token baked into its bundle, which Square doesn't allow for production.
- `MockReaderUI` is linked into every build. Remove it from the target before shipping.
- Digital receipts (the EMV requirement that buyers are offered one): the confirmation screen shows a QR code to `/r/<token>`, a mobile receipt page with items, tax, total, card and a Square receipt link. The QR code needs the backend URL (`BOOTH_URL`); without it the screen falls back to suggesting a photo. If the backend is down at payment time, the page shows "your receipt will appear shortly" until the order uploads (the kiosk retries). Not yet tried on a physical iPad with a real card.
- Lock the iPad to the app with Guided Access (Settings → Accessibility).
- The terms only allow attended use: the kiosk must be within staff line of sight and inaccessible outside business hours.

Fonts: Noto Serif (SIL Open Font License). Icons: Lucide (ISC). Gummy bear model: "Gummy Bears" by Styro (CC-BY-4.0), modified. Licenses are in `Kiosk/Resources/Licenses/`.
