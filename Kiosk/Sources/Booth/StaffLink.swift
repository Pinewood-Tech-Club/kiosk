import Foundation
import Observation

@Observable
@MainActor
final class StaffLink {
    private struct Session: Decodable {
        let token: String
        let expiresAt: Double
    }

    private static let deviceKey = "boothStaffDeviceID"

    private(set) var connectionState: BoothConnection.ConnectionState = .idle
    private(set) var state: BoothState?
    private(set) var problem: String?

    @ObservationIgnored private(set) var connection: BoothConnection?
    @ObservationIgnored private var log: (String) -> Void = { _ in }
    @ObservationIgnored private var started = false

    static var deviceID: String {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: deviceKey), !stored.isEmpty { return stored }
        let id = "staff-" + UUID().uuidString
        defaults.set(id, forKey: deviceKey)
        return id
    }

    var openOrders: [BoothOrderSummary] { state?.orders.filter(\.isOpen) ?? [] }
    var openAlerts: [BoothAlert] { state?.alerts.filter(\.isOpen) ?? [] }

    func start(log: @escaping (String) -> Void) {
        guard !started else { return }
        started = true
        self.log = log
        connect()
    }

    func signIn(pin: String) async throws {
        guard let config = BoothConfig.anonymous() else { throw BoothError.badResponse("BOOTH_URL isn't set") }
        let session: Session = try await BoothAPI(config: config, deviceID: Self.deviceID).post("/v1/staff/session", ["pin": pin])
        Keychain.set(Data(session.token.utf8), for: BoothConfig.staffSessionAccount)
        log("Staff: signed in until \(Date(timeIntervalSince1970: session.expiresAt / 1000).formatted(date: .abbreviated, time: .shortened))")
        if connection == nil { connect() }
    }

    private func connect() {
        guard let config = BoothConfig.staff() else {
            problem = BoothConfig.publicBaseURL == nil
                ? "BOOTH_URL isn't set."
                : "No staff token. Set BOOTH_STAFF_TOKEN or sign in with the staff PIN."
            log("Staff: \(problem ?? "")")
            return
        }
        problem = nil
        let connection = BoothConnection(api: BoothAPI(config: config, deviceID: Self.deviceID), role: .staff) { [weak self] in self?.log($0) }
        connection.onState = { [weak self] state in self?.state = state }
        connection.onConnectionChange = { [weak self] state in self?.connectionState = state }
        self.connection = connection
        connection.start()
    }
}
