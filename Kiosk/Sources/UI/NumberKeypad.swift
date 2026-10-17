import SwiftUI

struct NumberKeypad: View {
    let canType: Bool
    let canDelete: Bool
    let type: (Int) -> Void
    let delete: () -> Void

    var body: some View {
        Grid(horizontalSpacing: 18, verticalSpacing: 16) {
            ForEach([[1, 2, 3], [4, 5, 6], [7, 8, 9]], id: \.self) { row in
                GridRow {
                    ForEach(row, id: \.self) { digitKey($0) }
                }
            }
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                digitKey(0)
                Button(action: delete) {
                    LucideIcon(name: "delete", size: 34).frame(width: 140)
                }
                .buttonStyle(.glassSecondary(height: 84, fontSize: 36))
                .disabled(!canDelete)
                .accessibilityLabel("Delete")
            }
        }
    }

    private func digitKey(_ digit: Int) -> some View {
        Button { type(digit) } label: {
            Text("\(digit)").frame(width: 140)
        }
        .buttonStyle(.glassSecondary(height: 84, fontSize: 38))
        .disabled(!canType)
    }
}
