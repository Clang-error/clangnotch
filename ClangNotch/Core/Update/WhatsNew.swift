import AppKit
import SwiftUI

/// "새로운 점": a release's notes, once, on the first launch after an update. The notes come
/// from the update check before the restart, or from GitHub by the version's tag when the
/// update came another way (user, 2026-11-12).
@MainActor
final class WhatsNew {
    static let shared = WhatsNew()

    private static let lastLaunchedKey = "lastLaunchedVersion"
    /// [version: notes] of the newer version the update check found.
    private static let savedNotesKey = "updateNotes"
    private var window: NSWindow?

    static func save(_ notes: String, for version: String) {
        UserDefaults.standard.set([version: notes], forKey: savedNotesKey)
    }

    /// At launch. A first install only records its version; `--whats-new` shows it anyway.
    func showIfUpdated() {
        let current = UpdateChecker.currentVersion
        let last = UserDefaults.standard.string(forKey: Self.lastLaunchedKey)
        UserDefaults.standard.set(current, forKey: Self.lastLaunchedKey)
        guard CommandLine.arguments.contains("--whats-new") || (last != nil && last != current) else { return }
        Task {
            guard let notes = await Self.notes(for: current), !notes.isEmpty else { return }
            show(version: current, notes: notes)
        }
    }

    static func notes(for version: String) async -> String? {
        if let saved = (UserDefaults.standard.dictionary(forKey: savedNotesKey) as? [String: String])?[version] {
            return saved
        }
        guard let url = URL(string: "https://api.github.com/repos/Clang-error/clangnotch/releases/tags/v\(version)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["body"] as? String
    }

    private func show(version: String, notes: String) {
        window?.close()
        let view = WhatsNewView(version: version, notes: notes) { [weak self] in self?.window?.close() }
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = L("새로운 점", "What's New")
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 460, height: 520))
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

private struct WhatsNewView: View {
    let version: String
    let notes: String
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                Text(L("ClangNotch \(version)의 새로운 점", "What's new in ClangNotch \(version)"))
                    .font(.title3.weight(.semibold))
            }
            .padding(.top, 28)
            .padding(.bottom, 16)
            ScrollView {
                ReleaseNotesText(notes: notes)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 4)
            }
            Divider()
            HStack {
                Spacer()
                Button(L("확인", "OK"), action: close)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .padding(16)
        }
        .frame(width: 460, height: 520)
    }
}

/// A release's notes, as the releases write them: "- " lines as bullets, "#" lines as
/// headings, the rest as paragraphs; **bold** and `code` inside a line.
struct ReleaseNotesText: View {
    let notes: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("#") {
                    Text(Self.inline(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
                        .font(.headline)
                        .padding(.top, 4)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(Self.inline(String(line.dropFirst(2))))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(Self.inline(line)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private var lines: [String] {
        notes.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
