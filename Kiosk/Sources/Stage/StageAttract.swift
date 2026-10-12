import RealityKit
import SwiftUI

/// Where the item at the center is framed and where card flights start and end.
struct Staging {
    var band: CGRect
    /// Screen y that a scoop on its way in stays under.
    var ceilingY: CGFloat
    var scaleBoost: Float
    /// No cards on screen: scoops and toppings come from and leave for points above the top edge, and vessels below the
    /// bottom edge, as if their cards were just off screen.
    var offscreenCards: Bool

    static let builder = Staging(band: Layout.heroBand, ceilingY: Stage.flightCeilingY, scaleBoost: 1, offscreenCards: false)
    static let attract = Staging(band: CGRect(x: 296, y: 96, width: 440, height: 1050), ceilingY: 24, scaleBoost: 1.25,
                                 offscreenCards: true)
}

/// The attract screen's item: stripped down and rebuilt as a new random combination over and over, the vessel changing
/// every time, with the builder's own animations. Every step is a stage tween, so slow motion applies and `reset` stops it.
@MainActor
final class AttractShow {
    static let enterDelay = 0.8
    static let dwell = 7.0

    /// What the stage shows right now, scoop by scoop and topping by topping.
    var item = AttractShow.opening
    var finished = AttractShow.opening
    var next: Tween?
    var rng = SystemRandomNumberGenerator()

    static let opening = IceCreamItem(vessel: .cup, flavors: [.chocolate, .cookies], toppings: [.whip, .gummies])

    func nextItem() -> IceCreamItem {
        let vessel: Vessel = finished.vessel == .cup ? .cone : .cup
        while true {
            let flavors = (0..<Int.random(in: 1...3, using: &rng)).map { _ in Flavor.allCases.randomElement(using: &rng)! }
            // Candy can't be shown on a lone scoop in a cup: the scoop's top is below that surface's floor, so ScatterLayer
            // finds no spot and traps. Every build spends part of its time in a cup.
            let choices = flavors.count == 1 ? Topping.allCases.filter(\.isLayered) : Topping.allCases
            let toppings = Topping.stacked(Array(choices.shuffled(using: &rng).prefix(Int.random(in: 1...3, using: &rng))))
            if flavors != finished.flavors || Set(toppings) != Set(finished.toppings) {
                return IceCreamItem(vessel: vessel, flavors: flavors, toppings: toppings)
            }
        }
    }
}

extension Stage {
    var isAttractRunning: Bool { attract != nil }

    func startAttract() {
        reset()
        staging = .attract
        setControlsVisible(false, animated: false)
        updateIcons()
        let show = AttractShow()
        attract = show
        attractAfter(AttractShow.enterDelay) { [unowned self] in attractEnter(show.item) }
    }

    func flavorPort(_ flavor: Flavor, slot: Int = 1) -> Transform {
        guard staging.offscreenCards else { return flavorIconModelTransform(flavor, slot: slot) }
        let offsets: [Flavor: CGFloat] = [.vanilla: -70, .chocolate: 0, .cookies: 70]
        let scale = heroes[selectedVessel]?.pose.scale ?? Self.maxHeroScale(selectedVessel)
        return Transform(scale: .init(repeating: scale), rotation: simd_quatf(angle: 0.3, axis: [1, 0, 0]),
                         translation: world(CGPoint(x: staging.band.midX + offsets[flavor, default: 0], y: -420)))
    }

    func toppingPort(_ topping: Topping) -> SIMD3<Float> {
        let offsets: [Topping: CGFloat] = [.whip: -60, .chocolate: 60, .gummies: -40, .mms: 40, .sprinkles: 0]
        return world(CGPoint(x: staging.band.midX + offsets[topping, default: 0], y: -320))
    }

    /// A vessel's pose where its flights begin and end: on its card, or out of sight below the screen holding `count` scoops.
    func vesselPort(_ vessel: Vessel, count: Int, scale: Float) -> RigPose {
        guard staging.offscreenCards else { return iconPose(vessel) }
        let reach = (contentExtents["\(vessel.rawValue)\(min(count, 3))"]?.yMax ?? 0.15) + (count > 0 ? 0.04 : 0)
        var position = world(CGPoint(x: staging.band.midX, y: Layout.screen.height + 360))
        position.y -= reach * scale
        return RigPose(position: position, scale: scale, pitch: Self.preferredPitch, yaw: 0)
    }

    private func attractAfter(_ delay: Double, _ action: @escaping () -> Void) {
        attract?.next = animate(delay: delay, duration: 0, { _ in }, completion: action)
    }

    private func attractWhen(_ ready: @escaping () -> Bool, timeout: Double = 8, then action: @escaping () -> Void) {
        let deadline = now + timeout
        func poll() {
            guard attract != nil else { return }
            if ready() || now >= deadline {
                action()
            } else {
                attract?.next = animate(duration: 1.0 / 60, { _ in }, completion: poll)
            }
        }
        poll()
    }

    private var attractHero: ItemRig? { heroes[selectedVessel] }

    private func attractSettled(_ count: Int) -> Bool {
        guard let hero = attractHero, hero.motion == nil, heroes.count == 1 else { return false }
        return scoops.count == count && settledScoopCount(hero) == count && scoops.allSatisfy(\.isLanded)
            && hero.toppings?.isIdle ?? true
    }

    private func attractEnter(_ item: IceCreamItem) {
        selectedVessel = item.vessel
        let rig = makeItemRig(item)
        heroes[item.vessel] = rig
        scoops = rig.scoops
        reframe(rig, animated: false)
        rig.pose = vesselPort(item.vessel, count: item.flavors.count, scale: rig.framing?.scale ?? 1)
        rig.apply()
        root.addChild(rig.root)
        flyHeroToCenter(rig, duration: 1.3)
        attractAfter(1.3) { [unowned self] in attractDwell() }
    }

    private func attractDwell() {
        attract?.finished = attract?.item ?? AttractShow.opening
        attractWhen({ [unowned self] in attractSettled(attract?.item.flavors.count ?? 0) }) { [unowned self] in
            attractAfter(AttractShow.dwell) { [unowned self] in attractStripToppings() }
        }
    }

    private func attractStripToppings() {
        guard let show = attract, let top = show.item.toppings.last else {
            attractWhen({ [unowned self] in attractHero?.toppings?.isIdle ?? true }) { [unowned self] in attractRemoveScoops() }
            return
        }
        show.item.toppings.removeLast()
        setToppings(show.item.toppings, itemID: show.item.id)
        attractAfter(top.isLayered ? 0.8 : 1.0) { [unowned self] in attractStripToppings() }
    }

    private func attractRemoveScoops() {
        guard let show = attract else { return }
        guard !scoops.isEmpty else {
            let next = show.nextItem()
            let swapLate = Bool.random(using: &show.rng)
            show.item = IceCreamItem(vessel: show.item.vessel)
            attractAfter(0.5) { [unowned self] in attractAddScoops(next, swapLate: swapLate) }
            return
        }
        removeScoop(at: scoops.count - 1)
        show.item.flavors.removeLast()
        attractAfter(0.75) { [unowned self] in attractRemoveScoops() }
    }

    private func attractAddScoops(_ target: IceCreamItem, swapLate: Bool) {
        guard let show = attract else { return }
        guard show.item.flavors.count < target.flavors.count else {
            attractWhen({ [unowned self] in attractSettled(target.flavors.count) }) { [unowned self] in
                if swapLate {
                    attractAddToppings(target, swapAfter: true)
                } else {
                    attractSwap(to: target.vessel) { [unowned self] in attractAddToppings(target, swapAfter: false) }
                }
            }
            return
        }
        let flavor = target.flavors[show.item.flavors.count]
        addScoop(flavor)
        show.item.flavors.append(flavor)
        attractAfter(0.7) { [unowned self] in attractAddScoops(target, swapLate: swapLate) }
    }

    private func attractAddToppings(_ target: IceCreamItem, swapAfter: Bool) {
        guard let show = attract else { return }
        guard show.item.toppings.count < target.toppings.count else {
            attractWhen({ [unowned self] in attractSettled(target.flavors.count) }) { [unowned self] in
                if swapAfter {
                    attractSwap(to: target.vessel) { [unowned self] in attractDwell() }
                } else {
                    attractDwell()
                }
            }
            return
        }
        let topping = target.toppings[show.item.toppings.count]
        show.item.toppings.append(topping)
        setToppings(show.item.toppings, itemID: show.item.id)
        let duration = switch topping {
        case .whip: 1.8
        case .chocolate, .caramel: 2.6
        case .gummies, .mms, .sprinkles: 1.4
        }
        attractAfter(duration) { [unowned self] in attractAddToppings(target, swapAfter: swapAfter) }
    }

    private func attractSwap(to vessel: Vessel, then next: @escaping () -> Void) {
        guard let show = attract else { return }
        show.item.vessel = vessel
        swapVessel(to: vessel)
        attractAfter(0.9) { [unowned self] in
            attractWhen({ [unowned self] in attractSettled(show.item.flavors.count) }) { [unowned self] in
                attractAfter(0.4, next)
            }
        }
    }
}
