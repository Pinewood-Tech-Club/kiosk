import RealityKit
import UIKit

extension Stage {
    /// Temporary look-dev hook: `-kioskToppingLab gummies|mms|sprinkles|candy|bears|zoom`.
    func showCandyLab(_ mode: String) {
        guard let candy = assets?.candy, let rig = heroes[selectedVessel] else {
            log("Candy lab: no candy library or item")
            return
        }
        let defaults = UserDefaults.standard
        var rng = ToppingRandom(seed: UInt64(max(defaults.integer(forKey: "kioskToppingLabSeed"), 1)))
        let kinds: [String: any ScatterKind] = ["gummies": candy.gummyBears, "mms": candy.candyLentils, "sprinkles": candy.sprinkles]
        let onItem: [any ScatterKind] = switch mode {
        case "candy", "zoom": [candy.sprinkles, candy.candyLentils, candy.gummyBears]
        case "bears": []
        default: kinds[mode].map { [$0] } ?? []
        }

        let bounds = rig.body.visualBounds(relativeTo: rig.body)
        let top = bounds.max.y
        let dome = min(bounds.extents.x, bounds.extents.z) * 0.42
        let holder = Entity()
        holder.name = "candy-lab"
        var layer: Float = 0
        for kind in onItem {
            for (index, piece) in kind.makePieces(rng: &rng).enumerated() {
                let r = dome * sqrt(Float.random(in: 0.02...1, using: &rng))
                let a = Float(index) * 2.39996 + Float.random(in: 0...6.28, using: &rng)
                let p = SIMD3<Float>(bounds.center.x + r * cos(a), 0, bounds.center.z + r * sin(a))
                let drop = 0.55 * r * r / dome
                let model = ModelEntity(mesh: piece.mesh, materials: piece.materials)
                let tilt = simd_quatf(angle: atan(1.1 * r / dome), axis: simd_normalize([-sin(a), 0, cos(a)]))
                model.orientation = tilt * simd_quatf(angle: Float.random(in: 0...6.28, using: &rng), axis: [0, 1, 0])
                model.position = [p.x, top - drop + piece.halfExtents.y * 0.6 + layer, p.z]
                holder.addChild(model)
            }
            layer += 0.0015
        }
        applyLighting(holder)
        rig.body.addChild(holder)

        if mode == "zoom" {
            rig.pose.scale *= 2.4
            rig.pose.position.y -= 0.32
            rig.apply()
        }

        let shown: [String] = mode == "candy" || mode == "bears" ? ["gummies", "mms", "sprinkles"] : [mode].filter { kinds[$0] != nil }
        for (index, name) in shown.enumerated() {
            guard let kind = kinds[name] else { continue }
            let pile = kind.makeIconPile(rng: &rng)
            applyLighting(pile)
            let anchor = Entity()
            anchor.position = world(CGPoint(x: 220 + CGFloat(index) * 300, y: mode == "bears" ? 1900 : 2420))
            anchor.orientation = simd_quatf(angle: 0.32, axis: [1, 0, 0])
            anchor.scale = .init(repeating: mode == "bears" ? 11 : 7)
            anchor.addChild(pile)
            root.addChild(anchor)
        }

        if mode == "bears", let bear = candy.gummyBears.makePieces(rng: &rng).first {
            for (index, material) in candy.gummyBears.materials.enumerated() {
                let model = ModelEntity(mesh: bear.mesh, materials: [material])
                model.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
                model.scale = .init(repeating: 13)
                model.position = world(CGPoint(x: 230 + CGFloat(index) * 400, y: 1250), z: 0.05)
                applyLighting(model)
                root.addChild(model)
            }
        }
        log("Candy lab \(mode): \(holder.children.count) pieces on the item")
    }
}
