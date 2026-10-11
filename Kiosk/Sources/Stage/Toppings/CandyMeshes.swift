import RealityKit
import simd

enum CandyMeshes {
    struct Built {
        let mesh: MeshResource
        let halfExtents: SIMD3<Float>
    }

    /// A superellipse of revolution: `exponent` > 2 flattens the faces while keeping the rim round.
    static func lentil(radius: Float, halfThickness: Float, exponent: Float, ovality: Float,
                       segments: Int = 40, rings: Int = 22) throws -> Built {
        let power = 2 / exponent
        func shaped(_ v: Float) -> Float { copysign(pow(abs(v), power), v) }
        var rows: [[SIMD3<Float>]] = []
        for i in 1..<rings {
            let t = -Float.pi / 2 + Float.pi * Float(i) / Float(rings)
            let r = radius * shaped(cos(t))
            let y = halfThickness * shaped(sin(t))
            rows.append((0..<segments).map { j in
                let a = 2 * Float.pi * Float(j) / Float(segments)
                return [r * cos(a) * (1 + ovality), y, r * sin(a) * (1 - ovality)]
            })
        }
        return try build(rows: rows, start: [0, -halfThickness, 0], end: [0, halfThickness, 0], name: "lentil")
    }

    /// A plump candy lentil with a little irregularity from `rng` (wobbly outline, uneven faces, shallow dents).
    /// The print face (+Y, or -Y when `printUp` is false) has a top-down planar projection filling the UV square,
    /// mirrored underneath so the print reads correctly once the piece is flipped. The other face sits on one
    /// constant UV; the two halves have separate equator vertices so no triangle blends between the mappings.
    static func candyLentil(radius: Float, halfThickness: Float, exponent: Float, printUp: Bool,
                            rng: inout ToppingRandom, segments: Int = 48, rings: Int = 24) throws -> Built {
        let power = 2 / exponent
        func shaped(_ v: Float) -> Float { copysign(pow(abs(v), power), v) }
        let wobble = [0.02, 0.008, 0.005].enumerated().map { k, amount in
            (k: Float(k + 2), amount: Float.random(in: 0...amount, using: &rng), phase: Float.random(in: 0...(2 * .pi), using: &rng))
        }
        let lift = Float.random(in: -0.06...0.06, using: &rng)
        let tilt = SIMD2<Float>(.random(in: -0.025...0.025, using: &rng), .random(in: -0.025...0.025, using: &rng))
        func smoothPoint(_ t: Float, _ a: Float) -> SIMD3<Float> {
            let edge = radius * (1 + wobble.reduce(0) { $0 + $1.amount * cos($1.k * a + $1.phase) })
            let r = edge * shaped(cos(t))
            let y = halfThickness * (1 + (t > 0 ? lift : -lift)) * shaped(sin(t)) + tilt.x * r * cos(a) + tilt.y * r * sin(a)
            return [r * cos(a), y, r * sin(a)]
        }
        let dents = (0..<Int.random(in: 1...3, using: &rng)).map { _ in
            (center: smoothPoint(.random(in: -1.3...1.3, using: &rng), .random(in: 0...(2 * .pi), using: &rng)),
             reach: Float.random(in: 0.0012...0.0024, using: &rng), depth: Float.random(in: 0.00005...0.00014, using: &rng))
        }
        func point(_ t: Float, _ a: Float) -> SIMD3<Float> {
            var p = smoothPoint(t, a)
            for dent in dents {
                let d2 = simd_distance_squared(p, dent.center) / (dent.reach * dent.reach)
                if d2 < 9 { p -= simd_normalize(p) * dent.depth * exp(-d2) }
            }
            return p
        }

        let half = rings / 2
        var positions: [SIMD3<Float>] = []
        var weld: [Int] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        let span = 2 * radius * 1.08
        var equator: [Int] = []
        for top in [true, false] {
            let sign: Float = top ? 1 : -1
            let printed = top == printUp
            func uv(_ p: SIMD3<Float>) -> SIMD2<Float> {
                guard printed else { return [0.01, 0.01] }
                return [0.5 + p.x / span, 0.5 + (top ? -p.z : p.z) / span]
            }
            let pole = positions.count
            let polePoint = point(sign * .pi / 2, 0)
            positions.append(polePoint)
            weld.append(pole)
            uvs.append(uv(polePoint))
            var rows: [Int] = []
            for k in 1...half {
                let t = sign * (Float.pi / 2 - Float.pi * Float(k) / Float(rings))
                rows.append(positions.count)
                for j in 0..<segments {
                    let p = point(t, 2 * .pi * Float(j) / Float(segments))
                    weld.append(k == half && !top ? equator[j] : positions.count)
                    if k == half && top { equator.append(positions.count) }
                    positions.append(p)
                    uvs.append(uv(p))
                }
            }
            func index(_ row: Int, _ j: Int) -> UInt32 { UInt32(rows[row] + j % segments) }
            for j in 0..<segments {
                indices += [UInt32(pole), index(0, j), index(0, j + 1)]
            }
            for row in 0..<(rows.count - 1) {
                for j in 0..<segments {
                    let a = index(row, j), b = index(row, j + 1), c = index(row + 1, j), d = index(row + 1, j + 1)
                    indices += [a, c, b, b, c, d]
                }
            }
        }

        let lo = positions.reduce(SIMD3<Float>(repeating: .greatestFiniteMagnitude)) { simd_min($0, $1) }
        let hi = positions.reduce(SIMD3<Float>(repeating: -.greatestFiniteMagnitude)) { simd_max($0, $1) }
        let center = (lo + hi) / 2
        positions = positions.map { $0 - center }
        for t in stride(from: 0, to: indices.count, by: 3) {
            let p0 = positions[Int(indices[t])], p1 = positions[Int(indices[t + 1])], p2 = positions[Int(indices[t + 2])]
            if simd_dot(simd_cross(p1 - p0, p2 - p0), p0 + p1 + p2) < 0 { indices.swapAt(t + 1, t + 2) }
        }
        var welded = [SIMD3<Float>](repeating: .zero, count: positions.count)
        for t in stride(from: 0, to: indices.count, by: 3) {
            let i0 = Int(indices[t]), i1 = Int(indices[t + 1]), i2 = Int(indices[t + 2])
            let n = simd_cross(positions[i1] - positions[i0], positions[i2] - positions[i0])
            welded[weld[i0]] += n
            welded[weld[i1]] += n
            welded[weld[i2]] += n
        }
        let normals = weld.map { simd_length(welded[$0]) > 0 ? simd_normalize(welded[$0]) : SIMD3<Float>(0, 1, 0) }

        var descriptor = MeshDescriptor(name: "candy-lentil")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)
        return Built(mesh: try MeshResource.generate(from: [descriptor]), halfExtents: (hi - lo) / 2)
    }

    /// `length` is overall, ends included; `bend` (radians) curves it in the XZ plane so it still lies flat.
    static func sprinkle(length: Float, radius: Float, bend: Float, segments: Int = 10, bodyRows: Int = 8,
                         capRows: Int = 4) throws -> Built {
        let body = max(length - 2 * radius, 0.0005)
        let curvature = bend / body
        func frame(_ s: Float) -> (point: SIMD3<Float>, tangent: SIMD3<Float>) {
            guard abs(curvature) > 1e-4 else { return ([s, 0, 0], [1, 0, 0]) }
            let a = curvature * s
            return ([sin(a) / curvature, 0, (1 - cos(a)) / curvature], [cos(a), 0, sin(a)])
        }
        func ring(_ s: Float, along: Float, scale: Float) -> [SIMD3<Float>] {
            let (p, t) = frame(s)
            let up = SIMD3<Float>(0, 1, 0)
            let side = simd_normalize(simd_cross(t, up))
            return (0..<segments).map { j in
                let a = 2 * Float.pi * Float(j) / Float(segments)
                return p + t * along + (up * cos(a) + side * sin(a)) * scale
            }
        }
        var rows: [[SIMD3<Float>]] = []
        for k in stride(from: capRows - 1, through: 1, by: -1) {
            let lat = Float.pi / 2 * Float(k) / Float(capRows)
            rows.append(ring(-body / 2, along: -radius * sin(lat), scale: radius * cos(lat)))
        }
        for k in 0...bodyRows {
            rows.append(ring(-body / 2 + body * Float(k) / Float(bodyRows), along: 0, scale: radius))
        }
        for k in 1..<capRows {
            let lat = Float.pi / 2 * Float(k) / Float(capRows)
            rows.append(ring(body / 2, along: radius * sin(lat), scale: radius * cos(lat)))
        }
        let start = frame(-body / 2), end = frame(body / 2)
        return try build(rows: rows, start: start.point - start.tangent * radius, end: end.point + end.tangent * radius,
                         name: "sprinkle")
    }

    private static func build(rows: [[SIMD3<Float>]], start: SIMD3<Float>, end: SIMD3<Float>, name: String) throws -> Built {
        let segments = rows[0].count
        var positions = [start] + rows.flatMap { $0 } + [end]
        let last = UInt32(positions.count - 1)
        func index(_ row: Int, _ j: Int) -> UInt32 { UInt32(1 + row * segments + (j % segments)) }
        var indices: [UInt32] = []
        for j in 0..<segments {
            indices += [0, index(0, j), index(0, j + 1)]
            indices += [last, index(rows.count - 1, j + 1), index(rows.count - 1, j)]
        }
        for row in 0..<(rows.count - 1) {
            for j in 0..<segments {
                let a = index(row, j), b = index(row, j + 1), c = index(row + 1, j), d = index(row + 1, j + 1)
                indices += [a, c, b, b, c, d]
            }
        }
        var volume: Float = 0
        for t in stride(from: 0, to: indices.count, by: 3) {
            volume += simd_dot(positions[Int(indices[t])], simd_cross(positions[Int(indices[t + 1])], positions[Int(indices[t + 2])]))
        }
        if volume < 0 {
            for t in stride(from: 0, to: indices.count, by: 3) { indices.swapAt(t + 1, t + 2) }
        }

        let lo = positions.reduce(SIMD3<Float>(repeating: .greatestFiniteMagnitude)) { simd_min($0, $1) }
        let hi = positions.reduce(SIMD3<Float>(repeating: -.greatestFiniteMagnitude)) { simd_max($0, $1) }
        let center = (lo + hi) / 2
        positions = positions.map { $0 - center }

        var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
        for t in stride(from: 0, to: indices.count, by: 3) {
            let i0 = Int(indices[t]), i1 = Int(indices[t + 1]), i2 = Int(indices[t + 2])
            let n = simd_cross(positions[i1] - positions[i0], positions[i2] - positions[i0])
            normals[i0] += n
            normals[i1] += n
            normals[i2] += n
        }
        normals = normals.map { simd_length($0) > 0 ? simd_normalize($0) : [0, 1, 0] }

        var descriptor = MeshDescriptor(name: name)
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        return Built(mesh: try MeshResource.generate(from: [descriptor]), halfExtents: (hi - lo) / 2)
    }
}
