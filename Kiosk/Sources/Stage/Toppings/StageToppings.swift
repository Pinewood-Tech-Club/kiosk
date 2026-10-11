import QuartzCore
import RealityKit

/// Layers taken off a rig that leaves (the vessel swapped away under its scoops), finishing their removal in place.
@MainActor
final class DetachedToppings {
    let container: Entity
    let layers: [any ToppingLayer]

    init(container: Entity, layers: [any ToppingLayer]) {
        self.container = container
        self.layers = layers
    }
}

extension Stage {
    func scoopSurfaceParts(_ vessel: Vessel, count: Int) -> [ScoopSurface.Part] {
        guard let assets else { return [] }
        return (0..<min(count, 3)).map { index in
            let key = placementKey(index: index, count: count, vessel: vessel)
            let set = assets.scoopSet(index + 1)
            return ScoopSurface.Part(mesh: set.data, pose: set.resolve(finalPoseName(vessel, key: key)),
                                     placement: assets.placements.placement(vessel, key: key))
        }
    }

    func scoopSurface(_ vessel: Vessel, count: Int) -> ScoopSurface? {
        guard count > 0, assets != nil else { return nil }
        let key = "\(vessel.rawValue)\(min(count, 3))"
        if let surface = scoopSurfaces[key] { return surface }
        let started = CACurrentMediaTime()
        let surface = ScoopSurface.build(scoopSurfaceParts(vessel, count: count))
        scoopSurfaces[key] = surface
        log(String(format: "Scoop surface %@ built on demand in %.1f ms", key, (CACurrentMediaTime() - started) * 1000))
        return surface
    }

    func precomputeScoopSurfaces() {
        var jobs: [(String, [ScoopSurface.Part])] = []
        for vessel in Vessel.allCases {
            for count in 1...3 where scoopSurfaces["\(vessel.rawValue)\(count)"] == nil {
                jobs.append(("\(vessel.rawValue)\(count)", scoopSurfaceParts(vessel, count: count)))
            }
        }
        Task { [weak self] in
            let started = CACurrentMediaTime()
            let built = await Task.detached(priority: .userInitiated) {
                jobs.map { ($0.0, ScoopSurface.build($0.1)) }
            }.value
            guard let self else { return }
            for (key, surface) in built where scoopSurfaces[key] == nil { scoopSurfaces[key] = surface }
            log(String(format: "Scoop surfaces built in %.0f ms: ", (CACurrentMediaTime() - started) * 1000)
                + built.map { String(format: "%@ apex %.1f mm r %.1f mm", $0.0, $0.1.apex.y * 1000, $0.1.radius * 1000) }
                .joined(separator: ", "))
        }
    }

    func toppingStack(_ rig: ItemRig) -> ToppingStack {
        if let stack = rig.toppings { return stack }
        let stack = ToppingStack(rig: rig)
        stack.light = { [unowned self] in applyLighting($0) }
        rig.toppings = stack
        toppingStacks.append(stack)
        return stack
    }

    func forgetToppings(_ rig: ItemRig) {
        guard let stack = rig.toppings else { return }
        toppingStacks.removeAll { $0 === stack }
        rig.toppings = nil
    }

    /// How many scoops sit settled on the rig (landed or pressing into place), or nil while any is still moving.
    func settledScoopCount(_ rig: ItemRig) -> Int? {
        for actor in rig.scoops where actor.mount !== rig || actor.state == .flying || actor.state == .leaving {
            return nil
        }
        return rig.scoops.count
    }

    /// The item being built changed its toppings: new ones come out of their cards onto the hero.
    func setToppings(_ toppings: [Topping], itemID: UUID) {
        guard isBuilt, let hero = heroes[selectedVessel] else { return }
        let stack = toppingStack(hero)
        stack.setSeed(ToppingSeed.item(itemID))
        if let count = settledScoopCount(hero), count != stack.scoopCount {
            stack.setScoops(count, surface: scoopSurface(hero.vessel, count: count), animated: true, now: now)
        }
        stack.setToppings(toppings, animated: true, now: now) { [unowned self] topping in toppingLaunch(topping, onto: hero) }
        reframe(hero)
    }

    /// Shows an item's toppings already in place (rebuilt items, tray minis, the order sheet).
    func applyToppings(_ item: IceCreamItem, to rig: ItemRig) {
        guard !item.toppings.isEmpty || rig.toppings != nil else { return }
        let stack = toppingStack(rig)
        stack.setSeed(ToppingSeed.item(item.id))
        stack.setScoops(item.flavors.count, surface: scoopSurface(item.vessel, count: item.flavors.count), animated: false, now: now)
        stack.setToppings(item.toppings, animated: false, now: now)
    }

    /// The scoops are being handed to another vessel: the toppings come off where they are and go back on once the
    /// scoops have settled into the new one.
    func moveToppings(from old: ItemRig, to new: ItemRig) {
        guard let stack = old.toppings, old !== new else { return }
        toppingStack(new).adopt(stack)
        let container = Entity()
        container.transform = Transform(matrix: stack.root.transformMatrix(relativeTo: nil))
        root.addChild(container)
        let layers = stack.detachLayers(into: container, now: now)
        if layers.isEmpty {
            container.removeFromParent()
        } else {
            detachedToppings.append(DetachedToppings(container: container, layers: layers))
        }
    }

    /// Extra height the hero's toppings add above its scoops, for framing.
    func toppingHeadroom(_ rig: ItemRig) -> Float {
        guard let top = rig.toppings?.top, let scoops = scoopSurface(rig.vessel, count: rig.scoops.count) else { return 0 }
        return max(0, top - scoops.apex.y)
    }

    func updateToppings() {
        toppingStacks.removeAll { $0.rig == nil }
        for stack in toppingStacks {
            guard let rig = stack.rig else { continue }
            if let count = settledScoopCount(rig) {
                let before = stack.scoopCount
                stack.follow(scoops: count, surface: { [unowned self] in scoopSurface(rig.vessel, count: count) }, now: now)
                if stack.scoopCount != before, heroes[selectedVessel] === rig { reframe(rig) }
            }
            stack.update(now: now)
        }
        guard !detachedToppings.isEmpty else { return }
        for detached in detachedToppings {
            for layer in detached.layers { layer.update(now: now) }
        }
        detachedToppings.removeAll { detached in
            guard detached.layers.allSatisfy(\.isFinished) else { return false }
            detached.container.removeFromParent()
            return true
        }
    }

    func removeDetachedToppings() {
        for detached in detachedToppings { detached.container.removeFromParent() }
        detachedToppings.removeAll()
    }
}
