import Observation
import SwiftUI

@Observable
@MainActor
final class AppModel {
    enum Screen: Equatable { case roleSetup, attract, builder, name, confirmation, staff }
    enum DeviceRole: String { case kiosk, staff }
    enum BuilderMode: Equatable { case customize, summary }

    struct Notice: Equatable {
        let title: String
        let details: [String]

        var message: String {
            details
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { $0.last.map { ".!?".contains($0) } == true ? $0 : $0 + "." }
                .joined(separator: " ")
        }
    }

    /// Where to go once the item being edited has been put back.
    enum AfterEdit: Equatable {
        case newItem
        case edit(UUID)
        case viewOrder
    }

    enum Confirmation: Identifiable, Equatable {
        case removeEmptyEdit(then: AfterEdit)
        case deleteItem(UUID)
        case startOver

        var id: String {
            switch self {
            case .removeEmptyEdit: "remove-empty"
            case .deleteItem(let id): "delete-\(id)"
            case .startOver: "start-over"
            }
        }
    }

    var screen: Screen = .roleSetup {
        didSet {
            guard screen != oldValue else { return }
            if screen == .attract { square.reauthorizeIfIdle() }
            leavingScreen = oldValue
            leavingTask?.cancel()
            leavingTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(0.6))
                if !Task.isCancelled { self?.leavingScreen = nil }
            }
        }
    }
    /// The screen just left, kept for the length of a crossfade so it stays drawn until covered.
    private(set) var leavingScreen: Screen?
    @ObservationIgnored private var leavingTask: Task<Void, Never>?
    var builderVisible = false
    private(set) var mode: BuilderMode = .customize
    private(set) var step: BuilderStep = .vessel
    private(set) var current = IceCreamItem() {
        didSet { if current.toppings != oldValue.toppings { stage.setToppings(current.toppings, itemID: current.id) } }
    }
    private(set) var items: [IceCreamItem] = []
    private(set) var editingID: UUID?
    private(set) var stageReady = false
    private var assetLoadFailed = false
    var assetsFailed: Bool { assetLoadFailed || forcedError == .assets }
    var forcedError: ForcedError?
    private(set) var pressedCards: Set<CardKey> = []
    /// The cards draw a flat glyph in each icon area until the stage draws its 3D icons there.
    private(set) var stageDrawsToppingIcons = false
    var toppingsScroll = ScrollPosition(idType: Topping.self)
    var confirmation: Confirmation?
    var notice: Notice?
    var receipt: Receipt?
    var customerName = ""
    private(set) var isPaying = false

    var debugBarHidden: Bool {
        didSet { UserDefaults.standard.set(debugBarHidden, forKey: "debugBarHidden") }
    }
    var simulatePayment: Bool
    var slowMotion: Double = 1 {
        didSet { stage.timeScale = slowMotion }
    }
    var show3DDebug = false {
        didSet { stage.logsHitches = show3DDebug }
    }
    var showsLog = false

    let square = SquareService()
    let booth = BoothLink()
    let staff = StaffLink()
    private(set) var role: DeviceRole?
    private var kioskServicesStarted = false
    @ObservationIgnored let stage = Stage()
    @ObservationIgnored let host = ViewControllerHost()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var transitionTask: Task<Void, Never>?
    /// The builder still shows what it held when the order opened, until the sheet covers it.
    @ObservationIgnored private var builderResetPending = false

    init() {
        let defaults = UserDefaults.standard
        debugBarHidden = defaults.bool(forKey: "debugBarHidden")
        simulatePayment = false
        forcedError = defaults.string(forKey: "kioskForceError").flatMap(ForcedError.init(rawValue:))
    }

    /// Everything that would be charged right now, with the item being edited in place of its saved version.
    var liveQuote: OrderQuote {
        guard mode == .customize else { return orderQuote }
        var basket = items
        if let editingID, let index = basket.firstIndex(where: { $0.id == editingID }) {
            basket[index] = current
        } else if current.hasChoices {
            basket.append(current)
        }
        return Pricing.quote(basket)
    }

    var orderQuote: OrderQuote { Pricing.quote(items) }

    var canViewOrder: Bool { !items.isEmpty || current.scoopCount > 0 }

    var isEditing: Bool { editingID != nil }

    var canContinue: Bool {
        switch step {
        case .vessel: true
        case .flavors, .toppings: current.scoopCount > 0
        }
    }

    /// What one more scoop adds to the order: scoops are billed by their position in the whole order.
    var nextScoopCents: Int {
        Pricing.scoopCents(atPosition: liveQuote.scoopCount + 1)
    }

    func count(of flavor: Flavor) -> Int {
        current.flavors.filter { $0 == flavor }.count
    }

    var editingIndex: Int? {
        editingID.flatMap { id in items.firstIndex { $0.id == id } }
    }

    /// The tray's New item slot: finishes the edit, or adds the item being built, then starts a fresh cup.
    var canStartNewItem: Bool {
        mode == .customize && (isEditing || current.scoopCount > 0)
    }

    func start() {
        guard !started else { return }
        started = true
        stage.log = { [weak self] in self?.square.record($0) }
        stage.onSheetCovered = { [weak self] in self?.resetBuilderUnderSheet() }
        square.canReauthorize = { [weak self] in self?.screen == .attract || self?.screen == .roleSetup }
        switch LaunchOptions.current.role {
        case DeviceRole.staff.rawValue: chooseStaffRole()
        case DeviceRole.kiosk.rawValue: startKioskServices()
        default: break
        }
        Task {
            while true {
                try? await Task.sleep(for: .seconds(5))
                guard show3DDebug else { continue }
                let s = stage.stats.summary()
                square.record(String(format: "Frames (5 s window): %.0f fps, p50 %.2f ms, p99 %.2f ms, max %.2f ms; update CPU p99 %.3f ms, max %.3f ms (%d frames)",
                                     s.fps, s.p50 * 1000, s.p99 * 1000, s.max * 1000, s.cpuP99 * 1000, s.cpuMax * 1000, s.samples))
                stage.stats.reset()
            }
        }
        Task {
            let assets = forcedError == .assets ? nil : await AssetLibrary.load(log: { [weak self] in self?.square.record($0) })
            if let assets {
                stage.build(with: assets)
                stageDrawsToppingIcons = true
                assets.checkContacts { [weak self] in self?.square.record($0) }
                stageReady = true
                try? await Task.sleep(for: .seconds(0.4))
                applyLaunchOptions()
            } else {
                assetLoadFailed = true
                square.record(forcedError == .assets ? "3D assets failed to load (forced)" : "3D assets failed to load")
                if LaunchOptions.current.role == DeviceRole.kiosk.rawValue, screen == .roleSetup { enterKioskRole(animated: false) }
            }
        }
    }

    /// Square and the kiosk's booth link run only on the kiosk iPad: a staff iPad must never report itself as the kiosk.
    private func startKioskServices() {
        guard !kioskServicesStarted, role != .staff else { return }
        kioskServicesStarted = true
        role = .kiosk
        booth.start(square: square, app: self)
        if UserDefaults.standard.bool(forKey: "kioskNoSquare") {
            square.record("Square disabled by -kioskNoSquare")
        } else {
            square.start()
        }
    }

    var canChooseStaff: Bool { !kioskServicesStarted }
    var canChooseKiosk: Bool { role != .staff }

    func chooseKioskRole() {
        enterKioskRole(animated: true)
    }

    private func enterKioskRole(animated: Bool) {
        guard canChooseKiosk else { return }
        startKioskServices()
        if animated {
            withAnimation(.easeInOut(duration: 0.5)) { screen = .attract }
        } else {
            screen = .attract
        }
    }

    func chooseStaffRole() {
        guard canChooseStaff else { return }
        role = .staff
        staff.start { [weak self] in self?.square.record($0) }
        withAnimation(.easeInOut(duration: 0.5)) { screen = .staff }
    }

    func changeRole() {
        resetEverything()
        withAnimation(.easeInOut(duration: 0.35)) { screen = .roleSetup }
    }

    func beginOrder() {
        guard stageReady, !assetsFailed, screen == .attract else { return }
        resetEverything()
        stage.restore(current: current, items: [], step: .vessel)
        builderVisible = true
        withAnimation(.easeInOut(duration: 0.5)) { screen = .builder }
    }

    private func resetEverything() {
        transitionTask?.cancel()
        builderResetPending = false
        items = []
        current = IceCreamItem()
        editingID = nil
        mode = .customize
        step = .vessel
        pressedCards = []
        confirmation = nil
        notice = nil
        receipt = nil
        customerName = ""
        stage.reset()
    }

    func resetToAttract() {
        withAnimation(.easeInOut(duration: 0.5)) { screen = .attract }
        transitionTask?.cancel()
        transitionTask = Task {
            try? await Task.sleep(for: .seconds(0.6))
            guard !Task.isCancelled, screen == .attract else { return }
            resetEverything()
        }
    }

    func setPressed(_ card: CardKey, _ pressed: Bool) {
        if pressed {
            pressedCards.insert(card)
        } else {
            pressedCards.remove(card)
        }
        stage.setPressed(card, pressed)
    }

    func scrollToppings(to topping: Topping) {
        toppingsScroll.scrollTo(x: Layout.toppingCarouselOffset(topping))
    }

    func selectVessel(_ vessel: Vessel) {
        guard screen == .builder, mode == .customize, step == .vessel, vessel != current.vessel else { return }
        current.vessel = vessel
        stage.swapVessel(to: vessel)
    }

    func addScoop(_ flavor: Flavor) {
        guard screen == .builder, mode == .customize, step == .flavors,
              current.scoopCount < Pricing.maxScoopsPerItem, !booth.isSoldOut(flavor) else { return }
        current.flavors.append(flavor)
        stage.addScoop(flavor)
    }

    /// Removes the top-most scoop of that flavor; scoops above it settle down one slot.
    func removeScoop(_ flavor: Flavor) {
        guard screen == .builder, mode == .customize, let index = current.flavors.lastIndex(of: flavor) else { return }
        current.flavors.remove(at: index)
        stage.removeScoop(at: index)
    }

    func hasTopping(_ topping: Topping) -> Bool {
        current.toppings.contains(topping)
    }

    func toggleTopping(_ topping: Topping) {
        hasTopping(topping) ? removeTopping(topping) : addTopping(topping)
    }

    func addTopping(_ topping: Topping) {
        guard screen == .builder, mode == .customize, step == .toppings, current.scoopCount > 0,
              !hasTopping(topping) else { return }
        setToppings(current.toppings + [topping])
    }

    func removeTopping(_ topping: Topping) {
        guard screen == .builder, mode == .customize, hasTopping(topping) else { return }
        setToppings(current.toppings.filter { $0 != topping })
    }

    private func setToppings(_ toppings: [Topping]) {
        current.toppings = toppings
    }

    func canJump(to target: BuilderStep) -> Bool {
        target != .toppings || current.scoopCount > 0
    }

    func jumpToStep(_ target: BuilderStep) {
        guard mode == .customize, target != step, canJump(to: target) else { return }
        setStep(target)
    }

    func goForward() {
        guard canContinue else { return }
        switch step {
        case .vessel: setStep(.flavors)
        case .flavors: setStep(.toppings)
        case .toppings: isEditing ? finishEditing(then: .newItem) : addToOrder()
        }
    }

    func goBack() {
        switch step {
        case .vessel: break
        case .flavors: setStep(.vessel)
        case .toppings: setStep(.flavors)
        }
    }

    private func setStep(_ newStep: BuilderStep) {
        if newStep == .toppings, step != .toppings {
            toppingsScroll = ScrollPosition(idType: Topping.self)
            stage.reportToppingScroll(0)
        }
        step = newStep
        stage.setStep(newStep, animated: true)
    }

    func addToOrder() {
        guard current.scoopCount > 0, !isEditing else { return }
        let item = current
        items.append(item)
        stage.sendCurrentToTray(item)
        startNextItem()
    }

    /// Leaving an edit keeps what the customer sees: the edited item is already live at the center and in
    /// the total, so it is saved rather than asking Save / Discard. Only an item emptied of scoops needs a
    /// decision, because it can't stay in the order.
    func finishEditing(then next: AfterEdit) {
        guard let editingID, let index = editingIndex else {
            proceed(to: next)
            return
        }
        guard current.scoopCount > 0 else {
            confirmation = .removeEmptyEdit(then: next)
            return
        }
        items[index] = current
        stage.returnHeroToEntry(editingID, item: current)
        self.editingID = nil
        current = IceCreamItem()
        proceed(to: next)
    }

    private func proceed(to next: AfterEdit) {
        switch next {
        case .newItem: startNextItem()
        case .edit(let id): edit(id)
        case .viewOrder: viewOrder()
        }
    }

    func startNewItem() {
        guard canStartNewItem else { return }
        if isEditing {
            finishEditing(then: .newItem)
        } else {
            addToOrder()
        }
    }

    /// Already on Vessel, the controls stay put and only the 3D hero changes; from a later step it's an
    /// ordinary step change back to Vessel.
    private func startNextItem() {
        current = IceCreamItem()
        setStep(.vessel)
        stage.presentNewItem(vessel: .cup, delay: 0.3)
    }

    /// Editing another item never throws work away: an edit in progress is saved, and an item being
    /// built that already has scoops is added to the order first.
    func tapTrayItem(_ id: UUID) {
        guard screen == .builder, id != editingID, items.contains(where: { $0.id == id }) else { return }
        if isEditing {
            finishEditing(then: .edit(id))
            return
        }
        if mode == .customize, current.scoopCount > 0 {
            let item = current
            items.append(item)
            stage.sendCurrentToTray(item)
            current = IceCreamItem()
        }
        edit(id)
    }

    func edit(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        transitionTask?.cancel()
        if mode == .summary {
            resetBuilderUnderSheet()
            mode = .customize
            stage.settleSheet(open: false, velocity: nil)
        }
        stage.dismissCurrentHero()
        editingID = id
        current = item
        stage.beginEditing(id)
        setStep(.toppings)
    }

    func requestDelete(_ id: UUID) {
        confirmation = .deleteItem(id)
    }

    func delete(_ id: UUID, presentNewItem: Bool = true) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: index)
        if id == editingID {
            editingID = nil
            stage.dismissCurrentHero()
            stage.removeTrayItem(id)
            current = IceCreamItem()
            setStep(.vessel)
            if presentNewItem { stage.presentNewItem(vessel: .cup, delay: 0.3) }
        } else {
            stage.removeTrayItem(id)
        }
        if mode == .summary, items.isEmpty {
            backToBuilder()
        }
    }

    func requestStartOver() {
        confirmation = .startOver
    }

    func confirm(_ confirmation: Confirmation) {
        self.confirmation = nil
        switch confirmation {
        case .removeEmptyEdit(let next):
            guard let editingID else { return }
            delete(editingID, presentNewItem: next == .newItem)
            if next != .newItem { proceed(to: next) }
        case .deleteItem(let id): delete(id)
        case .startOver: resetToAttract()
        }
    }

    /// The order is settled at once; the builder beneath keeps showing its last state until the rising
    /// sheet covers it (`resetBuilderUnderSheet`), so nothing changes on screen except the sheet arriving.
    func viewOrder() {
        guard canViewOrder, mode == .customize else { return }
        if isEditing, current.scoopCount == 0 {
            confirmation = .removeEmptyEdit(then: .viewOrder)
            return
        }
        transitionTask?.cancel()
        stage.openSheet()
        if let editingID, current.scoopCount > 0, let index = items.firstIndex(where: { $0.id == editingID }) {
            items[index] = current
            stage.returnHeroToEntry(editingID, item: current)
        } else if current.scoopCount > 0 {
            items.append(current)
            stage.sendCurrentToTray(current)
        }
        editingID = nil
        notice = nil
        builderResetPending = true
        mode = .summary
    }

    private func resetBuilderUnderSheet() {
        guard builderResetPending, mode == .summary else { return }
        builderResetPending = false
        current = IceCreamItem()
        step = .vessel
        pressedCards = []
        stage.resetBuilderUnderSheet()
    }

    /// `velocity` (points per second, downward) carries a pull-down's fling into the sheet's spring.
    func backToBuilder(velocity: CGFloat = 0) {
        guard mode == .summary else { return }
        notice = nil
        resetBuilderUnderSheet()
        mode = .customize
        stage.settleSheet(open: false, velocity: sheetProgressVelocity(velocity))
    }

    private func sheetProgressVelocity(_ velocity: CGFloat) -> Float {
        -Float(velocity / SheetGeometry.travel) / Float(max(slowMotion, 0.01))
    }

    /// The order's content, and with it the pull-down, stays mounted for as long as the order is up.
    var orderSheetMounted: Bool {
        mode == .summary || SheetGeometry(progress: stage.sheetModel.progress).contentOpacity > 0
    }

    var isPullingSheet: Bool { stage.sheetGrab != nil }

    func dragSheet(by translation: CGFloat) {
        guard mode == .summary else { return }
        stage.dragSheet(by: translation)
    }

    func endSheetDrag(translation: CGFloat, predicted: CGFloat, velocity: CGFloat) {
        guard mode == .summary, isPullingSheet else { return }
        let velocity = velocity.isFinite ? velocity : 0
        if predicted > 280 || (translation > 150 && velocity > -100) {
            backToBuilder(velocity: velocity)
        } else {
            stage.settleSheet(open: true, velocity: sheetProgressVelocity(velocity))
        }
    }

    /// Settles a pull-down that ended without a release (the system cancelled the touch), as if the finger
    /// had lifted where it was without a fling.
    func abandonSheetDrag() {
        guard isPullingSheet else { return }
        guard mode == .summary else {
            stage.settleSheet(open: false, velocity: nil)
            return
        }
        let pulled = (1 - CGFloat(stage.sheet.value)) * SheetGeometry.travel
        endSheetDrag(translation: pulled, predicted: pulled, velocity: 0)
    }

    func completeOrder() {
        guard !items.isEmpty, !isPullingSheet else { return }
        booth.checkReaderBeforePayment()
        notice = nil
        withAnimation(.easeInOut(duration: 0.4)) { screen = .name }
    }

    func backToSummary() {
        mode = .summary
        withAnimation(.easeInOut(duration: 0.4)) { screen = .builder }
    }

    private func nextOrderNumber() -> Int {
        let defaults = UserDefaults.standard
        let number = defaults.integer(forKey: "orderCounter") + 1
        defaults.set(number, forKey: "orderCounter")
        return number
    }

    func submitName() {
        let name = customerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isPaying, !items.isEmpty else { return }
        isPaying = true
        booth.checkReaderBeforePayment()
        let quote = orderQuote
        let number = nextOrderNumber()
        let checkout = CheckoutIdentity.make()
        Task {
            let result: PaymentResult
            if let forcedError, forcedError != .assets {
                result = await square.simulate(forcedError)
            } else if simulatePayment {
                square.record("Simulating payment for order #\(number) (\(quote.totalCents.formattedAsUSD))")
                try? await Task.sleep(for: .seconds(1.2))
                result = .succeeded(.simulated(quote: quote, customerName: name, orderNumber: number,
                                               merchantName: square.merchantName, checkout: checkout))
            } else {
                result = await square.pay(quote: quote, customerName: name, orderNumber: number, checkout: checkout,
                                          from: host.presenter)
            }
            isPaying = false
            switch result {
            case .succeeded(let receipt):
                booth.orderPaid(receipt, quote: quote)
                self.receipt = receipt
                stage.enterReceipt()
                withAnimation(.easeInOut(duration: 0.45)) { screen = .confirmation }
            case .failed(let problem):
                booth.paymentFailed(problem)
                notice = Notice(title: problem.title, details: problem.details)
                backToSummary()
            case .canceled:
                backToSummary()
            }
        }
    }

    private func applyLaunchOptions() {
        let options = LaunchOptions.current
        if let slowmo = options.slowMotion { slowMotion = slowmo }
        if options.debug3D { show3DDebug = true }
        if let simulate = options.simulatePayment { simulatePayment = simulate }
        if let hide = options.hideDebugBar { debugBarHidden = hide }
        if options.role == DeviceRole.kiosk.rawValue, screen == .roleSetup { enterKioskRole(animated: false) }

        if let screenName = options.screen {
            items = options.items
            current = options.current ?? IceCreamItem()
            step = options.step ?? .vessel
            customerName = options.name ?? ""
            switch screenName {
            case "builder":
                screen = .builder
                builderVisible = true
                stage.restore(current: current, items: items, step: step)
            case "summary":
                screen = .builder
                builderVisible = true
                mode = .summary
                current = IceCreamItem()
                step = .vessel
                stage.restore(current: current, items: items, step: .vessel, summary: true)
            case "name":
                current = IceCreamItem()
                step = .vessel
                stage.restore(current: current, items: items, step: .vessel, summary: true)
                mode = .summary
                builderVisible = true
                screen = .name
            case "confirmation":
                stage.restore(current: nil, items: items, step: .vessel, summary: true)
                stage.enterReceipt()
                builderVisible = true
                receipt = .simulated(quote: orderQuote, customerName: customerName.isEmpty ? "Alex" : customerName,
                                     orderNumber: 42, merchantName: square.merchantName)
                screen = .confirmation
            default:
                screen = .attract
            }
        }
        if let topping = options.toppingsScroll {
            Task {
                try? await Task.sleep(for: .seconds(0.5))
                scrollToppings(to: topping)
            }
        }
        if let script = options.script {
            Task { await ScriptRunner(app: self).run(script) }
        }
    }

    func setCustomerNameForScript(_ name: String) { customerName = name }
    func setSummaryScroll(_ offset: CGFloat) {
        stage.summaryScroll = offset
    }
}

/// Square's payment and settings screens must be presented from a UIViewController.
struct ViewControllerHost: UIViewControllerRepresentable {
    let controller = UIViewController()

    /// Presenting from `controller` itself left Square's payment UI hidden behind the SwiftUI
    /// content on iPad, so present from the window's frontmost view controller instead.
    var presenter: UIViewController {
        var top = controller.view.window?.rootViewController ?? controller
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    func makeUIViewController(context: Context) -> UIViewController { controller }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
