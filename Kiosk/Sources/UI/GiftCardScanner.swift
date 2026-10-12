import AVFoundation
import SwiftUI

/// Live front-camera preview that reports every barcode it reads. `DataScannerViewController` can't use the front
/// camera, which is the one facing a customer at the kiosk.
struct GiftCardScanner: UIViewRepresentable {
    let onCode: (String) -> Void
    let onUnavailable: (String) -> Void

    func makeCoordinator() -> GiftCardCamera { GiftCardCamera() }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        let camera = context.coordinator
        camera.onCode = onCode
        camera.onUnavailable = onUnavailable
        Task { await camera.start(in: view.previewLayer) }
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        context.coordinator.onCode = onCode
        context.coordinator.onUnavailable = onUnavailable
    }

    static func dismantleUIView(_ view: PreviewView, coordinator: GiftCardCamera) {
        coordinator.stop()
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

final class GiftCardCamera: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    private static let symbologies: [AVMetadataObject.ObjectType] = [
        .qr, .code128, .pdf417, .ean13, .code39, .code39Mod43, .code93, .dataMatrix, .aztec, .interleaved2of5, .itf14,
    ]

    @MainActor var onCode: (String) -> Void = { _ in }
    @MainActor var onUnavailable: (String) -> Void = { _ in }

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "kiosk.giftcard.camera")
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var stopped = false

    @MainActor
    func start(in layer: AVCaptureVideoPreviewLayer) async {
        guard await Self.hasPermission() else {
            onUnavailable("Camera permission denied")
            return
        }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: device) else {
            #if !targetEnvironment(simulator)
            onUnavailable("No front camera")
            #endif
            return
        }
        let output = AVCaptureMetadataOutput()
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            onUnavailable("Camera configuration failed")
            return
        }
        session.addInput(input)
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: queue)
        output.metadataObjectTypes = Self.symbologies.filter(output.availableMetadataObjectTypes.contains)
        session.commitConfiguration()

        layer.session = session
        let rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
        self.rotation = rotation
        layer.connection?.videoRotationAngle = rotation.videoRotationAngleForHorizonLevelPreview

        let session = session
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            session.startRunning()
        }
    }

    @MainActor
    func stop() {
        let session = session
        queue.async { [weak self] in
            self?.stopped = true
            session.stopRunning()
        }
    }

    private static func hasPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        let codes = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
        guard !codes.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            codes.forEach(self.onCode)
        }
    }
}
