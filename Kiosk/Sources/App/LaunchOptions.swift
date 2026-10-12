import Foundation
import QuartzCore
import simd
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
    var toppingsScroll: Topping?

    static var current: LaunchOptions {
        let defaults = UserDefaults.standard
        var options = LaunchOptions()
        options.role = defaults.string(forKey: "kioskRole") ?? configuredRole
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
        if let toppings = defaults.string(forKey: "kioskToppings") {
            var item = options.current ?? IceCreamItem()
            item.toppings = parseToppings(toppings)
            options.current = item
            if options.screen == nil { options.screen = "builder" }
        }
        options.toppingsScroll = defaults.string(forKey: "kioskToppingsScroll").flatMap(Topping.init(rawValue:))
        options.name = defaults.string(forKey: "kioskCustomerName")
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

    private static var configuredRole: String? {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "KioskRole") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty || raw.hasPrefix("$(") ? nil : raw.lowercased()
    }

    /// `cone:vanilla,chocolate`, `cup` (no scoops), or with toppings in the order added:
    /// `cup:cookies+whip+gummies`.
    static func parseItem(_ text: String) -> IceCreamItem? {
        let base = text.prefix { $0 != "+" }
        let parts = base.split(separator: ":", maxSplits: 1).map(String.init)
        guard let first = parts.first, let vessel = Vessel(rawValue: first.trimmingCharacters(in: .whitespaces)) else { return nil }
        let flavors = parts.count > 1
            ? parts[1].split(separator: ",").compactMap { Flavor(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
            : []
        return IceCreamItem(vessel: vessel, flavors: Array(flavors.prefix(Pricing.maxScoopsPerItem)),
                            toppings: parseToppings(String(text.dropFirst(base.count))))
    }

    /// `whip+gummies`, in the order added.
    static func parseToppings(_ text: String) -> [Topping] {
        var toppings: [Topping] = []
        for name in text.split(separator: "+") {
            guard let topping = Topping(rawValue: name.trimmingCharacters(in: .whitespaces)), !toppings.contains(topping) else { continue }
            toppings.append(topping)
        }
        return toppings
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

    /// A finger dragging the order sheet down, paced in slow motion like the rest of the scene.
    private func pullSheet(from start: CGFloat, to end: CGFloat, seconds: Double) async -> CGFloat {
        let steps = max(Int(seconds * 60), 2)
        for i in 1...steps {
            app.dragSheet(by: start + (end - start) * CGFloat(i) / CGFloat(steps))
            await wait(seconds / Double(steps))
        }
        return end
    }

    private func select(_ vessel: Vessel) async {
        await tap(.vessel(vessel)) { app.selectVessel(vessel) }
    }

    private func toggle(_ topping: Topping) async {
        let card = app.stage.toppingCardFrame(topping)
        let margin = Layout.toppingCarouselMargin - 1
        if app.step == .toppings, card.minX < margin || card.maxX > Layout.screen.width - margin {
            await scrollToppings(to: topping)
        }
        await tap(.topping(topping)) { app.toggleTopping(topping) }
        log("toppings \(app.current.toppings.map(\.rawValue).joined(separator: ","))")
    }

    private func scrollToppings(to topping: Topping) async {
        withAnimation(.smooth(duration: 0.5)) { app.scrollToppings(to: topping) }
        await wait(0.8)
    }

    private func openToppings() async {
        if app.current.scoopCount == 0 { app.jumpToStep(.flavors); await add(.vanilla); await wait(1.0) }
        if app.step != .toppings { app.jumpToStep(.toppings); await wait(1.0) }
    }

    /// Whip and syrup going on and off under pieces, scoops added and removed under toppings, a vessel swap, the tray,
    /// lifting the item back out to edit, and the order sheet.
    private func toppingsTour() async {
        await openToppings()
        await wait(1.0)
        await toggle(.whip)
        await wait(3.0)
        await toggle(.whip)
        await wait(3.0)
        await toggle(.chocolate)
        await wait(2.5)
        await toggle(.chocolate)
        await wait(2.5)
        await toggle(.sprinkles)
        await wait(2.0)
        await toggle(.whip)
        await wait(3.0)
        app.jumpToStep(.flavors)
        await wait(1.0)
        if app.current.scoopCount < Pricing.maxScoopsPerItem { await add(.cookies); await wait(3.0) }
        if let last = app.current.flavors.last { app.removeScoop(last); await wait(3.0) }
        app.jumpToStep(.vessel)
        await wait(1.0)
        await select(app.current.vessel == .cup ? .cone : .cup)
        await wait(3.5)
        app.jumpToStep(.toppings)
        await wait(1.5)
        app.addToOrder()
        await wait(3.0)
        log("edit topped item")
        if let first = app.items.first { app.tapTrayItem(first.id) }
        await wait(3.0)
        log("view order")
        app.viewOrder()
        await wait(4.0)
    }

    func run(_ script: String) async {
        await wait(1.2)
        log("start \(script)")
        switch script {
        case "toppings":
            await openToppings()
            for topping in [Topping.whip, .gummies, .sprinkles] {
                await toggle(topping)
                await wait(1.2)
            }
            await toggle(.whip)
            await wait(1.2)
            await toggle(.gummies)
            await wait(1.2)
            await toggle(.chocolate)
            await wait(1.2)
            let built = app.current.toppings
            log("toppings built \(built.map(\.rawValue))")
            app.goForward()
            await wait(2.0)
            guard let id = app.items.last?.id else { break }
            app.tapTrayItem(id)
            await wait(2.0)
            log("toppings after edit \(app.current.toppings.map(\.rawValue)), \(app.current.toppings == built ? "restored" : "MISMATCH")")
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
        case "clip-tour":
            await clipTour()
        case "clip-interrupts":
            await clipInterrupts()
        case "toppings-tour":
            await toppingsTour()
        case "toppings-carousel":
            await openToppings()
            await wait(1.5)
            await scrollToppings(to: .chocolate)
            log("carousel middle")
            await wait(2.0)
            await scrollToppings(to: .sprinkles)
            log("carousel end")
            await wait(2.0)
            log("carousel toss")
            await toggle(.sprinkles)
            await wait(3.0)
            await toggle(.gummies)
            await wait(3.0)
            await scrollToppings(to: .whip)
            log("carousel start")
            await wait(2.0)
        case "toppings-syrups":
            await openToppings()
            await wait(1.5)
            log("pour chocolate")
            await toggle(.chocolate)
            await wait(2.0)
            log("pour caramel")
            await toggle(.caramel)
            await wait(2.0)
            await toggle(.gummies)
            await wait(2.5)
            log("chocolate off under caramel")
            await toggle(.chocolate)
            await wait(2.0)
            log("chocolate back over caramel")
            await toggle(.chocolate)
            await wait(2.0)
            app.addToOrder()
            await wait(3.0)
            app.viewOrder()
            await wait(4.0)
        case "toppings-candy":
            await openToppings()
            for topping in [Topping.gummies, .mms, .sprinkles] {
                await toggle(topping)
                await wait(2.0)
            }
            await toggle(.mms)
            await wait(2.5)
            app.addToOrder()
            await wait(3.0)
            app.viewOrder()
            await wait(4.0)
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
            app.jumpToStep(.vessel)
            await wait(1.6)
            app.goForward()
            await wait(0.8)
            await add(.cookies)
            await wait(1.6)
            app.goForward()
            await wait(1.6)
            app.goForward()
            await wait(2.5)
        case "vessel-new":
            await wait(0.6)
            app.selectVessel(.cone)
            await wait(1.2)
            app.goForward()
            await wait(0.8)
            await add(.chocolate)
            await wait(1.4)
            app.goBack()
            await wait(1.2)
            app.startNewItem()
            await wait(2.6)
            if let first = app.items.first { app.tapTrayItem(first.id) }
            await wait(2.0)
            app.jumpToStep(.vessel)
            await wait(1.2)
            app.startNewItem()
            await wait(3.0)
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
        case "edit-scroll":
            await wait(0.8)
            if let item = app.items.dropFirst(app.items.count - 2).first { app.tapTrayItem(item.id) }
            await wait(2.0)
            for target: CGFloat in [260, -40] {
                let steps = 60
                for i in 1...steps {
                    app.stage.trayDragChanged(target * CGFloat(i) / CGFloat(steps))
                    await wait(1.2 / Double(steps))
                }
                app.stage.trayDragEnded(predictedDx: target)
                await wait(1.5)
            }
        case "step-fade":
            await wait(1.0)
            app.goForward()
            await wait(1.5)
            app.goBack()
            await wait(1.5)
        case "pull-down":
            await wait(0.8)
            app.viewOrder()
            await wait(2.2)
            var offset: CGFloat = 0
            for (target, seconds) in [(90.0, 0.3), (170.0, 0.35), (60.0, 0.4), (30.0, 0.2)] {
                offset = await pullSheet(from: offset, to: target, seconds: seconds)
            }
            app.endSheetDrag(translation: offset, predicted: offset - 30, velocity: -150 * app.slowMotion)
            await wait(1.6)
            offset = await pullSheet(from: 0, to: 260, seconds: 0.35)
            app.endSheetDrag(translation: offset, predicted: offset + 180, velocity: 900 * app.slowMotion)
            await wait(2.0)
        case "sheet-oscillate":
            await sheetOscillation()
        case "sheet-stress":
            await SheetDragStress(app: app).run()
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
        case "pay":
            if app.screen != .name { app.completeOrder() }
            await wait(0.8)
            if app.customerName.isEmpty { app.setCustomerNameForScript("Alex") }
            app.submitName()
            await wait(3.0)
        case "demo":
            if app.screen == .attract {
                await wait(1.0)
                app.beginOrder(ignoringClosure: true)
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
        if let check = app.stage.clipCheck {
            for issue in check.takeIssues() { log(issue.text) }
            log(check.summary)
        }
        log("end \(script)")
    }

    /// One finger held on the order sheet throughout: slow pulls up and down, past the open position, all the
    /// way to the tray and a hold there, then a release at the bottom; then a pull to the bottom, a hold and a
    /// slow climb back that releases open.
    private func sheetOscillation() async {
        if app.mode != .summary { app.viewOrder() }
        await wait(2.2)
        var offset: CGFloat = 0
        let legs: [(CGFloat, Double)] = [(320, 1.2), (90, 0.9), (720, 1.6), (260, 1.1), (-70, 0.9), (1250, 2.2),
                                         (1250, 1.0), (520, 1.5), (1000, 1.2), (180, 1.6), (1250, 2.0), (1250, 1.0)]
        for (target, seconds) in legs {
            offset = await pullSheet(from: offset, to: target, seconds: seconds)
        }
        app.endSheetDrag(translation: offset, predicted: offset, velocity: 0)
        await wait(2.0)
        log("released at the bottom: \(app.mode == .summary ? "open" : "closed"), progress \(app.stage.sheet.value)")
        app.viewOrder()
        await wait(2.2)
        offset = 0
        for (target, seconds) in [(CGFloat(1250), 2.0), (1250, 1.2), (40, 2.2)] as [(CGFloat, Double)] {
            offset = await pullSheet(from: offset, to: target, seconds: seconds)
        }
        app.endSheetDrag(translation: offset, predicted: offset - 20, velocity: -80 * app.slowMotion)
        await wait(2.0)
        log("released after climbing back: \(app.mode == .summary ? "open" : "closed"), progress \(app.stage.sheet.value)")
    }

    /// Motions cut short by the next tap: a scoop still flying in when the one beneath it is taken off, and vessel
    /// swaps reversed before the scoops have landed. Starts on the vessel step with a cone holding vanilla.
    private func clipInterrupts() async {
        while app.stage.clipCheck == nil { try? await Task.sleep(for: .seconds(0.2)) }
        func step(_ name: String) { log("clip-interrupts \(name): \(app.current.vessel.rawValue) \(app.current.flavors.map(\.rawValue).joined(separator: ","))") }
        for vessel in [Vessel.cone, .cup] {
            app.jumpToStep(.vessel)
            await wait(0.5)
            if app.current.vessel != vessel { await select(vessel); await wait(1.6) }
            app.jumpToStep(.flavors)
            await wait(0.7)
            for (below, delay) in [(1, 0.1), (1, 0.25), (1, 0.4), (1, 0.55), (2, 0.1), (2, 0.3), (2, 0.5), (2, 0.7)] {
                for flavor in [Flavor.vanilla, .cookies].prefix(below) where app.count(of: flavor) == 0 {
                    await add(flavor)
                    await wait(1.6)
                }
                step("reflow from mid-air after \(delay)")
                await add(.chocolate)
                await wait(delay)
                app.removeScoop(.vanilla)
                await wait(2.0)
                app.removeScoop(.chocolate)
                app.removeScoop(.cookies)
                await wait(1.6)
            }
        }
        for count in 1...3 {
            app.jumpToStep(.flavors)
            await wait(0.6)
            while app.current.flavors.count < count { await add([Flavor.vanilla, .chocolate, .cookies][app.current.flavors.count]); await wait(1.6) }
            app.jumpToStep(.vessel)
            await wait(0.6)
            for gap in [0.15, 0.3, 0.45] {
                step("ping-pong \(gap)")
                await select(app.current.vessel == .cup ? .cone : .cup)
                await wait(gap)
                await select(app.current.vessel == .cup ? .cone : .cup)
                await wait(2.0)
            }
        }
    }

    /// Every way a scoop moves against a vessel: adds into each slot, transfers with 1-3 scoops both ways,
    /// top, middle and bottom removals, in the cup and the cone. Pair with the clip check's log lines.
    private func clipTour() async {
        func swap(to vessel: Vessel) async {
            app.jumpToStep(.vessel)
            await wait(0.6)
            await select(vessel)
            await wait(1.6)
            app.jumpToStep(.flavors)
            await wait(0.7)
        }
        func step(_ name: String) {
            log("clip-tour \(name): \(app.current.vessel.rawValue) \(app.current.flavors.map(\.rawValue).joined(separator: ","))")
        }
        while app.stage.clipCheck == nil { try? await Task.sleep(for: .seconds(0.2)) }
        app.jumpToStep(.flavors)
        await wait(0.8)
        step("cup adds")
        for flavor in [Flavor.vanilla, .chocolate, .cookies] {
            await add(flavor)
            await wait(1.8)
        }
        step("transfers with 3")
        await swap(to: .cone)
        await swap(to: .cup)
        step("cup top, re-add, middle")
        app.removeScoop(.cookies)
        await wait(1.8)
        await add(.cookies)
        await wait(1.8)
        app.removeScoop(.chocolate)
        await wait(2.2)
        step("transfer with 2")
        await swap(to: .cone)
        step("cone add, middle, top")
        await add(.chocolate)
        await wait(1.8)
        app.removeScoop(.cookies)
        await wait(2.2)
        app.removeScoop(.chocolate)
        await wait(1.8)
        step("transfers with 1")
        await swap(to: .cup)
        await swap(to: .cone)
        await swap(to: .cup)
        step("cup bottom removals")
        app.removeScoop(.vanilla)
        await wait(1.8)
        await add(.vanilla)
        await wait(1.8)
        await add(.chocolate)
        await wait(1.8)
        app.removeScoop(.vanilla)
        await wait(2.2)
        app.removeScoop(.chocolate)
        await wait(1.8)
        step("cone adds and bottom removal")
        await swap(to: .cone)
        for flavor in [Flavor.cookies, .vanilla, .chocolate] {
            await add(flavor)
            await wait(1.8)
        }
        app.removeScoop(.cookies)
        await wait(2.2)
        step("transfer with 2 back")
        await swap(to: .cup)
        await wait(1.0)
    }
}

/// Rapid random taps that a customer could make, then a consistency check once the scene settles.
@MainActor
struct StressRunner {
    let app: AppModel
    let includeTray: Bool

    fileprivate struct SplitMix: RandomNumberGenerator {
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

    private var cardsVisible: Bool { app.mode == .customize && app.confirmation == nil }

    func run() async {
        let defaults = UserDefaults.standard
        let seed = defaults.object(forKey: "kioskSeed") != nil ? UInt64(defaults.integer(forKey: "kioskSeed")) : UInt64(Date().timeIntervalSince1970)
        let rounds = defaults.object(forKey: "kioskStressRounds") != nil ? defaults.integer(forKey: "kioskStressRounds") : 20
        var rng = SplitMix(state: seed)
        log("seed \(seed), \(rounds) rounds, tray \(includeTray)")
        var failures = 0
        var clipRounds = 0
        var vesselRounds = 0
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
            let found = app.stage.clipCheck?.takeIssues() ?? []
            let clips = found.filter { !$0.isVessels }, overlaps = found.filter(\.isVessels)
            if clips.contains(where: \.isVisible) {
                clipRounds += 1
                log("round \(round) CLIP after [\(trace.joined(separator: " "))]: \(clips.filter(\.isVisible).map(\.text).joined(separator: "; "))")
            }
            for graze in clips where !graze.isVisible { log("round \(round) graze under \(ClipCheck.visibleDepth * 1000) mm: \(graze.text)") }
            if overlaps.contains(where: \.isVisible) {
                vesselRounds += 1
                log("round \(round) VESSELS after [\(trace.joined(separator: " "))]: \(overlaps.filter(\.isVisible).map(\.text).joined(separator: "; "))")
            }
        }
        log("done: \(rounds - failures)/\(rounds) rounds consistent, \(clipRounds) with a scoop through a vessel, \(vesselRounds) with vessels passing through each other, \(actions) actions, seed \(seed)")
        if let check = app.stage.clipCheck { log(check.summary) }
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

/// Feeds the order sheet's pull-down handlers everything a finger and the gesture system can: long slow
/// oscillations, reversals, pulls past the open position and below the tray, holds, flings, second-finger taps
/// and cancellations. While a pull is live the sheet must sit exactly under the finger; after each one it must
/// come to rest open or closed with its items on it. Every frame its progress must be finite and in range, and
/// the main thread must never stall.
@MainActor
struct SheetDragStress {
    let app: AppModel

    private enum Ending: CaseIterable {
        case release, fling, cancel, releaseThenCancel, cancelThenLateRelease, keepOrderingTap, checkOutTap, editTap
    }

    /// Pings the main thread from another every 20 ms; a reply that takes long is a stall.
    private final class Watch: @unchecked Sendable {
        private let lock = NSLock()
        private var worst = 0.0
        private let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))

        func start() {
            timer.schedule(deadline: .now(), repeating: .milliseconds(20))
            timer.setEventHandler { [self] in
                let sent = CACurrentMediaTime()
                DispatchQueue.main.async { [self] in
                    let lag = CACurrentMediaTime() - sent
                    lock.lock()
                    worst = max(worst, lag)
                    lock.unlock()
                }
            }
            timer.resume()
        }

        /// The longest main-thread lag since the last call.
        func take() -> Double {
            lock.lock()
            defer { worst = 0; lock.unlock() }
            return worst
        }

        func stop() { timer.cancel() }
    }

    private struct Lags {
        var worst = 0.0
        var stalls = 0

        mutating func add(_ lag: Double) {
            worst = max(worst, lag)
            if lag > 0.1 { stalls += 1 }
        }
    }

    private final class Tally {
        var updates = 0
        var frames = 0
        var issues: [String] = []
        var running = true
    }

    private func log(_ message: String) { app.square.record("SheetDrag: \(message)") }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    func run() async {
        let defaults = UserDefaults.standard
        let seed = defaults.object(forKey: "kioskSeed") != nil ? UInt64(defaults.integer(forKey: "kioskSeed")) : UInt64(Date().timeIntervalSince1970)
        let gestures = defaults.object(forKey: "kioskStressRounds") != nil ? defaults.integer(forKey: "kioskStressRounds") : 60
        var rng = StressRunner.SplitMix(state: seed)
        log("seed \(seed), \(gestures) gestures")
        let tally = Tally()
        let watch = Watch()
        watch.start()
        let monitor = Task { @MainActor in
            while tally.running {
                checkFrame(tally)
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
        if app.mode != .summary { app.viewOrder() }
        await settle(tally, "start")
        var failures = 0
        var dragLags = Lags()
        var settleLags = Lags()
        for index in 0..<gestures {
            let before = tally.issues.count
            _ = watch.take()
            let (trace, ending) = await gesture(&rng, tally)
            let dragLag = watch.take()
            await settle(tally, "gesture \(index)")
            if app.mode != .summary {
                app.viewOrder()
                await settle(tally, "reopen after gesture \(index)")
            }
            let settleLag = watch.take()
            dragLags.add(dragLag)
            settleLags.add(settleLag)
            let lags = String(format: "(main-thread lag %.0f ms dragging, %.0f ms settling)", dragLag * 1000, settleLag * 1000)
            let found = tally.issues[before...]
            if found.isEmpty {
                log("gesture \(index) OK: \(trace) \(ending) \(lags)")
            } else {
                failures += 1
                log("gesture \(index) FAIL: \(trace) \(ending) \(lags): \(found.prefix(6).joined(separator: "; "))")
            }
        }
        tally.running = false
        _ = await monitor.value
        watch.stop()
        log(String(format: "done: %d/%d gestures clean, %d drag updates, %d frames checked; worst main-thread lag %.0f ms while dragging (%d gestures over 100 ms), %.0f ms while settling or reopening (%d over 100 ms); seed %llu",
                   gestures - failures, gestures, tally.updates, tally.frames, dragLags.worst * 1000, dragLags.stalls,
                   settleLags.worst * 1000, settleLags.stalls, seed))
    }

    private func checkFrame(_ tally: Tally) {
        tally.frames += 1
        let value = CGFloat(app.stage.sheet.value)
        let published = app.stage.sheetModel.progress
        let range = SheetGeometry.progressRange
        if !value.isFinite || !published.isFinite {
            tally.issues.append("progress not finite (\(value), published \(published))")
        } else if value < range.lowerBound - 1e-6 || value > range.upperBound + 1e-6 {
            tally.issues.append("progress \(value) out of \(range)")
        }
        if app.isPullingSheet, !app.orderSheetMounted {
            tally.issues.append("pull live at \(value) with the sheet's gesture unmounted")
        }
    }

    /// One touch, from the first update the gesture reports (past its 12 pt minimum distance) to its end.
    private func gesture(_ rng: inout StressRunner.SplitMix, _ tally: Tally) async -> (String, Ending) {
        let rate = 1.0 / 120
        var offset: CGFloat = Bool.random(using: &rng) ? 12 : -12
        var lastStep: CGFloat = 0
        var expected: Float?
        var trace: [String] = []

        func move(to target: CGFloat) {
            if let expected, app.isPullingSheet, abs(app.stage.sheet.value - expected) > 1e-5 {
                tally.issues.append("sheet moved to \(app.stage.sheet.value) under a still finger at \(expected)")
            }
            lastStep = target - offset
            offset = target
            app.dragSheet(by: offset)
            tally.updates += 1
            guard app.isPullingSheet, let grab = app.stage.sheetGrab else {
                expected = nil
                return
            }
            let want = Float(app.stage.sheetProgress(grabbedAt: grab, offset: offset))
            if abs(app.stage.sheet.value - want) > 1e-5 {
                tally.issues.append("sheet at \(app.stage.sheet.value), finger says \(want)")
            }
            expected = app.stage.sheet.value
        }

        func glide(to target: CGFloat, seconds: Double) async {
            let from = offset
            let steps = max(Int(seconds / rate), 1)
            for i in 1...steps {
                let u = CGFloat(i) / CGFloat(steps)
                move(to: from + (target - from) * u * u * (3 - 2 * u))
                await sleep(rate)
            }
        }

        move(to: offset)
        let segments = 1 + Int(rng.next() % 8)
        for _ in 0..<segments {
            switch rng.next() % 7 {
            case 0:
                let center = CGFloat.random(in: 100...900, using: &rng)
                let amplitude = CGFloat.random(in: 30...500, using: &rng)
                let period = Double.random(in: 0.6...2.5, using: &rng)
                let cycles = Double.random(in: 1...4, using: &rng)
                trace.append("osc(\(Int(center))±\(Int(amplitude)))")
                let start = offset
                let steps = Int(period * cycles / rate)
                for i in 1...max(steps, 1) {
                    let t = Double(i) * rate
                    let wave = center + amplitude * CGFloat(sin(2 * .pi * t / period))
                    let blend = CGFloat(min(t / 0.3, 1))
                    move(to: start + (wave - start) * blend)
                    await sleep(rate)
                }
            case 1:
                let target = CGFloat.random(in: 1100...1600, using: &rng)
                trace.append("bottom(\(Int(target)))")
                await glide(to: target, seconds: Double.random(in: 0.4...2.5, using: &rng))
            case 2:
                let target = CGFloat.random(in: -500 ... -20, using: &rng)
                trace.append("above(\(Int(target)))")
                await glide(to: target, seconds: Double.random(in: 0.3...1.5, using: &rng))
            case 3:
                let seconds = Double.random(in: 0.1...1.5, using: &rng)
                trace.append(String(format: "hold(%.1fs)", seconds))
                await sleep(seconds)
            case 4:
                let target = CGFloat.random(in: -200...1500, using: &rng)
                trace.append("jump(\(Int(target)))")
                move(to: target)
                await sleep(rate)
            case 5:
                trace.append("jitter")
                for _ in 0..<Int(0.5 / rate) {
                    move(to: offset + CGFloat.random(in: -3...3, using: &rng))
                    await sleep(rate)
                }
            default:
                let target = CGFloat.random(in: -100...1300, using: &rng)
                trace.append("glide(\(Int(target)))")
                await glide(to: target, seconds: Double.random(in: 0.2...3, using: &rng))
            }
        }

        let ending = Ending.allCases[Int(rng.next() % UInt64(Ending.allCases.count))]
        var velocity = lastStep / CGFloat(rate)
        if trace.last?.hasPrefix("hold") == true { velocity = 0 }
        if ending == .fling { velocity = CGFloat.random(in: -4000...4000, using: &rng) }
        let predicted = offset + velocity * 0.25
        func release() { app.endSheetDrag(translation: offset, predicted: predicted, velocity: velocity) }
        switch ending {
        case .release, .fling:
            release()
        case .cancel:
            await Task.yield()
            app.abandonSheetDrag()
        case .releaseThenCancel:
            release()
            app.abandonSheetDrag()
        case .cancelThenLateRelease:
            app.abandonSheetDrag()
            release()
        case .keepOrderingTap:
            app.backToBuilder()
            await glide(to: offset + 200, seconds: 0.3)
            release()
        case .checkOutTap:
            app.completeOrder()
            if app.screen != .builder {
                tally.issues.append("Check Out went through mid-pull")
                app.backToSummary()
            }
            await glide(to: offset - 150, seconds: 0.3)
            release()
        case .editTap:
            if let item = app.items.randomElement(using: &rng) { app.tapTrayItem(item.id) }
            await glide(to: offset + 100, seconds: 0.2)
            release()
        }
        return (trace.joined(separator: " "), ending)
    }

    private func settle(_ tally: Tally, _ label: String) async {
        var waited = 0.0
        while !app.stage.isSettled, waited < 8 {
            await sleep(0.05)
            waited += 0.05
        }
        await sleep(0.05)
        let stage = app.stage
        var issues: [String] = []
        if !stage.isSettled {
            issues.append("never settled (progress \(stage.sheet.value), target \(stage.sheet.target), pulling \(app.isPullingSheet))")
        }
        let open = app.mode == .summary
        if open != stage.summaryActive { issues.append("mode \(app.mode) but sheet active \(stage.summaryActive)") }
        if abs(stage.sheet.value - (open ? 1 : 0)) > 1e-4 { issues.append("came to rest at \(stage.sheet.value) while \(open ? "open" : "closed")") }
        if abs(stage.sheetModel.progress - CGFloat(stage.sheet.value)) > 1e-4 { issues.append("SwiftUI sees \(stage.sheetModel.progress)") }
        for entry in stage.tray where entry.mode == .docked {
            guard let rig = entry.rig else { continue }
            if simd_length(rig.pose.position - stage.dockedPose(entry).pose.position) > 1e-4 {
                issues.append("item \(Int(entry.index)) left its \(open ? "row" : "slot")")
            }
        }
        issues += stage.consistencyIssues(current: open ? nil : app.current, items: app.items, editingID: app.editingID,
                                          showsCards: !open)
        tally.issues += issues.map { "\(label): \($0)" }
    }
}
