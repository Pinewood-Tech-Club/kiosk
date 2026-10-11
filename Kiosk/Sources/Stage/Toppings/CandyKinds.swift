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

enum CandyTexture {
    static func make(_ bytes: [UInt8], width: Int, height: Int, semantic: TextureResource.Semantic) async throws -> TextureResource {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: semantic == .color ? CGColorSpace.sRGB : CGColorSpace.linearSRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw CocoaError(.coderInvalidValue) }
        return try await TextureResource(image: image, options: .init(semantic: semantic))
    }
}

struct GummyBears: ScatterKind {
    enum Flavor: CaseIterable {
        case raspberry, orange, lemon, strawberry, pineapple
    }

    /// The shell plus a slightly smaller core inside it: material 0 is the opaque core, 1 the translucent shell.
    let bear: CandyMeshes.Built
    /// Per flavor: [core, shell].
    let materials: [[PhysicallyBasedMaterial]]

    var count: Int { 8 }

    private init(bear: CandyMeshes.Built, materials: [[PhysicallyBasedMaterial]]) {
        self.bear = bear
        self.materials = materials
    }

    static func make(shell: CandyMeshes.Built) async -> GummyBears {
        let bear = CandyMeshes.Built(mesh: (try? withCore(shell.mesh)) ?? shell.mesh, halfExtents: shell.halfExtents)
        var materials: [[PhysicallyBasedMaterial]] = []
        for flavor in Flavor.allCases {
            let recipe = recipe(flavor)
            materials.append(jelly(recipe, shade: try? await JellyShade(recipe)))
        }
        return GummyBears(bear: bear, materials: materials)
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

    /// The shell keeps the asset's UVs, which carry shading data (see gummy_bear.py): u = how face-on the surface is,
    /// v = jelly thickness behind it, roughened here with blotchy noise so the color mottles like the bubbles and starch
    /// specks in a real bear. The core is the shell pushed inward by a share of the local thickness, so a band of bare
    /// shell lines every silhouette from any angle; it keeps u and swaps v for the noise alone.
    private static func withCore(_ mesh: MeshResource) throws -> MeshResource {
        guard let model = mesh.contents.models.first(where: { _ in true }) else { return mesh }
        let ys = model.parts.flatMap { $0.positions.elements.map(\.y) }
        let depth = (ys.max() ?? 0) - (ys.min() ?? 0)
        func shading(_ part: MeshResource.Part) -> [SIMD2<Float>] {
            if let file = part.textureCoordinates?.elements, file.count == part.positions.count { return file }
            return (part.normals?.elements ?? part.positions.elements.map { simd_normalize($0) }).map { [abs($0.y), 0.4] }
        }
        func parts(_ suffix: String, material: Int, inset: Bool,
                   uv: (SIMD3<Float>, SIMD2<Float>) -> SIMD2<Float>) -> [MeshResource.Part] {
            model.parts.map { part in
                var copy = part
                copy.id = part.id + suffix
                copy.materialIndex = material
                let shade = shading(part)
                if inset, let normals = part.normals?.elements, normals.count == part.positions.count {
                    copy.positions = MeshBuffers.Positions(zip(zip(part.positions.elements, normals), shade).map { pn, uv in
                        pn.0 - pn.1 * min(0.1 * uv.y * 2 * depth + 0.0001, 0.0004, 0.4 * uv.y * 2 * depth)
                    })
                }
                // Lookups stay between the outer texel centers: the default sampler wraps, so u = 1 would blend in u = 0.
                let scale = Float(JellyShade.size - 1) / Float(JellyShade.size)
                copy.textureCoordinates = MeshBuffers.TextureCoordinates(zip(part.positions.elements, shade).map {
                    uv($0, $1) * scale + 0.5 / Float(JellyShade.size)
                })
                copy.tangents = nil
                copy.bitangents = nil
                return copy
            }
        }
        let hasNormals = model.parts.allSatisfy { $0.normals?.count == $0.positions.count }
        let core = parts("-core", material: 0, inset: hasNormals) { p, uv in [uv.x, JellyNoise.blotches(p)] }
        let shell = parts("-shell", material: 1, inset: false) { p, uv in
            [uv.x, min(max(uv.y + (JellyNoise.blotches(p * 1.8) - 0.5) * 0.22, 0), 1)]
        }
        var contents = MeshResource.Contents()
        contents.models = [MeshResource.Model(id: "core", parts: core), MeshResource.Model(id: "shell", parts: shell)]
        contents.instances = [MeshResource.Instance(id: "core", model: "core",
                                                    at: hasNormals ? matrix_identity_float4x4 : simd_float4x4(diagonal: [0.84, 0.62, 0.88, 1])),
                              MeshResource.Instance(id: "shell", model: "shell")]
        return try MeshResource.generate(from: contents)
    }

    struct Recipe {
        let color: SIMD3<Float>
        /// Thick parts.
        let deep: SIMD3<Float>
        /// How much paler the thin parts are than the base color, toward white.
        let pale: Float
        /// Shell opacity where the jelly is thin, and where it is thick.
        let shell: Float
        let shellThick: Float
        let glow: Float
    }

    private static func recipe(_ flavor: Flavor) -> Recipe {
        switch flavor {
        case .raspberry: Recipe(color: [0.94, 0.07, 0.04], deep: [0.62, 0.0, 0.02], pale: 0.06, shell: 0.5, shellThick: 0.74, glow: 2.0)
        case .orange: Recipe(color: [1.0, 0.56, 0.03], deep: [0.88, 0.32, 0.0], pale: 0.08, shell: 0.5, shellThick: 0.74, glow: 1.9)
        case .lemon: Recipe(color: [1.0, 0.86, 0.06], deep: [0.96, 0.7, 0.0], pale: 0.08, shell: 0.48, shellThick: 0.72, glow: 1.8)
        case .strawberry: Recipe(color: [0.2, 0.56, 0.03], deep: [0.06, 0.32, 0.0], pale: 0.1, shell: 0.5, shellThick: 0.74, glow: 2.1)
        case .pineapple: Recipe(color: [1.0, 0.94, 0.74], deep: [0.92, 0.8, 0.52], pale: 0.04, shell: 0.44, shellThick: 0.66, glow: 1.35)
        }
    }

    /// RealityKit has no transmission or subsurface scattering, and alpha blending over a light background
    /// washes a tinted shell out to pastel where real jelly filters light and stays saturated. So a bright,
    /// self-lit, mottled core sits just inside a translucent shell: along every silhouette only the shell is
    /// crossed and the scoop shows through it, while the core glows through the middle. The core is opaque so
    /// overlapping bears and other candy never sort wrongly against it; only the thin shells blend.
    private static func jelly(_ recipe: Recipe, shade: JellyShade?) -> [PhysicallyBasedMaterial] {
        let c = recipe.color
        let flat = UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
        let diffuse = UIColor(red: CGFloat(c.x * 0.18), green: CGFloat(c.y * 0.18), blue: CGFloat(c.z * 0.18), alpha: 1)
        var core = PhysicallyBasedMaterial()
        core.baseColor = .init(tint: diffuse)
        core.metallic = 0.0
        core.roughness = 1.0
        core.specular = 0.0
        core.emissiveIntensity = recipe.glow
        core.faceCulling = .back

        var shell = PhysicallyBasedMaterial()
        shell.baseColor = .init(tint: diffuse)
        shell.metallic = 0.0
        shell.roughness = 0.62
        shell.specular = 0.24
        shell.emissiveIntensity = recipe.glow * 0.7
        shell.faceCulling = .back

        // A textured emissive ignores its tint, so the textures carry the color themselves.
        if let shade {
            core.emissiveColor = .init(texture: .init(shade.coreGlow))
            shell.emissiveColor = .init(texture: .init(shade.shellGlow))
            shell.blending = .transparent(opacity: .init(scale: 1, texture: .init(shade.shellOpacity)))
        } else {
            core.emissiveColor = .init(color: flat)
            shell.emissiveColor = .init(color: flat)
            shell.blending = .transparent(opacity: .init(floatLiteral: recipe.shell))
        }
        return [core, shell]
    }
}

/// Lookup textures indexed by the bear's UVs. Shell: u = face-on, v = thickness. Core: v = blotch noise.
struct JellyShade {
    static let size = 64
    let shellGlow: TextureResource
    let shellOpacity: TextureResource
    let coreGlow: TextureResource

    init(_ recipe: GummyBears.Recipe) async throws {
        let c = recipe.color
        let one = SIMD3<Float>(repeating: 1)
        let light = c + (one - c) * recipe.pale
        let deep = recipe.deep
        func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
            let t = min(max((x - a) / (b - a), 0), 1)
            return t * t * (3 - 2 * t)
        }
        func thick(_ v: Float) -> Float { smooth(0.12, 0.6, v) }
        shellGlow = try await Self.bake(.color) { u, v in light + (deep - light) * min(0.7 * thick(v) + 0.5 * (1 - u), 1) }
        shellOpacity = try await Self.bake(.raw) { u, v in
            SIMD3(repeating: recipe.shell + (recipe.shellThick - recipe.shell) * thick(v) + 0.16 * (1 - u))
        }
        coreGlow = try await Self.bake(.color) { _, n in
            c * (0.55 + 0.45 * n) + (one - c) * (0.14 * n * n * n)
        }
    }

    private static func bake(_ semantic: TextureResource.Semantic, _ value: (Float, Float) -> SIMD3<Float>) async throws -> TextureResource {
        var bytes = [UInt8](repeating: 255, count: size * size * 4)
        for row in 0..<size {
            let v = 1 - (Float(row) + 0.5) / Float(size)
            for column in 0..<size {
                let rgb = simd_clamp(value((Float(column) + 0.5) / Float(size), v), .zero, SIMD3<Float>(repeating: 1))
                let i = (row * size + column) * 4
                bytes[i] = UInt8(255 * rgb.x)
                bytes[i + 1] = UInt8(255 * rgb.y)
                bytes[i + 2] = UInt8(255 * rgb.z)
            }
        }
        return try await CandyTexture.make(bytes, width: size, height: size, semantic: semantic)
    }
}

enum JellyNoise {
    static func blotches(_ p: SIMD3<Float>) -> Float {
        let n = 0.7 * value(p / 0.0011) + 0.3 * value(p / 0.0006 + 17.3)
        return min(max((n - 0.5) * 1.6 + 0.5, 0), 1)
    }

    private static func value(_ p: SIMD3<Float>) -> Float {
        let cell = p.rounded(.down)
        let f = p - cell
        let w = f * f * (3 - 2 * f)
        func corner(_ dx: Float, _ dy: Float, _ dz: Float) -> Float {
            let c = SIMD3<Int32>(Int32(cell.x + dx), Int32(cell.y + dy), Int32(cell.z + dz))
            var h = UInt32(bitPattern: c.x &* 73_856_093) ^ UInt32(bitPattern: c.y &* 19_349_663) ^ UInt32(bitPattern: c.z &* 83_492_791)
            h = (h ^ (h >> 13)) &* 0x5bd1_e995
            h ^= h >> 15
            return Float(h & 0xFFFF) / 65535
        }
        func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
        let x00 = lerp(corner(0, 0, 0), corner(1, 0, 0), w.x), x10 = lerp(corner(0, 1, 0), corner(1, 1, 0), w.x)
        let x01 = lerp(corner(0, 0, 1), corner(1, 0, 1), w.x), x11 = lerp(corner(0, 1, 1), corner(1, 1, 1), w.x)
        return lerp(lerp(x00, x10, w.y), lerp(x01, x11, w.y), w.z)
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
