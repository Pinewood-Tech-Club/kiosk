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
    private(set) var credentialSource: SquareCredentials.Source?
    @ObservationIgnored let credentials = SquareCredentialStore()
    @ObservationIgnored var canReauthorize: () -> Bool = { true }
    @ObservationIgnored private var checkoutClient: BoothCheckoutClient?
    @ObservationIgnored private var reauthorizationPending = false

    private var sdk: any SDKManager { MobilePaymentsSDK.shared }
    @ObservationIgnored private let locationManager = CLLocationManager()
    @ObservationIgnored private var bluetoothManager: CBCentralManager?
    @ObservationIgnored private var paymentHandle: PaymentHandle?
    @ObservationIgnored private var continuation: CheckedContinuation<PaymentResult, Never>?
    @ObservationIgnored private var pending: (quote: OrderQuote, name: String, number: Int, checkout: CheckoutIdentity, order: SquareAPI.CreatedOrder)?
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
        guard isStarted, Config.squareApplicationID != nil else { return }
        sdk.authorizationManager.remove(self)
        sdk.readerManager.remove(self)
    }

    private var hasApplicationID: Bool { Config.squareApplicationID != nil }
    var isConfigured: Bool { hasApplicationID && credentialSource != nil }
    var isSandbox: Bool { hasApplicationID && sdk.settingsManager.sdkSettings.environment == .sandbox }
    var environmentName: String { hasApplicationID ? (isSandbox ? "Sandbox" : "Production") : "No credentials" }
    var isAuthorized: Bool { authorizationState == .authorized }

    private static let authorizedFingerprintKey = "squareAuthorizedFingerprint"

    func start() {
        guard !isStarted else { return }
        isStarted = true
        credentialSource = credentials.current?.source
        guard hasApplicationID else {
            record("Square application ID missing; only simulated payments are available")
            return
        }
        credentials.onChange = { [weak self] credentials in self?.credentialsChanged(credentials) }
        sdk.authorizationManager.add(self)
        sdk.readerManager.add(self)
        authorizationState = sdk.authorizationManager.state
        readers = sdk.readerManager.readers
        record("SDK \(sdk.settingsManager.sdkSettings.version), environment: \(environmentName), credentials: \(credentials.sourceDescription)")
        requestPermissions()
        guard let current = credentials.current else {
            record("Waiting for Square credentials from the booth")
            return
        }
        if isAuthorized, authorizedFingerprint(fallback: current) != current.fingerprint {
            reauthorizationPending = true
            reauthorizeIfIdle()
        }
        authorize()
        loadLocation()
        loadCatalog()
    }

    func attachBooth(_ api: BoothAPI) {
        checkoutClient = BoothCheckoutClient(api: api) { [weak self] in self?.record($0) }
        credentials.attach(api: api) { [weak self] in self?.record($0) }
    }

    /// Builds from before the booth handed out tokens authorized with the bundled one, so that is what an unrecorded
    /// authorization used.
    private func authorizedFingerprint(fallback: SquareCredentials) -> String? {
        UserDefaults.standard.string(forKey: Self.authorizedFingerprintKey) ?? (fallback.source == .bundled ? fallback.fingerprint : nil)
    }

    private func credentialsChanged(_ new: SquareCredentials?) {
        credentialSource = new?.source
        guard isStarted, hasApplicationID, let new else { return }
        switch sdk.authorizationManager.state {
        case .notAuthorized:
            authorize()
        case .authorized:
            if authorizedFingerprint(fallback: new) != new.fingerprint {
                reauthorizationPending = true
                reauthorizeIfIdle()
            }
        default:
            reauthorizationPending = true
        }
        loadLocation()
        loadCatalog()
    }

    /// Swapping the SDK's token means deauthorizing, so it waits until no customer is mid-order.
    func reauthorizeIfIdle() {
        guard reauthorizationPending, phase == .idle, canReauthorize(), sdk.authorizationManager.state == .authorized else { return }
        reauthorizationPending = false
        record("Re-authorizing Square with the new token")
        sdk.authorizationManager.deauthorize { [weak self] in self?.authorize() }
    }

    private var api: SquareAPI? {
        guard let credentials = credentials.current else { return nil }
        return SquareAPI(
            baseURL: URL(string: isSandbox ? "https://connect.squareupsandbox.com" : "https://connect.squareup.com")!,
            accessToken: credentials.accessToken,
            locationID: credentials.locationID
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
            [IceCreamItem(vessel: .cone, flavors: [.vanilla, .chocolate], toppings: [.whip, .chocolate, .sprinkles]),
             IceCreamItem(vessel: .cup, flavors: [.cookies], toppings: [.gummies])],
        ]
        for (index, basket) in baskets.enumerated() {
            let quote = Pricing.quote(basket)
            do {
                let order = try await api.createOrder(quote: quote, catalog: catalog, customerName: "Verify", referenceID: "verify-\(index + 1)", sourceName: "\(Config.eventName) Kiosk")
                let subtotal = order.totalCents - order.taxCents
                let verdict = subtotal == quote.totalCents ? "MATCH" : "MISMATCH"
                record("VERIFY basket \(index + 1): \(quote.scoopCount) scoops, \(quote.coneCount) cones, \(quote.toppingCount) toppings, kiosk \(quote.totalCents) square \(order.totalCents) tax \(order.taxCents) catalog=\(order.usedCatalog) \(verdict)")
                let local = Receipt.chargedLines(for: quote).map { "\($0.title)|\($0.detail)|\($0.cents)" }
                let remote = order.lines.map { "\($0.title)|\($0.detail)|\($0.cents)" }
                record("VERIFY lines basket \(index + 1): \(local == remote ? "SAME" : "DIFFERENT") \(remote.joined(separator: " ; "))")
            } catch {
                record("VERIFY basket \(index + 1) failed: \(error.localizedDescription)")
            }
        }
    }

    private func requestPermissions() {
        guard UserDefaults.standard.string(forKey: "kioskToppingLab") == nil else { return }
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
        guard sdk.authorizationManager.state == .notAuthorized, let credentials = credentials.current else { return }

        record("Authorizing for location \(credentials.locationID) with the \(self.credentials.sourceDescription) token…")
        sdk.authorizationManager.authorize(withAccessToken: credentials.accessToken, locationID: credentials.locationID) { [weak self] error in
            if let error {
                self?.record("Authorization failed: \(Self.describe(error))")
            } else {
                UserDefaults.standard.set(credentials.fingerprint, forKey: Self.authorizedFingerprintKey)
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
    func pay(quote: OrderQuote, customerName: String, orderNumber: Int, checkout: CheckoutIdentity,
             from viewController: UIViewController) async -> PaymentResult {
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

        let sourceName = "\(Config.eventName) Kiosk"
        let order: SquareAPI.CreatedOrder
        if credentials.current?.source == .booth, let checkoutClient,
           let remote = await checkoutClient.createOrder(quote: quote, customerName: customerName, orderNumber: orderNumber,
                                                         checkout: checkout, locationID: api.locationID, sourceName: sourceName) {
            order = remote
        } else {
            do {
                order = try await api.createOrder(quote: quote, catalog: catalog, customerName: customerName, referenceID: referenceID,
                                                  sourceName: sourceName, idempotencyKey: "\(checkout.id)-device", checkoutID: checkout.id)
            } catch {
                phase = .idle
                return orderFailed(error)
            }
        }
        record("Order \(order.id) created (\(order.usedCatalog ? "catalog" : "ad-hoc") line items), total \(order.totalCents.formattedAsUSD) (tax \(order.taxCents.formattedAsUSD))")
        if order.totalCents - order.taxCents != quote.totalCents {
            record("WARNING: Square subtotal \((order.totalCents - order.taxCents).formattedAsUSD) differs from kiosk total \(quote.totalCents.formattedAsUSD)")
        }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.pending = (quote, customerName, orderNumber, checkout, order)
            let parameters = PaymentParameters(
                paymentAttemptID: UUID().uuidString,
                amountMoney: Money(amount: UInt(order.totalCents), currency: .USD),
                processingMode: isSandbox ? .onlineOnly : .autoDetect
            )
            parameters.orderID = order.id
            parameters.referenceID = referenceID

            phase = .takingPayment
            record("Calling startPayment for \(order.totalCents.formattedAsUSD)")
            paymentHandle = sdk.paymentManager.startPayment(
                parameters,
                promptParameters: PromptParameters(mode: .default, additionalMethods: AdditionalPaymentMethods([])),
                from: viewController,
                delegate: self
            )
            if paymentHandle == nil {
                record("startPayment returned no handle")
                finish(.failed(.readerNotReady))
            }
        }
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
            isSimulated: false, checkoutID: pending.checkout.id, receiptToken: pending.checkout.receiptToken
        )
        finish(.succeeded(receipt))
    }

    func paymentManager(_ paymentManager: PaymentManager, didFail payment: Payment, withError error: Error) {
        finish(paymentFailed(error))
    }

    func paymentManager(_ paymentManager: PaymentManager, didCancel payment: Payment) {
        record("Payment canceled")
        finish(.canceled)
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
        readers = sdk.readerManager.readers
    }
}

// MARK: - CBCentralManagerDelegate

extension SquareService: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        record("Bluetooth permission: \(CBManager.authorization == .allowedAlways ? "granted" : "not granted")")
    }
}
