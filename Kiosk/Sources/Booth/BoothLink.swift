import Foundation
import Network
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
    enum ConnectionState: Equatable {
        case disabled
        case connecting
        case connected
        case waiting(retryAt: Date)
    }

    private struct HelpEvent {
        let id = UUID().uuidString
        let reason: HelpReason
        let message: String
        let at: Date
        var lastSent: Date?
    }

    private static let soldOutKey = "boothSoldOut"
    private static let heartbeatInterval: TimeInterval = 10
    private static let silenceLimit: TimeInterval = 25
    private static let connectTimeout: TimeInterval = 20
    private static let healthyAfter: TimeInterval = 20
    private static let idleLimit: TimeInterval = 60
    private static let helpRateLimit: TimeInterval = 30
    private static let helpExpiry: TimeInterval = 600
    private static let helpResend: TimeInterval = 20
    private static let uploadInterval: TimeInterval = 15

    private(set) var connectionState: ConnectionState = .disabled
    private(set) var soldOut: Set<Flavor>
    private(set) var helpBannerVisible = false

    @ObservationIgnored private var config: BoothConfig?
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var square: SquareService?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private let session = URLSession(configuration: .ephemeral)
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var failureLogged = false
    @ObservationIgnored private var unauthorizedLogged = false
    @ObservationIgnored private var connectStartedAt = Date()
    @ObservationIgnored private var connectedAt: Date?
    @ObservationIgnored private var lastInbound = Date()
    @ObservationIgnored private var lastHeartbeat = Date.distantPast
    @ObservationIgnored private var lastHealth: Data?
    @ObservationIgnored private var lastHealthSent = Date.distantPast
    @ObservationIgnored private var lastUpload = Date.distantPast
    @ObservationIgnored private var lastOrderDrain = Date.distantPast
    @ObservationIgnored private var lastTouch = Date()
    @ObservationIgnored private var idleSent = false
    @ObservationIgnored private var pendingHelp: [HelpEvent] = []
    @ObservationIgnored private var lastHelpSent: [HelpReason: Date] = [:]
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var pathSatisfied = true
    @ObservationIgnored private var shipper: LogShipper?
    @ObservationIgnored private var outbox: OrderOutbox?

    init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.soldOutKey) ?? []
        soldOut = Set(stored.compactMap(Flavor.init(rawValue:)))
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
        self.config = config
        UIDevice.current.isBatteryMonitoringEnabled = true

        let http = BoothHTTP(config: config)
        shipper = LogShipper(http: http, fileURL: SquareService.logFileURL) { [weak self] message in
            Task { @MainActor in self?.log(message) }
        }
        outbox = OrderOutbox(http: http) { [weak self] message in self?.log(message) }

        observeTouches()
        observeActivation()
        startPathMonitor()
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
        log("Booth: link enabled for \(config.baseURL.host() ?? "server")")
        connect()
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
        guard config != nil else { return }
        let now = Date()
        if reason != .button, let last = lastHelpSent[reason], now.timeIntervalSince(last) < Self.helpRateLimit { return }
        lastHelpSent[reason] = now
        var event = HelpEvent(reason: reason, message: message, at: now)
        log("Booth: help requested (\(reason.rawValue)): \(message)")
        if connectionState == .connected {
            sendHelp(event)
            event.lastSent = now
        }
        pendingHelp.append(event)
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
        outbox?.enqueue(BoothOrder(receipt: receipt, quote: quote))
    }

    private func log(_ message: String) {
        square?.record(message)
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
                reconnectIfWaiting()
                lastHeartbeat = .distantPast
            }
        }
    }

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.pathChanged(satisfied: satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "booth.path"))
        pathMonitor = monitor
    }

    private func pathChanged(satisfied: Bool) {
        let regained = satisfied && !pathSatisfied
        pathSatisfied = satisfied
        if regained { reconnectIfWaiting() }
    }

    private func reconnectIfWaiting() {
        if case .waiting = connectionState { connect() }
    }

    private func connect() {
        guard let config else { return }
        retryTask?.cancel()
        retryTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        generation += 1
        let current = generation
        connectionState = .connecting
        connectStartedAt = Date()

        var request = URLRequest(url: config.socketURL)
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = Self.connectTimeout
        let task = session.webSocketTask(with: request)
        socket = task
        task.resume()
        Task { [weak self] in await self?.run(task, generation: current) }
    }

    private func run(_ task: URLSessionWebSocketTask, generation current: Int) async {
        task.sendPing { [weak self] error in
            Task { @MainActor in
                guard let self, current == self.generation, self.connectionState == .connecting else { return }
                if let error {
                    self.ended(current, task: task, reason: error.localizedDescription)
                } else {
                    self.didConnect()
                }
            }
        }
        while current == generation {
            do {
                let message = try await task.receive()
                guard current == generation else { return }
                if connectionState == .connecting { didConnect() }
                lastInbound = Date()
                handle(message)
            } catch {
                ended(current, task: task, reason: error.localizedDescription)
                return
            }
        }
    }

    private func didConnect() {
        connectionState = .connected
        connectedAt = Date()
        lastInbound = Date()
        lastHeartbeat = .distantPast
        lastUpload = .distantPast
        lastOrderDrain = .distantPast
        failureLogged = false
        unauthorizedLogged = false
        log("Booth: connected")
        sendHealth(force: true)
        for index in pendingHelp.indices {
            sendHelp(pendingHelp[index])
            pendingHelp[index].lastSent = Date()
        }
    }

    private func ended(_ current: Int, task: URLSessionWebSocketTask?, reason: String) {
        guard current == generation else { return }
        generation += 1
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil

        let unauthorized = (task?.response as? HTTPURLResponse)?.statusCode == 401
        let wasConnected = connectionState == .connected
        if wasConnected, let connectedAt, Date().timeIntervalSince(connectedAt) >= Self.healthyAfter { failures = 0 }
        self.connectedAt = nil

        if unauthorized {
            if !unauthorizedLogged { log("Booth: server rejected the token (401); retrying slowly") }
            unauthorizedLogged = true
        } else if !failureLogged {
            log(wasConnected ? "Booth: disconnected (\(reason))" : "Booth: connection failed (\(reason))")
        }
        failureLogged = true

        let base = unauthorized ? 60 : min(30, pow(2, Double(failures)))
        failures += 1
        let delay = unauthorized ? base : min(30, base * Double.random(in: 0.8...1.2))
        connectionState = .waiting(retryAt: Date().addingTimeInterval(delay))
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    private func tick() {
        let now = Date()
        pendingHelp.removeAll { now.timeIntervalSince($0.at) > Self.helpExpiry }
        checkIdle(now)

        if let outbox, outbox.hasPending, now.timeIntervalSince(lastOrderDrain) >= Self.uploadInterval {
            lastOrderDrain = now
            Task { await outbox.drain() }
        }

        switch connectionState {
        case .connecting:
            if now.timeIntervalSince(connectStartedAt) > Self.connectTimeout {
                ended(generation, task: socket, reason: "timed out")
            }
        case .connected:
            if now.timeIntervalSince(lastInbound) > Self.silenceLimit {
                ended(generation, task: socket, reason: "no reply from server")
                return
            }
            if now.timeIntervalSince(lastHeartbeat) >= Self.heartbeatInterval { sendHeartbeat(now) }
            sendHealth(force: false)
            resendHelp(now)
            if now.timeIntervalSince(lastUpload) >= Self.uploadInterval {
                lastUpload = now
                if let shipper { Task { await shipper.ship() } }
            }
        case .disabled, .waiting:
            break
        }
    }

    private func checkIdle(_ now: Date) {
        guard !idleSent, let app, app.screen == .builder || app.screen == .name,
              !app.items.isEmpty || app.current.hasChoices,
              now.timeIntervalSince(lastTouch) >= Self.idleLimit else { return }
        idleSent = true
        requestHelp(.idle, message: "Customer has been idle for a minute mid-order on the \(app.screen.boothName) screen")
    }

    private func resendHelp(_ now: Date) {
        for index in pendingHelp.indices {
            guard let sent = pendingHelp[index].lastSent, now.timeIntervalSince(sent) >= Self.helpResend else { continue }
            sendHelp(pendingHelp[index])
            pendingHelp[index].lastSent = now
        }
    }

    private func send(_ object: [String: Any]) {
        guard connectionState == .connected, let socket,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    private func sendHeartbeat(_ now: Date) {
        lastHeartbeat = now
        send(["type": "heartbeat", "at": BoothTime.string(now), "screen": (app?.screen ?? .roleSetup).boothName])
    }

    private func sendHealth(force: Bool) {
        guard let app, let square else { return }
        let snapshot = BoothHealth.snapshot(square: square, screen: app.screen.boothName, simulatePayment: app.simulatePayment)
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot, options: .sortedKeys) else { return }
        let now = Date()
        let age = now.timeIntervalSince(lastHealthSent)
        let changed = data != lastHealth
        guard force || (changed && age >= 2) || age >= 60 else { return }
        lastHealth = data
        lastHealthSent = now
        send(["type": "health", "health": snapshot])
    }

    private func sendHelp(_ event: HelpEvent) {
        send(["type": "help", "id": event.id, "reason": event.reason.rawValue,
              "message": event.message, "at": BoothTime.string(event.at)])
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let raw): data = raw
        @unknown default: return
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String else { return }
        switch type {
        case "snapshot":
            let state = object["state"] as? [String: Any]
            if let map = state?["soldOut"] as? [String: Any] {
                applySoldOut(map)
            } else if let flavors = state?["flavors"] as? [[String: Any]] {
                applySoldOut(Dictionary(flavors.compactMap { entry in
                    (entry["id"] as? String).map { ($0, entry["soldOut"] ?? false) }
                }, uniquingKeysWith: { $1 }))
            }
        case "soldOut":
            if let map = object["soldOut"] as? [String: Any] { applySoldOut(map) }
        case "helpReceived":
            if let id = object["id"] as? String { pendingHelp.removeAll { $0.id == id } }
        case "error":
            log("Booth: server error: \(object["message"] as? String ?? object["error"] as? String ?? "unknown")")
        default:
            break
        }
    }

    private func applySoldOut(_ map: [String: Any]) {
        let updated = Set(Flavor.allCases.filter { (map[$0.rawValue] as? Bool) == true })
        guard updated != soldOut else { return }
        soldOut = updated
        UserDefaults.standard.set(updated.map(\.rawValue).sorted(), forKey: Self.soldOutKey)
        log("Booth: sold out is now " + (updated.isEmpty ? "none" : updated.map(\.rawValue).sorted().joined(separator: ", ")))
    }
}
