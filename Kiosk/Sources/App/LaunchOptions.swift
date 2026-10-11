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

    private func tap(_ card: CardKey, action: () -> Void) async {
        app.setPressed(card, true)
        try? await Task.sleep(for: .seconds(0.09))
        app.setPressed(card, false)
        action()
    }

    private func add(_ flavor: Flavor) async {
        await tap(.flavor(flavor)) { app.addScoop(flavor) }
    }

    private func select(_ vessel: Vessel) async {
        await tap(.vessel(vessel)) { app.selectVessel(vessel) }
    }

    func run(_ script: String) async {
        await wait(1.2)
        log("start \(script)")
        switch script {
        case "vessel-to-cone":
            await wait(1.0)
            await select(.cone)
            await wait(2.2)
            await select(.cup)
            await wait(2.2)
        case "vessel-pingpong":
            await select(.cone)
            await wait(0.4)
            await select(.cup)
            await wait(0.35)
            await select(.cone)
            await wait(2.5)
        case "bounce":
            await wait(0.5)
            await select(app.current.vessel)
            await wait(1.0)
        case "scoops":
            if app.step != .flavors { app.goForward(); await wait(0.8) }
            await add(.vanilla)
            await wait(1.6)
            await add(.chocolate)
            await wait(1.6)
            await add(.cookies)
            await wait(2.0)
            app.removeScoop(.cookies)
            await wait(1.6)
        case "scoops-rapid":
            if app.step != .flavors { app.goForward(); await wait(0.8) }
            await add(.cookies)
            await wait(0.25)
            await add(.chocolate)
            await wait(0.25)
            await add(.vanilla)
            await wait(2.5)
        case "press-hold":
            await wait(0.5)
            app.setPressed(.vessel(.cup), true)
            app.setPressed(.vessel(.cone), true)
            try? await Task.sleep(for: .seconds(6))
            app.setPressed(.vessel(.cup), false)
            app.setPressed(.vessel(.cone), false)
            await wait(1)
        case "remove-middle":
            await wait(0.6)
            app.removeScoop(.chocolate)
            await wait(2.5)
        case "back-swap":
            await wait(0.5)
            app.goBack()
            await wait(0.8)
            await select(app.current.vessel == .cup ? .cone : .cup)
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
        case "edit":
            await wait(0.8)
            if let first = app.items.first { app.tapTrayItem(first.id) }
            await wait(2.0)
            app.jumpToStep(.flavors)
            await wait(0.8)
            await add(.cookies)
            await wait(1.6)
            app.jumpToStep(.toppings)
            await wait(0.8)
            app.goForward()
            await wait(2.5)
        case "edit-done":
            await wait(0.8)
            if let first = app.items.first { app.tapTrayItem(first.id) }
            await wait(2.4)
            app.finishEditing(then: .newItem)
            await wait(3.0)
        case "edit-new":
            await wait(0.8)
            if let first = app.items.first { app.tapTrayItem(first.id) }
            await wait(2.0)
            app.jumpToStep(.flavors)
            await wait(0.8)
            await add(.vanilla)
            await wait(1.6)
            app.startNewItem()
            await wait(3.0)
        case "edit-switch":
            await wait(0.8)
            if let first = app.items.first { app.tapTrayItem(first.id) }
            await wait(2.2)
            if let last = app.items.last { app.tapTrayItem(last.id) }
            await wait(3.0)
        case "edit-empty":
            await wait(0.8)
            if let first = app.items.first { app.tapTrayItem(first.id) }
            await wait(2.0)
            app.jumpToStep(.flavors)
            await wait(0.8)
            for flavor in app.current.flavors.reversed() {
                app.removeScoop(flavor)
                await wait(0.9)
            }
            app.finishEditing(then: .newItem)
            await wait(2.0)
        case "edit-adds":
            await wait(0.8)
            if let first = app.items.first { app.tapTrayItem(first.id) }
            await wait(2.0)
            app.jumpToStep(.flavors)
            await wait(0.8)
            for flavor in app.current.flavors.reversed() {
                app.removeScoop(flavor)
                await wait(1.2)
            }
            await wait(0.6)
            await add(.chocolate)
            await wait(2.4)
            await add(.vanilla)
            await wait(2.4)
            await add(.cookies)
            await wait(2.4)
        case "fresh":
            await wait(0.6)
            app.goForward()
            await wait(0.8)
            await add(.chocolate)
            await wait(1.4)
            app.startNewItem()
            await wait(2.6)
            app.goForward()
            await wait(0.8)
            await add(.vanilla)
            await wait(1.4)
            await add(.cookies)
            await wait(1.4)
            app.startNewItem()
            await wait(3.0)
        case "tray-scroll":
            await wait(0.8)
            for target: CGFloat in [150, 0, -40] {
                let steps = 40
                for i in 1...steps {
                    app.stage.trayDragChanged(target * CGFloat(i) / CGFloat(steps))
                    try? await Task.sleep(for: .seconds(0.9 / Double(steps)))
                }
                app.stage.trayDragEnded(predictedDx: target)
                await wait(1.2)
            }
            app.goForward()
            await wait(0.6)
            await add(.chocolate)
            await wait(1.4)
            app.addToOrder()
            await wait(2.5)
        case "step-fade":
            await wait(1.0)
            app.goForward()
            await wait(1.5)
            app.goBack()
            await wait(1.5)
        case "pull-down":
            await wait(0.8)
            app.viewOrder()
            await wait(2.4)
            for distance in [60.0, 120, 70, 20] {
                let steps = 20
                let start = app.sheetDrag
                for i in 1...steps {
                    app.dragSheet(by: start + (distance - start) * Double(i) / Double(steps))
                    try? await Task.sleep(for: .seconds(0.4 / Double(steps)))
                }
            }
            app.endSheetDrag(translation: 20, predicted: 40)
            await wait(1.5)
            for i in 1...24 {
                app.dragSheet(by: 220 * Double(i) / 24)
                try? await Task.sleep(for: .seconds(0.3 / 24))
            }
            app.endSheetDrag(translation: 220, predicted: 600)
            await wait(2.5)
        case "summary":
            await wait(0.8)
            app.viewOrder()
            await wait(2.5)
            app.backToBuilder()
            await wait(2.5)
        case "name-pingpong":
            let dwells = [0.2, 0.45, 0.5, 0.6, 0.9, 1.5, 0.3, 0.55]
            for round in 0..<40 {
                app.completeOrder()
                await wait(dwells[round % dwells.count])
                app.backToSummary()
                await wait(dwells[(round + 3) % dwells.count])
                log("name round \(round)")
            }
        case "swap-continue":
            await wait(0.6)
            await select(.cone)
            await wait(0.45)
            await select(.cup)
            await wait(0.3)
            app.goForward()
            await wait(2.5)
        case "vessel-spam":
            for gap in [0.5, 0.3, 0.6, 0.2, 0.45, 0.25, 0.7, 0.15] {
                await select(app.current.vessel == .cup ? .cone : .cup)
                try? await Task.sleep(for: .seconds(gap))
            }
            await wait(4)
            let issues = app.stage.consistencyIssues(current: app.current, items: app.items, editingID: app.editingID, showsCards: true)
            log(issues.isEmpty ? "vessel-spam consistent" : "vessel-spam FAIL: " + issues.joined(separator: "; "))
        case "stress", "stress-tray":
            await StressRunner(app: app, includeTray: script == "stress-tray").run()
        case "tray-remove":
            await wait(0.8)
            if let target = app.items.dropFirst().first {
                app.delete(target.id)
            }
            await wait(1.5)
        case "demo":
            if app.screen == .attract {
                await wait(1.0)
                app.beginOrder()
                await wait(2.2)
            }
            await select(.cone)
            await wait(1.6)
            app.goForward()
            await wait(0.8)
            await add(.chocolate)
            await wait(1.3)
            await add(.vanilla)
            await wait(1.5)
            app.goForward()
            await wait(1.0)
            app.addToOrder()
            await wait(2.4)
            app.goForward()
            await wait(0.8)
            await add(.cookies)
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

/// Rapid random taps that a customer could make, then a consistency check once the scene settles.
@MainActor
struct StressRunner {
    let app: AppModel
    let includeTray: Bool

    private struct SplitMix {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func pick<T>(_ values: [T]) -> T { values[Int(next() % UInt64(values.count))] }
    }

    private func log(_ message: String) { app.square.record("Stress: \(message)") }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private var cardsVisible: Bool { app.mode == .customize && !app.itemInFlight && app.confirmation == nil }

    func run() async {
        let defaults = UserDefaults.standard
        let seed = defaults.object(forKey: "kioskSeed") != nil ? UInt64(defaults.integer(forKey: "kioskSeed")) : UInt64(Date().timeIntervalSince1970)
        let rounds = defaults.object(forKey: "kioskStressRounds") != nil ? defaults.integer(forKey: "kioskStressRounds") : 20
        var rng = SplitMix(state: seed)
        log("seed \(seed), \(rounds) rounds, tray \(includeTray)")
        var failures = 0
        var actions = 0
        for round in 0..<rounds {
            let burst = 6 + Int(rng.next() % 30)
            var trace: [String] = []
            for _ in 0..<burst {
                if let action = await act(&rng) {
                    trace.append(action)
                    actions += 1
                }
                let r = rng.unit()
                await sleep(r < 0.6 ? 0.02 + rng.unit() * 0.13 : (r < 0.9 ? 0.15 + rng.unit() * 0.45 : 0.6 + rng.unit() * 0.9))
            }
            var waited = 0.0
            while !app.stage.isSettled, waited < 10 {
                await sleep(0.1)
                waited += 0.1
            }
            await sleep(0.1)
            let issues = check(settled: app.stage.isSettled)
            if issues.isEmpty {
                log("round \(round) OK: \(state)")
            } else {
                failures += 1
                log("round \(round) FAIL after [\(trace.joined(separator: " "))]: \(issues.joined(separator: "; "))")
            }
        }
        log("done: \(rounds - failures)/\(rounds) rounds consistent, \(actions) actions, seed \(seed)")
    }

    private var state: String {
        let current = app.mode == .summary ? "summary" : "\(app.current.vessel.rawValue):\(app.current.flavors.map(\.rawValue).joined(separator: ","))"
        return "\(app.step.title.lowercased()) \(current) tray \(app.items.count)\(app.isEditing ? " editing" : "")"
    }

    private func check(settled: Bool) -> [String] {
        var issues = settled ? [] : ["never settled (\(app.stage.activeAnimationCount) tweens, \(app.stage.morphingCount) morphing)"]
        issues += app.stage.consistencyIssues(current: app.mode == .summary ? nil : app.current, items: app.items,
                                              editingID: app.editingID, showsCards: app.mode == .customize)
        return issues
    }

    private func tap(_ card: CardKey, action: () -> Void) async {
        app.setPressed(card, true)
        await sleep(0.04 + Double.random(in: 0...0.06))
        app.setPressed(card, false)
        action()
    }

    private func act(_ rng: inout SplitMix) async -> String? {
        if app.confirmation != nil {
            if let confirmation = app.confirmation, rng.unit() < 0.5 { app.confirm(confirmation) } else { app.confirmation = nil }
            return "confirm"
        }
        if app.mode == .summary {
            if rng.unit() < 0.6 { app.backToBuilder(); return "back" }
            if let item = app.items.randomElement() { app.tapTrayItem(item.id); return "edit" }
            return nil
        }
        let r = rng.unit()
        if includeTray, r < 0.18 {
            switch rng.next() % 5 {
            case 0:
                guard app.canStartNewItem else { return nil }
                app.startNewItem(); return "new"
            case 1:
                guard !app.items.isEmpty else { return nil }
                let item = app.items[Int(rng.next() % UInt64(app.items.count))]
                app.tapTrayItem(item.id); return "tray\(app.items.firstIndex { $0.id == item.id } ?? -1)"
            case 2:
                guard app.canViewOrder else { return nil }
                app.viewOrder(); return "view"
            case 3:
                guard let id = app.editingID else { return nil }
                app.delete(id); return "delete"
            default:
                guard app.isEditing, cardsVisible else { return nil }
                app.finishEditing(then: .newItem); return "done"
            }
        }
        guard cardsVisible else { return nil }
        switch app.step {
        case .vessel where r < 0.7:
            let vessel: Vessel = rng.pick(Vessel.allCases)
            await tap(.vessel(vessel)) { app.selectVessel(vessel) }
            return vessel.rawValue
        case .flavors where r < 0.45:
            guard app.current.scoopCount < Pricing.maxScoopsPerItem else { return nil }
            let flavor: Flavor = rng.pick(Flavor.allCases)
            await tap(.flavor(flavor)) { app.addScoop(flavor) }
            return "+" + flavor.rawValue
        case .flavors where r < 0.7:
            let present = Flavor.allCases.filter { app.count(of: $0) > 0 }
            guard !present.isEmpty else { return nil }
            let flavor: Flavor = rng.pick(present)
            app.removeScoop(flavor)
            return "-" + flavor.rawValue
        default:
            let s = rng.unit()
            if s < 0.4 {
                let target: BuilderStep = rng.pick(BuilderStep.allCases)
                app.jumpToStep(target)
                return "@" + target.title.lowercased()
            } else if s < 0.7 {
                app.goBack()
                return "<"
            } else {
                if app.step == .toppings, !includeTray || app.isEditing { return nil }
                app.goForward()
                return ">"
            }
        }
    }
}
