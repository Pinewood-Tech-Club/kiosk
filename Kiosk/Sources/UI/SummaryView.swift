import SwiftUI

/// The order, laid out on the expanded tray sheet. Each row leaves its left column empty: the item's
/// live 3D model flies up from the tray and spins there (positions come from `Layout.summaryRowCenterY`).
struct SummaryView: View {
    let app: AppModel

    var body: some View {
        let quote = app.orderQuote
        ZStack(alignment: .top) {
            Capsule()
                .fill(Theme.ink.opacity(0.22))
                .frame(width: 56, height: 6)
                .position(x: Layout.midX, y: Layout.sheetRect.minY + 14)

            HStack {
                Button { app.backToBuilder() } label: {
                    HStack(spacing: 6) {
                        LucideIcon(name: "chevron-down", size: 24)
                        Text("Keep ordering")
                    }
                }
                .buttonStyle(.glassSecondary(height: 60, fontSize: 21))
                Spacer()
            }
            .padding(.horizontal, 40)
            .frame(height: 60)
            .position(x: Layout.midX, y: Layout.backButtonCenter.y)

            Text("Your order")
                .font(Theme.serif(40))
                .foregroundStyle(Theme.ink)
                .position(x: Layout.midX, y: Layout.backButtonCenter.y)

            if let notice = app.notice {
                HStack(spacing: 10) {
                    LucideIcon(name: "circle-alert", size: 20)
                    Text(([notice.title] + notice.details).joined(separator: " "))
                        .lineLimit(2)
                }
                .font(Theme.serif(19, .medium))
                .foregroundStyle(Theme.accentDeep)
                .frame(maxWidth: 820)
                .position(x: Layout.midX, y: Layout.summaryListRect.minY - 26)
                .transition(.opacity)
            }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(quote.lines.enumerated()), id: \.element.id) { index, line in
                        SummaryRow(line: line, showsDivider: index > 0,
                                   edit: { app.tapTrayItem(line.id) },
                                   remove: { app.requestDelete(line.id) })
                            .transition(.opacity)
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .scrollDisabled(quote.lines.count <= Layout.summaryRowsThatFit)
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y + $0.contentInsets.top }) { _, offset in
                app.setSummaryScroll(offset)
            }
            .frame(width: Layout.summaryListRect.width, height: Layout.summaryListRect.height)
            .position(x: Layout.summaryListRect.midX, y: Layout.summaryListRect.midY)

            checkout(quote)
                .frame(width: Layout.screen.width - 112)
                .position(x: Layout.midX, y: 1212)
        }
        .frame(width: Layout.screen.width, height: Layout.screen.height)
        .animation(.easeInOut(duration: 0.35), value: quote.lines.map(\.id))
        .animation(.easeInOut(duration: 0.3), value: app.notice)
    }

    private func checkout(_ quote: OrderQuote) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Theme.inkFaint).frame(height: 1)
            HStack(alignment: .firstTextBaseline) {
                Text("Total").font(Theme.serif(32))
                Spacer()
                Text(quote.totalCents.formattedAsUSD)
                    .font(Theme.serif(56, .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(quote.totalCents)))
            }
            .foregroundStyle(Theme.ink)
            .padding(.top, 22)
            Text(contents(quote))
                .font(Theme.serif(19, .regular))
                .foregroundStyle(Theme.ink.opacity(0.65))
            Button { app.completeOrder() } label: {
                Text("Check Out").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassCTA(height: 88, fontSize: 30))
            .disabled(quote.isEmpty)
            .padding(.top, 26)
        }
    }

    private func contents(_ quote: OrderQuote) -> String {
        var text = quote.scoopCount == 1 ? "1 scoop" : "\(quote.scoopCount) scoops"
        if quote.coneCount > 0 {
            text += quote.coneCount == 1 ? " and 1 waffle cone" : " and \(quote.coneCount) waffle cones"
        }
        return text + ", before tax"
    }
}

private struct SummaryRow: View {
    let line: OrderQuote.Line
    let showsDivider: Bool
    let edit: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 268)
            VStack(alignment: .leading, spacing: 6) {
                Text(line.item.vessel.title)
                    .font(Theme.serif(30))
                    .foregroundStyle(Theme.ink)
                Text(line.item.flavors.map(\.title).joined(separator: " · "))
                    .font(Theme.serif(21, .regular))
                    .foregroundStyle(Theme.ink.opacity(0.65))
            }
            Spacer(minLength: 16)
            Text(line.totalCents.formattedAsUSD)
                .font(Theme.serif(28, .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .padding(.trailing, 26)
            GlassIconButton(icon: "pencil", size: 52, iconSize: 20, action: edit)
                .accessibilityLabel("Edit \(line.item.vessel.title)")
            GlassIconButton(icon: "trash-2", size: 52, iconSize: 20, action: remove)
                .accessibilityLabel("Remove \(line.item.vessel.title)")
                .padding(.leading, 16)
        }
        .padding(.trailing, 40)
        .frame(height: Layout.summaryRowHeight)
        .contentShape(Rectangle())
        .onTapGesture(perform: edit)
        .overlay(alignment: .top) {
            if showsDivider {
                Rectangle().fill(Theme.inkFaint).frame(height: 1).padding(.leading, 268).padding(.trailing, 40)
            }
        }
    }
}
