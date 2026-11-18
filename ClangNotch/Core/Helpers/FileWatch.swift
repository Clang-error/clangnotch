import Foundation

/// A file or folder watched for changes through a vnode source (`O_EVTONLY`, so it never holds
/// a volume busy). `onChange` runs on `queue` for each event. The watch ends when it is
/// released; the descriptor closes with it.
final class FileWatch {
    private let source: DispatchSourceFileSystemObject

    /// Nil when the path can't be opened (it doesn't exist yet, or went away).
    init?(path: String, events: DispatchSource.FileSystemEvent, queue: DispatchQueue = .main,
          onChange: @escaping @Sendable () -> Void) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: queue)
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { source.cancel() }
}
