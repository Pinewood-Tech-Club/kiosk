import SquareMobilePaymentsSDK
import UIKit

@MainActor
enum BoothHealth {
    static func snapshot(square: SquareService, screen: String, simulatePayment: Bool) -> KioskHealth {
        let lastError = square.log.first { entry in
            guard !entry.message.hasPrefix("Booth") else { return false }
            let lowered = entry.message.lowercased()
            return ["failed", "error", "uncaught", "warning"].contains { lowered.contains($0) }
        }
        let readers = square.readers
        return KioskHealth(
            appVersion: BoothIdentity.appVersion,
            environment: square.environmentName,
            authorized: square.isAuthorized,
            authorizationState: authorizationName(square.authorizationState),
            readers: readers.map(readerHealth),
            readerReady: readers.contains { $0.statusInfo.status == .ready },
            catalog: catalogHealth(square.catalogStatus),
            deviceBattery: deviceBattery(),
            simulatePayment: simulatePayment,
            screen: screen,
            lastError: lastError.map { String($0.message.prefix(300)) },
            lastErrorAt: lastError.map { BoothTime.string($0.date) },
            flavors: Flavor.allCases.map { KioskHealth.FlavorInfo(id: $0.rawValue, name: $0.title) }
        )
    }

    private static func authorizationName(_ state: AuthorizationState) -> String {
        switch state {
        case .authorized: "authorized"
        case .authorizing: "authorizing"
        default: "notAuthorized"
        }
    }

    private static func readerHealth(_ reader: ReaderInfo) -> KioskHealth.Reader {
        KioskHealth.Reader(
            name: reader.name,
            model: modelName(reader.model),
            state: stateName(reader.statusInfo),
            batteryPercent: reader.batteryStatus.map { Int($0.percentage) },
            isCharging: reader.batteryStatus?.isCharging
        )
    }

    private static func modelName(_ model: ReaderModel) -> String {
        switch model {
        case .magstripe: "magstripe"
        case .contactlessAndChip: "contactlessAndChip"
        case .stand: "stand"
        case .tapToPay: "tapToPay"
        default: "unknown"
        }
    }

    private static func stateName(_ info: ReaderStatusInfo) -> String {
        switch info.status {
        case .ready: return "ready"
        case .connectingToDevice, .connectingToSquare: return "connecting"
        case .faulty: return "faulty"
        case .readerUnavailable:
            switch info.unavailableReasonInfo?.reason {
            case .blockingFirmwareUpdate: return "updating"
            case .bluetoothDisabled: return "disabled"
            case nil: return "unavailable"
            default: return "failedToConnect"
            }
        @unknown default: return "unknown"
        }
    }

    private static func catalogHealth(_ status: SquareService.CatalogStatus) -> KioskHealth.Catalog {
        if case .failed(let message) = status {
            return KioskHealth.Catalog(ok: false, status: status.badgeText, error: message)
        }
        return KioskHealth.Catalog(ok: true, status: status.badgeText, error: nil)
    }

    private static func deviceBattery() -> KioskHealth.Battery? {
        let device = UIDevice.current
        guard device.batteryLevel >= 0 else { return nil }
        return KioskHealth.Battery(
            percent: Int((device.batteryLevel * 100).rounded()),
            charging: device.batteryState == .charging || device.batteryState == .full
        )
    }
}

extension AppModel.Screen {
    var boothName: String {
        switch self {
        case .roleSetup: "roleSetup"
        case .attract: "attract"
        case .builder: "builder"
        case .name: "name"
        case .confirmation: "confirmation"
        }
    }
}
