import SwiftUI

struct NameEntryView: View {
    @Bindable var app: AppModel
    @State private var focused = false
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
                .foregroundStyle(Theme.text)

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
        .onChange(of: app.giftCard == nil) { _, nameShown in
            if !nameShown { focused = false }
        }
        .onAppear {
            Task {
                try? await Task.sleep(for: .seconds(0.45))
                app.square.record("Name field focus: \(Self.controllerContext())")
                if app.giftCard == nil { focused = true }
            }
        }
    }

    private var nameField: some View {
        NameField(text: $app.customerName, isFocused: $focused, maxLength: 24, onSubmit: submit)
            .accessibilityLabel("Name for pickup")
            .padding(.horizontal, 36)
            .frame(width: 660, height: 112)
            .glassField(isFocused: focused, cornerRadius: 56, morph: GlassMorph(id: "field", namespace: glass))
            .disabled(app.isPaying)
    }

    private var continueButton: some View {
        Button { submit() } label: {
            HStack(spacing: 12) {
                if app.isPaying {
                    ProgressView().tint(Theme.onText)
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

/// A UIKit field so every keyboard trait is set before the field first becomes first responder. Changing
/// traits on a focused field needs `reloadInputViews()`, which drops the keyboard's auto-shift, and SwiftUI's
/// `TextField` exposes neither the shortcut bar nor predictions. On a shared kiosk those would offer the
/// device owner's contacts and clipboard to every customer.
private struct NameField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let maxLength: Int
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        field.font = UIFont(name: Theme.SerifWeight.medium.rawValue, size: 48)
        field.adjustsFontForContentSizeCategory = false
        field.textColor = UIColor(Theme.text)
        field.tintColor = UIColor(Theme.accent)
        field.textAlignment = .center
        field.borderStyle = .none
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        field.autocapitalizationType = .words
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.inlinePredictionType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.textContentType = nil
        field.writingToolsBehavior = .none
        field.allowsEditingTextAttributes = false
        field.returnKeyType = .continue
        field.enablesReturnKeyAutomatically = true
        field.inputAssistantItem.leadingBarButtonGroups = []
        field.inputAssistantItem.trailingBarButtonGroups = []
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
        field.isEnabled = context.environment.isEnabled
        if isFocused, !field.isFirstResponder, field.window != nil {
            field.becomeFirstResponder()
        } else if !isFocused, field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: NameField

        init(_ parent: NameField) { self.parent = parent }

        @objc func editingChanged(_ field: UITextField) {
            guard field.markedTextRange == nil else { return }
            let typed = field.text ?? ""
            let value = Self.capitalizingWords(String(typed.prefix(parent.maxLength)))
            if value != typed {
                let caret = field.selectedTextRange
                field.text = value
                if value.count == typed.count { field.selectedTextRange = caret }
            }
            if parent.text != value { parent.text = value }
        }

        // The keyboard's `.words` auto-shift is unreliable here (hardware keyboards, the device's
        // Auto-Capitalization setting), so word starts are uppercased on input. Later letters are left
        // alone so names like "McKenzie" survive.
        static func capitalizingWords(_ text: String) -> String {
            var result = ""
            var atWordStart = true
            for character in text {
                result += atWordStart ? character.uppercased() : String(character)
                atWordStart = character.isWhitespace || character == "-"
            }
            return result
        }

        func textFieldDidBeginEditing(_ field: UITextField) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textFieldDidEndEditing(_ field: UITextField) {
            if parent.isFocused { parent.isFocused = false }
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }
    }
}
