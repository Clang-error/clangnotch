import AppKit
import Foundation

struct ClipboardItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case text
        /// Files copied in Finder (or elsewhere): their locations, not their contents. Copying
        /// the item again puts the same files back, as Finder's copy does.
        case files([URL])
        /// An image, kept on disk in the app's cache (`ClipboardManager.imageFolder`), with a
        /// small thumbnail in memory for the row.
        case image(file: URL, type: NSPasteboard.PasteboardType, thumbnail: NSImage, pixels: CGSize)
    }

    let id = UUID()
    /// What the row says: the text, the files' names, or "Image 1200×800".
    let text: String
    let copiedAt: Date
    var kind: Kind = .text
    /// Pinned items sit on top and survive "clear" and the 20-item cap (until quit).
    var isPinned = false

    var files: [URL]? { if case .files(let urls) = kind { urls } else { nil } }
    var imageFile: URL? { if case .image(let file, _, _, _) = kind { file } else { nil } }
    var thumbnail: NSImage? {
        switch kind {
        case .image(_, _, let thumbnail, _): thumbnail
        case .files(let urls): urls.first.map { NSWorkspace.shared.icon(forFile: $0.path) }
        case .text: nil
        }
    }
}
