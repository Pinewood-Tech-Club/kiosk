import Foundation

enum BoothError: Error, Sendable {
    case network(String)
    case badResponse(String)
    case encoding(String)
    case http(status: Int, code: String, message: String, retryAfter: TimeInterval?)

    var status: Int? {
        if case .http(let status, _, _, _) = self { return status }
        return nil
    }

    var isUnauthorized: Bool { status == 401 }

    var isRetryable: Bool {
        switch self {
        case .network, .badResponse: true
        case .encoding: false
        case .http(let status, _, _, _): status == 401 || status == 408 || status == 429 || status >= 500
        }
    }

    var isItemFault: Bool {
        switch self {
        case .encoding: true
        case .http(let status, _, _, _): status == 400 || status == 413
        default: false
        }
    }

    var needsSlowRetry: Bool {
        guard let status else { return false }
        return status == 401 || status == 403 || status == 404
    }

    var retryAfter: TimeInterval? {
        if case .http(_, _, _, let retryAfter) = self { return retryAfter }
        return nil
    }

    var summary: String {
        switch self {
        case .network(let reason): reason
        case .badResponse(let reason): "unexpected response (\(reason))"
        case .encoding(let reason): "could not encode (\(reason))"
        case .http(let status, let code, let message, _):
            status == 401 ? "401 unauthorized (check the token)" : "HTTP \(status) \(code) \(message)"
        }
    }

    func nextDelay(failures: Int, cap: TimeInterval) -> TimeInterval {
        var delay = BoothBackoff.delay(failures: failures, cap: cap)
        if needsSlowRetry { delay = max(delay, 60 * Double.random(in: 0.8...1.2)) }
        if let retryAfter { delay = max(delay, retryAfter) }
        return delay
    }
}

struct BoothAPI: Sendable {
    let config: BoothConfig
    let deviceID: String

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    func socketRequest() -> URLRequest {
        var request = URLRequest(url: config.socketURL)
        authorize(&request)
        request.timeoutInterval = 20
        return request
    }

    func post<Body: Encodable, Response: Decodable>(_ path: String, _ body: Body) async throws -> Response {
        let data: Data
        do {
            data = try JSONEncoder().encode(body)
        } catch {
            throw BoothError.encoding(error.localizedDescription)
        }
        return try decode(try await send("POST", path, body: data))
    }

    func get<Response: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> Response {
        try decode(try await send("GET", path, query: query))
    }

    private func decode<Response: Decodable>(_ data: Data) throws -> Response {
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw BoothError.badResponse(error.localizedDescription)
        }
    }

    private func authorize(_ request: inout URLRequest) {
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue(deviceID, forHTTPHeaderField: "X-Booth-Device")
    }

    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        guard var components = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false) else {
            throw BoothError.badResponse("bad base URL")
        }
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw BoothError.badResponse("bad URL") }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        authorize(&request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw BoothError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw BoothError.badResponse("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            let body = (try? JSONDecoder().decode(BoothErrorEnvelope.self, from: data))?.error
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init).map { min(max($0, 0), 120) }
            throw BoothError.http(status: http.statusCode, code: body?.code ?? "", message: body?.message ?? "", retryAfter: retryAfter)
        }
        return data
    }
}
