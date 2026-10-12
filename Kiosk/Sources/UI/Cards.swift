import SwiftUI

/// Same spring as the 3D press (`Stage.pressResponse` / `Stage.pressDamping`), so card and model move as one.
let cardPressSpring = Animation.spring(response: Double(Stage.pressResponse), dampingFraction: Double(Stage.pressDamping))

struct PressEffect: ViewModifier {
    let pressed: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed ? CGFloat(Stage.pressScale) : 1)
            .offset(y: pressed ? CGFloat(Stage.pressDepth) : 0)
            .animation(cardPressSpring, value: pressed)
    }
}

/// Reports press state to the app (which also drives the 3D model) instead of styling the label itself.
struct CardPressStyle: ButtonStyle {
    let onPressChange: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in onPressChange(pressed) }
    }
}

/// A card's name and price line along its bottom edge, beneath the 3D icon.
struct CardCaption<Detail: View>: View {
    let title: String
    var titleSize: CGFloat = 26
    @ViewBuilder let detail: Detail

    var body: some View {
        VStack(spacing: 4) {
            Spacer()
            Text(title)
                .font(Theme.serif(titleSize))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            detail
                .font(Theme.sans(18, .medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 22)
        .frame(width: Layout.cardSize.width, height: Layout.cardSize.height)
    }
}

@Observable
@MainActor
final class CarouselScrollModel {
    private(set) var offset: CGFloat = 0

    func update(_ offset: CGFloat) {
        if offset != self.offset { self.offset = offset }
    }
}

/// A native scroll view of invisible buttons takes the touches, momentum and snapping, but the cards are drawn at
/// the offset the stage latched for this frame, the one its 3D icons use. Drawn by the scroll view itself, the
/// cards would move a frame ahead of their icons: the stage updates before the scroll view moves within a frame.
struct ToppingCarousel: View {
    @Bindable var app: AppModel

    var body: some View {
        let band = Layout.toppingCarouselRect
        ZStack {
            ToppingCardFaces(app: app)
                .mask { CarouselEdgeFade() }
                .allowsHitTesting(false)

            ScrollView(.horizontal) {
                HStack(spacing: Layout.cardSpacing) {
                    ForEach(Topping.allCases) { topping in
                        ToppingCardButton(app: app, topping: topping)
                    }
                }
                .scrollTargetLayout()
                .frame(height: band.height)
            }
            .scrollPosition($app.toppingsScroll)
            .scrollTargetBehavior(.viewAligned)
            .contentMargins(.horizontal, Layout.toppingCarouselMargin, for: .scrollContent)
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x + $0.contentInsets.leading } action: { _, offset in
                app.stage.reportToppingScroll(offset)
            }
        }
        .frame(width: band.width, height: band.height)
        .position(x: band.midX, y: band.midY)
    }
}

/// Fades the carousel out toward the screen's sides. The stage masks the 3D icons with the same view, so an
/// icon fades exactly as much as the card under it.
struct CarouselEdgeFade: View {
    var body: some View {
        let fade = Layout.toppingCarouselFade
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: fade)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: fade)
        }
    }
}

private struct ToppingCardFaces: View {
    let app: AppModel

    var body: some View {
        let band = Layout.toppingCarouselRect
        HStack(spacing: Layout.cardSpacing) {
            ForEach(Topping.allCases) { topping in
                ToppingCardFace(app: app, topping: topping)
            }
        }
        .fixedSize()
        .offset(x: Layout.toppingCarouselMargin - app.stage.toppingScroll.offset)
        .frame(width: band.width, height: band.height, alignment: .leading)
    }
}

private struct ToppingCardFace: View {
    let app: AppModel
    let topping: Topping

    var body: some View {
        let soldOut = app.booth.isSoldOut(topping)
        ZStack {
            CardBackground(highlighted: app.hasTopping(topping), dimmed: soldOut)
            if !app.stageDrawsToppingIcons {
                ToppingGlyph(topping: topping, size: Layout.toppingIconSize.height * 0.8)
                    .offset(y: Layout.toppingIconOffsetY)
            }
            if !soldOut {
                ToppingCaption(topping: topping, soldOut: false)
            }
        }
        .frame(width: Layout.cardSize.width, height: Layout.cardSize.height)
        .modifier(PressEffect(pressed: app.pressedCards.contains(.topping(topping))))
    }
}

private struct ToppingCaption: View {
    let topping: Topping
    let soldOut: Bool

    var body: some View {
        CardCaption(title: topping.title) {
            Text(soldOut ? "Sold out" : "+\(topping.priceCents.formattedAsUSD)")
                .font(Theme.sans(18, soldOut ? .semibold : .medium))
                .monospacedDigit()
                .foregroundStyle(soldOut ? Theme.text : Theme.textSecondary)
        }
    }
}

/// The sold-out veil the vessel and flavor cards draw over their 3D icons. The carousel's faces sit beneath the
/// stage, so this draws above it, at the same latched offset and edge fade, with the caption on top of the veil.
struct ToppingSoldOutVeils: View {
    let app: AppModel

    var body: some View {
        let band = Layout.toppingCarouselRect
        HStack(spacing: Layout.cardSpacing) {
            ForEach(Topping.allCases) { topping in
                let soldOut = app.booth.isSoldOut(topping)
                ZStack {
                    if soldOut {
                        ToppingCaption(topping: topping, soldOut: true)
                            .background {
                                RoundedRectangle(cornerRadius: Layout.cardCornerRadius, style: .continuous)
                                    .fill(Theme.background.opacity(0.7))
                            }
                            .transition(.opacity)
                    }
                }
                .frame(width: Layout.cardSize.width, height: Layout.cardSize.height)
                .modifier(PressEffect(pressed: app.pressedCards.contains(.topping(topping))))
                .animation(.easeInOut(duration: 0.25), value: soldOut)
            }
        }
        .fixedSize()
        .offset(x: Layout.toppingCarouselMargin - app.stage.toppingScroll.offset)
        .frame(width: band.width, height: band.height, alignment: .leading)
        .mask { CarouselEdgeFade() }
        .position(x: band.midX, y: band.midY)
        .allowsHitTesting(false)
    }
}

private struct ToppingCardButton: View {
    let app: AppModel
    let topping: Topping

    var body: some View {
        let selected = app.hasTopping(topping)
        let soldOut = app.booth.isSoldOut(topping)
        let price = "+\(topping.priceCents.formattedAsUSD)"
        Button { app.toggleTopping(topping) } label: {
            Color.clear
                .frame(width: Layout.cardSize.width, height: Layout.cardSize.height)
                .contentShape(.rect(cornerRadius: Layout.cardCornerRadius))
        }
        .buttonStyle(CardPressStyle { app.setPressed(.topping(topping), $0) })
        .disabled(soldOut && !selected)
        .accessibilityLabel(topping.title)
        .accessibilityValue(selected ? "Added" : soldOut ? "Sold out" : price)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("topping-\(topping.rawValue)")
    }
}
