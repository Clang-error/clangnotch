import AppKit

@main
struct NowPlayingChecks {
    static func track(_ title: String, app: String = "com.apple.Music", playing: Bool = true) -> NowPlaying {
        NowPlaying(title: title, artist: "Artist", album: nil, bundleID: app, appName: nil, isPlaying: playing, artwork: nil)
    }

    static func main() {
        let t0 = Date()
        var p = NowPlayingCardPolicy()
        // The first reading is what already played: no card.
        precondition(p.change(from: nil, to: track("A")) == .nothing, "the first reading seeds and drops nothing")

        // A new track that has held: a card.
        let b = track("B")
        guard case .started(let keyB) = p.change(from: track("A"), to: b) else { preconditionFailure("a new track starts") }
        precondition(p.allowsCard(for: b, key: keyB, frontmostBundleID: nil, now: t0), "a new track drops a card")
        p.cardShown(for: b, at: t0)

        // Paused and played again: the same track, no second card for 10 minutes.
        precondition(p.change(from: b, to: track("B", playing: false)) == .sameTrack, "pausing is the same track")
        guard case .started(let again) = p.change(from: track("B", playing: false), to: b) else { preconditionFailure("playing again starts") }
        precondition(!p.allowsCard(for: b, key: again, frontmostBundleID: nil, now: t0.addingTimeInterval(120)),
                     "the same track doesn't drop again within 10 minutes")
        precondition(p.allowsCard(for: b, key: again, frontmostBundleID: nil, now: t0.addingTimeInterval(11 * 60)),
                     "after 10 minutes it may")

        // Skipping in the same app: every track drops one, at once, the previous one too.
        let c = track("C")
        precondition(p.allowsCard(for: c, key: c.key, frontmostBundleID: nil, now: t0.addingTimeInterval(5)),
                     "the next track in the same app drops a card even 5 s later")
        p.cardShown(for: c, at: t0.addingTimeInterval(5))
        precondition(p.allowsCard(for: b, key: b.key, frontmostBundleID: nil, now: t0.addingTimeInterval(8)),
                     "going back to the previous track drops a card")
        p.cardShown(for: b, at: t0.addingTimeInterval(8))
        // The dry run answers the same and records nothing.
        let d = track("D")
        precondition(p.wouldAllowCard(for: d, key: d.key, frontmostBundleID: nil, now: t0.addingTimeInterval(9))
                     && p.wouldAllowCard(for: d, key: d.key, frontmostBundleID: nil, now: t0.addingTimeInterval(9)),
                     "asking ahead doesn't use the card up")
        precondition(!p.wouldAllowCard(for: d, key: d.key, frontmostBundleID: "com.apple.Music", now: t0.addingTimeInterval(9)),
                     "asking ahead sees the app in front")
        // Another app 5 s after a card: too soon.
        let other = track("Clip", app: "com.google.Chrome")
        precondition(!p.allowsCard(for: other, key: other.key, frontmostBundleID: nil, now: t0.addingTimeInterval(12)),
                     "another app within 20 s of the last card drops nothing")

        // The app that plays is in front: no card.
        var q = NowPlayingCardPolicy()
        _ = q.change(from: nil, to: track("X"))
        let safari = track("Video", app: "com.apple.Safari")
        precondition(!q.allowsCard(for: safari, key: safari.key, frontmostBundleID: "com.apple.Safari", now: t0),
                     "not while the playing app is in front")

        // A track that changed again before the delay ran out: no card for the old key.
        precondition(!q.allowsCard(for: track("Y"), key: track("Z").key, frontmostBundleID: nil, now: t0),
                     "a key that no longer plays drops nothing")

        // Two sources taking turns every 3 s for 5 minutes: at most one card each.
        var r = NowPlayingCardPolicy()
        var old: NowPlaying? = nil
        _ = r.change(from: nil, to: track("seed"))
        old = track("seed")
        var cards = 0
        for step in 0..<100 {
            let now = t0.addingTimeInterval(Double(step) * 3)
            let new = step % 2 == 0 ? track("Song", app: "com.apple.Music") : track("Clip", app: "com.google.Chrome")
            if case .started(let key) = r.change(from: old, to: new),
               r.allowsCard(for: new, key: key, frontmostBundleID: nil, now: now.addingTimeInterval(1.2)) {
                r.cardShown(for: new, at: now.addingTimeInterval(1.2))
                cards += 1
            }
            old = new
        }
        precondition(cards <= 2, "alternating sources dropped \(cards) cards")

        // Reading restarts (bridge restarted): the first answer seeds again.
        r.restart()
        precondition(r.change(from: nil, to: track("Other")) == .nothing, "a restart's first reading drops nothing")
        // Artwork: kept within one track, not carried to another.
        let picture = NSImage(size: NSSize(width: 1, height: 1))
        var withArt = track("Song"); withArt.artwork = picture
        precondition(track("Song", playing: false).keepingArtwork(of: withArt).artwork === picture,
                     "a reading of the same track without artwork keeps the picture")
        precondition(track("Next song").keepingArtwork(of: withArt).artwork == nil,
                     "another track doesn't inherit the picture")
        var fresh = track("Next song"); fresh.artwork = NSImage(size: NSSize(width: 2, height: 2))
        precondition(fresh.keepingArtwork(of: withArt).artwork === fresh.artwork, "its own artwork wins")
        print("PASS: now playing card policy (seed, once per track, 20 s gap, app in front, alternating sources, artwork per track)")
    }
}
