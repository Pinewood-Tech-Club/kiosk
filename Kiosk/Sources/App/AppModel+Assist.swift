import Foundation

extension AppModel {
    enum AssistOutcome: Equatable {
        case applied
        case rejected(String)
    }

    func assistSession(assisted: Bool, results: [AssistSession.Result]) -> AssistSession {
        var screenName = screen.boothName
        var stepName: String?
        var lines: [AssistSession.Item] = []
        var total = 0
        var donation = 0
        switch screen {
        case .builder where mode == .customize:
            stepName = step.title.lowercased()
            let quote = liveQuote
            lines = quote.lines.map { line in
                Self.sessionItem(line.item, cents: line.totalCents, current: line.item.id == current.id, inOrder: true)
            }
            if !lines.contains(where: \.current) {
                lines.append(Self.sessionItem(current, cents: 0, current: true, inOrder: false))
            }
            total = quote.totalCents
            donation = quote.donationCents
        case .builder, .name, .confirmation:
            if screen == .builder { screenName = "summary" }
            let quote = orderQuote
            lines = quote.lines.map { Self.sessionItem($0.item, cents: $0.totalCents, current: false, inOrder: true) }
            total = quote.totalCents
            donation = quote.donationCents
        case .roleSetup, .attract, .staff:
            break
        }
        return AssistSession(screen: screenName, step: stepName, editing: screen == .builder && mode == .customize && isEditing,
                             items: lines, customerName: customerName, totalCents: total, donationCents: donation, paying: isPaying || giftCard != nil,
                             orderingOpen: orderingOpen, assisted: assisted, maxScoops: Pricing.maxScoopsPerItem, results: results)
    }

    private static func sessionItem(_ item: IceCreamItem, cents: Int, current: Bool, inOrder: Bool) -> AssistSession.Item {
        AssistSession.Item(id: item.id.uuidString, vessel: item.vessel.rawValue, flavors: item.flavors.map(\.rawValue),
                           toppings: item.toppings.map(\.rawValue), cents: cents, current: current, inOrder: inOrder)
    }

    func applyAssist(_ op: AssistCommand.Op) async -> AssistOutcome {
        guard role == .kiosk else { return .rejected("This iPad isn't running as a kiosk") }
        guard !isPaying, giftCard == nil else { return .rejected("Payment is in progress on the kiosk") }
        switch op {
        case .unsupported(let reason):
            return .rejected(reason)
        case .startOver:
            switch screen {
            case .builder, .name, .confirmation:
                confirmation = nil
                resetToAttract()
                return .applied
            case .attract:
                return .applied
            case .roleSetup, .staff:
                return .rejected("The kiosk isn't taking orders")
            }
        case .navigate(let destination):
            return await assistNavigate(to: destination)
        case .setName(let name):
            guard screen == .builder || screen == .name else { return .rejected("No order in progress") }
            customerName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
            return .applied
        case .addItem:
            return await assistAddItem()
        case .removeItem(let item):
            return await assistRemoveItem(item)
        case .addScoop(let item, let flavor):
            if booth.isSoldOut(flavor) { return .rejected("\(flavor.title) is sold out") }
            if let problem = await assistFocus(item, step: .flavors) { return .rejected(problem) }
            guard current.scoopCount < Pricing.maxScoopsPerItem else { return .rejected("\(Pricing.maxScoopsPerItem) scoops max") }
            let before = current.scoopCount
            addScoop(flavor)
            return current.scoopCount > before ? .applied : .rejected("Couldn't add the scoop")
        case .removeScoop(let item, let flavor):
            if let problem = await assistFocus(item, step: .flavors) { return .rejected(problem) }
            guard current.flavors.contains(flavor) else { return .rejected("No \(flavor.title) scoop on that item") }
            removeScoop(flavor)
            return .applied
        case .setVessel(let item, let vessel):
            if booth.isSoldOut(vessel) { return .rejected("\(vessel == .cup ? "Cups are" : "Waffle cones are") sold out") }
            if let problem = await assistFocus(item, step: .vessel) { return .rejected(problem) }
            selectVessel(vessel)
            return current.vessel == vessel ? .applied : .rejected("Couldn't change the cup or cone")
        case .setTopping(let item, let topping, let on):
            if on, booth.isSoldOut(topping) { return .rejected("\(topping.title) is sold out") }
            if let problem = await assistFocus(item, step: .toppings) { return .rejected(problem) }
            if on { addTopping(topping) } else { removeTopping(topping) }
            return hasTopping(topping) == on ? .applied : .rejected("Couldn't change \(topping.title)")
        }
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func assistFocus(_ itemID: String, step target: BuilderStep) async -> String? {
        guard let id = UUID(uuidString: itemID) else { return "That item is no longer in the order" }
        if screen == .name {
            backToSummary()
            await pause(0.5)
        }
        guard screen == .builder else { return "No order in progress" }
        if mode != .customize || current.id != id {
            guard items.contains(where: { $0.id == id }) else { return "That item is no longer in the order" }
            if isEditing, current.scoopCount == 0 { return "The item being edited has no scoops left" }
            tapTrayItem(id)
            await pause(0.6)
            guard mode == .customize, current.id == id else { return "Couldn't open that item" }
        }
        if step != target {
            if target == .toppings, current.scoopCount == 0 { return "Add a scoop first" }
            jumpToStep(target)
            await pause(0.45)
        }
        return nil
    }

    private func assistNavigate(to destination: AssistDestination) async -> AssistOutcome {
        if screen == .confirmation { return .rejected("This order is paid. Start over for a new one.") }
        if screen == .roleSetup || screen == .staff { return .rejected("The kiosk isn't taking orders") }
        switch destination {
        case .builder:
            if screen == .attract {
                guard orderingOpen else { return .rejected("This kiosk is closed") }
                guard stageReady, !assetsFailed else { return .rejected("The kiosk isn't ready yet") }
                await beginOrder()
                return screen == .builder ? .applied : .rejected("Couldn't start an order")
            }
            if screen == .name {
                backToSummary()
                await pause(0.5)
            }
            if mode == .summary { backToBuilder() }
            return .applied
        case .summary:
            if screen == .attract { return .rejected("No order in progress") }
            if screen == .name {
                backToSummary()
                return .applied
            }
            if mode == .summary { return .applied }
            if isEditing, current.scoopCount == 0 { return .rejected("The item being edited has no scoops left") }
            guard canViewOrder else { return .rejected("The order is empty") }
            viewOrder()
            return .applied
        case .name:
            if screen == .attract { return .rejected("No order in progress") }
            if screen == .name { return .applied }
            if mode == .customize {
                if isEditing, current.scoopCount == 0 { return .rejected("The item being edited has no scoops left") }
                guard canViewOrder else { return .rejected("The order is empty") }
                viewOrder()
                await pause(0.7)
            }
            guard !items.isEmpty else { return .rejected("The order is empty") }
            completeOrder()
            return screen == .name ? .applied : .rejected("Couldn't go to name entry")
        }
    }

    private func assistAddItem() async -> AssistOutcome {
        switch screen {
        case .attract:
            return await assistNavigate(to: .builder)
        case .name:
            backToSummary()
            await pause(0.5)
        case .builder:
            break
        case .confirmation:
            return .rejected("This order is paid. Start over for a new one.")
        case .roleSetup, .staff:
            return .rejected("The kiosk isn't taking orders")
        }
        if mode == .summary {
            backToBuilder()
            return .applied
        }
        if isEditing, current.scoopCount == 0 { return .rejected("The item being edited has no scoops left") }
        if canStartNewItem {
            startNewItem()
        } else if step != .vessel {
            jumpToStep(.vessel)
        }
        return .applied
    }

    private func assistRemoveItem(_ itemID: String) async -> AssistOutcome {
        guard let id = UUID(uuidString: itemID) else { return .rejected("That item is no longer in the order") }
        guard screen == .builder || screen == .name else { return .rejected("No order in progress") }
        if mode == .customize, current.id == id, !isEditing {
            discardCurrentItem()
            return .applied
        }
        guard items.contains(where: { $0.id == id }) else { return .rejected("That item is no longer in the order") }
        if screen == .name {
            backToSummary()
            await pause(0.5)
        }
        if case .deleteItem(id) = confirmation { confirmation = nil }
        delete(id)
        return .applied
    }
}
