import Foundation
import Security

/// Downloads a release and swaps it in for the running app. Nothing is put in place unless
/// the new app is ClangNotch, the release's version, signed with a Developer ID of the same
/// team as the running app, and accepted by Gatekeeper as notarized. Anything less leaves
/// the update to the release page.
enum UpdateInstaller {
    /// Something went wrong on the way (network, disk image); a later try may work.
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// The release itself doesn't check out. Fetching it again won't change that.
    struct Rejected: Error, CustomStringConvertible {
        let description: String
    }

    /// Where a checked update waits for the restart. Spotlight skips a `.noindex` folder, so
    /// the copy never shows up as a second ClangNotch in the app list.
    static var stagingFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.clangerror.ClangNotch/Update.noindex")
    }

    static var stagedApp: URL { stagingFolder.appendingPathComponent("ClangNotch.app") }

    /// Whether this copy can replace itself: not run from a disk image or by App
    /// Translocation (both read-only), and in a folder it may write to.
    static func canReplaceRunningApp() -> Bool {
        let app = Bundle.main.bundleURL
        guard !app.path.contains("/AppTranslocation/"),
              (try? app.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) != true else { return false }
        return FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path)
            && FileManager.default.isWritableFile(atPath: app.path)
    }

    /// The running app's team, when the app is itself signed with a Developer ID. A
    /// development build (Apple Development, ad hoc) gets nil and never updates itself: it
    /// would replace itself with a release, and it shares the staging folder with the
    /// installed app.
    static func runningDeveloperIDTeam() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              let requirement = developerIDRequirement(team: team),
              SecStaticCodeCheckValidity(staticCode, [], requirement) == errSecSuccess else { return nil }
        return team
    }

    /// Downloads the release's disk image, checks the app in it and leaves that app at
    /// `stagedApp`. Blocking work; call it off the main thread.
    static func prepare(from asset: URL, version: String, team: String) async throws {
        let fm = FileManager.default
        detachLeftovers()
        try? fm.removeItem(at: stagingFolder)
        try fm.createDirectory(at: stagingFolder, withIntermediateDirectories: true)

        let (download, response) = try await URLSession.shared.download(from: asset)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure(description: "download answered \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let image = stagingFolder.appendingPathComponent("ClangNotch.dmg")
        try fm.moveItem(at: download, to: image)
        defer { try? fm.removeItem(at: image) }

        let mount = stagingFolder.appendingPathComponent("mount-\(UUID().uuidString)")
        let device = try attach(image, at: mount)
        defer { detach(device) }

        // ditto keeps the bundle exactly as signed.
        try run("/usr/bin/ditto", [mount.appendingPathComponent("ClangNotch.app").path, stagedApp.path])
        do {
            try verify(stagedApp, version: version, team: team)
        } catch {
            try? fm.removeItem(at: stagedApp)
            throw error
        }
        unregister(stagedApp)
    }

    /// The staged update, if one for `version` is there and still checks out.
    static func stagedUpdate(version: String, team: String) -> URL? {
        guard FileManager.default.fileExists(atPath: stagedApp.path),
              (try? verify(stagedApp, version: version, team: team)) != nil else { return nil }
        unregister(stagedApp)
        return stagedApp
    }

    /// Keeps the waiting copy from counting as a second installed ClangNotch: LaunchServices
    /// had registered it in testing (2026-11-10), `.noindex` or not.
    private static func unregister(_ app: URL) {
        _ = try? run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                     ["-u", app.path], allowFailure: true)
    }

    /// Puts the staged app where the running one is and starts a helper that opens it once
    /// this process has exited. Throws, with nothing replaced, when the copy doesn't check
    /// out. Returns false when the app was replaced but the helper didn't start: the new
    /// version then runs from the next launch. Blocking work; call it off the main thread.
    static func install(version: String, team: String) throws -> Bool {
        let fm = FileManager.default
        let target = Bundle.main.bundleURL
        // A fresh folder of our own on the target's volume: swapping is atomic only within a
        // volume, and nothing can be waiting at a path nobody knew in advance.
        let scratch = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        defer { try? fm.removeItem(at: scratch) }
        let incoming = scratch.appendingPathComponent("ClangNotch.app")
        try run("/usr/bin/ditto", [stagedApp.path, incoming.path])
        // The copy that goes in is the one checked.
        try verify(incoming, version: version, team: team)
        _ = try fm.replaceItemAt(target, withItemAt: incoming)
        try? fm.removeItem(at: stagingFolder)

        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while /bin/kill -0 \"$0\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$1\"",
                              String(ProcessInfo.processInfo.processIdentifier), target.path]
        return (try? relaunch.run()) != nil
    }

    // MARK: - Checks

    /// Everything that has to hold before an app may replace this one.
    static func verify(_ app: URL, version: String, team: String) throws {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw Rejected(description: "not ClangNotch")
        }
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        guard let found = info["CFBundleShortVersionString"] as? String, found == version,
              UpdateChecker.isNewer(found, than: current) else {
            throw Rejected(description: "version \(info["CFBundleShortVersionString"] ?? "?") is not the newer \(version)")
        }
        // A valid signature, all of it, by a Developer ID of the running app's team.
        var code: SecStaticCode?
        guard let requirement = developerIDRequirement(team: team),
              SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw Rejected(description: "can't read the signature")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else { throw Rejected(description: "signature check failed (\(status))") }
        // Notarized: Apple has checked this build. Gatekeeper reads the stapled ticket.
        let verdict = try run("/usr/sbin/spctl", ["--assess", "--type", "execute", "-vv", app.path], allowFailure: true)
        guard verdict.status == 0, verdict.output.contains("source=Notarized Developer ID") else {
            throw Rejected(description: "Gatekeeper: \(verdict.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// Signed for this bundle identifier by a Developer ID of `team`: the two certificate
    /// fields mark a Developer ID's intermediate and leaf.
    private static func developerIDRequirement(team: String) -> SecRequirement? {
        guard let identifier = Bundle.main.bundleIdentifier, !team.isEmpty,
              team.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        let text = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
            + " and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]"
        var requirement: SecRequirement?
        return SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess ? requirement : nil
    }

    // MARK: - Disk images

    /// Attaches by a mount point of its own and returns the image's device, which detaches
    /// it even when the mount point can't.
    private static func attach(_ image: URL, at mount: URL) throws -> String {
        let result = try run("/usr/bin/hdiutil", ["attach", image.path, "-nobrowse", "-readonly", "-noautoopen",
                                                  "-mountpoint", mount.path, "-plist"], stdoutOnly: true)
        guard let plist = try? PropertyListSerialization.propertyList(from: Data(result.output.utf8), format: nil) as? [String: Any],
              let device = wholeDisk(plist["system-entities"]) else {
            throw Failure(description: "hdiutil attached nothing")
        }
        return device
    }

    private static func detach(_ device: String) {
        _ = try? run("/usr/bin/hdiutil", ["detach", device, "-force", "-quiet"], allowFailure: true)
    }

    /// Images an earlier run left attached when it quit before detaching them.
    private static func detachLeftovers() {
        guard let info = try? run("/usr/bin/hdiutil", ["info", "-plist"], allowFailure: true, stdoutOnly: true),
              let plist = try? PropertyListSerialization.propertyList(from: Data(info.output.utf8), format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return }
        for image in images where (image["image-path"] as? String)?.hasPrefix(stagingFolder.path) == true {
            if let device = wholeDisk(image["system-entities"]) { detach(device) }
        }
    }

    /// "/dev/disk5" of "/dev/disk5", "/dev/disk5s1".
    private static func wholeDisk(_ entities: Any?) -> String? {
        (entities as? [[String: Any]])?.compactMap { $0["dev-entry"] as? String }.min { $0.count < $1.count }
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String], allowFailure: Bool = false,
                            stdoutOnly: Bool = false) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = stdoutOnly ? FileHandle.nullDevice : pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard allowFailure || process.terminationStatus == 0 else {
            throw Failure(description: "\(URL(fileURLWithPath: executable).lastPathComponent) failed: \(output)")
        }
        return (process.terminationStatus, output)
    }
}
