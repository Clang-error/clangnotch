import SwiftUI

struct ClipboardHistoryView: View {
    @ObservedObject var manager: ClipboardManager

    /// Pinned first, each part newest first.
    private var orderedItems: [ClipboardItem] {
        manager.items.filter(\.isPinned) + manager.items.filter { !$0.isPinned }
    }

    var body: some View {
        VStack(spacing: 0) {
            if manager.items.isEmpty {
                Spacer(minLength: 0)
                VStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 22, weight: .light))
                        .foregroundColor(.white.opacity(0.3))
                    Text(L("클립보드 기록 없음", "No clipboard history yet"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                    Text(L("글을 복사하면 여기에 쌓입니다. 누르면 다시 복사합니다.", "Text you copy collects here. Click one to copy it again."))
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.35))
                }
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(orderedItems) { item in
                            ClipboardRowView(item: item, manager: manager) {
                                manager.copyToClipboard(item)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .animation(.spring(response: 0.3, dampingFraction: 0.85), value: manager.items)
                }
                footer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Count on the left, clear on the right (pins stay), like cyclop's clipboard footer.
    private var footer: some View {
        HStack {
            Text(L("\(manager.items.count)개", "\(manager.items.count) items"))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundColor(.white.opacity(0.4))
            Spacer()
            if manager.items.contains(where: { !$0.isPinned }) {
                Button(manager.items.contains(where: \.isPinned) ? L("고정 빼고 지우기", "Clear unpinned") : L("모두 지우기", "Clear all")) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { manager.clearUnpinned() }
                }
                .buttonStyle(NotchPressButtonStyle())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }
}

private struct ClipboardRowView: View {
    let item: ClipboardItem
    let manager: ClipboardManager
    let onTap: () -> Void

    @State private var copied = false
    @State private var hovering = false
    @State private var copiedResetTask: Task<Void, Never>?

    var body: some View {
        Button {
            onTap()
            showCopied()
        } label: {
            HStack(alignment: .top, spacing: 8) {
                if item.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.top, 2)
                }
                Text(item.text)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if copied {
                    Label(L("복사됨", "Copied"), systemImage: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(NotchPalette.accent)
                        .padding(.top, 1)
                } else if hovering {
                    // Room for the pin/delete buttons laid over this corner below.
                    Color.clear.frame(width: 42, height: 14)
                } else {
                    Text(relativeTime(item.copiedAt))
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.top, 1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .notchCard(cornerRadius: 8)
        }
        .buttonStyle(NotchHoverButtonStyle(cornerRadius: 8))
        // Pin and delete appear only under the cursor (cyclop). Laid over the row, not
        // nested in its button, so their clicks never also copy the item.
        .overlay(alignment: .topTrailing) {
            if hovering && !copied {
                HStack(spacing: 2) {
                    rowAction(item.isPinned ? "pin.slash" : "pin",
                              help: item.isPinned ? L("고정 풀기", "Unpin") : L("고정", "Pin")) {
                        manager.togglePin(item)
                    }
                    rowAction("xmark", help: L("지우기", "Delete")) {
                        manager.remove(item)
                    }
                }
                .padding(.top, 3)
                .padding(.trailing, 6)
            }
        }
        .padding(.horizontal, 4)
        .onHover { hovering = $0 }
    }

    private func rowAction(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressButtonStyle())
        .help(help)
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
        if seconds < 60 { return L("방금", "now") }
        if seconds < 3600 { return L("\(seconds / 60)분 전", "\(seconds / 60)m ago") }
        return L("\(seconds / 3600)시간 전", "\(seconds / 3600)h ago")
    }
}
