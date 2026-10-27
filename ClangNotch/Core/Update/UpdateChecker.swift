import AppKit
import UserNotifications

/// "업데이트 알림 받기": asks GitHub for the latest release at launch and once a day, and
/// posts one notification per newer version. Installing stays manual (the release's DMG).
@MainActor
final class UpdateChecker: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = UpdateChecker()

    /// The newer version on GitHub, if any.
    @Published private(set) var availableVersion: String?
    @Published private(set) var releaseURL = URL(string: "https://github.com/Clang-error/clangnotch/releases/latest")!

    private static let latestReleaseAPI = URL(string: "https://api.github.com/repos/Clang-error/clangnotch/releases/latest")!
    private static let notifiedKey = "notifiedUpdateVersion"
    nonisolated private static let notificationID = "clangnotch-update"
    private var timer: Timer?

    private override init() {}

    func syncWithSettings() {
        timer?.invalidate()
        timer = nil
        guard AppSettings.shared.checkForUpdates else {
            availableVersion = nil
            return
        }
        UNUserNotificationCenter.current().delegate = self
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
            return
        }
        availableVersion = latest
        notifyOnce(latest)
    }

    /// "1.10" > "1.9", "1.1" > "1.0.9"; missing parts count as 0.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private func notifyOnce(_ version: String) {
        guard UserDefaults.standard.string(forKey: Self.notifiedKey) != version else { return }
        UserDefaults.standard.set(version, forKey: Self.notifiedKey)
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = L("ClangNotch \(version)이 나왔습니다", "ClangNotch \(version) is out")
            content.body = L("눌러서 받기", "Click to download")
            center.add(UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: nil))
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.identifier == Self.notificationID else { return }
        _ = await MainActor.run { NSWorkspace.shared.open(UpdateChecker.shared.releaseURL) }
    }

    /// Being the delegate must not hide ClangNotch's other notifications (battery) while it is active.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
