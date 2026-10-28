import Foundation

struct ClipboardItem: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let copiedAt: Date
    /// Pinned items sit on top and survive "clear" and the 20-item cap (until quit).
    var isPinned = false
}
