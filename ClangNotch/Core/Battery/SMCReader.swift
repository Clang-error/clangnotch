import Foundation
import IOKit

/// Reads float keys from the System Management Controller (AppleSMC's user client), no rights
/// needed. Open only while something is on screen that needs it: the Battery tab's open Mac row
/// (`MacPower`). The battery's own `PowerTelemetryData` changes about every 20 s; these keys
/// change every second (measured 2026-11-18).
final class SMCReader {
    private var connection: io_connect_t = 0
    private var keyInfo: [UInt32: KeyInfo] = [:]

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
    }

    deinit { IOServiceClose(connection) }

    /// A `flt ` key's value; nil when the Mac has no such key or it isn't a float.
    func float(_ key: String) -> Float? {
        let code = key.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let info: KeyInfo
        if let cached = keyInfo[code] {
            info = cached
        } else {
            var request = Param(key: code, command: Self.getKeyInfo)
            guard call(&request) else { return nil }
            info = request.keyInfo
            keyInfo[code] = info
        }
        guard info.dataType == Self.floatType, info.dataSize == 4 else { return nil }
        var request = Param(key: code, command: Self.readKey)
        request.keyInfo.dataSize = info.dataSize
        guard call(&request) else { return nil }
        return Float(bitPattern: UInt32(truncatingIfNeeded: request.bytes.0))
    }

    private func call(_ param: inout Param) -> Bool {
        var output = Param()
        var size = MemoryLayout<Param>.stride
        let result = IOConnectCallStructMethod(connection, 2, &param, MemoryLayout<Param>.stride, &output, &size)
        param = output
        return result == KERN_SUCCESS && output.result == 0
    }

    private static let readKey: UInt8 = 5
    private static let getKeyInfo: UInt8 = 9
    private static let floatType: UInt32 = 0x666C_7420  // "flt "

    // SMCParamStruct, 80 bytes. Swift lays a struct out by size, not stride: the padding after
    // KeyInfo keeps `result` at C's offset 40 and `bytes` at 48.
    private struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
        var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
    }

    private struct Param {
        var key: UInt32 = 0
        var version: (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)
        var powerLimits: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
        var keyInfo = KeyInfo()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var command: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)

        init() {}
        init(key: UInt32, command: UInt8) {
            self.key = key
            self.command = command
        }
    }
}
