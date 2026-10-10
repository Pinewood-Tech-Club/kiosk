import SwiftUI

enum Theme {
    static let background = Color(red: 0.984, green: 0.969, blue: 0.949)
    static let backgroundDeep = Color(red: 0.957, green: 0.933, blue: 0.902)
    static let card = Color.white
    static let ink = Color(red: 0.235, green: 0.161, blue: 0.125)
    static let inkSecondary = Color(red: 0.235, green: 0.161, blue: 0.125).opacity(0.62)
    static let inkFaint = Color(red: 0.235, green: 0.161, blue: 0.125).opacity(0.12)
    static let accent = Color(red: 0.882, green: 0.478, blue: 0.424)
    static let success = Color(red: 0.31, green: 0.62, blue: 0.47)

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

struct PrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 72
    var fontSize: CGFloat = 28
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.serif(fontSize))
            .foregroundStyle(.white)
            .padding(.horizontal, 40)
            .frame(minHeight: height)
            .background(Theme.ink, in: .capsule)
            .shadow(color: Theme.ink.opacity(isEnabled ? 0.22 : 0), radius: 18, y: 8)
            .opacity(isEnabled ? 1 : 0.3)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.62), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = 60
    var fontSize: CGFloat = 22

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.serif(fontSize, .medium))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 28)
            .frame(minHeight: height)
            .background(Theme.card, in: .capsule)
            .overlay(Capsule().strokeBorder(Theme.inkFaint, lineWidth: 1.5))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.62), value: configuration.isPressed)
    }
}

struct PressableStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .animation(.spring(response: 0.26, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct CardBackground: View {
    var highlighted = false

    var body: some View {
        RoundedRectangle(cornerRadius: Layout.cardCornerRadius, style: .continuous)
            .fill(Theme.card)
            .shadow(color: Theme.cardShadow, radius: 22, y: 10)
            .overlay {
                RoundedRectangle(cornerRadius: Layout.cardCornerRadius, style: .continuous)
                    .strokeBorder(highlighted ? Theme.ink : Theme.inkFaint, lineWidth: highlighted ? 3 : 1)
            }
    }
}

extension View {
    func bounce(trigger: Int) -> some View {
        keyframeAnimator(initialValue: 1.0, trigger: trigger) { content, scale in
            content.scaleEffect(scale)
        } keyframes: { _ in
            CubicKeyframe(0.9, duration: 0.11)
            SpringKeyframe(1.0, duration: 0.35, spring: .init(response: 0.32, dampingRatio: 0.45))
        }
    }
}
