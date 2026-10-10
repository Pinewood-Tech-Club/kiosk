import SwiftUI

struct SummaryView: View {
    let app: AppModel

    var body: some View {
        let quote = app.orderQuote
        VStack(spacing: 0) {
            ZStack {
                Text("Your Order")
                    .font(Theme.serif(52))
                    .foregroundStyle(Theme.ink)
                HStack {
                    Button { app.backToBuilder() } label: {
                        HStack(spacing: 6) {
                            LucideIcon(name: "chevron-left", size: 26)
                            Text("Keep ordering").font(Theme.serif(22, .medium))
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle(height: 56))
                    Spacer()
                }
            }
            .padding(.horizontal, 48)
            .padding(.top, 84)

            if let notice = app.notice {
                NoticeBanner(notice: notice)
                    .padding(.horizontal, 64)
                    .padding(.top, 28)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            ScrollView {
                VStack(spacing: 14) {
                    ForEach(Array(quote.lines.enumerated()), id: \.element.id) { index, line in
                        ItemRow(index: index + 1, line: line) { app.removeItem(line.id) }
                    }
                    PricingExplainer(quote: quote)
                        .padding(.top, 14)
                }
                .padding(.horizontal, 64)
                .padding(.vertical, 28)
            }
            .scrollBounceBehavior(.basedOnSize)

            VStack(spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Total").font(Theme.serif(34))
                    Spacer()
                    Text(quote.totalCents.formattedAsUSD)
                        .font(Theme.serif(40, .bold))
                        .monospacedDigit()
                }
                .foregroundStyle(Theme.ink)
                Text("Sales tax, if any, is added at payment.")
                    .font(Theme.sans(16))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { app.completeOrder() } label: {
                    HStack(spacing: 12) {
                        Text("Complete Order")
                        LucideIcon(name: "arrow-right", size: 26)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle(height: 84, fontSize: 30))
                .disabled(quote.isEmpty)
            }
            .padding(.horizontal, 64)
            .padding(.top, 24)
            .padding(.bottom, 44)
            .background(Theme.background.shadow(.drop(color: Theme.cardShadow, radius: 20, y: -6)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .animation(.easeInOut(duration: 0.3), value: app.notice)
        .animation(.easeInOut(duration: 0.3), value: quote.lines.map(\.id))
    }
}

private struct ItemRow: View {
    let index: Int
    let line: OrderQuote.Line
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 20) {
            LucideIcon(name: line.item.vessel == .cone ? "ice-cream-cone" : "ice-cream-bowl", size: 34)
                .foregroundStyle(Theme.ink)
                .frame(width: 68, height: 68)
                .background(Theme.backgroundDeep, in: .circle)
            VStack(alignment: .leading, spacing: 6) {
                Text(line.item.title)
                    .font(Theme.serif(26))
                    .foregroundStyle(Theme.ink)
                Text(line.item.flavorSummary)
                    .font(Theme.sans(18))
                    .foregroundStyle(Theme.inkSecondary)
                HStack(spacing: 6) {
                    Text("\(line.item.scoopCount) scoop\(line.item.scoopCount == 1 ? "" : "s") \(line.scoopShareCents.formattedAsUSD)")
                    if line.vesselCents > 0 {
                        Text("· waffle cone \(line.vesselCents.formattedAsUSD)")
                    }
                }
                .font(Theme.sans(15))
                .foregroundStyle(Theme.inkSecondary)
            }
            Spacer()
            Text(line.totalCents.formattedAsUSD)
                .font(Theme.serif(26))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
            Button(action: remove) {
                LucideIcon(name: "x", size: 22)
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: 52, height: 52)
                    .background(Theme.backgroundDeep, in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Remove item \(index)")
        }
        .padding(20)
        .background(Theme.card, in: .rect(cornerRadius: 26, style: .continuous))
        .shadow(color: Theme.cardShadow, radius: 14, y: 6)
    }
}

private struct PricingExplainer: View {
    let quote: OrderQuote

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How scoop pricing works")
                .font(Theme.serif(22))
                .foregroundStyle(Theme.ink)
            Text("Scoops are priced by the total number of scoops in your whole order, so every extra scoop gets cheaper.")
                .font(Theme.sans(17))
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                ForEach(Pricing.tierTable, id: \.scoops) { tier in
                    tierChip("\(tier.scoops) scoop\(tier.scoops == 1 ? "" : "s")", tier.cents.formattedAsUSD,
                             active: quote.scoopCount == tier.scoops)
                }
                tierChip("Each extra", "+\(Pricing.additionalScoopCents.formattedAsUSD)", active: quote.scoopCount > 3)
            }
            Divider().overlay(Theme.inkFaint)
            row("Your \(quote.scoopCount) scoop\(quote.scoopCount == 1 ? "" : "s")", quote.scoopsTotalCents)
            if quote.coneCount > 0 {
                row("Waffle cone\(quote.coneCount == 1 ? "" : "s") \(quote.coneCount) × \(Pricing.waffleConeCents.formattedAsUSD)",
                    quote.conesTotalCents)
            }
            if quote.lines.count > 1 {
                Text("Item prices above share the scoop price evenly across your scoops.")
                    .font(Theme.sans(15))
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.backgroundDeep, in: .rect(cornerRadius: 26, style: .continuous))
    }

    private func tierChip(_ title: String, _ price: String, active: Bool) -> some View {
        VStack(spacing: 2) {
            Text(title).font(Theme.sans(14, .medium))
            Text(price).font(Theme.serif(20))
        }
        .foregroundStyle(active ? .white : Theme.ink)
        .frame(maxWidth: .infinity, minHeight: 64)
        .background(active ? Theme.ink : Theme.card, in: .rect(cornerRadius: 16, style: .continuous))
    }

    private func row(_ title: String, _ cents: Int) -> some View {
        HStack {
            Text(title).font(Theme.sans(18, .medium))
            Spacer()
            Text(cents.formattedAsUSD).font(Theme.sans(18, .semibold)).monospacedDigit()
        }
        .foregroundStyle(Theme.ink)
    }
}

struct NoticeBanner: View {
    let notice: AppModel.Notice

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            LucideIcon(name: "circle-alert", size: 28)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(notice.title).font(Theme.serif(22))
                ForEach(notice.details, id: \.self) {
                    Text($0).font(Theme.sans(16)).foregroundStyle(Theme.inkSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.ink)
        .padding(20)
        .background(Theme.accent.opacity(0.12), in: .rect(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.accent.opacity(0.4), lineWidth: 1))
    }
}
