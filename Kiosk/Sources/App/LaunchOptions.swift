import Foundation
import SwiftUI

/// Testing hooks, read from launch arguments such as `-kioskScreen builder -kioskStep flavors`.
struct LaunchOptions {
    var role: String?
    var screen: String?
    var step: BuilderStep?
    var items: [IceCreamItem] = []
    var current: IceCreamItem?
    var name: String?
    var script: String?
    var slowMotion: Double?
    var debug3D = false
    var simulatePayment: Bool?
    var hideDebugBar: Bool?

    static var current: LaunchOptions {
        let defaults = UserDefaults.standard
        var options = LaunchOptions()
        options.role = defaults.string(forKey: "kioskRole")
        options.screen = defaults.string(forKey: "kioskScreen")
        options.script = defaults.string(forKey: "kioskScript")
        if defaults.bool(forKey: "kioskAutoplay") { options.script = "demo" }
        if options.script != nil, options.role == nil { options.role = "kiosk" }
        if let step = defaults.string(forKey: "kioskStep") {
            options.step = BuilderStep.allCases.first { $0.title.lowercased() == step.lowercased() }
            if options.screen == nil { options.screen = "builder" }
        }
        if let items = defaults.string(forKey: "kioskItems") {
            options.items = items.split(separator: ";").compactMap { parseItem(String($0)) }
        }
        if let current = defaults.string(forKey: "kioskCurrent") {
            options.current = parseItem(current)
            if options.screen == nil { options.screen = "builder" }
        }
        options.name = defaults.string(forKey: "kioskName")
        if defaults.object(forKey: "kioskSlowmo") != nil {
            options.slowMotion = defaults.double(forKey: "kioskSlowmo")
        }
        options.debug3D = defaults.bool(forKey: "kioskDebug3D")
        if defaults.object(forKey: "kioskSimulatePayment") != nil {
            options.simulatePayment = defaults.bool(forKey: "kioskSimulatePayment")
        }
        if defaults.object(forKey: "kioskHideDebugBar") != nil {
            options.hideDebugBar = defaults.bool(forKey: "kioskHideDebugBar")
        }
        if options.screen != nil, options.role == nil { options.role = "kiosk" }
        return options
    }

    /// `cone:vanilla,chocolate` or `cup` (no scoops).
    static func parseItem(_ text: String) -> IceCreamItem? {
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        guard let first = parts.first, let vessel = Vessel(rawValue: first.trimmingCharacters(in: .whitespaces)) else { return nil }
        let flavors = parts.count > 1
            ? parts[1].split(separator: ",").compactMap { Flavor(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
            : []
        return IceCreamItem(vessel: vessel, flavors: Array(flavors.prefix(Pricing.maxScoopsPerItem)))
    }
}

@MainActor
struct ScriptRunner {
    let app: AppModel

    private func wait(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds / max(app.slowMotion, 0.01)))
    }

    private func log(_ message: String) {
        app.square.record("Script: \(message)")
    }

    private func drag(_ total: CGSize, duration: Double) async {
        let steps = max(Int(duration * 60), 2)
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            app.stage.dragChanged(translation: CGSize(width: total.width * t, height: total.height * t))
            try? await Task.sleep(for: .seconds(duration / Double(steps)))
        }
        app.stage.dragEnded()
    }

    func run(_ script: String) async {
        await wait(1.2)
        log("start \(script)")
        switch script {
        case "vessel-to-cone":
            await wait(1.0)
            app.selectVessel(.cone)
            await wait(2.2)
            app.selectVessel(.cup)
            await wait(2.2)
        case "vessel-pingpong":
            app.selectVessel(.cone)
            await wait(0.4)
            app.selectVessel(.cup)
            await wait(0.35)
            app.selectVessel(.cone)
            await wait(2.5)
        case "bounce":
            await wait(0.5)
            app.selectVessel(app.current.vessel)
            await wait(1.0)
        case "scoops":
            if app.step != .flavors { app.goForward(); await wait(0.8) }
            app.addScoop(.vanilla)
            await wait(1.6)
            app.addScoop(.chocolate)
            await wait(1.6)
            app.addScoop(.cookies)
            await wait(2.0)
            app.undoScoop()
            await wait(1.6)
        case "scoops-rapid":
            if app.step != .flavors { app.goForward(); await wait(0.8) }
            app.addScoop(.cookies)
            await wait(0.25)
            app.addScoop(.chocolate)
            await wait(0.25)
            app.addScoop(.vanilla)
            await wait(2.5)
        case "back-swap":
            await wait(0.5)
            app.goBack()
            await wait(0.8)
            app.selectVessel(app.current.vessel == .cup ? .cone : .cup)
            await wait(2.5)
        case "add-to-order":
            await wait(0.6)
            if app.step != .toppings { app.goForward(); await wait(0.6) }
            if app.step != .toppings { app.goForward(); await wait(0.6) }
            app.addToOrder()
            await wait(3.0)
        case "drag":
            await wait(0.5)
            await drag(CGSize(width: 260, height: 140), duration: 0.6)
            await wait(6.0)
            await drag(CGSize(width: -30, height: 12), duration: 0.25)
            await wait(3.0)
        case "tray-remove":
            await wait(0.8)
            if let target = app.items.dropFirst().first, let center = app.stage.trayItemCenter(target.id) {
                let hit = app.stage.trayItem(at: center)
                log("tray hit-test at \(Int(center.x)),\(Int(center.y)) -> \(hit == target.id ? "match" : "MISMATCH")")
                app.removeItem(target.id)
            }
            await wait(1.5)
        case "demo":
            if app.screen == .attract {
                await wait(1.0)
                app.beginOrder()
                await wait(2.2)
            }
            app.selectVessel(.cone)
            await wait(1.6)
            app.goForward()
            await wait(0.8)
            app.addScoop(.chocolate)
            await wait(1.3)
            app.addScoop(.vanilla)
            await wait(1.5)
            app.goForward()
            await wait(1.0)
            app.addToOrder()
            await wait(2.4)
            app.goForward()
            await wait(0.8)
            app.addScoop(.cookies)
            await wait(1.6)
            app.goForward()
            await wait(0.8)
            app.addToOrder()
            await wait(2.4)
            app.viewOrder()
            await wait(2.5)
            app.completeOrder()
            await wait(1.5)
            app.setCustomerNameForScript("Alex")
            await wait(1.0)
            app.submitName()
            await wait(5.0)
        default:
            log("unknown script \(script)")
        }
        log("end \(script)")
    }
}
