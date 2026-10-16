import Foundation

struct GiftCardTender: Equatable, Sendable {
    let paymentID: String
    let cents: Int
    let last4: String
}

struct Receipt: Sendable {
    struct Line: Identifiable, Sendable {
        let id = UUID()
        let title: String
        let detail: String
        let quantity: Int
        let baseCents: Int
        let cents: Int
    }

    let merchantName: String
    let eventName: String
    let date: Date
    let orderNumber: Int
    let orderRef: String
    let customerName: String
    let squareOrderID: String
    let paymentID: String
    let cardDescription: String
    let lines: [Line]
    let subtotalCents: Int
    let taxCents: Int
    let totalCents: Int
    let isSimulated: Bool
    let checkoutID: String
    let receiptToken: String
    var giftCard: GiftCardTender? = nil

    var cardCents: Int { totalCents - (giftCard?.cents ?? 0) }

    var receiptURL: URL? {
        BoothConfig.publicBaseURL?.appending(path: "r/\(receiptToken)")
    }

    var displayLines: [(title: String, detail: String, amountCents: Int)] {
        lines.map { ($0.title, $0.detail, $0.cents) }
    }

    static func chargedLines(for quote: OrderQuote) -> [Line] {
        var lines: [Line] = []
        for (index, line) in quote.lines.enumerated() {
            let label = "#\(index + 1) \(line.item.vessel.title)"
            for (scoop, flavor) in line.item.flavors.enumerated() {
                let position = scoop + 1
                let cents = Pricing.scoopCents(atPosition: position)
                lines.append(Line(title: scoopName(position), detail: "\(label): \(flavor.title)", quantity: 1, baseCents: cents, cents: cents))
            }
            if line.item.vessel == .cone {
                lines.append(Line(title: "Waffle Cone", detail: "#\(index + 1)", quantity: 1, baseCents: line.vesselCents, cents: line.vesselCents))
            }
            for topping in line.item.toppings {
                lines.append(Line(title: "Ice Cream Toppings", detail: "\(label): \(topping.title)", quantity: 1,
                                  baseCents: topping.priceCents, cents: topping.priceCents))
            }
        }
        return lines
    }

    private static func scoopName(_ position: Int) -> String {
        switch position {
        case 1: "Ice Cream (First Scoop)"
        case 2: "Ice Cream (Second Scoop)"
        default: "Ice Cream (Third Scoop)"
        }
    }

    static func simulated(quote: OrderQuote, customerName: String, orderNumber: Int, merchantName: String,
                          checkout: CheckoutIdentity? = nil) -> Receipt {
        let checkout = checkout ?? .make(orderNumber: orderNumber)
        func randomID(_ length: Int) -> String {
            let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
            return String((0..<length).map { _ in alphabet.randomElement()! })
        }
        return Receipt(merchantName: merchantName, eventName: Config.eventName, date: Date(), orderNumber: orderNumber,
                       orderRef: checkout.orderRef, customerName: customerName, squareOrderID: "SIM-" + randomID(22), paymentID: "SIM-" + randomID(22),
                       cardDescription: "Visa •••• 1111", lines: chargedLines(for: quote), subtotalCents: quote.totalCents,
                       taxCents: 0, totalCents: quote.totalCents, isSimulated: true, checkoutID: checkout.id,
                       receiptToken: checkout.receiptToken)
    }
}
