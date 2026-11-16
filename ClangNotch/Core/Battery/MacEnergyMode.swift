import Foundation

/// The Mac's energy mode (System Settings -> Battery): shown on the Mac's 기기 줄 in the Battery tab.
/// Read from `pmset -g`, whose "Currently in use" block carries the mode of the power source in
/// use: `powermode` 0 automatic, 1 low power, 2 high power. A Mac or macOS without the three-way
/// setting prints `lowpowermode` (and `highpowermode`) 0 or 1 instead.
/// Reading needs no rights. Changing it needs an administrator, so the tab only shows it; a switch
/// under the Mac's row is planned (on a Mac without a high power mode, two choices filling the row).
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
}
