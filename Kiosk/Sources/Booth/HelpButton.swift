import SwiftUI

struct HelpButton: View {
    let booth: BoothLink

    private static let center = CGPoint(x: Layout.screen.width - Layout.backButtonCenter.x, y: Layout.stepIndicatorY)

    var body: some View {
        if booth.isEnabled {
            ZStack {
                GlassIconButton(icon: "life-buoy", size: 56, iconSize: 24) { booth.tapHelpButton() }
                    .accessibilityLabel("Get help")
                    .position(Self.center)

                if booth.helpBannerVisible {
                    Text("Someone's on the way")
                        .font(Theme.serif(18, .regular))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 20)
                        .frame(height: 42)
                        .glassEffect(.regular, in: .capsule)
                        .fixedSize()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(.trailing, 32)
                        .padding(.top, Self.center.y + 28 + 12)
                        .transition(.opacity.combined(with: .offset(y: -6)))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: booth.helpBannerVisible)
        }
    }
}
