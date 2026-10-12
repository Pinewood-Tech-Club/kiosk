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

            Color.black
                .opacity(app.blackout ? 1 : 0)
                .allowsHitTesting(app.blackout)
                .ignoresSafeArea()
                .zIndex(2.5)

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
            if let window {
                TouchObserver.install(on: window)
                CornerHold.install(on: window)
            }
        }
    }
}

/// Watches the window rather than a SwiftUI gesture, which a view update during the hold could cancel.
final class CornerHold: UIGestureRecognizer, UIGestureRecognizerDelegate {
    static let held = Notification.Name("KioskCornerHeld")
    static let corner = CGRect(x: 0, y: 0, width: 110, height: 110)
    static let duration: TimeInterval = 3
    private static let slop: CGFloat = 24

    private var timer: Timer?
    private var start = CGPoint.zero

    static func install(on window: UIWindow) {
        guard !(window.gestureRecognizers ?? []).contains(where: { $0 is CornerHold }) else { return }
        let hold = CornerHold(target: nil, action: nil)
        hold.cancelsTouchesInView = false
        hold.delaysTouchesBegan = false
        hold.delaysTouchesEnded = false
        hold.delegate = hold
        window.addGestureRecognizer(hold)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard timer == nil, event.allTouches?.count == 1, let touch = touches.first, let view,
              Self.corner.contains(touch.location(in: view)) else {
            stop()
            return
        }
        start = touch.location(in: view)
        timer = Timer.scheduledTimer(withTimeInterval: Self.duration, repeats: false) { [weak self] _ in
            self?.timer = nil
            NotificationCenter.default.post(name: Self.held, object: nil)
            self?.state = .failed
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, let view else { return }
        let point = touch.location(in: view)
        if hypot(point.x - start.x, point.y - start.y) > Self.slop { stop() }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { stop() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { stop() }

    override func reset() {
        timer?.invalidate()
        timer = nil
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        state = .failed
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
