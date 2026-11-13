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
    /// How far the orb has grown into a pill, in points past its own width.
    @State private var extra: CGFloat = 0
    @State private var opacity: Double = 0
    @State private var showsCheck = false
    @State private var checkID = 0
    /// Detached or on its way back: a copy now redraws the check instead of dropping anew.
    @State private var isOut = false
    @State private var run: Task<Void, Never>?

    private static let blue = Color(red: 0.04, green: 0.52, blue: 1.0)

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
            let pill = OrbPill(radius: r.radius)
            let centre = CGPoint(x: r.attach.x + r.direction.dx * distance, y: r.attach.y + r.direction.dy * distance)
            // The check keeps the pill's start: the pill grows outward beside the notch, both ways below it.
            let checkCentre = CGPoint(x: centre.x - OrbPill.leftShift(extra: extra, direction: r.direction), y: centre.y)
            ZStack(alignment: .topLeading) {
                ZStack {
                    OrbDropShape(attach: r.attach, direction: r.direction, distance: distance,
                                 radius: radius, neck: neck, extra: extra, part: .neck)
                    OrbDropShape(attach: r.attach, direction: r.direction, distance: distance,
                                 radius: radius, neck: neck, extra: extra, part: .orb)
                }
                .foregroundStyle(.black)
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                if showsCheck {
                    // Rides with the orb and shrinks with it: removed with a transition it stayed
                    // where it was while the orb went back in (user's recording, 2026-11-14).
                    // About half the orb: the check pops to 1.18x once drawn, and at 1.2x the radius
                    // it all but filled the orb (user, 2026-11-14).
                    DoneCheckmarkView(color: Self.blue, size: pill.checkSize)
                        .id(checkID)
                        .scaleEffect(max(radius / r.radius, 0.01))
                        .position(checkCentre)
                    if style == "pill" {
                        // Shows over the second half of the growth, so it never sits outside the pill.
                        Text(OrbPill.label)
                            .font(pill.font)
                            .foregroundStyle(.white.opacity(0.92))
                            .fixedSize()
                            .opacity(pill.extra > 0 ? max(0, Double(extra / pill.extra) * 2 - 1) : 0)
                            .position(x: checkCentre.x + pill.checkSize / 2 + OrbPill.spacing + pill.textWidth / 2,
                                      y: centre.y)
                    }
                }
            }
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
                withTransaction(still) { distance = r.distance; radius = r.radius; neck = 0; extra = pillExtra }
                withAnimation(.easeOut(duration: 0.15)) { opacity = 1 }
            } else if fromOut {
                // A copy while it was out (or going back in): out again, check redrawn.
                withAnimation(settle) { distance = r.distance; radius = r.radius; neck = 0; opacity = 1 }
            } else if r.pops {
                var start = Transaction()
                start.disablesAnimations = true
                withTransaction(start) { distance = r.distance; radius = 0; neck = 0; extra = 0; opacity = 1; showsCheck = false }
                withAnimation(settle) { radius = r.radius }
            } else {
                var start = Transaction()
                start.disablesAnimations = true
                withTransaction(start) {
                    distance = 0; radius = r.radius * 0.35; neck = 1; extra = 0; opacity = 1; showsCheck = false
                }
                // The drop swells out on its neck…
                withAnimation(.easeOut(duration: 0.18)) { distance = r.distance * 0.55; radius = r.radius * 0.75 }
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                // …and the neck lets go: the orb springs to where it settles.
                withAnimation(settle) { distance = r.distance; radius = r.radius; neck = 0 }
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

/// The drop: the orb, and the neck that ties it to the notch until it comes off. Drawn as two
/// shapes, since one path with both could cancel out where they overlap.
private struct OrbDropShape: Shape {
    enum Part { case orb, neck }
    let attach: CGPoint
    let direction: CGVector
    var distance: CGFloat
    var radius: CGFloat
    var neck: CGFloat
    var extra: CGFloat
    let part: Part

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(distance, radius), AnimatablePair(neck, extra)) }
        set {
            (distance, radius) = (newValue.first.first, newValue.first.second)
            (neck, extra) = (newValue.second.first, newValue.second.second)
        }
    }

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: attach.x + direction.dx * distance, y: attach.y + direction.dy * distance)
        var path = Path()
        switch part {
        case .orb:
            guard radius > 0 else { return path }
            // An orb, or a pill grown out of it (`OrbPill`).
            let minX = c.x - radius - OrbPill.leftShift(extra: extra, direction: direction)
            path.addRoundedRect(in: CGRect(x: minX, y: c.y - radius, width: radius * 2 + extra, height: radius * 2),
                                cornerSize: CGSize(width: radius, height: radius))
        case .neck:
            guard neck > 0.01, radius > 0 else { return path }
            // A liquid stem: a little wide where it leaves the notch, pinched just before the orb,
            // and thinning to nothing as the neck lets go. A straight taper from the full height
            // of the notch's side read as a flag beside the menu bar (user's recording, 2026-11-14).
            let side = CGVector(dx: -direction.dy, dy: direction.dx)
            func at(_ point: CGPoint, along: CGFloat, across: CGFloat) -> CGPoint {
                CGPoint(x: point.x + direction.dx * along + side.dx * across,
                        y: point.y + direction.dy * along + side.dy * across)
            }
            let stem = max(distance - radius * 0.6, 0)
            let base = min(radius, 11) * neck
            let waist = max(1, radius * 0.28) * neck
            let join = radius * 0.72
            // From a little inside the notch, so no seam shows where it meets it.
            path.move(to: at(attach, along: -3, across: base))
            path.addCurve(to: at(c, along: -radius * 0.55, across: join),
                          control1: at(attach, along: stem * 0.45, across: waist * 1.2),
                          control2: at(c, along: -radius * 1.1, across: waist))
            path.addLine(to: at(c, along: -radius * 0.55, across: -join))
            path.addCurve(to: at(attach, along: -3, across: -base),
                          control1: at(c, along: -radius * 1.1, across: -waist),
                          control2: at(attach, along: stem * 0.45, across: -waist * 1.2))
            path.closeSubpath()
        }
        return path
    }
}
