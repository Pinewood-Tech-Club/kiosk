import SwiftUI

private let stepFade = AnyTransition.asymmetric(
    insertion: .opacity.animation(.easeOut(duration: 0.26).delay(0.16)),
    removal: .opacity.animation(.easeIn(duration: 0.18))
)

/// Same spring as the 3D press (`Stage.pressResponse` / `Stage.pressDamping`), so card and model move as one.
private let pressSpring = Animation.spring(response: Double(Stage.pressResponse), dampingFraction: Double(Stage.pressDamping))

private struct PressEffect: ViewModifier {
    let pressed: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed ? CGFloat(Stage.pressScale) : 1)
            .offset(y: pressed ? CGFloat(Stage.pressDepth) : 0)
            .animation(pressSpring, value: pressed)
    }
}

/// Reports press state to the app (which also drives the 3D model) instead of styling the label itself.
private struct CardPressStyle: ButtonStyle {
    let onPressChange: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in onPressChange(pressed) }
    }
}

private struct SlotPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(pressSpring, value: configuration.isPressed)
    }
}

/// Drawn beneath the RealityView so 3D models sit on their cards and on the tray / order sheet.
struct BuilderBackdrop: View {
    let app: AppModel

    var body: some View {
        ZStack {
            if app.mode == .customize, !app.itemInFlight {
                cards
                    .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.3).delay(0.22)),
                                            removal: .opacity.animation(.easeIn(duration: 0.16))))
            }

            let sheet = app.mode == .summary ? Layout.sheetRect : Layout.trayGlassRect
            GlassTrayBackground(cornerRadius: app.mode == .summary ? 44 : 40, isExpanded: app.mode == .summary)
                .frame(width: sheet.width, height: sheet.height)
                .position(x: sheet.midX, y: sheet.midY)

            if app.mode == .summary {
                SummaryView(app: app)
                    .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.3).delay(0.2)),
                                            removal: .opacity.animation(.easeIn(duration: 0.14))))
            }
        }
        .frame(width: Layout.screen.width, height: Layout.screen.height)
    }

    @ViewBuilder
    private var cards: some View {
        switch app.step {
        case .vessel:
            ZStack {
                ForEach(Vessel.allCases) { vessel in
                    CardBackground(highlighted: app.current.vessel == vessel)
                        .frame(width: Layout.cardSize.width, height: Layout.cardSize.height)
                        .modifier(PressEffect(pressed: app.pressedCards.contains(.vessel(vessel))))
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
                        .modifier(PressEffect(pressed: app.pressedCards.contains(.flavor(flavor))))
                        .position(Layout.flavorCardCenter(flavor))
                }
            }
            .transition(stepFade)
        case .toppings:
            EmptyView()
        }
    }
}

struct BuilderForeground: View {
    @Bindable var app: AppModel

    var body: some View {
        ZStack {
            if app.mode == .customize {
                customize
                    .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.3).delay(0.22)),
                                            removal: .opacity.animation(.easeIn(duration: 0.16))))
            }
        }
        .frame(width: Layout.screen.width, height: Layout.screen.height)
        .alert(alertTitle, isPresented: alertBinding, presenting: app.confirmation) { confirmation in
            Button(confirmTitle(confirmation), role: .destructive) { app.confirm(confirmation) }
            Button(cancelTitle(confirmation), role: .cancel) {}
        } message: { confirmation in
            Text(alertMessage(confirmation))
        }
    }

    private var customize: some View {
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

            if !app.itemInFlight {
                switch app.step {
                case .vessel: vesselCards.transition(stepFade)
                case .flavors: flavorCards.transition(stepFade)
                case .toppings: EmptyView()
                }
            }

            primaryButton
            tray
        }
    }

    private var header: some View {
        ZStack {
            if app.step != .vessel {
                GlassBackButton { app.goBack() }
                    .position(Layout.backButtonCenter)
                    .transition(.opacity.animation(.easeInOut(duration: 0.22)))
            }

            GlassStepSelector(steps: BuilderStep.allCases,
                              selection: Binding(get: { app.step }, set: { _ in }),
                              title: { $0.title },
                              isEnabled: { app.canJump(to: $0) },
                              onSelect: { app.jumpToStep($0) },
                              width: 420)
                .position(x: Layout.midX, y: Layout.stepIndicatorY)

            Text(title)
                .font(Theme.serif(52))
                .foregroundStyle(Theme.ink)
                .contentTransition(.opacity)
                .position(x: Layout.midX, y: Layout.titleY)

            subtitle
                .position(x: Layout.midX, y: Layout.subtitleY + 10)
        }
        .animation(.easeInOut(duration: 0.3), value: app.step)
        .animation(.easeInOut(duration: 0.3), value: app.isEditing)
    }

    private var title: String {
        switch app.step {
        case .vessel: "Cup or cone?"
        case .flavors: "Pick your scoops"
        case .toppings: "Toppings"
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        if let editingID = app.editingID, let index = app.editingIndex {
            HStack(spacing: 28) {
                Text("Editing item \(index + 1)")
                    .font(Theme.serif(22, .regular))
                    .italic()
                    .foregroundStyle(Theme.ink.opacity(0.75))
                Button { app.finishEditing(then: .newItem) } label: {
                    HStack(spacing: 7) {
                        LucideIcon(name: "check", size: 18)
                        Text("Done")
                    }
                }
                .buttonStyle(.glassCTA(height: 46, fontSize: 18))
                Button { app.requestDelete(editingID) } label: {
                    HStack(spacing: 7) {
                        LucideIcon(name: "trash-2", size: 18)
                        Text("Remove")
                    }
                }
                .buttonStyle(.glassSecondary(height: 46, fontSize: 18))
            }
            .transition(.opacity)
        } else if app.step == .toppings {
            Text("Coming soon")
                .font(Theme.serif(22, .regular))
                .italic()
                .foregroundStyle(Theme.ink.opacity(0.6))
                .transition(.opacity)
        }
    }

    private func card<Label: View>(_ key: CardKey, center: CGPoint, action: @escaping () -> Void,
                                   @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            label()
                .frame(width: Layout.cardSize.width, height: Layout.cardSize.height)
                .contentShape(.rect(cornerRadius: Layout.cardCornerRadius))
        }
        .buttonStyle(CardPressStyle { app.setPressed(key, $0) })
        .modifier(PressEffect(pressed: app.pressedCards.contains(key)))
        .position(center)
    }

    private var vesselCards: some View {
        ZStack {
            ForEach(Vessel.allCases) { vessel in
                card(.vessel(vessel), center: Layout.vesselCardCenter(vessel), action: { app.selectVessel(vessel) }) {
                    VStack(spacing: 4) {
                        Spacer()
                        Text(vessel.title)
                            .font(Theme.serif(26))
                            .foregroundStyle(Theme.ink)
                        Text(vessel.priceLabel)
                            .font(Theme.sans(18, .medium))
                            .foregroundStyle(Theme.inkSecondary)
                    }
                    .padding(.bottom, 22)
                }
            }
        }
    }

    private var flavorCards: some View {
        let full = app.current.scoopCount >= Pricing.maxScoopsPerItem
        return ZStack {
            ForEach(Flavor.allCases) { flavor in
                let count = app.count(of: flavor)
                card(.flavor(flavor), center: Layout.flavorCardCenter(flavor), action: { app.addScoop(flavor) }) {
                    VStack(spacing: 4) {
                        Spacer()
                        Text(flavor.title)
                            .font(Theme.serif(25))
                            .foregroundStyle(Theme.ink)
                        Text(full ? "3 scoops max" : "+\(app.nextScoopCents.formattedAsUSD)")
                            .font(Theme.sans(18, .medium))
                            .monospacedDigit()
                            .foregroundStyle(Theme.inkSecondary)
                            .contentTransition(.numericText(value: Double(app.nextScoopCents)))
                    }
                    .padding(.bottom, 22)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        RoundedRectangle(cornerRadius: Layout.cardCornerRadius, style: .continuous)
                            .fill(Theme.background.opacity(full ? 0.55 : 0))
                    }
                    .overlay(alignment: .topTrailing) {
                        if count > 0 {
                            CountBadge(count: count)
                                .padding(16)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                }
                .overlay(alignment: .topLeading) {
                    if count > 0 {
                        GlassIconButton(icon: "minus", size: 52, iconSize: 22) { app.removeScoop(flavor) }
                            .accessibilityLabel("Remove a \(flavor.title) scoop")
                            .padding(10)
                            .offset(x: Layout.flavorCardCenter(flavor).x - Layout.cardSize.width / 2,
                                    y: Layout.flavorCardCenter(flavor).y - Layout.cardSize.height / 2)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: count)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: full)
        .animation(.easeInOut(duration: 0.25), value: app.nextScoopCents)
    }

    private var primaryButton: some View {
        Button { app.goForward() } label: {
            HStack(spacing: 12) {
                Text(primaryTitle)
                LucideIcon(name: app.step == .toppings ? (app.isEditing ? "check" : "plus") : "arrow-right", size: 26)
            }
            .frame(minWidth: Layout.primaryButtonSize.width - 100)
            .contentTransition(.opacity)
        }
        .buttonStyle(.glassCTA(height: Layout.primaryButtonSize.height))
        .disabled(!app.canContinue || app.itemInFlight)
        .opacity(app.itemInFlight ? 0 : 1)
        .animation(.easeOut(duration: 0.18), value: app.itemInFlight)
        .animation(.easeInOut(duration: 0.25), value: app.step)
        .position(Layout.primaryButtonCenter)
    }

    private var primaryTitle: String {
        guard app.step == .toppings else { return "Continue" }
        return app.isEditing ? "Done" : "Add to Order"
    }

    private var tray: some View {
        ZStack {
            if app.items.isEmpty {
                Text("Your order")
                    .font(Theme.serif(20, .regular))
                    .foregroundStyle(Theme.inkSecondary.opacity(0.7))
                    .position(x: Layout.trayItemsRect.midX, y: Layout.trayCenterY)
                    .transition(.opacity)
            }

            Color.clear
                .contentShape(Rectangle())
                .frame(width: Layout.trayItemsRect.width, height: Layout.trayItemsRect.height)
                .position(x: Layout.trayItemsRect.midX, y: Layout.trayItemsRect.midY)
                .gesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { app.stage.trayDragChanged($0.translation.width) }
                        .onEnded { app.stage.trayDragEnded(predictedDx: $0.predictedEndTranslation.width) }
                )
                .simultaneousGesture(
                    SpatialTapGesture(coordinateSpace: .global)
                        .onEnded { value in
                            if let id = app.stage.trayItem(at: value.location) { app.tapTrayItem(id) }
                        }
                )

            if let editingID = app.editingID {
                let _ = app.trayLayoutVersion
                if let center = app.stage.trayItemCenter(editingID), Layout.trayItemsRect.contains(center) {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(Theme.ink.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                        .frame(width: Layout.trayPitch - 18, height: Layout.trayItemsRect.height - 30)
                        .position(center)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }

            newItemSlot

            GlassViewOrderButton(totalCents: app.liveQuote.totalCents) { app.viewOrder() }
                .disabled(!app.canViewOrder)
                .position(x: Layout.viewOrderRect.midX, y: Layout.viewOrderRect.midY)

            GlassIconButton(icon: "rotate-ccw") { app.requestStartOver() }
                .accessibilityLabel("Start over")
                .position(Layout.resetCenter)
        }
        .animation(.easeInOut(duration: 0.3), value: app.items.isEmpty)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: app.editingID)
    }

    /// Pinned first slot of the tray. Not glass: it sits on the tray's glass.
    private var newItemSlot: some View {
        let enabled = app.canStartNewItem
        return Button { app.startNewItem() } label: {
            VStack(spacing: 6) {
                LucideIcon(name: "plus", size: 30)
                Text("New item").font(Theme.sans(16, .semibold))
            }
            .foregroundStyle(Theme.ink)
            .frame(width: Layout.trayNewItemRect.width, height: Layout.trayNewItemRect.height)
            .background(Theme.ink.opacity(0.07), in: .rect(cornerRadius: 26, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(Theme.ink.opacity(0.22), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            }
            .contentShape(.rect(cornerRadius: 26))
        }
        .buttonStyle(SlotPressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .animation(.easeInOut(duration: 0.25), value: enabled)
        .accessibilityLabel("Start a new item")
        .position(x: Layout.trayNewItemRect.midX, y: Layout.trayNewItemRect.midY)
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { app.confirmation != nil }, set: { if !$0 { app.confirmation = nil } })
    }

    private var alertTitle: String {
        switch app.confirmation {
        case .removeEmptyEdit: "Remove item \((app.editingIndex ?? 0) + 1)?"
        case .deleteItem: "Remove this item?"
        case .startOver: "Start over?"
        case nil: ""
        }
    }

    private func confirmTitle(_ confirmation: AppModel.Confirmation) -> String {
        switch confirmation {
        case .removeEmptyEdit: "Remove"
        case .deleteItem: "Remove"
        case .startOver: "Start Over"
        }
    }

    private func cancelTitle(_ confirmation: AppModel.Confirmation) -> String {
        if case .removeEmptyEdit = confirmation { return "Keep Editing" }
        return "Cancel"
    }

    private func alertMessage(_ confirmation: AppModel.Confirmation) -> String {
        switch confirmation {
        case .removeEmptyEdit: "It has no scoops left, so it can't stay in your order."
        case .deleteItem: "It will be taken out of your order."
        case .startOver: "This clears your whole order."
        }
    }
}
