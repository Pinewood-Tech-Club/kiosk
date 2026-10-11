import CryptoKit
import Foundation

struct SquareCredentials: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        case booth
        case bundled
    }

    var accessToken: String
    var locationID: String
    var merchantID: String?
    var expiresAt: Date?
    var environment: String
    var applicationID: String?
    var source: Source
    var fetchedAt: Date

    var fingerprint: String {
        SHA256.hash(data: Data(accessToken.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    func isUsable(at now: Date) -> Bool {
        expiresAt.map { $0 > now.addingTimeInterval(300) } ?? true
    }
}

private struct BoothSquareCredentials: Decodable {
    var accessToken: String
    var locationId: String
    var merchantId: String?
    var expiresAt: Double?
    var environment: String
    var applicationId: String?
    var source: String
    var fetchAgainAt: Double?
}

/// Square credentials for the SDK and the on-device API. The booth backend is the source of truth; its last answer is
/// kept in the Keychain so the kiosk works without it. The token baked into Local.xcconfig is only a dev fallback.
final class SquareCredentialStore {
    private static let keychainAccount = "squareCredentials"
    private static let maxInterval: TimeInterval = 30 * 60
    private static let minInterval: TimeInterval = 60

    private(set) var current: SquareCredentials?
    var onChange: ((SquareCredentials?) -> Void)?

    private var api: BoothAPI?
    private var log: (String) -> Void = { _ in }
    private var loop: Task<Void, Never>?
    private var failures = 0

    init() {
        current = Self.cached() ?? Self.bundled()
    }

    static var appEnvironment: String {
        (Config.squareApplicationID ?? "").hasPrefix("sandbox-") ? "sandbox" : "production"
    }

    var sourceDescription: String {
        switch current?.source {
        case .booth: "booth"
        case .bundled: "Local.xcconfig"
        case nil: "none"
        }
    }

    private static func cached() -> SquareCredentials? {
        guard let data = Keychain.data(for: keychainAccount),
              let credentials = try? JSONDecoder().decode(SquareCredentials.self, from: data),
              credentials.environment == appEnvironment,
              credentials.applicationID == nil || credentials.applicationID == Config.squareApplicationID,
              credentials.isUsable(at: Date())
        else { return nil }
        return credentials
    }

    private static func bundled() -> SquareCredentials? {
        guard let token = Config.accessToken, let location = Config.locationID else { return nil }
        return SquareCredentials(accessToken: token, locationID: location, merchantID: nil, expiresAt: nil, environment: appEnvironment,
                                 applicationID: Config.squareApplicationID, source: .bundled, fetchedAt: .distantPast)
    }

    func attach(api: BoothAPI, log: @escaping (String) -> Void) {
        guard self.api == nil else { return }
        self.api = api
        self.log = log
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = await self.refresh()
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    /// Fetches now and returns how long to wait before the next fetch.
    @MainActor
    @discardableResult
    func refresh() async -> TimeInterval {
        expireStale()
        guard let api else { return Self.maxInterval }
        do {
            let response: BoothSquareCredentials = try await api.get("/v1/square/credentials")
            failures = 0
            guard response.environment == Self.appEnvironment else {
                log("Square credentials: booth serves \(response.environment) but this build is \(Self.appEnvironment); ignoring them")
                return Self.maxInterval
            }
            if let theirs = response.applicationId, let mine = Config.squareApplicationID, theirs != mine {
                log("Square credentials: booth token is for application \(theirs), this build uses \(mine); ignoring it")
                return Self.maxInterval
            }
            let credentials = SquareCredentials(
                accessToken: response.accessToken, locationID: response.locationId, merchantID: response.merchantId,
                expiresAt: response.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) }, environment: response.environment,
                applicationID: response.applicationId, source: .booth, fetchedAt: Date()
            )
            if let data = try? JSONEncoder().encode(credentials) { Keychain.set(data, for: Self.keychainAccount) }
            apply(credentials, reason: "from the booth (\(response.source))")
            let next = response.fetchAgainAt.map { Date(timeIntervalSince1970: $0 / 1000).timeIntervalSinceNow } ?? Self.maxInterval
            return min(max(next, Self.minInterval), Self.maxInterval)
        } catch {
            failures += 1
            let booth = error as? BoothError
            if failures == 1 || failures % 20 == 0 {
                log("Square credentials: booth unavailable (\(booth?.summary ?? error.localizedDescription)); using the \(sourceDescription) token")
            }
            if booth?.status == 503 { return 10 * 60 }
            return max(Self.minInterval / 2, BoothBackoff.delay(failures: failures, cap: 10 * 60))
        }
    }

    private func expireStale() {
        guard let current, !current.isUsable(at: Date()) else { return }
        Keychain.remove(Self.keychainAccount)
        apply(Self.bundled(), reason: "after the cached token expired")
    }

    private func apply(_ credentials: SquareCredentials?, reason: String) {
        let changed = credentials?.accessToken != current?.accessToken || credentials?.locationID != current?.locationID
            || credentials?.source != current?.source
        current = credentials
        guard changed else { return }
        if let credentials {
            let expiry = credentials.expiresAt.map { ", expires \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
            log("Square credentials \(reason): location \(credentials.locationID), token \(credentials.fingerprint)\(expiry)")
        } else {
            log("Square credentials \(reason): none left")
        }
        onChange?(credentials)
    }
}
