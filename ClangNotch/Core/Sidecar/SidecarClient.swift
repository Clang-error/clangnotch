import Foundation

// Signatures verified using the Objective-C runtime on macOS 26.6.2.
@objc private protocol SCManagerProto: NSObjectProtocol {
    @objc(devices) var devices: [AnyObject] { get }
    @objc(connectedDevices) var connectedDevices: [AnyObject] { get }
    @objc(connectToDevice:completion:) func connect(to device: AnyObject, completion: @escaping (NSError?) -> Void)
    @objc(disconnectFromDevice:completion:) func disconnect(from device: AnyObject, completion: @escaping (NSError?) -> Void)
}

@objc private protocol SCDeviceProto {
    @objc(name) var name: String { get }
    @objc(identifier) var identifier: UUID { get }
}

protocol SidecarClientProtocol {
    func fetchDevices(completion: @escaping (Result<[SidecarDeviceInfo], Error>) -> Void)
    func setConnected(_ connected: Bool, deviceID: UUID, completion: @escaping (Error?) -> Void)
}

enum SidecarError: LocalizedError {
    case unavailable, deviceDisappeared

    var errorDescription: String? {
        switch self {
        case .unavailable: return "이 macOS에서 Sidecar 상태를 읽을 수 없습니다."
        case .deviceDisappeared: return "iPad를 더 이상 찾을 수 없습니다. 전원과 Wi-Fi를 확인해 주세요."
        }
    }
}

/// Serial worker owns discovery, requests and raw objects. Never dispatch_sync from the UI.
final class SidecarClient: SidecarClientProtocol, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.clangerror.ClangNotch.sidecar", qos: .utility)
    private var frameworkLoaded = false

    func fetchDevices(completion: @escaping (Result<[SidecarDeviceInfo], Error>) -> Void) {
        queue.async { [self] in
            guard let manager = manager() else { completion(.failure(SidecarError.unavailable)); return }
            let connected = manager.connectedDevices
            let connectedIDs = Set(connected.map(Self.id))
            var seen = Set<UUID>()
            // Never use recentDevices. Keep connected devices reachable for Disconnect
            // even if the current discovery list temporarily drops them.
            let devices = (manager.devices + connected).compactMap { raw -> SidecarDeviceInfo? in
                let id = Self.id(raw)
                guard seen.insert(id).inserted else { return nil }
                let device = unsafeBitCast(raw, to: SCDeviceProto.self)
                return SidecarDeviceInfo(id: id, name: device.name, isConnected: connectedIDs.contains(id))
            }
            completion(.success(devices))
        }
    }

    func setConnected(_ connected: Bool, deviceID: UUID, completion: @escaping (Error?) -> Void) {
        queue.async { [self] in
            guard let manager = manager() else { completion(SidecarError.unavailable); return }
            let existing = manager.connectedDevices
            if existing.contains(where: { Self.id($0) == deviceID }) == connected {
                completion(nil)
                return
            }
            // Re-resolve immediately before sending, not from a stale SwiftUI card.
            let candidates = connected ? manager.devices : existing
            guard let raw = candidates.first(where: { Self.id($0) == deviceID }) else {
                completion(SidecarError.deviceDisappeared)
                return
            }
            if connected { manager.connect(to: raw) { completion($0) } }
            else { manager.disconnect(from: raw) { completion($0) } }
        }
    }

    private func manager() -> SCManagerProto? {
        if !frameworkLoaded {
            frameworkLoaded = dlopen("/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore", RTLD_NOW) != nil
        }
        guard frameworkLoaded, let cls = NSClassFromString("SidecarDisplayManager") else { return nil }
        let selector = NSSelectorFromString("sharedManager")
        let clsObject = cls as AnyObject
        guard clsObject.responds(to: selector), let object = clsObject.perform(selector)?.takeUnretainedValue() else { return nil }
        let manager = unsafeBitCast(object, to: SCManagerProto.self)
        for name in ["devices", "connectedDevices", "connectToDevice:completion:", "disconnectFromDevice:completion:"] {
            guard manager.responds(to: NSSelectorFromString(name)) else { return nil }
        }
        return manager
    }

    private static func id(_ raw: AnyObject) -> UUID {
        unsafeBitCast(raw, to: SCDeviceProto.self).identifier
    }
}
