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

            ReceiptView(receipt: receipt, entries: ReceiptItem.group(receipt, items: app.items), stage: app.stage)
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

/// One ordered item on the receipt, with the amounts Square charged for it.
struct ReceiptItem: Identifiable {
    let id: UUID
    let number: Int
    let item: IceCreamItem?
    let vesselTitle: String
    let vesselCents: Int
    let scoopCount: Int
    let scoopCents: Int
    let toppingCount: Int
    let toppingCents: Int

    var totalCents: Int { vesselCents + scoopCents + toppingCents }

    /// "Cup + 2 Scoops ($6.00) + 1 Topping ($0.50)"; the vessel shows a price only when it has one.
    var composition: String {
        var parts = [vesselCents > 0 ? "\(vesselTitle) (\(vesselCents.formattedAsUSD))" : vesselTitle]
        if scoopCount > 0 {
            parts.append("\(scoopCount) Scoop\(scoopCount == 1 ? "" : "s") (\(scoopCents.formattedAsUSD))")
        }
        if toppingCount > 0 {
            parts.append("\(toppingCount) Topping\(toppingCount == 1 ? "" : "s") (\(toppingCents.formattedAsUSD))")
        }
        return parts.joined(separator: " + ")
    }

    var flavors: String { item.map { IceCreamItem.describe($0.flavors) } ?? "" }

    /// Groups Square's charged lines by the item tag in each line's note ("#2 Cup: Chocolate"), so every
    /// amount is exactly what Square billed. If the lines can't be grouped that way, falls back to the
    /// kiosk's order-position pricing, which is the same rule the catalog encodes.
    static func group(_ receipt: Receipt, items: [IceCreamItem]) -> [ReceiptItem] {
        var groups: [Int: (vessel: Int, scoops: Int, scoopCents: Int, toppings: Int, toppingCents: Int, hint: String)] = [:]
        var tagged = true
        for line in receipt.lines {
            guard let match = line.detail.firstMatch(of: /^#(\d+)/), let number = Int(match.1) else {
                tagged = false
                break
            }
            var group = groups[number] ?? (0, 0, 0, 0, 0, "")
            let cents = line.baseCents * line.quantity
            let title = line.title.lowercased()
            if title.contains("topping") {
                group.toppings += line.quantity
                group.toppingCents += cents
            } else if title.contains("cone") {
                group.vessel += cents
            } else {
                group.scoops += line.quantity
                group.scoopCents += cents
                if group.hint.isEmpty { group.hint = line.detail }
            }
            groups[number] = group
        }
        let total = groups.values.reduce(0) { $0 + $1.vessel + $1.scoopCents + $1.toppingCents }
        if tagged, !groups.isEmpty, total == receipt.subtotalCents, items.isEmpty || groups.count == items.count {
            return groups.keys.sorted().map { number in
                let group = groups[number]!
                let item = number <= items.count ? items[number - 1] : nil
                let isCone = item?.vessel == .cone || group.vessel > 0 || group.hint.contains("Cone")
                return ReceiptItem(id: item?.id ?? UUID(), number: number, item: item,
                                   vesselTitle: isCone ? Vessel.cone.title : Vessel.cup.title, vesselCents: group.vessel,
                                   scoopCount: group.scoops, scoopCents: group.scoopCents,
                                   toppingCount: group.toppings, toppingCents: group.toppingCents)
            }
        }
        return Pricing.quote(items).lines.enumerated().map { index, line in
            ReceiptItem(id: line.item.id, number: index + 1, item: line.item, vesselTitle: line.item.vessel.title,
                        vesselCents: line.vesselCents, scoopCount: line.item.scoopCount, scoopCents: line.scoopShareCents,
                        toppingCount: 0, toppingCents: 0)
        }
    }
}

private struct ReceiptView: View {
    let receipt: Receipt
    let entries: [ReceiptItem]
    let stage: Stage
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
            VStack(alignment: .leading, spacing: 14) {
                ForEach(entries) { entry in
                    HStack(alignment: .center, spacing: 14) {
                        // The item's live 3D model is drawn here by the stage.
                        Color.clear
                            .frame(width: 84, height: 84)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                                stage.setReceiptFrame(entry.id, frame)
                            }
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("Item \(entry.number)").font(Theme.serif(19))
                                Leader()
                                Text(entry.totalCents.formattedAsUSD).font(Theme.sans(17, .medium)).monospacedDigit()
                            }
                            Text(entry.composition)
                                .font(Theme.sans(14))
                                .foregroundStyle(Theme.ink.opacity(0.78))
                                .fixedSize(horizontal: false, vertical: true)
                            if !entry.flavors.isEmpty {
                                Text(entry.flavors)
                                    .font(Theme.serif(14, .regular))
                                    .italic()
                                    .foregroundStyle(Theme.inkSecondary)
                            }
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
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { stage.receiptClip = $0 }
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
