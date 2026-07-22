@preconcurrency import AVFoundation
import SwiftUI

/// A live camera QR scanner. Reports the first `nostrpair://` payload it sees.
///
/// Wrapped from AVFoundation because SwiftUI has no native scanner; the wrapper
/// is thin and the surface it exposes is a plain callback, so the feature views
/// stay declarative.
struct QRScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onScan = onScan
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}
}

// nonisolated so the AVFoundation delegate conformance does not drag the whole
// controller across the main-actor boundary; the one callback hops back to the
// main actor itself.
final class ScannerController: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?

    nonisolated(unsafe) private let captureSession = AVCaptureSession()
    /// AVCaptureSession start/stop blocks, and the session is not Sendable, so
    /// it is driven on a dedicated serial queue rather than a detached Task.
    private let sessionQueue = DispatchQueue(label: "dev.jedbridges.comb.scanner")
    private var preview: AVCaptureVideoPreviewLayer?
    /// The scanner fires once. A second read while the first is being handled
    /// would start two pairing sessions from one code.
    private var hasReported = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configure()
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(input)
        else { return }
        captureSession.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard captureSession.canAddOutput(output) else { return }
        captureSession.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: captureSession)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.layer.bounds
        view.layer.addSublayer(preview)
        self.preview = preview

        sessionQueue.async { [captureSession] in
            captureSession.startRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.layer.bounds
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if captureSession.isRunning {
            sessionQueue.async { [captureSession] in captureSession.stopRunning() }
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput objects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasReported,
              let object = objects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue,
              value.hasPrefix("nostrpair://")
        else { return }

        hasReported = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onScan?(value)
    }
}
