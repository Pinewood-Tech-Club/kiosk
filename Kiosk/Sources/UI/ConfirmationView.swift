import SwiftUI

struct ConfirmationView: View {
    let app: AppModel
    let receipt: Receipt
    @State private var email = ""
    @State private var emailNote: String?
    @State private var deadline = Date().addingTimeInterval(Self.timeout)
    @FocusState private var emailFocused: Bool

    private static let timeout: TimeInterval = 10

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                LucideIcon(name: "check", size: 44)
                    .foregroundStyle(.white)
                    .frame(width: 88, height: 88)
                    .background(Theme.success, in: .circle)
                Text("Thank you, \(receipt.customerName)!")
                    .font(Theme.serif(50))
                    .foregroundStyle(Theme.ink)
                Text("Order #\(receipt.orderNumber) is paid. We'll call your name when it's ready.")
                    .font(Theme.sans(20))
                    .foregroundStyle(Theme.inkSecondary)
            }
            .padding(.top, 76)

            ReceiptCard(receipt: receipt)
                .padding(.horizontal, 96)
                .padding(.top, 30)

            HStack(spacing: 12) {
                LucideIcon(name: "mail", size: 22)
                    .foregroundStyle(Theme.inkSecondary)
                TextField("", text: $email, prompt: Text("Email me a receipt (optional)").foregroundStyle(Theme.ink.opacity(0.35)))
                    .font(Theme.sans(19))
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($emailFocused)
                    .onChange(of: email) { _, _ in extendDeadline() }
                Button("Send") {
                    emailFocused = false
                    emailNote = "Email receipts aren't available yet. Please take a photo of this screen."
                    extendDeadline()
                }
                .font(Theme.sans(18, .semibold))
                .foregroundStyle(Theme.ink)
                .disabled(email.isEmpty)
            }
            .padding(.horizontal, 22)
            .frame(height: 64)
            .background(Theme.card, in: .rect(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.inkFaint, lineWidth: 1))
            .padding(.horizontal, 96)
            .padding(.top, 20)

            HStack(spacing: 10) {
                LucideIcon(name: "camera", size: 20)
                Text(emailNote ?? "Tip: take a picture of this screen to keep as your receipt.")
                    .font(Theme.sans(17))
            }
            .foregroundStyle(Theme.inkSecondary)
            .padding(.top, 14)

            Spacer(minLength: 20)

            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                let remaining = max(0, deadline.timeIntervalSince(context.date))
                VStack(spacing: 14) {
                    Button { app.resetToAttract() } label: {
                        Text("New Order").frame(width: 420)
                    }
                    .buttonStyle(PrimaryButtonStyle(height: 84, fontSize: 30))
                    Text("Starting over in \(Int(remaining.rounded(.up)))s")
                        .font(Theme.sans(16, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.inkSecondary)
                    Capsule()
                        .fill(Theme.inkFaint)
                        .frame(width: 220, height: 4)
                        .overlay(alignment: .leading) {
                            Capsule().fill(Theme.ink.opacity(0.5))
                                .frame(width: 220 * remaining / Self.timeout, height: 4)
                        }
                }
                .onChange(of: remaining <= 0) { _, expired in
                    if expired, !emailFocused { app.resetToAttract() }
                }
            }
            .padding(.bottom, 44)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .onReceive(NotificationCenter.default.publisher(for: TouchObserver.didTouch)) { _ in extendDeadline() }
        .onChange(of: emailFocused) { _, _ in extendDeadline() }
    }

    private func extendDeadline() {
        deadline = Date().addingTimeInterval(Self.timeout)
    }
}

private struct ReceiptCard: View {
    let receipt: Receipt

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(receipt.merchantName).font(Theme.serif(24))
                if receipt.eventName != receipt.merchantName {
                    Text(receipt.eventName).font(Theme.sans(16)).foregroundStyle(Theme.inkSecondary)
                }
                Text(receipt.date.formatted(date: .long, time: .shortened))
                    .font(Theme.sans(16))
                    .foregroundStyle(Theme.inkSecondary)
            }
            .padding(.bottom, 14)

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                meta("Order", "#\(receipt.orderNumber) · \(receipt.customerName)")
                meta("Square order", receipt.squareOrderID)
                meta("Payment", receipt.paymentID)
                meta("Card", receipt.cardDescription)
            }
            .padding(.bottom, 14)

            Divider().overlay(Theme.inkFaint)

            VStack(spacing: 10) {
                ForEach(receipt.lines) { line in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.title).font(Theme.sans(18, .semibold))
                            Text(line.detail).font(Theme.sans(15)).foregroundStyle(Theme.inkSecondary)
                        }
                        Spacer()
                        Text(line.cents.formattedAsUSD).font(Theme.sans(18, .medium)).monospacedDigit()
                    }
                }
            }
            .padding(.vertical, 14)

            Divider().overlay(Theme.inkFaint)

            VStack(spacing: 6) {
                total("Subtotal", receipt.subtotalCents)
                total("Tax", receipt.taxCents)
                HStack {
                    Text("Total").font(Theme.serif(24))
                    Spacer()
                    Text(receipt.totalCents.formattedAsUSD).font(Theme.serif(26, .bold)).monospacedDigit()
                }
                .padding(.top, 4)
            }
            .padding(.top, 14)

            if receipt.isSimulated {
                Text("Simulated payment (test mode)")
                    .font(Theme.sans(14, .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 10)
            }
        }
        .foregroundStyle(Theme.ink)
        .padding(28)
        .background(Theme.card, in: .rect(cornerRadius: 28, style: .continuous))
        .shadow(color: Theme.cardShadow, radius: 20, y: 8)
    }

    private func meta(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).font(Theme.sans(15)).foregroundStyle(Theme.inkSecondary)
            Text(value).font(Theme.sans(15, .medium).monospaced()).textSelection(.enabled)
        }
    }

    private func total(_ title: String, _ cents: Int) -> some View {
        HStack {
            Text(title).font(Theme.sans(17)).foregroundStyle(Theme.inkSecondary)
            Spacer()
            Text(cents.formattedAsUSD).font(Theme.sans(17, .medium)).monospacedDigit()
        }
    }
}

/// Window-level recognizer that observes every touch without interfering with it.
final class TouchObserver: UIGestureRecognizer, UIGestureRecognizerDelegate {
    static let didTouch = Notification.Name("KioskDidTouch")

    static func install(on window: UIWindow) {
        guard !(window.gestureRecognizers ?? []).contains(where: { $0 is TouchObserver }) else { return }
        let observer = TouchObserver(target: nil, action: nil)
        observer.cancelsTouchesInView = false
        observer.delaysTouchesBegan = false
        observer.delaysTouchesEnded = false
        observer.delegate = observer
        window.addGestureRecognizer(observer)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        NotificationCenter.default.post(name: Self.didTouch, object: nil)
        state = .failed
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
