import Foundation

struct SquareAPI {
    struct CreatedOrder: Sendable {
        let id: String
        let totalCents: Int
        let taxCents: Int
        let lines: [Receipt.Line]
        let usedCatalog: Bool
    }

    struct Location: Sendable {
        let name: String
        let businessName: String?
    }

    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let baseURL: URL
    let accessToken: String
    let locationID: String

    func fetchLocation() async throws -> Location {
        let json = try await request("v2/locations/\(locationID)", method: "GET", body: nil)
        guard let location = json["location"] as? [String: Any], let name = location["name"] as? String else {
            throw APIError(message: "Unexpected location response")
        }
        return Location(name: name, businessName: location["business_name"] as? String)
    }

    func fetchCatalog(categoryName: String) async throws -> SquareCatalog {
        var categories: [[String: Any]] = []
        var cursor: String?
        repeat {
            var body: [String: Any] = ["object_types": ["CATEGORY"]]
            if let cursor { body["cursor"] = cursor }
            let json = try await request("v2/catalog/search", method: "POST", body: body)
            categories += json["objects"] as? [[String: Any]] ?? []
            cursor = (json["cursor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        } while cursor != nil

        let wanted = categoryName.trimmingCharacters(in: .whitespaces).lowercased()
        guard let categoryID = categories.first(where: {
            (($0["category_data"] as? [String: Any])?["name"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased() == wanted
        })?["id"] as? String else {
            throw APIError(message: "Catalog category \"\(categoryName)\" not found")
        }

        var items: [[String: Any]] = []
        cursor = nil
        repeat {
            var body: [String: Any] = ["category_ids": [categoryID], "limit": 100]
            if let cursor { body["cursor"] = cursor }
            let json = try await request("v2/catalog/search-catalog-items", method: "POST", body: body)
            items += json["items"] as? [[String: Any]] ?? []
            cursor = (json["cursor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        } while cursor != nil
        return try SquareCatalog.build(categoryName: categoryName, items: items)
    }

    static func catalogLineItems(for quote: OrderQuote, catalog: SquareCatalog) -> [[String: Any]] {
        var lines: [[String: Any]] = []
        for (index, line) in quote.lines.enumerated() {
            let label = "#\(index + 1) \(line.item.vessel.title)"
            for (scoop, flavor) in line.item.flavors.enumerated() {
                let position = scoop + 1
                lines.append([
                    "catalog_object_id": catalog.scoopEntry(atPosition: position).variationID,
                    "quantity": "1",
                    "note": "\(label): \(flavor.title)",
                ])
            }
            if line.item.vessel == .cone {
                lines.append([
                    "catalog_object_id": catalog.waffleCone.variationID,
                    "quantity": "1",
                    "note": "#\(index + 1)",
                ])
            }
            for topping in line.item.toppings {
                lines.append([
                    "catalog_object_id": catalog.topping.variationID,
                    "quantity": "1",
                    "note": "\(label): \(topping.title)",
                ])
            }
        }
        return lines
    }

    /// Auto-applied taxes also reach custom amounts, so the donation blocks every catalog tax at the location.
    static func donationLineItem(cents: Int, blockedTaxIDs: [String]) -> [String: Any] {
        var line: [String: Any] = [
            "name": Donation.lineName,
            "quantity": "1",
            "base_price_money": ["amount": cents, "currency": "USD"],
        ]
        if !blockedTaxIDs.isEmpty {
            line["pricing_blocklists"] = [
                "blocked_taxes": blockedTaxIDs.enumerated().map { ["uid": "donation-tax-\($0.offset)", "tax_catalog_object_id": $0.element] },
            ]
        }
        return line
    }

    func fetchTaxIDs() async throws -> [String] {
        var ids: [String] = []
        var cursor: String?
        repeat {
            var body: [String: Any] = ["object_types": ["TAX"]]
            if let cursor { body["cursor"] = cursor }
            let json = try await request("v2/catalog/search", method: "POST", body: body)
            for object in json["objects"] as? [[String: Any]] ?? [] {
                guard object["type"] as? String == "TAX", let id = object["id"] as? String, object["is_deleted"] as? Bool != true,
                      !(object["absent_at_location_ids"] as? [String] ?? []).contains(locationID),
                      object["present_at_all_locations"] as? Bool == true
                        || (object["present_at_location_ids"] as? [String] ?? []).contains(locationID)
                else { continue }
                ids.append(id)
            }
            cursor = (json["cursor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        } while cursor != nil
        return ids
    }

    static func lineItems(for quote: OrderQuote) -> [[String: Any]] {
        func money(_ cents: Int) -> [String: Any] { ["amount": cents, "currency": "USD"] }
        return quote.lines.map { line in
            let item = line.item
            var modifiers: [[String: Any]] = [[
                "name": item.vessel == .cone ? "Waffle cone" : "Cup",
                "base_price_money": money(line.vesselCents),
            ]]
            var counts: [(Flavor, Int)] = []
            for flavor in item.flavors {
                if let index = counts.firstIndex(where: { $0.0 == flavor }) {
                    counts[index].1 += 1
                } else {
                    counts.append((flavor, 1))
                }
            }
            for (flavor, count) in counts {
                modifiers.append(["name": flavor.title, "quantity": String(count), "base_price_money": money(0)])
            }
            for topping in item.toppings {
                modifiers.append(["name": topping.title, "base_price_money": money(topping.priceCents)])
            }
            return [
                "name": "Ice cream, \(item.scoopCount) scoop\(item.scoopCount == 1 ? "" : "s")",
                "quantity": "1",
                "base_price_money": money(line.scoopShareCents),
                "modifiers": modifiers,
            ]
        }
    }

    func createOrder(quote: OrderQuote, catalog: SquareCatalog? = nil, customerName: String, referenceID: String, sourceName: String,
                     idempotencyKey: String = UUID().uuidString, checkoutID: String? = nil) async throws -> CreatedOrder {
        var lineItems = catalog.map { Self.catalogLineItems(for: quote, catalog: $0) } ?? Self.lineItems(for: quote)
        if quote.donationCents > 0 {
            let taxIDs = (try? await fetchTaxIDs()) ?? []
            lineItems.append(Self.donationLineItem(cents: quote.donationCents, blockedTaxIDs: taxIDs))
        }
        var orderBody: [String: Any] = [
            "location_id": locationID,
            "reference_id": referenceID,
            "ticket_name": customerName,
            "source": ["name": sourceName],
            "pricing_options": ["auto_apply_taxes": true],
            "line_items": lineItems,
            "fulfillments": [[
                "type": "PICKUP",
                "state": "PROPOSED",
                "pickup_details": [
                    "recipient": ["display_name": customerName],
                    "schedule_type": "ASAP",
                    "prep_time_duration": "PT5M",
                ],
            ]],
        ]
        if let checkoutID { orderBody["metadata"] = ["checkout_id": checkoutID] }
        let body: [String: Any] = ["idempotency_key": idempotencyKey, "order": orderBody]

        let json = try await request("v2/orders", method: "POST", body: body)
        guard let order = json["order"] as? [String: Any],
              let id = order["id"] as? String,
              let total = (order["total_money"] as? [String: Any])?["amount"] as? Int
        else {
            throw APIError(message: "Unexpected CreateOrder response: \(json)")
        }
        let tax = (order["total_tax_money"] as? [String: Any])?["amount"] as? Int ?? 0
        let lines = (order["line_items"] as? [[String: Any]] ?? []).map { item -> Receipt.Line in
            func cents(_ key: String) -> Int { (item[key] as? [String: Any])?["amount"] as? Int ?? 0 }
            let modifiers = (item["modifiers"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            return Receipt.Line(
                title: item["name"] as? String ?? "Item",
                detail: item["note"] as? String ?? modifiers.joined(separator: ", "),
                quantity: Int(item["quantity"] as? String ?? "1") ?? 1,
                baseCents: cents("base_price_money"),
                cents: cents("total_money")
            )
        }
        return CreatedOrder(id: id, totalCents: total, taxCents: tax, lines: lines, usedCatalog: catalog != nil)
    }

    private func request(_ path: String, method: String, body: [String: Any]?) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        if let errors = json["errors"] as? [[String: Any]], !errors.isEmpty {
            let message = errors
                .map { "\($0["code"] ?? "ERROR"): \($0["detail"] ?? "")" }
                .joined(separator: "; ")
            throw APIError(message: message)
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw APIError(message: "\(path) returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        return json
    }
}
