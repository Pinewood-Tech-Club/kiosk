import Foundation
import simd

enum Ease {
    static func clamp01(_ t: Float) -> Float { min(max(t, 0), 1) }

    static func inOutCubic(_ t: Float) -> Float {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    static func outCubic(_ t: Float) -> Float { 1 - pow(1 - t, 3) }
    static func outQuad(_ t: Float) -> Float { 1 - (1 - t) * (1 - t) }
    static func inQuad(_ t: Float) -> Float { t * t }
    static func inCubic(_ t: Float) -> Float { t * t * t }
    static func inOutSine(_ t: Float) -> Float { -(cos(.pi * t) - 1) / 2 }

    static func segment(_ t: Float, _ a: Float, _ b: Float) -> Float {
        clamp01((t - a) / (b - a))
    }
}

/// CSS-style cubic-bezier timing curve (control points P1, P2; P0 = 0,0 and P3 = 1,1).
struct TimingCurve {
    let x1: Float, y1: Float, x2: Float, y2: Float

    init(_ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float) {
        self.x1 = x1; self.y1 = y1; self.x2 = x2; self.y2 = y2
    }

    private func bezier(_ t: Float, _ p1: Float, _ p2: Float) -> Float {
        let u = 1 - t
        return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
    }

    private func slope(_ t: Float, _ p1: Float, _ p2: Float) -> Float {
        let u = 1 - t
        return 3 * u * u * p1 + 6 * u * t * (p2 - p1) + 3 * t * t * (1 - p2)
    }

    func callAsFunction(_ x: Float) -> Float {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        var t = x
        for _ in 0..<8 {
            let dx = bezier(t, x1, x2) - x
            let d = slope(t, x1, x2)
            if abs(dx) < 1e-6 || abs(d) < 1e-6 { break }
            t -= dx / d
        }
        var lo: Float = 0, hi: Float = 1
        if abs(bezier(t, x1, x2) - x) > 1e-4 {
            t = x
            for _ in 0..<24 {
                if bezier(t, x1, x2) < x { lo = t } else { hi = t }
                t = (lo + hi) / 2
            }
        }
        return bezier(Ease.clamp01(t), y1, y2)
    }

    static let standard = TimingCurve(0.45, 0, 0.25, 1)
    static let flight = TimingCurve(0.36, 0, 0.18, 1)
    static let swoop = TimingCurve(0.55, 0, 0.3, 1)
    static let swiftUIEaseIn = TimingCurve(0.42, 0, 1, 1)
    static let swiftUIEaseOut = TimingCurve(0, 0, 0.58, 1)
    static let swiftUIEaseInOut = TimingCurve(0.42, 0, 0.58, 1)
}

/// Damped spring with the same parameterization (and therefore the same motion) as SwiftUI's
/// `.spring(response:dampingFraction:)`, so a 3D model can move in lockstep with a SwiftUI view.
struct Spring1D {
    var value: Float
    var velocity: Float = 0
    var target: Float
    let response: Float
    let dampingRatio: Float

    init(value: Float, response: Float, dampingRatio: Float) {
        self.value = value
        self.target = value
        self.response = response
        self.dampingRatio = dampingRatio
    }

    var isSettled: Bool { abs(value - target) < 1e-4 && abs(velocity) < 1e-3 }

    mutating func step(_ dt: Float) {
        guard dt > 0 else { return }
        if isSettled {
            value = target
            velocity = 0
            return
        }
        let omega = 2 * Float.pi / response
        let zeta = dampingRatio
        let x0 = value - target
        let v0 = velocity
        if zeta < 1 {
            let wd = omega * sqrt(1 - zeta * zeta)
            let decay = exp(-zeta * omega * dt)
            let a = x0
            let b = (v0 + zeta * omega * x0) / wd
            let c = cos(wd * dt), s = sin(wd * dt)
            value = target + decay * (a * c + b * s)
            velocity = decay * ((b * wd - zeta * omega * a) * c - (a * wd + zeta * omega * b) * s)
        } else {
            let decay = exp(-omega * dt)
            let k = v0 + omega * x0
            value = target + (x0 + k * dt) * decay
            velocity = (v0 - omega * k * dt) * decay
        }
    }
}

func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }

func cubicBezier(_ p0: SIMD3<Float>, _ c0: SIMD3<Float>, _ c1: SIMD3<Float>, _ p1: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
    let u = 1 - t
    return u * u * u * p0 + 3 * u * u * t * c0 + 3 * u * t * t * c1 + t * t * t * p1
}

func quadraticBezier(_ p0: SIMD3<Float>, _ c: SIMD3<Float>, _ p1: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
    let u = 1 - t
    return u * u * p0 + 2 * u * t * c + t * t * p1
}

/// Total yaw to travel from `from` so the result is congruent to `to` and covers at least `minimum` radians.
func forwardYawDelta(from: Float, to: Float, minimum: Float) -> Float {
    let tau = 2 * Float.pi
    var delta = (to - from).truncatingRemainder(dividingBy: tau)
    if delta < 0 { delta += tau }
    while delta < minimum { delta += tau }
    return delta
}

@MainActor
final class Tween {
    enum Phase: Int { case rigs = 0, attachments = 1, late = 2 }

    let startTime: Double
    let duration: Double
    let phase: Phase
    private let onUpdate: (Float) -> Void
    private var onComplete: (() -> Void)?
    private(set) var isFinished = false
    private var hasStarted = false
    private let onStart: (() -> Void)?

    init(start: Double, duration: Double, phase: Phase = .rigs,
         onStart: (() -> Void)? = nil,
         update: @escaping (Float) -> Void,
         completion: (() -> Void)? = nil) {
        self.startTime = start
        self.duration = max(duration, 1e-4)
        self.phase = phase
        self.onStart = onStart
        self.onUpdate = update
        self.onComplete = completion
    }

    func cancel() {
        isFinished = true
        onComplete = nil
    }

    func step(now: Double) {
        guard !isFinished, now >= startTime else { return }
        if !hasStarted {
            hasStarted = true
            onStart?()
            if isFinished { return }
        }
        let p = Float(min(max((now - startTime) / duration, 0), 1))
        onUpdate(p)
        if p >= 1, !isFinished {
            isFinished = true
            let completion = onComplete
            onComplete = nil
            completion?()
        }
    }
}
