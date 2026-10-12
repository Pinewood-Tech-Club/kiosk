import AVFoundation
import SwiftUI

/// Stays in the view tree for the app's lifetime so the video is already decoded when the screen fades
/// in; it only plays while visible.
struct AttractView: View {
    let app: AppModel
    var isActive = true
    @State private var showsButton = false
    @State private var playing = false
    @State private var pauseTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black
            LoopingVideoView(url: Bundle.main.url(forResource: "loop", withExtension: "mp4"), isPlaying: playing)

            GlassEffectContainer {
                if app.assetsFailed {
                    NotReadyNotice()
                        .glassEffectTransition(.materialize)
                } else if showsButton {
                    if app.orderingOpen {
                        BeginOrderButton { app.beginOrder() }
                            .glassEffectTransition(.materialize)
                    } else {
                        ClosedNotice(reason: app.closedReason)
                            .glassEffectTransition(.materialize)
                    }
                }
            }
            .position(x: Layout.midX, y: 1228)
            .animation(.smooth(duration: 0.8), value: app.assetsFailed)
            .animation(.smooth(duration: 0.5), value: app.orderingOpen)
        }
        .frame(width: Layout.screen.width, height: Layout.screen.height)
        .contentShape(Rectangle())
        .onTapGesture { app.beginOrder() }
        .ignoresSafeArea()
        .onChange(of: app.stageReady, initial: true) { _, ready in
            withAnimation(.smooth(duration: 0.8)) { showsButton = ready }
        }
        .onChange(of: isActive, initial: true) { _, active in
            pauseTask?.cancel()
            if active {
                playing = true
            } else {
                pauseTask = Task {
                    try? await Task.sleep(for: .seconds(0.6))
                    if !Task.isCancelled { playing = false }
                }
            }
        }
    }
}

private struct NotReadyNotice: View {
    var body: some View {
        VStack(spacing: 10) {
            Text("We're not quite ready")
                .font(Theme.serif(40))
            Text("Please ask a staff member for help.")
                .font(Theme.serif(24, .regular))
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 56)
        .padding(.vertical, 30)
        .background(RoundedRectangle(cornerRadius: 44, style: .continuous).fill(Theme.background.opacity(0.78)).padding(2))
        .glassEffect(.regular, in: .rect(cornerRadius: 44))
    }
}

private struct ClosedNotice: View {
    let reason: String

    var body: some View {
        VStack(spacing: 18) {
            Button {} label: {
                Text("Closed")
            }
            .buttonStyle(.glassOnMedia())
            .disabled(true)
            .opacity(0.55)
            Text(reason)
                .font(Theme.serif(26, .regular))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 8)
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
    var isPlaying = true

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
            if isPlaying { player.play() }
        }
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        guard let player = uiView.playerLayer.player else { return }
        if isPlaying, player.rate == 0 {
            player.play()
        } else if !isPlaying, player.rate != 0 {
            player.pause()
        }
    }

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
                .foregroundStyle(Theme.text)
            Button { app.chooseKioskRole() } label: {
                HStack(spacing: 14) {
                    Text("Start Kiosk")
                    LucideIcon(name: "arrow-right", size: 28)
                }
            }
            .buttonStyle(.glassCTA(height: 88, fontSize: 30))
            .disabled(!app.canChooseKiosk)
            .padding(.top, 56)

            Button { app.chooseStaffRole() } label: {
                HStack(spacing: 12) {
                    Text("Staff")
                    LucideIcon(name: "chevron-right", size: 22)
                }
            }
            .buttonStyle(.glassSecondary())
            .disabled(!app.canChooseStaff)
            .padding(.top, 24)

            if !app.canChooseStaff {
                Text("This iPad is running as the kiosk. Relaunch the app to use it for staff.")
                    .font(Theme.sans(17))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 16)
            }
        }
        .frame(width: 720, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}
