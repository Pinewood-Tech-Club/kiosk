import RealityKit
import UIKit

/// Stand-in candy (rounded bars, lentils, rods) sized like the real toppings, for testing scatter layers.
@MainActor
struct PlaceholderScatterKind: ScatterKind {
    enum Shape { case gummy, lentil, sprinkle }

    let shape: Shape

    var count: Int {
        switch shape {
        case .gummy: 8
        case .lentil: 8
        case .sprinkle: 70
        }
    }

    func makePieces(rng: inout ToppingRandom) -> [ScatterPiece] {
        let resources = Self.resources(shape)
        return (0..<count).map { _ in
            let material = resources.materials[Int.random(in: 0..<resources.materials.count, using: &rng)]
            return ScatterPiece(mesh: resources.mesh, materials: [material], halfExtents: resources.half)
        }
    }

    func makeIconPile(rng: inout ToppingRandom) -> Entity {
        let pieces = makePieces(rng: &rng).prefix(shape == .sprinkle ? 30 : 4)
        let largest = pieces.map { max($0.halfExtents.x, $0.halfExtents.z) }.max() ?? 0.004
        return IconPile.compose(pieces.enumerated().map { index, piece in
            let angle = Float(index) * 2.39996
            let r = largest * 1.6 * sqrt(Float(index) / Float(pieces.count))
            return (piece.mesh, piece.materials, simd_quatf(angle: angle, axis: [0, 1, 0]), [cos(angle) * r, 0, sin(angle) * r])
        })
    }

    private struct Resources {
        let mesh: MeshResource
        let materials: [any RealityKit.Material]
        let half: SIMD3<Float>
    }

    private static var cache: [Shape: Resources] = [:]

    private static func resources(_ shape: Shape) -> Resources {
        if let cached = cache[shape] { return cached }
        let made: Resources
        switch shape {
        case .gummy:
            let size = SIMD3<Float>(0.012, 0.008, 0.02)
            made = Resources(mesh: .generateBox(size: size, cornerRadius: 0.0035),
                             materials: materials([0xE53935, 0x43A047, 0xFDD835, 0xFB8C00, 0xFFFFFF], roughness: 0.25, clearcoat: true),
                             half: size / 2)
        case .lentil:
            made = Resources(mesh: lentil(radius: 0.0065, halfHeight: 0.003),
                             materials: materials([0xD32F2F, 0x1E88E5, 0x43A047, 0xFDD835, 0xEF6C00, 0x6D4C41], roughness: 0.2, clearcoat: true),
                             half: [0.0065, 0.003, 0.0065])
        case .sprinkle:
            let size = SIMD3<Float>(0.0015, 0.0015, 0.007)
            made = Resources(mesh: .generateBox(size: size, cornerRadius: 0.0007),
                             materials: materials([0xF06292, 0x4FC3F7, 0xFFF176, 0x81C784, 0xBA68C8, 0xFFFFFF], roughness: 0.5, clearcoat: false),
                             half: size / 2)
        }
        cache[shape] = made
        return made
    }

    private static func materials(_ colors: [UInt32], roughness: Float, clearcoat: Bool) -> [any RealityKit.Material] {
        colors.map { hex in
            var material = PhysicallyBasedMaterial()
            material.baseColor = .init(tint: UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                                                     green: CGFloat((hex >> 8) & 0xFF) / 255,
                                                     blue: CGFloat(hex & 0xFF) / 255, alpha: 1))
            material.roughness = .init(floatLiteral: roughness)
            material.metallic = .init(floatLiteral: 0)
            if clearcoat {
                material.clearcoat = .init(floatLiteral: 0.8)
                material.clearcoatRoughness = .init(floatLiteral: 0.1)
            }
            return material
        }
    }

    private static func lentil(radius: Float, halfHeight: Float) -> MeshResource {
        let rings = 12, segments = 24
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for ring in 0...rings {
            let phi = Float.pi * Float(ring) / Float(rings)
            for segment in 0...segments {
                let theta = 2 * Float.pi * Float(segment) / Float(segments)
                let unit = SIMD3<Float>(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta))
                positions.append(unit * SIMD3(radius, halfHeight, radius))
                normals.append(simd_normalize(unit / SIMD3(radius, halfHeight, radius)))
            }
        }
        let stride = UInt32(segments + 1)
        for ring in 0..<UInt32(rings) {
            for segment in 0..<UInt32(segments) {
                let a = ring * stride + segment, b = a + stride
                indices += [a, a + 1, b, a + 1, b + 1, b]
            }
        }
        var descriptor = MeshDescriptor(name: "lentil")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        return (try? MeshResource.generate(from: [descriptor])) ?? .generateSphere(radius: radius)
    }
}
