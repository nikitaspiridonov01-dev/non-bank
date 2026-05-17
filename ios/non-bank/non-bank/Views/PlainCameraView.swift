import SwiftUI
import UIKit

/// SwiftUI wrapper around `UIImagePickerController` in camera mode —
/// captures a single, unprocessed photo. **No document detection,
/// no perspective correction, no multi-page.** The receipt parser
/// downstream handles whatever rectangle the user actually captured.
///
/// Previously this path used `VNDocumentCameraViewController`
/// (VisionKit), which auto-detected document edges and corrected
/// perspective. We swapped to a plain camera at owner request —
/// for short / curled / partially-occluded receipts the auto-crop
/// sometimes cropped real items out of frame, and users had no way
/// to override the detection rectangle.
///
/// Callers **must** guard the presentation with
/// `UIImagePickerController.isSourceTypeAvailable(.camera)` —
/// simulators without a camera will crash if this controller is
/// instantiated. Production iOS devices always have one.
///
/// Callback signature mirrors the old `DocumentScannerView` so the
/// existing scan-flow modifiers slot in with a one-line change.
/// `onError` is kept for signature parity but practically unused —
/// `UIImagePickerController` doesn't surface user-facing errors
/// the way `VNDocumentCameraViewController` did. CreateTransactionModal
/// wires it up for completeness; the receipt scan flow currently has
/// no codepath that fires it.
struct PlainCameraView: UIViewControllerRepresentable {
    var onScan: (UIImage) -> Void
    var onCancel: () -> Void
    var onError: ((Error) -> Void)? = nil

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        // `public.image` is the only media type the receipt flow
        // can consume. Skipping `public.movie` from the available
        // list (which iOS adds by default on devices with video
        // capture) hides the photo/video toggle so the user lands
        // straight on the still-photo UI.
        controller.mediaTypes = ["public.image"]
        // The in-app review sheet already lets the user fine-tune
        // each item — letting the system editor crop here would
        // double the post-capture friction without changing OCR
        // accuracy meaningfully.
        controller.allowsEditing = false
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: PlainCameraView

        init(_ parent: PlainCameraView) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onScan(image)
            } else {
                // Should be impossible — `mediaTypes` is `public.image`
                // only — but fall through to cancel rather than dropping
                // the user back into the camera silently.
                parent.onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
        }
    }
}
