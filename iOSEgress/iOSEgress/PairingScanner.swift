import AVFoundation
import SwiftUI
import Vision
import VisionKit

struct PairingScanner: View {
    let scanned: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var allowed = false
    @State private var message = "Allow camera access to scan the pairing code."

    var body: some View {
        NavigationStack {
            Group {
                if allowed {
                    ScannerCamera { value in scanned(value); dismiss() }
                        .overlay(alignment: .bottom) {
                            Text("Point at the Device Egress code on your Mac.")
                                .font(.callout).padding().background(.regularMaterial, in: Capsule()).padding()
                        }
                } else {
                    ContentUnavailableView("Camera unavailable", systemImage: "qrcode.viewfinder", description: Text(message))
                }
            }
            .navigationTitle("Scan pairing code").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } } }
            .task {
                guard DataScannerViewController.isSupported else {
                    message = "Use Paste pairing link instead on this device or simulator."; return
                }
                let permission = await AVCaptureDevice.requestAccess(for: .video)
                allowed = permission && DataScannerViewController.isAvailable
                if !allowed { message = "Enable Camera for this app in Settings, or use Paste pairing link." }
            }
        }
    }
}

private struct ScannerCamera: UIViewControllerRepresentable {
    let scanned: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(scanned) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, recognizesMultipleItems: false,
                                                isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        do { try scanner.startScanning() } catch {
            context.coordinator.finished = true
            scanned("")
        }
        return scanner
    }
    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) { controller.stopScanning() }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let scanned: (String) -> Void
        var finished = false
        init(_ scanned: @escaping (String) -> Void) { self.scanned = scanned }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !finished else { return }
            for case .barcode(let barcode) in addedItems {
                if let value = barcode.payloadStringValue {
                    finished = true; dataScanner.stopScanning(); scanned(value); return
                }
            }
        }
    }
}
