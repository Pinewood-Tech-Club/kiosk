import RealityKit
import SwiftUI

/// Checks, once every animation has finished, that the 3D scene shows exactly what the order says.
extension Stage {
    var isSettled: Bool { tweens.isEmpty && morphing.isEmpty && !isDragging && sheet.isSettled && sheetGrab == nil }

    func consistencyIssues(current: IceCreamItem?, items: [IceCreamItem], editingID: UUID?, showsCards: Bool) -> [String] {
        var issues: [String] = []
        func check(_ condition: Bool, _ message: @autoclosure () -> String) {
            if !condition { issues.append(message()) }
        }
        func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tolerance: Float = 1e-4) -> Bool { simd_length(a - b) < tolerance }
        func near(_ a: simd_quatf, _ b: simd_quatf) -> Bool { abs(simd_dot(a.vector, b.vector)) > 0.9999 }

        var models: [ObjectIdentifier: String] = [:]
        let pooled = Set(scoopModelPool.values.flatMap { $0 }.map(ObjectIdentifier.init))

        func checkScoops(_ rig: ItemRig, flavors: [Flavor], label: String) {
            check(rig.scoops.map(\.flavor) == flavors,
                  "\(label): rig shows \(rig.scoops.map(\.flavor.rawValue)) but order has \(flavors.map(\.rawValue))")
            for (index, actor) in rig.scoops.enumerated() {
                let name = "\(label) scoop \(index + 1) (\(actor.flavor.rawValue))"
                let key = placementKey(index: index, count: rig.scoops.count, vessel: rig.vessel)
                check(actor.rig === rig, "\(name): owned by another rig")
                check(actor.root.parent === rig.body, "\(name): not attached to its rig")
                check(actor.state == .landed, "\(name): state \(actor.state)")
                check(actor.motion == nil && actor.relayout == nil, "\(name): still has a motion")
                check(actor.morpher == nil, "\(name): still morphing")
                check(actor.slot == index + 1, "\(name): uses slot \(actor.slot) mesh")
                check(actor.placementKey == key, "\(name): placement \(actor.placementKey), expected \(key)")
                if let assets {
                    let pose = assets.scoopSet(actor.slot).resolve(finalPoseName(rig.vessel, key: key))
                    check(actor.staticPose == pose, "\(name): pose \(actor.staticPose), expected \(pose)")
                    check(actor.model.model?.mesh === assets.scoopSet(actor.slot).staticMesh(pose), "\(name): mesh is not the \(pose) pose")
                }
                let slot = slotLocal(rig.vessel, key: key, height: 0)
                check(near(actor.root.transform.translation, slot.translation) && near(actor.root.transform.rotation, slot.rotation)
                      && near(actor.root.transform.scale, .one), "\(name): not at its slot pose")
                check(actor.model.parent === actor.root, "\(name): model detached")
                check(near(actor.model.transform.translation, .zero) && near(actor.model.transform.scale, .one), "\(name): model offset")
                check(actor.model.isEnabled && actor.root.isEnabled, "\(name): disabled")
                check(!actor.model.components.has(OpacityComponent.self), "\(name): translucent")
                let id = ObjectIdentifier(actor.model)
                if let other = models[id] { issues.append("\(name): shares its model with \(other)") }
                models[id] = name
                check(!pooled.contains(id), "\(name): its model is also in the pool")
            }
        }

        func checkVisible(_ rig: ItemRig, label: String) {
            check(rig.root.parent === root, "\(label): not in the scene")
            check(rig.root.isEnabled && rig.rolled.isEnabled, "\(label): hidden")
            check(rig.motion == nil, "\(label): still moving")
            check(abs(rig.modelScale - 1) < 1e-4, "\(label): model scale \(rig.modelScale)")
        }

        if let current {
            check(selectedVessel == current.vessel, "selected vessel \(selectedVessel.rawValue), order has \(current.vessel.rawValue)")
            if let hero = heroes[current.vessel] {
                checkVisible(hero, label: "hero")
                check(abs(hero.scaleMultiplier - 1) < 1e-4, "hero: scale multiplier \(hero.scaleMultiplier)")
                check(hero.vessel == current.vessel, "hero is a \(hero.vessel.rawValue)")
                check(zip(hero.scoops, scoops).allSatisfy { $0 === $1 } && hero.scoops.count == scoops.count, "hero scoops differ from the stage's list")
                checkScoops(hero, flavors: current.flavors, label: "hero")
                let center = centerPose(hero, yaw: hero.pose.yaw)
                check(near(hero.pose.position, center.position, 1e-3) && abs(hero.pose.scale - center.scale) < 1e-3,
                      "hero: not at its framed center pose")
            } else {
                issues.append("no hero for \(current.vessel.rawValue)")
            }
            for (vessel, rig) in heroes where vessel != current.vessel {
                issues.append("stray \(vessel.rawValue) hero (\(rig.scoops.count) scoops)")
            }
        }

        let trayIDs = tray.map(\.id)
        check(trayIDs == items.map(\.id), "tray order differs from the order's items")
        for entry in tray {
            guard let item = items.first(where: { $0.id == entry.id }) else { continue }
            if entry.id == editingID {
                check(entry.mode == .editing && entry.rig == nil, "editing entry: mode \(entry.mode)")
                continue
            }
            guard let rig = entry.rig else {
                issues.append("tray item \(entry.index): no rig")
                continue
            }
            check(entry.mode == .docked, "tray item \(entry.index): mode \(entry.mode)")
            check(rig.root.parent === root, "tray item \(entry.index): not in the scene")
            check(rig.motion == nil, "tray item \(entry.index): still moving")
            checkScoops(rig, flavors: item.flavors, label: "tray item \(Int(entry.index))")
        }

        let scoopRootsInWorld = root.children.filter { $0.name == ScoopActor.rootName }
        check(scoopRootsInWorld.isEmpty, "\(scoopRootsInWorld.count) scoop(s) left loose in the scene")
        let rigsInScene = root.children.filter { $0.name.hasPrefix("rig-") }.count
        let expectedRigs = vesselIcons.count + heroes.count + tray.filter { $0.rig != nil }.count
        check(rigsInScene == expectedRigs, "\(rigsInScene) rigs in the scene, expected \(expectedRigs)")

        let owned = heroes.values.reduce(0) { $0 + $1.scoops.count } + tray.reduce(0) { $0 + ($1.rig?.scoops.count ?? 0) }
        check(liveScoops.count == owned, "\(liveScoops.count - owned) stray scoop(s) alive")
        for (vessel, rig) in vesselIcons {
            let pose = iconPose(vessel)
            check(near(rig.pose.position, pose.position) && abs(rig.pose.roll - pose.roll) < 1e-4,
                  "\(vessel.rawValue) card icon is out of place")
            check(rig.scoops.isEmpty, "\(vessel.rawValue) card icon holds scoops")
        }
        for vessel in Vessel.allCases {
            check(abs((vesselIconAppear[vessel] ?? 0) - 1) < 1e-4, "\(vessel.rawValue) card icon appear \(vesselIconAppear[vessel] ?? -1)")
        }
        for (flavor, icon) in flavorIcons {
            check(abs(icon.appear - 1) < 1e-4, "\(flavor.rawValue) card icon appear \(icon.appear)")
        }
        if showsCards {
            for vessel in Vessel.allCases {
                let shown = iconShown[.vessel(vessel)] ?? 0
                check(vesselIcons[vessel]?.root.isEnabled == (step == .vessel) && vesselIcons[vessel]?.rolled.isEnabled == true,
                      "\(vessel.rawValue) card icon visibility wrong on \(step)")
                check(abs(shown - (step == .vessel ? 1 : 0)) < 1e-4, "\(vessel.rawValue) card icon shown \(shown) on \(step)")
            }
            for flavor in Flavor.allCases {
                let shown = iconShown[.flavor(flavor)] ?? 0
                check(flavorIcons[flavor]?.holder.isEnabled == (step == .flavors) && flavorIcons[flavor]?.model.parent != nil,
                      "\(flavor.rawValue) card icon visibility wrong on \(step)")
                check(abs(shown - (step == .flavors ? 1 : 0)) < 1e-4, "\(flavor.rawValue) card icon shown \(shown) on \(step)")
            }
        }
        return issues
    }
}

/// The vessel as a solid of revolution about its local Y axis, measured from its mesh: outer and inner wall
/// radius per height, the rim's height per azimuth (the cone's rim is slanted) and the cup's floor slab.
struct VesselProfile: Sendable {
    static let binHeight: Float = 0.0005
    static let sectorCount = 90

    enum Region { case above, cavity, solid, outside }

    let yMin: Float
    let outer: [Float]
    let inner: [Float]
    let top: [Float]
    let topMax: Float
    let radiusMax: Float
    let floorTop: Float
    let floorBottom: Float

    nonisolated init(_ geometry: ContactSolver.VesselGeometry) {
        var samples: [(p: SIMD3<Float>, n: SIMD3<Float>)] = []
        var t = 0
        let tris = geometry.triangles
        while t + 2 < tris.count {
            let a = tris[t], b = tris[t + 1], c = tris[t + 2]
            t += 3
            let cross = simd_cross(b - a, c - a)
            let length = simd_length(cross)
            guard length > 1e-12 else { continue }
            let n = cross / length
            for p in ContactSolver.densify(points: [a, b, c], triangles: [a, b, c], spacing: 0.0006) { samples.append((p, n)) }
        }
        if samples.isEmpty { samples = geometry.points.map { ($0, SIMD3<Float>(0, 1, 0)) } }
        let yMin = samples.map(\.p.y).min() ?? 0
        let yMax = samples.map(\.p.y).max() ?? 0.05
        let bins = Int(((yMax - yMin) / Self.binHeight).rounded(.up)) + 1
        func bin(_ y: Float) -> Int { min(max(Int((y - yMin) / Self.binHeight), 0), bins - 1) }
        func radius(_ p: SIMD3<Float>) -> Float { simd_length(SIMD2(p.x, p.z)) }

        var outer = [Float](repeating: -1, count: bins)
        var radiusMax: Float = 0
        for s in samples {
            let r = radius(s.p)
            outer[bin(s.p.y)] = max(outer[bin(s.p.y)], r)
            radiusMax = max(radiusMax, r)
        }
        // Wall faces pointing at the axis are the inner surface; the winding is checked by which group lies further in.
        var towardSum: Float = 0, towardCount: Float = 0, awaySum: Float = 0, awayCount: Float = 0
        for s in samples {
            let r = radius(s.p)
            guard r > 1e-4 else { continue }
            let facing = (s.n.x * s.p.x + s.n.z * s.p.z) / r
            if facing < -0.3 { towardSum += r; towardCount += 1 }
            if facing > 0.3 { awaySum += r; awayCount += 1 }
        }
        let flipped = towardCount > 0 && awayCount > 0 && towardSum / towardCount > awaySum / awayCount
        var inner = [Float](repeating: .infinity, count: bins)
        var floorTop = -Float.infinity, floorBottom = -Float.infinity
        var top = [Float](repeating: -.infinity, count: Self.sectorCount)
        for s in samples {
            let r = radius(s.p)
            let n = flipped ? -s.n : s.n
            if r > 1e-4, (n.x * s.p.x + n.z * s.p.z) / r < -0.3 { inner[bin(s.p.y)] = min(inner[bin(s.p.y)], r) }
            if r < 0.3 * radiusMax, s.p.y < (yMin + yMax) / 2 {
                if n.y > 0.7 { floorTop = max(floorTop, s.p.y) }
                if n.y < -0.7 { floorBottom = max(floorBottom, s.p.y) }
            }
            if r > 0.3 * radiusMax {
                let sector = Self.sector(s.p.x, s.p.z)
                top[sector] = max(top[sector], s.p.y)
            }
        }
        func fill(_ values: inout [Float], missing: (Float) -> Bool) {
            guard let first = values.firstIndex(where: { !missing($0) }) else { return }
            var last = first
            for i in 0..<values.count {
                if missing(values[i]) { values[i] = values[last] } else { last = i }
            }
            for i in 0..<first { values[i] = values[first] }
        }
        fill(&outer) { $0 < 0 }
        for i in 0..<bins where !inner[i].isFinite || inner[i] > outer[i] { inner[i] = outer[i] }
        fill(&top) { !$0.isFinite }
        self.yMin = yMin
        self.outer = outer
        self.inner = inner
        self.top = top
        self.topMax = top.max() ?? yMax
        self.radiusMax = radiusMax
        if floorTop.isFinite, floorBottom.isFinite, floorBottom < floorTop {
            self.floorTop = floorTop
            self.floorBottom = floorBottom
        } else {
            self.floorTop = yMin
            self.floorBottom = yMin
        }
    }

    nonisolated static func sector(_ x: Float, _ z: Float) -> Int {
        let angle = atan2(z, x) + .pi
        return min(Int(angle / (2 * .pi) * Float(sectorCount)), sectorCount - 1)
    }

    nonisolated func rim(_ x: Float, _ z: Float) -> Float { top[Self.sector(x, z)] }

    /// Region of a point in the vessel's frame and how far it is from the nearest boundary of that region
    /// (in the r–y plane), so a point just across a wall counts for little.
    nonisolated func classify(_ p: SIMD3<Float>) -> (Region, Float) {
        let rim = self.rim(p.x, p.z)
        if p.y >= rim { return (.above, p.y - rim) }
        if p.y < yMin { return (.outside, yMin - p.y) }
        let b = min(max(Int((p.y - yMin) / Self.binHeight), 0), outer.count - 1)
        let r = simd_length(SIMD2(p.x, p.z))
        let ro = outer[b], ri = inner[b]
        if r > ro { return (.outside, min(r - ro, rim - p.y)) }
        if p.y < floorBottom {
            return r < ri ? (.outside, min(floorBottom - p.y, ri - r)) : (.solid, min(r - ri, ro - r))
        }
        if p.y <= floorTop {
            return (.solid, r < ri ? min(floorTop - p.y, p.y - floorBottom) : min(ro - r, max(floorTop - p.y, r - ri)))
        }
        if r < ri { return (.cavity, min(ri - r, rim - p.y, p.y - floorTop)) }
        return (.solid, min(r - ri, ro - r, rim - p.y))
    }

    var summary: String {
        let rimLow = top.min() ?? 0
        let mid = outer.count / 2
        return String(format: "rim %.1f-%.1f mm, outer r max %.1f, mid-height r %.1f/%.1f (in/out), floor %.1f-%.1f",
                      rimLow * 1000, topMax * 1000, radiusMax * 1000, inner[mid] * 1000, outer[mid] * 1000,
                      floorBottom * 1000, floorTop * 1000)
    }
}

/// Per-frame check that no scoop's mesh crosses a vessel's wall: every frame, each scoop's current (morphed)
/// shape is sampled and tested against every vessel in the scene. A solid scoop that has parts both inside the
/// cavity and outside the wall below the rim must contain a piece of the wall, which is a visible intersection.
@MainActor
final class ClipCheck {
    static let vertexStride = 16
    static let tolerance: Float = 0.0005
    /// Deeper than this (about 6 pt at the hero's scale) a clip fails a stress round; shallower ones are logged as grazes.
    static let visibleDepth: Float = 0.0015

    struct Issue {
        let text: String
        let depth: Float
        var isVisible: Bool { depth > ClipCheck.visibleDepth }
    }

    struct Measure {
        var cavity: Float = 0
        var outside: Float = 0
        var solid: Float = 0
        var belowRim: Float = 0
        /// The scoop's base in the vessel's frame (distance from the axis, height) and its size relative to the vessel.
        var base = SIMD3<Float>.zero
        var severity: Float { max(min(cavity, outside), solid) }
    }

    private struct Episode {
        let label: String
        var frames = 0
        var worst = Measure()
        var phases: [String] = []
        let started: Double
    }

    let profiles: [Vessel: VesselProfile]
    private let shapes: [[[SIMD3<Float>]]]
    private let meshes: [ScoopMeshData]
    private var morphFrom: [ObjectIdentifier: [SIMD3<Float>]] = [:]
    private var open: [String: Episode] = [:]
    private var unreported: [Issue] = []
    private(set) var frames = 0
    private(set) var pairs = 0
    private(set) var episodes = 0
    private var worst: Float = 0
    private var closestGraze: Float = 0
    private var closestGrazeLabel = ""
    let log: (String) -> Void

    init(profiles: [Vessel: VesselProfile], meshes: [ScoopMeshData], log: @escaping (String) -> Void) {
        self.profiles = profiles
        self.meshes = meshes
        self.log = log
        shapes = meshes.map { mesh in mesh.poseNames.map { mesh.positions($0, stride: Self.vertexStride) } }
    }

    func shape(slot: Int, pose: String) -> [SIMD3<Float>] {
        shapes[slot - 1][meshes[slot - 1].poseIndex(pose)]
    }

    private func currentShape(_ actor: ScoopActor) -> [SIMD3<Float>] {
        let target = shape(slot: actor.slot, pose: actor.morpher != nil ? actor.morphTo : actor.staticPose)
        guard actor.morpher != nil, let from = morphFrom[ObjectIdentifier(actor)], from.count == target.count else { return target }
        let w = actor.morphWeight
        return zip(from, target).map { $0 + ($1 - $0) * w }
    }

    func willBeginMorph(_ actor: ScoopActor) {
        morphFrom[ObjectIdentifier(actor)] = currentShape(actor)
    }

    func forget(_ actor: ScoopActor) {
        morphFrom[ObjectIdentifier(actor)] = nil
    }

    nonisolated static func measure(_ points: [SIMD3<Float>], _ m: simd_float4x4, _ profile: VesselProfile) -> Measure {
        var result = Measure()
        for v in points {
            let w = m * SIMD4<Float>(v, 1)
            let p = SIMD3<Float>(w.x, w.y, w.z)
            let (region, depth) = profile.classify(p)
            switch region {
            case .above: break
            case .cavity: result.cavity = max(result.cavity, depth)
            case .solid: result.solid = max(result.solid, depth)
            case .outside:
                if depth > result.outside { result.outside = depth }
                result.belowRim = max(result.belowRim, profile.rim(p.x, p.z) - p.y)
            }
        }
        return result
    }

    /// How each placed pose sits against its vessel, for calibrating the check against the assets.
    func baseline(placements: Placements, poseName: (Vessel, String) -> String) -> String {
        var parts: [String] = []
        for vessel in Vessel.allCases {
            guard let profile = profiles[vessel] else { continue }
            for key in vessel == .cup ? ["solo", "1", "2", "3"] : ["1", "2", "3"] {
                let slot = key == "solo" ? 1 : Int(key)!
                let m = placements.placement(vessel, key: key).transform.matrix
                let r = Self.measure(shape(slot: slot, pose: poseName(vessel, key)), m, profile)
                parts.append(String(format: "%@:%@ %@ (in %.1f out %.1f solid %.1f)", vessel.rawValue, key,
                                    r.severity > Self.tolerance ? "CLIPS" : "clear", r.cavity * 1000, r.outside * 1000, r.solid * 1000))
            }
        }
        return "Clip baseline (placed poses): " + parts.joined(separator: ", ")
    }

    func run(_ stage: Stage) {
        frames += 1
        var rigs: [(vessel: Vessel, root: Entity, body: Entity, label: String)] = []
        var labels: [ObjectIdentifier: String] = [:]
        for (vessel, rig) in stage.heroes { labels[ObjectIdentifier(rig.root)] = vessel == stage.selectedVessel ? "hero" : "outgoing hero" }
        for entry in stage.tray { if let rig = entry.rig { labels[ObjectIdentifier(rig.root)] = "tray \(Int(entry.index.rounded()))" } }
        for rig in stage.vesselIcons.values { labels[ObjectIdentifier(rig.root)] = "card icon" }
        for child in stage.root.children where child.name.hasPrefix("rig-") && child.isEnabled {
            guard let vessel = Vessel(rawValue: String(child.name.dropFirst(4))),
                  let rolled = child.children.first?.children.first, rolled.isEnabled,
                  let body = rolled.children.first?.children.first else { continue }
            rigs.append((vessel, child, body, labels[ObjectIdentifier(child)] ?? "leaving"))
        }
        var seen = Set<String>()
        for actor in stage.liveScoops.values where actor.model.isEnabledInHierarchy && actor.root.parent != nil {
            let scoopWorld = actor.model.transformMatrix(relativeTo: nil)
            var shape: [SIMD3<Float>]?
            for rig in rigs {
                guard let profile = profiles[rig.vessel] else { continue }
                let bodyWorld = rig.body.transformMatrix(relativeTo: nil)
                guard simd_length(SIMD3(bodyWorld.columns.0.x, bodyWorld.columns.0.y, bodyWorld.columns.0.z)) > 1e-3 else { continue }
                let m = simd_inverse(bodyWorld) * scoopWorld
                let scale = simd_length(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z))
                let c4 = m * SIMD4<Float>(0, 0.022, 0, 1)
                let reach = 0.04 * scale
                guard simd_length(SIMD2(c4.x, c4.z)) - reach < profile.radiusMax, c4.y - reach < profile.topMax,
                      c4.y + reach > profile.yMin else { continue }
                if shape == nil { shape = currentShape(actor) }
                pairs += 1
                var result = Self.measure(shape!, m, profile)
                result.base = [simd_length(SIMD2(m.columns.3.x, m.columns.3.z)), m.columns.3.y, scale]
                guard result.severity > Self.tolerance else {
                    if result.severity > closestGraze {
                        closestGraze = result.severity
                        closestGrazeLabel = "\(actor.flavor.rawValue) slot \(actor.slot) vs \(rig.vessel.rawValue) \(rig.label) during \(actor.phase)"
                    }
                    continue
                }
                let key = "\(ObjectIdentifier(actor).hashValue)-\(ObjectIdentifier(rig.root).hashValue)"
                seen.insert(key)
                var episode = open[key] ?? Episode(
                    label: "\(actor.flavor.rawValue) slot \(actor.slot) vs \(rig.vessel.rawValue) \(rig.label)\(actor.rig.map { ObjectIdentifier($0.root) == ObjectIdentifier(rig.root) } == true ? " (own)" : "")",
                    started: stage.now)
                episode.frames += 1
                if result.severity > episode.worst.severity { episode.worst = result }
                if episode.phases.last != actor.phase { episode.phases.append(actor.phase) }
                open[key] = episode
            }
        }
        for (key, episode) in open where !seen.contains(key) {
            open[key] = nil
            close(episode)
        }
    }

    private func close(_ episode: Episode) {
        episodes += 1
        worst = max(worst, episode.worst.severity)
        let line = String(format: "%@ during %@: %d frames, %.1f mm deep (inside %.1f, outside %.1f, in wall %.1f; reaches %.1f mm below the rim; base r %.1f y %.1f, size ×%.2f) at t=%.2f",
                          episode.label, episode.phases.joined(separator: "→"), episode.frames, episode.worst.severity * 1000,
                          episode.worst.cavity * 1000, episode.worst.outside * 1000, episode.worst.solid * 1000,
                          episode.worst.belowRim * 1000, episode.worst.base.x * 1000, episode.worst.base.y * 1000,
                          episode.worst.base.z, episode.started)
        unreported.append(Issue(text: "clip: " + line, depth: episode.worst.severity))
        log("Clip: " + line)
    }

    /// Violations finished since the last call (episodes still in progress are closed first).
    func takeIssues() -> [Issue] {
        for episode in open.values { close(episode) }
        open.removeAll()
        defer { unreported.removeAll() }
        return unreported
    }

    var summary: String {
        String(format: "Clip check: %d frames, %d scoop-vessel tests, %d violations (worst %.1f mm), deepest sub-threshold contact %.2f mm (%@)",
               frames, pairs, episodes, worst * 1000, closestGraze * 1000, closestGrazeLabel)
    }
}
