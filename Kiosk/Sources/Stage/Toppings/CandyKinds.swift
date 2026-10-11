import RealityKit
import UIKit

@MainActor
final class CandyLibrary {
    let gummyBears: GummyBears
    let candyLentils: CandyLentils
    let sprinkles: Sprinkles

    private init(gummyBears: GummyBears, candyLentils: CandyLentils, sprinkles: Sprinkles) {
        self.gummyBears = gummyBears
        self.candyLentils = candyLentils
        self.sprinkles = sprinkles
    }

    func kind(_ topping: Topping) -> (any ScatterKind)? {
        switch topping {
        case .gummies: gummyBears
        case .mms: candyLentils
        case .sprinkles: sprinkles
        case .whip, .chocolate: nil
        }
    }

    static func load(gummyBearURL: URL?) async -> (CandyLibrary?, [String]) {
        var report: [String] = []
        do {
            let bear: CandyMeshes.Built
            if let gummyBearURL, let entity = try? await Entity(contentsOf: gummyBearURL), let mesh = firstMesh(in: entity) {
                bear = .init(mesh: mesh, halfExtents: mesh.bounds.extents / 2)
                let size = mesh.bounds.extents * 1000
                report.append(String(format: "GummyBear.usdz: loaded, %.1f × %.1f × %.1f mm", size.x, size.y, size.z))
            } else {
                bear = try CandyMeshes.lentil(radius: 0.0055, halfThickness: 0.004, exponent: 2, ovality: 0.4)
                report.append("GummyBear.usdz: MISSING, using placeholder")
            }
            let lentils = try [(0.0065, 0.0029, 2.35, 0.0), (0.0064, 0.0030, 2.5, 0.025), (0.0066, 0.0028, 2.3, -0.02)]
                .map { try CandyMeshes.lentil(radius: Float($0.0), halfThickness: Float($0.1), exponent: Float($0.2), ovality: Float($0.3)) }
            let rods = try Sprinkles.variants.map {
                try CandyMeshes.sprinkle(length: $0.length * 0.001, radius: $0.diameter * 0.0005, bend: $0.bend)
            }
            let library = CandyLibrary(gummyBears: GummyBears(bear: bear), candyLentils: CandyLentils(pieces: lentils),
                                       sprinkles: Sprinkles(pieces: rods))
            return (library, report)
        } catch {
            report.append("Candy meshes failed: \(error.localizedDescription)")
            return (nil, report)
        }
    }

    private static func firstMesh(in entity: Entity) -> MeshResource? {
        if let model = entity.components[ModelComponent.self] { return model.mesh }
        for child in entity.children {
            if let mesh = firstMesh(in: child) { return mesh }
        }
        return nil
    }
}

/// Up to two of each flavor in a serving: every color is likely without being guaranteed, and none dominates.
private func colorBag(_ colors: Int, count: Int, rng: inout ToppingRandom) -> [Int] {
    Array((0..<colors).flatMap { [$0, $0] }.shuffled(using: &rng).prefix(count))
}

private extension CandyMeshes.Built {
    func piece(_ material: some RealityKit.Material) -> ScatterPiece {
        ScatterPiece(mesh: mesh, materials: [material], halfExtents: halfExtents)
    }
}

struct GummyBears: ScatterKind {
    enum Flavor: CaseIterable {
        case raspberry, orange, lemon, strawberry, pineapple
    }

    let bear: CandyMeshes.Built
    let materials: [PhysicallyBasedMaterial]

    var count: Int { 8 }

    init(bear: CandyMeshes.Built) {
        self.bear = bear
        materials = Flavor.allCases.map(Self.material)
    }

    func makePieces(rng: inout ToppingRandom) -> [ScatterPiece] {
        colorBag(materials.count, count: count, rng: &rng).map { bear.piece(materials[$0]) }
    }

    func makeIconPile(rng: inout ToppingRandom) -> Entity {
        let colors = Array(materials.indices.shuffled(using: &rng).prefix(4))
        let standing = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        let half = bear.halfExtents
        let layout: [(simd_quatf, SIMD3<Float>)] = [
            (simd_quatf(angle: 0.18, axis: [0, 1, 0]) * simd_quatf(angle: -0.32, axis: [0, 0, 1])
                * simd_quatf(angle: -0.3, axis: [1, 0, 0]) * standing,
             [-0.0045, 0, -0.004]),
            (simd_quatf(angle: -0.25, axis: [0, 1, 0]) * simd_quatf(angle: 0.3, axis: [0, 0, 1])
                * simd_quatf(angle: -0.34, axis: [1, 0, 0]) * standing,
             [0.0058, 0, -0.0055]),
            (simd_quatf(angle: 0.55, axis: [0, 1, 0]) * simd_quatf(angle: 0.12, axis: [1, 0, 0]),
             [-0.0062, 0, 0.009]),
            (simd_quatf(angle: -0.7, axis: [0, 1, 0]) * simd_quatf(angle: -0.16, axis: [0, 0, 1]),
             [0.0072, half.y * 0.5, 0.0075]),
        ]
        return IconPile.compose(layout.enumerated().map { index, entry in
            (bear.mesh, materials[colors[index]], entry.0, entry.1)
        })
    }

    private static func material(_ flavor: Flavor) -> PhysicallyBasedMaterial {
        switch flavor {
        case .raspberry: gummy(red: 0.86, green: 0.03, blue: 0.05, opacity: 0.82, glow: 0.35)
        case .orange: gummy(red: 1.0, green: 0.42, blue: 0.02, opacity: 0.78, glow: 0.35)
        case .lemon: gummy(red: 1.0, green: 0.80, blue: 0.04, opacity: 0.74, glow: 0.3)
        case .strawberry: gummy(red: 0.28, green: 0.70, blue: 0.04, opacity: 0.8, glow: 0.3)
        case .pineapple: gummy(red: 0.98, green: 0.93, blue: 0.76, opacity: 0.58, glow: 0.12)
        }
    }

    /// RealityKit has no transmission, so the jelly is a tinted, partly transparent glossy shell; a faint
    /// emissive in the same hue stands in for light scattering back out of it.
    private static func gummy(red: CGFloat, green: CGFloat, blue: CGFloat, opacity: Float, glow: Float) -> PhysicallyBasedMaterial {
        let color = UIColor(red: red, green: green, blue: blue, alpha: 1)
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.metallic = 0.0
        material.roughness = 0.14
        material.specular = 0.7
        material.clearcoat = 1.0
        material.clearcoatRoughness = 0.03
        material.emissiveColor = .init(color: color)
        material.emissiveIntensity = glow
        material.blending = .transparent(opacity: .init(floatLiteral: opacity))
        material.faceCulling = .back
        return material
    }
}

/// M&M's: candy-shelled chocolate lentils.
struct CandyLentils: ScatterKind {
    let pieces: [CandyMeshes.Built]
    let materials: [PhysicallyBasedMaterial]

    var count: Int { 8 }

    init(pieces: [CandyMeshes.Built]) {
        self.pieces = pieces
        materials = [
            (0.80, 0.05, 0.06), (1.0, 0.40, 0.03), (1.0, 0.80, 0.05),
            (0.08, 0.60, 0.22), (0.04, 0.38, 0.82), (0.36, 0.20, 0.11),
        ].map { Self.shell(UIColor(red: $0.0, green: $0.1, blue: $0.2, alpha: 1)) }
    }

    func makePieces(rng: inout ToppingRandom) -> [ScatterPiece] {
        colorBag(materials.count, count: count, rng: &rng).map {
            pieces.randomElement(using: &rng)!.piece(materials[$0])
        }
    }

    func makeIconPile(rng: inout ToppingRandom) -> Entity {
        let colors = Array(materials.indices.shuffled(using: &rng).prefix(4))
        let r = pieces[0].halfExtents.x
        let layout: [(simd_quatf, SIMD3<Float>)] = [
            (simd_quatf(angle: 0.1, axis: [0, 0, 1]), [-r * 1.02, 0, r * 0.35]),
            (simd_quatf(angle: -0.08, axis: [1, 0, 0]), [r * 1.02, 0, r * 0.45]),
            (simd_quatf(angle: 0.05, axis: [1, 0, 0]), [0, 0, -r * 1.25]),
            (simd_quatf(angle: -0.5, axis: [1, 0, 0]) * simd_quatf(angle: 0.3, axis: [0, 0, 1]),
             [r * 0.05, pieces[0].halfExtents.y * 1.55, -r * 0.1]),
        ]
        return IconPile.compose(layout.enumerated().map { index, entry in
            (pieces[index % pieces.count].mesh, materials[colors[index]], entry.0, entry.1)
        })
    }

    private static func shell(_ color: UIColor) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.metallic = 0.0
        material.roughness = 0.3
        material.specular = 0.5
        material.clearcoat = 1.0
        material.clearcoatRoughness = 0.06
        return material
    }
}

struct Sprinkles: ScatterKind {
    static let variants: [(length: Float, diameter: Float, bend: Float)] = [
        (6.2, 1.5, 0), (6.8, 1.7, 0), (7.4, 1.4, 0), (7.9, 1.6, 0), (8.6, 1.5, 0),
        (9.0, 1.8, 0), (7.1, 1.3, 0), (8.2, 1.7, 0), (7.0, 1.5, 0.45), (8.4, 1.6, -0.35), (6.6, 1.4, 0.3),
    ]

    let pieces: [CandyMeshes.Built]
    let materials: [PhysicallyBasedMaterial]

    var count: Int { 72 }

    init(pieces: [CandyMeshes.Built]) {
        self.pieces = pieces
        let colors: [(CGFloat, CGFloat, CGFloat)] = [
            (0.98, 0.42, 0.63), (1.0, 0.84, 0.18), (0.22, 0.52, 0.95), (0.30, 0.78, 0.36),
            (1.0, 0.52, 0.12), (0.97, 0.95, 0.91), (0.58, 0.33, 0.86),
        ]
        materials = colors.flatMap { c in
            [1.0, 0.86].map { shade in
                Self.sugar(UIColor(red: min(c.0 * shade + (1 - shade) * 0.05, 1), green: c.1 * shade, blue: c.2 * shade, alpha: 1))
            }
        }
    }

    func makePieces(rng: inout ToppingRandom) -> [ScatterPiece] {
        (0..<count).map { _ in
            pieces.randomElement(using: &rng)!.piece(materials.randomElement(using: &rng)!)
        }
    }

    func makeIconPile(rng: inout ToppingRandom) -> Entity {
        let radius: Float = 0.0105
        let height: Float = 0.0055
        var entries: [(MeshResource, any RealityKit.Material, simd_quatf, SIMD3<Float>)] = []
        for index in 0..<34 {
            let r = radius * sqrt(Float(index) / 34) * Float.random(in: 0.85...1.0, using: &rng)
            let a = Float(index) * 2.39996 + Float.random(in: -0.3...0.3, using: &rng)
            let top = height * (1 - (r / radius) * (r / radius))
            let built = pieces.randomElement(using: &rng)!
            let yaw = simd_quatf(angle: Float.random(in: 0...(2 * .pi), using: &rng), axis: [0, 1, 0])
            let slope = simd_quatf(angle: Float.random(in: -0.35...0.35, using: &rng), axis: [cos(a), 0, sin(a)])
            entries.append((built.mesh, materials.randomElement(using: &rng)!, slope * yaw,
                            [r * cos(a), max(top - built.halfExtents.y, 0), r * sin(a)]))
        }
        return IconPile.compose(entries, dropToFloor: false)
    }

    private static func sugar(_ color: UIColor) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.metallic = 0.0
        material.roughness = 0.42
        material.specular = 0.45
        material.clearcoat = 0.35
        material.clearcoatRoughness = 0.2
        return material
    }
}

@MainActor
enum IconPile {
    /// Places pieces (y is the gap above the floor when `dropToFloor`), then centers the pile on the Y axis resting on y = 0.
    static func compose(_ entries: [(MeshResource, any RealityKit.Material, simd_quatf, SIMD3<Float>)],
                        dropToFloor: Bool = true) -> Entity {
        let pile = Entity()
        pile.name = "candy-icon-pile"
        for (mesh, material, rotation, position) in entries {
            let model = ModelEntity(mesh: mesh, materials: [material])
            model.orientation = rotation
            model.position = position
            pile.addChild(model)
            if dropToFloor {
                model.position.y += position.y - model.visualBounds(relativeTo: pile).min.y
            }
        }
        let bounds = pile.visualBounds(relativeTo: pile)
        for child in pile.children {
            child.position -= [bounds.center.x, bounds.min.y, bounds.center.z]
        }
        return pile
    }
}
