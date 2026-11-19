import AppKit
import SwiftUI

struct AboutSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var updates = UpdateChecker.shared
    @State private var copied = false
    /// 베타 받기 and 정식으로 되돌리기: the release found (its sheet is up), a look under way, or
    /// what the last look said.
    @State private var offer: UpdateChecker.Offer?
    /// A beta newer than this copy, looked up when the page opens. Without one the 베타 버전 row
    /// doesn't show: on the latest beta there's nothing to get (user, 2026-11-14).
    @State private var newerBeta: UpdateChecker.Offer?
    @State private var findingStable = false
    @State private var stableMessage: String?

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)
                        // The icon file is a full square (macOS 26 masks it itself); give it
                        // the same continuous rounded corners here.
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    Text("ClangNotch")
                        .font(.title2.weight(.semibold))
                    // Click to copy, for bug reports.
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(version, forType: .string)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.2))
                            copied = false
                        }
                    } label: {
                        Text(copied ? L("복사됨", "Copied") : L("버전 \(version)", "Version \(version)"))
                            .monospacedDigit()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(L("눌러서 복사", "Click to copy"))
                    Text(L("개발자 Clang_error", "Developer: Clang_error"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            Section {
                SettingToggle(L("업데이트 자동으로 받기", "Download updates automatically"),
                              L(UpdateChecker.runningBeta
                                    ? "새 버전을 받아 두고 알림. 베타를 쓰는 중이라 새 베타도 받음"
                                    : "새 버전을 받아 두고 알림",
                                UpdateChecker.runningBeta
                                    ? "Downloads a new version and tells you. On a beta, new betas too"
                                    : "Downloads a new version and tells you"),
                              isOn: $settings.checkForUpdates)
                    .onChange(of: settings.checkForUpdates) { _, _ in updates.syncWithSettings() }
                if settings.checkForUpdates {
                    SettingToggle(L("받은 업데이트 자동으로 설치", "Install downloaded updates automatically"),
                                  L("에이전트 세션이 유휴 상태, 노치가 닫혀 있을 때 자동으로 설치.",
                                    "Installs by itself while your agent sessions are idle and the notch is closed."),
                                  isOn: $settings.autoInstallUpdates)
                        .onChange(of: settings.autoInstallUpdates) { _, _ in updates.syncAutoInstall() }
                }
                if let version = updates.readyVersion {
                    HStack {
                        Text(L("새 버전 \(version) 준비됨", "Version \(version) is ready"))
                        Spacer()
                        Button(L("재시작해서 업데이트", "Restart to Update")) { updates.install() }
                            .disabled(updates.isInstalling)
                    }
                } else if let version = updates.availableVersion {
                    HStack {
                        Text(updates.isDownloading
                             ? L("새 버전 \(version) 받는 중…", "Downloading version \(version)…")
                             : L("새 버전 \(version)", "Version \(version) available"))
                        Spacer()
                        // Also the way when this copy can't replace itself (run from a disk image).
                        Button(L("받기", "Download")) { NSWorkspace.shared.open(updates.releaseURL) }
                    }
                }
                // What the newer version brings, folded until opened.
                if updates.availableVersion != nil || updates.readyVersion != nil, let notes = updates.availableNotes {
                    DisclosureGroup(L("변경 사항", "What's new")) {
                        ReleaseNotesText(notes: notes)
                            .font(.callout)
                            .padding(.vertical, 6)
                    }
                }
                if updates.availableVersion == nil && updates.readyVersion == nil {
                    HStack {
                        Text(updates.isChecking ? L("확인 중…", "Checking…")
                             : updates.checkFailed ? L("확인하지 못함. 인터넷 연결을 확인하세요", "Couldn't check. Check your connection")
                             : updates.upToDate ? L("최신 버전입니다", "You're up to date")
                             : L("새 버전 확인", "Check for a new version"))
                        Spacer()
                        Button(L("지금 확인", "Check Now")) { updates.checkNow() }
                            .disabled(updates.isChecking)
                    }
                }
                // 베타 받기: only when a newer beta is out; what it brings, then whether to install it
                // (a user's suggestion, 2026-11-14). A release comes later as a normal update.
                // Not when the update above is that same beta (a beta copy gets the next beta as
                // an update): one row for it is enough.
                if let beta = newerBeta, updates.availableVersion != beta.version, updates.readyVersion != beta.version {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("베타 버전", "Beta"))
                            Text(L("\(beta.version)이 나왔습니다", "\(beta.version) is out"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L("베타 받기", "Get Beta")) {
                            updates.clearOfferInstall()
                            offer = beta
                        }
                        .disabled(findingStable || updates.isDownloading || updates.isInstalling)
                    }
                }
                // 정식으로 되돌리기: only while a beta runs; back to the latest release.
                if UpdateChecker.runningBeta {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("정식 버전", "Release"))
                            Text(findingStable ? L("확인 중…", "Checking…")
                                 : stableMessage ?? L("최신 정식 버전으로 돌아갑니다", "Back to the latest release"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L("정식으로 되돌리기", "Back to Release")) {
                            findingStable = true
                            stableMessage = nil
                            Task {
                                let result = await updates.findStable()
                                findingStable = false
                                switch result {
                                case .found(let found):
                                    updates.clearOfferInstall()
                                    offer = found
                                case .none, .failed:
                                    stableMessage = L("확인하지 못함. 인터넷 연결을 확인하세요", "Couldn't check. Check your connection")
                                }
                            }
                        }
                        .disabled(findingStable || updates.isDownloading || updates.isInstalling)
                    }
                }
            } header: {
                Text(L("업데이트", "Updates"))
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .sheet(item: $offer) { found in
            OfferSheet(offer: found) { offer = nil }
        }
        .task {
            if case .found(let beta) = await updates.findBeta() { newerBeta = beta }
        }
    }
}

/// 베타 받기's and 정식으로 되돌리기's question: the version, what it means, the beta's notes, and
/// go ahead or not.
private struct OfferSheet: View {
    let offer: UpdateChecker.Offer
    let close: () -> Void
    @ObservedObject private var updates = UpdateChecker.shared
    /// This copy can put an update in place itself; otherwise the release page is the way.
    private let installsHere: Bool

    init(offer: UpdateChecker.Offer, close: @escaping () -> Void) {
        self.offer = offer
        self.close = close
        installsHere = offer.image != nil && UpdateInstaller.runningDeveloperIDTeam() != nil
            && UpdateInstaller.canReplaceRunningApp()
    }

    private var back: Bool { offer.kind == .stable }
    private var downloading: Bool { updates.offerInstall == .downloading }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                Text(back ? L("정식 \(offer.version)으로 되돌리기", "Back to \(offer.version)") : "ClangNotch \(offer.version)")
                    .font(.title3.weight(.semibold))
                Text(back
                     ? L("베타 \(UpdateChecker.currentVersion)에서 정식 \(offer.version)으로 돌아갑니다. 베타에서만 있던 기능은 제거됩니다.",
                         "From beta \(UpdateChecker.currentVersion) back to \(offer.version). What only the beta had is removed.")
                     : L("시험판이라 문제가 있을 수 있습니다.",
                         "A test version, so something may break."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 24)
            .padding(.horizontal, 28)
            .padding(.bottom, 14)
            if back {
                Spacer(minLength: 0)
            } else {
                Text(L("이 베타에 들어간 내용", "What's in this beta"))
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28)
                ScrollView {
                    ReleaseNotesText(notes: offer.notes.isEmpty ? L("적힌 변경 사항이 없습니다.", "No notes were written for it.") : offer.notes)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 8)
                }
            }
            Divider()
            HStack(spacing: 8) {
                if case .failed(let message) = updates.offerInstall {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if downloading {
                    ProgressView().controlSize(.small)
                    Text(L("받는 중…", "Downloading…")).font(.caption)
                }
                Spacer()
                Button(L("취소", "Cancel"), action: close)
                    .keyboardShortcut(.cancelAction)
                    .disabled(downloading)
                if installsHere, updates.offerInstall == .idle || downloading {
                    Button(back ? L("되돌리고 재시작", "Go Back and Restart") : L("설치하고 재시작", "Install and Restart")) {
                        updates.installOffer(offer)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(downloading)
                } else {
                    Button(L("릴리스 페이지에서 받기", "Get It on the Release Page")) {
                        NSWorkspace.shared.open(offer.page)
                        close()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 460, height: back ? 290 : 500)
    }
}
