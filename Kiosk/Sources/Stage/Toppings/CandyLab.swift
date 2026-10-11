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

        var points: [SIMD3<Float>] = []
        for scoop in rig.scoops {
            guard let assets else { continue }
            let matrix = scoop.model.transformMatrix(relativeTo: rig.body)
            for p in assets.scoopSet(scoop.slot).data.positions(scoop.staticPose, stride: 2) {
                let w = matrix * SIMD4<Float>(p, 1)
                points.append([w.x, w.y, w.z])
            }
        }
        let cell: Float = 0.001
        var grid: [SIMD2<Int32>: Float] = [:]
        for p in points {
            let key = SIMD2<Int32>(Int32((p.x / cell).rounded(.down)), Int32((p.z / cell).rounded(.down)))
            grid[key] = max(grid[key] ?? -1, p.y)
        }
        func height(_ x: Float, _ z: Float) -> Float? {
            let cx = Int32((x / cell).rounded(.down)), cz = Int32((z / cell).rounded(.down))
            var best: Float?
            for dx in -2...2 {
                for dz in -2...2 {
                    if let y = grid[SIMD2(cx + Int32(dx), cz + Int32(dz))] { best = max(best ?? -1, y) }
                }
            }
            return best
        }
        let lo = points.reduce(SIMD3<Float>(repeating: 1)) { simd_min($0, $1) }
        let hi = points.reduce(SIMD3<Float>(repeating: -1)) { simd_max($0, $1) }
        let center = (lo + hi) / 2
        let reach = min(hi.x - lo.x, hi.z - lo.z) * 0.45

        let holder = Entity()
        holder.name = "candy-lab"
        var placed: [SIMD3<Float>] = []
        for kind in onItem {
            for piece in kind.makePieces(rng: &rng) {
                var spot = SIMD3<Float>.zero
                for _ in 0..<12 {
                    let r = reach * sqrt(Float.random(in: 0...1, using: &rng))
                    let a = Float.random(in: 0...(2 * .pi), using: &rng)
                    let x = center.x + r * cos(a), z = center.z + r * sin(a)
                    guard let y = height(x, z) else { continue }
                    spot = [x, y, z]
                    if !placed.contains(where: { simd_distance($0, spot) < max(piece.halfExtents.x, piece.halfExtents.z) * 1.1 }) { break }
                }
                guard spot != .zero else { continue }
                let d: Float = 0.003
                let hx = (height(spot.x + d, spot.z) ?? spot.y) - (height(spot.x - d, spot.z) ?? spot.y)
                let hz = (height(spot.x, spot.z + d) ?? spot.y) - (height(spot.x, spot.z - d) ?? spot.y)
                let normal = simd_normalize(SIMD3<Float>(-hx / (2 * d), 1, -hz / (2 * d)))
                let model = ModelEntity(mesh: piece.mesh, materials: piece.materials)
                model.orientation = simd_quatf(from: [0, 1, 0], to: normal)
                    * simd_quatf(angle: Float.random(in: 0...(2 * .pi), using: &rng), axis: [0, 1, 0])
                model.position = spot + normal * piece.halfExtents.y * 0.75
                holder.addChild(model)
                if piece.halfExtents.x > 0.002 { placed.append(spot) }
            }
        }
        applyLighting(holder)
        rig.body.addChild(holder)

        if mode == "zoom" {
            rig.pose.scale *= 2.6
            rig.pose.position.y -= 0.18
            rig.apply()
        }

        let shown: [String] = mode == "candy" || mode == "bears" ? ["gummies", "mms", "sprinkles"] : [mode].filter { kinds[$0] != nil }
        for (index, name) in shown.enumerated() {
            guard let kind = kinds[name] else { continue }
            let pile = kind.makeIconPile(rng: &rng)
            applyLighting(pile)
            let anchor = Entity()
            anchor.position = world(CGPoint(x: 230 + CGFloat(index) * 286, y: 980))
            anchor.orientation = simd_quatf(angle: 0.32, axis: [1, 0, 0])
            anchor.scale = .init(repeating: 6)
            anchor.addChild(pile)
            root.addChild(anchor)
        }

        if mode == "bears" {
            for (index, material) in candy.gummyBears.materials.enumerated() {
                let model = ModelEntity(mesh: candy.gummyBears.bear.mesh, materials: material)
                model.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
                model.scale = .init(repeating: 9)
                model.position = world(CGPoint(x: 196 + CGFloat(index) * 160, y: 640), z: 0.03)
                applyLighting(model)
                root.addChild(model)
            }
            rig.root.isEnabled = false
            let backdrop = ModelEntity(mesh: .generatePlane(width: 0.9, height: 0.24),
                                       materials: [UnlitMaterial(color: .white, applyPostProcessToneMap: false)])
            backdrop.position = world(CGPoint(x: 516, y: 640), z: -0.06)
            root.addChild(backdrop)
        }
        let contents = candy.gummyBears.bear.mesh.contents
        let parts = contents.models.map { "\($0.id):" + $0.parts.map { "\($0.id)#\($0.materialIndex)" }.joined(separator: ",") }
        log("Candy lab \(mode): \(holder.children.count) pieces on the item, \(points.count) scoop points; bear instances "
            + contents.instances.map { "\($0.id)->\($0.model) \($0.transform.columns.0.x)" }.joined(separator: " ") + " models " + parts.joined(separator: " "))
    }
}
