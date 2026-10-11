import Foundation
import Observation
import UIKit

enum HelpReason: String, Sendable {
    case button
    case paymentFailed = "payment_failed"
    case noReader = "no_reader"
    case idle
}

@Observable
@MainActor
final class BoothLink {
    private struct SoldOutSnapshot: Codable {
        var rev: Int
        var soldOut: [String]
    }

    private static let soldOutKey = "boothSoldOutState"
    private static let idleLimit: TimeInterval = 60
    private static let helpRateLimit: TimeInterval = 30
    private static let uploadInterval: TimeInterval = 15
    private static let healthDebounce: TimeInterval = 2
    private static let healthRefresh: TimeInterval = 60

    private(set) var connectionState: BoothConnection.ConnectionState = .idle
    private(set) var soldOut: Set<Flavor>
    private(set) var helpBannerVisible = false

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var square: SquareService?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var connection: BoothConnection?
    @ObservationIgnored private var shipper: LogShipper?
    @ObservationIgnored private let outbox = BoothOutbox()
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var lastUpload = Date.distantPast
    @ObservationIgnored private var lastTouch = Date()
    @ObservationIgnored private var idleSent = false
    @ObservationIgnored private var lastHelpSent: [HelpReason: Date] = [:]
    @ObservationIgnored private var lastHealth: KioskHealth?
    @ObservationIgnored private var lastHealthQueued = Date.distantPast
    @ObservationIgnored private var forceHealth = false

    init() {
        let stored = UserDefaults.standard.data(forKey: Self.soldOutKey).flatMap { try? JSONDecoder().decode(SoldOutSnapshot.self, from: $0) }
        soldOut = Set((stored?.soldOut ?? []).compactMap(Flavor.init(rawValue:)))
    }

    var isEnabled: Bool { BoothConfig.current != nil }

    func isSoldOut(_ flavor: Flavor) -> Bool { soldOut.contains(flavor) }

    func start(square: SquareService, app: AppModel) {
        guard !started else { return }
        started = true
        self.square = square
        self.app = app
        guard let config = BoothConfig.current else {
            square.record("Booth: link disabled (BOOTH_URL or BOOTH_TOKEN not set)")
            return
        }
        UIDevice.current.isBatteryMonitoringEnabled = true
        observeTouches()
        observeActivation()
        Task { [weak self] in await self?.bootstrap(config) }
    }

    func tapHelpButton() {
        guard !helpBannerVisible else { return }
        helpBannerVisible = true
        requestHelp(.button, message: "Customer pressed the help button on the \(app?.screen.boothName ?? "builder") screen")
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.helpBannerVisible = false
        }
    }

    func requestHelp(_ reason: HelpReason, message: String) {
        guard isEnabled else { return }
        let now = Date()
        if reason != .button, let last = lastHelpSent[reason], now.timeIntervalSince(last) < Self.helpRateLimit { return }
        lastHelpSent[reason] = now
        log("Booth: help requested (\(reason.rawValue)): \(message)")
        let outbox = outbox
        Task { await outbox.enqueueHelp(reason: reason.rawValue, message: message) }
    }

    func paymentFailed(_ problem: PaymentProblem) {
        requestHelp(.paymentFailed, message: "Payment failed: \(problem.title)")
    }

    func checkReaderBeforePayment() {
        guard let app, let square, !app.simulatePayment, app.forcedError == nil, square.isConfigured,
              !UserDefaults.standard.bool(forKey: "kioskNoSquare"),
              !square.readers.contains(where: { $0.statusInfo.status == .ready }) else { return }
        requestHelp(.noReader, message: "No card reader is ready at checkout")
    }

    func orderPaid(_ receipt: Receipt, quote: OrderQuote) {
        let order = BoothOrder(receipt: receipt, quote: quote)
        log("Booth: order #\(order.orderNumber) queued for upload")
        let outbox = outbox
        Task { await outbox.enqueueOrder(order) }
    }

    private func log(_ message: String) {
        square?.record(message)
    }

    private func bootstrap(_ config: BoothConfig) async {
        let deviceID = await outbox.device()
        let api = BoothAPI(config: config, deviceID: deviceID)
        await outbox.attach(api: api) { [weak self] message in
            Task { @MainActor in self?.log(message) }
        }

        let connection = BoothConnection(api: api, role: .kiosk) { [weak self] message in self?.log(message) }
        connection.screen = { [weak self] in self?.app?.screen.boothName ?? "roleSetup" }
        connection.onState = { [weak self] state in self?.applyState(state) }
        connection.onConnectionChange = { [weak self] state in self?.connectionChanged(state) }
        self.connection = connection

        shipper = LogShipper(api: api, fileURL: SquareService.logFileURL) { [weak self] message in
            Task { @MainActor in self?.log(message) }
        }
        log("Booth: link enabled for \(config.baseURL.host() ?? "server") as \(deviceID.prefix(8))")
        connection.start()
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    private func connectionChanged(_ state: BoothConnection.ConnectionState) {
        connectionState = state
        guard state == .connected else { return }
        forceHealth = true
        lastUpload = .distantPast
        let outbox = outbox
        let shipper = shipper
        Task {
            await outbox.kick(resetBackoff: true)
            await shipper?.resetBackoff()
        }
    }

    private func applyState(_ state: BoothState) {
        let updated = Set(state.flavors.filter(\.soldOut).compactMap { Flavor(rawValue: $0.id) })
        guard updated != soldOut else { return }
        soldOut = updated
        let snapshot = SoldOutSnapshot(rev: state.rev, soldOut: updated.map(\.rawValue).sorted())
        UserDefaults.standard.set(try? JSONEncoder().encode(snapshot), forKey: Self.soldOutKey)
        log("Booth: sold out is now " + (snapshot.soldOut.isEmpty ? "none" : snapshot.soldOut.joined(separator: ", ")))
    }

    private func observeTouches() {
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: TouchObserver.didTouch) {
                guard let self else { return }
                lastTouch = Date()
                idleSent = false
            }
        }
    }

    private func observeActivation() {
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
                guard let self else { return }
                let outbox = outbox
                Task { await outbox.kick(resetBackoff: true) }
            }
        }
    }

    private func tick() {
        let now = Date()
        checkIdle(now)
        queueHealth(now)
        if connectionState == .connected, now.timeIntervalSince(lastUpload) >= Self.uploadInterval, let shipper {
            lastUpload = now
            Task { await shipper.ship() }
        }
    }

    private func queueHealth(_ now: Date) {
        guard let app, let square else { return }
        let snapshot = BoothHealth.snapshot(square: square, screen: app.screen.boothName, simulatePayment: app.simulatePayment)
        let age = now.timeIntervalSince(lastHealthQueued)
        let changed = snapshot != lastHealth
        guard forceHealth || (changed && age >= Self.healthDebounce) || (connectionState == .connected && age >= Self.healthRefresh) else { return }
        forceHealth = false
        lastHealth = snapshot
        lastHealthQueued = now
        let outbox = outbox
        Task { await outbox.enqueueHealth(snapshot) }
    }

    private func checkIdle(_ now: Date) {
        guard !idleSent, let app, app.screen == .builder || app.screen == .name,
              !app.items.isEmpty || app.current.hasChoices,
              now.timeIntervalSince(lastTouch) >= Self.idleLimit else { return }
        idleSent = true
        requestHelp(.idle, message: "Customer has been idle for a minute mid-order on the \(app.screen.boothName) screen")
    }
}
