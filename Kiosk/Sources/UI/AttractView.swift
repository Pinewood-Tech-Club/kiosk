import AVFoundation
import SwiftUI

struct AttractView: View {
    let app: AppModel

    var body: some View {
        ZStack {
            Color.black
            LoopingVideoView(url: Bundle.main.url(forResource: "loop", withExtension: "mp4"))

            Text("Begin Order")
                .font(Theme.serif(46))
                .foregroundStyle(.black)
                .padding(.horizontal, 44)
                .padding(.vertical, 22)
                .background(.white, in: .rect(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
                .opacity(app.stageReady ? 1 : 0)
                .animation(.easeOut(duration: 0.5), value: app.stageReady)
                .position(x: Layout.midX, y: 1228)
        }
        .frame(width: Layout.screen.width, height: Layout.screen.height)
        .contentShape(Rectangle())
        .onTapGesture { app.beginOrder() }
        .ignoresSafeArea()
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
        VStack(spacing: 40) {
            Text("Choose this iPad's role")
                .font(Theme.serif(48))
                .foregroundStyle(Theme.ink)

            VStack(spacing: 18) {
                roleButton(title: "Kiosk", detail: "Customer self-order", icon: "ice-cream-cone", enabled: true) {
                    app.chooseKioskRole()
                }
                roleButton(title: "Order Queue", detail: "Coming soon", icon: "shopping-bag", enabled: false) {}
                roleButton(title: "Stats", detail: "Coming soon", icon: "refresh-cw", enabled: false) {}
            }
            .frame(width: 520)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    private func roleButton(title: String, detail: String, icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 20) {
                LucideIcon(name: icon, size: 30)
                    .frame(width: 60, height: 60)
                    .background(Theme.backgroundDeep, in: .circle)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Theme.serif(28))
                    Text(detail).font(Theme.sans(17)).foregroundStyle(Theme.inkSecondary)
                }
                Spacer()
                if enabled { LucideIcon(name: "chevron-right", size: 26) }
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 26)
            .frame(height: 104)
            .background(Theme.card, in: .rect(cornerRadius: 28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Theme.inkFaint, lineWidth: 1))
            .shadow(color: Theme.cardShadow, radius: enabled ? 16 : 0, y: 6)
            .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(PressableStyle(pressedScale: 0.97))
        .disabled(!enabled)
    }
}
