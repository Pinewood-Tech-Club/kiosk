import SquareMobilePaymentsSDK
import SwiftUI

struct DebugBar: View {
    @Bindable var app: AppModel

    private var square: SquareService { app.square }

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                HStack(spacing: 10) {
                    StatusDot(text: square.environmentName, color: square.isSandbox ? .orange : (square.isConfigured ? .green : .red))
                    StatusDot(text: authText, color: square.isAuthorized ? .green : .red)
                    StatusDot(text: readerText, color: readerColor)
                    if square.isConfigured { StatusDot(text: square.catalogStatus.badgeText, color: catalogColor) }
                    if let forced = app.forcedError { StatusDot(text: "Forcing: \(forced.label)", color: .red) }
                    if app.simulatePayment { StatusDot(text: "Simulated pay", color: .purple) }
                    if app.slowMotion != 1 { StatusDot(text: "×\(app.slowMotion.formatted())", color: .blue) }
                }
                .padding(.horizontal, 12)
                .frame(height: 32)
                .glassEffect(.regular, in: .capsule)

                if square.isSandbox, square.isAuthorized {
                    Button(square.isMockReaderPresented ? "Hide Mock Reader" : "Mock Reader") { square.toggleMockReader() }
                }
                Button("Readers") { square.presentReaderSettings(from: app.host.presenter) }
                    .disabled(!square.isAuthorized)
                Button("Log") { app.showsLog = true }
                Menu("Debug") {
                    if !square.isProduction || app.simulatePayment {
                        Toggle("Simulate payment success", isOn: $app.simulatePayment)
                    }
                    if !square.isProduction || app.forcedError != nil {
                        Picker("Simulate error", selection: $app.forcedError) {
                            Text("None").tag(ForcedError?.none)
                            ForEach(ForcedError.allCases) { Text($0.label).tag(ForcedError?.some($0)) }
                        }
                        .pickerStyle(.menu)
                    }
                    Picker("Animation speed", selection: $app.slowMotion) {
                        Text("Normal").tag(1.0)
                        Text("0.5× slow-mo").tag(0.5)
                        Text("0.25× slow-mo").tag(0.25)
                        Text("0.1× slow-mo").tag(0.1)
                    }
                    Toggle("Show 3D debug info", isOn: $app.show3DDebug)
                    Divider()
                    Button("Change role") { app.changeRole() }
                    Button("Hide debug bar") {
                        withAnimation(.easeInOut(duration: 0.25)) { app.hideDebugBar() }
                    }
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { app.hideDebugBar() }
                } label: {
                    HStack(spacing: 5) {
                        LucideIcon(name: "eye-off", size: 13)
                        Text("Hide")
                    }
                }
            }
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.primary)
        .tint(.primary)
        .padding(.top, 10)
        .padding(.trailing, 14)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var authText: String {
        guard square.isConfigured else { return "No Square config" }
        switch square.authorizationState {
        case .authorized: return "Authorized"
        case .authorizing: return "Authorizing…"
        default: return "Not authorized"
        }
    }

    private var readerText: String {
        if square.readers.isEmpty { return "No readers" }
        return square.readers
            .map { "\(modelName($0.model)): \(statusName($0.statusInfo.status))" }
            .joined(separator: " · ")
    }

    private var catalogColor: Color {
        switch square.catalogStatus {
        case .ready: .green
        case .failed: .red
        case .loading, .notConfigured: .orange
        }
    }

    private var readerColor: Color {
        if square.readers.contains(where: { $0.statusInfo.status == .ready }) { return .green }
        return square.readers.isEmpty ? .red : .orange
    }

    private func modelName(_ model: ReaderModel) -> String {
        switch model {
        case .magstripe: "Magstripe"
        case .contactlessAndChip: "Contactless+Chip"
        case .stand: "Stand"
        case .tapToPay: "Tap to Pay"
        default: "Reader"
        }
    }

    private func statusName(_ status: ReaderStatus) -> String {
        switch status {
        case .ready: "Ready"
        case .connectingToDevice: "Connecting"
        case .connectingToSquare: "Connecting to Square"
        case .readerUnavailable: "Unavailable"
        case .faulty: "Faulty"
        @unknown default: "Unknown"
        }
    }
}

private struct StatusDot: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).lineLimit(1)
        }
    }
}

struct LogView: View {
    let entries: [LogEntry]

    var body: some View {
        NavigationStack {
            List(entries) { entry in
                VStack(alignment: .leading) {
                    Text(entry.date.formatted(date: .omitted, time: .standard))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(entry.message).font(.callout.monospaced()).textSelection(.enabled)
                }
            }
            .navigationTitle("Log")
        }
    }
}
