import SwiftUI

@main
struct ClangNotchApp: App {
    @NSApplicationDelegateAdaptor(ClangNotchAppDelegate.self) var appDelegate

    // Everything lives in the notch panel and the menu bar item; the settings window is
    // `ClangNotchAppDelegate.showSettingsWindow`. An accessory app has no ⌘, to open this.
    var body: some Scene {
        Settings { EmptyView() }
    }
}
