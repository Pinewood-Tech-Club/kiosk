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
                if totalCents > 0 {
                    Text(totalCents.formattedAsUSD)
                        .font(Theme.sans(19, .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(totalCents)))
                        .opacity(0.82)
                }
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

/// The builder's step navigation: a native `UISegmentedControl` (which draws its own Liquid Glass), used
/// directly because SwiftUI's segmented Picker can block a segment but can't show it as disabled.
/// Tapping a disabled segment calls `onBlockedTap` so the screen can explain why.
struct GlassStepSelector<Step: Hashable>: View {
    let steps: [Step]
    @Binding var selection: Step
    let title: (Step) -> String
    var isEnabled: (Step) -> Bool = { _ in true }
    var onSelect: (Step) -> Void = { _ in }
    var onBlockedTap: (Step) -> Void = { _ in }
    var width: CGFloat = 480

    var body: some View {
        SegmentedSteps(titles: steps.map(title),
                       selected: steps.firstIndex(of: selection) ?? 0,
                       enabled: steps.map(isEnabled),
                       onSelect: { index in
                           let step = steps[index]
                           guard step != selection else { return }
                           selection = step
                           onSelect(step)
                       })
            .frame(width: width, height: 52)
            .overlay {
                // Disabled segments swallow touches in UIKit; this catches them for the hint.
                HStack(spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        Color.clear
                            .contentShape(Rectangle())
                            .allowsHitTesting(!isEnabled(step))
                            .onTapGesture { onBlockedTap(step) }
                    }
                }
            }
            .onAppear(perform: SegmentedAppearance.apply)
    }
}

private struct SegmentedSteps: UIViewRepresentable {
    let titles: [String]
    let selected: Int
    let enabled: [Bool]
    let onSelect: (Int) -> Void

    func makeUIView(context: Context) -> UISegmentedControl {
        let control = UISegmentedControl(items: titles)
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return control
    }

    func updateUIView(_ control: UISegmentedControl, context: Context) {
        context.coordinator.onSelect = onSelect
        control.selectedSegmentIndex = selected
        for (index, isEnabled) in enabled.enumerated() where control.isEnabledForSegment(at: index) != isEnabled {
            UIView.transition(with: control, duration: 0.25, options: .transitionCrossDissolve) {
                control.setEnabled(isEnabled, forSegmentAt: index)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    final class Coordinator: NSObject {
        var onSelect: (Int) -> Void
        init(onSelect: @escaping (Int) -> Void) { self.onSelect = onSelect }

        @MainActor @objc func changed(_ control: UISegmentedControl) {
            onSelect(control.selectedSegmentIndex)
        }
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
        control.setTitleTextAttributes([
            .font: UIFont.systemFont(ofSize: 18, weight: .medium),
            .foregroundColor: UIColor(Theme.ink.opacity(0.28)),
        ], for: .disabled)
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
