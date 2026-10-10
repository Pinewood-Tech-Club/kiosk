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

struct IceCreamItem: Identifiable, Equatable, Sendable {
    let id: UUID
    var vessel: Vessel
    var flavors: [Flavor]

    init(id: UUID = UUID(), vessel: Vessel = .cup, flavors: [Flavor] = []) {
        self.id = id
        self.vessel = vessel
        self.flavors = flavors
    }

    var scoopCount: Int { flavors.count }

    var title: String {
        "\(vessel.title) · \(scoopCount) scoop\(scoopCount == 1 ? "" : "s")"
    }

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

    static let tierTable: [(scoops: Int, cents: Int)] = [(1, 400), (2, 700), (3, 900)]
    static let additionalScoopCents = 200

    static func scoopsTotal(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        if let tier = tierTable.first(where: { $0.scoops == count }) { return tier.cents }
        let top = tierTable[tierTable.count - 1]
        return top.cents + (count - top.scoops) * additionalScoopCents
    }

    static func quote(_ items: [IceCreamItem]) -> OrderQuote {
        let scoopCount = items.reduce(0) { $0 + $1.scoopCount }
        let scoopsTotal = scoopsTotal(scoopCount)
        let shares = allocate(scoopsTotal, weights: items.map(\.scoopCount))
        let lines = zip(items, shares).map { item, share in
            OrderQuote.Line(item: item, scoopShareCents: share, vesselCents: item.vessel.priceCents)
        }
        return OrderQuote(lines: lines, scoopCount: scoopCount, scoopsTotalCents: scoopsTotal)
    }

    /// Splits `total` proportionally to `weights` with largest-remainder rounding, so the parts always sum to `total`.
    static func allocate(_ total: Int, weights: [Int]) -> [Int] {
        let weightSum = weights.reduce(0, +)
        guard weightSum > 0 else { return weights.map { _ in 0 } }
        var parts = weights.map { total * $0 / weightSum }
        let remainders = weights.enumerated().map { ($0.offset, (total * $0.element) % weightSum) }
        var leftover = total - parts.reduce(0, +)
        for (index, _) in remainders.sorted(by: { $0.1 > $1.1 || ($0.1 == $1.1 && $0.0 < $1.0) }) where leftover > 0 {
            parts[index] += 1
            leftover -= 1
        }
        return parts
    }
}

struct OrderQuote: Sendable {
    struct Line: Identifiable, Sendable {
        let item: IceCreamItem
        let scoopShareCents: Int
        let vesselCents: Int

        var id: UUID { item.id }
        var totalCents: Int { scoopShareCents + vesselCents }
    }

    let lines: [Line]
    let scoopCount: Int
    let scoopsTotalCents: Int

    var coneCount: Int { lines.filter { $0.item.vessel == .cone }.count }
    var conesTotalCents: Int { lines.reduce(0) { $0 + $1.vesselCents } }
    var totalCents: Int { scoopsTotalCents + conesTotalCents }
    var isEmpty: Bool { lines.isEmpty }
}

extension Int {
    var formattedAsUSD: String {
        (Double(self) / 100).formatted(.currency(code: "USD"))
    }
}
