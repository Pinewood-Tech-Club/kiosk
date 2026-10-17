import XCTest
@testable import Kiosk

@MainActor
private final class StubBackend: GiftCardBackend {
    var orderTotal = 650
    var balance = GiftCardBalance(last4: "5678", balanceCents: 5000, state: "ACTIVE")
    var lookupError: Error?
    var chargeApproved: Int?
    var chargeError: Error?
    var completeErrors: [Error] = []
    var createError: Error?
    private(set) var created: [(checkoutID: String, quote: OrderQuote)] = []
    private(set) var charges: [String] = []
    private(set) var chargedCheckouts: [String] = []
    private(set) var completed: [[String]] = []
    private(set) var completeKeys: [String] = []
    private(set) var canceled: [[String]] = []

    var isSimulated: Bool { false }

    func createCheckout(quote: OrderQuote, customerName: String, orderNumber: Int, checkout: CheckoutIdentity) async throws -> SquareAPI.CreatedOrder {
        if !created.isEmpty, let createError { throw createError }
        created.append((checkout.id, quote))
        return SquareAPI.CreatedOrder(id: "ORDER-\(created.count)", totalCents: totalCents(checkout.id), taxCents: 50,
                                      lines: Receipt.chargedLines(for: quote), usedCatalog: true)
    }

    private func totalCents(_ checkoutID: String) -> Int {
        orderTotal + (created.first { $0.checkoutID == checkoutID }?.quote.donationCents ?? 0)
    }

    func lookup(gan: String) async throws -> GiftCardBalance {
        if let lookupError { throw lookupError }
        return balance
    }

    func charge(checkoutID: String, gan: String, idempotencyKey: String) async throws -> GiftCardCharge {
        charges.append(gan)
        if let chargeError { throw chargeError }
        let total = totalCents(checkoutID)
        let approved = chargeApproved ?? min(balance.balanceCents, total)
        chargedCheckouts.append(checkoutID)
        return GiftCardCharge(paymentId: "GIFT", approvedCents: approved, remainingCents: total - approved, last4: balance.last4)
    }

    func complete(checkoutID: String, paymentIDs: [String], idempotencyKey: String) async throws {
        completeKeys.append(idempotencyKey)
        if !completeErrors.isEmpty { throw completeErrors.removeFirst() }
        completed.append(paymentIDs)
    }

    func cancel(checkoutID: String, paymentIDs: [String]) async throws {
        canceled.append(paymentIDs)
    }
}

@MainActor
final class GiftCardCheckoutTests: XCTestCase {
    private var backend: StubBackend!
    private var readerResult: ReaderChargeResult = .approved(paymentID: "CARD", cardDescription: "Visa •••• 4242")
    private var readerAmounts: [Int] = []
    private var outcome: GiftCardCheckout.Outcome?

    private static let number = "7783320012345678"

    override func setUp() async throws {
        backend = StubBackend()
        setUpOutcome()
    }

    private func setUpOutcome() {
        readerAmounts = []
        outcome = nil
    }

    private func makeCheckout() -> GiftCardCheckout {
        let checkout = GiftCardCheckout(
            quote: Pricing.quote([IceCreamItem(vessel: .cup, flavors: [.vanilla])]), customerName: "Alex", orderNumber: 7,
            checkout: .make(orderNumber: 7), backend: backend, merchantName: "Booth", appliedPause: .zero,
            retryDelays: [.zero, .zero], log: { _ in },
            reader: { [unowned self] amount, _, _ in
                readerAmounts.append(amount)
                return readerResult
            }
        )
        checkout.onFinish = { [unowned self] in outcome = $0 }
        return checkout
    }

    private func wait(_ description: String, until condition: () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for \(description)")
    }

    private func waitForOutcome() async {
        await wait("an outcome") { outcome != nil }
    }

    private func notice() -> AppModel.Notice? {
        guard case .left(let notice, _) = outcome else { return nil }
        return notice
    }

    private func receipt() -> Receipt? {
        guard case .paid(let receipt) = outcome else { return nil }
        return receipt
    }

    // MARK: Numbers

    func testParsesSquareGiftCardCodes() {
        XCTAssertEqual(GiftCardNumber.parse("sqgc://7783320012345678"), Self.number)
        XCTAssertEqual(GiftCardNumber.parse("SQGC://7783320012345678\n"), Self.number)
        XCTAssertEqual(GiftCardNumber.parse("7783 3200 1234 5678"), Self.number)
        XCTAssertEqual(GiftCardNumber.parse("7783-3200-1234-5678"), Self.number)
        XCTAssertNil(GiftCardNumber.parse("778332001234567"))
        XCTAssertNil(GiftCardNumber.parse("77833200123456789"))
        XCTAssertNil(GiftCardNumber.parse("https://example.com"))
        XCTAssertNil(GiftCardNumber.parse("٧٧٨٣٣٢٠٠١٢٣٤٥٦٧٨"))
        XCTAssertEqual(GiftCardNumber.grouped(Self.number), "7783 3200 1234 5678")
        XCTAssertEqual(GiftCardNumber.grouped("778332"), "7783 32")
    }

    func testMapsServerErrorCodes() {
        func failure(_ status: Int, _ code: String) -> GiftCardFailure {
            GiftCardFailure(BoothError.http(status: status, code: code, message: "", retryAfter: nil))
        }
        XCTAssertEqual(failure(400, "invalid_gan"), .notFound)
        XCTAssertEqual(failure(404, "giftcard_not_found"), .notFound)
        XCTAssertEqual(failure(429, "rate_limited"), .rateLimited)
        XCTAssertEqual(failure(409, "giftcard_inactive"), .inactive)
        XCTAssertEqual(failure(409, "giftcard_empty"), .empty)
        XCTAssertEqual(failure(409, "amount_mismatch"), .amountMismatch)
        XCTAssertFalse(failure(409, "amount_mismatch").isRetryable)
        XCTAssertTrue(failure(503, "unavailable").isRetryable)
        XCTAssertTrue(GiftCardFailure(BoothError.network("offline")).isRetryable)
    }

    // MARK: Entry

    func testManualEntryTakesSixteenDigits() {
        let checkout = makeCheckout()
        checkout.enterManually()
        XCTAssertEqual(checkout.step, .manual)
        for digit in Array(repeating: 4, count: 20) { checkout.type(digit) }
        XCTAssertEqual(checkout.digits.count, 16)
        XCTAssertTrue(checkout.canSubmitDigits)
        checkout.deleteDigit()
        XCTAssertFalse(checkout.canSubmitDigits)
        checkout.back()
        XCTAssertEqual(checkout.step, .scan)
    }

    func testIgnoresOtherBarcodes() {
        let checkout = makeCheckout()
        XCTAssertFalse(checkout.scanned("012345678905"))
        XCTAssertEqual(checkout.step, .scan)
        XCTAssertTrue(checkout.scanned("sqgc://" + Self.number))
        XCTAssertEqual(checkout.step, .checking)
    }

    func testWithoutACameraBackLeavesForName() {
        let checkout = makeCheckout()
        checkout.cameraUnavailable()
        XCTAssertEqual(checkout.step, .manual)
        checkout.back()
        guard case .backToName = outcome else { return XCTFail("expected backToName, got \(String(describing: outcome))") }
    }

    // MARK: Gift card only

    func testPaysInFullWithTheGiftCard() async {
        let checkout = makeCheckout()
        checkout.scanned(Self.number)
        await wait("full confirmation") { checkout.step == .confirmFull(totalCents: 650, balanceCents: 5000, last4: "5678") }
        checkout.confirm()
        await waitForOutcome()
        XCTAssertEqual(backend.completed, [["GIFT"]])
        XCTAssertTrue(readerAmounts.isEmpty)
        let receipt = receipt()
        XCTAssertEqual(receipt?.paymentID, "GIFT")
        XCTAssertEqual(receipt?.cardDescription, "Gift card •••• 5678")
        XCTAssertEqual(receipt?.giftCard, GiftCardTender(paymentID: "GIFT", cents: 650, last4: "5678"))
        XCTAssertEqual(receipt?.totalCents, 650)
        XCTAssertEqual(receipt?.subtotalCents, 600)
        XCTAssertEqual(receipt?.cardCents, 0)
    }

    // MARK: Leftover donation

    func testOffersALeftoverUnderTenDollarsAndDonatesIt() async {
        backend.balance = GiftCardBalance(last4: "5678", balanceCents: 1000, state: "ACTIVE")
        let checkout = makeCheckout()
        let original = checkout.checkout
        checkout.scanned(Self.number)
        await wait("full confirmation") { checkout.step == .confirmFull(totalCents: 650, balanceCents: 1000, last4: "5678") }
        checkout.confirm()
        XCTAssertEqual(checkout.leftoverOffer, 350)
        XCTAssertTrue(backend.charges.isEmpty)
        checkout.donateLeftover()
        XCTAssertNil(checkout.leftoverOffer)
        await waitForOutcome()
        XCTAssertEqual(backend.created.map(\.quote.donationCents), [0, 350])
        XCTAssertNotEqual(checkout.checkout.id, original.id)
        XCTAssertNotEqual(checkout.checkout.receiptToken, original.receiptToken)
        XCTAssertEqual(checkout.checkout.orderRef, original.orderRef)
        XCTAssertEqual(backend.chargedCheckouts, [checkout.checkout.id])
        XCTAssertEqual(checkout.quote.donationCents, 350)
        let receipt = receipt()
        XCTAssertEqual(receipt?.totalCents, 1000)
        XCTAssertEqual(receipt?.giftCard?.cents, 1000)
        XCTAssertEqual(receipt?.donationCents, 350)
        XCTAssertEqual(receipt?.checkoutID, checkout.checkout.id)
        XCTAssertEqual(receipt?.receiptToken, checkout.checkout.receiptToken)
    }

    func testDecliningTheLeftoverChargesTheOrderAsIs() async {
        backend.balance = GiftCardBalance(last4: "5678", balanceCents: 1000, state: "ACTIVE")
        let checkout = makeCheckout()
        let original = checkout.checkout
        checkout.scanned(Self.number)
        await wait("full confirmation") { if case .confirmFull = checkout.step { true } else { false } }
        checkout.confirm()
        XCTAssertEqual(checkout.leftoverOffer, 350)
        checkout.declineLeftover()
        await waitForOutcome()
        XCTAssertEqual(backend.created.count, 1)
        XCTAssertEqual(backend.chargedCheckouts, [original.id])
        XCTAssertEqual(receipt()?.totalCents, 650)
        XCTAssertEqual(receipt()?.donationCents, 0)
    }

    func testNoOfferForTenDollarsLeftOrAnEmptiedCard() async {
        for balance in [1650, 650] {
            setUpOutcome()
            backend = StubBackend()
            backend.balance = GiftCardBalance(last4: "5678", balanceCents: balance, state: "ACTIVE")
            let checkout = makeCheckout()
            checkout.scanned(Self.number)
            await wait("full confirmation") { if case .confirmFull = checkout.step { true } else { false } }
            checkout.confirm()
            XCTAssertNil(checkout.leftoverOffer)
            await waitForOutcome()
            XCTAssertEqual(receipt()?.totalCents, 650)
        }
    }

    func testNoOfferWhenTheCardOnlyCoversPart() async {
        backend.balance = GiftCardBalance(last4: "5678", balanceCents: 200, state: "ACTIVE")
        let checkout = makeCheckout()
        checkout.scanned(Self.number)
        await wait("split confirmation") { if case .confirmSplit = checkout.step { true } else { false } }
        checkout.confirm()
        XCTAssertNil(checkout.leftoverOffer)
        await waitForOutcome()
        XCTAssertEqual(readerAmounts, [450])
    }

    func testFailedDonationCheckoutShowsAProblemAndKeepsTheOrder() async {
        backend.balance = GiftCardBalance(last4: "5678", balanceCents: 1000, state: "ACTIVE")
        backend.createError = GiftCardFailure.unavailable("down")
        let checkout = makeCheckout()
        let original = checkout.checkout
        checkout.scanned(Self.number)
        await wait("full confirmation") { if case .confirmFull = checkout.step { true } else { false } }
        checkout.confirm()
        checkout.donateLeftover()
        await wait("problem") { checkout.step == .problem(.unavailable) }
        XCTAssertTrue(backend.charges.isEmpty)
        XCTAssertEqual(checkout.checkout.id, original.id)
        XCTAssertEqual(checkout.quote.donationCents, 0)
        checkout.tryAnother()
        backend.createError = nil
        checkout.scanned(Self.number)
        await wait("full confirmation again") { if case .confirmFull = checkout.step { true } else { false } }
        checkout.confirm()
        XCTAssertEqual(checkout.leftoverOffer, 350)
    }

    func testCancelAtConfirmationLeavesWithoutCharging() async {
        let checkout = makeCheckout()
        checkout.scanned(Self.number)
        await wait("full confirmation") { if case .confirmFull = checkout.step { true } else { false } }
        checkout.leave()
        await waitForOutcome()
        XCTAssertNil(notice())
        XCTAssertTrue(backend.charges.isEmpty)
        XCTAssertTrue(backend.canceled.isEmpty)
    }

    func testBalanceThatDroppedBeforeTheChargeAsksAgain() async {
        let checkout = makeCheckout()
        backend.chargeApproved = 400
        checkout.scanned(Self.number)
        await wait("full confirmation") { if case .confirmFull = checkout.step { true } else { false } }
        checkout.confirm()
        await wait("split confirmation") { checkout.step == .confirmSplit(balanceCents: 400, remainingCents: 250, last4: "5678") }
        checkout.leave()
        await waitForOutcome()
        XCTAssertEqual(backend.canceled, [["GIFT"]])
        XCTAssertEqual(notice()?.title, GiftCardCheckout.wasNotCharged)
    }

    // MARK: Split

    func testSplitsWithTheReader() async {
        backend.balance = GiftCardBalance(last4: "5678", balanceCents: 200, state: "ACTIVE")
        let checkout = makeCheckout()
        checkout.scanned(Self.number)
        await wait("split confirmation") { checkout.step == .confirmSplit(balanceCents: 200, remainingCents: 450, last4: "5678") }
        checkout.confirm()
        await waitForOutcome()
        XCTAssertEqual(readerAmounts, [450])
        XCTAssertEqual(backend.completed, [["GIFT", "CARD"]])
        let receipt = receipt()
        XCTAssertEqual(receipt?.paymentID, "CARD")
        XCTAssertEqual(receipt?.cardDescription, "Visa •••• 4242 + Gift card •••• 5678")
        XCTAssertEqual(receipt?.giftCard?.cents, 200)
        XCTAssertEqual(receipt?.cardCents, 450)
        XCTAssertEqual(receipt.map { BoothOrder(receipt: $0, quote: Pricing.quote([])) }?.card, "Visa 4242 + Gift card 5678")
    }

    func testCanceledReaderReleasesTheGiftCard() async {
        backend.balance = GiftCardBalance(last4: "5678", balanceCents: 200, state: "ACTIVE")
        readerResult = .canceled
        let checkout = makeCheckout()
        checkout.scanned(Self.number)
        await wait("split confirmation") { if case .confirmSplit = checkout.step { true } else { false } }
        checkout.confirm()
        await waitForOutcome()
        XCTAssertEqual(backend.canceled, [["GIFT"]])
        XCTAssertTrue(backend.completed.isEmpty)
        XCTAssertEqual(notice()?.title, GiftCardCheckout.wasNotCharged)
    }

    func testFailedReaderCancelsItsPaymentToo() async {
        backend.balance = GiftCardBalance(last4: "5678", balanceCents: 200, state: "ACTIVE")
        readerResult = .failed(.timedOut, paymentID: "CARD-FAILED")
        let checkout = makeCheckout()
        checkout.scanned(Self.number)
        await wait("split confirmation") { if case .confirmSplit = checkout.step { true } else { false } }
        checkout.confirm()
        await waitForOutcome()
        XCTAssertEqual(backend.canceled, [["GIFT", "CARD-FAILED"]])
        XCTAssertEqual(notice()?.message.contains(GiftCardCheckout.wasNotCharged), true)
    }

    // MARK: Completing

    func testRetriesCompleteWithTheSameKey() async {
        backend.completeErrors = [BoothError.network("offline"), BoothError.http(status: 503, code: "unavailable", message: "", retryAfter: nil)]
        let checkout = makeCheckout()
        checkout.scanned(Self.number)
        await wait("full confirmation") { if case .confirmFull = checkout.step { true } else { false } }
        checkout.confirm()
        await waitForOutcome()
        XCTAssertNotNil(receipt())
        XCTAssertEqual(backend.completeKeys.count, 3)
        XCTAssertEqual(Set(backend.completeKeys).count, 1)
    }

    func testCompleteThatKeepsFailingCancelsEveryPayment() async {
        backend.balance = GiftCardBalance(last4: "5678", balanceCents: 200, state: "ACTIVE")
        backend.completeErrors = Array(repeating: BoothError.network("offline"), count: 3)
        let checkout = makeCheckout()
        checkout.scanned(Self.number)
        await wait("split confirmation") { if case .confirmSplit = checkout.step { true } else { false } }
        checkout.confirm()
        await waitForOutcome()
        XCTAssertNil(receipt())
        XCTAssertEqual(backend.canceled, [["GIFT", "CARD"]])
        XCTAssertEqual(notice()?.title, "Payment didn't go through")
    }

    func testAmountMismatchIsNotRetried() async {
        backend.completeErrors = [BoothError.http(status: 409, code: "amount_mismatch", message: "", retryAfter: nil)]
        let checkout = makeCheckout()
        checkout.scanned(Self.number)
        await wait("full confirmation") { if case .confirmFull = checkout.step { true } else { false } }
        checkout.confirm()
        await waitForOutcome()
        XCTAssertEqual(backend.completeKeys.count, 1)
        XCTAssertEqual(backend.canceled, [["GIFT"]])
    }

    // MARK: Problems

    private func problem(after configure: () -> Void) async -> GiftCardCheckout.Step {
        configure()
        let checkout = makeCheckout()
        checkout.scanned(Self.number)
        await wait("a problem") { if case .problem = checkout.step { true } else { false } }
        return checkout.step
    }

    func testProblems() async {
        let notFound = await problem { backend.lookupError = BoothError.http(status: 404, code: "giftcard_not_found", message: "", retryAfter: nil) }
        XCTAssertEqual(notFound, .problem(.notFound))
        let limited = await problem { backend.lookupError = BoothError.http(status: 429, code: "rate_limited", message: "", retryAfter: 300) }
        XCTAssertEqual(limited, .problem(.rateLimited))
        let down = await problem { backend.lookupError = BoothError.network("offline") }
        XCTAssertEqual(down, .problem(.unavailable))
        let empty = await problem {
            backend.lookupError = nil
            backend.balance = GiftCardBalance(last4: "5678", balanceCents: 0, state: "ACTIVE")
        }
        XCTAssertEqual(empty, .problem(.empty))
        let inactive = await problem { backend.balance = GiftCardBalance(last4: "5678", balanceCents: 900, state: "DEACTIVATED") }
        XCTAssertEqual(inactive, .problem(.inactive))
    }

    func testTryAnotherCardReusesTheCheckout() async {
        backend.balance = GiftCardBalance(last4: "5678", balanceCents: 0, state: "ACTIVE")
        let checkout = makeCheckout()
        checkout.scanned(Self.number)
        await wait("empty card") { checkout.step == .problem(.empty) }
        checkout.tryAnother()
        XCTAssertEqual(checkout.step, .scan)
        backend.balance = GiftCardBalance(last4: "9999", balanceCents: 5000, state: "ACTIVE")
        checkout.scanned("7783320012349999")
        await wait("full confirmation") { checkout.step == .confirmFull(totalCents: 650, balanceCents: 5000, last4: "9999") }
    }
}
