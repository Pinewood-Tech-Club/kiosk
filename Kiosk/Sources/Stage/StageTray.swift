import RealityKit
import SwiftUI

extension Stage {
    /// Top of the item (vessel plus placed scoops) and its widest horizontal radius, in the vessel's frame.
    func itemMetrics(_ item: IceCreamItem) -> (top: Float, radius: Float) {
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
        return (top, radius)
    }

    /// Scale and vertical offset that fit the whole item (scoops included) into `box` when viewed at `pitch`,
    /// centered on the box: every item gets the same visual footprint whatever it holds.
    func fitted(_ entry: TrayEntry, box: CGSize, pitch: Float, centerY: CGFloat, centerX: CGFloat) -> (position: SIMD3<Float>, scale: Float) {
        let height = entry.contentTop * cos(pitch) + 2 * entry.contentRadius * sin(pitch)
        let width = 2 * entry.contentRadius
        let scale = min(Float(box.height) * 0.001 / height, Float(box.width) * 0.001 / width)
        var position = world(CGPoint(x: centerX, y: centerY))
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

    func trayPose(_ entry: TrayEntry) -> RigPose {
        let pitch: Float = 0.3
        let fit = fitted(entry, box: Layout.trayMiniBox, pitch: pitch, centerY: Layout.trayCenterY, centerX: trayCenterX(entry))
        return RigPose(position: fit.position, scale: fit.scale, pitch: pitch, yaw: -0.55)
    }

    func summaryCenterY(_ entry: TrayEntry) -> CGFloat {
        Layout.summaryRowCenterY(CGFloat(entry.index)) - summaryScroll + CGFloat(summaryDrag.value)
    }

    func summaryPose(_ entry: TrayEntry) -> RigPose {
        let pitch: Float = 0.42
        let fit = fitted(entry, box: Layout.summaryMiniBox, pitch: pitch, centerY: summaryCenterY(entry),
                         centerX: Layout.summaryItemCenterX)
        return RigPose(position: fit.position, scale: fit.scale, pitch: pitch, yaw: entry.spinYaw)
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
        summaryDrag.step(dt)
        publishTrayTiles()
        for entry in tray {
            guard let rig = entry.rig else { continue }
            let edge: Float
            switch entry.mode {
            case .tray:
                rig.pose = trayPose(entry)
                let x = trayCenterX(entry)
                let reach = Layout.trayPitch / 2
                edge = x > Layout.trayItemsRect.minX - reach && x < Layout.trayItemsRect.maxX + reach ? 1 : 0
            case .summary:
                entry.spinVelocity += (0.32 - entry.spinVelocity) * (1 - exp(-dt / 0.9))
                entry.spinYaw += entry.spinVelocity * dt
                if entry.spinYaw > 200 { entry.spinYaw -= 2 * .pi * 30 }
                rig.pose = summaryPose(entry)
                edge = summaryEdge(summaryCenterY(entry))
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

    /// A tile for every item that is in the tray or on its way there; none while the order sheet is up.
    private func publishTrayTiles() {
        guard !summaryActive else {
            trayTiles.update([])
            return
        }
        trayTiles.update(tray.compactMap { entry in
            let inTray = entry.mode == .tray || (entry.mode == .flying && !entry.flyingToSummary)
            return inTray ? TrayTileModel.Tile(id: entry.id, x: trayCenterX(entry)) : nil
        })
    }

    func animateTrayScroll(to target: CGFloat, duration: Double = 0.5) {
        trayScrollTween?.cancel()
        let from = trayScroll
        guard abs(from - target) > 0.5 else {
            trayScroll = target
            onLayoutChange()
            return
        }
        trayScrollTween = animate(duration: duration) { [unowned self] p in
            trayScroll = from + (target - from) * CGFloat(Ease.outCubic(p))
        } completion: { [weak self] in
            self?.onLayoutChange()
        }
    }

    /// Flies an entry's rig to its tray slot or summary row, fading it fully in on the way.
    private func flyEntry(_ entry: TrayEntry, toSummary: Bool, delay: Double = 0, duration: Double = 0.9) {
        guard let rig = entry.rig else { return }
        entry.mode = .flying
        entry.flyingToSummary = toSummary
        entry.lastEdge = -1
        rig.root.isEnabled = true
        if rig.scaleMultiplier < 1 {
            rig.appearTween?.cancel()
            var from: Float = 0
            rig.appearTween = animate(delay: delay, duration: 0.3, onStart: { from = rig.scaleMultiplier }) { p in
                rig.scaleMultiplier = lerp(from, 1, TimingCurve.standard(p))
            }
        }
        if toSummary { entry.spinYaw = -0.55 }
        flyRig(rig, duration: duration, delay: delay, minSpin: 1.5 * .pi, dip: false, timing: .swoop,
               control: { p0, p1 in
                   SIMD3<Float>(lerp(p0.x, p1.x, 0.3) + (toSummary ? 0.12 : -0.12), lerp(p0.y, p1.y, 0.5), 0.12)
               },
               target: { [unowned self] in toSummary ? summaryPose(entry) : trayPose(entry) }) { [weak self] in
            entry.mode = toSummary ? .summary : .tray
            entry.spinYaw = rig.pose.yaw
            entry.spinVelocity = 0
            self?.onLayoutChange()
        }
    }

    func sendCurrentToTray(_ item: IceCreamItem) {
        guard let hero = heroes[selectedVessel] else { return }
        heroes[selectedVessel] = nil
        isDragging = false
        scoops.removeAll()
        let entry = TrayEntry(item: item, rig: hero, index: Float(tray.count), metrics: itemMetrics(item))
        tray.append(entry)
        if summaryActive {
            flyEntry(entry, toSummary: true, duration: 1.0)
        } else {
            animateTrayScroll(to: maxTrayScroll, duration: 0.4)
            flyEntry(entry, toSummary: false, duration: 1.05)
        }
    }

    func returnHeroToEntry(_ id: UUID, item: IceCreamItem) {
        guard let entry = tray.first(where: { $0.id == id }), let hero = heroes[selectedVessel] else { return }
        heroes[selectedVessel] = nil
        isDragging = false
        scoops.removeAll()
        entry.item = item
        entry.rig = hero
        entry.setMetrics(itemMetrics(item))
        if !summaryActive {
            animateTrayScroll(to: trayScroll(showing: Int(entry.index.rounded())), duration: 0.6)
        }
        flyEntry(entry, toSummary: summaryActive, duration: 1.0)
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
        flyHeroToCenter(rig, duration: 0.95)
        if !summaryActive {
            animateTrayScroll(to: trayScroll(showing: Int(entry.index.rounded())), duration: 0.5)
        }
        onLayoutChange()
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
        summaryActive = false
        setSummaryDrag(0)
        setControlsVisible(false, animated: false)
        receiptFrames = [:]
        for (i, entry) in tray.enumerated() {
            guard let rig = entry.rig else { continue }
            rig.cancelMotions()
            rig.setOpacity(1)
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

    func setSummaryDrag(_ offset: Float) {
        summaryDrag.value = offset
        summaryDrag.target = offset
        summaryDrag.velocity = 0
    }

    func releaseSummaryDrag() {
        summaryDrag.target = 0
    }

    func enterSummary() {
        summaryActive = true
        summaryScroll = 0
        setControlsVisible(false, animated: true)
        for (i, entry) in tray.enumerated() where entry.rig != nil {
            flyEntry(entry, toSummary: true, delay: Double(i) * 0.05)
        }
    }

    func exitSummary() {
        summaryActive = false
        setControlsVisible(true, animated: true)
        for (i, entry) in tray.enumerated() where entry.rig != nil {
            flyEntry(entry, toSummary: false, delay: Double(i) * 0.04, duration: 0.85)
        }
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
        summaryActive = false
        summaryScroll = 0
        setSummaryDrag(0)
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
        controlsVisible = true
        setStep(.vessel, animated: false)
        updateIcons()
    }

    func restore(current: IceCreamItem?, items: [IceCreamItem], step: BuilderStep, summary: Bool = false) {
        reset()
        summaryActive = summary
        for item in items {
            let rig = makeItemRig(item)
            let entry = TrayEntry(item: item, rig: rig, index: Float(tray.count), metrics: itemMetrics(item))
            entry.mode = summary ? .summary : .tray
            tray.append(entry)
            root.addChild(rig.root)
        }
        trayScroll = maxTrayScroll
        if let current, !summary {
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
        controlsVisible = !summary
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
            actor.root.transform = slotLocal(item.vessel, key: key, height: 0)
            rig.scoops.append(actor)
            rig.body.addChild(actor.root)
        }
        return rig
    }
}
