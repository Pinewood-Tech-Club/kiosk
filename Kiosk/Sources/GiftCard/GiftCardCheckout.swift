import Foundation
import Observation

enum ReaderChargeResult: Sendable {
    case approved(paymentID: String, cardDescription: String)
    case failed(PaymentProblem, paymentID: String?)
    case canceled
}

/// One customer's attempt to pay with a gift card, from scanning the number to a completed Square order.
///
/// The gift card is only ever held (an APPROVED payment); nothing is captured until `/v1/checkout/complete` succeeds,
/// and every way out before that cancels the holds, so a customer who walks away is never charged.
@Observable
@MainActor
final class GiftCardCheckout {
    enum Step: Equatable {
        case scan
        case manual
        case checking
        case confirmFull(totalCents: Int, balanceCents: Int, last4: String)
        case confirmSplit(balanceCents: Int, remainingCents: Int, last4: String)
        case charging
        case applied(giftCents: Int, remainingCents: Int)
        case readerPayment(remainingCents: Int)
        case completing
        case problem(Problem)
    }

    enum Problem: Equatable {
        case empty
        case inactive
        case notFound
        case rateLimited
        case unavailable
    }

    enum Outcome {
        case paid(Receipt)
        case left(notice: AppModel.Notice?, problem: PaymentProblem?)
        case payByCard
        case backToName
    }

    typealias Reader = @MainActor (_ amountCents: Int, _ orderID: String, _ checkout: CheckoutIdentity) async -> ReaderChargeResult

    static let wasNotCharged = "Your gift card wasn't charged"

    let quote: OrderQuote
    let customerName: String
    let orderNumber: Int
    let checkout: CheckoutIdentity
    private(set) var step: Step = .scan
    private(set) var digits = ""
    private(set) var cameraAvailable = true
    var onFinish: (Outcome) -> Void = { _ in }

    @ObservationIgnored private let backend: GiftCardBackend
    @ObservationIgnored private let reader: Reader
    @ObservationIgnored private let merchantName: String
    @ObservationIgnored private let log: (String) -> Void
    @ObservationIgnored private let appliedPause: Duration
    @ObservationIgnored private let retryDelays: [Duration]
    @ObservationIgnored private var order: SquareAPI.CreatedOrder?
    @ObservationIgnored private var gan: String?
    @ObservationIgnored private var hold: GiftCardCharge?
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var finished = false

    init(quote: OrderQuote, customerName: String, orderNumber: Int, checkout: CheckoutIdentity, backend: GiftCardBackend,
         merchantName: String, appliedPause: Duration = .seconds(2.2), retryDelays: [Duration] = [.seconds(1), .seconds(3)],
         log: @escaping (String) -> Void, reader: @escaping Reader) {
        self.quote = quote
        self.customerName = customerName
        self.orderNumber = orderNumber
        self.checkout = checkout
        self.backend = backend
        self.merchantName = merchantName
        self.appliedPause = appliedPause
        self.retryDelays = retryDelays
        self.log = log
        self.reader = reader
    }

    var isBusy: Bool {
        switch step {
        case .checking, .charging, .applied, .readerPayment, .completing: true
        default: false
        }
    }

    // MARK: Entering the number

    func cameraUnavailable() {
        cameraAvailable = false
        if step == .scan { step = .manual }
    }

    func enterManually() {
        guard step == .scan else { return }
        digits = ""
        step = .manual
    }

    func type(_ digit: Int) {
        guard step == .manual, digits.count < GiftCardNumber.length, (0...9).contains(digit) else { return }
        digits += String(digit)
    }

    func deleteDigit() {
        guard step == .manual, !digits.isEmpty else { return }
        digits.removeLast()
    }

    var canSubmitDigits: Bool { step == .manual && digits.count == GiftCardNumber.length }

    func submitDigits() {
        guard canSubmitDigits else { return }
        submit(digits)
    }

    /// Returns false for codes that aren't a gift card number, so the scanner keeps looking.
    @discardableResult
    func scanned(_ code: String) -> Bool {
        guard step == .scan, let number = GiftCardNumber.parse(code) else { return false }
        submit(number)
        return true
    }

    private func submit(_ number: String) {
        gan = number
        attempt += 1
        let current = attempt
        step = .checking
        log("Gift card ending \(GiftCardNumber.last4(number)): checking balance for order #\(orderNumber)")
        Task {
            async let created = ensureOrder()
            async let looked = lookup(number)
            let (orderResult, balanceResult) = await (created, looked)
            guard current == attempt, step == .checking else { return }
            switch (orderResult, balanceResult) {
            case (_, .failure(let failure)):
                show(failure)
            case (.failure(let failure), _):
                show(failure)
            case (.success(let order), .success(let balance)):
                decide(order: order, balance: balance)
            }
        }
    }

    private func ensureOrder() async -> Result<SquareAPI.CreatedOrder, GiftCardFailure> {
        if let order { return .success(order) }
        do {
            let created = try await backend.createCheckout(quote: quote, customerName: customerName, orderNumber: orderNumber,
                                                           checkout: checkout)
            order = created
            log("Gift card checkout \(checkout.id): order \(created.id), total \(created.totalCents.formattedAsUSD)")
            return .success(created)
        } catch {
            let failure = GiftCardFailure(error)
            log("Gift card checkout failed: \(failure)")
            return .failure(failure)
        }
    }

    private func lookup(_ number: String) async -> Result<GiftCardBalance, GiftCardFailure> {
        do {
            return .success(try await backend.lookup(gan: number))
        } catch {
            let failure = GiftCardFailure(error)
            log("Gift card lookup failed: \(failure)")
            return .failure(failure)
        }
    }

    private func decide(order: SquareAPI.CreatedOrder, balance: GiftCardBalance) {
        log("Gift card ending \(balance.last4): \(balance.state), balance \(balance.balanceCents.formattedAsUSD), order total \(order.totalCents.formattedAsUSD)")
        if !balance.isActive {
            step = .problem(.inactive)
        } else if balance.balanceCents <= 0 {
            step = .problem(.empty)
        } else if balance.balanceCents >= order.totalCents {
            step = .confirmFull(totalCents: order.totalCents, balanceCents: balance.balanceCents, last4: balance.last4)
        } else {
            step = .confirmSplit(balanceCents: balance.balanceCents, remainingCents: order.totalCents - balance.balanceCents,
                                 last4: balance.last4)
        }
    }

    private func show(_ failure: GiftCardFailure) {
        switch failure {
        case .notFound: step = .problem(.notFound)
        case .inactive: step = .problem(.inactive)
        case .empty: step = .problem(.empty)
        case .rateLimited: step = .problem(.rateLimited)
        case .amountMismatch, .unavailable: step = .problem(.unavailable)
        }
    }

    // MARK: Paying

    func confirm() {
        switch step {
        case .confirmFull:
            charge(agreedToSplit: false)
        case .confirmSplit:
            if let hold {
                payRemainder(after: hold)
            } else {
                charge(agreedToSplit: true)
            }
        default:
            break
        }
    }

    private func charge(agreedToSplit: Bool) {
        guard let gan, let order else { return }
        step = .charging
        let key = UUID().uuidString
        Task {
            let charge: GiftCardCharge
            do {
                charge = try await backend.charge(checkoutID: checkout.id, gan: gan, idempotencyKey: key)
            } catch {
                let failure = GiftCardFailure(error)
                log("Gift card charge failed: \(failure)")
                guard !finished else { return }
                if failure.isRetryable {
                    // The charge may have gone through without its response arriving.
                    await cancelHolds([])
                }
                show(failure)
                return
            }
            hold = charge
            log("Gift card ending \(charge.last4): held \(charge.approvedCents.formattedAsUSD) as \(charge.paymentId), \(charge.remainingCents.formattedAsUSD) remaining")
            guard !finished else { return }
            if charge.remainingCents <= 0 {
                await complete(paymentIDs: [charge.paymentId], cardDescription: nil, order: order)
            } else if agreedToSplit {
                payRemainder(after: charge)
            } else {
                step = .confirmSplit(balanceCents: charge.approvedCents, remainingCents: charge.remainingCents, last4: charge.last4)
            }
        }
    }

    private func payRemainder(after charge: GiftCardCharge) {
        guard let order else { return }
        step = .applied(giftCents: charge.approvedCents, remainingCents: charge.remainingCents)
        Task {
            try? await Task.sleep(for: appliedPause)
            guard !finished else { return }
            step = .readerPayment(remainingCents: charge.remainingCents)
            log("Taking \(charge.remainingCents.formattedAsUSD) on the reader for the rest of order \(order.id)")
            let result = await reader(charge.remainingCents, order.id, checkout)
            switch result {
            case .approved(let paymentID, let card):
                log("Reader payment \(paymentID) approved for the rest (\(card))")
                await complete(paymentIDs: [charge.paymentId, paymentID], cardDescription: card, order: order)
            case .failed(let problem, let paymentID):
                log("Reader payment for the rest failed: \(problem.title)")
                await cancelHolds([charge.paymentId] + (paymentID.map { [$0] } ?? []))
                finish(.left(notice: AppModel.Notice(title: problem.title, details: problem.details + [Self.wasNotCharged]),
                             problem: problem))
            case .canceled:
                log("Reader payment for the rest canceled")
                await cancelHolds([charge.paymentId])
                finish(.left(notice: AppModel.Notice(title: Self.wasNotCharged, details: ["You can pay another way or try again"]),
                             problem: nil))
            }
        }
    }

    private func complete(paymentIDs: [String], cardDescription: String?, order: SquareAPI.CreatedOrder) async {
        guard let hold else { return }
        step = .completing
        let key = UUID().uuidString
        var lastFailure: GiftCardFailure?
        for delay in [Duration.zero] + retryDelays {
            if delay > .zero { try? await Task.sleep(for: delay) }
            do {
                try await backend.complete(checkoutID: checkout.id, paymentIDs: paymentIDs, idempotencyKey: key)
                log("Checkout \(checkout.id) completed with \(paymentIDs.joined(separator: ", "))")
                finish(.paid(receipt(order: order, hold: hold, readerPaymentID: paymentIDs.count > 1 ? paymentIDs[1] : nil,
                                     readerCard: cardDescription)))
                return
            } catch {
                let failure = GiftCardFailure(error)
                lastFailure = failure
                log("Completing checkout \(checkout.id) failed: \(failure)")
                if !failure.isRetryable { break }
            }
        }
        log("Giving up on checkout \(checkout.id) (\(lastFailure.map { "\($0)" } ?? "unknown")); canceling its payments")
        await cancelHolds(paymentIDs)
        finish(.left(notice: AppModel.Notice(title: "Payment didn't go through",
                                             details: ["We couldn't finish your payment, so your cards weren't charged",
                                                       "Please try again or ask a volunteer for help"]),
                     problem: nil))
    }

    private func cancelHolds(_ paymentIDs: [String]) async {
        for delay in [Duration.zero] + retryDelays {
            if delay > .zero { try? await Task.sleep(for: delay) }
            do {
                try await backend.cancel(checkoutID: checkout.id, paymentIDs: paymentIDs)
                log("Canceled gift card holds for checkout \(checkout.id)" + (paymentIDs.isEmpty ? "" : " and \(paymentIDs.joined(separator: ", "))"))
                hold = nil
                return
            } catch {
                log("Canceling checkout \(checkout.id) failed: \(GiftCardFailure(error)); the server releases holds after 15 minutes")
            }
        }
    }

    private func receipt(order: SquareAPI.CreatedOrder, hold: GiftCardCharge, readerPaymentID: String?, readerCard: String?) -> Receipt {
        let gift = GiftCardTender(paymentID: hold.paymentId, cents: hold.approvedCents, last4: hold.last4)
        let giftLabel = "Gift card •••• \(hold.last4)"
        return Receipt(
            merchantName: merchantName, eventName: Config.eventName, date: Date(), orderNumber: orderNumber,
            orderRef: checkout.orderRef, customerName: customerName, squareOrderID: order.id,
            paymentID: readerPaymentID ?? hold.paymentId,
            cardDescription: readerCard.map { "\($0) + \(giftLabel)" } ?? giftLabel,
            lines: order.lines, subtotalCents: order.totalCents - order.taxCents, taxCents: order.taxCents,
            totalCents: order.totalCents, isSimulated: backend.isSimulated, checkoutID: checkout.id,
            receiptToken: checkout.receiptToken, giftCard: gift
        )
    }

    // MARK: Leaving

    func back() {
        switch step {
        case .scan, .manual where !cameraAvailable:
            finish(.backToName)
        case .manual:
            step = .scan
        case .problem(.rateLimited), .confirmFull, .confirmSplit:
            leave()
        case .problem:
            tryAnother()
        default:
            break
        }
    }

    func tryAnother() {
        guard !isBusy else { return }
        attempt += 1
        gan = nil
        digits = ""
        step = cameraAvailable ? .scan : .manual
    }

    /// Leaves for the order summary, releasing a hold if one was taken.
    func leave() {
        guard !finished else { return }
        guard let hold else {
            finish(.left(notice: nil, problem: nil))
            return
        }
        step = .completing
        Task {
            await cancelHolds([hold.paymentId])
            finish(.left(notice: AppModel.Notice(title: Self.wasNotCharged, details: []), problem: nil))
        }
    }

    func payByCard() {
        guard !finished, !isBusy else { return }
        attempt += 1
        guard let hold else {
            finish(.payByCard)
            return
        }
        step = .completing
        Task {
            await cancelHolds([hold.paymentId])
            finish(.payByCard)
        }
    }

    private func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        onFinish(outcome)
    }
}
