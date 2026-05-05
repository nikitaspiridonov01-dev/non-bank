import SwiftUI

// MARK: - Profile Name Sheet

/// Reusable big-text name-input sheet, visually mirroring the
/// `FriendFormView` creation screen (centered 36-pt bold TextField,
/// "Cancel" / "Save" toolbar). Used in two places:
///
/// 1. **Settings → Your name** — tapping the row opens this sheet so
///    the user can set/edit the name shown to share-link recipients.
/// 2. **Pre-share name prompt** — when the user taps Share without
///    having a profile name set, this sheet appears first; on save the
///    name is persisted and the share flow continues.
///
/// Both call sites share the same UI, the same input pattern, and the
/// same 35-char cap as `FriendFormView.nameInput`.
struct ProfileNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFieldFocused: Bool
    @State private var name: String

    /// Header copy shown above the input. Different across call sites
    /// ("Your name" for the Settings flow; "What's your name?" for the
    /// pre-share prompt).
    let title: String
    /// Subtitle copy shown under the title — explains where the name
    /// will appear (helpful on first-time prompt).
    let subtitle: String?
    /// Action label on the confirm toolbar button.
    let saveButtonTitle: String
    /// Whether to call the environment `dismiss()` after `onSave`
    /// returns. **Defaults to `true`** for the simple Settings flow
    /// where the sheet should just go away. **Set to `false`** when
    /// the parent uses `.sheet(item:)` and intends to *transition*
    /// the sheet content (e.g. `askName → share`) inside `onSave` —
    /// because `dismiss()` writes `nil` back to the bound state via
    /// `DismissAction`, it would race with and overwrite the
    /// transition the parent just performed, killing the next sheet
    /// content swap. The pre-share `TransactionDetailView` flow uses
    /// `false` for exactly this reason.
    let dismissOnSave: Bool
    /// Fired on save with the trimmed name. Caller persists / propagates.
    var onSave: (String) -> Void

    /// Match the same cap `FriendFormView` uses so the two flows
    /// behave identically.
    private static let nameMaxLength = 35

    init(
        initialName: String = "",
        title: String = "Your name",
        subtitle: String? = nil,
        saveButtonTitle: String = "Save",
        dismissOnSave: Bool = true,
        onSave: @escaping (String) -> Void
    ) {
        _name = State(initialValue: initialName)
        self.title = title
        self.subtitle = subtitle
        self.saveButtonTitle = saveButtonTitle
        self.dismissOnSave = dismissOnSave
        self.onSave = onSave
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppColors.backgroundPrimary.ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer()

                    if let subtitle {
                        Text(subtitle)
                            .font(AppFonts.caption)
                            .foregroundColor(AppColors.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, AppSpacing.xxxl)
                            .padding(.bottom, AppSpacing.xxl)
                    }

                    nameInput

                    Spacer()
                }
            }
            .navigationTitle(title)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saveButtonTitle) { save() }
                        .disabled(!canSave)
                }
            }
            .onAppear {
                nameFieldFocused = true
            }
        }
    }

    // MARK: - Large Name Input
    //
    // Visual parity with `FriendFormView.nameInput`: same font/weight,
    // same vertical rhythm, same character cap. Different `prompt`
    // string so the placeholder makes sense in both flows.

    private var nameInput: some View {
        TextField(
            "",
            text: $name,
            prompt: Text("Name")
                .font(AppFonts.displayLarge)
                .foregroundColor(AppColors.textDisabled)
        )
        .font(AppFonts.displayLarge)
        .foregroundColor(AppColors.textPrimary)
        .multilineTextAlignment(.center)
        .minimumScaleFactor(0.5)
        .textContentType(.name)
        .submitLabel(.done)
        .focused($nameFieldFocused)
        .onSubmit {
            if canSave { save() }
        }
        .lineLimit(1)
        .padding(.horizontal, AppSpacing.xxl)
        .frame(height: 90)
        .onChange(of: name) { newValue in
            if newValue.count > Self.nameMaxLength {
                name = String(newValue.prefix(Self.nameMaxLength))
            }
        }
    }

    // MARK: - Save

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
        // Skip `dismiss()` when the parent is going to transition
        // the sheet content itself — calling DismissAction writes
        // `nil` back to the binding, which would erase the
        // transition the parent just performed (e.g. flipping
        // `shareFlow` from `.askName` to `.share`).
        if dismissOnSave {
            dismiss()
        }
    }
}
