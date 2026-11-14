#!/usr/bin/env python3
"""Replays traced AirPods advertisement frames through AirPodsLidWatcher.handle and checks what
the 에어팟 드롭다운 is told. The method, its Sighting struct and the reading of whose frame it is
are cut from the source; the watcher's other parts (scanning, proof, trace file) and the card
are stood in for.
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
claim = (block("    private func claim(").replace("private func", "func", 1)
         .replace("let now = Date()", "let now = clock", 1))
levels_read = block("    private static func levelsRead(").replace("private static", "static", 1)
ending = block("    private static func ending(").replace("private static", "static", 1)
lapse = re.search(r"    private static let readLapse.*\n", source).group(0).replace("private ", "", 1)

harness = """
import Foundation

enum Kind { case buds, headphones }
enum AirPodsArt { static func kind(for productID: UInt16) -> Kind? { productID == 0x202D ? .headphones : .buds } }

struct Told { let drops: Bool; let side: String?; let level: Int?; let at: Double; let address: String }

final class AirPodsDropdown {
    static let shared = AirPodsDropdown()
    var told: [Told] = []
    var folds = 0
    var at = 0.0
    /// A card dropped by the connection alone is up, still drawn as the pair.
    var awaits = false
    func awaitsFrame(address: String) -> Bool { awaits }
    func keepAlive(address: String) {}
    func setBothWorn(_ worn: Bool, address: String) {}
    func caseClosed(address: String) { folds += 1 }
    func caseOpened(address: String, productID: UInt16, level: Int?, caseLevel: Int?, side: String? = nil,
                    sides: (left: Int?, right: Int?)? = nil,
                    charging: (left: Bool, right: Bool, case: Bool)? = nil, drops: Bool = true) {
        told.append(Told(drops: drops, side: side, level: level, at: at, address: address))
    }
}

final class Watcher {
    struct Paired { let address: String; let productID: UInt16 }
    var candidates = [Paired(address: "aa-bb-cc-11-22-33", productID: 0x2024)]
    var owners: [String: UUID] = [:]
    var readAt: [String: Date] = [:]
    func tailRead(_ address: String, from id: UUID, at now: Date) {
        readAt[address] = now
        owners[address] = id
    }
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
""" + handle + "\n" + tenths + lapse + claim + "\n" + levels_read + "\n" + ending + """
}

let pair = UUID()

func bytes(_ hex: String) -> [UInt8] { hex.split(separator: " ").map { UInt8($0, radix: 16)! } }

/// Feeds frames as a live scan hears them: one every `every` seconds, each held for `count` frames.
func replay(_ steps: [(String, Int)], every: Double = 3) -> [Told] {
    let watcher = Watcher()
    AirPodsDropdown.shared.told = []
    var t = 0.0
    for (hex, count) in steps {
        for _ in 0..<count {
            watcher.clock = Date(timeIntervalSince1970: t)
            AirPodsDropdown.shared.at = t
            watcher.handle(bytes(hex), from: pair)
            t += every
        }
    }
    return AirPodsDropdown.shared.told
}

// Frames traced from this Mac's AirPods Pro (left bud worn, right bud in the case). The tail is
// as the Mac hands our own pair's over: the three levels in percent, their tens the state's
// tenths (8 → 82 %, A → 100 %, F → FF), then the end of the pair's address or zeros.
let base = "4C 00 07 19 01 24 20"
func frame(_ state: String, ending: String = "00 00 00") -> String {
    let b = bytes(state)
    let tenths: [UInt8] = [b[1] >> 4, b[1] & 0x0F, b[2] & 0x0F]
    let levels: [String] = tenths.map { tenth in
        if tenth == 0xF { return "FF" }
        return String(format: "%02X", tenth >= 10 ? 100 : Int(tenth) * 10 + 2)
    }
    return "\\(base) \\(state) 00 0A 0A \\(levels.joined(separator: " ")) AE 0E 40 \\(ending) 16 1C 5B A2 11 24"
}
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

// Worn with the iPhone and walked up to the Mac (2026-11-14 05:57): the Mac connected, which
// dropped the card as the pair. The worn right bud's first frame after the silence (its 20 %
// was system_profiler's right 23 %, the left bud in the shut case unheard) names it for that card.
let walkedUp = frame("02 F2 8F 11")
AirPodsDropdown.shared.awaits = true
let named = replay([(walkedUp, 1)])
precondition(named.count == 1 && !named[0].drops && named[0].side == "R" && named[0].level == 20,
             "The card the connection dropped hears which bud is worn: \\(named)")
AirPodsDropdown.shared.awaits = false
precondition(replay([(walkedUp, 2)]).isEmpty, "With no such card up the same frames say nothing")

// Whose frame it is. Another Pro 2 opening beside us (seen 2026-11-14): lid open, one bud out, levels a tenth from ours, so it passes the fingerprint (`matches` stands in
// as true), and our pair had been quiet for over an hour, so no proof held (`proven` is nil).
// Its tail is ciphertext.
let stranger = UUID()
let strangerOpening = "\\(base) 04 FA 95 31 00 00 3C 9D 17 E2 60 B4 C8 71 0F 5A D3 28 96 4B E1 7C 05"
/// Frames from several peripherals at their own times, through one watcher.
func hear(_ watcher: Watcher, _ steps: [(String, UUID, Double)]) -> [Told] {
    AirPodsDropdown.shared.told = []
    for (hex, id, t) in steps {
        watcher.clock = Date(timeIntervalSince1970: t)
        AirPodsDropdown.shared.at = t
        watcher.handle(bytes(hex), from: id)
    }
    return AirPodsDropdown.shared.told
}
let shutBoth = frame("55 9A B4 19")
let ownOpening = frame("55 9A B4 31")

// A pair that has never read is told by fingerprint, as before: the stranger's opening drops.
precondition(hear(Watcher(), [(strangerOpening, stranger, 0)]).filter(\\.drops).count == 1,
             "Without a frame of ours ever read, the fingerprint still decides")
// Once our pair's tail has read, a frame that doesn't read is not ours.
let quiet = hear(Watcher(), [(shutBoth, pair, 0), (strangerOpening, stranger, 5040), (ownOpening, pair, 5100)])
precondition(quiet.filter(\\.drops).map(\\.at) == [5100],
             "A stranger's opening drops nothing once our pair has read; ours still does: \\(quiet)")
// Levels that fit by chance don't make a frame ours when its address bytes are someone else's.
let chance = hear(Watcher(), [(shutBoth, pair, 0), (frame("04 FA 95 31", ending: "7E 41 D9"), stranger, 60)])
precondition(chance.isEmpty, "Another address in the tail is not ours: \\(chance)")
// A pair that hasn't read for a week falls back to the fingerprint.
let lapsed = hear(Watcher(), [(shutBoth, pair, 0), (strangerOpening, stranger, 8 * 86400)])
precondition(lapsed.filter(\\.drops).count == 1, "After a week without reading, the fingerprint decides again: \\(lapsed)")
// Two pairs of one model: the address in the tail names the pair, and binds its peripheral for
// the frames that carry zeros.
let two = Watcher()
two.candidates.append(Watcher.Paired(address: "aa-bb-cc-44-55-66", productID: 0x2024))
let second = hear(two, [(frame("55 9A B4 31", ending: "44 55 66"), pair, 0), (frame("55 9A B4 39"), pair, 2),
                        (frame("55 9A B4 32"), pair, 20)])
precondition(second.map(\\.address) == ["aa-bb-cc-44-55-66", "aa-bb-cc-44-55-66"] && two.readAt["aa-bb-cc-11-22-33"] == nil,
             "The tail's address picks the pair: \\(second)")

print("PASS: a worn bud put back with the lid shut drops nothing; a bud from the case into an ear with the lid shut drops, as the left bud; a card dropped by the connection hears which bud is worn; once our pair's tail has read a stranger's opening drops nothing, and a pair never read or not read for a week is told by fingerprint")
"""

with tempfile.TemporaryDirectory(prefix="clangnotch-airpods-lid-checks-") as folder:
    main = Path(folder) / "main.swift"
    main.write_text(harness)
    binary = Path(folder) / "checks"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", str(main), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
