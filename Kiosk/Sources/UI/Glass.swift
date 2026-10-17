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
        /// The primary look over a cream backing, so it stays legible over video even when the system glass
        /// setting is at its clearest.
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
                .foregroundStyle(kind == .secondary ? Theme.text : Theme.onText)
                .padding(.horizontal, horizontalPadding)
                .frame(minHeight: height - 2 * Self.verticalInset)
        }
        .buttonBorderShape(shape)
        .controlSize(.large)
        .glassMorph(morph)

        switch kind {
        case .primary: button.buttonStyle(.glassProminent).tint(Theme.text)
        case .secondary: button.buttonStyle(.glass)
        case .onMedia:
            button.buttonStyle(.glassProminent).tint(Theme.text)
                .background(Capsule().fill(Theme.text.opacity(0.78)).padding(2))
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
                .foregroundStyle(prominent ? Theme.onText : Theme.text)
                .frame(width: width.map { $0 - 2 * KioskGlassButtonStyle.horizontalInset } ?? size - 2 * KioskGlassButtonStyle.verticalInset,
                       height: size - 2 * KioskGlassButtonStyle.verticalInset)
        }
        .buttonBorderShape(shape)
        .controlSize(.large)
        .glassMorph(morph)

        if prominent {
            button.buttonStyle(.glassProminent).tint(Theme.text)
        } else {
            button.buttonStyle(.glass)
        }
    }
}

struct GlassViewOrderButton: View {
    let totalCents: Int
    let itemCount: Int
    var size = Layout.viewOrderRect.size
    var cornerRadius = Layout.trayTileRadius
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text("View Order").font(Theme.serif(24))
                ZStack(alignment: .trailing) {
                    Text("$00.00").hidden()
                    Text(totalCents.formattedAsUSD)
                        .contentTransition(.numericText(value: Double(totalCents)))
                }
                .font(Theme.sans(19, .semibold))
                .monospacedDigit()
                .opacity(0.82)
                Text(itemCount == 1 ? "1 item" : "\(itemCount) items")
                    .font(Theme.sans(14, .medium))
                    .monospacedDigit()
                    .opacity(0.6)
                    .contentTransition(.numericText(value: Double(itemCount)))
            }
            .foregroundStyle(Theme.onText)
            .frame(width: size.width - 2 * KioskGlassButtonStyle.horizontalInset, height: size.height - 2 * KioskGlassButtonStyle.verticalInset)
            .animation(.snappy, value: totalCents)
            .animation(.snappy, value: itemCount)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.roundedRectangle(radius: cornerRadius))
        .controlSize(.large)
        .tint(Theme.text)
    }
}

/// The builder's step navigation: a native `UISegmentedControl`, so it keeps the system Liquid Glass
/// interaction (press, lift the selection into a lens, slide it between steps, snap on release).
/// Completed steps carry a check, the current one sits on the cream selection, and steps that can't be
/// reached yet are disabled; tapping one calls `onBlockedTap` so the screen can explain why.
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

    var body: some View {
        let selected = steps.firstIndex(of: selection) ?? 0
        StepSegments(segments: steps.enumerated().map { index, step in
                         StepSegments.Segment(title: title(step), number: index + 1, selected: index == selected,
                                              enabled: isEnabled(step),
                                              complete: isComplete(step) && index != selected)
                     },
                     selected: selected,
                     onSelect: { onSelect(steps[$0]) },
                     onBlockedTap: { onBlockedTap(steps[$0]) })
            .frame(width: CGFloat(steps.count) * segmentWidth + 2 * inset, height: height)
    }
}

private struct StepSegments: UIViewRepresentable {
    struct Segment: Equatable {
        let title: String
        let number: Int
        let selected: Bool
        let enabled: Bool
        let complete: Bool
    }

    let segments: [Segment]
    let selected: Int
    let onSelect: (Int) -> Void
    let onBlockedTap: (Int) -> Void

    func makeUIView(context: Context) -> StepSegmentedControl {
        let control = StepSegmentedControl()
        control.selectedSegmentTintColor = UIColor(Theme.text)
        control.setTitleTextAttributes(StepSegmentedControl.attributes(.medium, Theme.text), for: .normal)
        control.setTitleTextAttributes(StepSegmentedControl.attributes(.semibold, Theme.onText), for: .selected)
        control.setTitleTextAttributes(StepSegmentedControl.attributes(.medium, Theme.text.opacity(0.4)), for: .disabled)
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)

        let blockedTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.blockedTap(_:)))
        blockedTap.cancelsTouchesInView = false
        blockedTap.delaysTouchesEnded = false
        blockedTap.delegate = context.coordinator
        control.addGestureRecognizer(blockedTap)

        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentHuggingPriority(.defaultLow, for: .vertical)
        return control
    }

    func updateUIView(_ control: StepSegmentedControl, context: Context) {
        context.coordinator.parent = self
        if control.segments != segments {
            control.apply(segments)
        }
        if control.selectedSegmentIndex != selected {
            control.selectedSegmentIndex = selected
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: StepSegments
        init(parent: StepSegments) { self.parent = parent }

        @MainActor @objc func changed(_ control: StepSegmentedControl) {
            parent.onSelect(control.selectedSegmentIndex)
            // The app can refuse a step (an item in flight); put the selection back if it didn't move.
            DispatchQueue.main.async { [weak control] in
                guard let control, control.selectedSegmentIndex != self.parent.selected else { return }
                control.selectedSegmentIndex = self.parent.selected
            }
        }

        @MainActor @objc func blockedTap(_ recognizer: UITapGestureRecognizer) {
            guard let control = recognizer.view as? StepSegmentedControl,
                  let index = control.disabledSegment(at: recognizer.location(in: control)) else { return }
            parent.onBlockedTap(index)
        }

        @MainActor func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let control = recognizer.view as? StepSegmentedControl else { return false }
            return control.disabledSegment(at: touch.location(in: control)) != nil
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

final class StepSegmentedControl: UISegmentedControl {
    fileprivate private(set) var segments: [StepSegments.Segment] = []

    fileprivate static func attributes(_ weight: Theme.SerifWeight, _ color: Color) -> [NSAttributedString.Key: Any] {
        [.font: UIFont(name: weight.rawValue, size: 22) ?? .systemFont(ofSize: 22), .foregroundColor: UIColor(color)]
    }

    fileprivate func apply(_ new: [StepSegments.Segment]) {
        let selected = selectedSegmentIndex
        while numberOfSegments < new.count { insertSegment(withTitle: nil, at: numberOfSegments, animated: false) }
        while numberOfSegments > new.count { removeSegment(at: numberOfSegments - 1, animated: false) }
        for (index, segment) in new.enumerated() {
            let old = segments.indices.contains(index) ? segments[index] : nil
            guard old != segment else { continue }
            let update = { [self] in
                let image = Self.render(segment)
                image.accessibilityLabel = segment.title
                setImage(image, forSegmentAt: index)
                setEnabled(segment.enabled, forSegmentAt: index)
            }
            // A cross-dissolve snapshots the whole control, so a selection change would lose the native slide.
            if old == nil || old?.enabled == segment.enabled {
                update()
            } else {
                UIView.transition(with: self, duration: 0.25, options: .transitionCrossDissolve, animations: update)
            }
        }
        segments = new
        selectedSegmentIndex = selected
    }

    func disabledSegment(at point: CGPoint) -> Int? {
        guard bounds.contains(point), numberOfSegments > 0 else { return nil }
        let index = min(Int(point.x / (bounds.width / CGFloat(numberOfSegments))), numberOfSegments - 1)
        return isEnabledForSegment(at: index) ? nil : index
    }

    /// A segment shows an image or a title, never both, so the step's symbol and label are drawn together
    /// as one template image, which the control tints per state like a title.
    private static func render(_ segment: StepSegments.Segment) -> UIImage {
        let weight: Theme.SerifWeight = segment.selected ? .semibold : .medium
        let text = NSAttributedString(string: segment.title, attributes: [
            .font: UIFont(name: weight.rawValue, size: 22) ?? .systemFont(ofSize: 22),
        ])
        let symbolName = segment.complete ? "checkmark.circle.fill"
            : segment.selected ? "\(segment.number).circle.fill" : "\(segment.number).circle"
        let symbol = UIImage(systemName: symbolName,
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: segment.complete ? .semibold : .regular))
        let side: CGFloat = 28, gap: CGFloat = 10
        let textSize = text.size()
        let size = CGSize(width: ceil(side + gap + textSize.width), height: ceil(max(side, textSize.height)))
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            let alpha: CGFloat = segment.complete || segment.selected ? 1 : 0.55
            symbol?.withTintColor(UIColor.black.withAlphaComponent(alpha))
                .draw(in: CGRect(x: 0, y: (size.height - side) / 2, width: side, height: side))
            text.draw(at: CGPoint(x: side + gap, y: (size.height - textSize.height) / 2))
        }
        return image.withRenderingMode(.alwaysTemplate)
    }
}

/// The tray of 3D minis: a glass well drawn beneath the RealityView so the minis render on it. Expanded,
/// it becomes the order sheet and turns solid, so the order's text and glass buttons sit on an opaque
/// surface rather than on glass.
struct GlassTrayBackground: View {
    var cornerRadius: CGFloat = 40
    /// 0 is the tray's clear glass, 1 the order sheet's opaque surface.
    var fill: Double = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(Theme.surface)
            .opacity(fill)
            .glassEffect(.regular, in: shape)
            .overlay { shape.strokeBorder(Theme.hairline, lineWidth: 1).opacity(fill) }
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
                shape.strokeBorder(Theme.text.opacity(isFocused ? 0.7 : 0), lineWidth: 2)
                    .allowsHitTesting(false)
            }
            .animation(.easeInOut(duration: 0.2), value: isFocused)
    }
}
