import RealityKit
import UIKit

enum FudgeIconDesign: CaseIterable {
    case dollop, foldedHeap, fallingDrop
}

@MainActor
enum FudgeIcon {
    static func make(_ design: FudgeIconDesign = .dollop) -> Entity {
        let root = Entity()
        root.name = "fudge-icon"
        let field: FudgeField = switch design {
        case .dollop: .dollop()
        case .foldedHeap: .foldedHeap()
        case .fallingDrop: .fallingDrop()
        }
        if let mesh = try? MeshResource.generate(from: [field.mesh(cells: 128)]) {
            root.addChild(ModelEntity(mesh: mesh, materials: [FudgeStyle.material]))
        }
        return root
    }
}

private func smoothUnion(_ a: Float, _ b: Float, _ k: Float) -> Float {
    let h = max(k - abs(a - b), 0) / k
    return min(a, b) - h * h * k * 0.25
}

private func ellipsoid(_ p: SIMD3<Float>, center: SIMD3<Float>, radii: SIMD3<Float>) -> Float {
    let q = p - center
    let k0 = simd_length(q / radii), k1 = simd_length(q / (radii * radii))
    return k1 > 1e-6 ? k0 * (k0 - 1) / k1 : -radii.min()
}

private func roundedSlab(_ p: SIMD3<Float>, edge: Float, thickness: Float) -> Float {
    let q = SIMD2<Float>(simd_length(SIMD2<Float>(p.x, p.z)) - edge + thickness / 2, abs(p.y))
    return simd_length(simd_max(q, .zero)) + min(max(q.x, q.y), 0) - thickness / 2
}

private func boxDistance(_ p: SIMD3<Float>, lower: SIMD3<Float>, upper: SIMD3<Float>) -> Float {
    simd_length(simd_max(simd_max(lower - p, p - upper), .zero))
}

private struct TubeSample {
    var point: SIMD3<Float>
    var radius: Float
    var axis: SIMD3<Float> = [0, 1, 0]
    var spread: Float = 0
}

private struct Tube {
    private struct Segment {
        var start: SIMD3<Float>
        var span: SIMD3<Float>
        var tangent: SIMD3<Float>
        var inverseLength2: Float
        var radii: SIMD2<Float>
        var spreads: SIMD2<Float>
        var axes: (SIMD3<Float>, SIMD3<Float>)
        var reach: SIMD2<Float>
    }

    private struct Chunk {
        var lower: SIMD3<Float>
        var upper: SIMD3<Float>
        var range: Range<Int>
    }

    private var segments: [Segment] = []
    private var chunks: [Chunk] = []

    init(count: Int, _ sample: (Float) -> TubeSample) {
        let samples = (0...count).map { sample(Float($0) / Float(count)) }
        for i in 0..<count {
            let a = samples[i], b = samples[i + 1]
            let span = b.point - a.point
            let length2 = simd_dot(span, span)
            // Interior ribbon segments run on past their ends so neighbours overlap; clamped, every joint leaves a groove.
            segments.append(Segment(start: a.point, span: span, tangent: length2 > 0 ? span / length2.squareRoot() : [0, 1, 0],
                                    inverseLength2: length2 > 0 ? 1 / length2 : 0, radii: [a.radius, b.radius],
                                    spreads: [a.spread, b.spread], axes: (simd_normalize(a.axis), simd_normalize(b.axis)),
                                    reach: [i == 0 ? 0 : -0.5, i == count - 1 ? 1 : 1.5]))
        }
        for start in stride(from: 0, to: segments.count, by: 12) {
            let range = start..<min(start + 12, segments.count)
            var lower = SIMD3<Float>(repeating: .infinity), upper = SIMD3<Float>(repeating: -.infinity)
            for segment in segments[range] {
                let reach = max(segment.radii.x, segment.radii.y) + max(segment.spreads.x, segment.spreads.y)
                let from = segment.start + segment.span * segment.reach.x, to = segment.start + segment.span * segment.reach.y
                lower = simd_min(lower, simd_min(from, to) - reach)
                upper = simd_max(upper, simd_max(from, to) + reach)
            }
            chunks.append(Chunk(lower: lower, upper: upper, range: range))
        }
    }

    func distance(_ p: SIMD3<Float>, within cutoff: Float = .infinity) -> Float {
        var best = cutoff
        segments.withUnsafeBufferPointer { segments in
            // Inside the solid every chunk containing `p` must be measured, or the field jumps at chunk borders and
            // the surface shows seams.
            for chunk in chunks where boxDistance(p, lower: chunk.lower, upper: chunk.upper) <= max(best, 0) {
                for i in chunk.range {
                    let s = segments[i]
                    let offset = p - s.start
                    let along = simd_dot(offset, s.span) * s.inverseLength2
                    let h = Ease.clamp01(along)
                    let radius = s.radii.x + (s.radii.y - s.radii.x) * h
                    let spread = s.spreads.x + (s.spreads.y - s.spreads.x) * h
                    if spread > 0 {
                        let d = offset - s.span * min(max(along, s.reach.x), s.reach.y)
                        let across = simd_cross(s.axes.0 + (s.axes.1 - s.axes.0) * h, s.tangent)
                        let length = simd_length(across)
                        if length > 1e-5 {
                            let width = across / length
                            let q = SIMD3<Float>(max(abs(simd_dot(d, width)) - spread, 0),
                                                 simd_dot(d, simd_cross(s.tangent, width)), simd_dot(d, s.tangent))
                            best = min(best, simd_length(q) - radius)
                            continue
                        }
                    }
                    best = min(best, simd_length(offset - s.span * h) - radius)
                }
            }
        }
        return best
    }
}

private struct FudgeField {
    var lower: SIMD3<Float>
    var upper: SIMD3<Float>
    var distance: (SIMD3<Float>) -> Float

    static func dollop() -> FudgeField {
        FudgeField(lower: [-1, 0, -1], upper: [1, 0.75, 1]) { p in
            var d = plop(p - [0, 0.15, 0], radius: 0.8, thickness: 0.3, phase: 1)
            d = smoothUnion(d, plop(p - [0.1, 0.37, -0.07], radius: 0.5, thickness: 0.28, phase: 2.6), 0.1)
            d = smoothUnion(d, plop(p - [0.02, 0.56, 0.04], radius: 0.24, thickness: 0.22, phase: 4), 0.1)
            return max(d, -p.y)
        }
    }

    static func foldedHeap() -> FudgeField {
        let pile = Tube(count: 420) { t in
            let a = 2 * .pi * 3.4 * t + 0.4
            let wander = 2 * .pi * 1.6 * t + 1
            let center = SIMD3<Float>(cos(wander), 0, 0.9 * sin(wander)) * lerp(0.36, 0.16, t)
            let r = lerp(0.22, 0.17, t) + 0.04 * sin(2 * .pi * 1.7 * t)
            let radial = SIMD3<Float>(cos(a), 0, sin(a))
            return TubeSample(point: center + radial * r + [0, 0.12 + 0.36 * t, 0], radius: 0.085,
                              axis: simd_normalize([0, 1, 0] + radial * 0.3), spread: lerp(0.08, 0.05, t))
        }
        return FudgeField(lower: [-0.95, 0, -0.95], upper: [0.95, 0.75, 0.95]) { p in
            let a = atan2(p.z, p.x)
            let pool = roundedSlab(p - [0, 0.06, 0], edge: 0.78 * (1 + 0.06 * sin(3 * a + 1)), thickness: 0.12)
            return max(smoothUnion(pile.distance(p), pool, 0.12), -p.y)
        }
    }

    static func fallingDrop() -> FudgeField {
        let landing = Tube(count: 160) { t in
            let a = 2 * .pi * 1.8 * t + 2
            let radial = SIMD3<Float>(cos(a), 0, sin(a))
            return TubeSample(point: [0.04, 0.5 + 0.12 * t, 0.02] + radial * (0.2 - 0.09 * t), radius: 0.07, spread: 0.04)
        }
        let tip = Tube(count: 30) { t in
            TubeSample(point: [0.04, 1.06 + 0.3 * t, 0.02], radius: lerp(0.14, 0.012, pow(t, 0.75)))
        }
        return FudgeField(lower: [-1, 0, -1], upper: [1, 1.4, 1]) { p in
            var mound = plop(p - [0, 0.15, 0], radius: 0.8, thickness: 0.3, phase: 1)
            mound = smoothUnion(mound, plop(p - [0.04, 0.38, 0.02], radius: 0.42, thickness: 0.26, phase: 2.6), 0.07)
            mound = smoothUnion(mound, landing.distance(p, within: mound + 0.07), 0.07)
            var drop = ellipsoid(p, center: [0.04, 1.1, 0.02], radii: [0.15, 0.165, 0.15])
            drop = smoothUnion(drop, tip.distance(p, within: drop + 0.1), 0.1)
            return min(max(mound, -p.y), drop)
        }
    }

    private static func plop(_ q: SIMD3<Float>, radius: Float, thickness: Float, phase: Float) -> Float {
        let a = atan2(q.z, q.x)
        let edge = radius * (1 + 0.08 * sin(3 * a + phase) + 0.05 * sin(5 * a + 2 * phase))
        let slab = roundedSlab(q, edge: edge, thickness: thickness)
        return smoothUnion(slab, ellipsoid(q, center: .zero, radii: [edge * 0.8, thickness * 0.85, edge * 0.8]), thickness * 0.6)
    }

    func mesh(cells: Int) -> MeshDescriptor {
        let size = upper - lower
        let h = max(size.x, size.y, size.z) / Float(cells)
        let origin = lower - h * 2
        let n = SIMD3<Int>(Int((size.x / h).rounded(.up)) + 5, Int((size.y / h).rounded(.up)) + 5, Int((size.z / h).rounded(.up)) + 5)
        func index(_ i: Int, _ j: Int, _ k: Int) -> Int { (k * n.y + j) * n.x + i }
        func point(_ i: Int, _ j: Int, _ k: Int) -> SIMD3<Float> { origin + SIMD3(Float(i), Float(j), Float(k)) * h }

        var values = [Float](repeating: 1, count: n.x * n.y * n.z)
        let block = 4
        let reach = Float(block) * h * 0.9 + h
        values.withUnsafeMutableBufferPointer { values in
            DispatchQueue.concurrentPerform(iterations: (n.z - 2) / block + 1) { slab in
                let bk = slab * block
                for bj in stride(from: 0, to: n.y - 1, by: block) {
                    for bi in stride(from: 0, to: n.x - 1, by: block) {
                        let top = SIMD3(min(bi + block, n.x - 1), min(bj + block, n.y - 1), min(bk + block, n.z - 1))
                        let coarse = distance((point(bi, bj, bk) + point(top.x, top.y, top.z)) / 2)
                        for k in bk...top.z {
                            for j in bj...top.y {
                                for i in bi...top.x {
                                    values[index(i, j, k)] = abs(coarse) > reach ? coarse : distance(point(i, j, k))
                                }
                            }
                        }
                    }
                }
            }
        }

        let corners: [SIMD3<Int>] = [[0, 0, 0], [1, 0, 0], [0, 1, 0], [1, 1, 0], [0, 0, 1], [1, 0, 1], [0, 1, 1], [1, 1, 1]]
        let edges: [(Int, Int)] = [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)]
        var vertexOf = [Int32](repeating: -1, count: values.count)
        var positions: [SIMD3<Float>] = []
        for k in 0..<(n.z - 1) {
            for j in 0..<(n.y - 1) {
                for i in 0..<(n.x - 1) {
                    var v = SIMD8<Float>()
                    var inside = 0
                    for c in 0..<8 {
                        v[c] = values[index(i + corners[c].x, j + corners[c].y, k + corners[c].z)]
                        if v[c] < 0 { inside += 1 }
                    }
                    guard inside > 0, inside < 8 else { continue }
                    var sum = SIMD3<Float>.zero
                    var crossings: Float = 0
                    for (a, b) in edges where (v[a] < 0) != (v[b] < 0) {
                        let ca = SIMD3<Float>(corners[a]), cb = SIMD3<Float>(corners[b])
                        sum += ca + (cb - ca) * (v[a] / (v[a] - v[b]))
                        crossings += 1
                    }
                    vertexOf[index(i, j, k)] = Int32(positions.count)
                    positions.append(point(i, j, k) + sum / crossings * h)
                }
            }
        }

        let e = h * 0.6
        func gradient(_ p: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(distance(p + [e, 0, 0]) - distance(p - [e, 0, 0]),
                  distance(p + [0, e, 0]) - distance(p - [0, e, 0]),
                  distance(p + [0, 0, e]) - distance(p - [0, 0, e])) / (2 * e)
        }
        var normals = [SIMD3<Float>](repeating: [0, 1, 0], count: positions.count)
        let batches = 64, total = positions.count
        positions.withUnsafeMutableBufferPointer { positions in
            normals.withUnsafeMutableBufferPointer { normals in
                DispatchQueue.concurrentPerform(iterations: batches) { batch in
                    for v in stride(from: batch, to: total, by: batches) {
                        let start = positions[v]
                        var p = start
                        for _ in 0..<2 {
                            let g = gradient(p)
                            let length2 = simd_dot(g, g)
                            guard length2 > 1e-8 else { break }
                            p -= g * (distance(p) / length2)
                        }
                        if simd_length(p - start) > h { p = start + simd_normalize(p - start) * h }
                        positions[v] = p
                        let g = gradient(p)
                        if simd_length(g) > 1e-6 { normals[v] = simd_normalize(g) }
                    }
                }
            }
        }

        var indices: [UInt32] = []
        func quad(_ cells: [(Int, Int, Int)]) {
            let q = cells.map { Int(vertexOf[index($0.0, $0.1, $0.2)]) }
            guard !q.contains(-1) else { return }
            let split = simd_distance(positions[q[0]], positions[q[2]]) <= simd_distance(positions[q[1]], positions[q[3]])
            let triangles = split ? [(q[0], q[1], q[2]), (q[0], q[2], q[3])] : [(q[0], q[1], q[3]), (q[1], q[2], q[3])]
            for (a, b, c) in triangles {
                let face = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
                let outward = simd_dot(face, normals[a] + normals[b] + normals[c]) >= 0
                indices += outward ? [UInt32(a), UInt32(b), UInt32(c)] : [UInt32(a), UInt32(c), UInt32(b)]
            }
        }
        for k in 1..<(n.z - 1) {
            for j in 1..<(n.y - 1) {
                for i in 1..<(n.x - 1) {
                    let here = values[index(i, j, k)] < 0
                    if here != (values[index(i + 1, j, k)] < 0) {
                        quad([(i, j - 1, k - 1), (i, j, k - 1), (i, j, k), (i, j - 1, k)])
                    }
                    if here != (values[index(i, j + 1, k)] < 0) {
                        quad([(i - 1, j, k - 1), (i, j, k - 1), (i, j, k), (i - 1, j, k)])
                    }
                    if here != (values[index(i, j, k + 1)] < 0) {
                        quad([(i - 1, j - 1, k), (i, j - 1, k), (i, j, k), (i - 1, j, k)])
                    }
                }
            }
        }

        var descriptor = MeshDescriptor(name: "fudge-icon")
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(normals)
        descriptor.primitives = .triangles(indices)
        return descriptor
    }
}
