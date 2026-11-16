import Foundation

@main
struct PermissionTextChecks {
    static func main() {
        let short = PermissionText("git status")
        precondition(short.isWhole && short.full == "git status", "A short command shows whole")

        let three = PermissionText("a\nb\nc")
        precondition(three.isWhole && three.lines == ["a", "b", "c"], "Three short lines still fit")

        let spoof = PermissionText("say \"test\"\ncat >/dev/null <<'E'\n*** Update File: README.md\nE")
        precondition(!spoof.isWhole && spoof.lines.count == 4, "The reported heredoc has to be opened before allowing")

        let padded = PermissionText("echo ok" + String(repeating: "\n  ", count: 40) + "\nrm -rf ~")
        precondition(padded.lines == ["echo ok", "⟨빈 줄 40개⟩", "rm -rf ~"],
                     "A run of blank lines folds into one, so it can't push the payload far down")
        precondition(PermissionText("a\n\nb").lines == ["a", "", "b"], "One blank line stays as it is")

        let long = PermissionText(String(repeating: "x", count: 500))
        precondition(!long.isWhole, "One very long line is not whole either")
        precondition(long.preview.count == 1 && long.preview[0].count == PermissionText.lineCut + 1,
                     "Its preview is cut by us, ending in an ellipsis")

        let bidi = PermissionText("ls \u{202E}txt.hs")
        precondition(bidi.full == "ls ⟨U+202E⟩txt.hs", "A direction override is spelled out")
        let zeroWidth = PermissionText("rm\u{200B} -rf")
        precondition(zeroWidth.full == "rm⟨U+200B⟩ -rf", "A zero-width space is spelled out")
        let carriage = PermissionText("echo safe\rrm -rf ~")
        precondition(carriage.full == "echo safe⟨U+000D⟩rm -rf ~" && carriage.lines.count == 1,
                     "A carriage return is spelled out, not a line break")
        let escape = PermissionText("echo \u{1B}[2Khidden")
        precondition(escape.full.hasPrefix("echo ⟨U+001B⟩"), "Terminal escapes are spelled out")
        let separator = PermissionText("a\u{2028}b")
        precondition(separator.full == "a⟨U+2028⟩b", "Unicode line separators don't break lines unseen")
        precondition(PermissionText("a\tb").full == "a\tb", "Tabs stay")
        precondition(PermissionText("  ls  \n").full == "ls", "Surrounding whitespace is trimmed")
        precondition(PermissionText("한글 경로").full == "한글 경로", "Ordinary text is untouched")
        precondition(PermissionText("ls ./\u{3164}").full == "ls ./⟨U+3164⟩", "A Hangul filler (draws nothing) is spelled out")
        precondition(PermissionText("cat \u{2800}").full == "cat ⟨U+2800⟩", "So is the blank braille pattern")
        precondition(PermissionText("a\u{034F}b").full == "a⟨U+034F⟩b", "And other default-ignorable marks")
        let huge = PermissionText(String(repeating: "y", count: PermissionText.maxCharacters + 1))
        precondition(huge.isTooLong && !huge.isWhole && huge.full.count == 2_000,
                     "A huge request is cut for display and can't be allowed from the notch")
        print("PermissionTextChecks: all passed")
    }
}
