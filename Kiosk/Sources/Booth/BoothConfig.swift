import Foundation

struct BoothConfig: Sendable {
    let baseURL: URL
    let socketURL: URL
    let token: String

    static let current: BoothConfig? = {
        let defaults = UserDefaults.standard
        guard var host = clean(defaults.string(forKey: "boothURL")) ?? plistValue("BoothURL"),
              let token = clean(defaults.string(forKey: "boothToken")) ?? plistValue("BoothToken") else { return nil }
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

    private static func clean(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty || trimmed.hasPrefix("$(") ? nil : trimmed
    }

    private static func plistValue(_ key: String) -> String? {
        clean(Bundle.main.object(forInfoDictionaryKey: key) as? String)
    }
}

enum BoothIdentity {
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

enum BoothBackoff {
    static func delay(failures: Int, cap: TimeInterval, jitter: ClosedRange<Double> = 0.5...1.5) -> TimeInterval {
        let exponent = Double(min(max(failures - 1, 0), 10))
        return min(cap, pow(2, exponent)) * Double.random(in: jitter)
    }
}
