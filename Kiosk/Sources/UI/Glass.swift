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
    var iconSize: CGFloat = 26
    var morph: GlassMorph?
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            LucideIcon(name: icon, size: iconSize)
                .foregroundStyle(prominent ? Color.white : Theme.ink)
                .frame(width: size - 2 * KioskGlassButtonStyle.verticalInset, height: size - 2 * KioskGlassButtonStyle.verticalInset)
        }
        .buttonBorderShape(.circle)
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text("View Order").font(Theme.serif(24))
                Text(totalCents.formattedAsUSD)
                    .font(Theme.sans(19, .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(totalCents)))
                    .opacity(0.82)
            }
            .foregroundStyle(.white)
            .frame(width: size.width - 36, height: size.height - 2 * KioskGlassButtonStyle.verticalInset)
            .animation(.snappy, value: totalCents)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(Theme.ink)
    }
}

struct GlassStepSelector<Step: Hashable>: View {
    let steps: [Step]
    @Binding var selection: Step
    let title: (Step) -> String
    var isEnabled: (Step) -> Bool = { _ in true }
    var onSelect: (Step) -> Void = { _ in }
    var width: CGFloat = 480

    var body: some View {
        Picker("Step", selection: Binding(get: { selection }, set: { step in
            guard step != selection else { return }
            selection = step
            onSelect(step)
        })) {
            ForEach(steps, id: \.self) { step in
                Text(title(step))
                    .tag(step)
                    .selectionDisabled(!isEnabled(step))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.extraLarge)
        .frame(width: width)
        .onAppear(perform: SegmentedAppearance.apply)
    }
}

@MainActor
private enum SegmentedAppearance {
    private static var applied = false

    static func apply() {
        guard !applied else { return }
        applied = true
        let control = UISegmentedControl.appearance()
        control.selectedSegmentTintColor = UIColor(Theme.ink)
        control.setTitleTextAttributes([
            .font: UIFont.systemFont(ofSize: 18, weight: .medium),
            .foregroundColor: UIColor(Theme.ink.opacity(0.78)),
        ], for: .normal)
        control.setTitleTextAttributes([
            .font: UIFont.systemFont(ofSize: 18, weight: .semibold),
            .foregroundColor: UIColor.white,
        ], for: .selected)
    }
}

/// One glass surface for the tray of 3D minis. Draw it beneath the RealityView so the minis render on
/// it, and put the View Order and reset buttons beside it rather than on it (no glass on glass).
struct GlassTrayBackground: View {
    var cornerRadius: CGFloat = 40

    var body: some View {
        Color.clear
            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius, style: .continuous))
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
