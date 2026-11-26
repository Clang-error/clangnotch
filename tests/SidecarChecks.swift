import Foundation

private final class FakeSidecarClient: SidecarClientProtocol {
    var fetches: [(Result<[SidecarDeviceInfo], Error>) -> Void] = []
    var requests: [(Error?) -> Void] = []
    func fetchDevices(completion: @escaping (Result<[SidecarDeviceInfo], Error>) -> Void) { fetches.append(completion) }
    func setConnected(_ connected: Bool, deviceID: UUID, completion: @escaping (Error?) -> Void) { requests.append(completion) }
    var optionFetches: [(Set<SidecarDisplayOption>) -> Void] = []
    var writes: [(Bool, SidecarDisplayOption)] = []
    func fetchShownOptions(completion: @escaping (Set<SidecarDisplayOption>) -> Void) { optionFetches.append(completion) }
    func setShown(_ shown: Bool, option: SidecarDisplayOption) { writes.append((shown, option)) }
}

@main
struct SidecarChecks {
    @MainActor static func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    @MainActor static func main() async throws {
        let client = FakeSidecarClient()
        let manager = SidecarManager(client: client, operationTimeout: 0.15)
        let device = SidecarDeviceInfo(id: UUID(), name: "Test iPad", isConnected: false)
        let connected = SidecarDeviceInfo(id: device.id, name: device.name, isConnected: true)
        manager.start()
        manager.start()
        manager.refresh()
        precondition(client.fetches.count == 1, "Only one discovery in flight")
        client.fetches[0](.success([device]))
        await settle()
        precondition(manager.devices == [device])

        manager.toggle(device)
        manager.toggle(device)
        precondition(client.requests.count == 1 && manager.busyDeviceID == device.id)
        manager.refresh()
        client.fetches[1](.success([connected]))
        await settle()
        precondition(manager.busyDeviceID != nil, "A temporary connectedDevices entry is not a completed request")
        client.requests[0](SidecarError.deviceDisappeared)
        await settle()
        precondition(manager.busyDeviceID == nil && manager.errorMessage != nil)
        client.fetches[2](.success([device]))
        await settle()
        print("PASS: coalesced discovery, duplicate-click guard, provisional connection failure")

        manager.toggle(device)
        client.requests[1](nil)
        await settle()
        client.fetches[3](.success([device]))
        await settle()
        precondition(manager.busyDeviceID != nil, "Accepted is not connected")
        manager.refresh()
        client.fetches[4](.success([connected]))
        await settle()
        precondition(manager.busyDeviceID == nil && manager.errorMessage == nil)
        manager.toggle(connected)
        client.requests[2](nil)
        await settle()
        client.fetches[5](.success([]))
        await settle()
        precondition(manager.busyDeviceID == nil, "Disappearing after disconnect is success")
        print("PASS: accepted vs connected, disconnect with vanished discovery entry")

        manager.refresh()
        client.fetches[6](.success([device]))
        await settle()
        manager.toggle(device)
        manager.refresh() // Deliberately never complete either callback before the deadline.
        try await Task.sleep(for: .milliseconds(220))
        precondition(manager.busyDeviceID == nil && manager.errorMessage != nil, "Deadline cannot depend on a stuck poll")
        manager.toggle(device)
        let newRequest = manager.busyDeviceID
        client.requests[3](SidecarError.unavailable)
        await settle()
        precondition(manager.busyDeviceID == newRequest && manager.errorMessage == nil, "Old callback cannot finish new request")
        manager.stop()
        client.fetches[7](.success([connected]))
        client.requests[4](nil)
        await settle()
        precondition(manager.busyDeviceID == nil && manager.devices == [device])
        print("PASS: independent timeout, stale completion ignored, stopped manager ignores results")

        // 사이드바·Touch Bar 칩
        let optionClient = FakeSidecarClient()
        let options = SidecarManager(client: optionClient)
        options.start()
        optionClient.fetches[0](.success([device]))
        await settle()
        options.toggleShown(.sidebar)
        precondition(optionClient.optionFetches.isEmpty && optionClient.writes.isEmpty && options.shownOptions.isEmpty,
                     "No iPad connected: no reads, and a press does nothing")
        options.refresh()
        optionClient.fetches[1](.success([connected]))
        await settle()
        precondition(optionClient.optionFetches.count == 1, "Options are read while connected")
        optionClient.optionFetches[0]([.touchBar])
        await settle()
        precondition(options.shownOptions == [.touchBar])
        options.refresh()
        optionClient.fetches[2](.success([connected]))
        await settle()
        options.toggleShown(.sidebar)
        precondition(options.shownOptions == [.touchBar, .sidebar] && optionClient.writes.count == 1
                     && optionClient.writes[0] == (true, .sidebar), "A press shows at once and writes")
        optionClient.optionFetches[1]([.touchBar])
        await settle()
        precondition(options.shownOptions == [.touchBar, .sidebar], "A read started before the press can't undo it")
        options.toggleShown(.touchBar)
        precondition(options.shownOptions == [.sidebar] && optionClient.writes.last! == (false, .touchBar))
        print("PASS: Sidecar chips read only while connected, press shows at once, stale read ignored")

        if CommandLine.arguments.contains("--live") {
            let real = SidecarClient()
            let result: Result<[SidecarDeviceInfo], Error> = await withCheckedContinuation { continuation in
                real.fetchDevices {
                    precondition(!Thread.isMainThread, "Private API must finish on its worker")
                    continuation.resume(returning: $0)
                }
            }
            let devices = try result.get()
            let error: Error? = await withCheckedContinuation { continuation in
                real.setConnected(true, deviceID: UUID()) {
                    precondition(!Thread.isMainThread)
                    continuation.resume(returning: $0)
                }
            }
            precondition(error is SidecarError, "Missing device must be rejected without a connect request")
            print("PASS: live worker discovery (\(devices.count) devices), nonexistent device rejected")
        }
    }
}
