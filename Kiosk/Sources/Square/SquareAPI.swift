import Foundation

struct SquareAPI {
    struct CreatedOrder: Sendable {
        let id: String
        let totalCents: Int
        let taxCents: Int
        let lineTotals: [Int]
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
            return [
                "name": "Ice cream, \(item.scoopCount) scoop\(item.scoopCount == 1 ? "" : "s")",
                "quantity": "1",
                "base_price_money": money(line.scoopShareCents),
                "modifiers": modifiers,
            ]
        }
    }

    func createOrder(quote: OrderQuote, customerName: String, referenceID: String, sourceName: String) async throws -> CreatedOrder {
        let body: [String: Any] = [
            "idempotency_key": UUID().uuidString,
            "order": [
                "location_id": locationID,
                "reference_id": referenceID,
                "ticket_name": customerName,
                "source": ["name": sourceName],
                "pricing_options": ["auto_apply_taxes": true],
                "line_items": Self.lineItems(for: quote),
                "fulfillments": [[
                    "type": "PICKUP",
                    "state": "PROPOSED",
                    "pickup_details": [
                        "recipient": ["display_name": customerName],
                        "schedule_type": "ASAP",
                        "prep_time_duration": "PT5M",
                    ],
                ]],
            ] as [String: Any],
        ]

        let json = try await request("v2/orders", method: "POST", body: body)
        guard let order = json["order"] as? [String: Any],
              let id = order["id"] as? String,
              let total = (order["total_money"] as? [String: Any])?["amount"] as? Int
        else {
            throw APIError(message: "Unexpected CreateOrder response: \(json)")
        }
        let tax = (order["total_tax_money"] as? [String: Any])?["amount"] as? Int ?? 0
        let lines = (order["line_items"] as? [[String: Any]] ?? []).map {
            ($0["total_money"] as? [String: Any])?["amount"] as? Int ?? 0
        }
        return CreatedOrder(id: id, totalCents: total, taxCents: tax, lineTotals: lines)
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
