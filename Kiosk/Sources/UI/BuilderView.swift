import SwiftUI

private let stepFade = AnyTransition.asymmetric(
    insertion: .opacity.animation(.easeOut(duration: 0.26).delay(0.16)),
    removal: .opacity.animation(.easeIn(duration: 0.18))
)

/// Drawn beneath the RealityView so the 3D icons sit on top of their cards.
struct BuilderBackdrop: View {
    let app: AppModel

    var body: some View {
        ZStack {
            Group {
                switch app.step {
                case .vessel:
                    ZStack {
                        ForEach(Vessel.allCases) { vessel in
                            CardBackground(highlighted: app.current.vessel == vessel)
                                .frame(width: Layout.cardSize.width, height: Layout.cardSize.height)
                                .bounce(trigger: app.vesselBounces[vessel, default: 0])
                                .position(Layout.vesselCardCenter(vessel))
                                .animation(.easeInOut(duration: 0.3), value: app.current.vessel)
                        }
                    }
                    .transition(stepFade)
                case .flavors:
                    ZStack {
                        ForEach(Flavor.allCases) { flavor in
                            CardBackground()
                                .frame(width: Layout.cardSize.width, height: Layout.cardSize.height)
                                .bounce(trigger: app.flavorBounces[flavor, default: 0])
                                .position(Layout.flavorCardCenter(flavor))
                        }
                    }
                    .transition(stepFade)
                case .toppings:
                    EmptyView()
                }
            }

            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(Theme.backgroundDeep)
                .overlay {
                    RoundedRectangle(cornerRadius: 36, style: .continuous)
                        .strokeBorder(Theme.inkFaint, lineWidth: 1)
                }
                .frame(width: Layout.trayRect.width, height: Layout.trayRect.height)
                .position(x: Layout.trayRect.midX, y: Layout.trayRect.midY)
        }
        .frame(width: Layout.screen.width, height: Layout.screen.height)
    }
}

struct BuilderForeground: View {
    let app: AppModel
    @State private var selectedTrayItem: UUID?
    @State private var confirmingReset = false

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .frame(width: Layout.dragArea.width, height: Layout.dragArea.height)
                .position(x: Layout.dragArea.midX, y: Layout.dragArea.midY)
                .gesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { app.stage.dragChanged(translation: $0.translation) }
                        .onEnded { _ in app.stage.dragEnded() }
                )

            header

            Group {
                switch app.step {
                case .vessel: vesselControls.transition(stepFade)
                case .flavors: flavorControls.transition(stepFade)
                case .toppings: EmptyView()
                }
            }

            primaryButton
            tray
        }
        .frame(width: Layout.screen.width, height: Layout.screen.height)
        .alert("Start over?", isPresented: $confirmingReset) {
            Button("Start Over", role: .destructive) { app.resetToAttract() }
            Button("Keep Ordering", role: .cancel) {}
        } message: {
            Text("This clears your whole order.")
        }
    }

    private var header: some View {
        ZStack {
            if app.step != .vessel {
                Button { app.goBack() } label: {
                    HStack(spacing: 6) {
                        LucideIcon(name: "chevron-left", size: 26)
                        Text("Back").font(Theme.serif(22, .medium))
                    }
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 20)
                    .frame(height: 56)
                    .background(Theme.card, in: .capsule)
                    .overlay(Capsule().strokeBorder(Theme.inkFaint, lineWidth: 1))
                    .contentShape(.capsule)
                }
                .buttonStyle(PressableStyle())
                .position(Layout.backButtonCenter)
                .transition(.opacity.animation(.easeInOut(duration: 0.22)))
            }

            StepIndicator(step: app.step)
                .position(x: Layout.midX, y: Layout.stepIndicatorY)

            Text(title)
                .font(Theme.serif(50))
                .foregroundStyle(Theme.ink)
                .contentTransition(.opacity)
                .position(x: Layout.midX, y: Layout.titleY)

            subtitle
                .position(x: Layout.midX, y: Layout.subtitleY)
        }
        .animation(.easeInOut(duration: 0.3), value: app.step)
    }

    private var title: String {
        switch app.step {
        case .vessel: "Choose your vessel"
        case .flavors: "Pick your scoops"
        case .toppings: "Toppings"
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        switch app.step {
        case .vessel:
            Text("Cups are included · Waffle cones are \(Pricing.waffleConeCents.formattedAsUSD)")
                .font(Theme.sans(19))
                .foregroundStyle(Theme.inkSecondary)
        case .flavors:
            HStack(spacing: 14) {
                if app.current.flavors.isEmpty {
                    Text("Tap a flavor to add a scoop")
                        .font(Theme.sans(19))
                        .foregroundStyle(Theme.inkSecondary)
                } else {
                    Text(app.current.flavors.map(\.title).joined(separator: " · "))
                        .font(Theme.sans(19, .medium))
                        .foregroundStyle(Theme.ink)
                    Button { app.undoScoop() } label: {
                        HStack(spacing: 6) {
                            LucideIcon(name: "undo-2", size: 18)
                            Text("Undo").font(Theme.sans(17, .semibold))
                        }
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .background(Theme.card, in: .capsule)
                        .overlay(Capsule().strokeBorder(Theme.inkFaint, lineWidth: 1))
                        .contentShape(.capsule)
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .animation(.easeInOut(duration: 0.25), value: app.current.flavors)
        case .toppings:
            Text("Toppings are coming soon. Your ice cream is ready!")
                .font(Theme.sans(19))
                .foregroundStyle(Theme.inkSecondary)
        }
    }

    private var vesselControls: some View {
        ZStack {
            ForEach(Vessel.allCases) { vessel in
                let center = Layout.vesselCardCenter(vessel)
                Button { app.selectVessel(vessel) } label: {
                    VStack(spacing: 4) {
                        Spacer()
                        Text(vessel.title)
                            .font(Theme.serif(26))
                            .foregroundStyle(Theme.ink)
                        Text(vessel.priceLabel)
                            .font(Theme.sans(18, .medium))
                            .foregroundStyle(vessel == .cup ? Theme.success : Theme.inkSecondary)
                    }
                    .padding(.bottom, 22)
                    .frame(width: Layout.cardSize.width, height: Layout.cardSize.height)
                    .contentShape(.rect(cornerRadius: Layout.cardCornerRadius))
                }
                .buttonStyle(.plain)
                .bounce(trigger: app.vesselBounces[vessel, default: 0])
                .position(center)
            }
        }
    }

    private var flavorControls: some View {
        let full = app.current.scoopCount >= Pricing.maxScoopsPerItem
        return ZStack {
            ForEach(Flavor.allCases) { flavor in
                let center = Layout.flavorCardCenter(flavor)
                let count = app.current.flavors.filter { $0 == flavor }.count
                Button { app.addScoop(flavor) } label: {
                    VStack(spacing: 4) {
                        Spacer()
                        Text(flavor.title)
                            .font(Theme.serif(25))
                            .foregroundStyle(Theme.ink)
                            .opacity(full ? 0.4 : 1)
                    }
                    .padding(.bottom, 34)
                    .frame(width: Layout.cardSize.width, height: Layout.cardSize.height)
                    .background {
                        RoundedRectangle(cornerRadius: Layout.cardCornerRadius, style: .continuous)
                            .fill(Theme.background.opacity(full ? 0.62 : 0))
                    }
                    .overlay(alignment: .topTrailing) {
                        if count > 0 {
                            Text("×\(count)")
                                .font(Theme.sans(17, .bold))
                                .foregroundStyle(.white)
                                .frame(minWidth: 38, minHeight: 34)
                                .background(Theme.accent, in: .capsule)
                                .padding(16)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .contentShape(.rect(cornerRadius: Layout.cardCornerRadius))
                }
                .buttonStyle(.plain)
                .bounce(trigger: app.flavorBounces[flavor, default: 0])
                .position(center)
                .animation(.spring(response: 0.35, dampingFraction: 0.6), value: count)
            }

            if full {
                Text("Max \(Pricing.maxScoopsPerItem) scoops per item")
                    .font(Theme.sans(18, .medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .position(x: Layout.midX, y: Layout.captionY)
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: full)
    }

    private var primaryButton: some View {
        Button { app.goForward() } label: {
            HStack(spacing: 12) {
                Text(app.step == .toppings ? "Add to Order" : "Continue")
                LucideIcon(name: app.step == .toppings ? "plus" : "arrow-right", size: 26)
            }
            .frame(minWidth: Layout.primaryButtonSize.width - 80)
            .contentTransition(.opacity)
        }
        .buttonStyle(PrimaryButtonStyle(height: Layout.primaryButtonSize.height))
        .disabled(!app.canContinue || app.isSendingToTray)
        .opacity(app.isSendingToTray ? 0 : 1)
        .animation(.easeOut(duration: 0.18), value: app.isSendingToTray)
        .animation(.easeInOut(duration: 0.25), value: app.step)
        .animation(.easeInOut(duration: 0.25), value: app.canContinue)
        .position(Layout.primaryButtonCenter)
    }

    private var tray: some View {
        ZStack {
            if app.items.isEmpty {
                Text("Your order will appear here")
                    .font(Theme.serif(20, .regular))
                    .italic()
                    .foregroundStyle(Theme.inkSecondary)
                    .position(x: Layout.trayItemsRect.midX, y: Layout.trayCenterY)
                    .transition(.opacity)
            }

            Color.clear
                .contentShape(Rectangle())
                .frame(width: Layout.trayItemsRect.width, height: Layout.trayItemsRect.height)
                .position(x: Layout.trayItemsRect.midX, y: Layout.trayItemsRect.midY)
                .gesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged {
                            if selectedTrayItem != nil { selectedTrayItem = nil }
                            app.stage.trayDragChanged($0.translation.width)
                        }
                        .onEnded { app.stage.trayDragEnded(predictedDx: $0.predictedEndTranslation.width) }
                )
                .simultaneousGesture(
                    SpatialTapGesture(coordinateSpace: .named("screen"))
                        .onEnded { value in
                            let hit = app.stage.trayItem(at: value.location)
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                selectedTrayItem = hit == selectedTrayItem ? nil : hit
                            }
                        }
                )

            if let id = selectedTrayItem, let center = app.stage.trayItemCenter(id) {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { selectedTrayItem = nil }
                    app.removeItem(id)
                } label: {
                    HStack(spacing: 8) {
                        LucideIcon(name: "trash-2", size: 20)
                        Text("Remove").font(Theme.sans(18, .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 48)
                    .background(Theme.accent, in: .capsule)
                    .shadow(color: Theme.accent.opacity(0.35), radius: 10, y: 4)
                }
                .buttonStyle(PressableStyle())
                .position(x: center.x, y: Layout.trayRect.minY - 34)
                .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
                .task(id: id) {
                    try? await Task.sleep(for: .seconds(4))
                    withAnimation(.easeOut(duration: 0.2)) { selectedTrayItem = nil }
                }
            }

            Button { app.viewOrder() } label: {
                VStack(spacing: 2) {
                    Text("View Order").font(Theme.serif(24))
                    Text(app.liveQuote.totalCents.formattedAsUSD)
                        .font(Theme.sans(19, .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(app.liveQuote.totalCents)))
                        .opacity(0.85)
                }
                .foregroundStyle(.white)
                .frame(width: Layout.viewOrderRect.width, height: Layout.viewOrderRect.height)
                .background(Theme.ink, in: .rect(cornerRadius: 28, style: .continuous))
                .opacity(app.canViewOrder ? 1 : 0.35)
                .animation(.snappy, value: app.liveQuote.totalCents)
            }
            .buttonStyle(PressableStyle(pressedScale: 0.96))
            .disabled(!app.canViewOrder)
            .position(x: Layout.viewOrderRect.midX, y: Layout.viewOrderRect.midY)

            Button { confirmingReset = true } label: {
                LucideIcon(name: "rotate-ccw", size: 26)
                    .foregroundStyle(Theme.ink)
                    .frame(width: 64, height: 64)
                    .background(Theme.card, in: .circle)
                    .overlay(Circle().strokeBorder(Theme.inkFaint, lineWidth: 1))
                    .contentShape(.circle)
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Start over")
            .position(Layout.resetCenter)
        }
        .animation(.easeInOut(duration: 0.3), value: app.items.isEmpty)
    }
}

private struct StepIndicator: View {
    let step: BuilderStep

    var body: some View {
        HStack(spacing: 14) {
            ForEach(BuilderStep.allCases, id: \.self) { item in
                HStack(spacing: 8) {
                    Text("\(item.rawValue + 1)")
                        .font(Theme.sans(14, .bold))
                        .foregroundStyle(item == step ? .white : Theme.inkSecondary)
                        .frame(width: 26, height: 26)
                        .background(item == step ? Theme.ink : Theme.inkFaint, in: .circle)
                    Text(item.title)
                        .font(Theme.sans(16, item == step ? .semibold : .regular))
                        .foregroundStyle(item == step ? Theme.ink : Theme.inkSecondary)
                }
                if item != .toppings {
                    Capsule().fill(Theme.inkFaint).frame(width: 28, height: 2)
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: step)
    }
}
