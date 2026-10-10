import SwiftUI

struct NameEntryView: View {
    @Bindable var app: AppModel
    @FocusState private var focused: Bool

    private var trimmed: String { app.customerName.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { app.backToSummary() } label: {
                    HStack(spacing: 6) {
                        LucideIcon(name: "chevron-left", size: 26)
                        Text("Back").font(Theme.serif(22, .medium))
                    }
                }
                .buttonStyle(SecondaryButtonStyle(height: 56))
                .disabled(app.isPaying)
                Spacer()
            }
            .padding(.horizontal, 48)
            .padding(.top, 84)

            Spacer().frame(height: 150)

            VStack(spacing: 18) {
                Text("What's your name?")
                    .font(Theme.serif(54))
                    .foregroundStyle(Theme.ink)
                Text("We'll call it out when your order is ready.")
                    .font(Theme.sans(20))
                    .foregroundStyle(Theme.inkSecondary)
            }

            TextField("", text: $app.customerName, prompt: Text("Your name").foregroundStyle(Theme.ink.opacity(0.25)))
                .font(Theme.serif(44, .medium))
                .foregroundStyle(Theme.ink)
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
                .padding(.horizontal, 32)
                .frame(width: 620, height: 104)
                .background(Theme.card, in: .rect(cornerRadius: 30, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .strokeBorder(focused ? Theme.ink : Theme.inkFaint, lineWidth: focused ? 2.5 : 1)
                }
                .shadow(color: Theme.cardShadow, radius: 20, y: 8)
                .padding(.top, 52)
                .disabled(app.isPaying)
                .animation(.easeInOut(duration: 0.2), value: focused)

            Button { submit() } label: {
                HStack(spacing: 12) {
                    if app.isPaying {
                        ProgressView().tint(.white)
                        Text(app.simulatePayment ? "Processing…" : "Preparing payment…")
                    } else {
                        Text("Continue to Payment")
                        LucideIcon(name: "arrow-right", size: 26)
                    }
                }
                .frame(width: 460)
            }
            .buttonStyle(PrimaryButtonStyle(height: 80, fontSize: 28))
            .disabled(trimmed.isEmpty || app.isPaying)
            .padding(.top, 36)
            .animation(.easeInOut(duration: 0.2), value: app.isPaying)

            Text("Total \(app.orderQuote.totalCents.formattedAsUSD) plus any sales tax")
                .font(Theme.sans(17))
                .foregroundStyle(Theme.inkSecondary)
                .padding(.top, 18)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .onAppear {
            Task {
                try? await Task.sleep(for: .seconds(0.45))
                focused = true
            }
        }
    }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        focused = false
        app.submitName()
    }
}
