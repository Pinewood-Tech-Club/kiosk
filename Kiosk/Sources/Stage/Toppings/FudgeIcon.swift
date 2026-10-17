import RealityKit
import UIKit

/// The hot fudge card's icon: a steel ladle brimming with fudge, one fat drip run over its lip and down the outside.
/// Real size, resting on y = 0. Needs the stage's lighting.
@MainActor
enum FudgeIcon {
    private static let bowl: Float = 0.012
    private static let wall: Float = 0.0008
    private static let rimAngle: Float = 68 * .pi / 180
    private static var rimRadius: Float { bowl * sin(rimAngle) }
    private static var rimHeight: Float { bowl * (1 - cos(rimAngle)) }
    private static var fudgeLevel: Float { rimHeight - 0.0005 }
    private static let dripAngle: Float = .pi / 2

    static func make() -> Entity {
        let root = Entity()
        root.name = "fudge-icon"
        var steel = PhysicallyBasedMaterial()
        steel.baseColor = .init(tint: UIColor(red: 0.8, green: 0.8, blue: 0.82, alpha: 1))
        steel.metallic = .init(floatLiteral: 1)
        steel.roughness = .init(floatLiteral: 0.24)
        var fudge = FudgeStyle.material
        fudge.roughness = .init(floatLiteral: 0.14)
        fudge.clearcoatRoughness = .init(floatLiteral: 0.015)
        for (descriptor, material) in [(bowlMesh(), steel), (handleMesh(), steel), (surfaceMesh(), fudge), (dripMesh(), fudge)] {
            if let mesh = try? MeshResource.generate(from: [descriptor]) {
                root.addChild(ModelEntity(mesh: mesh, materials: [material]))
            }
        }
        return root
    }

    private struct Builder {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        mutating func grid(rows: Int, columns: Int, wrap: Bool) {
            let start = UInt32(positions.count - rows * columns)
            let across = wrap ? columns : columns - 1
            for r in 0..<(rows - 1) {
                for c in 0..<across {
                    let c1 = (c + 1) % columns
                    let a = start + UInt32(r * columns + c), b = start + UInt32(r * columns + c1)
                    let d = a + UInt32(columns), e = b + UInt32(columns)
                    indices += [a, d, b, b, d, e]
                }
            }
        }

        func descriptor(_ name: String) -> MeshDescriptor {
            var descriptor = MeshDescriptor(name: name)
            descriptor.positions = MeshBuffer(positions)
            descriptor.normals = MeshBuffer(normals)
            descriptor.primitives = .triangles(indices)
            return descriptor
        }
    }

    /// The bowl turned from one profile: the outside, a rounded lip, and the inside back down.
    private static func bowlMesh() -> MeshDescriptor {
        var profile: [(SIMD2<Float>, SIMD2<Float>)] = []
        let steps = 28
        for i in 0...steps {
            let phi = rimAngle * Float(i) / Float(steps)
            profile.append(([bowl * sin(phi), bowl - bowl * cos(phi)], [sin(phi), -cos(phi)]))
        }
        let inner = bowl - wall
        let outerRim = SIMD2<Float>(bowl * sin(rimAngle), bowl - bowl * cos(rimAngle))
        let innerRim = SIMD2<Float>(inner * sin(rimAngle), bowl - inner * cos(rimAngle))
        let lip = (outerRim + innerRim) / 2
        let outward = simd_normalize(outerRim - innerRim)
        let upward = SIMD2<Float>(-outward.y, outward.x)
        for i in 1..<10 {
            let a = Float.pi * Float(i) / 10
            let n = outward * cos(a) + upward * sin(a) * (upward.y > 0 ? 1 : -1)
            profile.append((lip + n * (wall / 2), n))
        }
        for i in stride(from: steps, through: 0, by: -1) {
            let phi = rimAngle * Float(i) / Float(steps)
            profile.append(([inner * sin(phi), bowl - inner * cos(phi)], [-sin(phi), cos(phi)]))
        }
        var mesh = Builder()
        let sides = 72
        for (point, normal) in profile {
            for s in 0..<sides {
                let a = Float(s) / Float(sides) * 2 * .pi
                let c = cos(a), sn = sin(a)
                mesh.positions.append([point.x * c, point.y, point.x * sn])
                mesh.normals.append(simd_normalize(SIMD3(normal.x * c, normal.y, normal.x * sn) + [0, 1e-6, 0]))
            }
        }
        mesh.grid(rows: profile.count, columns: sides, wrap: true)
        return mesh.descriptor("fudge-icon-bowl")
    }

    private static func tube(_ mesh: inout Builder, path: [SIMD3<Float>], up: (Int) -> SIMD3<Float>,
                             radius: (Float) -> SIMD2<Float>) {
        let sides = 20
        let start = mesh.positions.count
        for (i, p) in path.enumerated() {
            let tangent = simd_normalize(path[min(i + 1, path.count - 1)] - path[max(i - 1, 0)])
            var normal = up(i)
            normal = simd_normalize(normal - tangent * simd_dot(normal, tangent))
            let side = simd_cross(tangent, normal)
            let u = Float(i) / Float(path.count - 1)
            let r = radius(u)
            for s in 0..<sides {
                let a = Float(s) / Float(sides) * 2 * .pi
                let c = cos(a), sn = sin(a)
                mesh.positions.append(p + side * (c * r.x) + normal * (sn * r.y))
                mesh.normals.append(simd_normalize(side * (c / max(r.x, 1e-6)) + normal * (sn / max(r.y, 1e-6))))
            }
        }
        mesh.grid(rows: path.count, columns: sides, wrap: true)
        for end in [0, path.count - 1] {
            let tip = UInt32(mesh.positions.count)
            let direction = end == 0 ? path[0] - path[1] : path[end] - path[end - 1]
            mesh.positions.append(path[end])
            mesh.normals.append(simd_normalize(direction))
            let ring = UInt32(start + end * sides)
            for s in 0..<sides {
                let a = ring + UInt32(s), b = ring + UInt32((s + 1) % sides)
                mesh.indices += end == 0 ? [tip, b, a] : [tip, a, b]
            }
        }
    }

    private static func handleMesh() -> MeshDescriptor {
        var mesh = Builder()
        let p0 = SIMD3<Float>(-rimRadius + 0.0004, rimHeight - 0.0012, 0)
        let p1 = SIMD3<Float>(-rimRadius - 0.003, rimHeight + 0.003, 0)
        let p2 = SIMD3<Float>(-rimRadius - 0.0065, rimHeight + 0.0085, 0)
        let p3 = SIMD3<Float>(-rimRadius - 0.0095, rimHeight + 0.0125, 0)
        let path = (0...40).map { cubicBezier(p0, p1, p2, p3, Float($0) / 40) }
        tube(&mesh, path: path, up: { _ in [1, 0, 0] }) { u in
            let r = 0.0012 + 0.0003 * u
            return [r * 1.5, r * 0.75]
        }
        return mesh.descriptor("fudge-icon-handle")
    }

    /// Brimming: domed a little above the lip, softly folded where it was ladled in, its edge tucked into the steel.
    private static func surfaceMesh() -> MeshDescriptor {
        var mesh = Builder()
        let inner = bowl - wall
        let level = fudgeLevel
        let edge = (inner * inner - (bowl - level) * (bowl - level)).squareRoot() + 0.0003
        let rings = 40, sides = 120
        func height(_ r: Float, _ a: Float) -> Float {
            let x = min(r / edge, 1)
            let dome = 0.0019 * pow(1 - x * x, 0.7)
            let fold = 0.00022 * cos(2 * .pi * r / 0.0042 - a) * exp(-r / 0.006) * (1 - x)
            var toward = remainder(a - dripAngle, 2 * .pi)
            toward = exp(-toward * toward / 0.12)
            let spill = 0.0011 * toward * FudgeMath.smoothstep(0.4, 1, x)
            return level + dome + fold + spill
        }
        mesh.positions.append([0, height(0, 0), 0])
        mesh.normals.append([0, 1, 0])
        for i in 1...rings {
            let r = edge * Float(i) / Float(rings)
            for s in 0..<sides {
                let a = Float(s) / Float(sides) * 2 * .pi
                let e: Float = 0.00005
                let dr = (height(r + e, a) - height(max(r - e, 0), a)) / (2 * e)
                let da = (height(r, a + 0.002) - height(r, a - 0.002)) / (0.004 * r)
                let radial = SIMD3<Float>(cos(a), 0, sin(a)), tangent = SIMD3<Float>(-sin(a), 0, cos(a))
                mesh.positions.append(radial * r + [0, height(r, a), 0])
                mesh.normals.append(simd_normalize(SIMD3<Float>(0, 1, 0) - radial * dr - tangent * da))
            }
        }
        for s in 0..<sides {
            mesh.indices += [0, UInt32(1 + (s + 1) % sides), UInt32(1 + s)]
        }
        for i in 1..<rings {
            for s in 0..<sides {
                let a = UInt32(1 + (i - 1) * sides + s), b = UInt32(1 + (i - 1) * sides + (s + 1) % sides)
                let c = a + UInt32(sides), d = b + UInt32(sides)
                mesh.indices += [a, b, c, b, d, c]
            }
        }
        return mesh.descriptor("fudge-icon-surface")
    }

    /// Over the lip and down the outside of the bowl, pressed onto the steel, ending in a heavy bead.
    private static func dripMesh() -> MeshDescriptor {
        var mesh = Builder()
        let radial = SIMD3<Float>(cos(dripAngle), 0, sin(dripAngle))
        var path: [SIMD3<Float>] = []
        var ups: [SIMD3<Float>] = []
        let count = 48
        let inside: Float = rimRadius - 0.0032
        let lipTop = rimHeight + wall / 2
        let lowest = rimAngle - 0.62
        for i in 0...count {
            let u = Float(i) / Float(count)
            if u < 0.3 {
                let x = u / 0.3
                let r = inside + (rimRadius - inside) * x
                let y = fudgeLevel + 0.0012 + (lipTop + 0.0002 - fudgeLevel - 0.0012) * Ease.inOutSine(x)
                path.append(radial * r + [0, y, 0])
                ups.append(simd_normalize(SIMD3<Float>(0, 1, 0) + radial * (0.9 * x * x)))
            } else {
                let x = (u - 0.3) / 0.7
                let phi = rimAngle - (rimAngle - lowest) * x
                let n = radial * sin(phi) + SIMD3<Float>(0, -cos(phi), 0)
                path.append(radial * (bowl * sin(phi)) + [0, bowl - bowl * cos(phi), 0] + n * 0.0002)
                ups.append(n)
            }
        }
        tube(&mesh, path: path, up: { ups[$0] }) { u in
            let neck = 0.0021 + 0.0007 * (1 - FudgeMath.smoothstep(0, 0.35, u))
            let bead = FudgeMath.smoothstep(0.72, 0.95, u) * 0.0008
            let end = (1 - pow(FudgeMath.smoothstep(0.93, 1, u), 2)).squareRoot()
            let w = (neck + bead) * max(end, 0.05)
            return [w, w * 0.62]
        }
        return mesh.descriptor("fudge-icon-drip")
    }
}
