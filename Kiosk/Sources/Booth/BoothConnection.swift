import Foundation
import Network
import Observation
import UIKit

@Observable
@MainActor
final class BoothConnection {
    enum Role { case kiosk, staff }

    enum ConnectionState: Equatable {
        case idle
        case connecting
        case connected
        case waiting(retryAt: Date)
    }

    private struct PendingAction {
        let action: BoothAction
        let createdAt: Date
        var lastAttempt: Date?
    }

    private static let beatInterval: TimeInterval = 10
    private static let silenceLimit: TimeInterval = 25
    private static let connectTimeout: TimeInterval = 20
    private static let healthyAfter: TimeInterval = 20
    private static let syncSpacing: TimeInterval = 3
    private static let syncRetry: TimeInterval = 10
    private static let actionRetry: TimeInterval = 5
    private static let actionLifetime: TimeInterval = 600
    private static let logSpacing: TimeInterval = 10

    private(set) var state: BoothState?
    private(set) var rev = 0
    private(set) var connectionState: ConnectionState = .idle

    @ObservationIgnored var screen: () -> String = { "" }
    @ObservationIgnored var onState: ((BoothState) -> Void)?
    @ObservationIgnored var onConnectionChange: ((ConnectionState) -> Void)?

    @ObservationIgnored private let api: BoothAPI
    @ObservationIgnored private let role: Role
    @ObservationIgnored private let log: (String) -> Void
    @ObservationIgnored private let session = URLSession(configuration: .ephemeral)
    @ObservationIgnored private var started = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var isForeground = true
    @ObservationIgnored private var pathSatisfied = true
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var failureLogged = false
    @ObservationIgnored private var unauthorizedLogged = false
    @ObservationIgnored private var lastTransitionLog = Date.distantPast
    @ObservationIgnored private var connectStartedAt = Date()
    @ObservationIgnored private var connectedAt: Date?
    @ObservationIgnored private var lastInbound = Date()
    @ObservationIgnored private var lastBeat = Date.distantPast
    @ObservationIgnored private var needsSync = false
    @ObservationIgnored private var lastSync = Date.distantPast
    @ObservationIgnored private var pendingActions: [PendingAction] = []
    @ObservationIgnored private var actionHTTPInFlight = false

    init(api: BoothAPI, role: Role, log: @escaping (String) -> Void) {
        self.api = api
        self.role = role
        self.log = log
    }

    func start() {
        guard !started else { return }
        started = true
        isForeground = UIApplication.shared.applicationState != .background
        observeLifecycle()
        startPathMonitor()
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
        resume(resetBackoff: true)
    }

    @discardableResult
    func ack(alertID: String, by name: String) -> String {
        enqueue(BoothAction(id: UUID().uuidString, type: "ack", alertId: alertID, flavor: nil, soldOut: nil, orderId: nil, status: nil, by: name))
    }

    @discardableResult
    func setSoldOut(_ flavor: String, soldOut: Bool, by name: String) -> String {
        enqueue(BoothAction(id: UUID().uuidString, type: "setSoldOut", alertId: nil, flavor: flavor, soldOut: soldOut, orderId: nil, status: nil, by: name))
    }

    @discardableResult
    func setOrderStatus(_ orderID: String, status: String, by name: String) -> String {
        enqueue(BoothAction(id: UUID().uuidString, type: "setOrderStatus", alertId: nil, flavor: nil, soldOut: nil, orderId: orderID, status: status, by: name))
    }

    func requestSync() {
        needsSync = true
        let now = Date()
        guard now.timeIntervalSince(lastSync) >= Self.syncSpacing else { return }
        lastSync = now
        send(["type": "sync"])
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        Task { [weak self] in
            for await _ in center.notifications(named: UIApplication.didBecomeActiveNotification) {
                guard let self else { return }
                foregrounded()
            }
        }
        Task { [weak self] in
            for await _ in center.notifications(named: UIApplication.willEnterForegroundNotification) {
                guard let self else { return }
                foregrounded()
            }
        }
        Task { [weak self] in
            for await _ in center.notifications(named: UIApplication.didEnterBackgroundNotification) {
                guard let self else { return }
                isForeground = false
                suspend()
            }
        }
    }

    private func foregrounded() {
        isForeground = true
        if connectionState == .connected {
            if Date().timeIntervalSince(lastInbound) > 15 {
                ended(generation, task: socket, reason: "connection went stale while the app was inactive", resetBackoff: true)
            } else {
                lastBeat = .distantPast
            }
        } else {
            resume(resetBackoff: true)
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
        guard satisfied != pathSatisfied else { return }
        pathSatisfied = satisfied
        if satisfied {
            resume(resetBackoff: true)
        } else {
            suspend()
        }
    }

    private func resume(resetBackoff: Bool) {
        guard isForeground, pathSatisfied else { return }
        switch connectionState {
        case .connected, .connecting:
            return
        case .idle, .waiting:
            if resetBackoff { failures = 0 }
            connect()
        }
    }

    private func suspend() {
        retryTask?.cancel()
        retryTask = nil
        generation += 1
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        connectedAt = nil
        guard connectionState != .idle else { return }
        let wasConnected = connectionState == .connected
        setConnection(.idle)
        if wasConnected { logTransition("Booth: connection paused (app inactive or network lost)") }
    }

    private func setConnection(_ new: ConnectionState) {
        guard connectionState != new else { return }
        connectionState = new
        onConnectionChange?(new)
    }

    private func logTransition(_ message: String) {
        let now = Date()
        guard now.timeIntervalSince(lastTransitionLog) >= Self.logSpacing else { return }
        lastTransitionLog = now
        log(message)
    }

    private func connect() {
        retryTask?.cancel()
        retryTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        generation += 1
        let current = generation
        connectStartedAt = Date()
        setConnection(.connecting)

        let task = session.webSocketTask(with: api.socketRequest())
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
        connectedAt = Date()
        lastInbound = Date()
        failureLogged = false
        unauthorizedLogged = false
        needsSync = false
        setConnection(.connected)
        logTransition("Booth: connected")
        beat(Date())
    }

    private func ended(_ current: Int, task: URLSessionWebSocketTask?, reason: String, resetBackoff: Bool = false) {
        guard current == generation else { return }
        generation += 1
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil

        let status = (task?.response as? HTTPURLResponse)?.statusCode
        let slow = status == 401 || status == 403 || status == 404
        let wasConnected = connectionState == .connected
        if wasConnected, let connectedAt, Date().timeIntervalSince(connectedAt) >= Self.healthyAfter { failures = 0 }
        if resetBackoff { failures = 0 }
        connectedAt = nil

        if slow {
            if !unauthorizedLogged { log("Booth: server refused the connection (HTTP \(status ?? 0)); retrying slowly") }
            unauthorizedLogged = true
        } else if !failureLogged {
            logTransition(wasConnected ? "Booth: disconnected (\(reason))" : "Booth: connection failed (\(reason))")
        }
        failureLogged = true

        guard isForeground, pathSatisfied else {
            setConnection(.idle)
            return
        }
        failures += 1
        let delay = slow ? 60 * Double.random(in: 0.8...1.2) : BoothBackoff.delay(failures: failures, cap: 30, jitter: 0.7...1.3)
        setConnection(.waiting(retryAt: Date().addingTimeInterval(delay)))
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    private func tick() {
        let now = Date()
        switch connectionState {
        case .connecting:
            if now.timeIntervalSince(connectStartedAt) > Self.connectTimeout {
                ended(generation, task: socket, reason: "timed out")
            }
        case .connected:
            if now.timeIntervalSince(lastInbound) > Self.silenceLimit {
                ended(generation, task: socket, reason: "no reply from server")
            } else {
                if now.timeIntervalSince(lastBeat) >= Self.beatInterval { beat(now) }
                if needsSync, now.timeIntervalSince(lastSync) >= Self.syncRetry { requestSync() }
            }
        case .idle, .waiting:
            break
        }
        retryActions(now)
    }

    private func beat(_ now: Date) {
        lastBeat = now
        let millis = Int(now.timeIntervalSince1970 * 1000)
        switch role {
        case .kiosk: send(["type": "heartbeat", "t": millis, "screen": screen()])
        case .staff: send(["type": "ping", "t": millis])
        }
    }

    private func send(_ object: [String: Any]) {
        guard connectionState == .connected, let socket, JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    private func sendEncodable(_ type: String, key: String, value: some Encodable) {
        guard connectionState == .connected,
              let valueData = try? JSONEncoder().encode(value),
              let valueObject = try? JSONSerialization.jsonObject(with: valueData) else { return }
        send(["type": type, key: valueObject])
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let raw): data = raw
        @unknown default: return
        }
        guard let decoded = try? JSONDecoder().decode(BoothServerMessage.self, from: data) else { return }
        switch decoded {
        case .snapshot(let snapshot):
            state = snapshot
            rev = snapshot.rev
            needsSync = false
            onState?(snapshot)
        case .patch(let patchRev, let change):
            applyPatch(rev: patchRev, change: change)
        case .pong(let serverRev):
            if let serverRev, serverRev > rev { requestSync() }
        case .result(let result):
            completeAction(result)
        case .error(let body):
            log("Booth: server error \(body.code): \(body.message)")
        case .unknown:
            break
        }
    }

    private func applyPatch(rev patchRev: Int, change: BoothChange) {
        guard patchRev > rev else { return }
        guard patchRev == rev + 1, var current = state else {
            requestSync()
            return
        }
        switch change {
        case .flavors(let flavors):
            current.flavors = flavors
        case .alert(let alert):
            if let index = current.alerts.firstIndex(where: { $0.id == alert.id }) {
                current.alerts[index] = alert
            } else {
                current.alerts.insert(alert, at: 0)
                if current.alerts.count > 60 { current.alerts.removeLast(current.alerts.count - 60) }
            }
        case .kiosk(let kiosk):
            current.kiosk = kiosk
        case .order(let order):
            if let index = current.orders.firstIndex(where: { $0.id == order.id }) {
                current.orders[index] = order
            } else {
                current.orders.insert(order, at: 0)
                current.orders.sort { $0.paidAt > $1.paidAt }
                if current.orders.count > 100 { current.orders.removeLast(current.orders.count - 100) }
            }
        case .unknown:
            break
        }
        current.rev = patchRev
        state = current
        rev = patchRev
        onState?(current)
    }

    private func enqueue(_ action: BoothAction) -> String {
        pendingActions.append(PendingAction(action: action, createdAt: Date(), lastAttempt: nil))
        retryActions(Date())
        return action.id
    }

    private func completeAction(_ result: BoothResult) {
        guard let index = pendingActions.firstIndex(where: { $0.action.id == result.id }) else { return }
        if result.status == "rejected" {
            log("Booth: server rejected an action: \(result.error?.message ?? "no reason")")
        }
        pendingActions.remove(at: index)
    }

    private func retryActions(_ now: Date) {
        pendingActions.removeAll { now.timeIntervalSince($0.createdAt) > Self.actionLifetime }
        guard !pendingActions.isEmpty else { return }
        let due = pendingActions.indices.filter { index in
            pendingActions[index].lastAttempt.map { now.timeIntervalSince($0) >= Self.actionRetry } ?? true
        }
        guard !due.isEmpty else { return }
        for index in due { pendingActions[index].lastAttempt = now }
        let actions = due.map { pendingActions[$0].action }
        if connectionState == .connected {
            for action in actions { sendEncodable("action", key: "action", value: action) }
        } else if !actionHTTPInFlight {
            actionHTTPInFlight = true
            Task { [weak self, api] in
                let response: BoothBatchResponse? = try? await api.post("/v1/actions", ["actions": actions])
                guard let self else { return }
                actionHTTPInFlight = false
                response?.results.forEach { self.completeAction($0) }
            }
        }
    }
}
