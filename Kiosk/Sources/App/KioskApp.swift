import SquareMobilePaymentsSDK
import SwiftUI

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if let applicationID = Config.squareApplicationID {
            MobilePaymentsSDK.initialize(
                applicationLaunchOptions: launchOptions,
                squareApplicationID: applicationID
            )
        }
        installExceptionLogger()
        application.isIdleTimerDisabled = true
        return true
    }

    /// Crash reports from the device omit the exception reason, so write it to kiosk.log, then hand
    /// the exception on to the handler Square's crash reporter installed.
    private func installExceptionLogger() {
        AppDelegate.previousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            SquareService.appendToLogFile("Uncaught \(exception.name.rawValue): \(exception.reason ?? "no reason")")
            AppDelegate.previousExceptionHandler?(exception)
        }
    }

    nonisolated(unsafe) private static var previousExceptionHandler: (@convention(c) (NSException) -> Void)?
}

@main
struct KioskApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var app = AppModel()

    var body: some SwiftUI.Scene {
        WindowGroup {
            RootView(app: app)
        }
    }
}
