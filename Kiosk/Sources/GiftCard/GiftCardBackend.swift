import Foundation

struct GiftCardBalance: Decodable, Equatable, Sendable {
    let last4: String
    let balanceCents: Int
    let state: String

    var isActive: Bool { state == "ACTIVE" }
}

struct GiftCardCharge: Decodable, Equatable, Sendable {
    let paymentId: String
    let approvedCents: Int
    let remainingCents: Int
    let last4: String
}

enum GiftCardFailure: Error, Equatable {
    case notFound
    case inactive
    case empty
    case rateLimited
    case amountMismatch
    case unavailable(String)

    /// Maps the booth server's error codes for the gift card and checkout routes.
    init(_ error: Error) {
        guard let booth = error as? BoothError else {
            self = error as? GiftCardFailure ?? .unavailable(error.localizedDescription)
            return
        }
        switch booth {
        case .http(_, "invalid_gan", _, _), .http(_, "giftcard_not_found", _, _): self = .notFound
        case .http(_, "giftcard_inactive", _, _): self = .inactive
        case .http(_, "giftcard_empty", _, _): self = .empty
        case .http(_, "rate_limited", _, _), .http(429, _, _, _): self = .rateLimited
        case .http(_, "amount_mismatch", _, _): self = .amountMismatch
        default: self = .unavailable(booth.summary)
        }
    }

    var isRetryable: Bool {
        guard case .unavailable = self else { return false }
        return true
    }
}

@MainActor
protocol GiftCardBackend: AnyObject {
    var isSimulated: Bool { get }
    func createCheckout(quote: OrderQuote, customerName: String, orderNumber: Int, checkout: CheckoutIdentity) async throws -> SquareAPI.CreatedOrder
    func lookup(gan: String) async throws -> GiftCardBalance
    func charge(checkoutID: String, gan: String, idempotencyKey: String) async throws -> GiftCardCharge
    func complete(checkoutID: String, paymentIDs: [String], idempotencyKey: String) async throws
    func cancel(checkoutID: String, paymentIDs: [String]) async throws
}

private struct LookupRequest: Encodable { let gan: String }
private struct ChargeRequest: Encodable { let checkoutId: String; let gan: String; let idempotencyKey: String }
private struct CompleteRequest: Encodable { let checkoutId: String; let paymentIds: [String]; let idempotencyKey: String }
private struct CompleteResponse: Decodable { let status: String }
private struct CancelRequest: Encodable { let checkoutId: String; let paymentIds: [String]? }
private struct CancelResponse: Decodable { let canceled: [String] }

@MainActor
final class BoothGiftCards: GiftCardBackend {
    private let api: BoothAPI
    private let square: SquareService

    init(api: BoothAPI, square: SquareService) {
        self.api = api
        self.square = square
    }

    var isSimulated: Bool { false }

    func createCheckout(quote: OrderQuote, customerName: String, orderNumber: Int, checkout: CheckoutIdentity) async throws -> SquareAPI.CreatedOrder {
        try await square.createServerOrder(quote: quote, customerName: customerName, orderNumber: orderNumber, checkout: checkout)
    }

    func lookup(gan: String) async throws -> GiftCardBalance {
        try await api.post("/v1/giftcards/lookup", LookupRequest(gan: gan))
    }

    func charge(checkoutID: String, gan: String, idempotencyKey: String) async throws -> GiftCardCharge {
        try await api.post("/v1/giftcards/charge", ChargeRequest(checkoutId: checkoutID, gan: gan, idempotencyKey: idempotencyKey))
    }

    func complete(checkoutID: String, paymentIDs: [String], idempotencyKey: String) async throws {
        let response: CompleteResponse = try await api.post(
            "/v1/checkout/complete", CompleteRequest(checkoutId: checkoutID, paymentIds: paymentIDs, idempotencyKey: idempotencyKey))
        guard response.status == "completed" else { throw BoothError.badResponse("status \(response.status)") }
    }

    func cancel(checkoutID: String, paymentIDs: [String]) async throws {
        let _: CancelResponse = try await api.post(
            "/v1/checkout/cancel", CancelRequest(checkoutId: checkoutID, paymentIds: paymentIDs.isEmpty ? nil : paymentIDs))
    }
}

/// Stands in for the booth server while payments are simulated, so the whole gift card flow runs on a simulator.
/// The last four digits pick the outcome.
@MainActor
final class SimulatedGiftCards: GiftCardBackend {
    enum Ending: String {
        case empty = "0000"
        case partial = "1111"
        case notFound = "4040"
        case rateLimited = "4290"
        case completeFails = "5000"
        case inactive = "8888"
    }

    static let partialBalanceCents = 200
    static let fullBalanceCents = 5000

    private var held: [String: Int] = [:]
    private var totals: [String: Int] = [:]
    private(set) var completed: [[String]] = []
    private(set) var canceled: [[String]] = []

    var isSimulated: Bool { true }

    private func pause() async { try? await Task.sleep(for: .milliseconds(500)) }

    func createCheckout(quote: OrderQuote, customerName: String, orderNumber: Int, checkout: CheckoutIdentity) async throws -> SquareAPI.CreatedOrder {
        await pause()
        totals[checkout.id] = quote.totalCents
        return SquareAPI.CreatedOrder(id: "SIM-ORDER-\(orderNumber)", totalCents: quote.totalCents, taxCents: 0,
                                      lines: Receipt.chargedLines(for: quote), usedCatalog: false)
    }

    func lookup(gan: String) async throws -> GiftCardBalance {
        await pause()
        guard let digits = GiftCardNumber.parse(gan) else { throw GiftCardFailure.notFound }
        let last4 = GiftCardNumber.last4(digits)
        switch Ending(rawValue: last4) {
        case .notFound: throw GiftCardFailure.notFound
        case .rateLimited: throw GiftCardFailure.rateLimited
        case .empty: return GiftCardBalance(last4: last4, balanceCents: 0, state: "ACTIVE")
        case .inactive: return GiftCardBalance(last4: last4, balanceCents: Self.fullBalanceCents, state: "DEACTIVATED")
        case .partial: return GiftCardBalance(last4: last4, balanceCents: Self.partialBalanceCents, state: "ACTIVE")
        default: return GiftCardBalance(last4: last4, balanceCents: Self.fullBalanceCents, state: "ACTIVE")
        }
    }

    func charge(checkoutID: String, gan: String, idempotencyKey: String) async throws -> GiftCardCharge {
        let balance = try await lookup(gan: gan)
        guard balance.isActive else { throw GiftCardFailure.inactive }
        guard balance.balanceCents > 0 else { throw GiftCardFailure.empty }
        let total = totals[checkoutID] ?? 0
        let approved = min(balance.balanceCents, total)
        held[checkoutID] = approved
        return GiftCardCharge(paymentId: "SIM-GIFT-\(balance.last4)", approvedCents: approved, remainingCents: total - approved,
                              last4: balance.last4)
    }

    func complete(checkoutID: String, paymentIDs: [String], idempotencyKey: String) async throws {
        await pause()
        if paymentIDs.contains(where: { $0.hasSuffix(Ending.completeFails.rawValue) }) {
            throw GiftCardFailure.unavailable("simulated complete failure")
        }
        completed.append(paymentIDs)
    }

    func cancel(checkoutID: String, paymentIDs: [String]) async throws {
        await pause()
        held[checkoutID] = nil
        canceled.append(paymentIDs)
    }
}
