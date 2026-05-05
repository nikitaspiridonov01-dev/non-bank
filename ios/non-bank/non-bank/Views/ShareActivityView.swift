import SwiftUI
import UIKit

// MARK: - Share Activity View

/// SwiftUI wrapper around `UIActivityViewController`. SwiftUI's built-in
/// `ShareLink` can't be triggered programmatically — it has to be on the
/// tap target itself. Our share flow needs to defer the share sheet
/// until AFTER an intermediate name-prompt step, so we drop down to
/// UIKit for that case.
///
/// Used via `.sheet(item:)` with `IdentifiableURL` so dismissal is
/// driven by setting the binding to `nil`.
struct ShareActivityView: UIViewControllerRepresentable {
    let items: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: applicationActivities)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        // No-op — the controller's content is fixed at creation.
    }
}

// `IdentifiableURL` is defined elsewhere in the project
// (`ExportTransactionsView.swift`) and reused here for the share flow.
