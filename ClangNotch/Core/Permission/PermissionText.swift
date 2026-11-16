import Foundation

/// What the 권한 드롭다운 shows of a request. Anything that would not show in full is opened
/// with 전체 보기 and read to its end before 허용 works, and characters that draw nothing are
/// spelled out, so what runs can't hide behind blank lines, a cut-off middle or an invisible
/// character.
struct PermissionText: Equatable {
    static let wholeLines = 3
    static let wholeCharacters = 180
    static let previewLines = 2
    static let lineCut = 70
    /// Past this the notch only offers the agent's own prompt; drawing it all would stall the notch.
    static let maxCharacters = 20_000

    /// The text, trimmed, with invisible characters as `⟨U+XXXX⟩` (only its start when too long).
    let full: String
    /// Its lines, a run of blank ones folded into one `⟨빈 줄 N개⟩`.
    let lines: [String]
    let isTooLong: Bool

    init(_ raw: String) {
        isTooLong = raw.utf8.count > Self.maxCharacters
        full = Self.visible(isTooLong ? String(raw.prefix(2_000)) : raw).trimmingCharacters(in: .whitespacesAndNewlines)
        lines = Self.foldingBlankRuns(full.components(separatedBy: "\n"))
    }

    /// Fits the dropdown as is; shown without a line limit, so wrapping hides nothing.
    var isWhole: Bool { !isTooLong && lines.count <= Self.wholeLines && full.count <= Self.wholeCharacters }

    /// The first lines of one that doesn't, each cut here rather than by the layout.
    var preview: [String] {
        lines.prefix(Self.previewLines).map { $0.count > Self.lineCut ? $0.prefix(Self.lineCut) + "…" : $0 }
    }

    /// Controls (but newline and tab), format characters (zero-width, direction overrides),
    /// line or paragraph separators, default-ignorable ones (Hangul fillers, variation
    /// selectors) and the blank braille pattern become visible.
    static func visible(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let hidden: Bool
            switch scalar.properties.generalCategory {
            case .control: hidden = scalar != "\n" && scalar != "\t"
            case .format, .lineSeparator, .paragraphSeparator: hidden = true
            default: hidden = scalar.properties.isDefaultIgnorableCodePoint || scalar == "\u{2800}"
            }
            if hidden {
                out.append(contentsOf: String(format: "⟨U+%04X⟩", scalar.value).unicodeScalars)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    private static func foldingBlankRuns(_ lines: [String]) -> [String] {
        var out: [String] = []
        var blanks = 0
        func flush() {
            if blanks == 1 { out.append("") }
            if blanks > 1 { out.append(L("⟨빈 줄 \(blanks)개⟩", "⟨\(blanks) blank lines⟩")) }
            blanks = 0
        }
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                blanks += 1
            } else {
                flush()
                out.append(line)
            }
        }
        flush()
        return out
    }
}
