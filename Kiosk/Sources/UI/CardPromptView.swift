import SwiftUI

/// Covers the screen while a payment waits for a card. Square's own screens appear on top once a card
/// touches the reader.
struct CardPromptLayer: View {
    let square: SquareService

    var body: some View {
        ZStack {
            if let prompt = square.cardPrompt {
                CardPromptView(
                    prompt: prompt,
                    onCancel: { square.cancelCardPrompt() },
                    onReady: { square.keepWaitingForCard() }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: square.cardPrompt == nil)
        .allowsHitTesting(square.cardPrompt != nil)
    }
}

struct CardPromptView: View {
    let prompt: CardPrompt
    let onCancel: () -> Void
    let onReady: () -> Void

    private var isStillThere: Bool { prompt.stage == .stillThere }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Text(prompt.amountCents.formattedAsUSD)
                .font(Theme.serif(104, .bold))
                .foregroundStyle(Theme.text)
                .monospacedDigit()

            CardTapHint(isActive: !isStillThere)
                .frame(width: 420, height: 440)
                .padding(.vertical, 28)
                .opacity(isStillThere ? 0.35 : 1)

            ZStack(alignment: .top) {
                waitingText.opacity(isStillThere ? 0 : 1)
                stillThereText.opacity(isStillThere ? 1 : 0)
            }
            .frame(height: 150, alignment: .top)

            Spacer()

            ZStack(alignment: .bottom) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.glassSecondary(height: 76, fontSize: 26))
                    .opacity(isStillThere ? 0 : 1)
                    .allowsHitTesting(!isStillThere)
                VStack(spacing: 24) {
                    Button(action: onReady) {
                        Text("I'm ready to pay").frame(minWidth: 400)
                    }
                    .buttonStyle(.glassCTA(height: 88, fontSize: 30))
                    Button("Back to my order", action: onCancel)
                        .buttonStyle(.glassSecondary(height: 76, fontSize: 26))
                }
                .opacity(isStillThere ? 1 : 0)
                .allowsHitTesting(isStillThere)
            }
            .frame(height: 188, alignment: .bottom)
            .padding(.bottom, 96)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .animation(.easeInOut(duration: 0.35), value: prompt.stage)
    }

    private var waitingText: some View {
        VStack(spacing: 18) {
            Text(prompt.instruction)
                .font(Theme.serif(56))
            Text("on the card reader")
                .font(Theme.serif(30, .regular))
                .foregroundStyle(Theme.textSecondary)
        }
        .foregroundStyle(Theme.text)
    }

    private var stillThereText: some View {
        VStack(spacing: 18) {
            Text("Still there?")
                .font(Theme.serif(56))
            Text("Your card hasn't been charged. Tap below when you're ready.")
                .font(Theme.serif(30, .regular))
                .foregroundStyle(Theme.textSecondary)
        }
        .foregroundStyle(Theme.text)
        .multilineTextAlignment(.center)
    }
}

/// A card that drifts down to a reader and back, with contactless waves rising to meet it as it arrives.
private struct CardTapHint: View {
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let period = 2.8

    var body: some View {
        TimelineView(.animation(paused: !isActive || reduceMotion)) { context in
            let nearness = reduceMotion ? 1 : Self.nearness(at: context.date.timeIntervalSinceReferenceDate)
            let glow = isActive ? nearness : 0
            ZStack {
                reader(glow: glow)
                    .offset(y: 130)
                RisingWaves(glow: glow)
                    .frame(width: 160, height: 80)
                    .offset(y: 15)
                card
                    .rotationEffect(.degrees(-10 + 10 * nearness))
                    .offset(x: 24 - 24 * nearness, y: -150 + 70 * nearness)
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 16)
            }
        }
        .accessibilityHidden(true)
    }

    /// 0 with the card raised, 1 with it held over the reader.
    private static func nearness(at time: TimeInterval) -> Double {
        let t = time.truncatingRemainder(dividingBy: period) / period
        let rise: Double
        switch t {
        case ..<0.35: rise = t / 0.35
        case ..<0.7: rise = 1
        case ..<0.95: rise = 1 - (t - 0.7) / 0.25
        default: rise = 0
        }
        return rise * rise * (3 - 2 * rise)
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(LinearGradient(colors: [Theme.text, Theme.text.opacity(0.82)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 236, height: 150)
            .overlay(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.accent.opacity(0.85))
                    .frame(width: 42, height: 32)
                    .padding(.leading, 28)
                    .padding(.top, 44)
            }
            .overlay(alignment: .bottomLeading) {
                Capsule()
                    .fill(Theme.onText.opacity(0.18))
                    .frame(width: 120, height: 10)
                    .padding(.leading, 28)
                    .padding(.bottom, 26)
            }
    }

    private func reader(glow: Double) -> some View {
        RoundedRectangle(cornerRadius: 32, style: .continuous)
            .fill(Theme.surface)
            .frame(width: 210, height: 150)
            .overlay {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1.5)
            }
            .overlay {
                ContactlessMark()
                    .stroke(style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .foregroundStyle(Theme.textSecondary.mix(with: Theme.success, by: glow))
                    .frame(width: 52, height: 52)
            }
    }
}

/// Arcs fanning upward from the reader's top edge, lit one after another as the card closes in.
private struct RisingWaves: View {
    let glow: Double

    var body: some View {
        ZStack {
            ForEach(0..<3) { index in
                let lit = min(max(glow * 3 - Double(index), 0), 1)
                UpwardArc(radius: 24 + CGFloat(index) * 20)
                    .stroke(style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .foregroundStyle(Theme.success.opacity(lit))
            }
        }
    }
}

private struct UpwardArc: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.maxY), radius: radius,
                    startAngle: .degrees(-128), endAngle: .degrees(-52), clockwise: false)
        return path
    }
}

/// The contactless symbol printed on the reader.
private struct ContactlessMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.minX, y: rect.midY)
        for index in 0..<4 {
            let radius = rect.width * (0.22 + 0.24 * CGFloat(index))
            path.addPath(Path { arc in
                arc.addArc(center: center, radius: radius, startAngle: .degrees(-45), endAngle: .degrees(45), clockwise: false)
            })
        }
        return path
    }
}
