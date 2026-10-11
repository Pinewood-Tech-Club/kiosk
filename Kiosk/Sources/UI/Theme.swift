import SwiftUI

enum Theme {
    static let background = Color.black
    static let surface = Color(red: 0.110, green: 0.094, blue: 0.082)
    static let text = Color(red: 0.969, green: 0.937, blue: 0.894)
    static let textSecondary = text.opacity(0.68)
    static let hairline = text.opacity(0.16)
    static let onText = Color.black
    static let accent = Color(red: 0.941, green: 0.565, blue: 0.502)
    static let success = Color(red: 0.365, green: 0.733, blue: 0.549)

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
            .fill(Theme.surface)
            .overlay {
                RoundedRectangle(cornerRadius: Layout.cardCornerRadius, style: .continuous)
                    .strokeBorder(highlighted ? Theme.text : Theme.hairline, lineWidth: highlighted ? 3 : 1)
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
            .foregroundStyle(Theme.onText)
            .contentTransition(.numericText(value: Double(count)))
            .frame(minWidth: 42, minHeight: 34)
            .background(Theme.text, in: .capsule)
            .animation(.snappy, value: count)
    }
}
