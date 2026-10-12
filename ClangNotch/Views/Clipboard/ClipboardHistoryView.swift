import SwiftUI

struct ClipboardHistoryView: View {
    @ObservedObject var manager: ClipboardManager

    var body: some View {
        VStack(spacing: 0) {
            if manager.items.isEmpty {
                Spacer(minLength: 0)
                Text("No clipboard history yet")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
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

    @State private var isPressed = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(item.text)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(relativeTime(item.copiedAt))
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.35))
                .padding(.top, 1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isPressed ? Color.white.opacity(0.12) : Color.white.opacity(0.06))
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture { onTap() }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .padding(.horizontal, 4)
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }
}
