import AppKit
import Combine

@MainActor
final class ClipboardManager: ObservableObject {
    static let shared = ClipboardManager()

    @Published private(set) var items: [ClipboardItem] = []
    /// Each copy made in another app, for the 복사 방울 (`ClipboardOrbView`). Our own writes
    /// move `lastChangeCount` along, so they don't count.
    let copied = PassthroughSubject<Void, Never>()

    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int = -1
    private var timer: Timer?
    private let maxItems = 20
    /// Bigger images aren't kept: their thumbnail would be all there is to show.
    private let maxImageBytes = 50 * 1024 * 1024

    /// Copied images live here rather than in memory, and go when their item goes.
    static let imageFolder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("com.clangerror.ClangNotch/Clipboard", isDirectory: true)
    }()

    private init() {
        // Images from a previous run have no item any more.
        try? FileManager.default.removeItem(at: Self.imageFolder)
        if AppSettings.shared.enableClipboardHistory { start() }
    }

    // MARK: - Lifecycle

    func start() {
        guard timer == nil, !DemoMode.isActive else { return }
        lastChangeCount = pasteboard.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        items.forEach(deleteImage)
        items = []
    }

    func syncWithSettings() {
        if AppSettings.shared.enableClipboardHistory {
            start()
        } else {
            stop()
        }
    }

    // MARK: - Polling

    private func poll() {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        // Skip transient / concealed (password manager) items
        let types = pasteboard.types ?? []
        let typeStrings = types.map(\.rawValue)
        // A password copied is still a copy: the orb says so, and the history leaves it out.
        // A transient item is an app's own passing data, not something the user copied.
        if !typeStrings.contains("org.nspasteboard.TransientType") { copied.send() }
        if typeStrings.contains("org.nspasteboard.ConcealedType") ||
           typeStrings.contains("org.nspasteboard.TransientType") { return }

        guard let item = readItem(types: types) else { return }

        // Deduplicate against the most recent item
        if let first = items.first, first.text == item.text, first.files == item.files, item.imageFile == nil {
            return
        }
        items.insert(item, at: 0)
        if items.filter({ !$0.isPinned }).count > maxItems,
           let oldest = items.lastIndex(where: { !$0.isPinned }) {
            deleteImage(items[oldest])
            items.remove(at: oldest)
        }
    }

    /// Files first (Finder also puts their names on the pasteboard as text), then an image,
    /// then text.
    private func readItem(types: [NSPasteboard.PasteboardType]) -> ClipboardItem? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let names = urls.map(\.lastPathComponent)
            let text = names.count == 1 ? names[0] : L("\(names[0]) 외 \(names.count - 1)개", "\(names[0]) and \(names.count - 1) more")
            return ClipboardItem(text: text, copiedAt: Date(), kind: .files(urls))
        }
        if let type = [NSPasteboard.PasteboardType.png, .tiff].first(where: types.contains),
           let data = pasteboard.data(forType: type), data.count <= maxImageBytes,
           let image = NSImage(data: data), let item = imageItem(data: data, type: type, image: image) {
            return item
        }
        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ClipboardItem(text: text, copiedAt: Date())
    }

    private func imageItem(data: Data, type: NSPasteboard.PasteboardType, image: NSImage) -> ClipboardItem? {
        let folder = Self.imageFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(UUID().uuidString + (type == .png ? ".png" : ".tiff"))
        guard (try? data.write(to: file)) != nil else { return nil }
        let rep = image.representations.first
        let pixels = CGSize(width: rep?.pixelsWide ?? Int(image.size.width), height: rep?.pixelsHigh ?? Int(image.size.height))
        let label = L("이미지 \(Int(pixels.width))×\(Int(pixels.height))", "Image \(Int(pixels.width))×\(Int(pixels.height))")
        return ClipboardItem(text: label, copiedAt: Date(),
                             kind: .image(file: file, type: type, thumbnail: Self.thumbnail(of: image)))
    }

    /// A 96 pt thumbnail, so the row doesn't hold the full image in memory.
    private static func thumbnail(of image: NSImage) -> NSImage {
        let side: CGFloat = 96
        let scale = min(side / max(image.size.width, 1), side / max(image.size.height, 1), 1)
        let size = NSSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
        let small = NSImage(size: size)
        small.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        small.unlockFocus()
        return small
    }

    private func deleteImage(_ item: ClipboardItem) {
        if let file = item.imageFile { try? FileManager.default.removeItem(at: file) }
    }

    // MARK: - Actions

    func copyToClipboard(_ item: ClipboardItem) {
        guard !DemoMode.isActive else { return }
        pasteboard.clearContents()
        switch item.kind {
        case .text:
            pasteboard.setString(item.text, forType: .string)
        case .files(let urls):
            pasteboard.writeObjects(urls as [NSURL])
        case .image(let file, let type, _):
            if let data = try? Data(contentsOf: file) { pasteboard.setData(data, forType: type) }
        }
        // Update lastChangeCount so our own write doesn't appear as a new item
        lastChangeCount = pasteboard.changeCount
    }

    func remove(_ item: ClipboardItem) {
        deleteImage(item)
        items.removeAll { $0.id == item.id }
    }

    func togglePin(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isPinned.toggle()
    }

    /// Clears everything except pinned items.
    func clearUnpinned() {
        items.filter { !$0.isPinned }.forEach(deleteImage)
        items.removeAll { !$0.isPinned }
    }
}

// MARK: - Demo

extension ClipboardManager {
    /// `--demo`: made-up history; the real pasteboard is never read or written.
    func demoApply(_ items: [ClipboardItem]) {
        self.items = items
    }
}
