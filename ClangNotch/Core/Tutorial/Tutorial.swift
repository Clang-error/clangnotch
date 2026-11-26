import AppKit
import SwiftUI

/// The 튜토리얼 window: how to use the notch, in five pages, the first of which picks the app's
/// language (user, 2026-11-26). When it comes is `TutorialLaunch`'s call; 설정 -> 일반 opens it
/// again any time.
@MainActor
final class Tutorial: ObservableObject {
    static let shared = Tutorial()

    private static let seenKey = "tutorialSeen"
    static var seen: Bool { UserDefaults.standard.bool(forKey: seenKey) }

    /// The release's notes for the last page's "새로운 점 보기", once they have come (from the
    /// update check, or GitHub). nil hides the link: offline, the link would lead nowhere.
    @Published private(set) var whatsNewNotes: String?
    private var window: NSWindow?

    private init() {}

    /// `linksWhatsNew`: the update that brought the 튜토리얼 shows it in 새로운 점's place, so its
    /// last page offers the notes.
    func show(linksWhatsNew: Bool) {
        // Counted as seen once it is up, closed early or not: it is offered once.
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        whatsNewNotes = nil
        if linksWhatsNew {
            let version = UpdateChecker.currentVersion
            Task {
                guard let notes = await WhatsNew.notes(for: version), !notes.isEmpty else { return }
                whatsNewNotes = notes
            }
        }
        window?.close()
        let view = TutorialView(tutorial: self) { [weak self] in self?.window?.close() }
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = L("튜토리얼", "Tutorial")
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: TutorialView.size.width, height: TutorialView.size.height))
        window.center()
        self.window = window
        // Once closed, drop the window and its view tree (and the playing clip) for good.
        var closeObserver: NSObjectProtocol?
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            window?.contentViewController = nil
            MainActor.assumeIsolated { if self?.window === window { self?.window = nil } }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// The last page's link: this window gives way to 새로운 점.
    func openWhatsNew() {
        guard let notes = whatsNewNotes else { return }
        window?.close()
        WhatsNew.shared.show(version: UpdateChecker.currentVersion, notes: notes)
    }
}
