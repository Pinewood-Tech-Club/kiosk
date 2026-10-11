import SwiftUI

/// Pass to a glass component to morph it with other glass in the same `GlassEffectContainer`.
struct GlassMorph {
    let id: String
    let namespace: Namespace.ID
}

extension View {
    @ViewBuilder
    func glassMorph(_ morph: GlassMorph?) -> some View {
        if let morph {
            glassEffectID(morph.id, in: morph.namespace)
        } else {
            self
        }
    }
}

struct KioskGlassButtonStyle: PrimitiveButtonStyle {
    enum Kind {
        case primary
        case secondary
        /// Cream prominent glass with ink text over a cream backing, legible over video even when the
        /// system glass setting is at its clearest.
        case onMedia
    }

    var kind: Kind = .primary
    var height: CGFloat = 80
    var fontSize: CGFloat = 28
    var horizontalPadding: CGFloat = 24
    var shape: ButtonBorderShape = .capsule
    var morph: GlassMorph?

    func makeBody(configuration: Configuration) -> some View {
        let button = Button(role: configuration.role) {
            configuration.trigger()
        } label: {
            configuration.label
                .font(Theme.serif(fontSize, kind == .secondary ? .medium : .semibold))
                .foregroundStyle(kind == .primary ? Color.white : Theme.ink)
                .padding(.horizontal, horizontalPadding)
                .frame(minHeight: height - 2 * Self.verticalInset)
        }
        .buttonBorderShape(shape)
        .controlSize(.large)
        .glassMorph(morph)

        switch kind {
        case .primary: button.buttonStyle(.glassProminent).tint(Theme.ink)
        case .secondary: button.buttonStyle(.glass)
        case .onMedia:
            button.buttonStyle(.glassProminent).tint(Theme.background)
                .background(Capsule().fill(Theme.background.opacity(0.78)).padding(2))
        }
    }

    /// Padding that `.glass` / `.glassProminent` put above and below the label at `.large`.
    static let verticalInset: CGFloat = 7
    static let horizontalInset: CGFloat = 18
}

extension PrimitiveButtonStyle where Self == KioskGlassButtonStyle {
    static func glassCTA(height: CGFloat = 80, fontSize: CGFloat = 28, morph: GlassMorph? = nil) -> KioskGlassButtonStyle {
        KioskGlassButtonStyle(kind: .primary, height: height, fontSize: fontSize, horizontalPadding: 32, morph: morph)
    }

    static func glassSecondary(height: CGFloat = 60, fontSize: CGFloat = 22, morph: GlassMorph? = nil) -> KioskGlassButtonStyle {
        KioskGlassButtonStyle(kind: .secondary, height: height, fontSize: fontSize, horizontalPadding: 10, morph: morph)
    }

    static func glassOnMedia(height: CGFloat = 112, fontSize: CGFloat = 46) -> KioskGlassButtonStyle {
        KioskGlassButtonStyle(kind: .onMedia, height: height, fontSize: fontSize, horizontalPadding: 40)
    }
}

struct GlassBackButton: View {
    var title = "Back"
    var morph: GlassMorph?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                LucideIcon(name: "chevron-left", size: 26)
                Text(title)
            }
        }
        .buttonStyle(.glassSecondary(height: 60, fontSize: 22, morph: morph))
    }
}

struct GlassIconButton: View {
    let icon: String
    var prominent = false
    var size: CGFloat = 64
    /// Only for non-circular shapes; a circle is always `size` wide.
    var width: CGFloat?
    var iconSize: CGFloat = 26
    var shape: ButtonBorderShape = .circle
    var morph: GlassMorph?
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            LucideIcon(name: icon, size: iconSize)
                .foregroundStyle(prominent ? Color.white : Theme.ink)
                .frame(width: width.map { $0 - 2 * KioskGlassButtonStyle.horizontalInset } ?? size - 2 * KioskGlassButtonStyle.verticalInset,
                       height: size - 2 * KioskGlassButtonStyle.verticalInset)
        }
        .buttonBorderShape(shape)
        .controlSize(.large)
        .glassMorph(morph)

        if prominent {
            button.buttonStyle(.glassProminent).tint(Theme.ink)
        } else {
            button.buttonStyle(.glass)
        }
    }
}

struct GlassViewOrderButton: View {
    let totalCents: Int
    var size = Layout.viewOrderRect.size
    var cornerRadius = Layout.trayTileRadius
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text("View Order").font(Theme.serif(24))
                if totalCents > 0 {
                    Text(totalCents.formattedAsUSD)
                        .font(Theme.sans(19, .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(totalCents)))
                        .opacity(0.82)
                }
            }
            .foregroundStyle(.white)
            .frame(width: size.width - 2 * KioskGlassButtonStyle.horizontalInset, height: size.height - 2 * KioskGlassButtonStyle.verticalInset)
            .animation(.snappy, value: totalCents)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.roundedRectangle(radius: cornerRadius))
        .controlSize(.large)
        .tint(Theme.ink)
    }
}

/// The builder's step navigation, drawn as a progress bar: completed steps carry a check, the current one
/// sits on an ink capsule, and steps that can't be reached yet are faded. Tapping a reachable step jumps to
/// it; tapping a faded one calls `onBlockedTap` so the screen can explain why.
struct GlassStepSelector<Step: Hashable>: View {
    let steps: [Step]
    let selection: Step
    let title: (Step) -> String
    var isEnabled: (Step) -> Bool = { _ in true }
    var isComplete: (Step) -> Bool = { _ in false }
    var onSelect: (Step) -> Void = { _ in }
    var onBlockedTap: (Step) -> Void = { _ in }
    var segmentWidth: CGFloat = Self.segmentWidth
    var height: CGFloat = 68

    static var segmentWidth: CGFloat { 192 }
    private let inset: CGFloat = 6
    @Namespace private var indicator

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                segment(number: index + 1, step: step)
            }
        }
        .padding(inset)
        .glassEffect(.regular.interactive(), in: .capsule)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: selection)
    }

    private func segment(number: Int, step: Step) -> some View {
        let selected = step == selection
        let enabled = isEnabled(step)
        return Button {
            if !enabled {
                onBlockedTap(step)
            } else if !selected {
                onSelect(step)
            }
        } label: {
            HStack(spacing: 10) {
                StepMarker(number: number, selected: selected, complete: isComplete(step) && !selected)
                Text(title(step))
                    .font(Theme.serif(22, selected ? .semibold : .medium))
            }
            .foregroundStyle(selected ? Color.white : Theme.ink)
            .opacity(enabled || selected ? 1 : 0.32)
            .frame(width: segmentWidth, height: height - 2 * inset)
            .background {
                if selected {
                    Capsule()
                        .fill(Theme.ink)
                        .matchedGeometryEffect(id: "indicator", in: indicator)
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(StepPressStyle())
        .animation(.easeInOut(duration: 0.25), value: enabled)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(enabled ? "" : "Not available yet")
    }
}

private struct StepMarker: View {
    let number: Int
    let selected: Bool
    let complete: Bool

    var body: some View {
        ZStack {
            if complete {
                Circle().fill(Theme.ink)
                LucideIcon(name: "check", size: 16).foregroundStyle(.white)
            } else if selected {
                Circle().fill(.white)
                numeral.foregroundStyle(Theme.ink)
            } else {
                Circle().strokeBorder(Theme.ink.opacity(0.55), lineWidth: 1.5)
                numeral
            }
        }
        .frame(width: 28, height: 28)
        .animation(.easeInOut(duration: 0.25), value: complete)
    }

    private var numeral: some View {
        Text("\(number)").font(Theme.sans(15, .semibold)).monospacedDigit()
    }
}

private struct StepPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// The tray of 3D minis: a glass well drawn beneath the RealityView so the minis render on it. Expanded,
/// it becomes the order sheet and turns solid, so the order's text and glass buttons sit on paper rather
/// than on glass.
struct GlassTrayBackground: View {
    var cornerRadius: CGFloat = 40
    var isExpanded = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(Theme.background)
            .opacity(isExpanded ? 1 : 0)
            .glassEffect(.regular, in: shape)
            .shadow(color: Theme.cardShadow.opacity(isExpanded ? 1 : 0), radius: 30, y: -6)
    }
}

extension View {
    /// Liquid Glass for a text field. Apply to the field itself so the text renders above the glass.
    func glassField(isFocused: Bool, cornerRadius: CGFloat, morph: GlassMorph? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .glassEffect(.regular.interactive(), in: shape)
            .glassMorph(morph)
            .overlay {
                shape.strokeBorder(Theme.ink.opacity(isFocused ? 0.7 : 0), lineWidth: 2)
                    .allowsHitTesting(false)
            }
            .animation(.easeInOut(duration: 0.2), value: isFocused)
    }
}
