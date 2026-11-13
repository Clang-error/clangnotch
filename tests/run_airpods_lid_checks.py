#!/usr/bin/env python3
"""Replays traced AirPods advertisement frames through AirPodsLidWatcher.handle and checks what
the 에어팟 드롭다운 is told. The method and its Sighting struct are cut from the source; the
watcher's other parts (scanning, proof, trace file) and the card are stood in for.
"""
import re
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = (root / "ClangNotch/Core/Battery/AirPodsLidWatcher.swift").read_text()


def block(start):
    begin = source.index(start)
    end = source.index("\n    }\n", begin) + len("\n    }")
    return source[begin:end]


# `private` dropped: the harness calls them from outside the class.
sighting = block("    private struct Sighting {").replace("private struct", "struct", 1)
handle = (block("    private func handle(_ b: [UInt8], from id: UUID) {").replace("private func", "func", 1)
          .replace("let now = Date()", "let now = clock", 1))
tenths = re.search(r"    private func tenths\(.*\n", source).group(0)

harness = """
import Foundation

enum Kind { case buds, headphones }
enum AirPodsArt { static func kind(for productID: UInt16) -> Kind? { productID == 0x202D ? .headphones : .buds } }

struct Told { let drops: Bool; let side: String?; let level: Int?; let at: Double }

final class AirPodsDropdown {
    static let shared = AirPodsDropdown()
    var told: [Told] = []
    var folds = 0
    var at = 0.0
    func keepAlive(address: String) {}
    func setBothWorn(_ worn: Bool, address: String) {}
    func caseClosed(address: String) { folds += 1 }
    func caseOpened(address: String, productID: UInt16, level: Int?, caseLevel: Int?, side: String? = nil,
                    sides: (left: Int?, right: Int?)? = nil,
                    charging: (left: Bool, right: Bool, case: Bool)? = nil, drops: Bool = true) {
        told.append(Told(drops: drops, side: side, level: level, at: at))
    }
}

final class Watcher {
    struct Paired { let address: String; let productID: UInt16 }
    var candidates = [Paired(address: "pro", productID: 0x2024)]
    var owners: [String: UUID] = [:]
    var slow = false
    var clock = Date(timeIntervalSince1970: 0)
""" + sighting + """
    var sightings: [UUID: Sighting] = [:]
    func proven(_ address: String) -> UUID? { nil }
    func matches(_ address: String, _ left: Int, _ right: Int, _ caseTenths: Int) -> Bool { true }
    func remember(_ id: UUID, _ sighting: Sighting) { sightings[id] = sighting }
    func trace(_ b: [UInt8], id: UUID, leftSpeaking: Bool, out: Int, inEar: Int, lidShut: Bool) {}
    func traceNote(_ text: String) {}
    func opened(_ id: UUID, _ address: String, at now: Date) {}
    func acts(_ id: UUID, for address: String) -> Bool { true }
    func reevaluate() {}
    func handleHeadphones(_ b: [UInt8], model: UInt16, from id: UUID) {}
""" + handle + "\n" + tenths + """
}

let pair = UUID()

/// Feeds frames as a live scan hears them: one every `every` seconds, each held for `count` frames.
func replay(_ steps: [(String, Int)], every: Double = 3) -> [Told] {
    let watcher = Watcher()
    AirPodsDropdown.shared.told = []
    var t = 0.0
    for (hex, count) in steps {
        let bytes = hex.split(separator: " ").map { UInt8($0, radix: 16)! }
        for _ in 0..<count {
            watcher.clock = Date(timeIntervalSince1970: t)
            AirPodsDropdown.shared.at = t
            watcher.handle(bytes, from: pair)
            t += every
        }
    }
    return AirPodsDropdown.shared.told
}

// Frames traced from this Mac's AirPods Pro (left bud worn, right bud in the case).
let base = "4C 00 07 19 01 24 20"
let tail = "00 0A 0A 52 FF FF AE 0E 40 00 00 00 16 1C 5B A2 11 24"
func frame(_ state: String) -> String { "\\(base) \\(state) \\(tail)" }
// Lid shut, the right bud in the case: the worn left bud's frame. 0x20 is set, but the frame is the
// left bud's own (its 80 % matched system_profiler's left 82 %; 2026-11-14 00:16 and 00:22).
let shutWorn = frame("22 F8 8F 11")
let shutOutOfEar = frame("20 F8 8F 11")
// 2026-11-12 nonstop trace: lid open with both buds in the case, the left bud out, then in an ear.
let openBoth = frame("55 99 B8 51")
let openLeftOut = frame("51 99 98 31")
let leftOutShutting = frame("51 99 98 39")

// The user's case: lid shut, one bud worn, taken out of the ear and put back. Nothing drops, and
// whatever the card hears names the left bud.
let backIn = replay([(shutWorn, 3), (shutOutOfEar, 3), (shutWorn, 3)])
precondition(!backIn.contains { $0.drops },
             "A bud already worn, taken out and put back with the lid shut, must not drop the card: \\(backIn)")
// With no bud in an ear the card that's up shows the pair (side nil); a bud in shows that bud.
precondition(!backIn.contains { $0.side == "R" } && backIn.last?.side == "L" && backIn.last?.level == 80,
             "The worn bud is the left one at 80 %: \\(backIn)")

// The card for a bud put in an ear with the lid shut stays (acbf41c): out of the open case, lid
// shut, then into the ear drops it, for the left bud at its 80 %.
let designed = replay([(openBoth, 1), (openLeftOut, 1), (leftOutShutting, 1), (shutOutOfEar, 2), (shutWorn, 2)], every: 2)
let drops = designed.filter(\\.drops)
precondition(drops.count == 2 && drops[0].at == 0, "Drops for the lid opening and the bud going in: \\(designed)")
precondition(drops[1].side == "L" && drops[1].level == 80, "The bud that went in is the left one at 80 %: \\(drops[1])")

print("PASS: a worn bud put back with the lid shut drops nothing; a bud from the case into an ear with the lid shut drops, as the left bud")
"""

with tempfile.TemporaryDirectory(prefix="clangnotch-airpods-lid-checks-") as folder:
    main = Path(folder) / "main.swift"
    main.write_text(harness)
    binary = Path(folder) / "checks"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", str(main), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
