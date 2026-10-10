import SwiftUI

struct RootView: View {
    @Bindable var app: AppModel

    private var stageOpacity: Double {
        switch app.screen {
        case .builder: app.builderVisible ? 1 : 0
        case .roleSetup, .attract: 1
        case .summary, .name, .confirmation: 0
        }
    }

    var body: some View {
        ZStack {
            AmbientBackdrop()

            app.host.frame(width: 0, height: 0)

            if app.screen == .builder {
                BuilderBackdrop(app: app)
                    .opacity(app.builderVisible ? 1 : 0)
                    .transition(.opacity)
            }

            StageView(stage: app.stage)
                .opacity(stageOpacity)

            if app.screen == .builder {
                BuilderForeground(app: app)
                    .opacity(app.builderVisible ? 1 : 0)
                    .allowsHitTesting(app.builderVisible)
                    .transition(.opacity)
            }

            Group {
                switch app.screen {
                case .roleSetup: RoleSetupView(app: app)
                case .attract: AttractView(app: app)
                case .builder: EmptyView()
                case .summary: SummaryView(app: app)
                case .name: NameEntryView(app: app)
                case .confirmation:
                    if let receipt = app.receipt { ConfirmationView(app: app, receipt: receipt) }
                }
            }
            .transition(.opacity)

            if app.show3DDebug, app.screen == .builder {
                StageDebugOverlay(stage: app.stage)
            }

            VStack {
                if app.debugBarHidden {
                    HStack {
                        Color.clear
                            .frame(width: 96, height: 96)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 3) {
                                withAnimation(.easeInOut(duration: 0.25)) { app.debugBarHidden = false }
                            }
                        Spacer()
                    }
                } else {
                    DebugBar(app: app)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
            }
        }
        .coordinateSpace(.named("screen"))
        .ignoresSafeArea()
        .ignoresSafeArea(.keyboard)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .background(WindowHook())
        .sheet(isPresented: $app.showsLog) {
            LogView(entries: app.square.log)
        }
        .onAppear { app.start() }
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
