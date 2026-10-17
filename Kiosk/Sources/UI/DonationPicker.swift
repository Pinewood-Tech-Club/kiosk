import SwiftUI

struct DonationPicker: View {
    let app: AppModel
    @State private var showsCustom = false

    var body: some View {
        let donation = app.donationCents
        let custom = donation > 0 && !Donation.presetsCents.contains(donation)
        HStack(spacing: 12) {
            Text("Add a donation to \(Donation.organization)?")
                .font(Theme.serif(24))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 16)
            ForEach(Donation.presetsCents, id: \.self) { cents in
                chip(Self.dollars(cents), selected: donation == cents, width: 92) {
                    app.setDonation(donation == cents ? 0 : cents)
                }
                .accessibilityLabel("Donate \(Self.dollars(cents))")
            }
            chip(custom ? Self.dollars(donation) : "Custom", selected: custom, width: 128) {
                if custom {
                    app.setDonation(0)
                } else {
                    showsCustom = true
                }
            }
            .accessibilityLabel(custom ? "Custom donation, \(Self.dollars(donation))" : "Custom donation")
        }
        .disabled(!app.canChangeDonation)
        .animation(.snappy(duration: 0.25), value: donation)
        .sheet(isPresented: $showsCustom) {
            CustomDonationSheet { app.setDonation($0) }
        }
    }

    private func chip(_ title: String, selected: Bool, width: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .monospacedDigit()
                .frame(width: width - 2 * KioskGlassButtonStyle.horizontalInset)
        }
        .buttonStyle(KioskGlassButtonStyle(kind: selected ? .primary : .secondary, height: 60, fontSize: 22, horizontalPadding: 0))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    static func dollars(_ cents: Int) -> String {
        cents % 100 == 0 ? "$\(cents / 100)" : cents.formattedAsUSD
    }
}

struct CustomDonationSheet: View {
    let add: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var dollars = 0

    var body: some View {
        VStack(spacing: 0) {
            Text("Custom donation")
                .font(Theme.serif(40))
                .foregroundStyle(Theme.text)
            Text("Any whole dollar amount up to $\(Donation.maxCustomDollars).")
                .font(Theme.serif(21, .regular))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 10)

            Text("$\(dollars)")
                .font(Theme.serif(56, .medium))
                .monospacedDigit()
                .foregroundStyle(dollars == 0 ? Theme.text.opacity(0.25) : Theme.text)
                .contentTransition(.numericText(value: Double(dollars)))
                .animation(.snappy(duration: 0.2), value: dollars)
                .frame(width: 400, height: 112)
                .glassField(isFocused: true, cornerRadius: 56)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Donation amount")
                .accessibilityValue("$\(dollars)")
                .padding(.top, 32)

            NumberKeypad(canType: dollars * 10 <= Donation.maxCustomDollars, canDelete: dollars > 0, type: type,
                         delete: { dollars /= 10 })
                .padding(.top, 32)

            Button { submit() } label: {
                Text(dollars > 0 ? "Add $\(dollars) Donation" : "Add Donation").frame(minWidth: 400)
            }
            .buttonStyle(.glassCTA(height: 88, fontSize: 30))
            .disabled(dollars == 0)
            .padding(.top, 36)

            Button { dismiss() } label: {
                Text("Cancel").frame(minWidth: 400)
            }
            .buttonStyle(.glassSecondary(height: 72, fontSize: 24))
            .padding(.top, 16)
        }
        .padding(.horizontal, 56)
        .padding(.vertical, 48)
        .presentationSizing(.fitted)
    }

    private func type(_ digit: Int) {
        let next = dollars * 10 + digit
        guard next > 0, next <= Donation.maxCustomDollars else { return }
        dollars = next
    }

    private func submit() {
        guard dollars > 0 else { return }
        add(dollars * 100)
        dismiss()
    }
}
