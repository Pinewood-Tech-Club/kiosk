import SwiftUI

/// Screens change by fading one opaque layer over another. Only the attract and name overlays ever fade;
/// whatever they cover appears instantly underneath and stays fully opaque until covered
/// (`AppModel.leavingScreen`), so no frame shows a half-faded screen over the bare backdrop.
struct RootView: View {
    @Bindable var app: AppModel

    private func shows(_ screen: AppModel.Screen) -> Bool { app.screen == screen || app.leavingScreen == screen }
    private var builderShown: Bool { shows(.builder) || shows(.name) }
    /// The stage plays the attract scene over the photos only once nothing else is still drawn beneath them.
    private var attractBehindStage: Bool { app.attractLive && app.screen == .attract && app.leavingScreen == nil }
    private var showsAssistBadge: Bool {
        app.booth.assistActive && [.attract, .builder, .name, .confirmation].contains(app.screen)
    }

    var body: some View {
        GeometryReader { proxy in
            // Full-screen layers must be laid out in a container that has no safe area. Fixed-size
            // children of an `.ignoresSafeArea()` ZStack are still centered in the safe area, which put
            // every screen 12.5 pt above the RealityView and left a bar at the bottom.
            layers.frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .ignoresSafeArea(.keyboard)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .background(WindowHook())
        .sheet(isPresented: $app.showsLog) {
            LogView(entries: app.square.log)
        }
        .onAppear {
            app.start()
        }
    }

    private var layers: some View {
        ZStack {
            Theme.background

            app.host.frame(width: 0, height: 0)

            if builderShown {
                BuilderBackdrop(app: app)
                    .opacity(app.builderVisible ? 1 : 0)
                    .transition(.identity)
            }

            // Beneath the stage so each receipt row's live 3D item draws on the paper.
            if shows(.confirmation), let receipt = app.receipt {
                ConfirmationView(app: app, receipt: receipt)
                    .background(Theme.background)
                    .transition(.identity)
            }

            AttractBackdrop(isActive: app.screen == .attract)
                .opacity(app.screen == .attract ? 1 : 0)
                .zIndex(attractBehindStage ? 0 : 2)

            // Never hidden: a RealityView left hidden for a while doesn't render again. The opaque screens
            // above it cover it instead.
            StageView(stage: app.stage, clipsTray: !attractBehindStage)

            if builderShown, app.screen != .confirmation {
                BuilderForeground(app: app)
                    .opacity(app.builderVisible ? 1 : 0)
                    .allowsHitTesting(app.screen == .builder && app.builderVisible)
                    .transition(.identity)
            }

            if shows(.roleSetup) {
                RoleSetupView(app: app).transition(.identity)
            }

            if shows(.staff) {
                StaffWebView { app.exitStaffMode() }.transition(.identity)
            }

            if shows(.name) {
                NameEntryView(app: app)
                    .background(Theme.background)
                    .opacity(app.screen == .name ? 1 : 0)
                    .allowsHitTesting(app.screen == .name)
                    .transition(.opacity)
                    .zIndex(1)
            }

            if shows(.name), let giftCard = app.giftCard {
                GiftCardView(checkout: giftCard)
                    .background(Theme.background)
                    .opacity(app.screen == .name ? 1 : 0)
                    .allowsHitTesting(app.screen == .name)
                    .transition(.opacity)
                    .zIndex(1.5)
            }

            AttractView(app: app)
                .opacity(app.screen == .attract ? 1 : 0)
                .allowsHitTesting(app.screen == .attract)
                .zIndex(2)

            if app.show3DDebug, app.screen == .builder {
                StageDebugOverlay(stage: app.stage).zIndex(3)
            }

            ZStack {
                if showsAssistBadge {
                    AssistBadge().transition(.opacity.combined(with: .offset(y: -8)))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: showsAssistBadge)
            .zIndex(3.5)

            VStack {
                if app.screen != .staff, app.showsDebugBar {
                    DebugBar(app: app)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
            }
            .zIndex(4)
        }
        .coordinateSpace(.named("screen"))
    }
}

private struct WindowHook: UIViewRepresentable {
    func makeUIView(context: Context) -> HookView { HookView() }
    func updateUIView(_ uiView: HookView, context: Context) {}

    final class HookView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { TouchObserver.install(on: window) }
        }
    }
}
