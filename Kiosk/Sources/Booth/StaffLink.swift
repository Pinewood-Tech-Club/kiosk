import Foundation
import Observation

@Observable
@MainActor
final class StaffLink {
    private struct Session: Decodable {
        let token: String
        let expiresAt: Double
    }

    struct Intent: Equatable {
        let actionID: String
        var soldOut = false
        var settledAt: Date?
    }

    private static let deviceKey = "boothStaffDeviceID"
    private static let settleGrace: TimeInterval = 5
    static let actorName = "Counter iPad"

    private(set) var connectionState: BoothConnection.ConnectionState = .idle
    private(set) var state: BoothState?
    private(set) var problem: String?
    private(set) var lastLiveAt: Date?
    private(set) var stateReceivedAt: Date?
    private(set) var clockOffset: TimeInterval = 0
    private(set) var soldOutIntents: [String: Intent] = [:]
    private(set) var ackIntents: [String: Intent] = [:]
    private(set) var rejection: String?

    private(set) var connection: BoothConnection?
    @ObservationIgnored private var log: (String) -> Void = { _ in }
    @ObservationIgnored private var started = false

    static var deviceID: String {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: deviceKey), !stored.isEmpty { return stored }
        let id = "staff-" + UUID().uuidString
        defaults.set(id, forKey: deviceKey)
        return id
    }

    private static var actionStore: URL {
        URL.applicationSupportDirectory.appending(path: "StaffActions.json")
    }

    var openOrders: [BoothOrderSummary] { state?.orders.filter(\.isOpen) ?? [] }
    var openAlerts: [BoothAlert] { state?.alerts.filter(\.isOpen) ?? [] }

    var needsSignIn: Bool {
        connection == nil ? BoothConfig.publicBaseURL != nil : connection?.refusedStatus == 401
    }

    var hasQueuedActions: Bool {
        soldOutIntents.values.contains { $0.settledAt == nil } || ackIntents.values.contains { $0.settledAt == nil }
    }

    func isSoldOut(_ flavor: BoothFlavorState) -> Bool {
        soldOutIntents[flavor.id]?.soldOut ?? flavor.soldOut
    }

    func isSending(flavor id: String) -> Bool {
        soldOutIntents[id].map { $0.settledAt == nil } ?? false
    }

    func isAcknowledged(_ alert: BoothAlert) -> Bool {
        !alert.isOpen || ackIntents[alert.id] != nil
    }

    func isSending(alert id: String) -> Bool {
        ackIntents[id].map { $0.settledAt == nil } ?? false
    }

    func localDate(_ serverMillis: Double) -> Date {
        Date(timeIntervalSince1970: serverMillis / 1000 - clockOffset)
    }

    func start(log: @escaping (String) -> Void) {
        guard !started else { return }
        started = true
        self.log = log
        connect()
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.reconcile()
            }
        }
    }

    func signIn(pin: String) async throws {
        guard let config = BoothConfig.anonymous() else { throw BoothError.badResponse("BOOTH_URL isn't set") }
        let session: Session = try await BoothAPI(config: config, deviceID: Self.deviceID).post("/v1/staff/session", ["pin": pin])
        Keychain.set(Data(session.token.utf8), for: BoothConfig.staffSessionAccount)
        log("Staff: signed in until \(Date(timeIntervalSince1970: session.expiresAt / 1000).formatted(date: .abbreviated, time: .shortened))")
        connect(preferSession: true)
    }

    func toggleSoldOut(_ flavor: BoothFlavorState) {
        guard let connection else { return }
        let soldOut = !isSoldOut(flavor)
        let id = connection.setSoldOut(flavor.id, soldOut: soldOut, by: Self.actorName)
        soldOutIntents[flavor.id] = Intent(actionID: id, soldOut: soldOut)
    }

    func acknowledge(_ alert: BoothAlert) {
        guard let connection, ackIntents[alert.id] == nil, alert.isOpen else { return }
        let id = connection.ack(alertID: alert.id, by: Self.actorName)
        ackIntents[alert.id] = Intent(actionID: id)
    }

    func dismissRejection() {
        rejection = nil
    }

    private func connect(preferSession: Bool = false) {
        guard let config = BoothConfig.staff(preferSession: preferSession) else {
            problem = BoothConfig.publicBaseURL == nil
                ? "BOOTH_URL isn't set, so this iPad can't reach the booth."
                : nil
            log(problem.map { "Staff: \($0)" } ?? "Staff: no staff token yet, showing PIN sign-in")
            return
        }
        problem = nil
        if let old = connection {
            old.onState = nil
            old.onConnectionChange = nil
            old.onActionSettled = nil
            old.stop()
        }
        let connection = BoothConnection(api: BoothAPI(config: config, deviceID: Self.deviceID), role: .staff,
                                         actionStore: Self.actionStore) { [weak self] in self?.log($0) }
        connection.onState = { [weak self] state in self?.received(state) }
        connection.onConnectionChange = { [weak self] state in self?.connectionChanged(state) }
        connection.onActionSettled = { [weak self] id, result in self?.settled(id, result: result) }
        self.connection = connection
        restoreIntents(from: connection.queuedActions)
        connection.start()
    }

    private func restoreIntents(from actions: [BoothAction]) {
        for action in actions {
            switch action.type {
            case "setSoldOut":
                if let flavor = action.flavor, let soldOut = action.soldOut {
                    soldOutIntents[flavor] = Intent(actionID: action.id, soldOut: soldOut)
                }
            case "ack":
                if let alert = action.alertId { ackIntents[alert] = Intent(actionID: action.id) }
            default:
                break
            }
        }
    }

    private func received(_ new: BoothState) {
        if new.serverTime != state?.serverTime {
            clockOffset = new.serverTime / 1000 - Date().timeIntervalSince1970
        }
        state = new
        stateReceivedAt = Date()
        reconcile()
    }

    private func connectionChanged(_ new: BoothConnection.ConnectionState) {
        if connectionState == .connected || new == .connected { lastLiveAt = Date() }
        connectionState = new
    }

    private func settled(_ actionID: String, result: BoothResult?) {
        let rejected = result == nil || result?.status == "rejected"
        if let message = result?.error?.message, rejected {
            rejection = "The booth didn't accept that change: \(message)"
        } else if result == nil {
            rejection = "A change couldn't reach the booth for 10 minutes and was dropped. Try again."
        }
        for (key, intent) in soldOutIntents where intent.actionID == actionID {
            if rejected { soldOutIntents[key] = nil } else { soldOutIntents[key]?.settledAt = Date() }
        }
        for (key, intent) in ackIntents where intent.actionID == actionID {
            if rejected { ackIntents[key] = nil } else { ackIntents[key]?.settledAt = Date() }
        }
        reconcile()
    }

    /// Drops an optimistic value once the hub shows it, or once a live hub has had a few seconds to show it
    /// (another staff device may have changed it since, and the hub's value wins). While offline the local copy
    /// of the hub is stale, so an accepted change keeps showing.
    private func reconcile() {
        let now = Date()
        let expired = { (settledAt: Date) in
            self.connectionState == .connected && now.timeIntervalSince(settledAt) > Self.settleGrace
        }
        let flavors = Dictionary((state?.flavors ?? []).map { ($0.id, $0.soldOut) }, uniquingKeysWith: { first, _ in first })
        for (key, intent) in soldOutIntents {
            guard let settledAt = intent.settledAt else { continue }
            if flavors[key] == intent.soldOut || expired(settledAt) { soldOutIntents[key] = nil }
        }
        let alerts = Dictionary((state?.alerts ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (key, intent) in ackIntents {
            guard let settledAt = intent.settledAt else { continue }
            if alerts[key]?.isOpen != true || expired(settledAt) { ackIntents[key] = nil }
        }
    }
}
