import SwiftUI

struct ConfirmationView: View {
    let app: AppModel
    let receipt: Receipt
    @State private var deadline = Date().addingTimeInterval(Self.timeout)
    @State private var printed = false

    private static let timeout: TimeInterval = 10

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                HStack(spacing: 8) {
                    LucideIcon(name: "check", size: 20)
                    Text("Paid")
                        .font(Theme.sans(16, .bold))
                        .tracking(2.2)
                        .textCase(.uppercase)
                }
                .foregroundStyle(Theme.success)
                Text("Thank you, \(receipt.customerName).")
                    .font(Theme.serif(64))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("We'll call your name when it's ready.")
                    .font(Theme.serif(24, .regular))
                    .italic()
                    .foregroundStyle(Theme.ink.opacity(0.7))
            }
            .padding(.top, 76)
            .padding(.horizontal, 64)

            ReceiptView(receipt: receipt, lines: ReceiptLines.charged(receipt: receipt, quote: app.orderQuote))
                .frame(width: 560)
                .mask(alignment: .top) {
                    Rectangle().frame(maxHeight: printed ? .infinity : 0)
                }
                .padding(.top, 36)

            HStack(spacing: 8) {
                LucideIcon(name: "camera", size: 18)
                Text("Take a photo to keep this receipt.")
            }
            .font(Theme.sans(16))
            .foregroundStyle(Theme.inkSecondary)
            .padding(.top, 20)
            .opacity(printed ? 1 : 0)

            Spacer(minLength: 24)

            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                let remaining = max(0, deadline.timeIntervalSince(context.date))
                VStack(spacing: 20) {
                    Button { app.resetToAttract() } label: {
                        Text("New Order").frame(minWidth: 320)
                    }
                    .buttonStyle(.glassCTA(height: 88, fontSize: 30))
                    Countdown(remaining: remaining, total: Self.timeout)
                }
                .onChange(of: remaining <= 0) { _, expired in
                    if expired { app.resetToAttract() }
                }
            }
            .padding(.bottom, 52)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: TouchObserver.didTouch)) { _ in
            deadline = Date().addingTimeInterval(Self.timeout)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.1).delay(0.25)) { printed = true }
        }
    }
}

private struct Countdown: View {
    let remaining: TimeInterval
    let total: TimeInterval

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle().stroke(Theme.inkFaint, lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: remaining / total)
                    .stroke(Theme.ink.opacity(0.55), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: remaining)
            }
            .frame(width: 16, height: 16)
            Text("Starting over in \(Int(remaining.rounded(.up)))s")
                .font(Theme.sans(16, .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.inkSecondary)
        }
    }
}

/// What Square actually charged: one catalog line per scoop, priced by its position in the whole
/// order (1 Scoop, 2nd Scoop, 3rd+ Scoop), plus one Waffle Cone line per cone.
enum ReceiptLines {
    struct Item: Identifiable {
        let id: Int
        let title: String
        let charges: [Charge]
    }

    struct Charge: Identifiable {
        let id: Int
        let name: String
        let detail: String?
        let cents: Int
    }

    static func charged(receipt: Receipt, quote: OrderQuote) -> [Item] {
        guard !quote.isEmpty, quote.totalCents == receipt.subtotalCents else {
            return receipt.lines.enumerated().map { index, line in
                Item(id: index, title: line.title, charges: [Charge(id: 0, name: line.detail, detail: nil, cents: line.cents)])
            }
        }
        var position = 0
        return quote.lines.enumerated().map { index, line in
            var charges: [Charge] = line.item.flavors.enumerated().map { offset, flavor in
                position += 1
                let cents = Pricing.scoopsTotal(position) - Pricing.scoopsTotal(position - 1)
                return Charge(id: offset, name: flavor.title, detail: scoopName(position), cents: cents)
            }
            if line.item.vessel == .cone {
                charges.append(Charge(id: charges.count, name: "Waffle Cone", detail: nil, cents: line.vesselCents))
            }
            return Item(id: index, title: line.item.vessel.title, charges: charges)
        }
    }

    private static func scoopName(_ position: Int) -> String {
        switch position {
        case 1: "1 Scoop"
        case 2: "2nd Scoop"
        default: "3rd+ Scoop"
        }
    }
}

private struct ReceiptView: View {
    let receipt: Receipt
    let lines: [ReceiptLines.Item]
    @State private var itemsHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            rule.padding(.vertical, 18)
            items
            rule.padding(.vertical, 18)
            totals
            rule.padding(.vertical, 18)
            payment
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 40)
        .padding(.top, 34)
        .padding(.bottom, 40)
        .background(Theme.card, in: ReceiptShape())
        .shadow(color: Theme.cardShadow, radius: 24, y: 12)
    }

    private var rule: some View {
        Line()
            .stroke(Theme.ink.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
            .frame(height: 1)
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text(receipt.merchantName)
                .font(Theme.serif(22))
                .tracking(1.5)
                .textCase(.uppercase)
                .multilineTextAlignment(.center)
            if receipt.eventName != receipt.merchantName {
                Text(receipt.eventName).font(Theme.serif(17, .regular)).italic()
            }
            Text(receipt.date.formatted(.dateTime.month(.wide).day().year().hour().minute()))
                .font(Theme.sans(14))
                .foregroundStyle(Theme.inkSecondary)
                .padding(.top, 2)
            HStack {
                Text("Order \(receipt.orderNumber)")
                Spacer()
                Text(receipt.customerName)
            }
            .font(Theme.serif(20))
            .padding(.top, 16)
        }
    }

    private var items: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(lines) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(Theme.serif(19))
                        ForEach(item.charges) { charge in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(charge.name).font(Theme.sans(16))
                                if let detail = charge.detail {
                                    Text(detail).font(Theme.sans(14)).foregroundStyle(Theme.inkSecondary)
                                }
                                Leader()
                                Text(charge.cents.formattedAsUSD).font(Theme.sans(16)).monospacedDigit()
                            }
                            .padding(.leading, 14)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { itemsHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        .frame(height: min(itemsHeight, 330))
    }

    private var totals: some View {
        VStack(spacing: 8) {
            amountRow("Subtotal", receipt.subtotalCents)
            amountRow("Tax", receipt.taxCents)
            HStack(alignment: .firstTextBaseline) {
                Text("Total").font(Theme.serif(26))
                Spacer()
                Text(receipt.totalCents.formattedAsUSD).font(Theme.serif(30, .bold)).monospacedDigit()
            }
            .padding(.top, 6)
        }
    }

    private var payment: some View {
        VStack(spacing: 6) {
            Text(receipt.cardDescription).font(Theme.sans(15, .medium))
            Text("Payment \(receipt.paymentID)")
            Text("Square order \(receipt.squareOrderID)")
            if receipt.isSimulated {
                Text("Test mode · simulated payment")
                    .font(Theme.sans(13, .semibold))
                    .foregroundStyle(Theme.accentDeep)
                    .padding(.top, 6)
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(Theme.inkSecondary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity)
    }

    private func amountRow(_ title: String, _ cents: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(Theme.sans(16)).foregroundStyle(Theme.inkSecondary)
            Spacer()
            Text(cents.formattedAsUSD).font(Theme.sans(16)).monospacedDigit()
        }
    }
}

private struct Leader: View {
    var body: some View {
        Line()
            .stroke(Theme.ink.opacity(0.3), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [0.1, 5]))
            .frame(height: 1.2)
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
    }
}

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}

private struct ReceiptShape: Shape {
    var cornerRadius: CGFloat = 6
    var toothWidth: CGFloat = 16
    var toothDepth: CGFloat = 7

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let teeth = max(1, Int((rect.width / toothWidth).rounded()))
        let step = rect.width / CGFloat(teeth)
        let base = rect.maxY - toothDepth
        path.move(to: CGPoint(x: rect.minX, y: base))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cornerRadius))
        path.addArc(center: CGPoint(x: rect.minX + cornerRadius, y: rect.minY + cornerRadius), radius: cornerRadius,
                    startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX - cornerRadius, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - cornerRadius, y: rect.minY + cornerRadius), radius: cornerRadius,
                    startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: base))
        for i in stride(from: teeth, to: 0, by: -1) {
            let x = rect.minX + CGFloat(i) * step
            path.addLine(to: CGPoint(x: x - step / 2, y: rect.maxY))
            path.addLine(to: CGPoint(x: x - step, y: base))
        }
        path.closeSubpath()
        return path
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
