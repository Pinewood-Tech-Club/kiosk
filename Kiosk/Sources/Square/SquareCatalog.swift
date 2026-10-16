import Foundation

struct SquareCatalog: Sendable {
    struct Entry: Sendable {
        let variationID: String
        let itemName: String
        let cents: Int
    }

    let categoryName: String
    let firstScoop: Entry
    let secondScoop: Entry
    let additionalScoop: Entry
    let waffleCone: Entry
    let topping: Entry

    var entries: [Entry] { [firstScoop, secondScoop, additionalScoop, waffleCone, topping] }

    static let requiredNames = ["Ice Cream (First Scoop)", "Ice Cream (Second Scoop)", "Ice Cream (Third Scoop)", "Waffle Cone", "Ice Cream Toppings"]

    func scoopEntry(atPosition position: Int) -> Entry {
        switch position {
        case 1: firstScoop
        case 2: secondScoop
        default: additionalScoop
        }
    }

    func scoopsTotal(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        return (1...count).reduce(0) { $0 + scoopEntry(atPosition: $1).cents }
    }

    /// Nil when the catalog prices reproduce the kiosk's pricing rules; otherwise a description of the mismatch.
    var pricingMismatch: String? {
        for count in 1...(Pricing.maxScoopsPerItem * 4) where scoopsTotal(count) != Pricing.scoopsTotal(count) {
            return "\(count) scoops: catalog \(scoopsTotal(count).formattedAsUSD) vs kiosk \(Pricing.scoopsTotal(count).formattedAsUSD)"
        }
        if waffleCone.cents != Pricing.waffleConeCents {
            return "Waffle Cone: catalog \(waffleCone.cents.formattedAsUSD) vs kiosk \(Pricing.waffleConeCents.formattedAsUSD)"
        }
        if topping.cents != Pricing.toppingCents {
            return "Topping: catalog \(topping.cents.formattedAsUSD) vs kiosk \(Pricing.toppingCents.formattedAsUSD)"
        }
        return nil
    }

    static func build(categoryName: String, items: [[String: Any]]) throws -> SquareCatalog {
        var byName: [String: Entry] = [:]
        for object in items {
            guard let data = object["item_data"] as? [String: Any],
                  let name = data["name"] as? String,
                  data["is_archived"] as? Bool != true,
                  let variations = data["variations"] as? [[String: Any]]
            else { continue }
            let sellable = variations.compactMap { variation -> Entry? in
                guard let id = variation["id"] as? String,
                      let vData = variation["item_variation_data"] as? [String: Any],
                      vData["pricing_type"] as? String == "FIXED_PRICING",
                      vData["sellable"] as? Bool != false,
                      let cents = (vData["price_money"] as? [String: Any])?["amount"] as? Int
                else { return nil }
                return Entry(variationID: id, itemName: name, cents: cents)
            }
            if sellable.count == 1 {
                byName[name.lowercased()] = sellable[0]
            } else if sellable.count > 1 {
                throw SquareAPI.APIError(message: "Catalog item \"\(name)\" has \(sellable.count) sellable variations; expected exactly one")
            }
        }
        let missing = requiredNames.filter { byName[$0.lowercased()] == nil }
        guard missing.isEmpty else {
            throw SquareAPI.APIError(message: "Category \"\(categoryName)\" is missing item(s): \(missing.joined(separator: ", "))")
        }
        return SquareCatalog(
            categoryName: categoryName,
            firstScoop: byName["ice cream (first scoop)"]!,
            secondScoop: byName["ice cream (second scoop)"]!,
            additionalScoop: byName["ice cream (third scoop)"]!,
            waffleCone: byName["waffle cone"]!,
            topping: byName["ice cream toppings"]!
        )
    }
}
