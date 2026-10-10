import SwiftUI

struct NameEntryView: View {
    @Bindable var app: AppModel
    @FocusState private var focused: Bool
    @Namespace private var glass
    @State private var revealsContinue = false

    private var trimmed: String { app.customerName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var showsContinue: Bool { !trimmed.isEmpty || app.isPaying }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                GlassBackButton { app.backToSummary() }
                    .disabled(app.isPaying)
                Spacer()
            }
            .padding(.horizontal, 48)
            .padding(.top, 84)

            Spacer().frame(height: 140)

            Text("What's your name?")
                .font(Theme.serif(64))
                .foregroundStyle(Theme.ink)

            GlassEffectContainer(spacing: 40) {
                VStack(spacing: 30) {
                    nameField
                    if revealsContinue {
                        continueButton
                    }
                }
            }
            .frame(height: 112 + 30 + 88, alignment: .top)
            .padding(.top, 56)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: showsContinue, initial: true) { _, shows in
            // Glass only morphs between shapes inside an explicit animation transaction.
            withAnimation(.bouncy(duration: 0.6, extraBounce: 0.08)) { revealsContinue = shows }
        }
        .onAppear {
            Task {
                try? await Task.sleep(for: .seconds(0.45))
                app.square.record("Name field focus: \(Self.controllerContext())")
                focused = true
            }
        }
    }

    private var nameField: some View {
        TextField("", text: $app.customerName, prompt: Text("Name for pickup").foregroundStyle(Theme.ink.opacity(0.3)))
            .font(Theme.serif(48, .medium))
            .foregroundStyle(Theme.ink)
            .tint(Theme.accentDeep)
            .multilineTextAlignment(.center)
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            .textContentType(.givenName)
            .submitLabel(.continue)
            .focused($focused)
            .onSubmit { submit() }
            .onChange(of: app.customerName) { _, value in
                if value.count > 24 { app.customerName = String(value.prefix(24)) }
            }
            .padding(.horizontal, 36)
            .frame(width: 660, height: 112)
            .glassField(isFocused: focused, cornerRadius: 56, morph: GlassMorph(id: "field", namespace: glass))
            .disabled(app.isPaying)
    }

    private var continueButton: some View {
        Button { submit() } label: {
            HStack(spacing: 12) {
                if app.isPaying {
                    ProgressView().tint(.white)
                    Text(app.simulatePayment ? "Processing…" : "Preparing payment…")
                } else {
                    Text("Continue to Payment")
                    LucideIcon(name: "arrow-right", size: 28)
                }
            }
            .frame(minWidth: 400)
            .contentTransition(.opacity)
        }
        .buttonStyle(.glassCTA(height: 88, fontSize: 30, morph: GlassMorph(id: "continue", namespace: glass)))
        .disabled(app.isPaying)
        .animation(.easeInOut(duration: 0.2), value: app.isPaying)
    }

    /// Recorded because a one-off UIViewControllerHierarchyInconsistency crash while the keyboard came up
    /// (2026-10-10, iPadOS 27.2 beta) couldn't be reproduced.
    private static func controllerContext() -> String {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return windows.map { window in
            var chain: [String] = []
            var controller = window.rootViewController
            while let current = controller {
                var name = String(describing: type(of: current))
                if current.isBeingPresented { name += "(presenting)" }
                if current.isBeingDismissed { name += "(dismissing)" }
                chain.append(name)
                controller = current.presentedViewController
            }
            let flags = window.isKeyWindow ? " key" : ""
            return "\(type(of: window))\(flags)[\(chain.joined(separator: " > "))]"
        }.joined(separator: ", ")
    }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        focused = false
        app.submitName()
    }
}
