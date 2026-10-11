import SwiftUI

struct StaffView: View {
    let app: AppModel

    private var staff: StaffLink { app.staff }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Staff")
                .font(Theme.serif(64))
                .foregroundStyle(Theme.text)
            Text(connectionText)
                .font(Theme.sans(20, .medium))
                .foregroundStyle(Theme.textSecondary)
            if staff.state != nil {
                Text("\(staff.openOrders.count) open orders, \(staff.openAlerts.count) open alerts")
                    .font(Theme.sans(20))
                    .foregroundStyle(Theme.text)
            }
            Text("The order queue and stats are coming soon.")
                .font(Theme.sans(17))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 16)
        }
        .frame(width: 720, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    private var connectionText: String {
        if let problem = staff.problem { return problem }
        switch staff.connectionState {
        case .connected: return "Connected to the booth"
        case .connecting: return "Connecting to the booth…"
        case .waiting: return "Booth unreachable, retrying"
        case .idle: return "Not connected"
        }
    }
}
