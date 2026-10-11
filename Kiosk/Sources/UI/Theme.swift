import SwiftUI

enum Theme {
    static let background = Color(red: 0.984, green: 0.969, blue: 0.949)
    static let backgroundDeep = Color(red: 0.957, green: 0.933, blue: 0.902)
    static let card = Color.white
    static let ink = Color(red: 0.235, green: 0.161, blue: 0.125)
    static let inkSecondary = Color(red: 0.235, green: 0.161, blue: 0.125).opacity(0.62)
    static let inkFaint = Color(red: 0.235, green: 0.161, blue: 0.125).opacity(0.12)
    static let accent = Color(red: 0.882, green: 0.478, blue: 0.424)
    static let accentDeep = Color(red: 0.792, green: 0.353, blue: 0.325)
    static let success = Color(red: 0.31, green: 0.62, blue: 0.47)

    // Type system: Noto Serif for every word a customer reads (titles, buttons, labels, hints) and for headline
    // amounts. The system sans is reserved for small figures and fine print: card prices, counts, timers, dates
    // and payment IDs.
    // Noto Serif ships without an italic face, so `.italic()` has no effect on it.
    enum SerifWeight: String {
        case regular = "NotoSerif-Regular"
        case medium = "NotoSerif-Medium"
        case semibold = "NotoSerif-SemiBold"
        case bold = "NotoSerif-Bold"
    }

    static func serif(_ size: CGFloat, _ weight: SerifWeight = .semibold) -> Font {
        .custom(weight.rawValue, fixedSize: size)
    }

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static let cardShadow = Color(red: 0.35, green: 0.22, blue: 0.12).opacity(0.10)
}

/// The cream page with faint vanilla, strawberry and pistachio glows, so Liquid Glass has some color
/// to bend at its edges.
struct AmbientBackdrop: View {
    var body: some View {
        MeshGradient(
            width: 3, height: 3,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.55, 0.45], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ],
            colors: [
                Color(red: 0.996, green: 0.957, blue: 0.886), Theme.background, Color(red: 0.992, green: 0.910, blue: 0.886),
                Theme.background, Theme.background, Theme.background,
                Color(red: 0.925, green: 0.953, blue: 0.898), Theme.background, Color(red: 0.984, green: 0.902, blue: 0.906),
            ],
            smoothsColors: true
        )
    }
}

struct LucideIcon: View {
    let name: String
    var size: CGFloat = 24

    var body: some View {
        Image("lucide-\(name)")
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

/// Solid card behind a vessel or flavor; the 3D model renders on top of it, so keep it opaque, not glass.
struct CardBackground: View {
    var highlighted = false
    var dimmed = false

    var body: some View {
        RoundedRectangle(cornerRadius: Layout.cardCornerRadius, style: .continuous)
            .fill(Theme.card)
            .shadow(color: Theme.cardShadow, radius: 22, y: 10)
            .overlay {
                RoundedRectangle(cornerRadius: Layout.cardCornerRadius, style: .continuous)
                    .strokeBorder(highlighted ? Theme.ink : Theme.inkFaint, lineWidth: highlighted ? 3 : 1)
            }
            .opacity(dimmed ? 0.55 : 1)
            .animation(.easeInOut(duration: 0.25), value: highlighted)
            .animation(.easeInOut(duration: 0.25), value: dimmed)
    }
}

struct CountBadge: View {
    let count: Int

    var body: some View {
        Text("×\(count)")
            .font(Theme.sans(17, .bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .contentTransition(.numericText(value: Double(count)))
            .frame(minWidth: 42, minHeight: 34)
            .background(Theme.ink, in: .capsule)
            .animation(.snappy, value: count)
    }
}
