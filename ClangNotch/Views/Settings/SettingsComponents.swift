import AppKit
import SwiftUI

/// A row of small pictures to pick one from, the picked one ringed in the accent colour, as
/// 노치 색's tiles. The settings text under a choice is its picture and a word, not a sentence.
struct PictureChoice<Value: Hashable, Tile: View>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    @ViewBuilder let tile: (Value) -> Tile

    var body: some View {
        HStack(spacing: 14) {
            ForEach(options, id: \.value) { option in
                let selected = selection == option.value
                Button { selection = option.value } label: {
                    VStack(spacing: 6) {
                        tile(option.value)
                            .frame(width: 92, height: 60)
                            .padding(3)
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5))
                        Text(option.title)
                            .font(.callout.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? .primary : .secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}

/// A switch with what it does in one line under it, so no setting needs a paragraph.
struct SettingToggle: View {
    let title: String
    let caption: String
    @Binding var isOn: Bool

    /// No caption where the title says it all.
    init(_ title: String, _ caption: String = "", isOn: Binding<Bool>) {
        self.title = title
        self.caption = caption
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if !caption.isEmpty {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
