import SwiftUI

// MARK: - Create Category Modal

struct CreateCategoryModal: View {
    @EnvironmentObject var categoryStore: CategoryStore
    @Binding var isPresented: Bool
    @State private var emoji: String = ""
    @State private var title: String = ""
    @State private var isDismissing: Bool = false
    @FocusState private var titleFocused: Bool

    private let maxCategoryTitleLength = 32

    private func setRandomEmoji() {
        let usedEmojis = Set(categoryStore.categories.map { $0.emoji })
        let commonEmojis = ["☕️", "🍔", "🍕", "🍎", "🚗", "🏠", "🎉", "💡", "🛒", "✈️", "📚", "💻", "🎁", "🍦", "🧃", "🧸", "🎸", "🧩", "🛍️", "🧹", "🛏️", "🪙", "💳", "🧾", "🛠️", "🐾", "🌳", "🌞", "🌧️", "🌙", "⭐️"]
        let available = commonEmojis.filter { !usedEmojis.contains($0) }
        emoji = available.randomElement() ?? "✨"
    }

    // MARK: - Inline validation hints

    private var emojiConflict: Bool {
        !isDismissing && !emoji.isEmpty && categoryStore.categories.contains(where: { $0.emoji == emoji })
    }

    private var titleConflict: Bool {
        guard !isDismissing else { return false }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && categoryStore.categories.contains(where: { $0.title.lowercased() == t.lowercased() })
    }

    private var canSave: Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !emoji.isEmpty
            && emoji != CategoryStore.uncategorized.emoji
            && !t.isEmpty
            && t.count <= maxCategoryTitleLength
            && !emojiConflict
            && !titleConflict
    }

    func tryAdd() {
        guard canSave else { return }
        let cat = Category(emoji: emoji, title: title.trimmingCharacters(in: .whitespacesAndNewlines))
        categoryStore.addCategory(cat)
        isDismissing = true
        isPresented = false
    }

    var body: some View {
        NavigationView {
            ZStack {
                AppColors.backgroundChip
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
                                .foregroundColor(.red)
                        } else if emojiConflict {
                            Text("This emoji is already used for another category. Choose a different one.")
                                .font(.footnote)
                                .foregroundColor(.red)
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
                                .foregroundColor(.red)
                        }
                    }
                }
                .background(Color.clear)
            }
            .scrollContentBackground(.hidden)
            .background(AppColors.backgroundPrimary)
            .navigationTitle("Create Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: { tryAdd() }) {
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
            setRandomEmoji()
            title = ""
        }
    }
}

// MARK: - Emoji Input Button (opens native emoji keyboard)

/// A button-like emoji selector backed by a hidden UITextField
/// that forces the emoji keyboard. Tapping an emoji replaces the
/// current one and dismisses the keyboard.
struct EmojiInputButton: UIViewRepresentable {
    @Binding var emoji: String

    func makeUIView(context: Context) -> EmojiTextField {
        let field = EmojiTextField()
        field.delegate = context.coordinator
        field.text = emoji
        field.textAlignment = .center
        field.font = .systemFont(ofSize: 54)
        field.tintColor = .clear // hide cursor
        field.backgroundColor = .clear
        field.setContentHuggingPriority(.required, for: .horizontal)
        field.setContentHuggingPriority(.required, for: .vertical)
        return field
    }

    func updateUIView(_ uiView: EmojiTextField, context: Context) {
        if uiView.text != emoji {
            uiView.text = emoji
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(emoji: $emoji)
    }

    class Coordinator: NSObject, UITextFieldDelegate {
        var emoji: Binding<String>

        init(emoji: Binding<String>) {
            self.emoji = emoji
        }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            // Only accept emoji characters
            guard !string.isEmpty else { return false } // block deletion
            let firstEmoji = string.first { $0.isEmojiCharacter }
            guard let selected = firstEmoji else { return false }
            let selectedStr = String(selected)
            // Update UIKit text immediately, then sync binding
            textField.text = selectedStr
            emoji.wrappedValue = selectedStr
            return false
        }
    }
}

/// A UITextField subclass that always presents the emoji keyboard.
class EmojiTextField: UITextField {
    override var textInputMode: UITextInputMode? {
        for mode in UITextInputMode.activeInputModes {
            if mode.primaryLanguage == "emoji" {
                return mode
            }
        }
        return super.textInputMode
    }

    override func caretRect(for position: UITextPosition) -> CGRect {
        .zero // hide caret
    }

    override func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        [] // hide selection
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        false // disable cut/copy/paste menu
    }
}

private extension Character {
    var isEmojiCharacter: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        return scalar.properties.isEmoji && (scalar.value > 0x238C || unicodeScalars.count > 1)
    }
}
