import SwiftUI

struct AssistBadge: View {
    var body: some View {
        HStack(spacing: 10) {
            LucideIcon(name: "hand-helping", size: 20)
            Text("A staff member is helping you")
                .font(Theme.serif(18, .regular))
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 20)
        .frame(height: 42)
        .glassEffect(.regular, in: .capsule)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A staff member is helping you")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 26)
        .allowsHitTesting(false)
    }
}
