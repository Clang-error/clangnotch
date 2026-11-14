import AppKit

/// One ClangNotch at a time: a beta opened next to the installed release ran both, two notches and
/// two hook receivers (a user's report, 2026-11-14). The newer version stays: a newer copy asks the
/// one already running to quit; an older or the same one brings the running one forward and quits.
/// Release builds only, so the development copies other work runs side by side are left alone.
enum SingleInstance {
    /// At launch, before anything starts. True when this copy should quit.
    @MainActor
    static func thisCopyShouldQuit() -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        guard let other = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first(where: { $0.processIdentifier != me && !$0.isTerminated }) else { return false }
        let theirs = other.bundleURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
        guard let theirs, AppVersion(UpdateChecker.currentVersion) > AppVersion(theirs) else {
            other.activate()
            return true
        }
        // Newer here: the other one goes. Its port (4318) and notch are free once it has quit.
        other.terminate()
        let deadline = Date().addingTimeInterval(5)
        while !other.isTerminated, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }
}
