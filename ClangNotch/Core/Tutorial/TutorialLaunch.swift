import Foundation

/// What a launch opens: the 튜토리얼, 새로운 점, or nothing. No state of its own, so
/// `tests/TutorialLaunchChecks.swift` runs it.
///
/// The 튜토리얼 comes once: on a first install, and on the first update to a version that has
/// it, where it takes 새로운 점's place and links to it from its last page (user, 2026-11-26).
/// "Once" is a flag, not a version: whoever skips versions still gets it.
enum TutorialLaunch: Equatable {
    case nothing
    case tutorial(linksWhatsNew: Bool)
    case whatsNew

    /// - lastVersion: the version the previous launch recorded; nil on a first install and on
    ///   1.4.0 and older, which recorded none.
    /// - hadSettings: settings from an earlier run were there (tells those two apart).
    /// - tutorialSeen: the 튜토리얼 has been shown before.
    /// - whatsNewAfterUpdate: 설정 -> 정보 -> "업데이트 후 새로운 점 표시"; off, an update
    ///   opens nothing (the 튜토리얼 in 새로운 점's place included). A first install is unaffected.
    /// - forceTutorial / forceWhatsNew: `--tutorial` / `--whats-new`.
    /// A `--demo` launch doesn't get this far (`WhatsNew.showIfUpdated`).
    static func decide(currentVersion: String, lastVersion: String?, hadSettings: Bool, tutorialSeen: Bool,
                       whatsNewAfterUpdate: Bool = true,
                       forceTutorial: Bool = false, forceWhatsNew: Bool = false) -> TutorialLaunch {
        let updated = lastVersion.map { $0 != currentVersion } ?? hadSettings
        let firstInstall = lastVersion == nil && !hadSettings
        if forceTutorial { return .tutorial(linksWhatsNew: updated || forceWhatsNew) }
        if !tutorialSeen, firstInstall { return .tutorial(linksWhatsNew: false) }
        if forceWhatsNew { return .whatsNew }
        guard updated, whatsNewAfterUpdate else { return .nothing }
        if !tutorialSeen { return .tutorial(linksWhatsNew: true) }
        return .whatsNew
    }
}
