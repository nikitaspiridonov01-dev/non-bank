import Foundation

struct Category: Identifiable, Codable, Equatable {
    let id: UUID
    let emoji: String
    let title: String
    let lastModified: Date

    init(id: UUID = UUID(), emoji: String, title: String, lastModified: Date = Date()) {
        self.id = id
        self.emoji = emoji
        self.title = title
        self.lastModified = lastModified
    }

    // Валидация (пример)
    var isValid: Bool {
        !emoji.isEmpty && !title.isEmpty && title.count <= 32
    }
}
