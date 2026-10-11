import Foundation

actor LogShipper {
    private struct State: Codable {
        var identity: String
        var epoch: Int
        var offset: UInt64
    }

    private struct Batch {
        let body: Data?
        let endOffset: UInt64
    }

    private static let stateKey = "boothLogShipState"
    private static let maxBatchBytes = 200_000
    private static let maxBatchLines = 300

    private let http: BoothHTTP
    private let fileURL: URL
    private let log: @Sendable (String) -> Void
    private var running = false
    private var lastFailure: String?

    init(http: BoothHTTP, fileURL: URL, log: @escaping @Sendable (String) -> Void) {
        self.http = http
        self.fileURL = fileURL
        self.log = log
    }

    func ship() async {
        guard !running else { return }
        running = true
        defer { running = false }
        while let batch = nextBatch() {
            if let body = batch.body {
                let outcome = await http.post("/v1/logs", body: body)
                guard case .ok = outcome else {
                    noteFailure(outcome.summary)
                    return
                }
            }
            var state = loadState()
            state?.offset = batch.endOffset
            saveState(state)
            noteSuccess()
        }
    }

    private func noteFailure(_ reason: String) {
        guard lastFailure != reason else { return }
        lastFailure = reason
        log("Booth: log upload failed: \(reason)")
    }

    private func noteSuccess() {
        guard lastFailure != nil else { return }
        lastFailure = nil
        log("Booth: log upload recovered")
    }

    private func loadState() -> State? {
        UserDefaults.standard.data(forKey: Self.stateKey).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
    }

    private func saveState(_ state: State?) {
        UserDefaults.standard.set(state.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.stateKey)
    }

    private func nextBatch() -> Batch? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { return nil }
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let created = (attributes[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let identity = "\(inode)-\(Int(created))"

        var state = loadState()
        if state?.identity != identity {
            state = State(identity: identity, epoch: 0, offset: 0)
        } else if let current = state, size < current.offset {
            state = State(identity: identity, epoch: current.epoch + 1, offset: 0)
        }
        saveState(state)
        guard let state, size > state.offset,
              let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }

        guard (try? handle.seek(toOffset: state.offset)) != nil,
              let data = try? handle.read(upToCount: Self.maxBatchBytes), !data.isEmpty else { return nil }
        let bytes = [UInt8](data)

        let newline = UInt8(ascii: "\n")
        let usable: Int
        if let last = bytes.lastIndex(of: newline) {
            usable = last + 1
        } else if bytes.count >= Self.maxBatchBytes {
            usable = bytes.count
        } else {
            return nil
        }

        let idPrefix = "\(BoothIdentity.installID)-\(identity)" + (state.epoch > 0 ? "e\(state.epoch)" : "")
        var lines: [[String: Any]] = []
        var lineStart = 0
        var previousDate = Date()
        while lineStart < usable, lines.count < Self.maxBatchLines {
            let end = bytes[lineStart..<usable].firstIndex(of: newline) ?? usable
            let text = String(decoding: bytes[lineStart..<end], as: UTF8.self)
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                let parsed = Self.parse(text, fallback: previousDate)
                previousDate = parsed.date
                lines.append([
                    "id": "\(idPrefix)-\(state.offset + UInt64(lineStart))",
                    "ts": BoothTime.string(parsed.date),
                    "level": Self.level(of: parsed.message),
                    "message": parsed.message,
                ])
            }
            lineStart = min(end + 1, usable)
        }
        guard lineStart > 0 else { return nil }

        let payload: [String: Any] = [
            "device": BoothIdentity.installID,
            "appVersion": BoothIdentity.appVersion,
            "lines": lines,
        ]
        let body = lines.isEmpty ? nil : try? JSONSerialization.data(withJSONObject: payload)
        if !lines.isEmpty, body == nil { return nil }
        return Batch(body: body, endOffset: state.offset + UInt64(lineStart))
    }

    private static func parse(_ line: String, fallback: Date) -> (date: Date, message: String) {
        if let space = line.firstIndex(of: " "), let date = BoothTime.parse(String(line[..<space])) {
            return (date, String(line[line.index(after: space)...]))
        }
        return (fallback, line)
    }

    private static func level(of message: String) -> String {
        let lowered = message.lowercased()
        if lowered.contains("error") || lowered.contains("failed") || message.contains("Uncaught") { return "error" }
        if message.contains("WARNING") { return "warn" }
        return "info"
    }
}
