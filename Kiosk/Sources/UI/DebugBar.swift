import SquareMobilePaymentsSDK
import SwiftUI

struct DebugBar: View {
    @Bindable var app: AppModel

    private var square: SquareService { app.square }

    var body: some View {
        HStack(spacing: 8) {
            Badge(text: square.environmentName, color: square.isSandbox ? .orange : (square.isConfigured ? .green : .red))
            Badge(text: authText, color: square.isAuthorized ? .green : .red)
            Badge(text: readerText, color: readerColor)
            if app.simulatePayment { Badge(text: "Simulated pay", color: .purple) }
            if app.slowMotion != 1 { Badge(text: "×\(app.slowMotion.formatted())", color: .blue) }
            Spacer(minLength: 8)
            if square.isSandbox, square.isAuthorized {
                Button(square.isMockReaderPresented ? "Hide Mock Reader" : "Mock Reader") { square.toggleMockReader() }
            }
            Button("Readers") { square.presentReaderSettings(from: app.host.presenter) }
                .disabled(!square.isAuthorized)
            Button("Log") { app.showsLog = true }
            Menu("Debug") {
                Toggle("Simulate payment success", isOn: $app.simulatePayment)
                Picker("Animation speed", selection: $app.slowMotion) {
                    Text("Normal").tag(1.0)
                    Text("0.5× slow-mo").tag(0.5)
                    Text("0.25× slow-mo").tag(0.25)
                    Text("0.1× slow-mo").tag(0.1)
                }
                Toggle("Show 3D debug info", isOn: $app.show3DDebug)
                Divider()
                Button("Change role") { app.changeRole() }
                Button("Hide debug bar (triple-tap top-left to restore)") {
                    withAnimation(.easeInOut(duration: 0.25)) { app.debugBarHidden = true }
                }
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(.primary)
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(.regularMaterial, in: .capsule)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .environment(\.colorScheme, .light)
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

private struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.15), in: .capsule)
            .foregroundStyle(color)
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
