import Observation
import SwiftUI

@Observable
@MainActor
final class AppModel {
    enum Screen: Equatable { case roleSetup, attract, builder, summary, name, confirmation }

    struct Notice: Equatable {
        let title: String
        let details: [String]
    }

    var screen: Screen = .roleSetup
    var builderVisible = false
    private(set) var step: BuilderStep = .vessel
    private(set) var current = IceCreamItem()
    private(set) var items: [IceCreamItem] = []
    private(set) var stageReady = false
    var notice: Notice?
    var receipt: Receipt?
    var customerName = ""
    private(set) var isPaying = false
    private(set) var isSendingToTray = false
    private(set) var vesselBounces: [Vessel: Int] = [:]
    private(set) var flavorBounces: [Flavor: Int] = [:]

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
        #if targetEnvironment(simulator)
        simulatePayment = true
        #else
        simulatePayment = !Config.isComplete
        #endif
    }

    var liveQuote: OrderQuote {
        let includeCurrent = current.scoopCount > 0 || current.vessel == .cone
        return Pricing.quote(items + (includeCurrent ? [current] : []))
    }

    var orderQuote: OrderQuote { Pricing.quote(items) }

    var canViewOrder: Bool { !items.isEmpty || current.scoopCount > 0 }

    var canContinue: Bool {
        switch step {
        case .vessel: true
        case .flavors, .toppings: current.scoopCount > 0
        }
    }

    func start() {
        guard !started else { return }
        started = true
        stage.log = { [weak self] in self?.square.record($0) }
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
                stageReady = true
                try? await Task.sleep(for: .seconds(0.4))
                applyLaunchOptions()
            } else {
                square.record("3D assets failed to load")
            }
        }
    }

    func chooseKioskRole() {
        withAnimation(.easeInOut(duration: 0.4)) { screen = .attract }
    }

    func changeRole() {
        resetEverything()
        withAnimation(.easeInOut(duration: 0.35)) { screen = .roleSetup }
    }

    func beginOrder() {
        guard stageReady, screen == .attract else { return }
        resetEverything()
        builderVisible = false
        withAnimation(.easeIn(duration: 0.35)) { screen = .builder }
        transitionTask?.cancel()
        transitionTask = Task {
            try? await Task.sleep(for: .seconds(0.35))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.4)) { builderVisible = true }
            stage.presentNewItem(vessel: .cup, delay: 0.3)
        }
    }

    private func resetEverything() {
        transitionTask?.cancel()
        isSendingToTray = false
        items = []
        current = IceCreamItem()
        step = .vessel
        notice = nil
        receipt = nil
        customerName = ""
        stage.reset()
    }

    func resetToAttract() {
        resetEverything()
        builderVisible = false
        withAnimation(.easeInOut(duration: 0.45)) { screen = .attract }
    }

    func selectVessel(_ vessel: Vessel) {
        guard screen == .builder, step == .vessel else { return }
        if vessel == current.vessel {
            stage.bounceVessel(vessel)
            vesselBounces[vessel, default: 0] += 1
            return
        }
        current.vessel = vessel
        stage.swapVessel(to: vessel)
    }

    func addScoop(_ flavor: Flavor) {
        guard screen == .builder, step == .flavors else { return }
        guard current.scoopCount < Pricing.maxScoopsPerItem else {
            stage.bounceFlavor(flavor)
            flavorBounces[flavor, default: 0] += 1
            return
        }
        current.flavors.append(flavor)
        stage.addScoop(flavor)
    }

    func undoScoop() {
        guard screen == .builder, !current.flavors.isEmpty else { return }
        current.flavors.removeLast()
        stage.removeTopScoop()
    }

    func goForward() {
        guard canContinue else { return }
        switch step {
        case .vessel: setStep(.flavors)
        case .flavors: setStep(.toppings)
        case .toppings: addToOrder()
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
        guard current.scoopCount > 0, !isSendingToTray else { return }
        let item = current
        items.append(item)
        stage.sendCurrentToTray(item)
        current = IceCreamItem()
        isSendingToTray = true
        transitionTask?.cancel()
        transitionTask = Task {
            try? await Task.sleep(for: .seconds(0.6 / max(slowMotion, 0.01)))
            guard !Task.isCancelled else { return }
            isSendingToTray = false
            setStep(.vessel)
            stage.presentNewItem(vessel: .cup, delay: 0.3)
        }
    }

    func removeItem(_ id: UUID) {
        items.removeAll { $0.id == id }
        stage.removeTrayItem(id)
        if screen == .summary, items.isEmpty {
            backToBuilder()
        }
    }

    func viewOrder() {
        guard canViewOrder else { return }
        if isSendingToTray {
            transitionTask?.cancel()
            isSendingToTray = false
            step = .vessel
            stage.setStep(.vessel, animated: false)
            stage.presentNewItem(vessel: .cup, delay: 0.4)
        }
        if current.scoopCount > 0 {
            let item = current
            items.append(item)
            stage.sendCurrentToTray(item)
            current = IceCreamItem()
            step = .vessel
            stage.setStep(.vessel, animated: false)
            stage.presentNewItem(vessel: .cup, delay: 0.4)
        }
        notice = nil
        withAnimation(.easeInOut(duration: 0.4)) { screen = .summary }
    }

    func backToBuilder() {
        withAnimation(.easeInOut(duration: 0.4)) { screen = .builder }
    }

    func completeOrder() {
        guard !items.isEmpty else { return }
        notice = nil
        withAnimation(.easeInOut(duration: 0.4)) { screen = .name }
    }

    func backToSummary() {
        withAnimation(.easeInOut(duration: 0.4)) { screen = .summary }
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
                withAnimation(.easeInOut(duration: 0.45)) { screen = .confirmation }
            case .failed(let title, let details):
                notice = Notice(title: title, details: details)
                withAnimation(.easeInOut(duration: 0.4)) { screen = .summary }
            case .canceled:
                notice = Notice(title: "Payment canceled", details: ["Your order is still here. Tap Complete Order to try again."])
                withAnimation(.easeInOut(duration: 0.4)) { screen = .summary }
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
                stage.restore(current: current, items: items, step: step)
                screen = .summary
            case "name":
                stage.restore(current: current, items: items, step: step)
                screen = .name
            case "confirmation":
                stage.restore(current: nil, items: [], step: .vessel)
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
