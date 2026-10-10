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
    case failed(title: String, details: [String])
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

    private(set) var authorizationState: AuthorizationState
    private(set) var readers: [ReaderInfo] = []
    private(set) var phase: Phase = .idle
    private(set) var log: [LogEntry] = []
    private(set) var isMockReaderPresented = false
    private(set) var merchantName = Config.eventName

    private var sdk: any SDKManager { MobilePaymentsSDK.shared }
    @ObservationIgnored private let locationManager = CLLocationManager()
    @ObservationIgnored private var bluetoothManager: CBCentralManager?
    @ObservationIgnored private var paymentHandle: PaymentHandle?
    @ObservationIgnored private var continuation: CheckedContinuation<PaymentResult, Never>?
    @ObservationIgnored private var pending: (quote: OrderQuote, name: String, number: Int, order: SquareAPI.CreatedOrder)?
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
                self?.record("Authorization failed: \(error.localizedDescription)")
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
            return .failed(title: "A payment is already in progress", details: [])
        }
        guard let api else {
            return .failed(title: "Square isn't configured", details: ["Add Square credentials in Config/Local.xcconfig, or turn on Simulate payment success in the debug bar."])
        }
        guard isAuthorized else {
            authorize()
            return .failed(title: "Payments aren't ready yet", details: ["The kiosk isn't authorized with Square. Please ask a volunteer for help."])
        }
        if let problem = Self.displayProblem(viewController) {
            record("Refusing to charge: \(problem)")
            return .failed(title: "Can't take payments right now", details: [problem] + Self.unsupportedModeHelp)
        }

        let referenceID = String(format: "kiosk-%04d", orderNumber)
        phase = .creatingOrder
        record("Creating order \(referenceID) for \(customerName) (\(quote.lines.count) items, local total \(quote.totalCents.formattedAsUSD))…")

        let order: SquareAPI.CreatedOrder
        do {
            order = try await api.createOrder(quote: quote, customerName: customerName, referenceID: referenceID,
                                              sourceName: "\(Config.eventName) Kiosk")
        } catch {
            phase = .idle
            record("CreateOrder failed: \(error.localizedDescription)")
            return .failed(title: "Couldn't create your order", details: [error.localizedDescription])
        }
        record("Order \(order.id) created, total \(order.totalCents.formattedAsUSD) (tax \(order.taxCents.formattedAsUSD))")
        if order.totalCents - order.taxCents != quote.totalCents {
            record("WARNING: Square subtotal \((order.totalCents - order.taxCents).formattedAsUSD) differs from kiosk total \(quote.totalCents.formattedAsUSD)")
        }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.pending = (quote, customerName, orderNumber, order)
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
                finish(.failed(title: "Couldn't start the card reader", details: ["Square didn't start the payment. Check the reader in the debug bar."]))
            }
        }
    }

    private static let unsupportedModeHelp = [
        "Square blocks payments while the screen is being recorded, mirrored or AirPlayed, or while the app is in Split View.",
        "Stop any screen recording or mirroring and keep the kiosk full screen, then try again.",
    ]

    /// Mirrors the conditions under which the SDK fails a payment with `unsupportedMode`,
    /// so we can refuse up front instead of after the order is created.
    private static func displayProblem(_ viewController: UIViewController) -> String? {
        guard let window = viewController.view.window, let scene = window.windowScene else { return nil }
        if scene.traitCollection.sceneCaptureState == .active {
            return "The screen is being recorded or mirrored."
        }
        if window.bounds.size != scene.screen.bounds.size {
            return "The kiosk isn't full screen."
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

    private static func appendToLogFile(_ message: String) {
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
            finish(.failed(title: "Payment finished without an order", details: ["Payment ID: \(paymentID)"]))
            return
        }
        let receipt = Receipt(
            merchantName: merchantName, eventName: Config.eventName, date: Date(), orderNumber: pending.number,
            customerName: pending.name, squareOrderID: payment.orderID ?? pending.order.id, paymentID: paymentID,
            cardDescription: card, lines: Receipt.lines(for: pending.quote),
            subtotalCents: total - pending.order.taxCents, taxCents: pending.order.taxCents, totalCents: total,
            isSimulated: false
        )
        finish(.succeeded(receipt))
    }

    func paymentManager(_ paymentManager: PaymentManager, didFail payment: Payment, withError error: Error) {
        let nsError = error as NSError
        let code = PaymentError(rawValue: nsError.code).map { "\($0)" } ?? "\(nsError.code)"
        record("Payment failed (\(code)): \(error.localizedDescription)")
        let details = PaymentError(rawValue: nsError.code) == .unsupportedMode
            ? Self.unsupportedModeHelp
            : [error.localizedDescription]
        finish(.failed(title: "Payment didn't go through", details: details))
    }

    func paymentManager(_ paymentManager: PaymentManager, didCancel payment: Payment) {
        record("Payment canceled")
        finish(.canceled)
    }
}

// MARK: - AuthorizationStateObserver

extension SquareService: AuthorizationStateObserver {
    func authorizationStateDidChange(_ authorizationState: AuthorizationState) {
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
