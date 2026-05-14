import SwiftUI

/// Thin wrapper around `ScanningReceiptIllustration` so the parsing
/// overlay imports a single name. Lives separately from the
/// illustration itself because the call site (CreateTransactionModal)
/// shouldn't reach into the design-system `Illustrations` folder for a
/// loader-flavoured configuration of one of its members.
struct ReceiptScanLoader: View {
    var body: some View {
        ScanningReceiptIllustration(tint: .neutral, size: .hero)
    }
}
