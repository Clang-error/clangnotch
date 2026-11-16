import AppKit
import UserNotifications

/// "업데이트 자동으로 받기": asks GitHub for the latest release at launch and once a day.
/// A newer one is downloaded and checked in the background (`UpdateInstaller`), then waits
/// for "재시작해서 업데이트" in the notification or in 설정 › 정보. A copy that can't replace
/// itself, or a release that doesn't check out, falls back to the release page.
/// A copy that is itself a beta looks at the newest release of either kind, so the next beta
/// reaches it the same way (2026-11-16: only for copies on a beta, and never installed unasked);
/// a release copy is only ever told about releases.
@MainActor
final class UpdateChecker: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = UpdateChecker()

    /// The newer version on GitHub, if any.
    @Published private(set) var availableVersion: String?
    /// Its release notes, for 설정 › 정보 › 변경 사항 (and 새로운 점 after the restart).
    @Published private(set) var availableNotes: String?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
    /// The newer version, downloaded and checked, waiting for a restart.
    @Published private(set) var readyVersion: String?
    @Published private(set) var isDownloading = false
    @Published private(set) var isInstalling = false
    /// For "지금 확인" in 설정 › 정보: a check under way, the last one finding nothing newer, or failing.
    @Published private(set) var isChecking = false
    @Published private(set) var upToDate = false
    @Published private(set) var checkFailed = false
    @Published private(set) var releaseURL = URL(string: "https://github.com/Clang-error/clangnotch/releases/latest")!

    private static let latestReleaseAPI = URL(string: "https://api.github.com/repos/Clang-error/clangnotch/releases/latest")!
    private static let notifiedKey = "notifiedUpdateVersion"
    private static let notifiedReadyKey = "notifiedReadyUpdateVersion"
    /// A release whose download didn't check out; it isn't fetched again.
    private static let rejectedKey = "rejectedUpdateVersion"
    nonisolated private static let notificationID = "clangnotch-update"
    nonisolated private static let readyCategory = "clangnotch-update-ready"
    nonisolated private static let installAction = "install"
    private var timer: Timer?

    private override init() {}

    #if DEBUG
    /// `--update-preview`: a made-up newer version with these notes, to look at 변경 사항.
    /// `--update-preview ready`: as if it were downloaded too, to look at the buttons that install.
    func preview(notes: String, ready: Bool) {
        availableVersion = "9.9.9"
        availableNotes = notes
        if ready { readyVersion = "9.9.9" }
    }
    #endif

    func syncWithSettings() {
        timer?.invalidate()
        timer = nil
        guard AppSettings.shared.checkForUpdates else {
            availableVersion = nil
            readyVersion = nil
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(
            identifier: Self.readyCategory,
            actions: [UNNotificationAction(identifier: Self.installAction,
                                           title: L("재시작해서 업데이트", "Restart to Update"))],
            intentIdentifiers: [])])
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { _ in
            Task { @MainActor in await UpdateChecker.shared.check() }
        }
        Task { await check() }
    }

    /// "지금 확인": asks GitHub now, with 자동으로 받기 off too. Off, a newer version is only shown
    /// with its 받기 button; on, it is fetched as in the daily check.
    func checkNow() {
        guard !isChecking else { return }
        Task { await check(manual: true) }
    }

    private func check(manual: Bool = false) async {
        isChecking = true
        defer { isChecking = false }
        let found: [String: Any]?
        if Self.runningBeta {
            found = (await Self.fetchJSON(Self.releasesAPI) as? [[String: Any]]).flatMap(Self.newestRelease(in:))
        } else {
            found = await Self.fetchJSON(Self.latestReleaseAPI) as? [String: Any]
        }
        guard let json = found, let tag = json["tag_name"] as? String else {
            checkFailed = true
            upToDate = false
            return
        }
        checkFailed = false
        let automatic = AppSettings.shared.checkForUpdates
        guard automatic || manual else { return }

        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let current = Self.currentVersion
        if let page = (json["html_url"] as? String).flatMap(URL.init(string:)) { releaseURL = page }
        guard Self.isNewer(latest, than: current) else {
            availableVersion = nil
            availableNotes = nil
            readyVersion = nil
            upToDate = true
            return
        }
        upToDate = false
        availableVersion = latest
        availableNotes = (json["body"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let notes = availableNotes { WhatsNew.save(notes, for: latest) }
        // Asked for by hand with 자동으로 받기 off: shown, not fetched.
        guard automatic else { return }
        guard readyVersion != latest, !isDownloading else { return }

        if let team = UpdateInstaller.runningDeveloperIDTeam(), UpdateInstaller.canReplaceRunningApp(),
           UserDefaults.standard.string(forKey: Self.rejectedKey) != latest,
           let asset = Self.diskImage(in: json) {
            isDownloading = true
            let outcome = await Task.detached(priority: .utility) { () -> Result<Void, Error> in
                // Already fetched on an earlier check, or after a relaunch that didn't install it.
                if UpdateInstaller.hasStagedUpdate(version: latest, team: team) { return .success(()) }
                do {
                    try await UpdateInstaller.prepare(from: asset, version: latest, team: team)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value
            isDownloading = false
            // Turned off while it was downloading.
            guard AppSettings.shared.checkForUpdates else { return }
            switch outcome {
            case .success where availableVersion == latest:
                readyVersion = latest
                notifyOnce(latest, ready: true)
                return
            case .failure(let error as UpdateInstaller.Rejected):
                debugLog("[Update] \(latest) doesn't check out: \(error)")
                UserDefaults.standard.set(latest, forKey: Self.rejectedKey)
            case .failure(let error):
                debugLog("[Update] \(latest) not downloaded this time: \(error)")
            default:
                break
            }
        }
        notifyOnce(latest, ready: false)
    }

    /// "재시작해서 업데이트". If the staged app no longer checks out, the release page instead.
    /// With nothing ready yet (a notification from before a relaunch), 설정 › 정보.
    func install() {
        guard let version = readyVersion, let team = UpdateInstaller.runningDeveloperIDTeam() else {
            ClangNotchAppDelegate.shared?.showSettingsWindow(page: .about)
            return
        }
        guard !isInstalling else { return }
        isInstalling = true
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try UpdateInstaller.install(version: version, team: team) }
            }.value
            isInstalling = false
            switch outcome {
            case .success(true):
                Self.quitForRelaunch()
            case .success(false):
                // In place, but nothing to reopen it: the new version runs from the next launch.
                debugLog("[Update] \(version) installed; the relaunch helper didn't start")
                readyVersion = nil
            case .failure(let error):
                debugLog("[Update] install of \(version) stopped: \(error)")
                readyVersion = nil
                NSWorkspace.shared.open(releaseURL)
            }
        }
    }

    /// Quits so the relaunch helper can open the version just put in place. AppKit doesn't quit
    /// while a window has a sheet attached: the beta's sheet in 설정 › 정보 kept the old copy running,
    /// "받는 중…" and all, with the new one already in place (2026-11-14). Sheets are closed first,
    /// and a quit that still hasn't happened after 5 s is forced, since the helper waits on it.
    private static func quitForRelaunch() {
        for window in NSApp.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(0) }
    }

    /// The release's disk image (`ClangNotch.dmg`).
    private static func diskImage(in release: [String: Any]) -> URL? {
        (release["assets"] as? [[String: Any]])?
            .first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }
            .flatMap { $0["browser_download_url"] as? String }
            .flatMap(URL.init(string:))
            .flatMap { $0.scheme == "https" ? $0 : nil }
    }

    /// The newest release in GitHub's list that isn't a draft, beta or not: what a beta copy
    /// compares itself with.
    nonisolated static func newestRelease(in releases: [[String: Any]]) -> [String: Any]? {
        releases
            .filter { $0["draft"] as? Bool != true && $0["tag_name"] is String }
            .max { AppVersion($0["tag_name"] as? String ?? "") < AppVersion($1["tag_name"] as? String ?? "") }
    }

    /// "1.10" > "1.9", "1.4.1" > "1.4.1-beta.3" > "1.4.0" (`AppVersion`).
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        AppVersion(a) > AppVersion(b)
    }

    // MARK: - Beta and back

    /// A release offered in 설정 › 정보: a beta newer than this copy ("베타 받기"), or, while a beta
    /// runs, the latest release to go back to ("정식으로 되돌리기").
    struct Offer: Identifiable {
        enum Kind { case beta, stable }
        let kind: Kind
        let version: String
        let notes: String
        let image: URL?
        let page: URL
        var id: String { version }
    }

    enum OfferSearch {
        case found(Offer)
        case none
        case failed
    }

    /// Fetching and putting an offer in place; `failed` keeps what went wrong for the sheet.
    enum OfferInstall: Equatable {
        case idle
        case downloading
        case failed(String)
    }
    @Published private(set) var offerInstall: OfferInstall = .idle

    private static let releasesAPI = URL(string: "https://api.github.com/repos/Clang-error/clangnotch/releases?per_page=20")!

    /// This copy is a beta, so "정식으로 되돌리기" applies.
    static var runningBeta: Bool { AppVersion(currentVersion).isBeta }

    /// The newest beta on GitHub (a pre-release, not a draft) that is newer than this copy. Nothing
    /// is downloaded until it is installed.
    func findBeta() async -> OfferSearch {
        guard let releases = await Self.fetchJSON(Self.releasesAPI) as? [[String: Any]] else { return .failed }
        let current = AppVersion(Self.currentVersion)
        let betas: [(AppVersion, [String: Any])] = releases.compactMap { release in
            guard release["prerelease"] as? Bool == true, release["draft"] as? Bool != true,
                  let tag = release["tag_name"] as? String else { return nil }
            let version = AppVersion(tag)
            return version.isBeta && version > current ? (version, release) : nil
        }
        guard let (_, release) = betas.max(by: { $0.0 < $1.0 }) else { return .none }
        return Self.offer(.beta, from: release).map(OfferSearch.found) ?? .failed
    }

    /// The release GitHub marks as the latest, to go back to from a beta.
    func findStable() async -> OfferSearch {
        guard let release = await Self.fetchJSON(Self.latestReleaseAPI) as? [String: Any] else { return .failed }
        return Self.offer(.stable, from: release).map(OfferSearch.found) ?? .failed
    }

    private static func fetchJSON(_ url: URL) async -> Any? {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func offer(_ kind: Offer.Kind, from release: [String: Any]) -> Offer? {
        guard let tag = release["tag_name"] as? String else { return nil }
        let page = (release["html_url"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/Clang-error/clangnotch/releases")!
        return Offer(kind: kind, version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                     notes: release["body"] as? String ?? "", image: diskImage(in: release), page: page)
    }

    /// Downloads the offer, checks it as any update is checked (`UpdateInstaller.verify`; going back
    /// to the latest release may go to a lower version, only that way and only when asked), puts it
    /// in place and restarts. A copy that can't replace itself (a development build, one run from a
    /// disk image) gets the release page instead.
    func installOffer(_ offer: Offer) {
        guard offerInstall != .downloading, !isDownloading, !isInstalling else { return }
        guard let team = UpdateInstaller.runningDeveloperIDTeam(), UpdateInstaller.canReplaceRunningApp(),
              let image = offer.image else {
            NSWorkspace.shared.open(offer.page)
            return
        }
        offerInstall = .downloading
        let back = offer.kind == .stable
        if back {
            // Going back isn't news: no 새로운 점 for the older version after the restart.
            WhatsNew.markSeen(offer.version)
        } else if !offer.notes.isEmpty {
            WhatsNew.save(offer.notes, for: offer.version)
        }
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<Bool, Error> in
                do {
                    try await UpdateInstaller.prepare(from: image, version: offer.version, team: team, allowOlder: back)
                    return .success(try UpdateInstaller.install(version: offer.version, team: team, allowOlder: back))
                } catch {
                    return .failure(error)
                }
            }.value
            switch outcome {
            case .success(true):
                Self.quitForRelaunch()
            case .success(false):
                // In place, but nothing reopened it: it runs from the next launch.
                offerInstall = .failed(L("설치했지만 다시 열지 못했습니다. ClangNotch를 다시 실행하세요.",
                                         "Installed, but it couldn't reopen. Open ClangNotch again."))
            case .failure(let error):
                debugLog("[Update] \(offer.version) not installed: \(error)")
                offerInstall = .failed(L("설치하지 못했습니다. 릴리스 페이지에서 받으세요.",
                                         "Couldn't install it. Get it from the release page."))
            }
        }
    }

    func clearOfferInstall() { if offerInstall != .downloading { offerInstall = .idle } }

    /// One notification per version: when it is downloaded and ready, or, when it can't be
    /// installed from here, when it is out.
    private func notifyOnce(_ version: String, ready: Bool) {
        let key = ready ? Self.notifiedReadyKey : Self.notifiedKey
        guard UserDefaults.standard.string(forKey: key) != version else { return }
        UserDefaults.standard.set(version, forKey: key)
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = L("ClangNotch \(version)이 나왔습니다", "ClangNotch \(version) is out")
            if ready {
                content.body = L("받아 두었습니다. 재시작하면 바뀝니다", "Downloaded. Restart to put it in place")
                content.categoryIdentifier = Self.readyCategory
            } else {
                content.body = L("눌러서 받기", "Click to download")
            }
            center.add(UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: nil))
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// The button installs; clicking the notification itself shows 설정 › 정보 when an update
    /// is ready there, else the release page.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.identifier == Self.notificationID else { return }
        let action = response.actionIdentifier
        await MainActor.run {
            let checker = UpdateChecker.shared
            if action == Self.installAction {
                checker.install()
            } else if checker.readyVersion != nil, let delegate = ClangNotchAppDelegate.shared {
                delegate.showSettingsWindow(page: .about)
            } else {
                NSWorkspace.shared.open(checker.releaseURL)
            }
        }
    }

    /// Being the delegate must not hide ClangNotch's other notifications (battery) while it is active.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
