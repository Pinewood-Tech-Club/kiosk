import Observation
import SwiftUI

@Observable
@MainActor
final class AppModel {
    enum Screen: Equatable { case roleSetup, attract, builder, name, confirmation }
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
    private(set) var current = IceCreamItem()
    private(set) var items: [IceCreamItem] = []
    private(set) var editingID: UUID?
    private(set) var stageReady = false
    private(set) var pressedCards: Set<CardKey> = []
    private(set) var trayLayoutVersion = 0
    var confirmation: Confirmation?
    private(set) var sheetDrag: CGFloat = 0
    var notice: Notice?
    var receipt: Receipt?
    var customerName = ""
    private(set) var isPaying = false
    private(set) var itemInFlight = false

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
    @ObservationIgnored let stage = Stage()
    @ObservationIgnored let host = ViewControllerHost()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var transitionTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        debugBarHidden = defaults.bool(forKey: "debugBarHidden")
        simulatePayment = false
    }

    /// Everything that would be charged right now, with the item being edited in place of its saved version.
    var liveQuote: OrderQuote {
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
        mode == .customize && !itemInFlight && (isEditing || current.scoopCount > 0)
    }

    func start() {
        guard !started else { return }
        started = true
        stage.log = { [weak self] in self?.square.record($0) }
        stage.onLayoutChange = { [weak self] in self?.trayLayoutVersion += 1 }
        if UserDefaults.standard.bool(forKey: "kioskNoSquare") {
            square.record("Square disabled by -kioskNoSquare")
        } else {
            square.start()
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
            if let assets = await AssetLibrary.load(log: { [weak self] in self?.square.record($0) }) {
                stage.build(with: assets)
                assets.checkContacts { [weak self] in self?.square.record($0) }
                stageReady = true
                try? await Task.sleep(for: .seconds(0.4))
                applyLaunchOptions()
            } else {
                square.record("3D assets failed to load")
            }
        }
    }

    func chooseKioskRole() {
        withAnimation(.easeInOut(duration: 0.5)) { screen = .attract }
    }

    func changeRole() {
        resetEverything()
        withAnimation(.easeInOut(duration: 0.35)) { screen = .roleSetup }
    }

    func beginOrder() {
        guard stageReady, screen == .attract else { return }
        resetEverything()
        stage.restore(current: current, items: [], step: .vessel)
        builderVisible = true
        withAnimation(.easeInOut(duration: 0.5)) { screen = .builder }
    }

    private func resetEverything() {
        transitionTask?.cancel()
        itemInFlight = false
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

    func selectVessel(_ vessel: Vessel) {
        guard screen == .builder, mode == .customize, step == .vessel, vessel != current.vessel else { return }
        current.vessel = vessel
        stage.swapVessel(to: vessel)
    }

    func addScoop(_ flavor: Flavor) {
        guard screen == .builder, mode == .customize, step == .flavors,
              current.scoopCount < Pricing.maxScoopsPerItem else { return }
        current.flavors.append(flavor)
        stage.addScoop(flavor)
    }

    /// Removes the top-most scoop of that flavor; scoops above it settle down one slot.
    func removeScoop(_ flavor: Flavor) {
        guard screen == .builder, mode == .customize, let index = current.flavors.lastIndex(of: flavor) else { return }
        current.flavors.remove(at: index)
        stage.removeScoop(at: index)
    }

    func canJump(to target: BuilderStep) -> Bool {
        target != .toppings || current.scoopCount > 0
    }

    func jumpToStep(_ target: BuilderStep) {
        guard mode == .customize, !itemInFlight, target != step, canJump(to: target) else { return }
        setStep(target)
    }

    func goForward() {
        guard canContinue, !itemInFlight else { return }
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
        step = newStep
        stage.setStep(newStep, animated: true)
    }

    func addToOrder() {
        guard current.scoopCount > 0, !itemInFlight, !isEditing else { return }
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
        trayLayoutVersion += 1
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

    private func startNextItem() {
        current = IceCreamItem()
        holdControlsWhileItemsFly(for: 0.6) { [weak self] in
            self?.setStep(.vessel)
            self?.stage.presentNewItem(vessel: .cup, delay: 0.3)
        }
    }

    /// Fades the step cards (and their 3D icons) out while an item flies between the center and the tray,
    /// so it never passes beneath a card's label, then brings them back.
    private func holdControlsWhileItemsFly(for seconds: Double, then finish: @escaping () -> Void) {
        itemInFlight = true
        stage.setControlsVisible(false, animated: true)
        transitionTask?.cancel()
        transitionTask = Task {
            try? await Task.sleep(for: .seconds(seconds / max(slowMotion, 0.01)))
            guard !Task.isCancelled else { return }
            itemInFlight = false
            finish()
            stage.setControlsVisible(true, animated: true)
        }
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
        itemInFlight = false
        if mode == .summary {
            mode = .customize
            stage.exitSummary()
        }
        if step == .vessel {
            stage.sendCurrentHeroHome()
        } else {
            stage.dismissCurrentHero()
        }
        editingID = id
        current = item
        step = .vessel
        stage.setStep(.vessel, animated: false)
        stage.beginEditing(id)
        trayLayoutVersion += 1
        holdControlsWhileItemsFly(for: 0.7) {}
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
        trayLayoutVersion += 1
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

    func viewOrder() {
        guard canViewOrder, mode == .customize else { return }
        if isEditing, current.scoopCount == 0 {
            confirmation = .removeEmptyEdit(then: .viewOrder)
            return
        }
        transitionTask?.cancel()
        itemInFlight = false
        stage.enterSummary()
        if let editingID, current.scoopCount > 0, let index = items.firstIndex(where: { $0.id == editingID }) {
            items[index] = current
            stage.returnHeroToEntry(editingID, item: current)
        } else if current.scoopCount > 0 {
            let item = current
            items.append(item)
            stage.sendCurrentToTray(item)
        } else {
            stage.dismissCurrentHero()
        }
        editingID = nil
        current = IceCreamItem()
        step = .vessel
        stage.setStep(.vessel, animated: false)
        notice = nil
        withAnimation(.smooth(duration: 0.55)) { mode = .summary }
    }

    func backToBuilder() {
        guard mode == .summary else { return }
        notice = nil
        stage.exitSummary()
        withAnimation(.smooth(duration: 0.5)) { mode = .customize }
        stage.presentNewItem(vessel: current.vessel, delay: 0.35)
    }

    /// Matches `Stage.summaryDrag`, so the sheet and its 3D items spring back together.
    private static let sheetSpring = Animation.spring(response: 0.36, dampingFraction: 0.86)

    func dragSheet(by translation: CGFloat) {
        guard mode == .summary else { return }
        sheetDrag = translation >= 0 ? translation : -24 * (1 - 1 / (-translation / 60 + 1))
        stage.setSummaryDrag(Float(sheetDrag))
    }

    func endSheetDrag(translation: CGFloat, predicted: CGFloat) {
        guard mode == .summary else { return }
        if translation > 150 || predicted > 420 {
            backToBuilder()
            stage.setSummaryDrag(0)
            sheetDrag = 0
        } else {
            withAnimation(Self.sheetSpring) { sheetDrag = 0 }
            stage.releaseSummaryDrag()
        }
    }

    func completeOrder() {
        guard !items.isEmpty else { return }
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
        let quote = orderQuote
        let number = nextOrderNumber()
        Task {
            let result: PaymentResult
            if simulatePayment {
                square.record("Simulating payment for order #\(number) (\(quote.totalCents.formattedAsUSD))")
                try? await Task.sleep(for: .seconds(1.2))
                result = .succeeded(.simulated(quote: quote, customerName: name, orderNumber: number,
                                               merchantName: square.merchantName))
            } else {
                result = await square.pay(quote: quote, customerName: name, orderNumber: number, from: host.presenter)
            }
            isPaying = false
            switch result {
            case .succeeded(let receipt):
                self.receipt = receipt
                stage.enterReceipt()
                withAnimation(.easeInOut(duration: 0.45)) { screen = .confirmation }
            case .failed(let title, let details):
                notice = Notice(title: title, details: details)
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
        if options.role == "kiosk", screen == .roleSetup { screen = .attract }

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
                stage.restore(current: nil, items: items, step: .vessel, summary: true)
            case "name":
                stage.restore(current: nil, items: items, step: .vessel, summary: true)
                mode = .summary
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
