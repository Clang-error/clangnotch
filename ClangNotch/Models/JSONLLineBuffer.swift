import Foundation

/// A file-system event can stop in the middle of JSON or a UTF-8 character.
struct JSONLLineBuffer {
    private var pending = Data()

    mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            if let line = String(data: pending[..<newline], encoding: .utf8), !line.isEmpty {
                lines.append(line)
            }
            pending.removeSubrange(...newline)
        }
        return lines
    }
}
