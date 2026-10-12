import SwiftUI

struct ClipboardHistoryView: View {
    @ObservedObject var manager: ClipboardManager

    var body: some View {
        VStack(spacing: 0) {
            if manager.items.isEmpty {
                Spacer(minLength: 0)
                Text("클립보드 기록 없음")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(manager.items) { item in
                            ClipboardRowView(item: item) {
                                manager.copyToClipboard(item)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ClipboardRowView: View {
    let item: ClipboardItem
    let onTap: () -> Void

    @State private var copied = false
    @State private var copiedResetTask: Task<Void, Never>?

    var body: some View {
        Button {
            onTap()
            showCopied()
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Text(item.text)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if copied {
                    Label("복사됨", systemImage: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(NotchPalette.accent)
                        .padding(.top, 1)
                } else {
                    Text(relativeTime(item.copiedAt))
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.top, 1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .buttonStyle(NotchHoverButtonStyle(cornerRadius: 6, base: 0.06))
        .padding(.horizontal, 4)
    }

    private func showCopied() {
        copiedResetTask?.cancel()
        copied = true
        copiedResetTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "방금" }
        if seconds < 3600 { return "\(seconds / 60)분 전" }
        return "\(seconds / 3600)시간 전"
    }
}
