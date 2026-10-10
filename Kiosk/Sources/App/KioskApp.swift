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
        application.isIdleTimerDisabled = true
        return true
    }
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
