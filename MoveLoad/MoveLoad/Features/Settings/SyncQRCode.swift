import SwiftUI
import AVFoundation
import CoreImage.CIFilterBuiltins
import SyncKit

/// Shows the team's sync settings as a QR code for another athlete to scan.
///
/// Everything needed to join is in the code, so this is the team's secret in
/// visible form — which is why the screen says so rather than leaving the
/// athlete to leave it on a table.
struct SyncQRCodeView: View {
    let settings: SyncSettings

    var body: some View {
        VStack(spacing: 20) {
            if let image = Self.qrCode(for: settings.shareablePayload) {
                Image(uiImage: image)
                    .interpolation(.none)   // keep the modules crisp when scaled up
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 280, maxHeight: 280)
                    .padding()
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                ContentUnavailableView(
                    "QR code indisponible",
                    systemImage: "qrcode",
                    description: Text("Les réglages de synchronisation ne sont pas complets.")
                )
            }

            Text("À scanner depuis Réglages > Synchronisation sur le téléphone du nouvel athlète.")
                .font(.callout)
                .multilineTextAlignment(.center)

            Label(
                "Ce code contient le code d'équipe : quiconque le photographie peut accéder aux données de l'équipe.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding()
        .navigationTitle("Partager les réglages")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// CoreImage renders one pixel per module, which upscales to a blurred
    /// mess unless it is magnified before becoming a UIImage.
    private static func qrCode(for payload: String) -> UIImage? {
        guard !payload.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// Camera view that reports the first QR code it recognises.
///
/// Built on AVFoundation rather than VisionKit's `DataScannerViewController`,
/// which needs an A12 or newer device — an athlete's older phone should not be
/// the reason they have to type a forty-character key by hand.
struct QRScannerView: UIViewControllerRepresentable {
    let onFound: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.onFound = onFound
        return controller
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
}

final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onFound: ((String) -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    /// Recognition fires repeatedly while the code stays in frame; the first
    /// result is the only one that should reach the caller.
    private var hasReported = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            showMessage(String(localized: "Caméra indisponible."))
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            showMessage("Caméra indisponible.")
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        // Set after adding the output: the available types are empty until
        // then, and assigning an unsupported one raises.
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.layer.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer

        startRunning()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.layer.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopRunning()
    }

    private func startRunning() {
        guard !session.isRunning else { return }
        // Starting the session blocks; off the main thread so the sheet
        // animates in rather than freezing half-presented.
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.startRunning()
        }
    }

    private func stopRunning() {
        guard session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.stopRunning()
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasReported,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue
        else { return }

        hasReported = true
        stopRunning()
        onFound?(value)
    }

    private func showMessage(_ text: String) {
        let label = UILabel()
        label.text = text
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])
    }
}
