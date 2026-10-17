import Foundation

struct CheckoutIdentity: Sendable {
    let id: String
    let receiptToken: String
    let orderRef: String

    static func make(orderNumber: Int) -> CheckoutIdentity {
        CheckoutIdentity(id: UUID().uuidString, receiptToken: ReceiptToken.make(), orderRef: KioskIdentity.orderRef(orderNumber))
    }
}

enum ReceiptToken {
    static func make() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private struct CheckoutRequest: Encodable {
    struct Item: Encodable {
        let vessel: String
        let flavors: [String]
        let toppings: [String]
    }

    let id: String
    let receiptToken: String
    let orderNumber: Int
    let orderRef: String
    let customerName: String
    let sourceName: String
    let locationId: String
    let quotedCents: Int
    let donationCents: Int?
    let items: [Item]
}

private struct CheckoutResponse: Decodable {
    struct Line: Decodable {
        let title: String
        let detail: String
        let quantity: Int
        let baseCents: Int
        let cents: Int
    }

    let id: String
    let status: String
    let squareOrderId: String
    let locationId: String
    let totalCents: Int
    let taxCents: Int
    let donationCents: Int?
    let usedCatalog: Bool
    let catalogError: String?
    let lines: [Line]
}

/// Creates the Square order through the booth backend, which prices the cart itself. Any failure, or no answer within
/// `timeout`, returns nil so the kiosk creates the order on the device instead; after a failure the backend is skipped
/// for a minute so a dead backend costs at most one timeout per minute.
final class BoothCheckoutClient {
    private static let timeout: Duration = .milliseconds(3500)
    private static let skipAfterFailure: TimeInterval = 60

    private let api: BoothAPI
    private let log: (String) -> Void
    private var skipUntil = Date.distantPast

    init(api: BoothAPI, log: @escaping (String) -> Void) {
        self.api = api
        self.log = log
    }

    @MainActor
    func createOrder(quote: OrderQuote, customerName: String, orderNumber: Int, checkout: CheckoutIdentity, locationID: String,
                     sourceName: String) async -> SquareAPI.CreatedOrder? {
        guard Date() >= skipUntil else { return nil }
        let request = Self.request(quote: quote, customerName: customerName, orderNumber: orderNumber, checkout: checkout,
                                   locationID: locationID, sourceName: sourceName)
        let api = api
        let started = Date()
        let outcome: Result<CheckoutResponse, Error>? = await withTaskGroup(of: Result<CheckoutResponse, Error>?.self) { group in
            group.addTask {
                do {
                    let response: CheckoutResponse = try await api.post("/v1/checkout", request)
                    return .success(response)
                } catch {
                    return .failure(error)
                }
            }
            group.addTask {
                try? await Task.sleep(for: Self.timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        switch outcome {
        case .success(let response) where response.locationId == locationID && Self.carriesDonation(response, of: quote):
            log("Booth checkout: order \(response.squareOrderId) \(response.status) in \(elapsed) ms (\(response.usedCatalog ? "catalog" : "ad-hoc: \(response.catalogError ?? "no catalog")"))")
            return response.order
        case .success(let response) where response.locationId == locationID:
            log("Booth checkout: the server left out the \(quote.donationCents.formattedAsUSD) donation; creating the order on the device")
            return nil
        case .success(let response):
            log("Booth checkout: server used location \(response.locationId), not \(locationID); creating the order on the device")
        case .failure(let error):
            log("Booth checkout failed after \(elapsed) ms (\((error as? BoothError)?.summary ?? error.localizedDescription)); creating the order on the device")
        case nil:
            log("Booth checkout: no answer within \(Self.timeout); creating the order on the device")
        }
        skipUntil = Date().addingTimeInterval(Self.skipAfterFailure)
        return nil
    }

    /// Gift cards are charged against the server's own record of the checkout, so unlike `createOrder` there is no
    /// device fallback and no shortcut past a recently failed backend.
    @MainActor
    func createServerOrder(quote: OrderQuote, customerName: String, orderNumber: Int, checkout: CheckoutIdentity,
                           locationID: String, sourceName: String) async throws -> SquareAPI.CreatedOrder {
        let request = Self.request(quote: quote, customerName: customerName, orderNumber: orderNumber, checkout: checkout,
                                   locationID: locationID, sourceName: sourceName)
        let response: CheckoutResponse = try await api.post("/v1/checkout", request)
        guard response.locationId == locationID else {
            throw BoothError.badResponse("server used location \(response.locationId), not \(locationID)")
        }
        guard Self.carriesDonation(response, of: quote) else {
            throw BoothError.badResponse("the server left out the \(quote.donationCents.formattedAsUSD) donation")
        }
        log("Booth checkout: order \(response.squareOrderId) \(response.status) for a gift card payment")
        return response.order
    }

    /// A server from before donations ignores the field and creates the order without it.
    private static func carriesDonation(_ response: CheckoutResponse, of quote: OrderQuote) -> Bool {
        (response.donationCents ?? 0) == quote.donationCents
    }

    private static func request(quote: OrderQuote, customerName: String, orderNumber: Int, checkout: CheckoutIdentity,
                                locationID: String, sourceName: String) -> CheckoutRequest {
        CheckoutRequest(
            id: checkout.id, receiptToken: checkout.receiptToken, orderNumber: orderNumber, orderRef: checkout.orderRef,
            customerName: customerName,
            sourceName: sourceName, locationId: locationID, quotedCents: quote.totalCents,
            donationCents: quote.donationCents > 0 ? quote.donationCents : nil,
            items: quote.lines.map {
                CheckoutRequest.Item(vessel: $0.item.vessel.rawValue, flavors: $0.item.flavors.map(\.rawValue),
                                     toppings: $0.item.toppings.map(\.rawValue))
            }
        )
    }
}

private extension CheckoutResponse {
    var order: SquareAPI.CreatedOrder {
        SquareAPI.CreatedOrder(
            id: squareOrderId, totalCents: totalCents, taxCents: taxCents,
            lines: lines.map {
                Receipt.Line(title: $0.title, detail: $0.detail, quantity: $0.quantity, baseCents: $0.baseCents, cents: $0.cents)
            },
            usedCatalog: usedCatalog
        )
    }
}
