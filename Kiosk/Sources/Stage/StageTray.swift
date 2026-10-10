import RealityKit
import SwiftUI

extension Stage {
    func contentCenterY(of item: IceCreamItem) -> Float {
        guard let assets else { return 0.05 }
        var top = assets.vesselTop(item.vessel)
        for index in item.flavors.indices {
            let key = placementKey(index: index, count: item.flavors.count, vessel: item.vessel)
            let y = assets.placements.placement(item.vessel, key: key).translation.y
            top = max(top, y + assets.scoopSet(index + 1).poseBounds(finalPoseName(item.vessel, key: key)).max.y)
        }
        return top / 2
    }

    var maxTrayScroll: CGFloat {
        guard !tray.isEmpty else { return 0 }
        let lastCenter = Layout.trayFirstCenterX + CGFloat(tray.count - 1) * Layout.trayPitch
        return max(0, lastCenter + Layout.trayPitch / 2 + 8 - Layout.trayItemsRect.maxX)
    }

    func trayCenterX(_ entry: TrayEntry) -> CGFloat {
        Layout.trayFirstCenterX + CGFloat(entry.index) * Layout.trayPitch - trayScroll
    }

    func trayPose(_ entry: TrayEntry) -> RigPose {
        var position = world(CGPoint(x: trayCenterX(entry), y: Layout.trayCenterY))
        let scale = Self.miniScale(entry.item.vessel)
        position.y += ((entry.rig?.pivot.y ?? 0) - entry.contentCenterY) * scale
        return RigPose(position: position, scale: scale, pitch: 0.3, yaw: -0.55)
    }

    func summaryCenterY(_ entry: TrayEntry) -> CGFloat {
        Layout.summaryRowCenterY(CGFloat(entry.index)) - summaryScroll
    }

    func summaryPose(_ entry: TrayEntry) -> RigPose {
        var position = world(CGPoint(x: Layout.summaryItemCenterX, y: summaryCenterY(entry)))
        let scale = Self.summaryScale(entry.item.vessel)
        position.y += ((entry.rig?.pivot.y ?? 0) - entry.contentCenterY) * scale
        return RigPose(position: position, scale: scale, pitch: 0.42, yaw: entry.spinYaw)
    }

    private func trayOpacity(_ x: CGFloat) -> Float {
        let fade: CGFloat = 40
        let left = (x - (Layout.trayItemsRect.minX + 6)) / fade
        let right = ((Layout.trayItemsRect.maxX - 6) - x) / fade
        return Float(min(max(min(left, right), 0), 1))
    }

    private func summaryOpacity(_ y: CGFloat) -> Float {
        let fade: CGFloat = 60
        let top = (y - Layout.summaryListRect.minY) / fade
        let bottom = (Layout.summaryListRect.maxY - y) / fade
        return Float(min(max(min(top, bottom), 0), 1))
    }

    func updateTray(dt: Float) {
        for entry in tray {
            guard let rig = entry.rig else { continue }
            let opacity: Float
            switch entry.mode {
            case .tray:
                rig.pose = trayPose(entry)
                opacity = trayOpacity(trayCenterX(entry))
            case .summary:
                entry.spinVelocity += (0.32 - entry.spinVelocity) * (1 - exp(-dt / 0.9))
                entry.spinYaw += entry.spinVelocity * dt
                if entry.spinYaw > 200 { entry.spinYaw -= 2 * .pi * 30 }
                rig.pose = summaryPose(entry)
                opacity = summaryOpacity(summaryCenterY(entry))
            case .flying, .editing, .removing:
                continue
            }
            rig.apply()
            if abs(opacity - entry.lastOpacity) > 0.004 {
                entry.lastOpacity = opacity
                rig.setOpacity(opacity)
            }
        }
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
        entry.lastOpacity = -1
        if rig.opacity < 1 {
            rig.opacityTween?.cancel()
            var from: Float = 0
            rig.opacityTween = animate(delay: delay, duration: 0.25, onStart: { from = rig.opacity }) { p in
                rig.setOpacity(lerp(from, 1, p))
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
        let entry = TrayEntry(item: item, rig: hero, index: Float(tray.count), contentCenterY: contentCenterY(of: item))
        tray.append(entry)
        if summaryActive {
            flyEntry(entry, toSummary: true, duration: 1.0)
        } else {
            animateTrayScroll(to: maxTrayScroll, duration: 0.7)
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
        entry.contentCenterY = contentCenterY(of: item)
        if !summaryActive, let center = trayItemCenter(id), !Layout.trayItemsRect.insetBy(dx: 40, dy: 0).contains(center) {
            let target = Layout.trayFirstCenterX + CGFloat(entry.index) * Layout.trayPitch - Layout.trayItemsRect.midX
            animateTrayScroll(to: min(max(target, 0), maxTrayScroll), duration: 0.6)
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
        flyHeroToCenter(rig, duration: 0.95)
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
        animateTrayScroll(to: min(trayScroll, maxTrayScroll), duration: 0.45)
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
        let target = min(max((trayDragStart ?? trayScroll) - predictedDx, 0), maxTrayScroll)
        trayDragStart = nil
        animateTrayScroll(to: target, duration: 0.5)
    }

    private func rubberBand(_ x: CGFloat) -> CGFloat { 60 * (1 - 1 / (x / 120 + 1)) }

    func trayItem(at point: CGPoint) -> UUID? {
        guard Layout.trayItemsRect.contains(point) else { return nil }
        for entry in tray where entry.mode != .removing {
            let x = trayCenterX(entry)
            if abs(point.x - x) < Layout.trayPitch / 2, trayOpacity(x) > 0.5 { return entry.id }
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
            icon.shadowAmount = 1
            icon.appearTween = nil
        }
        controlsVisible = true
        setStep(.vessel, animated: false)
        updateIcons()
    }

    func restore(current: IceCreamItem?, items: [IceCreamItem], step: BuilderStep, summary: Bool = false) {
        reset()
        summaryActive = summary
        for item in items {
            let rig = makeItemRig(item)
            let entry = TrayEntry(item: item, rig: rig, index: Float(tray.count), contentCenterY: contentCenterY(of: item))
            entry.mode = summary ? .summary : .tray
            tray.append(entry)
            root.addChild(rig.root)
        }
        trayScroll = maxTrayScroll
        if let current, !summary {
            selectedVessel = current.vessel
            let rig = makeItemRig(current)
            rig.pose = centerPose(current.vessel, yaw: 0.4)
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
            actor.rig = rig
            actor.placementKey = key
            actor.state = .landed
            actor.root.transform = slotLocal(item.vessel, key: key, height: 0)
            rig.scoops.append(actor)
            rig.body.addChild(actor.root)
        }
        return rig
    }
}
