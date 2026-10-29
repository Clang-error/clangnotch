import AppKit
import Combine

@MainActor
final class ClipboardManager: ObservableObject {
    static let shared = ClipboardManager()

    @Published private(set) var items: [ClipboardItem] = []

    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int = -1
    private var timer: Timer?
    private let maxItems = 20

    private init() {
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
        if typeStrings.contains("org.nspasteboard.ConcealedType") ||
           typeStrings.contains("org.nspasteboard.TransientType") { return }

        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Deduplicate against the most recent item
        if items.first?.text == text { return }

        let item = ClipboardItem(text: text, copiedAt: Date())
        items.insert(item, at: 0)
        if items.filter({ !$0.isPinned }).count > maxItems,
           let oldest = items.lastIndex(where: { !$0.isPinned }) {
            items.remove(at: oldest)
        }
    }

    // MARK: - Actions

    func copyToClipboard(_ item: ClipboardItem) {
        guard !DemoMode.isActive else { return }
        pasteboard.clearContents()
        pasteboard.setString(item.text, forType: .string)
        // Update lastChangeCount so our own write doesn't appear as a new item
        lastChangeCount = pasteboard.changeCount
    }

    func remove(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
    }

    func togglePin(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isPinned.toggle()
    }

    /// Clears everything except pinned items.
    func clearUnpinned() {
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
