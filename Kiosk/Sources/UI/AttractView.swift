import AVFoundation
import SwiftUI

struct AttractView: View {
    let app: AppModel
    @State private var showsButton = false

    var body: some View {
        ZStack {
            Color.black
            LoopingVideoView(url: Bundle.main.url(forResource: "loop", withExtension: "mp4"))

            GlassEffectContainer {
                if showsButton {
                    BeginOrderButton { app.beginOrder() }
                        .glassEffectTransition(.materialize)
                }
            }
            .position(x: Layout.midX, y: 1228)
        }
        .frame(width: Layout.screen.width, height: Layout.screen.height)
        .contentShape(Rectangle())
        .onTapGesture { app.beginOrder() }
        .ignoresSafeArea()
        .onChange(of: app.stageReady, initial: true) { _, ready in
            withAnimation(.smooth(duration: 0.8)) { showsButton = ready }
        }
    }
}

private struct BeginOrderButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Text("Begin Order")
                LucideIcon(name: "arrow-right", size: 34)
            }
        }
        .buttonStyle(.glassOnMedia())
        .phaseAnimator([false, true]) { content, lifted in
            content.scaleEffect(lifted ? 1.025 : 1)
        } animation: { _ in
            .easeInOut(duration: 1.8)
        }
    }
}

struct LoopingVideoView: UIViewRepresentable {
    let url: URL?

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.videoGravity = .resizeAspectFill
        view.backgroundColor = .black
        if let url {
            let item = AVPlayerItem(url: url)
            let player = AVQueuePlayer()
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = true
            context.coordinator.looper = AVPlayerLooper(player: player, templateItem: item)
            view.playerLayer.player = player
            player.play()
        }
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {}

    static func dismantleUIView(_ uiView: PlayerView, coordinator: Coordinator) {
        uiView.playerLayer.player?.pause()
        coordinator.looper?.disableLooping()
        coordinator.looper = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var looper: AVPlayerLooper?
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

struct RoleSetupView: View {
    let app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Set up this iPad")
                .font(Theme.serif(64))
                .foregroundStyle(Theme.ink)
            Button { app.chooseKioskRole() } label: {
                HStack(spacing: 14) {
                    Text("Start Kiosk")
                    LucideIcon(name: "arrow-right", size: 28)
                }
            }
            .buttonStyle(.glassCTA(height: 88, fontSize: 30))
            .padding(.top, 56)

            Text("Order Queue and Stats are coming soon.")
                .font(Theme.sans(17))
                .foregroundStyle(Theme.inkSecondary)
                .padding(.top, 40)
        }
        .frame(width: 720, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AmbientBackdrop())
    }
}
