import SwiftUI

/// Rename / re-emoji an existing category. Visually mirrors
/// `CreateCategoryModal` so users don't have to learn a second screen,
/// but two behaviour differences worth flagging:
///
///   1. Conflict checks ignore the category being edited (its own
///      title/emoji isn't a conflict with itself).
///   2. Reserved categories ("General" + the 18 seeded defaults) are
///      not editable. `CategoriesSheetView` drops the Button wrapper
///      for reserved rows entirely, so this modal never receives one
///      and doesn't need to re-check at save-time. If a future entry
///      point starts presenting this modal from somewhere else, the
///      `CategoryStore.isReserved(_:)` check should be reinstated as
///      a guard in `trySave`.
///
/// On save we both update the category record and call into
/// `TransactionStore.renameCategory(...)` so every existing
/// `Transaction.category` text reference gets rewritten to the new
/// title and emoji — without that step the old name would linger in
/// the home list until each row was edited by hand.
struct EditCategoryModal: View {
    @EnvironmentObject var categoryStore: CategoryStore
    @EnvironmentObject var transactionStore: TransactionStore
    @Binding var isPresented: Bool
    let category: Category

    @State private var emoji: String
    @State private var title: String
    @State private var isDismissing: Bool = false
    @FocusState private var titleFocused: Bool

    private let maxCategoryTitleLength = 32

    init(isPresented: Binding<Bool>, category: Category) {
        self._isPresented = isPresented
        self.category = category
        self._emoji = State(initialValue: category.emoji)
        self._title = State(initialValue: category.title)
    }

    // MARK: - Inline validation

    /// Conflict with another category (not this one). Letting the user
    /// keep the same emoji/title they started with is the whole point of
    /// "edit" — only a *different* category claiming the same value is
    /// the problem.
    private var emojiConflict: Bool {
        !isDismissing && !emoji.isEmpty && categoryStore.categories.contains(where: { $0.id != category.id && $0.emoji == emoji })
    }

    private var titleConflict: Bool {
        guard !isDismissing else { return false }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && categoryStore.categories.contains { $0.id != category.id && $0.title.lowercased() == t.lowercased() }
    }

    /// Save is allowed when the form is valid AND something actually
    /// changed — otherwise we'd run a no-op cascade through every
    /// transaction.
    private var canSave: Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let dirty = (emoji != category.emoji) || (t != category.title)
        return dirty
            && !emoji.isEmpty
            && emoji != CategoryStore.uncategorized.emoji
            && !t.isEmpty
            && t.count <= maxCategoryTitleLength
            && !emojiConflict
            && !titleConflict
    }

    private func trySave() {
        guard canSave else { return }
        let newTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = Category(id: category.id, emoji: emoji, title: newTitle, lastModified: Date())

        // Update the category record itself …
        categoryStore.updateCategory(updated)

        // … then rewrite every transaction that points at the old name
        // so the home list refreshes immediately and CloudKit syncs the
        // new label out to other devices.
        if newTitle != category.title || emoji != category.emoji {
            transactionStore.renameCategory(
                from: category.title,
                to: newTitle,
                newEmoji: emoji
            )
        }

        isDismissing = true
        isPresented = false
    }

    var body: some View {
        NavigationView {
            ZStack {
                AppColors.backgroundPrimary
                    .ignoresSafeArea()
                Form {
                    Section(header:
                        HStack {
                            Spacer()
                            EmojiInputButton(emoji: $emoji)
                                .frame(width: 70, height: 70)
                            Spacer()
                        }
                    ) {
                        if emojiConflict && titleConflict {
                            Text("This emoji and title are already used for another category. Choose different ones.")
                                .font(.footnote)
                                .foregroundColor(AppColors.danger)
                        } else if emojiConflict {
                            Text("This emoji is already used for another category. Choose a different one.")
                                .font(.footnote)
                                .foregroundColor(AppColors.danger)
                        }

                        TextField("Category Name", text: $title)
                            .focused($titleFocused)
                            .textContentType(.name)
                            .submitLabel(.done)
                            .onTapGesture { titleFocused = true }
                            .onChange(of: title) { newValue in
                                if newValue.count > maxCategoryTitleLength {
                                    title = String(newValue.prefix(maxCategoryTitleLength))
                                }
                            }

                        if titleConflict && !emojiConflict {
                            Text("This title is already used for another category. Choose a different one.")
                                .font(.footnote)
                                .foregroundColor(AppColors.danger)
                        }
                    }
                }
                .background(Color.clear)
            }
            .scrollContentBackground(.hidden)
            .background(AppColors.backgroundPrimary)
            .navigationTitle("Edit Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: { trySave() }) {
                        Image(systemName: "checkmark")
                    }
                    .disabled(!canSave)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
        .onAppear {
            isDismissing = false
        }
    }
}
