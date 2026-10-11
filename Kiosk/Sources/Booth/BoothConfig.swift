import Foundation

struct BoothConfig: Sendable {
    let baseURL: URL
    let socketURL: URL
    let token: String

    static let current: BoothConfig? = {
        guard var host = value("BoothURL"), let token = value("BoothToken") else { return nil }
        if !host.contains("://") { host = "https://" + host }
        guard var components = URLComponents(string: host), components.host?.isEmpty == false else { return nil }
        components.path = ""
        components.query = nil
        guard let base = components.url else { return nil }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = "/v1/ws"
        guard let socket = components.url else { return nil }
        return BoothConfig(baseURL: base, socketURL: socket, token: token)
    }()

    private static func value(_ key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.hasPrefix("$(") ? nil : trimmed
    }
}

enum BoothIdentity {
    static let installID: String = {
        let key = "boothInstallID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    static let appVersion: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }()
}

enum BoothTime {
    static func string(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    static func parse(_ text: String) -> Date? {
        try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)
    }
}

enum BoothOutcome: Sendable {
    case ok
    case unauthorized
    case rejected(Int)
    case failed(String)

    var summary: String {
        switch self {
        case .ok: "ok"
        case .unauthorized: "401 unauthorized (check BOOTH_TOKEN)"
        case .rejected(let status): "HTTP \(status)"
        case .failed(let reason): reason
        }
    }
}

struct BoothHTTP: Sendable {
    let config: BoothConfig

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()

    func post(_ path: String, body: Data) async -> BoothOutcome {
        var request = URLRequest(url: config.baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let (_, response) = try await Self.session.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode else { return .failed("no HTTP response") }
            switch status {
            case 200..<300: return .ok
            case 401: return .unauthorized
            default: return .rejected(status)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
