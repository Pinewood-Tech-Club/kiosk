import Foundation

actor LogShipper {
    private struct State: Codable {
        var identity: String
        var epoch: Int
        var offset: UInt64
    }

    private struct Request: Encodable {
        let appVersion: String
        let epoch: Int?
        let lines: [Line]
    }

    private struct Line: Encodable {
        let id: String
        let ts: String
        let level: String
        let message: String
    }

    private static let stateKey = "boothLogShipState"
    private static let maxBatchBytes = 200_000
    private static let maxBatchLines = 300
    private static let backlogLimit: UInt64 = 20_000_000
    private static let backlogKeep: UInt64 = 5_000_000

    private let api: BoothAPI
    private let fileURL: URL
    private let log: @Sendable (String) -> Void
    private var running = false
    private var failures = 0
    private var nextAttempt = Date.distantPast
    private var lastFailure: String?
    private var skips = 0

    init(api: BoothAPI, fileURL: URL, log: @escaping @Sendable (String) -> Void) {
        self.api = api
        self.fileURL = fileURL
        self.log = log
    }

    func resetBackoff() {
        failures = 0
        nextAttempt = .distantPast
    }

    nonisolated static func size(of fileURL: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    func skip(to offset: UInt64) {
        skips += 1
        guard let file = fileStatus() else { return }
        let current = loadState()
        let epoch = current?.identity == file.identity ? current?.epoch ?? 0 : 0
        saveState(State(identity: file.identity, epoch: epoch, offset: min(offset, file.size)))
    }

    func ship() async {
        guard !running, Date() >= nextAttempt else { return }
        running = true
        defer { running = false }
        while let batch = nextBatch() {
            let skipsBefore = skips
            if let lines = batch.lines {
                do {
                    let _: BoothLogsResponse = try await api.post("/v1/logs", Request(appVersion: BoothIdentity.appVersion,
                                                                                        epoch: BoothEpoch.known, lines: lines))
                } catch let error as BoothError {
                    if error.isItemFault {
                        log("Booth: server refused a log batch (\(error.summary)); skipped it")
                    } else {
                        noteFailure(error)
                        return
                    }
                } catch {
                    noteFailure(.network(error.localizedDescription))
                    return
                }
            }
            guard skips == skipsBefore else { continue }
            var state = loadState()
            state?.offset = batch.endOffset
            saveState(state)
            noteSuccess()
        }
    }

    private func noteFailure(_ error: BoothError) {
        failures += 1
        nextAttempt = Date().addingTimeInterval(error.nextDelay(failures: failures, cap: 120))
        guard lastFailure != error.summary else { return }
        lastFailure = error.summary
        log("Booth: log upload failed: \(error.summary)")
    }

    private func noteSuccess() {
        failures = 0
        nextAttempt = .distantPast
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

    private func fileStatus() -> (size: UInt64, identity: String)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { return nil }
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let created = (attributes[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return (size, "\(inode)-\(Int(created))")
    }

    private func nextBatch() -> (lines: [Line]?, endOffset: UInt64)? {
        guard let (size, identity) = fileStatus() else { return nil }

        var state = loadState()
        if state?.identity != identity {
            state = State(identity: identity, epoch: 0, offset: 0)
        } else if let current = state, size < current.offset {
            state = State(identity: identity, epoch: current.epoch + 1, offset: 0)
        }
        if var current = state, size - min(size, current.offset) > Self.backlogLimit {
            let skipped = size - current.offset
            current.offset = skipAhead(to: size - Self.backlogKeep, size: size)
            state = current
            log("Booth: \(skipped / 1_000_000) MB of log was never uploaded; skipped ahead to the last \(Self.backlogKeep / 1_000_000) MB")
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

        let prefix = String(api.deviceID.prefix(8))
        let idPrefix = "\(prefix)-\(identity)" + (state.epoch > 0 ? "e\(state.epoch)" : "")
        var lines: [Line] = []
        var lineStart = 0
        var previousDate = Date()
        while lineStart < usable, lines.count < Self.maxBatchLines {
            let end = bytes[lineStart..<usable].firstIndex(of: newline) ?? usable
            let text = String(decoding: bytes[lineStart..<end], as: UTF8.self)
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                let parsed = Self.parse(text, fallback: previousDate)
                previousDate = parsed.date
                lines.append(Line(id: "\(idPrefix)-\(state.offset + UInt64(lineStart))", ts: BoothTime.string(parsed.date),
                                  level: Self.level(of: parsed.message), message: parsed.message))
            }
            lineStart = min(end + 1, usable)
        }
        guard lineStart > 0 else { return nil }
        return (lines.isEmpty ? nil : lines, state.offset + UInt64(lineStart))
    }

    private func skipAhead(to target: UInt64, size: UInt64) -> UInt64 {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return target }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: target)) != nil, let data = try? handle.read(upToCount: 65_536),
              let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { return target }
        return min(size, target + UInt64(newline - data.startIndex) + 1)
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
