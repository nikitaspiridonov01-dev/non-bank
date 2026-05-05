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
                // Title input
                TextField(placeholderTitle, text: $title, axis: .vertical)
                .focused($titleFocused)
                .font(.system(size: 34, weight: .bold))
                .lineLimit(1...4)
                .scrollDisabled(true)
                .padding(.horizontal, AppSpacing.pageHorizontal)
                .padding(.top, AppSpacing.md)
                .padding(.bottom, AppSpacing.md)
                .onChange(of: title) { newValue in
                    if newValue.count > 40 {
                        title = String(newValue.prefix(40))
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
                            Text("Write a note...")
                                .font(AppFonts.bodyRegular)
                                .foregroundColor(AppColors.textSecondary)
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
                    Button("Done") {
                        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        title = trimmed
                        isPresented = false
                    }
                }
            }
            .onAppear { titleFocused = true }
        }
    }
}

