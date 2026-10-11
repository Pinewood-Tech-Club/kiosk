import Foundation

struct BoothOrder: Codable, Sendable {
    struct Item: Codable, Sendable {
        let vessel: String
        let flavors: [String]
    }

    struct Line: Codable, Sendable {
        let title: String
        let detail: String
        let cents: Int
    }

    let id: String
    let orderNumber: Int
    let squareOrderId: String
    let squarePaymentId: String
    let customerName: String
    let totalCents: Int
    let subtotalCents: Int
    let taxCents: Int
    let card: String
    let simulated: Bool
    let paidAt: String
    let items: [Item]
    let lines: [Line]
    let device: String
    let appVersion: String

    init(receipt: Receipt, quote: OrderQuote) {
        id = UUID().uuidString
        orderNumber = receipt.orderNumber
        squareOrderId = receipt.squareOrderID
        squarePaymentId = receipt.paymentID
        customerName = receipt.customerName
        totalCents = receipt.totalCents
        subtotalCents = receipt.subtotalCents
        taxCents = receipt.taxCents
        card = receipt.cardDescription
        simulated = receipt.isSimulated
        paidAt = BoothTime.string(receipt.date)
        items = quote.lines.map { Item(vessel: $0.item.vessel.rawValue, flavors: $0.item.flavors.map(\.rawValue)) }
        lines = receipt.lines.map { Line(title: $0.title, detail: $0.detail, cents: $0.cents) }
        device = BoothIdentity.installID
        appVersion = BoothIdentity.appVersion
    }
}

@MainActor
final class OrderOutbox {
    private let http: BoothHTTP
    private let fileURL: URL
    private let log: (String) -> Void
    private var pending: [BoothOrder]
    private var draining = false
    private var lastFailure: String?

    init(http: BoothHTTP, log: @escaping (String) -> Void) {
        self.http = http
        self.log = log
        let directory = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appending(path: "booth-orders.json")
        pending = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([BoothOrder].self, from: $0) } ?? []
    }

    var hasPending: Bool { !pending.isEmpty }

    func enqueue(_ order: BoothOrder) {
        pending.append(order)
        save()
        log("Booth: order #\(order.orderNumber) queued for upload")
        Task { await drain() }
    }

    func drain() async {
        guard !draining, !pending.isEmpty else { return }
        draining = true
        defer { draining = false }
        for order in pending {
            guard let body = try? JSONEncoder().encode(order) else { continue }
            let outcome = await http.post("/v1/orders", body: body)
            switch outcome {
            case .ok:
                pending.removeAll { $0.id == order.id }
                save()
                log("Booth: order #\(order.orderNumber) uploaded")
                lastFailure = nil
            case .rejected:
                noteFailure("order #\(order.orderNumber): \(outcome.summary)")
            case .unauthorized, .failed:
                noteFailure(outcome.summary)
                return
            }
        }
    }

    private func noteFailure(_ reason: String) {
        guard lastFailure != reason else { return }
        lastFailure = reason
        log("Booth: order upload failed: \(reason)")
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
