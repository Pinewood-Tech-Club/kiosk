import ImageIO
import SwiftUI
import UIKit

/// The attract screen's two columns of printed photos drifting up the sides of the screen. Each column is one layer moved
/// by a repeating Core Animation, so the drift costs the app nothing per frame; the photos are decoded once.
struct PhotoColumns: UIViewRepresentable {
    var isActive: Bool

    func makeUIView(context: Context) -> PhotoColumnsView { PhotoColumnsView() }

    func updateUIView(_ view: PhotoColumnsView, context: Context) { view.setActive(isActive) }
}

final class PhotoColumnsView: UIView {
    static let columnCenters: [CGFloat] = [118, Layout.screen.width - 118]
    static let maxPhotoSize = CGSize(width: 250, height: 340)
    static let photoArea: CGFloat = 60_000
    static let border: CGFloat = 6
    static let gap: CGFloat = 34
    static let speed: CGFloat = 52
    /// How far above the screen each column's prints begin, so rotated corners never show a gap at the top edge.
    static let lead: CGFloat = 360
    private static let epoch = CACurrentMediaTime()

    private struct Print {
        let image: CGImage
        let size: CGSize
        let angle: CGFloat
        let jitter: CGFloat
    }

    private let columns = [CALayer(), CALayer()]
    private var periods: [CGFloat] = [0, 0]
    private var isActive = false
    private var stopWork: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        for column in columns { layer.addSublayer(column) }
        NotificationCenter.default.addObserver(self, selector: #selector(resumeDrift),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
        Task { [weak self] in
            let photos = await Task.detached(priority: .utility) { Self.decodePhotos() }.value
            self?.build(photos)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        stopWork?.cancel()
        stopWork = nil
        if active {
            startDrift()
        } else {
            let work = DispatchWorkItem { [weak self] in self?.stopDrift() }
            stopWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
    }

    @objc private func resumeDrift() {
        if isActive { startDrift() }
    }

    private nonisolated static func decodePhotos() -> [CGImage] {
        guard let folder = Bundle.main.url(forResource: "AttractPhotos", withExtension: nil),
              let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 640,
                       kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return urls.filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, options) }
            }
    }

    private static func printSize(_ image: CGImage) -> CGSize {
        let aspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
        let width = (photoArea * aspect).squareRoot()
        let fit = min(1, maxPhotoSize.width / width, maxPhotoSize.height * aspect / width)
        return CGSize(width: (width * fit).rounded(), height: (width * fit / aspect).rounded())
    }

    /// Each column shows the whole set twice per loop (an odd count would otherwise put two prints turned the same way
    /// side by side where the loop wraps), the right column half the set ahead of the left so a photo is never on both
    /// sides at once.
    private func build(_ photos: [CGImage]) {
        guard !photos.isEmpty else { return }
        var rng = ToppingRandom(seed: 0xA77_AC75)
        let order = Array(photos.indices).shuffled(using: &rng)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, column) in columns.enumerated() {
            let start = index * photos.count / 2
            let loop = (0..<2 * photos.count).map { k in
                let image = photos[order[(start + k) % photos.count]]
                let sign: CGFloat = (k + index) % 2 == 0 ? 1 : -1
                return Print(image: image, size: Self.printSize(image),
                             angle: sign * CGFloat.random(in: 5...10, using: &rng) * .pi / 180,
                             jitter: CGFloat.random(in: -10...10, using: &rng))
            }
            var y = -Self.lead
            var k = 0
            while k < loop.count || y < periods[index] - Self.lead + Layout.screen.height + 2 * Self.lead {
                let print = loop[k % loop.count]
                let layer = makeLayer(print)
                layer.position = CGPoint(x: Self.columnCenters[index] + print.jitter, y: y + layer.bounds.height / 2)
                column.addSublayer(layer)
                y += layer.bounds.height + Self.gap
                k += 1
                if k == loop.count { periods[index] = y + Self.lead }
            }
        }
        CATransaction.commit()
        if isActive { startDrift() }
    }

    private func makeLayer(_ print: Print) -> CALayer {
        let border = Self.border
        let card = CALayer()
        card.bounds = CGRect(x: 0, y: 0, width: print.size.width + 2 * border, height: print.size.height + 2 * border)
        card.backgroundColor = UIColor(white: 0.97, alpha: 1).cgColor
        card.shadowColor = UIColor.black.cgColor
        card.shadowOpacity = 0.55
        card.shadowRadius = 14
        card.shadowOffset = CGSize(width: 0, height: 10)
        card.shadowPath = CGPath(rect: card.bounds, transform: nil)
        card.allowsEdgeAntialiasing = true
        card.setAffineTransform(CGAffineTransform(rotationAngle: print.angle))
        let photo = CALayer()
        photo.frame = card.bounds.insetBy(dx: border, dy: border)
        photo.contents = print.image
        photo.contentsGravity = .resizeAspectFill
        photo.masksToBounds = true
        card.addSublayer(photo)
        return card
    }

    private func startDrift() {
        let elapsed = CACurrentMediaTime() - Self.epoch
        for (index, column) in columns.enumerated() where periods[index] > 0 && column.animation(forKey: "drift") == nil {
            let drift = CABasicAnimation(keyPath: "transform.translation.y")
            drift.fromValue = 0
            drift.toValue = -periods[index]
            drift.duration = periods[index] / Self.speed
            drift.repeatCount = .infinity
            drift.isRemovedOnCompletion = false
            drift.timeOffset = elapsed.truncatingRemainder(dividingBy: drift.duration)
            column.add(drift, forKey: "drift")
        }
    }

    private func stopDrift() {
        for column in columns { column.removeAnimation(forKey: "drift") }
    }
}
