import SwiftUI

// MARK: - Dismissible Sheet
//
// Wraps content in a `NavigationStack` with a navigation title and a
// **Close** button in the leading toolbar slot. Replaces the 11
// inline implementations of:
//
//     NavigationStack {
//         content
//             .navigationTitle("...")
//             .navigationBarTitleDisplayMode(.inline)
//             .toolbar {
//                 ToolbarItem(placement: .cancellationAction) {
//                     Button("Close") { dismiss() }
//                 }
//             }
//     }
//
// across `InsightsView`, `InsightsDetailView`, `SmallExpensesListView`,
// `PeriodPickerSheet`, `FriendCardView`, `ProfileNameSheet`,
// `FriendFormView`, `FilterSheetView`, etc.
//
// Usage:
//
//     SomeContent()
//         .dismissibleSheet(title: "Period")
//
// Or with an inline `confirmation` action on the trailing edge:
//
//     SomeContent()
//         .dismissibleSheet(title: "Edit", confirm: ("Save", { saveAction() }))

struct DismissibleSheetModifier: ViewModifier {
    let title: String
    let titleDisplayMode: NavigationBarItem.TitleDisplayMode
    let confirm: (label: String, action: () -> Void)?
    let confirmDisabled: Bool

    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(titleDisplayMode)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                    if let confirm {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(confirm.label, action: confirm.action)
                                .disabled(confirmDisabled)
                        }
                    }
                }
        }
    }
}

extension View {
    /// Wraps the receiver in a `NavigationStack` with the provided
    /// navigation title and a **Close** button in the leading
    /// toolbar slot. The Close button calls the environment's
    /// `dismiss()` — works whether the sheet was opened via
    /// `.sheet(isPresented:)`, `.sheet(item:)`, or pushed.
    ///
    /// - Parameters:
    ///   - title: Navigation bar title.
    ///   - titleDisplayMode: Defaults to `.inline` (matches the
    ///     existing pattern across the app).
    ///   - confirm: Optional trailing-action button (label + action).
    ///   - confirmDisabled: When `true`, the trailing confirm
    ///     button is disabled. Use for forms with validation.
    func dismissibleSheet(
        title: String,
        titleDisplayMode: NavigationBarItem.TitleDisplayMode = .inline,
        confirm: (label: String, action: () -> Void)? = nil,
        confirmDisabled: Bool = false
    ) -> some View {
        modifier(DismissibleSheetModifier(
            title: title,
            titleDisplayMode: titleDisplayMode,
            confirm: confirm,
            confirmDisabled: confirmDisabled
        ))
    }
}
