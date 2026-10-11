import Foundation

actor BoothOutbox {
    private struct StoredEvent: Codable {
        var queuedAt: Double
        var event: BoothEvent
    }

    private struct StoredOrder: Codable {
        var queuedAt: Double
        var order: BoothOrder
    }

    private struct Identity: Codable {
        var deviceID: String
        var seqCeiling: Int
    }

    private struct QueuedEvent {
        let file: URL
        let stored: StoredEvent
        var id: String { stored.event.id }
        var isHelp: Bool { stored.event.type == "help" }
        var isHealth: Bool { stored.event.type == "health" }
    }

    private struct QueuedOrder {
        let file: URL
        let stored: StoredOrder
        var id: String { stored.order.id }
    }

    private struct Lane {
        var failures = 0
        var next = Date.distantPast
        var running = false
        var lastFailure: String?
    }

    private static let seqBlock = 100
    private static let eventBatch = 50
    private static let orderBatch = 20
    private static let eventCap = 200
    private static let helpLifetime: TimeInterval = 30 * 60
    private static let seqCeilingKey = "boothSeqCeiling"
    private static let installIDKey = "boothInstallID"

    private let root: URL
    private let legacyOrders: URL
    private var api: BoothAPI?
    private var log: (@Sendable (String) -> Void)?
    private var loaded = false
    private var loop: Task<Void, Never>?
    private var deviceID = ""
    private var seq = 0
    private var seqCeiling = 0
    private var events: [QueuedEvent] = []
    private var orders: [QueuedOrder] = []
    private var eventLane = Lane()
    private var orderLane = Lane()

    init() {
        let support = URL.applicationSupportDirectory
        root = support.appending(path: "BoothOutbox", directoryHint: .isDirectory)
        legacyOrders = support.appending(path: "booth-orders.json")
    }

    var pendingOrderCount: Int { orders.count }

    func device() -> String {
        ensureLoaded()
        return deviceID
    }

    func attach(api: BoothAPI, log: @escaping @Sendable (String) -> Void) {
        ensureLoaded()
        self.api = api
        self.log = log
        if loop == nil {
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    await self?.tick()
                }
            }
        }
        migrateLegacyOrders()
        Task { await flushDue() }
    }

    func kick(resetBackoff: Bool) {
        if resetBackoff {
            eventLane.failures = 0
            eventLane.next = .distantPast
            orderLane.failures = 0
            orderLane.next = .distantPast
        }
        Task { await flushDue() }
    }

    func enqueueHelp(reason: String, message: String) {
        ensureLoaded()
        let event = BoothEvent(id: UUID().uuidString, seq: allocateSeq(), type: "help", at: BoothTime.string(Date()),
                               reason: reason, message: message, health: nil)
        store(event)
        enforceEventBounds()
        Task { await flushDue() }
    }

    func enqueueHealth(_ health: KioskHealth) {
        ensureLoaded()
        let event = BoothEvent(id: UUID().uuidString, seq: allocateSeq(), type: "health", at: BoothTime.string(Date()),
                               reason: nil, message: nil, health: health)
        let superseded = events.filter(\.isHealth)
        guard store(event) else { return }
        for old in superseded { remove(event: old) }
        enforceEventBounds()
        Task { await flushDue() }
    }

    func enqueueOrder(_ order: BoothOrder) {
        ensureLoaded()
        store(order)
        Task { await flushDue() }
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        let manager = FileManager.default
        for name in ["events", "orders", "rejected", "corrupt"] {
            try? manager.createDirectory(at: root.appending(path: name, directoryHint: .isDirectory), withIntermediateDirectories: true)
        }
        loadIdentity()
        events = loadFiles("events", as: StoredEvent.self).map { QueuedEvent(file: $0.0, stored: $0.1) }
        orders = loadFiles("orders", as: StoredOrder.self).map { QueuedOrder(file: $0.0, stored: $0.1) }
        enforceEventBounds()
    }

    private func loadFiles<T: Decodable>(_ directory: String, as type: T.Type) -> [(URL, T)] {
        let folder = root.appending(path: directory, directoryHint: .isDirectory)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".json") }
            .sorted()
        var loadedItems: [(URL, T)] = []
        for name in names {
            let file = folder.appending(path: name)
            if let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(T.self, from: data) {
                loadedItems.append((file, value))
            } else {
                quarantine(file, into: "corrupt")
            }
        }
        return loadedItems
    }

    private func quarantine(_ file: URL, into directory: String) {
        let target = root.appending(path: directory, directoryHint: .isDirectory).appending(path: file.lastPathComponent)
        try? FileManager.default.removeItem(at: target)
        if (try? FileManager.default.moveItem(at: file, to: target)) == nil {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func loadIdentity() {
        let defaults = UserDefaults.standard
        let file = root.appending(path: "identity.json")
        let defaultsID = defaults.string(forKey: Self.installIDKey).flatMap { Self.isValid(deviceID: $0) ? $0 : nil }
        let defaultsCeiling = defaults.integer(forKey: Self.seqCeilingKey)

        if let data = try? Data(contentsOf: file) {
            if let identity = try? JSONDecoder().decode(Identity.self, from: data), Self.isValid(deviceID: identity.deviceID) {
                deviceID = identity.deviceID
                seqCeiling = max(identity.seqCeiling, defaultsID == identity.deviceID ? defaultsCeiling : 0)
            } else {
                deviceID = UUID().uuidString
                seqCeiling = 0
                log?("Booth: identity file unreadable, using a new device id")
            }
        } else {
            deviceID = defaultsID ?? UUID().uuidString
            seqCeiling = defaultsID != nil ? defaultsCeiling : 0
        }
        seq = seqCeiling
        persistIdentity()
    }

    private static func isValid(deviceID: String) -> Bool {
        guard (1...64).contains(deviceID.count) else { return false }
        return deviceID.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "_" || scalar == "-")
        }
    }

    private func persistIdentity() {
        let defaults = UserDefaults.standard
        defaults.set(deviceID, forKey: Self.installIDKey)
        defaults.set(seqCeiling, forKey: Self.seqCeilingKey)
        if let data = try? JSONEncoder().encode(Identity(deviceID: deviceID, seqCeiling: seqCeiling)) {
            try? data.write(to: root.appending(path: "identity.json"), options: .atomic)
        }
    }

    private func allocateSeq() -> Int {
        seq += 1
        if seq > seqCeiling {
            seqCeiling = seq + Self.seqBlock - 1
            persistIdentity()
        }
        return seq
    }

    @discardableResult
    private func store(_ event: BoothEvent) -> Bool {
        let stored = StoredEvent(queuedAt: Date().timeIntervalSince1970, event: event)
        let name = String(format: "%012ld-%@.json", event.seq, event.id)
        let file = root.appending(path: "events", directoryHint: .isDirectory).appending(path: name)
        guard let data = try? JSONEncoder().encode(stored), (try? data.write(to: file, options: .atomic)) != nil else {
            log?("Booth: could not save a \(event.type) event to disk")
            return false
        }
        events.append(QueuedEvent(file: file, stored: stored))
        return true
    }

    private func store(_ order: BoothOrder) {
        let stored = StoredOrder(queuedAt: Date().timeIntervalSince1970, order: order)
        let name = String(format: "%015ld-%@.json", Int(stored.queuedAt * 1000), order.id)
        let file = root.appending(path: "orders", directoryHint: .isDirectory).appending(path: name)
        let written = (try? JSONEncoder().encode(stored)).flatMap { try? $0.write(to: file, options: .atomic) } != nil
        if !written { log?("Booth: could not save order #\(order.orderNumber) to disk, holding it in memory") }
        orders.append(QueuedOrder(file: file, stored: stored))
    }

    private func remove(event: QueuedEvent) {
        try? FileManager.default.removeItem(at: event.file)
        events.removeAll { $0.id == event.id }
    }

    private func remove(orderID: String, rejected: Bool) {
        guard let order = orders.first(where: { $0.id == orderID }) else { return }
        if rejected {
            quarantine(order.file, into: "rejected")
        } else {
            try? FileManager.default.removeItem(at: order.file)
        }
        orders.removeAll { $0.id == orderID }
    }

    private func enforceEventBounds() {
        let cutoff = Date().timeIntervalSince1970 - Self.helpLifetime
        let expired = events.filter { $0.isHelp && $0.stored.queuedAt < cutoff }
        for event in expired { remove(event: event) }
        if !expired.isEmpty { log?("Booth: dropped \(expired.count) help events older than 30 minutes") }

        let overflow = events.count - Self.eventCap
        guard overflow > 0 else { return }
        let victims = (events.filter(\.isHelp) + events.filter { !$0.isHelp }).prefix(overflow)
        for event in victims { remove(event: event) }
        log?("Booth: dropped \(victims.count) queued events (queue full)")
    }

    private func migrateLegacyOrders() {
        guard let data = try? Data(contentsOf: legacyOrders) else { return }
        let legacy = (try? JSONDecoder().decode([BoothOrder].self, from: data)) ?? []
        for order in legacy where !orders.contains(where: { $0.id == order.id }) { store(order) }
        try? FileManager.default.removeItem(at: legacyOrders)
        if !legacy.isEmpty { log?("Booth: moved \(legacy.count) queued orders into the new outbox") }
    }

    private func tick() async {
        enforceEventBounds()
        await flushDue()
    }

    private func flushDue() async {
        guard api != nil else { return }
        let now = Date()
        async let eventsDone: Void = flushEvents(now)
        async let ordersDone: Void = flushOrders(now)
        _ = await (eventsDone, ordersDone)
    }

    private func flushEvents(_ now: Date) async {
        guard let api, !eventLane.running, now >= eventLane.next, !events.isEmpty else { return }
        eventLane.running = true
        defer { eventLane.running = false }
        var batchSize = Self.eventBatch
        while !events.isEmpty {
            let batch = Array(events.prefix(batchSize))
            do {
                let response: BoothBatchResponse = try await api.post("/v1/events", ["events": batch.map { $0.stored.event }])
                var progressed = false
                for result in response.results {
                    guard let queued = batch.first(where: { $0.id == result.id }) else { continue }
                    progressed = true
                    if result.status == "rejected" {
                        log?("Booth: server rejected \(queued.stored.event.type) event: \(result.error?.message ?? "no reason")")
                    }
                    remove(event: queued)
                }
                guard progressed else { throw BoothError.badResponse("no results") }
                eventLane.failures = 0
                eventLane.lastFailure = nil
                batchSize = Self.eventBatch
            } catch let error as BoothError {
                if error.isItemFault {
                    if batch.count > 1 {
                        batchSize = 1
                        continue
                    }
                    if let only = batch.first {
                        log?("Booth: dropped an event the server refused (\(error.summary))")
                        remove(event: only)
                    }
                    continue
                }
                fail(&eventLane, error, label: "event upload")
                return
            } catch {
                fail(&eventLane, .network(error.localizedDescription), label: "event upload")
                return
            }
        }
    }

    private func flushOrders(_ now: Date) async {
        guard let api, !orderLane.running, now >= orderLane.next, !orders.isEmpty else { return }
        orderLane.running = true
        defer { orderLane.running = false }
        var batchSize = Self.orderBatch
        var skipped: Set<String> = []
        var stuck: BoothError?
        while true {
            let batch = Array(orders.filter { !skipped.contains($0.id) }.prefix(batchSize))
            if batch.isEmpty { break }
            do {
                let response: BoothBatchResponse = try await api.post("/v1/orders", ["orders": batch.map { $0.stored.order }])
                var progressed = false
                for result in response.results {
                    guard let queued = batch.first(where: { $0.id == result.id }) else { continue }
                    progressed = true
                    if result.status == "rejected" {
                        log?("Booth: server rejected order #\(queued.stored.order.orderNumber): \(result.error?.message ?? "no reason"); kept in the outbox rejected folder")
                        remove(orderID: queued.id, rejected: true)
                    } else {
                        remove(orderID: queued.id, rejected: false)
                    }
                }
                guard progressed else { throw BoothError.badResponse("no results") }
                orderLane.failures = 0
                orderLane.lastFailure = nil
                batchSize = Self.orderBatch
            } catch let error as BoothError {
                if error.isItemFault {
                    if batch.count > 1 {
                        batchSize = 1
                        continue
                    }
                    if let only = batch.first { skipped.insert(only.id) }
                    stuck = error
                    continue
                }
                fail(&orderLane, error, label: "order upload")
                return
            } catch {
                fail(&orderLane, .network(error.localizedDescription), label: "order upload")
                return
            }
        }
        if let stuck { fail(&orderLane, stuck, label: "order upload") }
    }

    private func fail(_ lane: inout Lane, _ error: BoothError, label: String) {
        lane.failures += 1
        lane.next = Date().addingTimeInterval(error.nextDelay(failures: lane.failures, cap: 60))
        if lane.lastFailure != error.summary {
            lane.lastFailure = error.summary
            log?("Booth: \(label) failed: \(error.summary)")
        }
    }
}
