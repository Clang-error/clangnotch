import Foundation

/// Splits appended file data into complete UTF-8 lines and keeps the unfinished tail.
/// Only bytes not looked at before are searched, and the consumed lines are dropped in one cut:
/// searching from the start and cutting each line off in turn made a long line arriving in
/// pieces cost the square of its length (GitHub issue #3).
struct JSONLLineBuffer {
    private var pending = Data()
    /// Bytes at the start of `pending` already known to hold no newline.
    private var searched = 0

    mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        var lineStart = 0
        let from = searched
        // memchr and String(data:) stay fast in unoptimized (Debug) builds too; a Swift byte loop didn't.
        var ends: [Int] = []
        pending.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var at = from
            while at < raw.count, let hit = memchr(base + at, 0x0A, raw.count - at) {
                let index = base.distance(to: UnsafeRawPointer(hit))
                ends.append(index)
                at = index + 1
            }
        }
        for end in ends {
            if end > lineStart, let line = String(data: pending.subdata(in: lineStart..<end), encoding: .utf8) {
                lines.append(line)
            }
            lineStart = end + 1
        }
        if lineStart > 0 { pending = Data(pending.dropFirst(lineStart)) }
        searched = pending.count
        return lines
    }
}
