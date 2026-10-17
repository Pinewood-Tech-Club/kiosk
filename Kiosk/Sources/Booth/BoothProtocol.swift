import Foundation

extension KeyedDecodingContainer {
    func lenient<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }

    func lenientOptional<T: Decodable>(_ key: Key) -> T? {
        try? decodeIfPresent(T.self, forKey: key)
    }
}

enum BoothEpoch {
    static let key = "boothEpoch"

    static var known: Int? { UserDefaults.standard.object(forKey: key) as? Int }
}

struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

struct BoothFlavorState: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var soldOut: Bool

    init(id: String, name: String, soldOut: Bool) {
        self.id = id
        self.name = name
        self.soldOut = soldOut
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = c.lenient(AnyKey("id"), "")
        name = c.lenient(AnyKey("name"), "")
        soldOut = c.lenient(AnyKey("soldOut"), false)
    }
}

struct BoothSupplyState: Codable, Equatable, Sendable {
    var kind: String
    var id: String
    var name: String
    var soldOut: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        kind = c.lenient(AnyKey("kind"), "")
        id = c.lenient(AnyKey("id"), "")
        name = c.lenient(AnyKey("name"), "")
        soldOut = c.lenient(AnyKey("soldOut"), false)
    }
}

struct BoothAlert: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var key: String
    var kind: String
    var severity: String
    var title: String
    var detail: String
    var count: Int
    var createdAt: Double
    var updatedAt: Double
    var ackedAt: Double?
    var ackedBy: String?
    var resolvedAt: Double?

    var isOpen: Bool { ackedAt == nil && resolvedAt == nil }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = c.lenient(AnyKey("id"), "")
        key = c.lenient(AnyKey("key"), "")
        kind = c.lenient(AnyKey("kind"), "")
        severity = c.lenient(AnyKey("severity"), "info")
        title = c.lenient(AnyKey("title"), "")
        detail = c.lenient(AnyKey("detail"), "")
        count = c.lenient(AnyKey("count"), 1)
        createdAt = c.lenient(AnyKey("createdAt"), 0)
        updatedAt = c.lenient(AnyKey("updatedAt"), 0)
        ackedAt = c.lenientOptional(AnyKey("ackedAt"))
        ackedBy = c.lenientOptional(AnyKey("ackedBy"))
        resolvedAt = c.lenientOptional(AnyKey("resolvedAt"))
    }
}

struct KioskHealth: Codable, Equatable, Sendable {
    struct Reader: Codable, Equatable, Sendable {
        var name: String
        var model: String?
        var state: String
        var batteryPercent: Int?
        var isCharging: Bool?

        init(name: String, model: String?, state: String, batteryPercent: Int?, isCharging: Bool?) {
            self.name = name
            self.model = model
            self.state = state
            self.batteryPercent = batteryPercent
            self.isCharging = isCharging
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            name = c.lenient(AnyKey("name"), "")
            model = c.lenientOptional(AnyKey("model"))
            state = c.lenient(AnyKey("state"), "unknown")
            batteryPercent = c.lenientOptional(AnyKey("batteryPercent"))
            isCharging = c.lenientOptional(AnyKey("isCharging"))
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: AnyKey.self)
            try c.encode(name, forKey: AnyKey("name"))
            try c.encodeIfPresent(model, forKey: AnyKey("model"))
            try c.encode(state, forKey: AnyKey("state"))
            try c.encode(batteryPercent, forKey: AnyKey("batteryPercent"))
            try c.encode(isCharging, forKey: AnyKey("isCharging"))
        }
    }

    struct Catalog: Codable, Equatable, Sendable {
        var ok: Bool
        var status: String
        var error: String?

        init(ok: Bool, status: String, error: String?) {
            self.ok = ok
            self.status = status
            self.error = error
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            ok = c.lenient(AnyKey("ok"), true)
            status = c.lenient(AnyKey("status"), "")
            error = c.lenientOptional(AnyKey("error"))
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: AnyKey.self)
            try c.encode(ok, forKey: AnyKey("ok"))
            try c.encode(status, forKey: AnyKey("status"))
            try c.encode(error, forKey: AnyKey("error"))
        }
    }

    struct Battery: Codable, Equatable, Sendable {
        var percent: Int
        var charging: Bool

        init(percent: Int, charging: Bool) {
            self.percent = percent
            self.charging = charging
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            percent = c.lenient(AnyKey("percent"), 0)
            charging = c.lenient(AnyKey("charging"), false)
        }
    }

    struct FlavorInfo: Codable, Equatable, Sendable {
        var id: String
        var name: String

        init(id: String, name: String) {
            self.id = id
            self.name = name
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            id = c.lenient(AnyKey("id"), "")
            name = c.lenient(AnyKey("name"), "")
        }
    }

    var appVersion: String
    var environment: String
    var authorized: Bool
    var authorizationState: String
    var readers: [Reader]
    var readerReady: Bool
    var catalog: Catalog
    var deviceBattery: Battery?
    var simulatePayment: Bool
    var screen: String
    var lastError: String?
    var lastErrorAt: String?
    struct OutboxCounts: Codable, Equatable, Sendable {
        var orders: Int
        var events: Int

        init(orders: Int, events: Int) {
            self.orders = orders
            self.events = events
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            orders = c.lenient(AnyKey("orders"), 0)
            events = c.lenient(AnyKey("events"), 0)
        }
    }

    var flavors: [FlavorInfo]?
    var kioskName: String?
    var epoch: Int?
    var outbox: OutboxCounts?

    init(appVersion: String, environment: String, authorized: Bool, authorizationState: String, readers: [Reader],
         readerReady: Bool, catalog: Catalog, deviceBattery: Battery?, simulatePayment: Bool, screen: String,
         lastError: String?, lastErrorAt: String?, flavors: [FlavorInfo]?, kioskName: String?,
         epoch: Int? = nil, outbox: OutboxCounts? = nil) {
        self.appVersion = appVersion
        self.environment = environment
        self.authorized = authorized
        self.authorizationState = authorizationState
        self.readers = readers
        self.readerReady = readerReady
        self.catalog = catalog
        self.deviceBattery = deviceBattery
        self.simulatePayment = simulatePayment
        self.screen = screen
        self.lastError = lastError
        self.lastErrorAt = lastErrorAt
        self.flavors = flavors
        self.kioskName = kioskName
        self.epoch = epoch
        self.outbox = outbox
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        appVersion = c.lenient(AnyKey("appVersion"), "")
        environment = c.lenient(AnyKey("environment"), "")
        authorized = c.lenient(AnyKey("authorized"), false)
        authorizationState = c.lenient(AnyKey("authorizationState"), "")
        readers = c.lenient(AnyKey("readers"), [])
        readerReady = c.lenient(AnyKey("readerReady"), false)
        catalog = c.lenient(AnyKey("catalog"), Catalog(ok: true, status: "", error: nil))
        deviceBattery = c.lenientOptional(AnyKey("deviceBattery"))
        simulatePayment = c.lenient(AnyKey("simulatePayment"), false)
        screen = c.lenient(AnyKey("screen"), "")
        lastError = c.lenientOptional(AnyKey("lastError"))
        lastErrorAt = c.lenientOptional(AnyKey("lastErrorAt"))
        flavors = c.lenientOptional(AnyKey("flavors"))
        kioskName = c.lenientOptional(AnyKey("kioskName"))
        epoch = c.lenientOptional(AnyKey("epoch"))
        outbox = c.lenientOptional(AnyKey("outbox"))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(appVersion, forKey: AnyKey("appVersion"))
        try c.encode(environment, forKey: AnyKey("environment"))
        try c.encode(authorized, forKey: AnyKey("authorized"))
        try c.encode(authorizationState, forKey: AnyKey("authorizationState"))
        try c.encode(readers, forKey: AnyKey("readers"))
        try c.encode(readerReady, forKey: AnyKey("readerReady"))
        try c.encode(catalog, forKey: AnyKey("catalog"))
        try c.encode(deviceBattery, forKey: AnyKey("deviceBattery"))
        try c.encode(simulatePayment, forKey: AnyKey("simulatePayment"))
        try c.encode(screen, forKey: AnyKey("screen"))
        try c.encode(lastError, forKey: AnyKey("lastError"))
        try c.encode(lastErrorAt, forKey: AnyKey("lastErrorAt"))
        try c.encodeIfPresent(flavors, forKey: AnyKey("flavors"))
        try c.encodeIfPresent(kioskName, forKey: AnyKey("kioskName"))
        try c.encodeIfPresent(epoch, forKey: AnyKey("epoch"))
        try c.encodeIfPresent(outbox, forKey: AnyKey("outbox"))
    }
}

struct KioskState: Codable, Equatable, Sendable {
    var connected = false
    var online = false
    var lastSeenAt: Double?
    var screen: String?
    var health: KioskHealth?
    var healthAt: Double?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        connected = c.lenient(AnyKey("connected"), false)
        online = c.lenient(AnyKey("online"), false)
        lastSeenAt = c.lenientOptional(AnyKey("lastSeenAt"))
        screen = c.lenientOptional(AnyKey("screen"))
        health = c.lenientOptional(AnyKey("health"))
        healthAt = c.lenientOptional(AnyKey("healthAt"))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(connected, forKey: AnyKey("connected"))
        try c.encode(online, forKey: AnyKey("online"))
        try c.encode(lastSeenAt, forKey: AnyKey("lastSeenAt"))
        try c.encode(screen, forKey: AnyKey("screen"))
        try c.encode(health, forKey: AnyKey("health"))
        try c.encode(healthAt, forKey: AnyKey("healthAt"))
    }
}

struct KioskEntry: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var tag: String
    var open: Bool
    var debug: Bool
    var online: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = c.lenient(AnyKey("id"), "")
        name = c.lenient(AnyKey("name"), "")
        tag = c.lenient(AnyKey("tag"), "")
        open = c.lenient(AnyKey("open"), true)
        debug = c.lenient(AnyKey("debug"), false)
        online = c.lenient(AnyKey("online"), false)
    }
}

struct BoothOrderSummary: Codable, Equatable, Identifiable, Sendable {
    struct Item: Codable, Equatable, Sendable {
        var vessel: String
        var flavors: [String]
        var toppings: [String]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            vessel = c.lenient(AnyKey("vessel"), "cup")
            flavors = c.lenient(AnyKey("flavors"), [])
            toppings = c.lenient(AnyKey("toppings"), [])
        }
    }

    var id: String
    var orderNumber: Int?
    var customerName: String?
    var items: [Item]
    var totalCents: Int
    var simulated: Bool
    var paidAt: Double
    var receivedAt: Double
    var status: String
    var statusAt: Double
    var statusBy: String?

    var isOpen: Bool { ["paid", "preparing", "ready"].contains(status) }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = c.lenient(AnyKey("id"), "")
        orderNumber = c.lenientOptional(AnyKey("orderNumber"))
        customerName = c.lenientOptional(AnyKey("customerName"))
        items = c.lenient(AnyKey("items"), [])
        totalCents = c.lenient(AnyKey("totalCents"), 0)
        simulated = c.lenient(AnyKey("simulated"), false)
        paidAt = c.lenient(AnyKey("paidAt"), 0)
        receivedAt = c.lenient(AnyKey("receivedAt"), 0)
        status = c.lenient(AnyKey("status"), "paid")
        statusAt = c.lenient(AnyKey("statusAt"), 0)
        statusBy = c.lenientOptional(AnyKey("statusBy"))
    }
}

struct KioskOpenState: Codable, Equatable, Sendable {
    var open = true
    var changedAt: Double?
    var changedBy: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        open = c.lenient(AnyKey("open"), true)
        changedAt = c.lenientOptional(AnyKey("changedAt"))
        changedBy = c.lenientOptional(AnyKey("changedBy"))
    }
}

struct BoothState: Codable, Equatable, Sendable {
    var rev: Int
    var flavors: [BoothFlavorState]
    var supplies: [BoothSupplyState]?
    var kiosk: KioskState
    var kioskOpen: KioskOpenState
    var kiosks: [KioskEntry]?
    var alerts: [BoothAlert]
    var orders: [BoothOrderSummary]
    var serverTime: Double
    var epoch: Int?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        rev = c.lenient(AnyKey("rev"), 0)
        epoch = c.lenientOptional(AnyKey("epoch"))
        kiosks = c.lenientOptional(AnyKey("kiosks"))
        flavors = c.lenient(AnyKey("flavors"), [])
        supplies = c.lenientOptional(AnyKey("supplies"))
        kiosk = c.lenient(AnyKey("kiosk"), KioskState())
        kioskOpen = c.lenient(AnyKey("kioskOpen"), KioskOpenState())
        alerts = c.lenient(AnyKey("alerts"), [])
        orders = c.lenient(AnyKey("orders"), [])
        serverTime = c.lenient(AnyKey("serverTime"), 0)
    }
}

enum BoothChange: Sendable {
    case flavors([BoothFlavorState])
    case supplies([BoothSupplyState])
    case alert(BoothAlert)
    case kiosk(KioskState)
    case order(BoothOrderSummary)
    case kioskOpen(KioskOpenState)
    case kiosks([KioskEntry])
    case unknown
}

extension BoothChange: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        switch c.lenient(AnyKey("kind"), "") {
        case "flavors":
            self = c.lenientOptional(AnyKey("flavors")).map(BoothChange.flavors) ?? .unknown
        case "supplies":
            self = c.lenientOptional(AnyKey("supplies")).map(BoothChange.supplies) ?? .unknown
        case "alert":
            self = c.lenientOptional(AnyKey("alert")).map(BoothChange.alert) ?? .unknown
        case "kiosk":
            self = c.lenientOptional(AnyKey("kiosk")).map(BoothChange.kiosk) ?? .unknown
        case "order":
            self = c.lenientOptional(AnyKey("order")).map(BoothChange.order) ?? .unknown
        case "kioskOpen":
            self = c.lenientOptional(AnyKey("kioskOpen")).map(BoothChange.kioskOpen) ?? .unknown
        case "kiosks":
            self = c.lenientOptional(AnyKey("kiosks")).map(BoothChange.kiosks) ?? .unknown
        default:
            self = .unknown
        }
    }
}

struct BoothErrorBody: Codable, Equatable, Sendable {
    var code: String
    var message: String
    var retryable: Bool?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        code = c.lenient(AnyKey("code"), "")
        message = c.lenient(AnyKey("message"), "")
        retryable = c.lenientOptional(AnyKey("retryable"))
    }
}

struct BoothErrorEnvelope: Decodable, Sendable {
    var error: BoothErrorBody?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        error = c.lenientOptional(AnyKey("error"))
    }
}

struct BoothResult: Decodable, Equatable, Sendable {
    var id: String
    var status: String
    var alertId: String?
    var error: BoothErrorBody?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = c.lenient(AnyKey("id"), "")
        status = c.lenient(AnyKey("status"), "")
        alertId = c.lenientOptional(AnyKey("alertId"))
        error = c.lenientOptional(AnyKey("error"))
    }
}

struct BoothBatchResponse: Decodable, Sendable {
    var results: [BoothResult]
    var rev: Int?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        results = c.lenient(AnyKey("results"), [])
        rev = c.lenientOptional(AnyKey("rev"))
    }
}

struct BoothLogsResponse: Decodable, Sendable {
    var accepted: Int
    var stored: Int
    var duplicates: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        accepted = c.lenient(AnyKey("accepted"), 0)
        stored = c.lenient(AnyKey("stored"), 0)
        duplicates = c.lenient(AnyKey("duplicates"), 0)
    }
}

enum BoothServerMessage: Sendable {
    case snapshot(BoothState)
    case patch(rev: Int, change: BoothChange)
    case pong(rev: Int?)
    case result(BoothResult)
    case error(BoothErrorBody)
    case assist(active: Bool, expiresIn: Double)
    case command(AssistCommand)
    case control(BoothControl)
    case unknown
}

extension BoothServerMessage: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        switch c.lenient(AnyKey("type"), "") {
        case "snapshot":
            self = c.lenientOptional(AnyKey("state")).map(BoothServerMessage.snapshot) ?? .unknown
        case "patch":
            guard let rev: Int = c.lenientOptional(AnyKey("rev")) else {
                self = .unknown
                return
            }
            self = .patch(rev: rev, change: c.lenient(AnyKey("change"), BoothChange.unknown))
        case "pong":
            self = .pong(rev: c.lenientOptional(AnyKey("rev")))
        case "result":
            self = c.lenientOptional(AnyKey("result")).map(BoothServerMessage.result) ?? .result(Self.inlineResult(c))
        case "error":
            self = c.lenientOptional(AnyKey("error")).map(BoothServerMessage.error) ?? .unknown
        case "assist":
            self = .assist(active: c.lenient(AnyKey("active"), false), expiresIn: c.lenient(AnyKey("expiresIn"), 30_000) / 1000)
        case "command":
            self = c.lenientOptional(AnyKey("command")).map(BoothServerMessage.command) ?? .unknown
        case "control":
            self = c.lenientOptional(AnyKey("control")).map(BoothServerMessage.control) ?? .unknown
        default:
            self = .unknown
        }
    }

    private static func inlineResult(_ c: KeyedDecodingContainer<AnyKey>) -> BoothResult {
        BoothResult(
            id: c.lenient(AnyKey("id"), ""),
            status: c.lenient(AnyKey("status"), ""),
            alertId: c.lenientOptional(AnyKey("alertId")),
            error: c.lenientOptional(AnyKey("error"))
        )
    }
}

extension BoothResult {
    init(id: String, status: String, alertId: String?, error: BoothErrorBody?) {
        self.id = id
        self.status = status
        self.alertId = alertId
        self.error = error
    }
}

struct BoothEvent: Codable, Equatable, Sendable {
    var id: String
    var seq: Int
    var type: String
    var at: String
    var reason: String?
    var message: String?
    var health: KioskHealth?
    var epoch: Int?
}

struct BoothAction: Codable, Equatable, Sendable {
    var id: String
    var type: String
    var alertId: String?
    var flavor: String?
    var soldOut: Bool?
    var orderId: String?
    var status: String?
    var by: String
}

struct BoothOrder: Codable, Equatable, Sendable {
    struct Item: Codable, Equatable, Sendable {
        let vessel: String
        let flavors: [String]
        let toppings: [String]?
    }

    struct Line: Codable, Equatable, Sendable {
        let title: String
        let detail: String
        let cents: Int
    }

    let id: String
    let orderNumber: Int
    let orderRef: String?
    let squareOrderId: String
    let squarePaymentId: String
    let customerName: String
    let totalCents: Int
    let subtotalCents: Int
    let taxCents: Int
    let card: String
    let simulated: Bool
    let paidAt: String
    let appVersion: String
    let receiptToken: String?
    let items: [Item]
    let lines: [Line]
    let giftCardPaymentId: String?
    let giftCardCents: Int?
    let giftCardLast4: String?
    let donationCents: Int?
    var epoch: Int?

    init(receipt: Receipt, quote: OrderQuote) {
        id = receipt.checkoutID
        orderNumber = receipt.orderNumber
        orderRef = receipt.orderRef
        squareOrderId = receipt.squareOrderID
        squarePaymentId = receipt.paymentID
        customerName = receipt.customerName
        totalCents = receipt.totalCents
        subtotalCents = receipt.subtotalCents
        taxCents = receipt.taxCents
        card = receipt.cardDescription.replacingOccurrences(of: "\u{2022}", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        simulated = receipt.isSimulated
        paidAt = receipt.date.formatted(Date.ISO8601FormatStyle())
        appVersion = BoothIdentity.appVersion
        receiptToken = receipt.receiptToken
        items = quote.lines.map {
            Item(vessel: $0.item.vessel.rawValue, flavors: $0.item.flavors.map(\.rawValue), toppings: $0.item.toppings.map(\.rawValue))
        }
        lines = receipt.lines.map { Line(title: $0.title, detail: $0.detail, cents: $0.cents) }
        giftCardPaymentId = receipt.giftCard?.paymentID
        giftCardCents = receipt.giftCard?.cents
        giftCardLast4 = receipt.giftCard?.last4
        donationCents = receipt.donationCents > 0 ? receipt.donationCents : nil
    }
}
