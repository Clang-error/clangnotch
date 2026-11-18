import Foundation

/// The Mac's energy mode (System Settings -> Battery): shown on the Mac's 기기 줄 in the Battery tab.
/// Read from `pmset -g`, whose "Currently in use" block carries the mode of the power source in
/// use: `powermode` 0 automatic, 1 low power, 2 high power. A Mac or macOS without the three-way
/// setting prints `lowpowermode` (and `highpowermode`) 0 or 1 instead.
/// Reading needs no rights. Changing it needs root: the switch under the Mac's row (`BatteryView`,
/// the row clicked open) goes through the optional `EnergyHelper` and sets both power sources.
enum MacEnergyMode: Equatable {
    case automatic, lowPower, highPower

    var label: String {
        switch self {
        case .automatic: return L("자동", "Auto")
        case .lowPower: return L("저전력", "Low Power")
        case .highPower: return L("고성능", "High Power")
        }
    }

    var symbol: String {
        switch self {
        case .automatic: return "gauge.with.dots.needle.50percent"
        case .lowPower: return "leaf.fill"
        case .highPower: return "bolt.fill"
        }
    }

    /// The mode in `pmset -g`'s output; nil when it names none.
    static func parse(_ output: String) -> MacEnergyMode? {
        var values: [String: Int] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: \.isWhitespace)
            guard words.count >= 2, let value = Int(words[1]), values[String(words[0])] == nil else { continue }
            values[String(words[0])] = value
        }
        if let mode = values["powermode"] {
            return mode == 1 ? .lowPower : mode == 2 ? .highPower : .automatic
        }
        if values["highpowermode"] == 1 { return .highPower }
        if let low = values["lowpowermode"] { return low == 1 ? .lowPower : .automatic }
        return nil
    }

    /// Runs `pmset -g` (about 10 ms): call it off the main thread.
    static func read() -> MacEnergyMode? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// What this Mac can switch: whether `pmset` speaks the three-way `powermode`, and whether a
    /// high power mode exists at all (`pmset -g cap`). Two processes: call it off the main thread.
    struct Capabilities: Equatable {
        var threeWay: Bool
        var highPower: Bool
    }

    static func capabilities() -> Capabilities {
        Capabilities(threeWay: pmset(["-g"]).contains(where: { $0.first == "powermode" }),
                     highPower: pmset(["-g", "cap"]).contains(where: { $0.first == "highpowermode" }))
    }

    /// The words of each line `pmset` prints.
    private static func pmset(_ arguments: [String]) -> [[Substring]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: \.isWhitespace) }
    }

    /// `powermode`'s number for this mode; the helper turns it into the words this Mac's pmset takes.
    var pmsetNumber: Int64 { self == .lowPower ? 1 : self == .highPower ? 2 : 0 }
}

/// The power on the Mac's open row, from the SMC, measured and updated every second (unlike
/// `pmset -g ac`'s negotiated maximum). Read only while the Mac's row is open in the Battery tab.
/// On the charger (a DC-in voltage, `VD0R`): what comes in, total power in (`PDTR`), 입력 전력.
/// On battery: what the battery gives out (`PPBR`), which is what the Mac uses, 소비 전력.
struct MacPower: Equatable {
    var watts: Double
    var onCharger: Bool

    /// Nil when the Mac has no such keys.
    static func read(_ smc: SMCReader) -> MacPower? {
        if let volts = smc.float("VD0R"), volts > 1 {
            guard let watts = smc.float("PDTR"), watts > 0 else { return nil }
            return MacPower(watts: Double(watts), onCharger: true)
        }
        guard let watts = smc.float("PPBR"), abs(watts) > 0 else { return nil }
        return MacPower(watts: Double(abs(watts)), onCharger: false)
    }
}
