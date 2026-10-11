import Foundation

enum Vessel: String, CaseIterable, Identifiable, Sendable {
    case cup, cone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cup: "Cup"
        case .cone: "Waffle Cone"
        }
    }

    var priceCents: Int {
        switch self {
        case .cup: 0
        case .cone: Pricing.waffleConeCents
        }
    }

    var priceLabel: String {
        switch self {
        case .cup: "Included"
        case .cone: "+\(Pricing.waffleConeCents.formattedAsUSD)"
        }
    }
}

enum Flavor: String, CaseIterable, Identifiable, Sendable {
    case vanilla, chocolate, cookies

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vanilla: "Vanilla"
        case .chocolate: "Chocolate"
        case .cookies: "Cookies & Cream"
        }
    }
}

enum Topping: String, CaseIterable, Identifiable, Sendable {
    case whip, chocolate, gummies, mms, sprinkles

    var id: String { rawValue }

    var title: String {
        switch self {
        case .whip: "Whipped Cream"
        case .chocolate: "Chocolate Syrup"
        case .gummies: "Gummy Bears"
        case .mms: "M&M's"
        case .sprinkles: "Sprinkles"
        }
    }

    var priceCents: Int { Pricing.toppingCents }

    var group: ToppingGroup {
        switch self {
        case .whip, .chocolate: .creamAndSauces
        case .gummies, .mms, .sprinkles: .candyAndSprinkles
        }
    }
}

enum ToppingGroup: String, CaseIterable, Identifiable, Sendable {
    case creamAndSauces, candyAndSprinkles

    var id: String { rawValue }

    var title: String {
        switch self {
        case .creamAndSauces: "Cream & Sauces"
        case .candyAndSprinkles: "Candy & Sprinkles"
        }
    }

    var toppings: [Topping] { Topping.allCases.filter { $0.group == self } }
}

struct IceCreamItem: Identifiable, Equatable, Sendable {
    let id: UUID
    var vessel: Vessel
    var flavors: [Flavor]
    /// In the order they were added: pieces scattered later land on top of earlier ones.
    var toppings: [Topping]

    init(id: UUID = UUID(), vessel: Vessel = .cup, flavors: [Flavor] = [], toppings: [Topping] = []) {
        self.id = id
        self.vessel = vessel
        self.flavors = flavors
        self.toppings = toppings
    }

    var scoopCount: Int { flavors.count }

    var toppingSummary: String {
        Topping.allCases.filter(toppings.contains).map(\.title).formatted(.list(type: .and))
    }

    var title: String {
        "\(vessel.title) · \(scoopCount) scoop\(scoopCount == 1 ? "" : "s")"
    }

    var hasChoices: Bool { !flavors.isEmpty || vessel != .cup || !toppings.isEmpty }

    var flavorSummary: String {
        Self.describe(flavors)
    }

    static func describe(_ flavors: [Flavor]) -> String {
        var counts: [(Flavor, Int)] = []
        for flavor in flavors {
            if let index = counts.firstIndex(where: { $0.0 == flavor }) {
                counts[index].1 += 1
            } else {
                counts.append((flavor, 1))
            }
        }
        return counts.map { $0.1 > 1 ? "\($0.0.title) ×\($0.1)" : $0.0.title }.joined(separator: ", ")
    }
}

enum Pricing {
    static let maxScoopsPerItem = 3
    static let waffleConeCents = 150
    static let toppingCents = 50

    /// Scoops are billed by their position in the whole order (one Square catalog line per scoop):
    /// the order's 1st scoop is $4, the 2nd $3, every later one $2.
    static func scoopCents(atPosition position: Int) -> Int {
        switch position {
        case ...0: 0
        case 1: 400
        case 2: 300
        default: 200
        }
    }

    static func scoopsTotal(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        return (1...count).reduce(0) { $0 + scoopCents(atPosition: $1) }
    }

    static func quote(_ items: [IceCreamItem]) -> OrderQuote {
        var position = 0
        let lines = items.map { item in
            let scoops = item.flavors.indices.reduce(0) { total, _ in
                position += 1
                return total + scoopCents(atPosition: position)
            }
            return OrderQuote.Line(item: item, scoopShareCents: scoops, vesselCents: item.vessel.priceCents,
                                   toppingCents: item.toppings.count * Pricing.toppingCents)
        }
        return OrderQuote(lines: lines, scoopCount: position, scoopsTotalCents: scoopsTotal(position))
    }
}

struct OrderQuote: Sendable {
    struct Line: Identifiable, Sendable {
        let item: IceCreamItem
        /// What this item's scoops cost given their positions in the order.
        let scoopShareCents: Int
        let vesselCents: Int
        let toppingCents: Int

        var id: UUID { item.id }
        var totalCents: Int { scoopShareCents + vesselCents + toppingCents }
    }

    let lines: [Line]
    let scoopCount: Int
    let scoopsTotalCents: Int

    var coneCount: Int { lines.filter { $0.item.vessel == .cone }.count }
    var conesTotalCents: Int { lines.reduce(0) { $0 + $1.vesselCents } }
    var toppingCount: Int { lines.reduce(0) { $0 + $1.item.toppings.count } }
    var toppingsTotalCents: Int { lines.reduce(0) { $0 + $1.toppingCents } }
    var totalCents: Int { scoopsTotalCents + conesTotalCents + toppingsTotalCents }
    var isEmpty: Bool { lines.isEmpty }
}

extension Int {
    var formattedAsUSD: String {
        (Double(self) / 100).formatted(.currency(code: "USD"))
    }
}
