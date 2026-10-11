import SwiftUI

private enum StaffStyle {
    static let warning = Color(red: 0.961, green: 0.745, blue: 0.369)
    static let cardRadius: CGFloat = 32
    static let padding: CGFloat = 40
}

struct StaffView: View {
    let app: AppModel

    private var staff: StaffLink { app.staff }

    private var urgentOpen: Bool {
        staff.openAlerts.contains { $0.severity == "urgent" && !staff.isAcknowledged($0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if let rejection = staff.rejection {
                    RejectionBanner(message: rejection) { staff.dismissRejection() }
                }
                if let problem = staff.problem {
                    MessageCard(icon: "circle-alert", title: "Can't connect", detail: problem)
                } else if staff.needsSignIn {
                    StaffSignIn(staff: staff)
                } else if let state = staff.state {
                    AlertsSection(staff: staff, alerts: state.alerts)
                    HStack(alignment: .top, spacing: 24) {
                        KioskCard(staff: staff, kiosk: state.kiosk)
                        FlavorsCard(staff: staff, flavors: state.flavors)
                    }
                    OrdersSection(staff: staff, orders: state.orders)
                } else {
                    MessageCard(icon: "clock", title: "Connecting to the booth",
                                detail: "Alerts, the kiosk's status, flavors and orders appear here once this iPad reaches the booth.")
                }
            }
            .padding(StaffStyle.padding)
            .padding(.top, 8)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .overlay { UrgentFrame(active: urgentOpen) }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Counter")
                    .font(Theme.serif(56))
                    .foregroundStyle(Theme.text)
                Text("Tech Club Ice Cream")
                    .font(Theme.serif(20, .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
            ConnectionPill(staff: staff)
        }
    }
}

private struct ConnectionPill: View {
    let staff: StaffLink

    var body: some View {
        HStack(spacing: 12) {
            LucideIcon(name: icon, size: 24)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.serif(24))
                    .foregroundStyle(Theme.text)
                if let since = offlineSince {
                    Ago(prefix: "Last update", date: since)
                        .font(Theme.sans(16, .medium))
                        .foregroundStyle(Theme.textSecondary)
                } else if staff.connectionState == .connected {
                    Text("Updates arrive instantly")
                        .font(Theme.sans(16, .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                if staff.hasQueuedActions, staff.connectionState != .connected {
                    Text("Your changes send when it's back")
                        .font(Theme.sans(16, .semibold))
                        .foregroundStyle(StaffStyle.warning)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .frame(minHeight: 72)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .animation(.easeInOut(duration: 0.25), value: staff.connectionState)
    }

    private var hasBeenLive: Bool { staff.lastLiveAt != nil }

    private var offlineSince: Date? {
        guard staff.connectionState != .connected, hasBeenLive else { return nil }
        return staff.stateReceivedAt ?? staff.lastLiveAt
    }

    private var title: String {
        switch staff.connectionState {
        case .connected: "Live"
        case .connecting where !hasBeenLive: "Connecting"
        default: hasBeenLive ? "Offline, reconnecting" : "Can't reach the booth"
        }
    }

    private var icon: String {
        switch staff.connectionState {
        case .connected: "wifi"
        case .connecting where !hasBeenLive: "clock"
        default: "wifi-off"
        }
    }

    private var tint: Color {
        switch staff.connectionState {
        case .connected: Theme.success
        case .connecting where !hasBeenLive: Theme.textSecondary
        default: Theme.accent
        }
    }
}

private struct UrgentFrame: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if active {
            PhaseAnimator([false, true]) { bright in
                RoundedRectangle(cornerRadius: 0)
                    .strokeBorder(Theme.accent, lineWidth: 14)
                    .opacity(reduceMotion ? 1 : (bright ? 1 : 0.35))
            } animation: { _ in
                .easeInOut(duration: 0.8)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }
}

private struct AlertsSection: View {
    let staff: StaffLink
    let alerts: [BoothAlert]

    private var shown: [BoothAlert] {
        alerts.filter(\.isOpen).sorted { lhs, rhs in
            let left = staff.isAcknowledged(lhs), right = staff.isAcknowledged(rhs)
            if left != right { return !left }
            if rank(lhs) != rank(rhs) { return rank(lhs) < rank(rhs) }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func rank(_ alert: BoothAlert) -> Int {
        switch alert.severity {
        case "urgent": 0
        case "warning": 1
        default: 2
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: "Alerts", detail: shown.isEmpty ? nil : "\(shown.count) open")
            if shown.isEmpty {
                HStack(spacing: 16) {
                    LucideIcon(name: "circle-check", size: 34)
                        .foregroundStyle(Theme.success)
                    Text("All clear")
                        .font(Theme.serif(30))
                        .foregroundStyle(Theme.text)
                    Spacer()
                }
                .padding(.horizontal, 28)
                .frame(height: 96)
                .background(card)
            } else {
                ForEach(shown) { alert in
                    AlertRow(staff: staff, alert: alert)
                }
            }
        }
        .animation(.snappy, value: shown.map(\.id))
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: StaffStyle.cardRadius, style: .continuous)
            .fill(Theme.surface)
            .strokeBorder(Theme.hairline, lineWidth: 1)
    }
}

private struct AlertRow: View {
    let staff: StaffLink
    let alert: BoothAlert

    private var acknowledged: Bool { staff.isAcknowledged(alert) }
    private var urgent: Bool { alert.severity == "urgent" && !acknowledged }
    private var warning: Bool { alert.severity == "warning" && !acknowledged }
    private var compact: Bool { alert.severity == "info" || acknowledged }
    private var foreground: Color { urgent ? Theme.onText : Theme.text }

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            LucideIcon(name: icon, size: compact ? 28 : 40)
                .foregroundStyle(urgent ? Theme.onText : warning ? StaffStyle.warning : Theme.textSecondary)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(alert.title)
                        .font(Theme.serif(compact ? 24 : 34, urgent ? .bold : .semibold))
                    if alert.count > 1 {
                        Text("×\(alert.count)")
                            .font(Theme.sans(compact ? 18 : 22, .bold))
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(foreground)
                HStack(spacing: 8) {
                    if !alert.detail.isEmpty, !compact {
                        Text(alert.detail).lineLimit(2)
                        Text("·")
                    }
                    Ago(date: staff.localDate(alert.createdAt))
                }
                .font(Theme.sans(compact ? 16 : 20, .medium))
                .foregroundStyle(urgent ? Theme.onText.opacity(0.75) : Theme.textSecondary)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 28)
        .padding(.vertical, compact ? 16 : 24)
        .frame(minHeight: compact ? 84 : 128)
        .background {
            let shape = RoundedRectangle(cornerRadius: StaffStyle.cardRadius, style: .continuous)
            shape
                .fill(urgent ? Theme.accent : Theme.surface)
                .strokeBorder(warning ? StaffStyle.warning : Theme.hairline, lineWidth: warning ? 3 : 1)
        }
        .opacity(acknowledged ? 0.6 : 1)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    @ViewBuilder
    private var trailing: some View {
        if acknowledged {
            HStack(spacing: 8) {
                LucideIcon(name: staff.isSending(alert: alert.id) ? "clock" : "check", size: 22)
                Text(staff.isSending(alert: alert.id) ? "Sending" : "Acknowledged")
                    .font(Theme.serif(20, .medium))
            }
            .foregroundStyle(Theme.textSecondary)
        } else if compact {
            Button { staff.acknowledge(alert) } label: { Text("Dismiss") }
                .buttonStyle(.glassSecondary(height: 60, fontSize: 22))
        } else {
            Button { staff.acknowledge(alert) } label: {
                HStack(spacing: 10) {
                    LucideIcon(name: "check", size: 28)
                    Text("Got it")
                }
            }
            .buttonStyle(.glassCTA(height: 84, fontSize: 28))
        }
    }

    private var icon: String {
        switch alert.kind {
        case "help": "life-buoy"
        case "offline": "wifi-off"
        case "soldout": "ice-cream-bowl"
        default: "circle-alert"
        }
    }
}

private struct KioskCard: View {
    let staff: StaffLink
    let kiosk: KioskState

    private var everSeen: Bool { kiosk.lastSeenAt != nil || kiosk.health != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionTitle(title: "Kiosk", detail: nil)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    Circle()
                        .fill(kiosk.online ? Theme.success : Theme.accent)
                        .frame(width: 18, height: 18)
                    Text(!everSeen ? "Not seen yet" : kiosk.online ? "Online" : "Offline")
                        .font(Theme.serif(34))
                        .foregroundStyle(Theme.text)
                }
                if let seen = kiosk.lastSeenAt {
                    Ago(prefix: kiosk.online ? "Checked in" : "Last seen", date: staff.localDate(seen))
                        .font(Theme.sans(18, .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 6)
                }
                if let screen = kiosk.screen, kiosk.online {
                    Text("Showing \(Self.screenName(screen))")
                        .font(Theme.sans(18, .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 2)
                }
            }
            .padding(.bottom, 4)

            if let health = kiosk.health {
                VStack(spacing: 0) {
                    readerRow(health)
                    Divider().overlay(Theme.hairline)
                    batteryRow(icon: "tablet", label: "iPad", battery: health.deviceBattery.map { ($0.percent, $0.charging) })
                    Divider().overlay(Theme.hairline)
                    StatusRow(icon: "lock-keyhole", label: "Square",
                              value: health.authorized ? health.environment : "Not signed in",
                              tint: health.authorized ? Theme.text : Theme.accent)
                    if !health.catalog.ok {
                        Divider().overlay(Theme.hairline)
                        StatusRow(icon: "circle-alert", label: "Catalog", value: "Problem", tint: StaffStyle.warning)
                    }
                }
                if let healthAt = kiosk.healthAt {
                    Ago(prefix: "Health reported", date: staff.localDate(healthAt))
                        .font(Theme.sans(15, .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                Text("No health report yet.")
                    .font(Theme.serif(20, .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StaffCard())
    }

    @ViewBuilder
    private func readerRow(_ health: KioskHealth) -> some View {
        if let reader = health.readers.first(where: { $0.state.lowercased() == "ready" }) ?? health.readers.first {
            let ready = reader.state.lowercased() == "ready"
            VStack(alignment: .leading, spacing: 0) {
                StatusRow(icon: "credit-card", label: "Reader", value: ready ? "Ready" : Self.readerState(reader.state),
                          tint: ready ? Theme.success : Theme.accent)
                if let percent = reader.batteryPercent {
                    BatteryLine(percent: percent, charging: reader.isCharging == true)
                        .padding(.leading, 48)
                        .padding(.bottom, 12)
                        .padding(.top, -6)
                }
            }
        } else if health.simulatePayment {
            StatusRow(icon: "credit-card", label: "Reader", value: "Test payments", tint: Theme.textSecondary)
        } else {
            StatusRow(icon: "credit-card", label: "Reader", value: "None connected", tint: Theme.accent)
        }
    }

    @ViewBuilder
    private func batteryRow(icon: String, label: String, battery: (Int, Bool)?) -> some View {
        if let (percent, charging) = battery {
            StatusRow(icon: icon, label: label, value: "\(percent)%", tint: BatteryLine.tint(percent, charging: charging),
                      trailingIcon: BatteryLine.icon(percent, charging: charging))
        } else {
            StatusRow(icon: icon, label: label, value: "Battery unknown", tint: Theme.textSecondary)
        }
    }

    static func readerState(_ raw: String) -> String {
        if raw == "disabled" { return "Bluetooth off" }
        let spaced = raw.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst().lowercased()
    }

    static func screenName(_ raw: String) -> String {
        switch raw {
        case "attract": "the welcome screen"
        case "builder": "the order builder"
        case "name": "name entry"
        case "confirmation": "a receipt"
        case "payment": "the payment screen"
        default: Self.readerState(raw).lowercased()
        }
    }
}

private struct StatusRow: View {
    let icon: String
    let label: String
    let value: String
    var tint: Color = Theme.text
    var trailingIcon: String?

    var body: some View {
        HStack(spacing: 16) {
            LucideIcon(name: icon, size: 28)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 32)
            Text(label)
                .font(Theme.serif(22, .medium))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 8)
            if let trailingIcon {
                LucideIcon(name: trailingIcon, size: 28).foregroundStyle(tint)
            }
            Text(value)
                .font(Theme.serif(24))
                .foregroundStyle(tint)
                .monospacedDigit()
        }
        .frame(minHeight: 64)
    }
}

private struct BatteryLine: View {
    let percent: Int
    let charging: Bool

    var body: some View {
        HStack(spacing: 8) {
            LucideIcon(name: Self.icon(percent, charging: charging), size: 22)
            Text(charging ? "\(percent)%, charging" : "\(percent)%")
                .font(Theme.sans(17, .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(Self.tint(percent, charging: charging))
    }

    static func icon(_ percent: Int, charging: Bool) -> String {
        if charging { return "battery-charging" }
        switch percent {
        case ...20: return "battery-low"
        case ...70: return "battery-medium"
        default: return "battery-full"
        }
    }

    static func tint(_ percent: Int, charging: Bool) -> Color {
        if charging { return Theme.success }
        return percent <= 20 ? Theme.accent : percent <= 40 ? StaffStyle.warning : Theme.text
    }
}

private struct FlavorsCard: View {
    let staff: StaffLink
    let flavors: [BoothFlavorState]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionTitle(title: "Flavors", detail: flavors.isEmpty ? nil : "Tap to switch")
            if flavors.isEmpty {
                Text("Flavors show up here once the kiosk has connected.")
                    .font(Theme.serif(20, .medium))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                VStack(spacing: 14) {
                    ForEach(flavors, id: \.id) { flavor in
                        FlavorToggle(staff: staff, flavor: flavor)
                    }
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StaffCard())
    }
}

private struct FlavorToggle: View {
    let staff: StaffLink
    let flavor: BoothFlavorState

    var body: some View {
        let soldOut = staff.isSoldOut(flavor)
        let sending = staff.isSending(flavor: flavor.id)
        Button { staff.toggleSoldOut(flavor) } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(flavor.name)
                        .font(Theme.serif(26))
                        .foregroundStyle(soldOut ? Theme.textSecondary : Theme.text)
                        .strikethrough(soldOut, color: Theme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if sending {
                        Text(staff.connectionState == .connected ? "Sending" : "Queued, sends when online")
                            .font(Theme.sans(15, .semibold))
                            .foregroundStyle(StaffStyle.warning)
                    }
                }
                Spacer(minLength: 8)
                Text(soldOut ? "Sold out" : "Available")
                    .font(Theme.serif(20, .semibold))
                    .foregroundStyle(soldOut ? Theme.onText : Theme.success)
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .background {
                        Capsule().fill(soldOut ? Theme.accent : Theme.success.opacity(0.16))
                    }
            }
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity, minHeight: 92)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(soldOut ? Theme.accent.opacity(0.12) : Theme.background.opacity(0.35))
                    .strokeBorder(soldOut ? Theme.accent.opacity(0.7) : Theme.hairline, lineWidth: soldOut ? 2 : 1)
            }
            .contentShape(.rect(cornerRadius: 22))
        }
        .buttonStyle(PressScale())
        .animation(.snappy, value: soldOut)
        .accessibilityLabel("\(flavor.name), \(soldOut ? "sold out" : "available")")
        .accessibilityHint(soldOut ? "Marks it available" : "Marks it sold out")
    }
}

private struct OrdersSection: View {
    let staff: StaffLink
    let orders: [BoothOrderSummary]

    private static let shownCount = 8

    private var recent: [BoothOrderSummary] {
        Array(orders.sorted { $0.receivedAt > $1.receivedAt }.prefix(Self.shownCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: "Recent orders", detail: orders.isEmpty ? nil : "\(staff.openOrders.count) open")
            VStack(spacing: 0) {
                if recent.isEmpty {
                    Text("Paid orders appear here as they come in.")
                        .font(Theme.serif(20, .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
                } else {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, order in
                        if index > 0 { Divider().overlay(Theme.hairline) }
                        OrderRow(staff: staff, order: order)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 8)
            .background(StaffCard())
        }
        .animation(.snappy, value: recent.map(\.id))
    }
}

private struct OrderRow: View {
    let staff: StaffLink
    let order: BoothOrderSummary

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            Text(order.orderNumber.map { "#\($0)" } ?? "#")
                .font(Theme.sans(26, .bold))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
                .frame(width: 76, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text(order.customerName.flatMap { $0.isEmpty ? nil : $0 } ?? "No name")
                        .font(Theme.serif(24))
                        .foregroundStyle(Theme.text)
                    if order.simulated {
                        Text("Test")
                            .font(Theme.sans(14, .bold))
                            .foregroundStyle(Theme.onText)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(Theme.textSecondary, in: .capsule)
                    }
                }
                ForEach(Array(order.items.enumerated()), id: \.offset) { _, item in
                    Text(Self.describe(item, flavors: staff.state?.flavors ?? []))
                        .font(Theme.serif(18, .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                StatusChip(status: order.status)
                Ago(date: staff.localDate(order.receivedAt))
                    .font(Theme.sans(15, .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.vertical, 14)
        .opacity(order.isOpen ? 1 : 0.6)
    }

    static func describe(_ item: BoothOrderSummary.Item, flavors: [BoothFlavorState]) -> String {
        let vessel = Vessel(rawValue: item.vessel)?.title ?? item.vessel.capitalized
        let scoops = item.flavors.map { id in
            flavors.first { $0.id == id }?.name ?? Flavor(rawValue: id)?.title ?? id.capitalized
        }
        var text = "\(vessel): \(scoops.joined(separator: ", "))"
        if !item.toppings.isEmpty {
            text += " + " + item.toppings.map { Topping(rawValue: $0)?.title ?? $0.capitalized }.joined(separator: ", ")
        }
        return text
    }
}

private struct StatusChip: View {
    let status: String

    var body: some View {
        Text(title)
            .font(Theme.sans(15, .bold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(background, in: .capsule)
    }

    private var title: String {
        switch status {
        case "paid": "Paid"
        case "preparing": "Preparing"
        case "ready": "Ready"
        case "collected": "Collected"
        case "canceled": "Canceled"
        default: status.capitalized
        }
    }

    private var foreground: Color {
        switch status {
        case "paid", "ready": Theme.onText
        default: Theme.text
        }
    }

    private var background: Color {
        switch status {
        case "paid": Theme.text
        case "ready": Theme.success
        case "preparing": StaffStyle.warning.opacity(0.35)
        default: Theme.hairline
        }
    }
}

private struct StaffSignIn: View {
    let staff: StaffLink
    @State private var pin = ""
    @State private var working = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                LucideIcon(name: "lock-keyhole", size: 34)
                    .foregroundStyle(Theme.text)
                Text(staff.connection == nil ? "Sign in" : "Sign in again")
                    .font(Theme.serif(40))
                    .foregroundStyle(Theme.text)
            }
            Text(staff.connection == nil
                 ? "Enter the staff PIN to connect this iPad to the booth."
                 : "The booth didn't accept this iPad's sign-in. It may have expired; enter the staff PIN again.")
                .font(Theme.serif(22, .medium))
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 16) {
                SecureField("Staff PIN", text: $pin)
                    .font(Theme.serif(30))
                    .foregroundStyle(Theme.text)
                    .keyboardType(.numberPad)
                    .textContentType(.password)
                    .focused($focused)
                    .padding(.horizontal, 24)
                    .frame(width: 360, height: 80)
                    .glassField(isFocused: focused, cornerRadius: 24)
                    .onSubmit(submit)
                Button(action: submit) {
                    HStack(spacing: 10) {
                        Text(working ? "Signing in" : "Sign in")
                        LucideIcon(name: "arrow-right", size: 26)
                    }
                }
                .buttonStyle(.glassCTA(height: 84, fontSize: 28))
                .disabled(pin.isEmpty || working)
            }
            if let error {
                Text(error)
                    .font(Theme.serif(20, .medium))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StaffCard())
        .onAppear { focused = true }
    }

    private func submit() {
        guard !pin.isEmpty, !working else { return }
        working = true
        error = nil
        Task {
            do {
                try await staff.signIn(pin: pin)
                pin = ""
            } catch let failure as BoothError {
                error = failure.status == 401 ? "That PIN isn't right." : "Couldn't reach the booth (\(failure.summary))."
            } catch {
                self.error = "Couldn't sign in."
            }
            working = false
        }
    }
}

private struct SectionTitle: View {
    let title: String
    let detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title)
                .font(Theme.serif(30))
                .foregroundStyle(Theme.text)
            if let detail {
                Text(detail)
                    .font(Theme.sans(18, .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

private struct StaffCard: View {
    var body: some View {
        RoundedRectangle(cornerRadius: StaffStyle.cardRadius, style: .continuous)
            .fill(Theme.surface)
            .strokeBorder(Theme.hairline, lineWidth: 1)
    }
}

private struct MessageCard: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                LucideIcon(name: icon, size: 34)
                Text(title).font(Theme.serif(36))
            }
            .foregroundStyle(Theme.text)
            Text(detail)
                .font(Theme.serif(22, .medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StaffCard())
    }
}

private struct RejectionBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            LucideIcon(name: "circle-alert", size: 28)
                .foregroundStyle(StaffStyle.warning)
            Text(message)
                .font(Theme.serif(20, .medium))
                .foregroundStyle(Theme.text)
            Spacer(minLength: 8)
            GlassIconButton(icon: "x", size: 56, iconSize: 22, action: dismiss)
        }
        .padding(.leading, 24)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Theme.surface)
                .strokeBorder(StaffStyle.warning, lineWidth: 2)
        }
    }
}

private struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

private struct Ago: View {
    var prefix: String?
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            Text(prefix.map { "\($0) \(Self.relative(date, now: context.date))" } ?? Self.relative(date, now: context.date))
                .monospacedDigit()
        }
    }

    static func relative(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<10: return "just now"
        case ..<60: return "\(Int(seconds / 10) * 10) s ago"
        case ..<3600: return "\(Int(seconds / 60)) min ago"
        default: return "at \(date.formatted(date: .omitted, time: .shortened))"
        }
    }
}
