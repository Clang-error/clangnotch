// SpeedTestManager.swift
// Ping / download / upload measurement against Cloudflare's public speed endpoints.

import Foundation
import Combine

enum SpeedTestPhase {
    case idle
    case ping
    case download
    case upload
    case finished
    case failed
}

@MainActor
final class SpeedTestManager: ObservableObject {
    static let shared = SpeedTestManager()

    @Published private(set) var phase: SpeedTestPhase = .idle
    /// Throughput of the transfer in flight, refreshed ~10x/s. 0 when nothing is moving.
    @Published private(set) var liveMbps: Double = 0
    @Published private(set) var latencyMs: Double?
    @Published private(set) var downloadMbps: Double?
    @Published private(set) var uploadMbps: Double?
    @Published private(set) var errorMessage: String?
    /// When the numbers on screen were measured — they stay up for `resultLifetime`
    /// or until the next run.
    @Published private(set) var finishedAt: Date?

    /// Cloudflare's public speed endpoints — no key, no sign-up.
    /// `__down` rejects a byte count of 100 MB or more with a 403, so this asks for
    /// just under it; the time cap below ends the transfer early on a fast link.
    private let downloadURL = URL(string: "https://speed.cloudflare.com/__down?bytes=99000000")!
    private let uploadURL = URL(string: "https://speed.cloudflare.com/__up")!
    private let pingURL = URL(string: "https://speed.cloudflare.com/__down?bytes=0")!
    private let uploadProbeBytes = 2 * 1024 * 1024

    /// The download ends at its byte budget or this cap, whichever comes first.
    private let downloadCap: TimeInterval = 8

    /// How long a finished, failed or cancelled run's numbers stay before they're wiped.
    private let resultLifetime: TimeInterval = 5 * 60

    private var runTask: Task<Void, Never>?
    private var clearTask: Task<Void, Never>?

    var isRunning: Bool {
        switch phase {
        case .ping, .download, .upload: return true
        case .idle, .finished, .failed: return false
        }
    }

    func start() {
        guard !isRunning else { return }
        runTask?.cancel()
        clearTask?.cancel()
        latencyMs = nil
        downloadMbps = nil
        uploadMbps = nil
        errorMessage = nil
        finishedAt = nil
        liveMbps = 0
        runTask = Task { [weak self] in await self?.run() }
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        liveMbps = 0
        phase = .idle
        scheduleClear()
    }

    private func run() async {
        phase = .ping
        latencyMs = await measureLatency()
        guard !Task.isCancelled else { return }
        guard latencyMs != nil else {
            fail("연결 없음")
            return
        }

        phase = .download
        downloadMbps = await measure(request: URLRequest(url: downloadURL), body: nil, cap: downloadCap)
        guard !Task.isCancelled else { return }
        liveMbps = 0

        phase = .upload
        uploadMbps = await measureUpload()
        guard !Task.isCancelled else { return }
        liveMbps = 0

        if downloadMbps == nil && uploadMbps == nil {
            fail("측정 실패")
        } else {
            finishedAt = Date()
            phase = .finished
            scheduleClear()
        }
    }

    private func fail(_ message: String) {
        errorMessage = message
        liveMbps = 0
        phase = .failed
        scheduleClear()
    }

    private func scheduleClear() {
        clearTask?.cancel()
        clearTask = Task { [weak self, resultLifetime] in
            do { try await Task.sleep(for: .seconds(resultLifetime)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            latencyMs = nil
            downloadMbps = nil
            uploadMbps = nil
            errorMessage = nil
            finishedAt = nil
            phase = .idle
        }
    }

    /// The upload is timed to the server's acknowledgement rather than to the last
    /// byte handed to the socket: the kernel accepts megabytes before they reach the
    /// wire, and timing the handoff reports roughly double the real rate. That means
    /// the payload has to fit the link, so a short probe sizes the real one.
    private func measureUpload() async -> Double? {
        guard let probed = await upload(bytes: uploadProbeBytes, cap: 20) else { return nil }
        guard !Task.isCancelled else { return probed }

        let target = Int(probed * 1_000_000 / 8 * 6)   // ~6 seconds' worth
        let size = min(max(target, uploadProbeBytes), 64 * 1024 * 1024)
        return await upload(bytes: size, cap: 30) ?? probed
    }

    private func upload(bytes: Int, cap: TimeInterval) async -> Double? {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        return await measure(request: request, body: Data(count: bytes), cap: cap, endsAtCompletion: true)
    }

    private func measure(
        request: URLRequest,
        body: Data?,
        cap: TimeInterval,
        endsAtCompletion: Bool = false
    ) async -> Double? {
        let probe = SpeedProbe { [weak self] mbps in
            Task { @MainActor in self?.liveMbps = mbps }
        }
        return await probe.run(request: request, body: body, cap: cap, endsAtCompletion: endsAtCompletion)
    }

    /// Five round trips to a zero-byte endpoint. The fastest is the closest thing to
    /// the real path latency — the first pays for DNS/TLS, the rest carry queue noise.
    private func measureLatency() async -> Double? {
        var request = URLRequest(url: pingURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 5

        var best: Double?
        for _ in 0..<5 {
            guard !Task.isCancelled else { break }
            let started = CFAbsoluteTimeGetCurrent()
            guard (try? await URLSession.shared.data(for: request)) != nil else { continue }
            let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
            best = min(best ?? ms, ms)
        }
        return best
    }
}

/// One timed transfer. URLSession delivers its callbacks on a single-width queue, so
/// the counters are only ever touched there; the lock guards what `stop()` reaches
/// from the cancelling side.
private final class SpeedProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var session: URLSession!
    private var task: URLSessionTask?
    private var stopped = false
    private var continuation: CheckedContinuation<Double?, Never>?
    private var endsAtCompletion = false
    private var bytes: Int64 = 0
    private var startedAt: CFAbsoluteTime = 0
    private var lastByteAt: CFAbsoluteTime = 0
    private var lastEmitAt: CFAbsoluteTime = 0
    /// (timestamp, cumulative bytes) for the trailing window the live figure uses.
    private var samples: [(at: CFAbsoluteTime, bytes: Int64)] = []
    private let liveWindow: TimeInterval = 2
    /// Long enough for the kernel's send buffer to fill and for the trailing window to
    /// slide past the burst that filled it.
    private let liveWarmup: TimeInterval = 2.5

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
        super.init()

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    /// Mbps for the transfer, or nil if too little moved to mean anything.
    ///
    /// `endsAtCompletion` stops the clock when the server acknowledges instead of at
    /// the last delegate callback — required for uploads, where the callbacks report
    /// bytes buffered by the kernel rather than bytes on the wire. Such a transfer has
    /// to finish on its own: hitting `cap` aborts it with no usable measurement.
    func run(request: URLRequest, body: Data?, cap: TimeInterval, endsAtCompletion: Bool = false) async -> Double? {
        self.endsAtCompletion = endsAtCompletion
        let task = body.map { session.uploadTask(with: request, from: $0) }
            ?? session.dataTask(with: request)
        lock.lock()
        self.task = task
        lock.unlock()

        let capTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(cap))
            self?.stop()
        }
        defer { capTask.cancel() }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Double?, Never>) in
                continuation = cont
                task.resume()
            }
        } onCancel: {
            stop()
        }
    }

    /// Ends the transfer early — the time cap, or the caller going away. The bytes
    /// already counted still make a valid measurement.
    private func stop() {
        lock.lock()
        let task = self.task
        let wasStopped = stopped
        stopped = true
        lock.unlock()

        guard !wasStopped else { return }
        task?.cancel()
    }

    /// Rate over the last couple of seconds rather than the whole transfer. An
    /// upload's callbacks outrun the wire until the kernel's send buffer fills, and a
    /// trailing window converges on the real rate once it has; a cumulative average
    /// would stay stuck at the inflated opening figure.
    private var windowedMbps: Double {
        guard let oldest = samples.first, lastByteAt > oldest.at else { return 0 }
        return Double(bytes - oldest.bytes) * 8 / (lastByteAt - oldest.at) / 1_000_000
    }

    /// Delegate queue only. The clock starts at the first callback so DNS/TLS setup
    /// isn't charged against the throughput.
    private func record(_ count: Int64) {
        let now = CFAbsoluteTimeGetCurrent()
        bytes += count
        lastByteAt = now

        guard startedAt > 0 else {
            startedAt = now
            lastEmitAt = now
            samples = [(now, bytes)]
            return
        }

        samples.append((now, bytes))
        while samples.count > 1, now - samples[0].at > liveWindow { samples.removeFirst() }

        // An upload opens with the kernel swallowing megabytes in one go — those
        // callbacks are the socket buffer filling, not the wire, and they read as
        // several times the real rate. Stay quiet until that burst is behind us.
        guard !endsAtCompletion || now - startedAt >= liveWarmup else { return }
        guard now - lastEmitAt >= 0.1 else { return }
        lastEmitAt = now
        onProgress(windowedMbps)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        record(Int64(data.count))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        record(bytesSent)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // A cancel from the time cap is the normal end of a download — what arrived
        // still measures fine, provided enough of it did to mean anything.
        //
        // An acknowledgement-timed upload is judged the other way round: it either
        // completed or it isn't a measurement at all, and once it completed even a
        // fraction of a second is a real figure. Holding it to the download's floor
        // threw away every probe on a fast link — 2 MB acknowledges in ~0.2 s — and
        // with the probe gone the upload was never measured.
        let elapsed = (endsAtCompletion ? CFAbsoluteTimeGetCurrent() : lastByteAt) - startedAt
        let usable = startedAt > 0 && bytes > 0
            && (endsAtCompletion ? (error == nil && elapsed > 0) : elapsed > 0.3)
        let result: Double? = usable ? Double(bytes) * 8 / elapsed / 1_000_000 : nil

        let cont = continuation
        continuation = nil
        session.finishTasksAndInvalidate()
        cont?.resume(returning: result)
    }
}
