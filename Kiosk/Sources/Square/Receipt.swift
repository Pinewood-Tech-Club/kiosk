import Foundation

struct Receipt: Sendable {
    struct Line: Identifiable, Sendable {
        let id = UUID()
        let title: String
        let detail: String
        let cents: Int
    }

    let merchantName: String
    let eventName: String
    let date: Date
    let orderNumber: Int
    let customerName: String
    let squareOrderID: String
    let paymentID: String
    let cardDescription: String
    let lines: [Line]
    let subtotalCents: Int
    let taxCents: Int
    let totalCents: Int
    let isSimulated: Bool

    static func lines(for quote: OrderQuote) -> [Line] {
        quote.lines.map { line in
            var detail = line.item.flavorSummary
            if line.item.vessel == .cone {
                detail += " · cone +\(line.vesselCents.formattedAsUSD)"
            }
            return Line(title: line.item.title, detail: detail, cents: line.totalCents)
        }
    }

    static func simulated(quote: OrderQuote, customerName: String, orderNumber: Int, merchantName: String) -> Receipt {
        func randomID(_ length: Int) -> String {
            let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
            return String((0..<length).map { _ in alphabet.randomElement()! })
        }
        return Receipt(merchantName: merchantName, eventName: Config.eventName, date: Date(), orderNumber: orderNumber,
                       customerName: customerName, squareOrderID: "SIM-" + randomID(22), paymentID: "SIM-" + randomID(22),
                       cardDescription: "Visa •••• 1111", lines: lines(for: quote), subtotalCents: quote.totalCents,
                       taxCents: 0, totalCents: quote.totalCents, isSimulated: true)
    }
}
