import RealityKit
import SwiftUI

extension Stage {
    /// Top of the item (vessel plus placed scoops) and its widest horizontal radius, in the vessel's frame.
    func itemMetrics(_ item: IceCreamItem, rig: ItemRig? = nil) -> (top: Float, radius: Float) {
        guard let assets else { return (0.1, 0.045) }
        var top = assets.vesselTop(item.vessel)
        var radius = assets.vesselHalfWidth(item.vessel)
        for index in item.flavors.indices {
            let key = placementKey(index: index, count: item.flavors.count, vessel: item.vessel)
            let placement = assets.placements.placement(item.vessel, key: key)
            let bounds = assets.scoopSet(index + 1).poseBounds(finalPoseName(item.vessel, key: key))
            top = max(top, placement.translation.y + bounds.max.y)
            let reach = max(abs(bounds.min.x), abs(bounds.max.x), abs(bounds.min.z), abs(bounds.max.z))
            radius = max(radius, simd_length(SIMD2(placement.translation.x, placement.translation.z)) + reach)
        }
        if let toppings = rig?.toppings?.top { top = max(top, toppings) }
        return (top, radius)
    }

    /// Scale and vertical offset that fit the whole item (scoops included) into `box` when viewed at `pitch`,
    /// centered on the box: every item gets the same visual footprint whatever it holds.
    func fitted(_ entry: TrayEntry, box: CGSize, pitch: Float, centerY: CGFloat, centerX: CGFloat,
                z: Float = 0) -> (position: SIMD3<Float>, scale: Float) {
        let height = entry.contentTop * cos(pitch) + 2 * entry.contentRadius * sin(pitch)
        let width = 2 * entry.contentRadius
        let depthScale = (cameraDistance - z) / cameraDistance
        let scale = min(Float(box.height) * 0.001 / height, Float(box.width) * 0.001 / width) * depthScale
        var position = world(CGPoint(x: centerX, y: centerY), z: z)
        // Projected bounds run from the base's front edge up to the top's back edge; centre that span.
        let pivotY = entry.rig?.pivot.y ?? entry.contentTop / 2
        let lowest = -pivotY * cos(pitch) - entry.contentRadius * sin(pitch)
        let highest = (entry.contentTop - pivotY) * cos(pitch) + entry.contentRadius * sin(pitch)
        position.y -= (lowest + highest) / 2 * scale
        return (position, scale)
    }

    var maxTrayScroll: CGFloat {
        CGFloat(max(0, tray.count - Layout.trayVisibleSlots)) * Layout.trayPitch
    }

    func snappedTrayScroll(_ value: CGFloat) -> CGFloat {
        min(max((value / Layout.trayPitch).rounded() * Layout.trayPitch, 0), maxTrayScroll)
    }

    /// Smallest snapped scroll that shows slot `index` completely.
    func trayScroll(showing index: Int) -> CGFloat {
        let slot = CGFloat(index) * Layout.trayPitch
        let lowest = slot - CGFloat(Layout.trayVisibleSlots - 1) * Layout.trayPitch
        return min(max(trayScroll, lowest), slot, maxTrayScroll)
    }

    func trayCenterX(_ entry: TrayEntry) -> CGFloat {
        Layout.trayFirstCenterX + CGFloat(entry.index) * Layout.trayPitch - trayScroll
    }

    /// Where a docked item sits for the sheet's current progress, and how far it's shown (scrolled out of
    /// the tray or the order's list, it isn't).
    func dockedPose(_ entry: TrayEntry) -> (pose: RigPose, edge: Float) {
        let geometry = SheetGeometry(progress: CGFloat(sheet.value))
        let t = Float(geometry.t)
        let area = Layout.trayItemsRect
        let reach = Layout.trayPitch / 2
        let trayX = trayCenterX(entry)
        let inTray = trayX > area.minX - reach && trayX < area.maxX + reach
        // One scrolled out of the tray rises from the nearest visible slot instead, growing in as it goes.
        let startX = inTray ? trayX : min(max(trayX, area.minX + reach), area.maxX - reach)
        let rowY = Layout.summaryRowCenterY(CGFloat(entry.index)) - summaryScroll
        let center = geometry.itemCenter(trayX: startX, rowY: rowY)
        let pitch = lerp(0.3, 0.42, Float(geometry.itemSettle))
        let fit = fitted(entry, box: geometry.itemBox(), pitch: pitch, centerY: center.y, centerX: center.x, z: Self.itemPlaneZ)
        let yaw = Self.trayYaw + lerp(entry.spinAnchor, entry.spin, t)
        let w = Ease.clamp01(t / 0.3)
        let edge = lerp(inTray ? 1 : 0, summaryEdge(rowY), w * w * (3 - 2 * w))
        return (RigPose(position: fit.position, scale: fit.scale, pitch: pitch, yaw: yaw), edge)
    }

    private func advanceSpin(_ entry: TrayEntry, dt: Float, t: Float) {
        let turn = 2 * Float.pi
        entry.spinVelocity += ((summaryActive ? 0.32 : 0) - entry.spinVelocity) * (1 - exp(-dt / 0.9))
        entry.spin += entry.spinVelocity * dt
        // Only re-anchored while fully open, where the anchor's weight (1 - t) makes the change invisible.
        // Landing a quarter turn or more ahead keeps the way back into the tray a forward turn.
        if t >= 0.999 { entry.spinAnchor = ((entry.spin + turn / 4) / turn).rounded(.up) * turn }
        if entry.spinAnchor > 60 * turn {
            entry.spin -= 50 * turn
            entry.spinAnchor -= 50 * turn
        }
    }


    private func clipEdge(_ y: CGFloat, _ clip: CGRect, zone: CGFloat) -> Float {
        guard clip.height > 0 else { return 1 }
        let top = (y - clip.minY) / zone + 0.5
        let bottom = (clip.maxY - y) / zone + 0.5
        let t = Float(min(max(min(top, bottom), 0), 1))
        return t * t * (3 - 2 * t)
    }

    private func summaryEdge(_ y: CGFloat) -> Float {
        let zone: CGFloat = 70
        let top = (y - Layout.summaryListRect.minY) / zone
        let bottom = (Layout.summaryListRect.maxY - y) / zone
        let t = Float(min(max(min(top, bottom), 0), 1))
        return t * t * (3 - 2 * t)
    }

    func updateTray(dt: Float) {
        publishTrayTiles()
        let t = Float(SheetGeometry(progress: CGFloat(sheet.value)).t)
        for entry in tray {
            guard let rig = entry.rig else { continue }
            let edge: Float
            switch entry.mode {
            case .docked:
                advanceSpin(entry, dt: dt, t: t)
                let docked = dockedPose(entry)
                rig.pose = docked.pose
                edge = docked.edge
            case .receipt:
                entry.spinYaw += 0.32 * dt
                if entry.spinYaw > 200 { entry.spinYaw -= 2 * .pi * 30 }
                guard let frame = receiptFrames[entry.id] else {
                    rig.root.isEnabled = false
                    entry.lastEdge = 0
                    continue
                }
                let pitch: Float = 0.42
                let fit = fitted(entry, box: CGSize(width: frame.width * 0.9, height: frame.height * 0.9), pitch: pitch,
                                 centerY: frame.midY, centerX: frame.midX)
                rig.pose = RigPose(position: fit.position, scale: fit.scale, pitch: pitch, yaw: entry.spinYaw)
                edge = clipEdge(frame.midY, receiptClip, zone: frame.height * 0.6) * entry.appear
            case .flying, .editing, .removing:
                continue
            }
            rig.scaleMultiplier = edge
            rig.apply()
            if abs(edge - entry.lastEdge) > 0.002 {
                entry.lastEdge = edge
                rig.root.isEnabled = edge > 0.01
            }
        }
    }

    private func publishTrayTiles() {
        var tiles: [TrayTileModel.Tile] = []
        var editing: TrayTileModel.Tile?
        for entry in tray {
            let tile = TrayTileModel.Tile(id: entry.id, x: trayCenterX(entry))
            switch entry.mode {
            case .docked, .flying: tiles.append(tile)
            case .editing: editing = tile
            case .receipt, .removing: break
            }
        }
        trayTiles.update(tiles, editing: editing)
    }

    func animateTrayScroll(to target: CGFloat, duration: Double = 0.5) {
        trayScrollTween?.cancel()
        let from = trayScroll
        guard abs(from - target) > 0.5 else {
            trayScroll = target
            return
        }
        trayScrollTween = animate(duration: duration) { [unowned self] p in
            trayScroll = from + (target - from) * CGFloat(Ease.outCubic(p))
        }
    }

    /// Flies an entry's rig home, growing it fully in on the way. Home is its tray slot or its order row,
    /// wherever the sheet is right then, so it lands on the sheet even while that moves.
    private func flyEntry(_ entry: TrayEntry, duration: Double = 0.9) {
        guard let rig = entry.rig else { return }
        entry.mode = .flying
        entry.lastEdge = -1
        entry.spin = 0
        entry.spinAnchor = 0
        entry.spinVelocity = 0
        rig.root.isEnabled = true
        replane(rig, z: Self.itemPlaneZ)
        if rig.scaleMultiplier < 1 {
            rig.appearTween?.cancel()
            var from: Float = 0
            rig.appearTween = animate(duration: 0.3, onStart: { from = rig.scaleMultiplier }) { p in
                rig.scaleMultiplier = lerp(from, 1, TimingCurve.standard(p))
            }
        }
        let toSheet = summaryActive
        let side: Float = toSheet ? 0 : -0.12
        flyRig(rig, duration: duration, minSpin: 1.5 * .pi, dip: false, timing: toSheet ? .flight : .swoop,
               liveControl: toSheet,
               control: { p0, p1 in
                   SIMD3<Float>(lerp(p0.x, p1.x, 0.3) + side, lerp(p0.y, p1.y, 0.5), max(p0.z, p1.z) + 0.12)
               },
               target: { [unowned self] in dockedPose(entry).pose }) {
            entry.mode = .docked
            entry.spinAnchor = rig.pose.yaw - Self.trayYaw
            entry.spin = entry.spinAnchor
            entry.spinVelocity = 0
        }
    }

    /// Moves a rig to depth `z` without changing what's on screen: same projected pivot, compensated scale.
    func replane(_ rig: ItemRig, z: Float) {
        rig.pose = replaned(rig.pose, z: z)
        rig.apply()
    }

    func replaned(_ pose: RigPose, z: Float) -> RigPose {
        var pose = pose
        guard abs(pose.position.z - z) > 1e-5 else { return pose }
        pose.scale *= (cameraDistance - z) / (cameraDistance - pose.position.z)
        pose.position = world(screen(pose.position), z: z)
        return pose
    }

    func sendCurrentToTray(_ item: IceCreamItem) {
        guard let hero = heroes[selectedVessel] else { return }
        heroes[selectedVessel] = nil
        isDragging = false
        scoops.removeAll()
        let entry = TrayEntry(item: item, rig: hero, index: Float(tray.count), metrics: itemMetrics(item, rig: hero))
        tray.append(entry)
        if !summaryActive { animateTrayScroll(to: maxTrayScroll, duration: 0.4) }
        flyEntry(entry, duration: summaryActive ? 0.75 : 1.05)
    }

    func returnHeroToEntry(_ id: UUID, item: IceCreamItem) {
        guard let entry = tray.first(where: { $0.id == id }), let hero = heroes[selectedVessel] else { return }
        heroes[selectedVessel] = nil
        isDragging = false
        scoops.removeAll()
        entry.item = item
        entry.rig = hero
        entry.setMetrics(itemMetrics(item, rig: hero))
        if !summaryActive {
            animateTrayScroll(to: trayScroll(showing: Int(entry.index.rounded())), duration: 0.6)
        }
        flyEntry(entry, duration: summaryActive ? 0.75 : 1.0)
    }

    /// Moves a finished item out of the tray (or summary) to the center so it can be edited.
    func beginEditing(_ id: UUID) {
        guard let entry = tray.first(where: { $0.id == id }), let rig = entry.rig else { return }
        entry.rig = nil
        entry.mode = .editing
        rig.opacityTween?.cancel()
        rig.setOpacity(1)
        selectedVessel = rig.vessel
        heroes[rig.vessel] = rig
        scoops = rig.scoops
        rig.framing = nil
        reframe(rig, animated: false)
        rig.appearTween?.cancel()
        rig.root.isEnabled = true
        if rig.scaleMultiplier < 1 {
            var from: Float = 0
            rig.appearTween = animate(duration: 0.3, onStart: { from = rig.scaleMultiplier }) { p in
                rig.scaleMultiplier = lerp(from, 1, TimingCurve.standard(p))
            }
        }
        flyHeroToCenter(rig, duration: 0.95, inFront: true)
        if !summaryActive {
            animateTrayScroll(to: trayScroll(showing: Int(entry.index.rounded())), duration: 0.5)
        }
    }

    func removeTrayItem(_ id: UUID) {
        guard let index = tray.firstIndex(where: { $0.id == id }) else { return }
        let entry = tray.remove(at: index)
        entry.mode = .removing
        if let rig = entry.rig { dismiss(rig) }
        for (newIndex, other) in tray.enumerated() where other.index != Float(newIndex) {
            other.indexTween?.cancel()
            let from = other.index
            let to = Float(newIndex)
            other.indexTween = animate(delay: 0.08, duration: 0.35) { p in
                other.index = lerp(from, to, TimingCurve.swiftUIEaseInOut(p))
            }
        }
        animateTrayScroll(to: snappedTrayScroll(min(trayScroll, maxTrayScroll)), duration: 0.45)
    }

    /// Moves the order's items onto the confirmation receipt: the builder is gone (the screen is covered
    /// while this happens), and each item grows into its receipt row as the receipt prints.
    func enterReceipt() {
        for rig in heroes.values { discard(rig) }
        heroes.removeAll()
        for scoop in scoops { discard(scoop) }
        scoops.removeAll()
        isDragging = false
        snapSheet(open: false)
        setControlsVisible(false, animated: false)
        receiptFrames = [:]
        for (i, entry) in tray.enumerated() {
            guard let rig = entry.rig else { continue }
            rig.cancelMotions()
            rig.setOpacity(1)
            entry.spinYaw = rig.pose.yaw
            entry.mode = .receipt
            entry.lastEdge = -1
            entry.appear = 0
            entry.appearTween?.cancel()
            entry.appearTween = animate(delay: 0.55 + 0.14 * Double(i), duration: 0.45) { p in
                entry.appear = TimingCurve.standard(p)
            }
        }
    }

    func setReceiptFrame(_ id: UUID, _ frame: CGRect) {
        receiptFrames[id] = frame
    }

    static let trayYaw: Float = -0.55
    /// Docked items ride the sheet in front of the occluder; the builder's models stay well behind it.
    static let itemPlaneZ: Float = 0.6
    static let occluderZ: Float = 0.42
    static let sheetOpenResponse: Float = 0.6
    static let sheetOpenDamping: Float = 0.9

    /// The tray's glass grows into the order sheet. Docked items ride along from their slots to their rows,
    /// turning half a turn on the way.
    func openSheet() {
        if sheet.value <= 0.001 {
            summaryScroll = 0
            for entry in tray where entry.mode == .docked {
                entry.spin = entry.spinAnchor + .pi
                entry.spinVelocity = 0
            }
        }
        settleSheet(open: true, velocity: nil)
    }

    /// Springs the sheet open or closed from wherever it is; `velocity` is in progress per second.
    func settleSheet(open: Bool, velocity: Float?) {
        summaryActive = open
        sheetGrab = nil
        sheet.response = open ? Self.sheetOpenResponse : 0.55
        sheet.dampingRatio = open ? Self.sheetOpenDamping : 1
        sheet.target = open ? 1 : 0
        if let velocity { sheet.velocity = velocity }
    }

    /// Follows a pull-down, `offset` points below where it was grabbed. Above the open position the sheet
    /// resists; below the tray it waits there until the finger comes back up.
    func dragSheet(by offset: CGFloat) {
        guard offset.isFinite else { return }
        let grab = sheetGrab ?? sheet.value
        sheetGrab = grab
        let value = Float(sheetProgress(grabbedAt: grab, offset: offset))
        sheet.value = value
        sheet.target = value
        sheet.velocity = 0
    }

    func sheetProgress(grabbedAt grab: Float, offset: CGFloat) -> CGFloat {
        let travel = SheetGeometry.travel
        let raw = CGFloat(grab) - offset / travel
        guard raw > 1 else { return max(raw, 0) }
        let excess = (raw - 1) * travel
        return 1 + 24 * (1 - 1 / (excess / 60 + 1)) / travel
    }

    func snapSheet(open: Bool) {
        summaryActive = open
        sheetGrab = nil
        sheet.value = open ? 1 : 0
        sheet.target = sheet.value
        sheet.velocity = 0
        sheetCovered = open
        sheetModel.update(CGFloat(sheet.value))
        placeOccluder()
    }

    func stepSheet(_ dt: Float) {
        sheet.step(dt)
        let range = SheetGeometry.progressRange
        if sheet.value < Float(range.lowerBound) {
            sheet.value = Float(range.lowerBound)
            sheet.velocity = max(sheet.velocity, 0)
        } else if sheet.value > Float(range.upperBound) {
            sheet.value = Float(range.upperBound)
            sheet.velocity = min(sheet.velocity, 0)
        }
        let covered = summaryActive && sheet.value >= 0.995
        if covered != sheetCovered {
            sheetCovered = covered
            if covered { onSheetCovered() }
        }
        sheetModel.update(CGFloat(sheet.value))
        placeOccluder()
    }

    private func placeOccluder() {
        guard let occluder = sheetOccluder else { return }
        occluder.root.isEnabled = sheet.value > 0.0005
        guard occluder.root.isEnabled else { return }
        let geometry = SheetGeometry(progress: CGFloat(sheet.value))
        let rect = geometry.rect
        let r = geometry.cornerRadius
        let z = Self.occluderZ
        let k = 0.001 * (cameraDistance - z) / cameraDistance
        func place(_ part: Entity, _ frame: CGRect) {
            part.position = world(CGPoint(x: frame.midX, y: frame.midY), z: z)
            part.scale = [max(Float(frame.width) * k, 1e-5), max(Float(frame.height) * k, 1e-5), 1]
        }
        place(occluder.bars[0], rect.insetBy(dx: r, dy: 0))
        place(occluder.bars[1], rect.insetBy(dx: 0, dy: r))
        for (i, corner) in occluder.corners.enumerated() {
            let x = i % 2 == 0 ? rect.minX + r : rect.maxX - r
            let y = i < 2 ? rect.minY + r : rect.maxY - r
            place(corner, CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
        }
    }

    /// Replaces the builder with a fresh cup while the sheet covers it, so the builder is already complete
    /// whenever the sheet folds away.
    func resetBuilderUnderSheet(vessel: Vessel) {
        for rig in heroes.values { discard(rig) }
        heroes.removeAll()
        for scoop in scoops { discard(scoop) }
        scoops.removeAll()
        isDragging = false
        for vessel in Vessel.allCases { setVesselIconAppear(vessel, to: 1, duration: 0) }
        for flavor in Flavor.allCases { setFlavorIconAppear(flavor, to: 1, duration: 0) }
        controlsVisible = true
        setStep(.vessel, animated: false)
        placeFreshHero(vessel)
        updateIcons()
    }

    private func placeFreshHero(_ vessel: Vessel) {
        selectedVessel = vessel
        let rig = makeRig(vessel)
        reframe(rig, animated: false)
        rig.pose = centerPose(rig, yaw: 0.4)
        rig.apply()
        heroes[vessel] = rig
        scoops = rig.scoops
        root.addChild(rig.root)
        releaseTime = now - 2
        yawVelocity = Self.baseSpin
        pitchReturnDuration = 0
    }

    func trayDragChanged(_ dx: CGFloat) {
        if trayDragStart == nil {
            trayDragStart = trayScroll
            trayScrollTween?.cancel()
        }
        let raw = (trayDragStart ?? 0) - dx
        let limit = maxTrayScroll
        if raw < 0 {
            trayScroll = -rubberBand(-raw)
        } else if raw > limit {
            trayScroll = limit + rubberBand(raw - limit)
        } else {
            trayScroll = raw
        }
    }

    func trayDragEnded(predictedDx: CGFloat) {
        let target = snappedTrayScroll((trayDragStart ?? trayScroll) - predictedDx)
        trayDragStart = nil
        animateTrayScroll(to: target, duration: 0.5)
    }

    private func rubberBand(_ x: CGFloat) -> CGFloat { 60 * (1 - 1 / (x / 120 + 1)) }

    func trayItem(at point: CGPoint) -> UUID? {
        guard Layout.trayItemsRect.contains(point) else { return nil }
        for entry in tray where entry.mode != .removing {
            let x = trayCenterX(entry)
            if abs(point.x - x) < Layout.trayPitch / 2, x > Layout.trayItemsRect.minX, x < Layout.trayItemsRect.maxX { return entry.id }
        }
        return nil
    }

    func trayItemCenter(_ id: UUID) -> CGPoint? {
        guard let entry = tray.first(where: { $0.id == id }) else { return nil }
        return CGPoint(x: trayCenterX(entry), y: Layout.trayCenterY)
    }

    func reset() {
        for tween in tweens { tween.cancel() }
        tweens.removeAll()
        for rig in heroes.values { discard(rig) }
        heroes.removeAll()
        for scoop in scoops { discard(scoop) }
        scoops.removeAll()
        for entry in tray {
            if let rig = entry.rig { discard(rig) }
        }
        tray.removeAll()
        trayScroll = 0
        trayDragStart = nil
        summaryScroll = 0
        snapSheet(open: false)
        receiptFrames = [:]
        receiptClip = .zero
        isDragging = false
        selectedVessel = .cup
        for index in pressSprings.indices {
            pressSprings[index].value = 0
            pressSprings[index].target = 0
            pressSprings[index].velocity = 0
        }
        for vessel in Vessel.allCases {
            vesselIconAppear[vessel] = 1
            vesselIconAppearTweens[vessel] = nil
        }
        for icon in flavorIcons.values {
            icon.appear = 1
            icon.appearTween = nil
        }
        for actor in Array(liveScoops.values) { discard(actor) }
        removeDetachedToppings()
        for icon in toppingIcons.values { icon.reset() }
        controlsVisible = true
        setStep(.vessel, animated: false)
        updateIcons()
    }

    func restore(current: IceCreamItem?, items: [IceCreamItem], step: BuilderStep, summary: Bool = false) {
        reset()
        for item in items {
            let rig = makeItemRig(item)
            let entry = TrayEntry(item: item, rig: rig, index: Float(tray.count), metrics: itemMetrics(item, rig: rig))
            entry.mode = .docked
            tray.append(entry)
            root.addChild(rig.root)
        }
        trayScroll = maxTrayScroll
        snapSheet(open: summary)
        if let current {
            selectedVessel = current.vessel
            let rig = makeItemRig(current)
            reframe(rig, animated: false)
            rig.pose = centerPose(rig, yaw: 0.4)
            rig.apply()
            heroes[current.vessel] = rig
            scoops = rig.scoops
            root.addChild(rig.root)
            releaseTime = now - 2
            yawVelocity = Self.baseSpin
        }
        controlsVisible = true
        setStep(step, animated: false)
        updateTray(dt: 0)
        updateIcons()
    }

    func makeItemRig(_ item: IceCreamItem) -> ItemRig {
        let rig = makeRig(item.vessel)
        for (index, flavor) in item.flavors.enumerated() {
            let slot = index + 1
            let key = placementKey(index: index, count: item.flavors.count, vessel: item.vessel)
            let pose = assets!.scoopSet(slot).resolve(finalPoseName(item.vessel, key: key))
            let actor = ScoopActor(flavor: flavor, slot: slot, model: makeScoopModel(slot: slot, flavor: flavor, pose: pose), pose: pose)
            liveScoops[ObjectIdentifier(actor)] = actor
            actor.rig = rig
            actor.mount = rig
            actor.placementKey = key
            actor.state = .landed
            actor.phase = "landed"
            actor.root.transform = slotLocal(item.vessel, key: key, height: 0)
            rig.scoops.append(actor)
            rig.body.addChild(actor.root)
        }
        applyToppings(item, to: rig)
        return rig
    }
}
