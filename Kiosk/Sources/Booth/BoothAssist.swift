import Foundation

enum AssistDestination: String, Sendable {
    case builder, summary, name
}

struct AssistCommand: Decodable, Equatable, Sendable {
    enum Op: Equatable, Sendable {
        case addScoop(item: String, flavor: Flavor)
        case removeScoop(item: String, flavor: Flavor)
        case setVessel(item: String, vessel: Vessel)
        case setTopping(item: String, topping: Topping, on: Bool)
        case addItem
        case removeItem(item: String)
        case setName(String)
        case navigate(AssistDestination)
        case startOver
        case unsupported(String)
    }

    let id: String
    let by: String?
    let op: Op
    let stream: String?
    let seq: Int?
    let base: Int?
    let after: [String]
    let ref: UUID?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = c.lenient(AnyKey("id"), "")
        by = c.lenientOptional(AnyKey("by"))
        let streamName: String? = c.lenientOptional(AnyKey("stream"))
        stream = streamName?.isEmpty == false ? streamName : nil
        seq = (c.lenientOptional(AnyKey("seq")) as Int?).flatMap { $0 > 0 ? $0 : nil }
        base = (c.lenientOptional(AnyKey("base")) as Int?).flatMap { $0 >= 0 ? $0 : nil }
        after = c.lenient(AnyKey("after"), [String]())
        ref = (c.lenientOptional(AnyKey("ref")) as String?).flatMap(UUID.init(uuidString:))
        let name: String = c.lenient(AnyKey("op"), "")
        let item: String = c.lenient(AnyKey("item"), "")
        let flavor = Flavor(rawValue: c.lenient(AnyKey("flavor"), ""))
        let vessel = Vessel(rawValue: c.lenient(AnyKey("vessel"), ""))
        let topping = Topping(rawValue: c.lenient(AnyKey("topping"), ""))
        switch name {
        case "addScoop": op = flavor.map { .addScoop(item: item, flavor: $0) } ?? .unsupported("This kiosk doesn't have that flavor")
        case "removeScoop": op = flavor.map { .removeScoop(item: item, flavor: $0) } ?? .unsupported("This kiosk doesn't have that flavor")
        case "setVessel": op = vessel.map { .setVessel(item: item, vessel: $0) } ?? .unsupported("Unknown cup or cone")
        case "setTopping":
            op = topping.map { .setTopping(item: item, topping: $0, on: c.lenient(AnyKey("on"), true)) }
                ?? .unsupported("This kiosk doesn't have that topping")
        case "addItem": op = .addItem
        case "removeItem": op = .removeItem(item: item)
        case "setName": op = .setName(c.lenient(AnyKey("name"), ""))
        case "navigate":
            op = AssistDestination(rawValue: c.lenient(AnyKey("to"), "")).map { .navigate($0) } ?? .unsupported("Unknown screen")
        case "startOver": op = .startOver
        default: op = .unsupported("This kiosk's app doesn't know \(name.isEmpty ? "that command" : name)")
        }
    }
}

extension AssistCommand.Op {
    var pace: TimeInterval {
        switch self {
        case .addScoop: 0.7
        case .removeScoop: 0.5
        case .setVessel: 0.8
        case .setTopping(_, _, let on): on ? 1.0 : 0.5
        case .addItem: 0.9
        case .removeItem: 0.7
        case .navigate: 0.8
        case .setName: 0.3
        case .startOver: 0.6
        case .unsupported: 0
        }
    }
}

protocol AssistQueueItem {
    var id: String { get }
    var stream: String? { get }
    var seq: Int? { get }
    var base: Int? { get }
    var after: [String] { get }
}

extension AssistCommand: AssistQueueItem {}

struct AssistQueue<Item: AssistQueueItem> {
    enum Arrival {
        case queued
        case ignored
        case answered(AssistSession.Result)
    }

    private struct StreamState {
        var received = 0
        var done = 0
        var held: [Int: Item] = [:]
        var gapSince: Date?
        var touched: Date
    }

    static var gapTimeout: TimeInterval { 6 }
    static var tooLate: String { "That change arrived too late, so the kiosk skipped it" }
    static var skipped: String { "Skipped because an earlier change didn't go through" }

    private(set) var ready: [Item] = []
    private var runningItem: Item?
    private var streams: [String: StreamState] = [:]
    private var handled: [String: AssistSession.Result] = [:]
    private var handledOrder: [String] = []
    private let remembered: Int
    private let keptStreams: Int

    init(remembered: Int = 500, keptStreams: Int = 8) {
        self.remembered = remembered
        self.keptStreams = keptStreams
    }

    var running: String? { runningItem?.id }

    var isIdle: Bool { running == nil && ready.isEmpty && streams.values.allSatisfy(\.held.isEmpty) }

    mutating func receive(_ item: Item, now: Date) -> Arrival {
        let id = item.id
        guard !id.isEmpty else { return .ignored }
        if let done = handled[id] {
            return .answered(AssistSession.Result(id: id, status: done.status == "applied" ? "duplicate" : done.status, message: done.message))
        }
        if id == running || ready.contains(where: { $0.id == id }) { return .ignored }
        guard let name = item.stream, let seq = item.seq else {
            ready.append(item)
            return .queued
        }
        var stream = streams[name] ?? StreamState(touched: now)
        stream.touched = now
        defer {
            streams[name] = stream
            forgetOldStreams()
        }
        if stream.held.values.contains(where: { $0.id == id }) { return .ignored }
        if let base = item.base, base > stream.received {
            stream.received = base
            stream.done = max(stream.done, base)
        }
        if seq <= stream.received {
            let result = AssistSession.Result(id: id, status: "rejected", message: Self.tooLate)
            remember(result)
            return .answered(result)
        }
        stream.held[seq] = item
        release(&stream, now: now)
        return .queued
    }

    mutating func releaseGaps(now: Date) {
        for name in Array(streams.keys) {
            guard var stream = streams[name], let since = stream.gapSince, now.timeIntervalSince(since) >= Self.gapTimeout,
                  let first = stream.held.keys.min() else { continue }
            stream.received = first - 1
            release(&stream, now: now)
            streams[name] = stream
        }
    }

    mutating func next() -> Item? {
        guard running == nil, !ready.isEmpty else { return nil }
        let item = ready.removeFirst()
        runningItem = item
        return item
    }

    func blocker(of item: Item) -> String? {
        item.after.first { handled[$0]?.status == "rejected" }
    }

    mutating func finish(_ item: Item, _ result: AssistSession.Result) {
        remember(result)
        if let name = item.stream, let seq = item.seq, var stream = streams[name] {
            stream.done = max(stream.done, seq)
            streams[name] = stream
        }
        if running == item.id { runningItem = nil }
    }

    var streamStates: [AssistSession.Stream] {
        streams.sorted { $0.value.touched > $1.value.touched }.prefix(keptStreams).map { name, stream in
            let waiting = stream.held.count + ready.filter { $0.stream == name }.count + (runningItem?.stream == name ? 1 : 0)
            return AssistSession.Stream(id: name, received: stream.received, done: stream.done, waiting: waiting)
        }
    }

    private mutating func release(_ stream: inout StreamState, now: Date) {
        while let next = stream.held.keys.min(), next <= stream.received + 1 {
            ready.append(stream.held.removeValue(forKey: next)!)
            stream.received = max(stream.received, next)
        }
        stream.gapSince = stream.held.isEmpty ? nil : (stream.gapSince ?? now)
    }

    private mutating func remember(_ result: AssistSession.Result) {
        if handled[result.id] == nil { handledOrder.append(result.id) }
        handled[result.id] = result
        if handledOrder.count > remembered { handled[handledOrder.removeFirst()] = nil }
    }

    private mutating func forgetOldStreams() {
        guard streams.count > keptStreams * 4 else { return }
        let keep = Set(streams.sorted { $0.value.touched > $1.value.touched }.prefix(keptStreams * 2).map(\.key))
        streams = streams.filter { keep.contains($0.key) || !$0.value.held.isEmpty }
    }
}

struct BoothControl: Decodable, Equatable, Sendable {
    enum Op: Equatable, Sendable {
        case attract
        case reloadCatalog
        case resync
        case unknown(String)

        var name: String {
            switch self {
            case .attract: "attract"
            case .reloadCatalog: "reloadCatalog"
            case .resync: "resync"
            case .unknown(let name): name
            }
        }
    }

    let id: String
    let by: String?
    let op: Op

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = c.lenient(AnyKey("id"), "")
        by = c.lenientOptional(AnyKey("by"))
        let name: String = c.lenient(AnyKey("op"), "")
        switch name {
        case "attract": op = .attract
        case "reloadCatalog": op = .reloadCatalog
        case "resync": op = .resync
        default: op = .unknown(name)
        }
    }
}

struct AssistSession: Encodable, Equatable, Sendable {
    struct Item: Encodable, Equatable, Sendable {
        let id: String
        let vessel: String
        let flavors: [String]
        let toppings: [String]
        let cents: Int
        let current: Bool
        let inOrder: Bool
    }

    struct Result: Encodable, Equatable, Sendable {
        let id: String
        let status: String
        let message: String?
    }

    struct Stream: Encodable, Equatable, Sendable {
        let id: String
        let received: Int
        let done: Int
        let waiting: Int
    }

    var screen: String
    var step: String?
    var editing: Bool
    var items: [Item]
    var customerName: String
    var totalCents: Int
    var donationCents = 0
    var paying: Bool
    var orderingOpen: Bool
    var assisted: Bool
    var maxScoops: Int
    var results: [Result]
    var streams: [Stream] = []
}

struct AssistSessionMessage: Encodable, Sendable {
    let type = "session"
    let session: AssistSession
}
