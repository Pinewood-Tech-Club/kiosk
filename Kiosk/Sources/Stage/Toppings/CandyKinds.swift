import RealityKit
import CoreImage
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
            var shapes = ToppingRandom(seed: 11)
            let lentils = try (0..<CandyLentils.shapeCount).map { index in
                try CandyMeshes.candyLentil(radius: 0.0065, halfThickness: 0.0034, exponent: 2.2,
                                            printUp: index.isMultiple(of: 2), rng: &shapes)
            }
            let rods = try Sprinkles.variants.map {
                try CandyMeshes.sprinkle(length: $0.length * 0.001, radius: $0.diameter * 0.0005, bend: $0.bend)
            }
            let library = CandyLibrary(gummyBears: await GummyBears.make(shell: bear),
                                       candyLentils: await CandyLentils.make(pieces: lentils),
                                       sprinkles: Sprinkles(pieces: rods))
            switch JellyMaterial.library {
            case .success: report.append("Gummy jelly: shader")
            case .failure(let error): report.append("Gummy jelly: FALLBACK, shader failed: \(error.localizedDescription)")
            }
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
    let materials: [any RealityKit.Material]

    var count: Int { 8 }

    private init(bear: CandyMeshes.Built, materials: [any RealityKit.Material]) {
        self.bear = bear
        self.materials = materials
    }

    static func make(shell: CandyMeshes.Built) async -> GummyBears {
        let bear = CandyMeshes.Built(mesh: (try? withShading(shell.mesh)) ?? shell.mesh, halfExtents: shell.halfExtents)
        let materials: [any RealityKit.Material] = Flavor.allCases.map { flavor in
            let jelly = jelly(flavor)
            return (try? JellyMaterial.make(jelly)) ?? fallback(jelly)
        }
        return GummyBears(bear: bear, materials: materials)
    }

    func makePieces(rng: inout ToppingRandom) -> [ScatterPiece] {
        colorBag(materials.count, count: count, rng: &rng).map {
            ScatterPiece(mesh: bear.mesh, materials: [materials[$0]], halfExtents: bear.halfExtents)
        }
    }

    func makeIconPile(rng: inout ToppingRandom) -> Entity {
        let colors = Array(materials.indices.shuffled(using: &rng).prefix(4))
        let standing = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        let layout: [(simd_quatf, SIMD3<Float>)] = [
            (simd_quatf(angle: 0.15, axis: [0, 1, 0]) * simd_quatf(angle: -0.08, axis: [0, 0, 1])
                * simd_quatf(angle: -0.3, axis: [1, 0, 0]) * standing,
             [-0.0042, 0, -0.004]),
            (simd_quatf(angle: -0.22, axis: [0, 1, 0]) * simd_quatf(angle: 0.1, axis: [0, 0, 1])
                * simd_quatf(angle: -0.22, axis: [1, 0, 0]) * standing,
             [0.0066, 0, -0.001]),
            (simd_quatf(angle: 0.3, axis: [0, 1, 0]) * simd_quatf(angle: 0.55, axis: [1, 0, 0]),
             [-0.0068, 0, 0.0105]),
            (simd_quatf(angle: -0.4, axis: [0, 1, 0]) * simd_quatf(angle: 0.5, axis: [1, 0, 0])
                * simd_quatf(angle: -0.15, axis: [0, 0, 1]),
             [0.0078, 0, 0.0115]),
        ]
        return IconPile.compose(layout.enumerated().map { index, entry in
            (bear.mesh, [materials[colors[index]]], entry.0, entry.1)
        })
    }

    /// The jelly shader reads uv0 as (how face-on to the belly or back, thickness behind the surface), as baked by
    /// gummy_bear.py. A mesh without that data gets a guess from its normals.
    private static func withShading(_ mesh: MeshResource) throws -> MeshResource {
        guard var model = mesh.contents.models.first(where: { _ in true }),
              model.parts.contains(where: { $0.textureCoordinates?.count != $0.positions.count })
        else { return mesh }
        model.parts = .init(model.parts.map { part in
            var copy = part
            let normals = part.normals?.elements ?? part.positions.elements.map { simd_normalize($0) }
            copy.textureCoordinates = MeshBuffers.TextureCoordinates(normals.map { [abs($0.y), 0.4] })
            return copy
        })
        var contents = mesh.contents
        contents.models = [model]
        return try MeshResource.generate(from: contents)
    }

    private static func jelly(_ flavor: Flavor) -> JellyMaterial.Flavor {
        switch flavor {
        case .raspberry: .init(color: [0.62, 0.016, 0.016], see: 0.07)
        case .orange: .init(color: [0.92, 0.36, 0.015], see: 0.1)
        case .lemon: .init(color: [0.9, 0.74, 0.03], see: 0.18)
        case .strawberry: .init(color: [0.13, 0.42, 0.02], see: 0.1)
        case .pineapple: .init(color: [0.84, 0.78, 0.56], see: 0.7)
        }
    }

    private static func fallback(_ jelly: JellyMaterial.Flavor) -> PhysicallyBasedMaterial {
        let c = jelly.color
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: UIColor(red: CGFloat(c.x * 0.1), green: CGFloat(c.y * 0.1), blue: CGFloat(c.z * 0.1), alpha: 1))
        material.emissiveColor = .init(color: UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1))
        material.emissiveIntensity = 0.8
        material.roughness = 0.4
        material.specular = 0.5
        material.faceCulling = .back
        material.blending = .transparent(opacity: .init(floatLiteral: max(1 - jelly.see, 0.3)))
        return material
    }
}

/// M&M's: candy-shelled chocolate lentils with the white "m" printed on one face.
struct CandyLentils: ScatterKind {
    static let shapeCount = 8
    static let colors: [SIMD3<Float>] = [
        [0.80, 0.05, 0.06], [1.0, 0.40, 0.03], [1.0, 0.80, 0.05],
        [0.08, 0.60, 0.22], [0.04, 0.40, 0.84], [0.25, 0.12, 0.07],
    ]
    static let shades = 2

    /// Shape variants; even ones have the print on top, odd ones underneath.
    let pieces: [CandyMeshes.Built]
    /// Index `color * shades + shade`.
    let materials: [PhysicallyBasedMaterial]

    var count: Int { 8 }

    private init(pieces: [CandyMeshes.Built], materials: [PhysicallyBasedMaterial]) {
        self.pieces = pieces
        self.materials = materials
    }

    static func make(pieces: [CandyMeshes.Built]) async -> CandyLentils {
        var materials: [PhysicallyBasedMaterial] = []
        for (index, color) in colors.enumerated() {
            for shade in 0..<shades {
                let varied = color * (shade == 0 ? 1 : 0.93) + (shade == 0 ? .zero : SIMD3<Float>(0.015, 0.01, 0))
                materials.append(shell(try? await LentilPrint.texture(varied, seed: UInt64(index * shades + shade + 1)),
                                       fallback: varied))
            }
        }
        return CandyLentils(pieces: pieces, materials: materials)
    }

    func makePieces(rng: inout ToppingRandom) -> [ScatterPiece] {
        colorBag(Self.colors.count, count: count, rng: &rng).map {
            let shade = Int.random(in: 0..<Self.shades, using: &rng)
            return pieces.randomElement(using: &rng)!.piece(materials[$0 * Self.shades + shade])
        }
    }

    func makeIconPile(rng: inout ToppingRandom) -> Entity {
        let colors = Array(Self.colors.indices.shuffled(using: &rng).prefix(4))
        let up = pieces.indices.filter { $0.isMultiple(of: 2) }
        let r = pieces[0].halfExtents.x
        let h = pieces[0].halfExtents.y
        let layout: [(simd_quatf, SIMD3<Float>)] = [
            (simd_quatf(angle: -0.35, axis: [0, 1, 0]) * simd_quatf(angle: 0.95, axis: [1, 0, 0]), [r * 1.05, 0, -r * 0.75]),
            (simd_quatf(angle: 0.5, axis: [0, 1, 0]) * simd_quatf(angle: 0.06, axis: [0, 0, 1]), [-r * 1.0, 0, r * 0.35]),
            (simd_quatf(angle: -0.35, axis: [0, 1, 0]) * simd_quatf(angle: -0.05, axis: [1, 0, 0]), [r * 1.0, 0, r * 0.75]),
            (simd_quatf(angle: 0.38, axis: [1, 0, 0]) * simd_quatf(angle: 0.2, axis: [0, 0, 1])
                * simd_quatf(angle: -0.2, axis: [0, 1, 0]),
             [-r * 0.15, h * 1.3, r * 0.45]),
        ]
        return IconPile.compose(layout.enumerated().map { index, entry in
            (pieces[up[index % up.count]].mesh, [materials[colors[index] * Self.shades]], entry.0, entry.1)
        })
    }

    private static func shell(_ texture: TextureResource?, fallback: SIMD3<Float>) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        if let texture {
            material.baseColor = .init(tint: .white, texture: .init(texture))
        } else {
            material.baseColor = .init(tint: UIColor(red: CGFloat(fallback.x), green: CGFloat(fallback.y),
                                                     blue: CGFloat(fallback.z), alpha: 1))
        }
        material.metallic = 0.0
        material.roughness = 0.42
        material.specular = 0.45
        material.clearcoat = 0.3
        material.clearcoatRoughness = 0.4
        return material
    }
}

/// The lentil's print-face texture: the projected face disc fills the square, everything but the "m" is shell color.
@MainActor
enum LentilPrint {
    static let size = 256

    static func texture(_ color: SIMD3<Float>, seed: UInt64) async throws -> TextureResource {
        var rng = ToppingRandom(seed: seed)
        let side = CGFloat(size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let base = UIColor(red: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: 1)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let printed = renderer.image { context in
            let cg = context.cgContext
            base.setFill()
            cg.fill(CGRect(x: 0, y: 0, width: side, height: side))
            for _ in 0..<18 {
                let r = CGFloat.random(in: 20...60, using: &rng)
                let p = CGPoint(x: .random(in: 0...side, using: &rng), y: .random(in: 0...side, using: &rng))
                let tone: UIColor = Bool.random(using: &rng) ? .white : .black
                cg.setFillColor(tone.withAlphaComponent(0.025).cgColor)
                cg.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            }

            let font = UIFont(name: "AmericanTypewriter-Semibold", size: 100) ?? .systemFont(ofSize: 100, weight: .heavy)
            let ink = UIColor(red: 0.95, green: 0.94, blue: 0.91, alpha: .random(in: 0.74...0.84, using: &rng))
            let glyph = NSAttributedString(string: "m", attributes: [.font: font, .foregroundColor: ink,
                                                                     .strokeColor: ink, .strokeWidth: -2.5])
            let bounds = glyph.boundingRect(with: CGSize(width: 400, height: 400), options: [.usesLineFragmentOrigin], context: nil)
            let xHeight = font.xHeight
            let scale = side * 0.41 / bounds.width
            cg.saveGState()
            cg.translateBy(x: side * 0.5 + CGFloat.random(in: -3...3, using: &rng),
                           y: side * 0.5 + CGFloat.random(in: -3...3, using: &rng))
            cg.rotate(by: CGFloat.random(in: -0.04...0.04, using: &rng))
            cg.concatenate(CGAffineTransform(a: 1, b: 0, c: -0.2, d: 1, tx: 0, ty: 0))
            cg.scaleBy(x: scale, y: scale * 1.18)
            glyph.draw(at: CGPoint(x: -bounds.width / 2, y: -font.ascender + xHeight / 2))
            cg.restoreGState()
        }
        let soft = printed.cgImage.flatMap { blurred($0, radius: 1.1) } ?? printed.cgImage
        let image = renderer.image { context in
            let cg = context.cgContext
            soft.map { UIImage(cgImage: $0).draw(in: CGRect(x: 0, y: 0, width: side, height: side)) }
            for _ in 0..<5 {
                let p = CGPoint(x: side * 0.5 + .random(in: -side * 0.22...side * 0.22, using: &rng),
                                y: side * 0.5 + .random(in: -side * 0.15...side * 0.15, using: &rng))
                cg.saveGState()
                cg.translateBy(x: p.x, y: p.y)
                cg.rotate(by: .random(in: 0...(.pi), using: &rng))
                cg.setFillColor(base.withAlphaComponent(.random(in: 0.12...0.3, using: &rng)).cgColor)
                let w = CGFloat.random(in: 6...16, using: &rng)
                cg.fillEllipse(in: CGRect(x: -w / 2, y: -1, width: w, height: 2))
                cg.restoreGState()
            }
            for _ in 0..<40 {
                let r = CGFloat.random(in: 0.5...1.4, using: &rng)
                let p = CGPoint(x: side * 0.5 + .random(in: -side * 0.24...side * 0.24, using: &rng),
                                y: side * 0.5 + .random(in: -side * 0.17...side * 0.17, using: &rng))
                cg.setFillColor(base.withAlphaComponent(.random(in: 0.2...0.55, using: &rng)).cgColor)
                cg.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            }
        }
        guard let cgImage = image.cgImage else { throw CocoaError(.coderInvalidValue) }
        return try await TextureResource(image: cgImage, options: .init(semantic: .color))
    }

    private static let imaging = CIContext()

    private static func blurred(_ image: CGImage, radius: Double) -> CGImage? {
        let input = CIImage(cgImage: image)
        return imaging.createCGImage(input.clampedToExtent().applyingGaussianBlur(sigma: radius), from: input.extent)
    }
}

struct Sprinkles: ScatterKind {
    static let variants: [(length: Float, diameter: Float, bend: Float)] = [
        (6.2, 1.25, 0), (6.8, 1.35, 0), (7.4, 1.2, 0), (7.9, 1.4, 0), (8.0, 1.3, 0),
        (7.2, 1.45, 0), (6.5, 1.2, 0), (7.6, 1.4, 0), (7.0, 1.3, 0.45), (7.8, 1.35, -0.35), (6.6, 1.25, 0.3),
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
        let radius: Float = 0.013
        let height: Float = 0.0075
        var entries: [(MeshResource, [any RealityKit.Material], simd_quatf, SIMD3<Float>)] = []
        for index in 0..<72 {
            let r = radius * sqrt(Float(index) / 72) * Float.random(in: 0.85...1.0, using: &rng)
            let a = Float(index) * 2.39996 + Float.random(in: -0.3...0.3, using: &rng)
            let top = height * (1 - (r / radius) * (r / radius))
            let built = pieces.randomElement(using: &rng)!
            let yaw = simd_quatf(angle: Float.random(in: 0...(2 * .pi), using: &rng), axis: [0, 1, 0])
            let slope = simd_quatf(angle: Float.random(in: -0.35...0.35, using: &rng), axis: [cos(a), 0, sin(a)])
            entries.append((built.mesh, [materials.randomElement(using: &rng)!], slope * yaw,
                            [r * cos(a), max(top - built.halfExtents.y, 0), r * sin(a)]))
        }
        return IconPile.compose(entries, dropToFloor: false)
    }

    private static func sugar(_ color: UIColor) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.metallic = 0.0
        material.roughness = 0.56
        material.specular = 0.3
        return material
    }
}

@MainActor
enum IconPile {
    /// Places pieces (y is the gap above the floor when `dropToFloor`), then centers the pile on the Y axis resting on y = 0.
    static func compose(_ entries: [(MeshResource, [any RealityKit.Material], simd_quatf, SIMD3<Float>)],
                        dropToFloor: Bool = true) -> Entity {
        let pile = Entity()
        pile.name = "candy-icon-pile"
        for (mesh, materials, rotation, position) in entries {
            let model = ModelEntity(mesh: mesh, materials: materials)
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
