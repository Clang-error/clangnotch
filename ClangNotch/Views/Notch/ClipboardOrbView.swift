import AppKit
import Combine
import SwiftUI

/// 복사 방울: a copy from another app (`ClipboardManager.copied`) pulls a drop out of the closed
/// notch, below it or out of its side (설정 › 기능 › 클립보드 기록), that comes off as a small
/// black orb with the Done check in it and is drawn back in. Another copy while it is out redraws
/// the check and keeps it out a little longer. Out of the side it may cover menu bar icons for that
/// moment; it doesn't step aside for the cursor.
struct ClipboardOrbView: View {
    /// The closed surface it leaves from (wings included).
    let surfaceWidth: CGFloat
    let surfaceHeight: CGFloat
    /// Something black to come out of: a camera housing, or the closed notch drawing its surface
    /// (wings). An external display with a quiet notch has neither.
    let fromSurface: Bool
    /// Closed, on screen, and switched on.
    let enabled: Bool
    /// "down", "left" or "right" (`AppSettings.clipboardOrbDirection`).
    let direction: String
    /// "orb" (the check alone) or "pill" (check + 복사됨) (`AppSettings.clipboardOrbStyle`).
    let style: String
    /// How long it stays once off, in seconds (`AppSettings.foldSecondsCopy`, 설정 › 노치).
    let holdSeconds: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var distance: CGFloat = 0
    @State private var radius: CGFloat = 0
    @State private var neck: CGFloat = 0
    /// The orb pulled long (above 1) or pressed flat (below) along its way out, as it hangs and lets go.
    @State private var tall: CGFloat = 1
    /// Seconds into the drop coming out, which is drawn by the clock (`OrbPose.dropping`); below
    /// 0 the values above are drawn as they stand.
    @State private var dropTime: Double = -1
    /// How far the orb has grown into a pill, in points past its own width.
    @State private var extra: CGFloat = 0
    @State private var opacity: Double = 0
    @State private var showsCheck = false
    @State private var checkID = 0
    /// Detached or on its way back: a copy now redraws the check instead of dropping anew.
    @State private var isOut = false
    @State private var run: Task<Void, Never>?

    fileprivate static let blue = Color(red: 0.04, green: 0.52, blue: 1.0)

    private struct Route {
        let attach: CGPoint
        let direction: CGVector
        let distance: CGFloat
        let radius: CGFloat
        /// Nothing to come out of beside the notch: it grows where it settles and shrinks away.
        let pops: Bool
    }

    /// Below the notch the orb hangs 12 pt clear of it; out of a side it sits in the menu bar.
    /// Without a surface it drips from the screen's top edge instead, as the 에어팟 드롭다운
    /// does on an external display (2026-11-10).
    private func route(in width: CGFloat) -> Route {
        let centre = width / 2
        switch direction {
        case "left", "right":
            let sign: CGFloat = direction == "left" ? -1 : 1
            // The closed surface's sides sit its top corner radius in from its frame
            // (`NotchShape`): from the frame's edge the neck left a gap beside the wings.
            let side = surfaceWidth / 2 - cornerRadiusInsets.closed.top
            return Route(attach: CGPoint(x: centre + sign * side, y: surfaceHeight / 2),
                         direction: CGVector(dx: sign, dy: 0), distance: 10 + 12.5, radius: 12.5,
                         pops: !fromSurface)
        default:
            let top: CGFloat = fromSurface ? surfaceHeight : 0
            return Route(attach: CGPoint(x: centre, y: top), direction: CGVector(dx: 0, dy: 1),
                         distance: surfaceHeight - top + 12 + 17, radius: 17, pops: false)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let r = route(in: proxy.size.width)
            OrbDropLayer(time: dropTime,
                         pose: OrbPose(distance: distance, radius: radius, neck: neck, extra: extra, tall: tall),
                         attach: r.attach, direction: r.direction, fullDistance: r.distance, fullRadius: r.radius,
                         style: style, showsCheck: showsCheck, checkID: checkID)
            .opacity(opacity)
            .onReceive(ClipboardManager.shared.copied) { _ in
                guard enabled else { return }
                play(r, fromOut: isOut)
            }
        }
        .allowsHitTesting(false)
    }

    private func play(_ r: Route, fromOut: Bool) {
        run?.cancel()
        run = Task { @MainActor in
            let settle = Animation.spring(response: 0.3, dampingFraction: 0.62)
            let pillExtra = style == "pill" ? OrbPill(radius: r.radius).extra : 0
            if reduceMotion {
                // No drop or neck: it fades in where it settles and fades out again.
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) { distance = r.distance; radius = r.radius; neck = 0; tall = 1; extra = pillExtra; dropTime = -1 }
                withAnimation(.easeOut(duration: 0.15)) { opacity = 1 }
            } else if fromOut {
                // A copy while it was out (or going back in): out again, check redrawn. Still
                // dropping, it carries on as it was.
                withAnimation(settle) { distance = r.distance; radius = r.radius; neck = 0; tall = 1; opacity = 1 }
            } else if r.pops {
                var start = Transaction()
                start.disablesAnimations = true
                withTransaction(start) { distance = r.distance; radius = 0; neck = 0; tall = 1; extra = 0; opacity = 1; showsCheck = false; dropTime = -1 }
                withAnimation(settle) { radius = r.radius }
            } else {
                var start = Transaction()
                start.disablesAnimations = true
                // The drop comes out by the clock: swelling on its neck, then let go, bouncing to
                // where it settles and growing into a pill, each on its own curve
                // (`OrbPose.dropping`). As separate animations of these values they ran as one:
                // the shape is a single animated value, and each animation started while another
                // ran took the others over, so the neck, the bounce and the pill all moved on the
                // last one's curve and none as drawn (user, 2026-11-14). The values themselves go
                // to where the drop ends, for the hold and the way back in.
                withTransaction(start) {
                    distance = r.distance; radius = r.radius; neck = 0; tall = 1; extra = pillExtra
                    opacity = 1; showsCheck = false; dropTime = 0
                }
                withAnimation(.linear(duration: OrbPose.dropDuration)) { dropTime = OrbPose.dropDuration }
                // The check starts as the neck lets go.
                try? await Task.sleep(for: .seconds(OrbPose.swell))
                guard !Task.isCancelled else { return }
            }
            isOut = true
            checkID += 1
            showsCheck = true
            if pillExtra > 0, !reduceMotion {
                // The pill grows out of the orb while the check draws.
                withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) { extra = pillExtra }
            }
            try? await Task.sleep(for: .seconds(max(1, holdSeconds)))
            guard !Task.isCancelled else { return }
            if dropTime >= 0 {
                // The drop has long settled: from here the values are drawn as they stand.
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) { dropTime = -1 }
            }
            if extra > 0, !reduceMotion {
                // Back to an orb first, then in.
                withAnimation(.easeInOut(duration: 0.18)) { extra = 0 }
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
            }
            // Drawn back in (or, with nothing to go back into, shrunk away), check and all.
            withAnimation(.easeIn(duration: 0.22)) {
                if !reduceMotion {
                    if !r.pops { distance = 0 }
                    radius = r.pops ? 0 : r.radius * 0.25
                }
                opacity = 0
            }
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            showsCheck = false
            extra = 0
            isOut = false
        }
    }
}

/// The pill's measures for an orb of `radius`: the check where the orb had it, then 복사됨, with
/// as much room after the word as before the check. A fixed width left a wide gap after it (user,
/// 2026-11-14).
struct OrbPill {
    static let label = L("복사됨", "Copied")
    static let spacing: CGFloat = 5
    let radius: CGFloat

    /// About half the orb: the check pops to 1.18x once drawn (`DoneCheckmarkView`).
    var checkSize: CGFloat { radius * 0.95 }
    var font: Font { .system(size: radius < 15 ? 11 : 12, weight: .semibold) }
    var textWidth: CGFloat {
        let nsFont = NSFont.systemFont(ofSize: radius < 15 ? 11 : 12, weight: .semibold)
        return ceil((Self.label as NSString).size(withAttributes: [.font: nsFont]).width)
    }
    /// From the pill's end to the check's ring; the same room is left after the word, plus a little
    /// for the capsule's curve.
    var margin: CGFloat { radius - checkSize / 2 }
    /// Points the pill is wider than the orb.
    var extra: CGFloat { checkSize / 2 + Self.spacing + textWidth + margin + 2 - radius }

    /// How far the check (the pill's leading end) moves left of the orb's centre as it grows:
    /// none out of the right side, all of it out of the left, half below the notch.
    static func leftShift(extra: CGFloat, direction: CGVector) -> CGFloat {
        direction.dx > 0 ? 0 : direction.dx < 0 ? extra : extra / 2
    }
}

/// The pill's word, shown once the pill is wide enough to hold it. As a modifier that SwiftUI
/// animates by `extra` frame by frame: `.opacity(extra / full …)` on the view animated the final
/// opacity instead, so the word faded in from the first frame beside the still round orb (user's
/// recording, 2026-11-14).
private struct PillWordReveal: ViewModifier, Animatable {
    var extra: CGFloat
    let full: CGFloat
    var animatableData: CGFloat {
        get { extra }
        set { extra = newValue }
    }

    func body(content: Content) -> some View {
        content.opacity(full > 0 ? max(0, Double(extra / full) * 2 - 1) : 0)
    }
}

/// Where the drop is: how far out, how big, how much of its neck is left (1 tied to the notch … 0
/// gone), how far grown into a pill, and how stretched along its way out.
private struct OrbPose {
    var distance: CGFloat
    var radius: CGFloat
    var neck: CGFloat
    var extra: CGFloat
    var tall: CGFloat

    /// The drop swells on its neck this long, then lets go.
    static let swell = 0.18
    /// By now everything has settled.
    static let dropDuration = 0.98

    /// The drop coming out, `time` seconds in: it swells out on its neck, pulled a little long by
    /// its own weight; the neck lets go over 0.26 s (`OrbDropShape` shapes that); the orb bounces
    /// to where it settles, pressed flat for a moment and wobbling back round, like jelly; and it
    /// grows into a pill. Picked by the user from drafts (2026-11-14).
    static func dropping(at time: Double, distance: CGFloat, radius: CGFloat, pillExtra: CGFloat) -> OrbPose {
        guard time >= swell else {
            let out = CGFloat(1 - pow(1 - max(time, 0) / swell, 2))
            return OrbPose(distance: distance * 0.55 * out, radius: radius * (0.35 + 0.4 * out),
                           neck: 1, extra: 0, tall: 1 + 0.11 * out)
        }
        let since = time - swell
        let settled = spring(since, response: 0.3, damping: 0.45)
        return OrbPose(distance: distance * (0.55 + 0.45 * settled), radius: radius * (0.75 + 0.25 * settled),
                       neck: CGFloat(max(0, 1 - since / 0.26)),
                       extra: pillExtra * spring(since, response: 0.38, damping: 0.8),
                       tall: 1 + 0.11 * CGFloat(exp(-since / 0.11) * cos(2 * .pi * since / 0.19)))
    }

    /// An underdamped spring from 0 to 1, `time` seconds after it is let go.
    private static func spring(_ time: Double, response: Double, damping: Double) -> CGFloat {
        let frequency = 2 * Double.pi / response
        let damped = frequency * (1 - damping * damping).squareRoot()
        return CGFloat(1 - exp(-damping * frequency * time)
                       * (cos(damped * time) + damping * frequency / damped * sin(damped * time)))
    }
}

/// The drop and what rides in it, drawn frame by frame from one animated value: the clock while
/// it comes out, its pose otherwise.
private struct OrbDropLayer: View, Animatable {
    var time: Double
    var pose: OrbPose
    let attach: CGPoint
    let direction: CGVector
    let fullDistance: CGFloat
    let fullRadius: CGFloat
    let style: String
    let showsCheck: Bool
    let checkID: Int

    var animatableData: AnimatablePair<Double, AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>>>> {
        get {
            AnimatablePair(time, AnimatablePair(AnimatablePair(pose.distance, pose.radius),
                                                AnimatablePair(pose.neck, AnimatablePair(pose.extra, pose.tall))))
        }
        set {
            time = newValue.first
            let values = newValue.second
            pose = OrbPose(distance: values.first.first, radius: values.first.second, neck: values.second.first,
                           extra: values.second.second.first, tall: values.second.second.second)
        }
    }

    var body: some View {
        let pill = OrbPill(radius: fullRadius)
        let now = time >= 0
            ? OrbPose.dropping(at: time, distance: fullDistance, radius: fullRadius, pillExtra: style == "pill" ? pill.extra : 0)
            : pose
        let centre = CGPoint(x: attach.x + direction.dx * now.distance, y: attach.y + direction.dy * now.distance)
        // The check keeps the pill's start: the pill grows outward beside the notch, both ways below it.
        let checkCentre = CGPoint(x: centre.x - OrbPill.leftShift(extra: now.extra, direction: direction), y: centre.y)
        ZStack(alignment: .topLeading) {
            ZStack {
                OrbDropShape(attach: attach, direction: direction, pose: now, part: .neck)
                OrbDropShape(attach: attach, direction: direction, pose: now, part: .orb)
            }
            .foregroundStyle(.black)
            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            if showsCheck {
                // Rides with the orb and shrinks with it: removed with a transition it stayed
                // where it was while the orb went back in (user's recording, 2026-11-14).
                // About half the orb: the check pops to 1.18x once drawn, and at 1.2x the radius
                // it all but filled the orb (user, 2026-11-14).
                DoneCheckmarkView(color: ClipboardOrbView.blue, size: pill.checkSize)
                    .id(checkID)
                    .scaleEffect(max(now.radius / fullRadius, 0.01))
                    .position(checkCentre)
                if style == "pill" {
                    // Shows over the second half of the growth, and is cut to the pill, so it
                    // never sits outside it.
                    Text(OrbPill.label)
                        .font(pill.font)
                        .foregroundStyle(.white.opacity(0.92))
                        .fixedSize()
                        .modifier(PillWordReveal(extra: now.extra, full: pill.extra))
                        .position(x: checkCentre.x + pill.checkSize / 2 + OrbPill.spacing + pill.textWidth / 2,
                                  y: centre.y)
                        .mask(OrbDropShape(attach: attach, direction: direction, pose: now, part: .orb))
                }
            }
        }
    }
}

/// The drop: the orb, and the neck that ties it to the notch until it comes off. Drawn as two
/// shapes, since one path with both could cancel out where they overlap. `OrbDropLayer` hands it
/// each frame's pose, so it animates nothing itself.
private struct OrbDropShape: Shape {
    enum Part { case orb, neck }
    let attach: CGPoint
    let direction: CGVector
    let pose: OrbPose
    let part: Part

    func path(in rect: CGRect) -> Path {
        let (distance, radius, neck, extra, tall) = (pose.distance, pose.radius, pose.neck, pose.extra, pose.tall)
        let c = CGPoint(x: attach.x + direction.dx * distance, y: attach.y + direction.dy * distance)
        var path = Path()
        switch part {
        case .orb:
            guard radius > 0 else { return path }
            // An orb, or a pill grown out of it (`OrbPill`).
            let minX = c.x - radius - OrbPill.leftShift(extra: extra, direction: direction)
            let stretch = max(tall, 0.5), give = 1 / stretch.squareRoot()
            let width = (radius * 2 + extra) * (direction.dx != 0 ? stretch : give)
            let height = radius * 2 * (direction.dx != 0 ? give : stretch)
            let corner = min(width, height) / 2
            path.addRoundedRect(in: CGRect(x: minX + radius + extra / 2 - width / 2, y: c.y - height / 2,
                                           width: width, height: height),
                                cornerSize: CGSize(width: corner, height: corner))
        case .neck:
            guard neck > 0, radius > 0 else { return path }
            // A liquid stem: a little wide where it leaves the notch, pinched just before the orb.
            // A straight taper from the full height of the notch's side read as a flag beside the
            // menu bar (user's recording, 2026-11-14).
            let side = CGVector(dx: -direction.dy, dy: direction.dx)
            func at(_ point: CGPoint, along: CGFloat, across: CGFloat) -> CGPoint {
                CGPoint(x: point.x + direction.dx * along + side.dx * across,
                        y: point.y + direction.dy * along + side.dy * across)
            }
            // Letting go (`neck` 1 → 0): the stem thins gently to about half, its root narrowing
            // to the stem's own width; then its round end snaps off the notch, fast at first, and
            // sinks into the orb as a plain round rod. Picked by the user from drafts
            // (2026-11-14). Before: the stem thinned to a thread that stayed tied to the screen's
            // top edge and was cut off all at once; a thread coming off and following the orb in
            // was too thin to see; thinning to a quarter looked abrupt, and its last scrap
            // lingered on the orb.
            func smooth(_ x: CGFloat) -> CGFloat {
                let t = min(max(x, 0), 1)
                return t * t * (3 - 2 * t)
            }
            let gone = 1 - neck
            let thin = 1 - 0.5 * smooth(gone / 0.4)
            let waist = max(1, radius * 0.28) * thin
            let pulled = 1 - pow(1 - max(0, (gone - 0.3) / 0.7), 2.6)
            let left = 1 - pulled
            let half = waist + (min(radius, 11) * thin - waist) * (1 - smooth(gone / 0.3))
            // Where it spreads into the orb, down to the stem's own width at the end.
            let join = max(waist, radius * 0.72 * left)
            // From a little inside the notch, so no seam shows where it meets it; to where it
            // joins the orb, inside the orb's outline.
            let whole = distance - radius * 0.55 + 3
            let tip = -3 + whole * pulled
            // The round end, which never reaches back past where the stem started.
            let cap = min(half, tip + 3)
            let upper = tip + whole * left * 0.45
            let lower = -radius * 0.55 - min(radius * 0.55, whole * left * 0.6)
            path.move(to: at(attach, along: tip, across: half))
            path.addCurve(to: at(c, along: -radius * 0.55, across: join),
                          control1: at(attach, along: upper, across: waist * 1.2),
                          control2: at(c, along: lower, across: waist))
            path.addLine(to: at(c, along: -radius * 0.55, across: -join))
            path.addCurve(to: at(attach, along: tip, across: -half),
                          control1: at(c, along: lower, across: -waist),
                          control2: at(attach, along: upper, across: -waist * 1.2))
            if cap > 0 {
                path.addCurve(to: at(attach, along: tip, across: half),
                              control1: at(attach, along: tip - cap * 4 / 3, across: -half),
                              control2: at(attach, along: tip - cap * 4 / 3, across: half))
            }
            path.closeSubpath()
        }
        return path
    }
}
