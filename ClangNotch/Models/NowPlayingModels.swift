import AppKit
import Foundation

/// What is playing now, as macOS's Now Playing knows it.
struct NowPlaying: Equatable {
    var title: String
    var artist: String?
    var album: String?
    /// The app that plays it: Safari for the WebKit.GPU process that really plays a video.
    var bundleID: String?
    var appName: String?
    var isPlaying: Bool
    var artwork: NSImage?
    /// The colour the 음파 막대 take: the artwork's most vivid one.
    var accent: NSColor?
    /// The process that makes the sound (Safari's WebKit.GPU), for reading its levels.
    var pid: pid_t?
    var duration: TimeInterval?
    /// Where playback was at `elapsedAt`, moving on at `rate` (0 paused).
    var elapsed: TimeInterval?
    var elapsedAt: Date?
    var rate: Double = 0

    /// Where playback is now.
    func position(at now: Date) -> TimeInterval? {
        guard let elapsed else { return nil }
        let moved = isPlaying ? now.timeIntervalSince(elapsedAt ?? now) * (rate > 0 ? rate : 1) : 0
        return min(max(0, elapsed + moved), duration ?? .greatestFiniteMagnitude)
    }

    /// One track of one app. Elapsed time and the artwork arriving don't make a new one.
    var key: String { [bundleID ?? "", title, artist ?? ""].joined(separator: "\u{1F}") }

    /// The artwork comes a notification after the title, and only when it changes for this track:
    /// a reading without one keeps the picture `old` had for the same track, a new track starts
    /// without one until its own arrives.
    func keepingArtwork(of old: NowPlaying?) -> NowPlaying {
        guard artwork == nil, let old, old.key == key else { return self }
        var copy = self
        copy.artwork = old.artwork
        copy.accent = old.accent
        return copy
    }

    /// The artwork, or else the app's icon.
    var picture: NSImage? {
        if let artwork { return artwork }
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

extension NowPlaying {
    /// The artwork's colour as the design has it: its vivid pixels averaged, then made a soft
    /// light tint (a purple cover gives pale lavender bars). Nil for a grey picture.
    static func accent(of image: NSImage) -> NSColor? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var vivid = (r: 0.0, g: 0.0, b: 0.0, weight: 0.0)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let color = NSColor(srgbRed: CGFloat(pixels[i]) / 255, green: CGFloat(pixels[i + 1]) / 255,
                                blue: CGFloat(pixels[i + 2]) / 255, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            guard s > 0.25, b > 0.25 else { continue }
            let weight = Double(s * b)
            vivid.r += Double(color.redComponent) * weight
            vivid.g += Double(color.greenComponent) * weight
            vivid.b += Double(color.blueComponent) * weight
            vivid.weight += weight
        }
        // Mostly grey, black or white artwork: the bars stay the notch's own colour.
        guard vivid.weight > Double(side * side) * 0.04 else { return nil }
        let mixed = NSColor(srgbRed: vivid.r / vivid.weight, green: vivid.g / vivid.weight, blue: vivid.b / vivid.weight, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        mixed.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: min(max(s * 0.45, 0.14), 0.32), brightness: 0.9, alpha: 1)
    }
}

/// When the 미디어 드롭다운 comes down. The first try at showing what plays was dropped because
/// its card kept coming down: with sound from several places the Now Playing app keeps changing
/// hands, and every change dropped a card. So when what plays moves to another app, the card
/// drops only for a track not shown in the last 10 minutes and not within 20 s of the last card.
/// Within the app of the last card every new track drops one, the previous track too (skipping
/// with the keyboard missed cards under the 20 s rule, user 2026-11-12); the same track playing
/// again after a pause doesn't. Never while the app that plays is in front, nor for whatever was
/// already playing when reading started (a launch, a reinstall, the bridge restarting).
struct NowPlayingCardPolicy {
    enum Change: Equatable {
        case nothing
        /// Playback started, or another track plays: a card may drop once it has held a moment.
        case started(key: String)
        /// The same track: new artwork, or paused.
        case sameTrack
    }

    static let repeatWindow: TimeInterval = 10 * 60
    static let minimumGap: TimeInterval = 20

    private var seeded = false
    private var shownTracks: [String: Date] = [:]
    private var lastCard = Date.distantPast
    private var lastCardKey: String?
    private var lastCardApp: String?

    /// Reading starts over: its first answer is what already plays.
    mutating func restart() { seeded = false }

    /// A reading with no title: nothing plays, or an app switch is half done.
    mutating func readNothing() { seeded = true }

    mutating func change(from old: NowPlaying?, to new: NowPlaying) -> Change {
        guard seeded else { seeded = true; return .nothing }
        if new.isPlaying, old?.isPlaying != true || old?.key != new.key { return .started(key: new.key) }
        return old?.key == new.key ? .sameTrack : .nothing
    }

    /// After the change has held: whether the card drops now. Records it when it does.
    mutating func allowsCard(for playing: NowPlaying, key: String, frontmostBundleID: String?, now: Date) -> Bool {
        shownTracks = shownTracks.filter { now.timeIntervalSince($0.value) < Self.repeatWindow }
        return wouldAllowCard(for: playing, key: key, frontmostBundleID: frontmostBundleID, now: now)
    }

    /// The same answer without changing anything: asked the moment a track changes, so the
    /// wings can step aside before the card drops instead of showing the new track first.
    func wouldAllowCard(for playing: NowPlaying, key: String, frontmostBundleID: String?, now: Date) -> Bool {
        guard playing.isPlaying, playing.key == key else { return false }
        if let bundleID = playing.bundleID, frontmostBundleID == bundleID { return false }
        let sameApp = lastCardApp != nil && playing.bundleID == lastCardApp
        if let shown = shownTracks[key], now.timeIntervalSince(shown) < Self.repeatWindow,
           !sameApp || key == lastCardKey { return false }
        if !sameApp, now.timeIntervalSince(lastCard) < Self.minimumGap { return false }
        return true
    }

    mutating func cardShown(for playing: NowPlaying, at now: Date) {
        shownTracks[playing.key] = now
        lastCard = now
        lastCardKey = playing.key
        lastCardApp = playing.bundleID
    }
}
