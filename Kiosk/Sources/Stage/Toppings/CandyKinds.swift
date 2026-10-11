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
            let library = CandyLibrary(gummyBears: GummyBears(shell: bear, texture: try? await JellyTexture.make()), candyLentils: CandyLentils(pieces: lentils),
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

    /// The shell plus a slightly smaller core inside it: material 0 is the core (drawn first), 1 the shell.
    let bear: CandyMeshes.Built
    /// Per flavor: [core, shell].
    let materials: [[PhysicallyBasedMaterial]]

    var count: Int { 8 }

    init(shell: CandyMeshes.Built, texture: JellyTexture?) {
        bear = .init(mesh: (try? Self.withCore(shell.mesh)) ?? shell.mesh, halfExtents: shell.halfExtents)
        materials = Flavor.allCases.map { Self.materials($0, texture: texture) }
    }

    func makePieces(rng: inout ToppingRandom) -> [ScatterPiece] {
        colorBag(materials.count, count: count, rng: &rng).map {
            ScatterPiece(mesh: bear.mesh, materials: materials[$0], halfExtents: bear.halfExtents)
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
            (bear.mesh, materials[colors[index]], entry.0, entry.1)
        })
    }

    /// Adds planar UVs (seen from the belly, 12 mm per texture tile) for the jelly texture, and the core copy.
    private static func withCore(_ mesh: MeshResource) throws -> MeshResource {
        guard let model = mesh.contents.models.first(where: { _ in true }) else { return mesh }
        let tile: Float = 0.012
        let textured: [MeshResource.Part] = model.parts.map { part in
            var copy = part
            let positions = part.positions.elements
            let normals = part.normals?.elements ?? positions.map { simd_normalize($0) }
            copy.textureCoordinates = MeshBuffers.TextureCoordinates(positions.map { [$0.x / tile + 0.5, -$0.z / tile + 0.5] })
            var tangents: [SIMD3<Float>] = []
            var bitangents: [SIMD3<Float>] = []
            for n in normals {
                var t = SIMD3<Float>(1, 0, 0) - n * n.x
                if simd_length(t) < 1e-3 { t = simd_cross(n, [0, 0, -1]) }
                t = simd_normalize(t)
                tangents.append(t)
                bitangents.append(simd_normalize(simd_cross(n, t)))
            }
            copy.tangents = MeshBuffers.Tangents(tangents)
            copy.bitangents = MeshBuffers.Tangents(bitangents)
            return copy
        }
        func parts(_ suffix: String, material: Int) -> [MeshResource.Part] {
            textured.map { part in
                var copy = part
                copy.id = part.id + suffix
                copy.materialIndex = material
                return copy
            }
        }
        var contents = MeshResource.Contents()
        contents.models = [MeshResource.Model(id: "core", parts: parts("-core", material: 0)),
                           MeshResource.Model(id: "shell", parts: parts("-shell", material: 1))]
        contents.instances = [MeshResource.Instance(id: "core", model: "core",
                                                    at: simd_float4x4(diagonal: [0.96, 0.7, 0.97, 1])),
                              MeshResource.Instance(id: "shell", model: "shell")]
        return try MeshResource.generate(from: contents)
    }

    private static func materials(_ flavor: Flavor, texture: JellyTexture?) -> [PhysicallyBasedMaterial] {
        switch flavor {
        case .raspberry: jelly(0.88, 0.03, 0.04, shell: 0.8, core: 0.85, glow: 0.7, texture: texture)
        case .orange: jelly(1.0, 0.50, 0.0, shell: 0.8, core: 0.85, glow: 0.7, texture: texture)
        case .lemon: jelly(1.0, 0.84, 0.05, shell: 0.8, core: 0.85, glow: 0.7, texture: texture)
        case .strawberry: jelly(0.16, 0.52, 0.02, shell: 0.8, core: 0.85, glow: 0.7, texture: texture)
        case .pineapple: jelly(0.95, 0.86, 0.6, shell: 0.45, core: 0.55, glow: 0.4, texture: texture)
        }
    }

    /// RealityKit has no transmission or subsurface scattering, and alpha blending over a light background
    /// washes a tinted shell out to pastel where real jelly filters light and stays saturated. So a bright,
    /// self-lit, mottled core sits inside a deeper glossy shell: the body glows from within, the rims stay
    /// deeper, and emissive rather than diffuse color keeps it colored instead of painted.
    private static func jelly(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, shell shellOpacity: Float,
                              core coreOpacity: Float, glow: Float, texture: JellyTexture?) -> [PhysicallyBasedMaterial] {
        let deep = UIColor(red: red, green: green, blue: blue, alpha: 1)
        let light = UIColor(red: red + (1 - red) * 0.04, green: green + (1 - green) * 0.04, blue: blue + (1 - blue) * 0.04, alpha: 1)
        let diffuse = UIColor(red: red * 0.4, green: green * 0.4, blue: blue * 0.4, alpha: 1)
        var core = PhysicallyBasedMaterial()
        core.baseColor = .init(tint: diffuse)
        core.metallic = 0.0
        core.roughness = 0.6
        core.specular = 0.1
        core.emissiveColor = .init(color: light, texture: texture.map { .init($0.glow) })
        core.emissiveIntensity = glow
        core.blending = .transparent(opacity: .init(floatLiteral: coreOpacity))
        core.faceCulling = .back

        var shell = PhysicallyBasedMaterial()
        shell.baseColor = .init(tint: diffuse)
        shell.metallic = 0.0
        shell.roughness = 0.15
        shell.specular = 0.5
        shell.clearcoat = 1.0
        shell.clearcoatRoughness = 0.06
        if let texture { shell.normal = .init(texture: .init(texture.bumps)) }
        shell.emissiveColor = .init(color: deep)
        shell.emissiveIntensity = glow * 0.5
        shell.blending = .transparent(opacity: .init(floatLiteral: shellOpacity))
        shell.faceCulling = .back
        return [core, shell]
    }
}

/// Tileable speckle of soft blobs, like the bubbles and starch-mold texture inside a gummy: a brightness
/// map for the glowing core and matching bumps for the shell.
struct JellyTexture {
    let glow: TextureResource
    let bumps: TextureResource

    static func make() async throws -> JellyTexture {
        let size = 256
        var height = [Float](repeating: 0, count: size * size)
        var rng = ToppingRandom(seed: 7)
        for index in 0..<420 {
            let big = index < 40
            let cx = Float.random(in: 0..<Float(size), using: &rng)
            let cy = Float.random(in: 0..<Float(size), using: &rng)
            let radius = big ? Float.random(in: 14...30, using: &rng) : Float.random(in: 2.5...9, using: &rng)
            let amount = big ? Float.random(in: -0.5...0.5, using: &rng) : Float.random(in: 0.3...1, using: &rng)
            let reach = Int(radius * 2.5)
            for dy in -reach...reach {
                for dx in -reach...reach {
                    let d2 = Float(dx * dx + dy * dy) / (radius * radius)
                    guard d2 < 6 else { continue }
                    let x = (Int(cx) + dx + size) % size, y = (Int(cy) + dy + size) % size
                    height[y * size + x] += amount * exp(-d2)
                }
            }
        }
        let lo = height.min()!, hi = height.max()!
        height = height.map { ($0 - lo) / (hi - lo) }

        var glow = [UInt8](repeating: 255, count: size * size * 4)
        var bumps = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let i = y * size + x
                let g = UInt8(255 * (0.62 + 0.38 * height[i]))
                glow[i * 4] = g
                glow[i * 4 + 1] = g
                glow[i * 4 + 2] = g
                let dx = height[y * size + (x + 1) % size] - height[y * size + (x + size - 1) % size]
                let dy = height[((y + 1) % size) * size + x] - height[((y + size - 1) % size) * size + x]
                let n = simd_normalize(SIMD3<Float>(-dx * 2.2, dy * 2.2, 1))
                bumps[i * 4] = UInt8(255 * (n.x * 0.5 + 0.5))
                bumps[i * 4 + 1] = UInt8(255 * (n.y * 0.5 + 0.5))
                bumps[i * 4 + 2] = UInt8(255 * (n.z * 0.5 + 0.5))
            }
        }
        return JellyTexture(glow: try await texture(glow, size: size, semantic: .color),
                            bumps: try await texture(bumps, size: size, semantic: .normal))
    }

    private static func texture(_ bytes: [UInt8], size: Int, semantic: TextureResource.Semantic) async throws -> TextureResource {
        let data = Data(bytes) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                                  space: CGColorSpace(name: semantic == .color ? CGColorSpace.sRGB : CGColorSpace.linearSRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw CocoaError(.coderInvalidValue) }
        return try await TextureResource(image: image, options: .init(semantic: semantic))
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
            (simd_quatf(angle: 0.06, axis: [0, 0, 1]), [-r * 1.03, 0, r * 0.6]),
            (simd_quatf(angle: -0.05, axis: [1, 0, 0]), [r * 1.03, 0, r * 0.6]),
            (simd_quatf(angle: 0.04, axis: [1, 0, 0]), [0, 0, -r * 1.18]),
            (simd_quatf(angle: 0.45, axis: [1, 0, 0]) * simd_quatf(angle: 0.2, axis: [0, 0, 1]),
             [0, pieces[0].halfExtents.y * 1.4, r * 0.1]),
        ]
        return IconPile.compose(layout.enumerated().map { index, entry in
            (pieces[index % pieces.count].mesh, [materials[colors[index]]], entry.0, entry.1)
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
        let radius: Float = 0.013
        let height: Float = 0.0075
        var entries: [(MeshResource, [any RealityKit.Material], simd_quatf, SIMD3<Float>)] = []
        for index in 0..<52 {
            let r = radius * sqrt(Float(index) / 52) * Float.random(in: 0.85...1.0, using: &rng)
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
