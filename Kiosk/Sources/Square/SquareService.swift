import AVFoundation
import CoreBluetooth
import CoreLocation
import Observation
import SquareMobilePaymentsSDK
import UIKit

#if canImport(MockReaderUI)
import MockReaderUI
#endif

enum PaymentResult {
    case succeeded(Receipt)
    case failed(PaymentProblem)
    case canceled
}

struct LogEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let message: String
}

@Observable
final class SquareService: NSObject {
    enum Phase: Equatable { case idle, creatingOrder, takingPayment }
    enum CatalogStatus: Equatable {
        case notConfigured
        case loading
        case ready(itemCount: Int)
        case failed(String)

        var badgeText: String {
            switch self {
            case .notConfigured: "Catalog: ad-hoc"
            case .loading: "Catalog…"
            case .ready: "Catalog OK"
            case .failed: "Catalog error"
            }
        }
    }

    private(set) var authorizationState: AuthorizationState
    private(set) var readers: [ReaderInfo] = []
    private(set) var phase: Phase = .idle
    private(set) var log: [LogEntry] = []
    private(set) var isMockReaderPresented = false
    private(set) var merchantName = Config.eventName
    private(set) var catalogStatus: CatalogStatus = .notConfigured
    @ObservationIgnored private(set) var catalog: SquareCatalog?
    private(set) var cardPrompt: CardPrompt?
    /// Square's default payment screen instead of the kiosk's own card prompt; a fallback kept for debugging.
    var usesSquarePrompt = UserDefaults.standard.bool(forKey: "kioskSquarePrompt") {
        didSet { UserDefaults.standard.set(usesSquarePrompt, forKey: "kioskSquarePrompt") }
    }

    private var sdk: any SDKManager { MobilePaymentsSDK.shared }
    @ObservationIgnored private let locationManager = CLLocationManager()
    @ObservationIgnored private var bluetoothManager: CBCentralManager?
    @ObservationIgnored private var paymentHandle: PaymentHandle?
    @ObservationIgnored private var continuation: CheckedContinuation<PaymentResult, Never>?
    @ObservationIgnored private var pending: (quote: OrderQuote, name: String, number: Int, order: SquareAPI.CreatedOrder)?
    @ObservationIgnored private weak var presenter: UIViewController?
    @ObservationIgnored private var promptMode: PromptMode = .custom
    @ObservationIgnored private var cancelIntent: CancelIntent?
    @ObservationIgnored private var waitingSince: ContinuousClock.Instant?
    @ObservationIgnored private var promptTimer: Task<Void, Never>?
    @ObservationIgnored private var cardInReader = false
    #if canImport(MockReaderUI)
    @ObservationIgnored private var mockReader: MockReaderUI?
    #endif

    @ObservationIgnored private var isStarted = false

    // SwiftUI may construct throwaway instances of a view's @State model, so init must stay
    // side-effect free; observers and logging begin in start().
    override init() {
        authorizationState = .notAuthorized
        super.init()
    }

    deinit {
        guard isStarted, Config.isComplete else { return }
        sdk.authorizationManager.remove(self)
        sdk.readerManager.remove(self)
    }

    var isConfigured: Bool { Config.isComplete }
    var isSandbox: Bool { isConfigured && sdk.settingsManager.sdkSettings.environment == .sandbox }
    var environmentName: String { isConfigured ? (isSandbox ? "Sandbox" : "Production") : "No credentials" }
    var isAuthorized: Bool { authorizationState == .authorized }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        guard isConfigured else {
            record("Square credentials missing; only simulated payments are available")
            return
        }
        sdk.authorizationManager.add(self)
        sdk.readerManager.add(self)
        authorizationState = sdk.authorizationManager.state
        readers = sdk.readerManager.readers
        record("SDK \(sdk.settingsManager.sdkSettings.version), environment: \(environmentName)")
        requestPermissions()
        authorize()
        loadLocation()
        loadCatalog()
    }

    private var api: SquareAPI? {
        guard let token = Config.accessToken, let locationID = Config.locationID else { return nil }
        return SquareAPI(
            baseURL: URL(string: isSandbox ? "https://connect.squareupsandbox.com" : "https://connect.squareup.com")!,
            accessToken: token,
            locationID: locationID
        )
    }

    private func loadLocation() {
        guard let api else { return }
        Task { @MainActor in
            do {
                let location = try await api.fetchLocation()
                merchantName = location.businessName ?? location.name
                record("Location: \(location.name)")
            } catch {
                record("Location lookup failed: \(error.localizedDescription)")
            }
        }
    }

    func loadCatalog() {
        guard let api else { return }
        guard let categoryName = Config.categoryName else {
            catalogStatus = .notConfigured
            record("No SQUARE_CATEGORY_NAME configured; orders use ad-hoc line items")
            return
        }
        catalogStatus = .loading
        Task { @MainActor in
            do {
                let loaded = try await api.fetchCatalog(categoryName: categoryName)
                if let mismatch = loaded.pricingMismatch {
                    throw SquareAPI.APIError(message: "Catalog prices don't match kiosk pricing (\(mismatch))")
                }
                catalog = loaded
                catalogStatus = .ready(itemCount: loaded.entries.count)
                record("Catalog \"\(categoryName)\" loaded: " + loaded.entries.map { "\($0.itemName) \($0.cents.formattedAsUSD)" }.joined(separator: ", "))
            } catch {
                catalog = nil
                catalogStatus = .failed(error.localizedDescription)
                record("CATALOG ERROR: \(error.localizedDescription). Falling back to ad-hoc line items.")
            }
            if UserDefaults.standard.bool(forKey: "kioskVerifyOrders") {
                await verifyOrders(api: api)
            }
        }
    }

    @MainActor
    private func verifyOrders(api: SquareAPI) async {
        let baskets: [[IceCreamItem]] = [
            [IceCreamItem(vessel: .cup, flavors: [.vanilla])],
            [IceCreamItem(vessel: .cone, flavors: [.chocolate, .cookies])],
            [IceCreamItem(vessel: .cup, flavors: [.vanilla, .chocolate, .cookies])],
            [IceCreamItem(vessel: .cone, flavors: [.vanilla, .chocolate]), IceCreamItem(vessel: .cup, flavors: [.cookies, .cookies, .vanilla])],
            [IceCreamItem(vessel: .cone, flavors: [.vanilla, .vanilla, .chocolate]), IceCreamItem(vessel: .cone, flavors: [.cookies, .chocolate, .vanilla])],
            [IceCreamItem(vessel: .cup, flavors: [.vanilla]), IceCreamItem(vessel: .cone, flavors: [.chocolate]), IceCreamItem(vessel: .cup, flavors: [.cookies])],
        ]
        for (index, basket) in baskets.enumerated() {
            let quote = Pricing.quote(basket)
            do {
                let order = try await api.createOrder(quote: quote, catalog: catalog, customerName: "Verify", referenceID: "verify-\(index + 1)", sourceName: "\(Config.eventName) Kiosk")
                let subtotal = order.totalCents - order.taxCents
                let verdict = subtotal == quote.totalCents ? "MATCH" : "MISMATCH"
                record("VERIFY basket \(index + 1): \(quote.scoopCount) scoops, \(quote.coneCount) cones, kiosk \(quote.totalCents) square \(order.totalCents) tax \(order.taxCents) catalog=\(order.usedCatalog) \(verdict)")
                let local = Receipt.chargedLines(for: quote).map { "\($0.title)|\($0.detail)|\($0.cents)" }
                let remote = order.lines.map { "\($0.title)|\($0.detail)|\($0.cents)" }
                record("VERIFY lines basket \(index + 1): \(local == remote ? "SAME" : "DIFFERENT") \(remote.joined(separator: " ; "))")
            } catch {
                record("VERIFY basket \(index + 1) failed: \(error.localizedDescription)")
            }
        }
    }

    private func requestPermissions() {
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
        if CBManager.authorization == .notDetermined {
            bluetoothManager = CBCentralManager(delegate: self, queue: .main)
        }
        #if !targetEnvironment(simulator)
        if AVAudioApplication.shared.recordPermission == .undetermined {
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async { self.record("Microphone permission granted: \(granted)") }
            }
        }
        #endif
    }

    func authorize() {
        guard sdk.authorizationManager.state == .notAuthorized,
              let token = Config.accessToken,
              let locationID = Config.locationID
        else { return }

        record("Authorizing for location \(locationID)…")
        sdk.authorizationManager.authorize(withAccessToken: token, locationID: locationID) { [weak self] error in
            if let error {
                self?.record("Authorization failed: \(Self.describe(error))")
            } else {
                self?.record("Authorized")
            }
        }
    }

    func presentReaderSettings(from viewController: UIViewController) {
        sdk.settingsManager.presentSettings(with: viewController) { [weak self] error in
            if let error { self?.record("Settings error: \(error.localizedDescription)") }
        }
    }

    func toggleMockReader() {
        #if canImport(MockReaderUI)
        if isMockReaderPresented {
            mockReader?.dismiss()
            isMockReaderPresented = false
            return
        }
        do {
            if mockReader == nil {
                mockReader = try MockReaderUI(for: sdk)
            }
            try mockReader?.present()
            isMockReaderPresented = true
        } catch {
            record("Mock reader error: \(error.localizedDescription)")
        }
        #endif
    }

    // MARK: Payment

    @MainActor
    func pay(quote: OrderQuote, customerName: String, orderNumber: Int, from viewController: UIViewController) async -> PaymentResult {
        guard phase == .idle else {
            return refuse(.stillFinishing, because: Self.alreadyInProgressReason)
        }
        guard let api else {
            return refuse(.needsStaff, because: Self.notConfiguredReason)
        }
        guard isAuthorized else {
            authorize()
            return refuse(.needsStaff, because: Self.notAuthorizedReason + " (state: \(Self.describe(authorizationState)))")
        }
        guard !readers.isEmpty else {
            return refuse(.readerNotReady, because: Self.noReaderReason)
        }
        if let problem = Self.displayProblem(viewController) {
            return refuse(.paymentsPaused, because: problem)
        }

        let referenceID = String(format: "kiosk-%04d", orderNumber)
        phase = .creatingOrder
        record("Creating order \(referenceID) for \(customerName) (\(quote.lines.count) items, local total \(quote.totalCents.formattedAsUSD))…")

        let order: SquareAPI.CreatedOrder
        do {
            order = try await api.createOrder(quote: quote, catalog: catalog, customerName: customerName, referenceID: referenceID,
                                              sourceName: "\(Config.eventName) Kiosk")
        } catch {
            phase = .idle
            return orderFailed(error)
        }
        record("Order \(order.id) created (\(order.usedCatalog ? "catalog" : "ad-hoc") line items), total \(order.totalCents.formattedAsUSD) (tax \(order.taxCents.formattedAsUSD))")
        if order.totalCents - order.taxCents != quote.totalCents {
            record("WARNING: Square subtotal \((order.totalCents - order.taxCents).formattedAsUSD) differs from kiosk total \(quote.totalCents.formattedAsUSD)")
        }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.pending = (quote, customerName, orderNumber, order)
            presenter = viewController
            promptMode = usesSquarePrompt ? .default : .custom
            phase = .takingPayment
            if promptMode == .custom {
                cardPrompt = CardPrompt(amountCents: order.totalCents, instruction: cardInstruction, stage: .waiting)
                waitingSince = .now
            }
            startAttempt()
        }
    }

    /// One `startPayment` for the pending order. A custom-prompt payment may take several attempts while the
    /// customer finds their card; each attempt gets a fresh attempt ID and charges the same Square order.
    private func startAttempt() {
        guard let pending, let presenter else {
            finish(.failed(.readerNotReady))
            return
        }
        let parameters = PaymentParameters(
            paymentAttemptID: UUID().uuidString,
            amountMoney: Money(amount: UInt(pending.order.totalCents), currency: .USD),
            processingMode: isSandbox ? .onlineOnly : .autoDetect
        )
        parameters.orderID = pending.order.id
        parameters.referenceID = String(format: "kiosk-%04d", pending.number)

        record("Calling startPayment for \(pending.order.totalCents.formattedAsUSD) (\(promptMode == .custom ? "kiosk card prompt" : "Square prompt"))")
        paymentHandle = sdk.paymentManager.startPayment(
            parameters,
            promptParameters: PromptParameters(mode: promptMode, additionalMethods: AdditionalPaymentMethods([])),
            from: presenter,
            delegate: self
        )
        guard paymentHandle != nil else {
            record("startPayment returned no handle")
            finish(.failed(.readerNotReady))
            return
        }
        if promptMode == .custom { schedulePromptTimer(after: Self.rearmInterval, then: { $0.rearmOrAskIfStillThere() }) }
    }

    // Square fails a payment that has seen no card for about 30 s, and in both prompt modes it first covers
    // the screen with its own "Payment failed" page for another 30 s. Restarting the attempt before then keeps
    // that page away; the customer only sees the kiosk prompt, and patience is ours to choose.
    private static let rearmInterval: Duration = .seconds(20)
    private static let patience: Duration = .seconds(60)
    private static let stillThereTimeout: Duration = .seconds(30)

    private func schedulePromptTimer(after delay: Duration, then action: @escaping @MainActor (SquareService) -> Void) {
        promptTimer?.cancel()
        promptTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            action(self)
        }
    }

    private func rearmOrAskIfStillThere() {
        guard phase == .takingPayment, cardPrompt?.stage == .waiting, let handle = paymentHandle else { return }
        guard isWaitingForCard(handle) else {
            schedulePromptTimer(after: .seconds(5), then: { $0.rearmOrAskIfStillThere() })
            return
        }
        let waited = waitingSince.map { ContinuousClock.now - $0 } ?? .zero
        cancelIntent = waited + .seconds(1) >= Self.patience ? .askStillThere : .rearm
        if !handle.cancelPayment() {
            cancelIntent = nil
            schedulePromptTimer(after: .seconds(5), then: { $0.rearmOrAskIfStillThere() })
        }
    }

    /// Once a card touches the reader Square presents its own screens (PIN, processing, result) over the kiosk.
    private func isWaitingForCard(_ handle: PaymentHandle) -> Bool {
        handle.isPaymentCancelable && !cardInReader && presenter?.presentedViewController == nil
    }

    func keepWaitingForCard() {
        guard phase == .takingPayment, cardPrompt?.stage == .stillThere, paymentHandle == nil else { return }
        record("Customer is still there; waiting for a card again")
        cardPrompt?.stage = .waiting
        waitingSince = .now
        startAttempt()
    }

    func cancelCardPrompt() {
        guard phase == .takingPayment, cardPrompt != nil else { return }
        if cancelIntent != nil {
            cancelIntent = .customer
            return
        }
        guard let handle = paymentHandle else {
            record("Payment canceled from the card prompt")
            finish(.canceled)
            return
        }
        cancelIntent = .customer
        if !handle.cancelPayment() {
            cancelIntent = nil
            record("Cancel ignored: the card is already being read")
        }
    }

    private var cardInstruction: String {
        let methods = sdk.paymentManager.availableCardInputMethods
        let verbs = [(methods.contains(.contactless), "Tap"), (methods.contains(.chip), "insert"), (methods.contains(.swipe), "swipe")]
            .filter(\.0).map(\.1)
        guard !verbs.isEmpty else { return "Tap or insert your card" }
        let phrase = verbs.count == 1 ? verbs[0] : verbs.dropLast().joined(separator: ", ") + " or " + verbs.last!
        return phrase.prefix(1).uppercased() + phrase.dropFirst() + " your card"
    }

    private static let alreadyInProgressReason = "A payment is already in progress"
    private static let notConfiguredReason = "Square credentials missing in Config/Local.xcconfig; use Simulate payment success"
    private static let notAuthorizedReason = "SDK not authorized with Square; retrying authorization"
    private static let noReaderReason = "No card reader paired; pair one with Readers (or Mock Reader in sandbox)"
    private static let screenCapturedReason = "The screen is being recorded or mirrored"
    private static let notFullScreenReason = "The kiosk isn't full screen (Split View or Slide Over)"

    private func refuse(_ problem: PaymentProblem, because reason: String) -> PaymentResult {
        record("Refusing to charge: \(reason)")
        return .failed(problem)
    }

    private func orderFailed(_ error: Error) -> PaymentResult {
        record("CreateOrder failed: \(Self.describe(error))")
        return .failed(PaymentProblem(orderError: error))
    }

    private func paymentFailed(_ error: Error) -> PaymentResult {
        let nsError = error as NSError
        let code = nsError.domain == PaymentProblem.paymentErrorDomain
            ? PaymentError(rawValue: nsError.code).map { "\($0)" } ?? "\(nsError.code)"
            : "\(nsError.code)"
        record("Payment failed (\(code)): \(Self.describe(error))")
        return .failed(PaymentProblem(paymentError: error))
    }

    private static func describe(_ state: AuthorizationState) -> String {
        switch state {
        case .authorized: "authorized"
        case .authorizing: "authorizing"
        case .notAuthorized: "not authorized"
        @unknown default: "unknown (\(state.rawValue))"
        }
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        var text = "\(nsError.domain) \(nsError.code): \(error.localizedDescription)"
        if let reason = nsError.localizedFailureReason { text += " Reason: \(reason)" }
        if let suggestion = nsError.localizedRecoverySuggestion { text += " Suggestion: \(suggestion)" }
        return text
    }

    @MainActor
    func simulate(_ forced: ForcedError) async -> PaymentResult {
        record("Forcing error: \(forced.rawValue)")
        try? await Task.sleep(for: .seconds(1))
        switch forced {
        case .declined:
            return paymentFailed(NSError(domain: "KioskForcedError", code: 1,
                                         userInfo: [NSLocalizedDescriptionKey: "Simulated decline with no PaymentError code"]))
        case .timeout: return paymentFailed(PaymentProblem.paymentError(.timedOut))
        case .offline: return orderFailed(URLError(.notConnectedToInternet))
        case .paymentOffline: return paymentFailed(PaymentProblem.paymentError(.noNetwork))
        case .notConfigured: return refuse(.needsStaff, because: Self.notConfiguredReason)
        case .notAuthorized: return refuse(.needsStaff, because: Self.notAuthorizedReason)
        case .noReader: return refuse(.readerNotReady, because: Self.noReaderReason)
        case .readerFailedToStart:
            record("startPayment returned no handle")
            return .failed(.readerNotReady)
        case .screenShared: return refuse(.paymentsPaused, because: Self.screenCapturedReason)
        case .notFullScreen: return refuse(.paymentsPaused, because: Self.notFullScreenReason)
        case .unsupportedMode: return paymentFailed(PaymentProblem.paymentError(.unsupportedMode))
        case .locationPermission: return paymentFailed(PaymentProblem.paymentError(.locationPermissionNeeded))
        case .orderRejected:
            return orderFailed(SquareAPI.APIError(message: "UNAUTHORIZED: This request could not be authorized."))
        case .alreadyInProgress: return refuse(.stillFinishing, because: Self.alreadyInProgressReason)
        case .paidWithoutOrder:
            record("Payment finished without a pending order")
            return .failed(.paidWithoutOrder)
        case .canceled:
            record("Payment canceled")
            return .canceled
        case .assets:
            return .canceled
        }
    }

    /// Mirrors the conditions under which the SDK fails a payment with `unsupportedMode`,
    /// so we can refuse up front instead of after the order is created.
    private static func displayProblem(_ viewController: UIViewController) -> String? {
        guard let window = viewController.view.window, let scene = window.windowScene else { return nil }
        if scene.traitCollection.sceneCaptureState == .active {
            return screenCapturedReason
        }
        if window.bounds.size != scene.screen.bounds.size {
            return notFullScreenReason
        }
        return nil
    }

    private func finish(_ result: PaymentResult) {
        paymentHandle = nil
        phase = .idle
        pending = nil
        presenter = nil
        cardPrompt = nil
        cancelIntent = nil
        waitingSince = nil
        promptTimer?.cancel()
        promptTimer = nil
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: result)
    }

    // MARK: Log

    func record(_ message: String) {
        print("[Kiosk] \(message)")
        Self.appendToLogFile(message)
        log.insert(LogEntry(message: message), at: 0)
        if log.count > 300 { log.removeLast() }
    }
}

extension SquareService {
    static let logFileURL = URL.documentsDirectory.appending(path: "kiosk.log")

    private static let logTimestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .current)

    static func appendToLogFile(_ message: String) {
        let line = Data("\(Date().formatted(logTimestamp)) \(message)\n".utf8)
        guard let handle = try? FileHandle(forWritingTo: logFileURL) else {
            try? line.write(to: logFileURL)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }
}

struct CardPrompt: Equatable {
    enum Stage: Equatable { case waiting, stillThere }

    let amountCents: Int
    let instruction: String
    var stage: Stage
}

private enum CancelIntent {
    case rearm
    case askStillThere
    case customer
}

// MARK: - PaymentManagerDelegate

extension SquareService: PaymentManagerDelegate {
    func paymentManager(_ paymentManager: PaymentManager, didStart payment: Payment) {
        record("Square payment UI started")
    }

    func paymentManager(_ paymentManager: PaymentManager, willFinish payment: Payment) {
        record("Square payment will finish")
    }

    func paymentManager(_ paymentManager: PaymentManager, willCancel payment: Payment) {
        record("Square payment will cancel")
    }

    func paymentManager(_ paymentManager: PaymentManager, didFinish payment: Payment) {
        var paymentID = "—"
        var card = "Card"
        if let online = payment as? OnlinePayment {
            paymentID = online.id ?? "—"
            if let details = online.cardDetails?.card {
                card = "\(details.cardBrand.description) •••• \(details.last4 ?? "????")"
            }
            record("Payment \(paymentID) \(online.status.description), \(card)")
        } else if let offline = payment as? OfflinePayment {
            paymentID = offline.localID
            card = "Card (offline)"
            record("Offline payment \(paymentID) \(offline.status.description)")
        }
        let total = Int(payment.totalMoney.amount)
        guard let pending else {
            record("Payment \(paymentID) finished without a pending order")
            finish(.failed(.paidWithoutOrder))
            return
        }
        let receipt = Receipt(
            merchantName: merchantName, eventName: Config.eventName, date: Date(), orderNumber: pending.number,
            customerName: pending.name, squareOrderID: payment.orderID ?? pending.order.id, paymentID: paymentID,
            cardDescription: card, lines: pending.order.lines,
            subtotalCents: total - pending.order.taxCents, taxCents: pending.order.taxCents, totalCents: total,
            isSimulated: false
        )
        finish(.succeeded(receipt))
    }

    func paymentManager(_ paymentManager: PaymentManager, didFail payment: Payment, withError error: Error) {
        finish(paymentFailed(error))
    }

    func paymentManager(_ paymentManager: PaymentManager, didCancel payment: Payment) {
        paymentHandle = nil
        let intent = cancelIntent
        cancelIntent = nil
        switch intent {
        case .rearm:
            startAttempt()
        case .askStillThere:
            let waited = waitingSince.map { ContinuousClock.now - $0 } ?? .zero
            record("No card after \(waited.formatted(.units(allowed: [.seconds]))); asking if the customer is still there")
            cardPrompt?.stage = .stillThere
            schedulePromptTimer(after: Self.stillThereTimeout, then: { $0.giveUpWaitingForCard() })
        case .customer, nil:
            record("Payment canceled")
            finish(.canceled)
        }
    }

    private func giveUpWaitingForCard() {
        guard phase == .takingPayment, cardPrompt?.stage == .stillThere, paymentHandle == nil else { return }
        record("No answer to Still there?; giving up on the payment")
        finish(.failed(.timedOut))
    }
}

// MARK: - AuthorizationStateObserver

extension SquareService: AuthorizationStateObserver {
    func authorizationStateDidChange(_ authorizationState: AuthorizationState) {
        record("Authorization state: \(Self.describe(authorizationState))")
        self.authorizationState = authorizationState
    }
}

// MARK: - ReaderObserver

extension SquareService: ReaderObserver {
    func readerWasAdded(_ readerInfo: ReaderInfo) {
        record("Reader added: \(readerInfo.name)")
        readers = sdk.readerManager.readers
    }

    func readerWasRemoved(_ readerInfo: ReaderInfo) {
        record("Reader removed: \(readerInfo.name)")
        readers = sdk.readerManager.readers
    }

    func readerDidChange(_ readerInfo: ReaderInfo, change: ReaderChange) {
        switch change {
        case .cardInserted: cardInReader = true
        case .cardRemoved: cardInReader = false
        default: break
        }
        readers = sdk.readerManager.readers
    }
}

// MARK: - CBCentralManagerDelegate

extension SquareService: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        record("Bluetooth permission: \(CBManager.authorization == .allowedAlways ? "granted" : "not granted")")
    }
}
