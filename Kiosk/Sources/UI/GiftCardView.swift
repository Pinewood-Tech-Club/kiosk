import SwiftUI

struct GiftCardView: View {
    let checkout: GiftCardCheckout
    @State private var readCode: String?

    private var step: GiftCardCheckout.Step { checkout.step }

    private var showsBack: Bool {
        switch step {
        case .scan, .manual, .problem: true
        default: false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                GlassBackButton { checkout.back() }
                    .opacity(showsBack ? 1 : 0)
                    .disabled(!showsBack)
                Spacer()
            }
            .padding(.horizontal, 48)
            .padding(.top, 84)

            content
                .id(stepKey)
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.3), value: stepKey)
        .animation(.easeInOut(duration: 0.3), value: showsBack)
        .onChange(of: stepKey) { readCode = nil }
    }

    private var stepKey: String {
        switch step {
        case .scan: "scan"
        case .manual: "manual"
        case .checking: "checking"
        case .confirmFull: "confirm-full"
        case .confirmSplit: "confirm-split"
        case .charging: "charging"
        case .applied: "applied"
        case .readerPayment: "reader"
        case .completing: "completing"
        case .problem(let problem): "problem-\(problem)"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .scan: scan
        case .manual: manual
        case .checking: working("Checking your gift card…")
        case .charging: working("Charging your gift card…")
        case .completing: working("Finishing your payment…")
        case .readerPayment(let remaining): working("Pay \(remaining.formattedAsUSD) on the card reader")
        case .confirmFull(let total, let balance, let last4): confirmFull(total: total, balance: balance, last4: last4)
        case .confirmSplit(let balance, let remaining, let last4): confirmSplit(balance: balance, remaining: remaining, last4: last4)
        case .applied(let gift, let remaining): applied(gift: gift, remaining: remaining)
        case .problem(let problem): problemView(problem)
        }
    }

    // MARK: Scan

    private var scan: some View {
        VStack(spacing: 0) {
            title("Scan your gift card")
                .padding(.top, 40)
            subtitle("Hold your gift card's QR code or barcode up to the camera.")
                .padding(.top, 14)

            viewfinder
                .padding(.top, 44)

            HStack(spacing: 20) {
                Button { checkout.enterManually() } label: {
                    HStack(spacing: 10) {
                        LucideIcon(name: "keyboard", size: 24)
                        Text("Enter number instead")
                    }
                }
                .buttonStyle(.glassSecondary(height: 72, fontSize: 23))
                payByCardButton
            }
            .padding(.top, 48)
        }
    }

    private var viewfinder: some View {
        let shape = RoundedRectangle(cornerRadius: 44, style: .continuous)
        return ZStack {
            shape.fill(Theme.surface)
            GiftCardScanner(onCode: read, onUnavailable: { _ in checkout.cameraUnavailable() })
            if readCode != nil {
                Theme.success.opacity(0.22)
                LucideIcon(name: "check", size: 56)
                    .foregroundStyle(Theme.onText)
                    .frame(width: 112, height: 112)
                    .background(Theme.success, in: .circle)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .frame(width: 540, height: 540)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(readCode == nil ? Theme.hairline : Theme.success, lineWidth: readCode == nil ? 1 : 4)
        }
        .animation(.spring(duration: 0.35), value: readCode)
        .accessibilityElement()
        .accessibilityLabel("Gift card camera")
    }

    private func read(_ code: String) {
        guard readCode == nil, GiftCardNumber.parse(code) != nil else { return }
        readCode = code
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Task {
            try? await Task.sleep(for: .seconds(0.5))
            if !checkout.scanned(code) { readCode = nil }
        }
    }

    // MARK: Manual entry

    private var manual: some View {
        VStack(spacing: 0) {
            title("Enter your gift card number")
                .padding(.top, 40)
            subtitle("It's the 16-digit number on your card.")
                .padding(.top, 14)

            numberField
                .padding(.top, 40)

            keypad
                .padding(.top, 36)

            Button { checkout.submitDigits() } label: {
                HStack(spacing: 12) {
                    Text("Check Balance")
                    LucideIcon(name: "arrow-right", size: 28)
                }
                .frame(minWidth: 400)
            }
            .buttonStyle(.glassCTA(height: 88, fontSize: 30))
            .disabled(!checkout.canSubmitDigits)
            .padding(.top, 40)

            payByCardButton
                .padding(.top, 20)
        }
    }

    private var numberField: some View {
        let digits = Array(checkout.digits)
        return HStack(spacing: 26) {
            ForEach(0..<4, id: \.self) { group in
                HStack(spacing: 4) {
                    ForEach(0..<4, id: \.self) { offset in
                        let index = group * 4 + offset
                        Text(index < digits.count ? String(digits[index]) : "•")
                            .foregroundStyle(index < digits.count ? Theme.text : Theme.text.opacity(0.25))
                            .frame(width: 30)
                    }
                }
            }
        }
        .font(Theme.sans(46, .medium))
        .monospacedDigit()
        .frame(width: 660, height: 112)
        .glassField(isFocused: true, cornerRadius: 56)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Gift card number")
        .accessibilityValue(GiftCardNumber.grouped(checkout.digits))
    }

    private var keypad: some View {
        Grid(horizontalSpacing: 18, verticalSpacing: 16) {
            ForEach([[1, 2, 3], [4, 5, 6], [7, 8, 9]], id: \.self) { row in
                GridRow {
                    ForEach(row, id: \.self) { digitKey($0) }
                }
            }
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                digitKey(0)
                Button { checkout.deleteDigit() } label: {
                    LucideIcon(name: "delete", size: 34).frame(width: 140)
                }
                .buttonStyle(.glassSecondary(height: 84, fontSize: 36))
                .disabled(checkout.digits.isEmpty)
                .accessibilityLabel("Delete")
            }
        }
    }

    private func digitKey(_ digit: Int) -> some View {
        Button { checkout.type(digit) } label: {
            Text("\(digit)").frame(width: 140)
        }
        .buttonStyle(.glassSecondary(height: 84, fontSize: 38))
        .disabled(checkout.digits.count >= GiftCardNumber.length)
    }

    // MARK: Confirm

    private func confirmFull(total: Int, balance: Int, last4: String) -> some View {
        VStack(spacing: 0) {
            title("Pay \(total.formattedAsUSD) with gift card ending \(last4)?")
                .padding(.top, 150)
            AmountCard(rows: [
                .init(title: "Gift card balance", cents: balance),
                .init(title: "This order", cents: -total),
                .init(title: "Balance after", cents: balance - total, emphasized: true),
            ])
            .padding(.top, 48)
            decision(primary: "Pay \(total.formattedAsUSD)")
                .padding(.top, 56)
        }
    }

    private func confirmSplit(balance: Int, remaining: Int, last4: String) -> some View {
        VStack(spacing: 0) {
            title("Your gift card has \(balance.formattedAsUSD).")
                .padding(.top, 150)
            subtitle("Use it and pay the remaining \(remaining.formattedAsUSD) by card?")
                .padding(.top, 16)
            AmountCard(rows: [
                .init(title: "Order total", cents: balance + remaining),
                .init(title: "Gift card ending \(last4)", cents: -balance),
                .init(title: "Pay by card", cents: remaining, emphasized: true),
            ])
            .padding(.top, 48)
            decision(primary: "Split Payment")
                .padding(.top, 56)
        }
    }

    private func decision(primary: String) -> some View {
        VStack(spacing: 18) {
            Button { checkout.confirm() } label: {
                Text(primary).frame(minWidth: 400)
            }
            .buttonStyle(.glassCTA(height: 88, fontSize: 30))
            Button { checkout.leave() } label: {
                Text("Cancel").frame(minWidth: 400)
            }
            .buttonStyle(.glassSecondary(height: 72, fontSize: 24))
        }
    }

    private func applied(gift: Int, remaining: Int) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                LucideIcon(name: "check", size: 16)
                    .foregroundStyle(Theme.onText)
                    .frame(width: 28, height: 28)
                    .background(Theme.success, in: .circle)
                Text("Gift card applied")
                    .font(Theme.serif(24, .semibold))
                    .foregroundStyle(Theme.success)
            }
            .padding(.top, 260)
            title("\(gift.formattedAsUSD) is paid by your gift card.")
                .padding(.top, 18)
            subtitle("Now pay the remaining \(remaining.formattedAsUSD) on the card reader.")
                .padding(.top, 16)
        }
    }

    // MARK: Status

    private func working(_ message: String) -> some View {
        VStack(spacing: 28) {
            ProgressView()
                .controlSize(.extraLarge)
                .tint(Theme.text)
            Text(message)
                .font(Theme.serif(34))
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 380)
    }

    private func problemView(_ problem: GiftCardCheckout.Problem) -> some View {
        VStack(spacing: 0) {
            LucideIcon(name: "circle-alert", size: 56)
                .foregroundStyle(Theme.accent)
                .padding(.top, 220)
            title(problem.title)
                .padding(.top, 28)
            subtitle(problem.message)
                .padding(.top, 16)
            VStack(spacing: 18) {
                if problem == .rateLimited {
                    payByCardPrimary
                    Button { checkout.leave() } label: {
                        Text("Back to Order").frame(minWidth: 400)
                    }
                    .buttonStyle(.glassSecondary(height: 72, fontSize: 24))
                } else {
                    Button { checkout.tryAnother() } label: {
                        Text(problem == .notFound || problem == .unavailable ? "Try Again" : "Try Another Card").frame(minWidth: 400)
                    }
                    .buttonStyle(.glassCTA(height: 88, fontSize: 30))
                    Button { checkout.payByCard() } label: {
                        Text("Pay with Card").frame(minWidth: 400)
                    }
                    .buttonStyle(.glassSecondary(height: 72, fontSize: 24))
                }
            }
            .padding(.top, 56)
        }
    }

    // MARK: Pieces

    private var payByCardButton: some View {
        Button { checkout.payByCard() } label: {
            HStack(spacing: 10) {
                LucideIcon(name: "credit-card", size: 24)
                Text("Pay with card instead")
            }
        }
        .buttonStyle(.glassSecondary(height: 72, fontSize: 23))
    }

    private var payByCardPrimary: some View {
        Button { checkout.payByCard() } label: {
            Text("Pay with Card").frame(minWidth: 400)
        }
        .buttonStyle(.glassCTA(height: 88, fontSize: 30))
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(Theme.serif(52))
            .foregroundStyle(Theme.text)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 96)
    }

    private func subtitle(_ text: String) -> some View {
        Text(text)
            .font(Theme.serif(26, .regular))
            .foregroundStyle(Theme.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 96)
    }
}

private struct AmountCard: View {
    struct Row: Hashable {
        let title: String
        let cents: Int
        var emphasized = false
    }

    let rows: [Row]

    var body: some View {
        VStack(spacing: 16) {
            ForEach(rows, id: \.self) { row in
                if row.emphasized {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(row.title)
                        .font(Theme.serif(row.emphasized ? 26 : 22, row.emphasized ? .semibold : .regular))
                        .foregroundStyle(row.emphasized ? Theme.text : Theme.textSecondary)
                    Spacer()
                    Text(row.cents < 0 ? "−" + (-row.cents).formattedAsUSD : row.cents.formattedAsUSD)
                        .font(row.emphasized ? Theme.serif(30, .bold) : Theme.sans(22, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.text)
                }
            }
        }
        .padding(36)
        .frame(width: 600)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Theme.surface)
                .overlay { RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1) }
        }
    }
}

private extension GiftCardCheckout.Problem {
    var title: String {
        switch self {
        case .empty: "This gift card has no balance"
        case .inactive: "This gift card isn't active"
        case .notFound: "We couldn't find that gift card"
        case .rateLimited: "Please ask a volunteer for help"
        case .unavailable: "Gift cards aren't working right now"
        }
    }

    var message: String {
        switch self {
        case .empty, .inactive: "Try another gift card, or pay with a credit or debit card."
        case .notFound: "Check the number and try again."
        case .rateLimited: "This kiosk has had too many gift card tries. A volunteer can help, or you can pay by card."
        case .unavailable: "Try again, or pay with a credit or debit card."
        }
    }
}
