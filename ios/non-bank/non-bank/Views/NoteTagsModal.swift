import SwiftUI

// MARK: - Notes & Title editor
struct NoteTagsModal: View {
    @Binding var isPresented: Bool
    @Binding var title: String
    @Binding var note: String
    var placeholderTitle: String = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Title input — single line. The previous version
                // allowed `axis: .vertical` + `lineLimit(1...4)` which
                // let the user wrap mid-title via the return key. The
                // notes field stays multi-line (TextEditor below);
                // titles are now strictly one line so they render
                // predictably in row layouts and detail headers.
                TextField(placeholderTitle, text: $title)
                .focused($titleFocused)
                .font(.system(size: 34, weight: .bold))
                .submitLabel(.done)
                .onSubmit { commitAndDismiss() }
                .padding(.horizontal, AppSpacing.pageHorizontal)
                .padding(.top, AppSpacing.md)
                .padding(.bottom, AppSpacing.md)
                .onChange(of: title) { newValue in
                    // Strip any newline that slipped in (paste, dictation,
                    // hardware keyboard) — the keyboard's return key now
                    // submits via `onSubmit`, but other input paths can
                    // still inject `\n`.
                    var sanitized = newValue.replacingOccurrences(of: "\n", with: " ")
                    if sanitized.count > 40 {
                        sanitized = String(sanitized.prefix(40))
                    }
                    if sanitized != newValue {
                        title = sanitized
                    }
                }

                // Notes editor
                TextEditor(text: $note)
                    .font(AppFonts.bodyRegular)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.top, AppSpacing.xs)
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .topLeading) {
                        if note.isEmpty {
                            // Match the title TextField's placeholder
                            // tone — both use the system placeholder
                            // grey (`textDisabled` resolves to
                            // `Color(.placeholderText)`) so the two
                            // empty fields read as a single visual rhythm
                            // instead of two competing greys.
                            Text("Write a note...")
                                .font(AppFonts.bodyRegular)
                                .foregroundColor(AppColors.textDisabled)
                                .padding(.horizontal, 17)
                                .padding(.top, AppSpacing.md)
                                .allowsHitTesting(false)
                        }
                    }
            }
            .navigationTitle("Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { commitAndDismiss() }
                }
            }
            .onAppear { titleFocused = true }
        }
    }

    /// Trim and dismiss — used by both the toolbar Done button and
    /// the title field's keyboard return (`.submitLabel(.done)`).
    private func commitAndDismiss() {
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        isPresented = false
    }
}

