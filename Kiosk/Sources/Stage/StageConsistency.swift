import RealityKit
import SwiftUI

/// Checks, once every animation has finished, that the 3D scene shows exactly what the order says.
extension Stage {
    var isSettled: Bool { tweens.isEmpty && morphing.isEmpty && !isDragging }

    func consistencyIssues(current: IceCreamItem?, items: [IceCreamItem], editingID: UUID?, showsCards: Bool) -> [String] {
        var issues: [String] = []
        func check(_ condition: Bool, _ message: @autoclosure () -> String) {
            if !condition { issues.append(message()) }
        }
        func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tolerance: Float = 1e-4) -> Bool { simd_length(a - b) < tolerance }
        func near(_ a: simd_quatf, _ b: simd_quatf) -> Bool { abs(simd_dot(a.vector, b.vector)) > 0.9999 }

        var models: [ObjectIdentifier: String] = [:]
        let pooled = Set(scoopModelPool.values.flatMap { $0 }.map(ObjectIdentifier.init))

        func checkScoops(_ rig: ItemRig, flavors: [Flavor], label: String) {
            check(rig.scoops.map(\.flavor) == flavors,
                  "\(label): rig shows \(rig.scoops.map(\.flavor.rawValue)) but order has \(flavors.map(\.rawValue))")
            for (index, actor) in rig.scoops.enumerated() {
                let name = "\(label) scoop \(index + 1) (\(actor.flavor.rawValue))"
                let key = placementKey(index: index, count: rig.scoops.count, vessel: rig.vessel)
                check(actor.rig === rig, "\(name): owned by another rig")
                check(actor.root.parent === rig.body, "\(name): not attached to its rig")
                check(actor.state == .landed, "\(name): state \(actor.state)")
                check(actor.motion == nil && actor.relayout == nil, "\(name): still has a motion")
                check(actor.morpher == nil, "\(name): still morphing")
                check(actor.slot == index + 1, "\(name): uses slot \(actor.slot) mesh")
                check(actor.placementKey == key, "\(name): placement \(actor.placementKey), expected \(key)")
                if let assets {
                    let pose = assets.scoopSet(actor.slot).resolve(finalPoseName(rig.vessel, key: key))
                    check(actor.staticPose == pose, "\(name): pose \(actor.staticPose), expected \(pose)")
                    check(actor.model.model?.mesh === assets.scoopSet(actor.slot).staticMesh(pose), "\(name): mesh is not the \(pose) pose")
                }
                let slot = slotLocal(rig.vessel, key: key, height: 0)
                check(near(actor.root.transform.translation, slot.translation) && near(actor.root.transform.rotation, slot.rotation)
                      && near(actor.root.transform.scale, .one), "\(name): not at its slot pose")
                check(actor.model.parent === actor.root, "\(name): model detached")
                check(near(actor.model.transform.translation, .zero) && near(actor.model.transform.scale, .one), "\(name): model offset")
                check(actor.model.isEnabled && actor.root.isEnabled, "\(name): disabled")
                check(!actor.model.components.has(OpacityComponent.self), "\(name): translucent")
                let id = ObjectIdentifier(actor.model)
                if let other = models[id] { issues.append("\(name): shares its model with \(other)") }
                models[id] = name
                check(!pooled.contains(id), "\(name): its model is also in the pool")
            }
        }

        func checkVisible(_ rig: ItemRig, label: String) {
            check(rig.root.parent === root, "\(label): not in the scene")
            check(rig.root.isEnabled && rig.rolled.isEnabled, "\(label): hidden")
            check(rig.motion == nil, "\(label): still moving")
            check(abs(rig.modelScale - 1) < 1e-4, "\(label): model scale \(rig.modelScale)")
        }

        if let current {
            check(selectedVessel == current.vessel, "selected vessel \(selectedVessel.rawValue), order has \(current.vessel.rawValue)")
            if let hero = heroes[current.vessel] {
                checkVisible(hero, label: "hero")
                check(abs(hero.scaleMultiplier - 1) < 1e-4, "hero: scale multiplier \(hero.scaleMultiplier)")
                check(hero.vessel == current.vessel, "hero is a \(hero.vessel.rawValue)")
                check(zip(hero.scoops, scoops).allSatisfy { $0 === $1 } && hero.scoops.count == scoops.count, "hero scoops differ from the stage's list")
                checkScoops(hero, flavors: current.flavors, label: "hero")
                let center = centerPose(hero, yaw: hero.pose.yaw)
                check(near(hero.pose.position, center.position, 1e-3) && abs(hero.pose.scale - center.scale) < 1e-3,
                      "hero: not at its framed center pose")
            } else {
                issues.append("no hero for \(current.vessel.rawValue)")
            }
            for (vessel, rig) in heroes where vessel != current.vessel {
                issues.append("stray \(vessel.rawValue) hero (\(rig.scoops.count) scoops)")
            }
        }

        let trayIDs = tray.map(\.id)
        check(trayIDs == items.map(\.id), "tray order differs from the order's items")
        for entry in tray {
            guard let item = items.first(where: { $0.id == entry.id }) else { continue }
            if entry.id == editingID {
                check(entry.mode == .editing && entry.rig == nil, "editing entry: mode \(entry.mode)")
                continue
            }
            guard let rig = entry.rig else {
                issues.append("tray item \(entry.index): no rig")
                continue
            }
            check(entry.mode == .tray || entry.mode == .summary, "tray item \(entry.index): mode \(entry.mode)")
            check(rig.root.parent === root, "tray item \(entry.index): not in the scene")
            check(rig.motion == nil, "tray item \(entry.index): still moving")
            checkScoops(rig, flavors: item.flavors, label: "tray item \(Int(entry.index))")
        }

        let scoopRootsInWorld = root.children.filter { $0.name == ScoopActor.rootName }
        check(scoopRootsInWorld.isEmpty, "\(scoopRootsInWorld.count) scoop(s) left loose in the scene")
        let rigsInScene = root.children.filter { $0.name.hasPrefix("rig-") }.count
        let expectedRigs = vesselIcons.count + heroes.count + tray.filter { $0.rig != nil }.count
        check(rigsInScene == expectedRigs, "\(rigsInScene) rigs in the scene, expected \(expectedRigs)")

        let owned = heroes.values.reduce(0) { $0 + $1.scoops.count } + tray.reduce(0) { $0 + ($1.rig?.scoops.count ?? 0) }
        check(liveScoops.count == owned, "\(liveScoops.count - owned) stray scoop(s) alive")
        for (vessel, rig) in vesselIcons {
            let pose = iconPose(vessel)
            check(near(rig.pose.position, pose.position) && abs(rig.pose.roll - pose.roll) < 1e-4,
                  "\(vessel.rawValue) card icon is out of place")
            check(rig.scoops.isEmpty, "\(vessel.rawValue) card icon holds scoops")
        }
        for vessel in Vessel.allCases {
            check(abs((vesselIconAppear[vessel] ?? 0) - 1) < 1e-4, "\(vessel.rawValue) card icon appear \(vesselIconAppear[vessel] ?? -1)")
        }
        for (flavor, icon) in flavorIcons {
            check(abs(icon.appear - 1) < 1e-4, "\(flavor.rawValue) card icon appear \(icon.appear)")
        }
        if showsCards {
            for vessel in Vessel.allCases {
                let shown = iconShown[.vessel(vessel)] ?? 0
                check(vesselIcons[vessel]?.root.isEnabled == (step == .vessel) && vesselIcons[vessel]?.rolled.isEnabled == true,
                      "\(vessel.rawValue) card icon visibility wrong on \(step)")
                check(abs(shown - (step == .vessel ? 1 : 0)) < 1e-4, "\(vessel.rawValue) card icon shown \(shown) on \(step)")
            }
            for flavor in Flavor.allCases {
                let shown = iconShown[.flavor(flavor)] ?? 0
                check(flavorIcons[flavor]?.holder.isEnabled == (step == .flavors) && flavorIcons[flavor]?.model.parent != nil,
                      "\(flavor.rawValue) card icon visibility wrong on \(step)")
                check(abs(shown - (step == .flavors ? 1 : 0)) < 1e-4, "\(flavor.rawValue) card icon shown \(shown) on \(step)")
            }
        }
        return issues
    }
}
