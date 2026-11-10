import AppKit
import UserNotifications

/// "업데이트 자동으로 받기": asks GitHub for the latest release at launch and once a day.
/// A newer one is downloaded and checked in the background (`UpdateInstaller`), then waits
/// for "재시작해서 업데이트" in the notification or in 설정 › 정보. A copy that can't replace
/// itself, or a release that doesn't check out, falls back to the release page.
@MainActor
final class UpdateChecker: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = UpdateChecker()

    /// The newer version on GitHub, if any.
    @Published private(set) var availableVersion: String?
    /// The newer version, downloaded and checked, waiting for a restart.
    @Published private(set) var readyVersion: String?
    @Published private(set) var isDownloading = false
    @Published private(set) var isInstalling = false
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

    private func check() async {
        var request = URLRequest(url: Self.latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              AppSettings.shared.checkForUpdates
        else { return }

        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        if let page = (json["html_url"] as? String).flatMap(URL.init(string:)) { releaseURL = page }
        guard Self.isNewer(latest, than: current) else {
            availableVersion = nil
            readyVersion = nil
            return
        }
        availableVersion = latest
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
            (NSApp.delegate as? ClangNotchAppDelegate)?.showSettingsWindow(page: .about)
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
                NSApp.terminate(nil)
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

    /// The release's disk image (`ClangNotch.dmg`).
    private static func diskImage(in release: [String: Any]) -> URL? {
        (release["assets"] as? [[String: Any]])?
            .first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }
            .flatMap { $0["browser_download_url"] as? String }
            .flatMap(URL.init(string:))
            .flatMap { $0.scheme == "https" ? $0 : nil }
    }

    /// "1.10" > "1.9", "1.1" > "1.0.9"; missing parts count as 0.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

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
                content.body = L("받아 두었습니다 · 재시작하면 바뀝니다", "Downloaded · restart to put it in place")
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
            } else if checker.readyVersion != nil, let delegate = NSApp.delegate as? ClangNotchAppDelegate {
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
