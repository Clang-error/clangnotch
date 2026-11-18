import Foundation

/// The end of a watched session file that hasn't been read yet, read off the main thread (the
/// GitHub #3 follow-up: a working agent appends tool outputs of many MB, and reading and decoding
/// them on the main thread stalled the notch). It owns the file handle, the read position and the
/// unfinished last line. Every use goes through `queue`, one serial queue per session, so reads
/// stay in file order; whoever applies the lines on the main thread checks the tail is still the
/// session's (`===`), since a session can stop or restart while a read is under way.
final class SessionFileTail: @unchecked Sendable {
    let queue: DispatchQueue
    private let handle: FileHandle
    private var position: UInt64
    private var buffer: JSONLLineBuffer

    /// `buffer` carries the unfinished line the history read ended on.
    init(handle: FileHandle, position: UInt64, buffer: JSONLLineBuffer, label: String) {
        self.handle = handle
        self.position = position
        self.buffer = buffer
        queue = DispatchQueue(label: "ClangNotch.tail.\(label)", qos: .utility)
    }

    deinit { try? handle.close() }

    /// The lines completed since the last read. Call on `queue`.
    func readNewLines() -> [String] {
        dispatchPrecondition(condition: .onQueue(queue))
        handle.seek(toFileOffset: position)
        let data = handle.readDataToEndOfFile()
        position = handle.offsetInFile
        return data.isEmpty ? [] : buffer.append(data)
    }
}

/// Decoded JSONL records handed from a tail's queue to the main thread. JSON objects aren't
/// Sendable, but these are made on the queue and only read on the main thread after it.
struct DecodedRecords: @unchecked Sendable {
    let items: [[String: Any]]
}
