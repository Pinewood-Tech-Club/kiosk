import SwiftUI

extension AppModel {
    var giftCardsAvailable: Bool {
        if simulatePayment { return true }
        return square.credentialSource == .booth && booth.api != nil && booth.connectionState == .connected
            && booth.serverFeatures.contains("gift-cards")
    }

    func startGiftCard(name: String) {
        guard giftCard == nil, !items.isEmpty else { return }
        let backend: GiftCardBackend
        if simulatePayment {
            backend = SimulatedGiftCards()
        } else if let api = booth.api {
            backend = BoothGiftCards(api: api, square: square)
        } else {
            notice = Notice(title: "Gift cards aren't available right now", details: ["Please pay with a card"])
            backToSummary()
            return
        }
        let number = nextOrderNumber()
        let checkout = GiftCardCheckout(
            quote: orderQuote, customerName: name, orderNumber: number, checkout: CheckoutIdentity.make(orderNumber: number),
            backend: backend, merchantName: square.merchantName,
            log: { [weak self] in self?.square.record($0) },
            reader: { [weak self] amount, orderID, checkout in
                await self?.chargeRemainder(amountCents: amount, orderID: orderID, checkout: checkout) ?? .canceled
            }
        )
        checkout.onFinish = { [weak self, weak checkout] outcome in
            guard let self, let checkout, self.giftCard === checkout else { return }
            self.finishGiftCard(outcome, quote: checkout.quote)
        }
        withAnimation(.easeInOut(duration: 0.35)) { giftCard = checkout }
    }

    private func chargeRemainder(amountCents: Int, orderID: String, checkout: CheckoutIdentity) async -> ReaderChargeResult {
        if let forcedError, forcedError != .assets {
            switch await square.simulate(forcedError) {
            case .failed(let problem): return .failed(problem, paymentID: nil)
            case .canceled: return .canceled
            case .succeeded(let receipt): return .approved(paymentID: receipt.paymentID, cardDescription: receipt.cardDescription)
            }
        }
        if simulatePayment {
            square.record("Simulating the reader for the rest (\(amountCents.formattedAsUSD))")
            try? await Task.sleep(for: .seconds(1.2))
            return .approved(paymentID: "SIM-CARD-\(UUID().uuidString.prefix(8))", cardDescription: "Visa •••• 1111")
        }
        booth.checkReaderBeforePayment()
        return await square.chargeRemainder(amountCents: amountCents, orderID: orderID, checkout: checkout, from: host.presenter)
    }

    private func finishGiftCard(_ outcome: GiftCardCheckout.Outcome, quote: OrderQuote) {
        switch outcome {
        case .paid(let receipt):
            booth.orderPaid(receipt, quote: quote)
            self.receipt = receipt
            stage.enterReceipt()
            withAnimation(.easeInOut(duration: 0.45)) { screen = .confirmation }
        case .left(let notice, let problem):
            if let problem { booth.paymentFailed(problem) }
            self.notice = notice
            backToSummary()
        case .payByCard:
            payByCardInstead()
        case .backToName:
            withAnimation(.easeInOut(duration: 0.35)) { giftCard = nil }
        }
    }

    func payByCardInstead() {
        paymentMethod = .card
        withAnimation(.easeInOut(duration: 0.35)) { giftCard = nil }
        submitName()
    }
}
