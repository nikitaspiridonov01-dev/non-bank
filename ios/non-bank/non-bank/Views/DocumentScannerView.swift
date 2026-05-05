import SwiftUI
import VisionKit

/// SwiftUI wrapper around `VNDocumentCameraViewController`. Apple's native
/// document scanner handles edge detection, perspective correction and
/// noise reduction for free — using it for receipt capture meaningfully
/// improves OCR accuracy versus a raw camera-roll photo.
///
/// Returns the first scanned page (the user can re-take pages from inside
/// the controller; we ignore subsequent pages for the receipt flow).
struct DocumentScannerView: UIViewControllerRepresentable {
    var onScan: (UIImage) -> Void
    var onCancel: () -> Void
    var onError: ((Error) -> Void)? = nil

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScannerView

        init(_ parent: DocumentScannerView) {
            self.parent = parent
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            guard scan.pageCount > 0 else {
                parent.onCancel()
                return
            }
            parent.onScan(scan.imageOfPage(at: 0))
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.onCancel()
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            parent.onError?(error)
        }
    }
}
