import QuartzCore
import RealityKit
import SwiftUI

struct StageView: View {
    let stage: Stage

    var body: some View {
        RealityView { content in
            content.camera = .virtual
            content.renderingEffects.antialiasing = .multisample4X
            stage.attach(to: &content)
        }
        .mask { TrayClip().fill(style: FillStyle(eoFill: true)) }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear { HighFrameRate.shared.start() }
    }
}

/// Clips the tray's 3D minis to the tray's item area the way a scroll view clips its content. Only the
/// tray's horizontal band is clipped, so items fly into and out of the tray from above unclipped.
struct TrayClip: Shape {
    static var itemsArea: CGRect {
        let glass = Layout.trayGlassRect
        return CGRect(x: Layout.trayItemsRect.minX, y: glass.minY, width: glass.maxX - Layout.trayItemsRect.minX, height: glass.height)
    }

    static let itemsShape = UnevenRoundedRectangle(cornerRadii: .init(bottomTrailing: 40, topTrailing: 40), style: .continuous)

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        let glass = Layout.trayGlassRect
        path.addRect(CGRect(x: rect.minX, y: glass.minY, width: rect.width, height: rect.maxY - glass.minY))
        path.addPath(Self.itemsShape.path(in: Self.itemsArea))
        return path
    }
}

/// RealityView has no frame-rate API; an active display link asking for 120 Hz keeps ProMotion from
/// dropping the panel to a lower refresh rate while the 3D scene animates.
@MainActor
final class HighFrameRate: NSObject {
    static let shared = HighFrameRate()
    private var link: CADisplayLink?

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step(_ link: CADisplayLink) {}
}

struct StageDebugOverlay: View {
    let stage: Stage

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let summary = stage.stats.summary()
            ZStack(alignment: .topLeading) {
                ForEach(stage.debugMarkers()) { marker in
                    Circle().stroke(.red, lineWidth: 1.5).frame(width: 18, height: 18).position(marker.expected)
                    Rectangle().fill(.blue).frame(width: 8, height: 8).position(marker.actual)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "%.0f fps · p50 %.1f ms · p99 %.1f ms · max %.1f ms",
                                summary.fps, summary.p50 * 1000, summary.p99 * 1000, summary.max * 1000))
                    Text(String(format: "update CPU p99 %.2f ms · max %.2f ms · %d samples",
                                summary.cpuP99 * 1000, summary.cpuMax * 1000, summary.samples))
                    Text("tweens \(stage.activeAnimationCount) · morphing \(stage.morphingCount) · time ×\(stage.timeScale, specifier: "%.2f")")
                    ForEach(stage.assets?.report ?? [], id: \.self) { Text($0) }
                }
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .padding(10)
                .background(.black.opacity(0.65), in: .rect(cornerRadius: 10))
                .padding(.top, 64)
                .padding(.leading, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
