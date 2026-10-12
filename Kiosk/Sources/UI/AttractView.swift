import SwiftUI

/// The photos behind the attract screen's item; while the stage plays the attract scene they sit beneath it
/// (`RootView`), otherwise they cover it like any other screen.
struct AttractBackdrop: View {
    var isActive: Bool

    var body: some View {
        ZStack {
            RadialGradient(colors: [Theme.surface, Theme.background], center: UnitPoint(x: 0.5, y: 0.44),
                           startRadius: 0, endRadius: 760)
            PhotoColumns(isActive: isActive)
        }
        .frame(width: Layout.screen.width, height: Layout.screen.height)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

struct AttractView: View {
    let app: AppModel
    @State private var showsButton = false

    var body: some View {
        ZStack {
            Color.clear

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
