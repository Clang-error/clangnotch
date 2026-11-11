import AVFoundation
import AppKit
import SwiftUI

/// Sizes the 에어팟 드롭다운's drop is laid out in, top-left origin, full panel.
struct AirPodsBlobGeometry {
    let size: CGSize
    /// Where the notch ends.
    let menuBar: CGFloat
    /// The card's resting top.
    let cardTop: CGFloat
    let card: CGSize
    /// Width of the camera housing, or of the notch ClangNotch draws on a screen without one.
    /// Above the menu bar's bottom edge the blob may show only inside it.
    let notchWidth: CGFloat
    /// A camera housing hides the neck's top. Without one the neck starts above the screen's top
    /// edge, so the blob hangs from it the whole way: starting in the menu bar it stuck up like a
    /// spike, and the card rose off the top as a loose rounded box (2026-11-10 recording).
    let hasHousing: Bool
}

/// The panel's content. The card and its neck are two Core Animation shape layers in the notch
/// colour, so the drop moves in the render server at display rate; the name, renders and levels
/// are SwiftUI on top. (2026-11-09: a SwiftUI Canvas with blur + alpha threshold ran on the main
/// thread every frame and stuttered.)
@MainActor
final class AirPodsDropdownContainer: NSView {
    private let cardLayer = CAShapeLayer()
    private let neckLayer = CAShapeLayer()
    /// Holds both shapes so one mask keeps them out of the menu bar: nothing above its bottom
    /// edge except inside the notch's width. Without it the blob drew over the menu bar past the
    /// notch's sides (2026-11-09 recording).
    private let blobLayer = CALayer()
    private let blobMask = CAShapeLayer()
    private let hosting: FirstClickHostingView<AirPodsDropdownContent>
    private var geometry: AirPodsBlobGeometry?
    private var settled = false

    private static let corner: CGFloat = 26
    private static let samples = 48

    init(model: AirPodsDropdown) {
        hosting = FirstClickHostingView(rootView: AirPodsDropdownContent(model: model))
        super.init(frame: .zero)
        wantsLayer = true
        blobLayer.addSublayer(neckLayer)
        blobLayer.addSublayer(cardLayer)
        blobLayer.mask = blobMask
        layer?.addSublayer(blobLayer)
        addSubview(hosting)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The panel has just been sized to the full frame.
    func drop(_ geometry: AirPodsBlobGeometry, color: CGColor) {
        self.geometry = geometry
        settled = false
        cardLayer.fillColor = color
        neckLayer.fillColor = color
        animate(from: 0, to: 1, duration: AirPodsDropdown.dropDuration, easeOut: false)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// The panel has just shrunk to the card.
    func settle() {
        settled = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        blobLayer.frame = bounds
        blobMask.path = CGPath(rect: bounds, transform: nil)
        for shape in [cardLayer, neckLayer] {
            shape.removeAllAnimations()
            shape.frame = bounds
        }
        cardLayer.path = CGPath(roundedRect: bounds, cornerWidth: Self.corner, cornerHeight: Self.corner, transform: nil)
        neckLayer.path = nil
        CATransaction.commit()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// The panel has just grown back to the full frame; `from` is how far down the blob was.
    func rise(_ geometry: AirPodsBlobGeometry, from: Double) {
        self.geometry = geometry
        settled = false
        animate(from: from, to: 0, duration: AirPodsDropdown.riseDuration * from, easeOut: true)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        if settled || geometry == nil {
            hosting.frame = bounds
        } else if let g = geometry {
            // AppKit's origin is bottom-left.
            hosting.frame = NSRect(x: (bounds.width - g.card.width) / 2, y: bounds.height - g.cardTop - g.card.height,
                                   width: g.card.width, height: g.card.height)
        }
    }

    private func animate(from start: Double, to end: Double, duration: TimeInterval, easeOut: Bool) {
        guard let g = geometry, duration > 0 else { return }
        let steps = (0...Self.samples).map { start + (end - start) * Double($0) / Double(Self.samples) }
        let paths = steps.map { Self.paths(g, at: $0) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        blobLayer.frame = CGRect(origin: .zero, size: g.size)
        let mask = CGMutablePath()
        mask.addRect(CGRect(x: 0, y: 0, width: g.size.width, height: g.size.height - g.menuBar))   // below the menu bar (AppKit y up)
        if g.notchWidth > 0 {
            mask.addRect(CGRect(x: (g.size.width - g.notchWidth) / 2, y: g.size.height - g.menuBar,
                                width: g.notchWidth, height: g.menuBar))
        }
        blobMask.path = mask
        for (shape, values) in [(cardLayer, paths.map(\.card)), (neckLayer, paths.map(\.neck))] {
            shape.removeAllAnimations()
            shape.frame = CGRect(origin: .zero, size: g.size)
            shape.path = values.last
            let animation = CAKeyframeAnimation(keyPath: "path")
            animation.values = values
            animation.duration = duration
            animation.calculationMode = .linear
            if easeOut { animation.timingFunction = CAMediaTimingFunction(name: .easeIn) }
            shape.add(animation, forKey: "drop")
        }
        CATransaction.commit()
    }

    // MARK: - Shape

    /// Keyframes after the HTML mockup, in points: the card swells down out of the notch (no wider
    /// than the notch until it is below the menu bar), the neck thins and snaps, the card
    /// overshoots a little and settles.
    private static func paths(_ g: AirPodsBlobGeometry, at t: Double) -> (card: CGPath, neck: CGPath) {
        let w = g.card.width, h = g.card.height, mb = g.menuBar, top = g.cardTop
        let card = sample([(0, mb - 100, 110, 70), (0.25, mb - 20, 160, 120), (0.38, mb, 180, 150),
                           (0.5, mb + 2, w * 0.92, h * 0.9), (0.68, top + 10, w, h), (1, top, w, h)], at: t) // top, width, height
        let neck = sample([(0, 90, 70, 70), (0.38, 150, 130, 170), (0.5, 150, 110, 170), (0.6, 110, 30, 120),
                           (0.68, 50, 0, 40), (0.74, 0, 0, 0), (1, 0, 0, 0)], at: t)         // top width, waist, bottom width

        let mid = g.size.width / 2
        let rect = CGRect(x: mid - card.1 / 2, y: card.0, width: card.1, height: card.2)
        let radius = min(corner, rect.width / 2 - 0.5, rect.height / 2 - 0.5)
        let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: g.size.height)
        var transform = flip
        let cardPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: &transform)

        // From inside the camera housing down into the card's top edge. The sides bow in to a
        // waist and flare out where they meet the card, so it reads as one drop; it overlaps
        // the card by 2pt so the two layers show no seam.
        let topY = g.hasHousing ? mb - 14 : -20, bottomY = rect.minY + 2
        // Without a housing the whole neck shows, and at full width it read as a thick trunk
        // going back in (user, 2026-11-10): narrower at the top, pinched in the middle.
        let topHalf = neck.0 * (g.hasHousing ? 1 : 0.8) / 2, waist = neck.1 * (g.hasHousing ? 1 : 0.5) / 2
        let bottomHalf = min(neck.2, rect.width - 2 * radius) / 2
        let neckPath = CGMutablePath()
        neckPath.move(to: CGPoint(x: mid - topHalf, y: topY), transform: flip)
        neckPath.addLine(to: CGPoint(x: mid + topHalf, y: topY), transform: flip)
        neckPath.addCurve(to: CGPoint(x: mid + bottomHalf, y: bottomY),
                          control1: CGPoint(x: mid + waist, y: topY), control2: CGPoint(x: mid + waist, y: bottomY),
                          transform: flip)
        neckPath.addLine(to: CGPoint(x: mid - bottomHalf, y: bottomY), transform: flip)
        neckPath.addCurve(to: CGPoint(x: mid - topHalf, y: topY),
                          control1: CGPoint(x: mid - waist, y: bottomY), control2: CGPoint(x: mid - waist, y: topY),
                          transform: flip)
        neckPath.closeSubpath()
        return (cardPath, neckPath)
    }

    /// Piecewise interpolation with a smoothstep in each segment.
    private static func sample(_ keys: [(Double, CGFloat, CGFloat, CGFloat)], at t: Double) -> (CGFloat, CGFloat, CGFloat) {
        guard let next = keys.firstIndex(where: { $0.0 >= t }), next > 0 else { return (keys[0].1, keys[0].2, keys[0].3) }
        let a = keys[next - 1], b = keys[next]
        let raw = (t - a.0) / max(b.0 - a.0, 0.0001)
        let s = CGFloat(raw * raw * (3 - 2 * raw))
        return (a.1 + (b.1 - a.1) * s, a.2 + (b.2 - a.2) * s, a.3 + (b.3 - a.3) * s)
    }
}

/// The app is rarely active, so the first click must reach the card instead of being spent
/// on activating the window.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Name, X, Apple's renders and the levels, laid over the card.
struct AirPodsDropdownContent: View {
    @ObservedObject var model: AirPodsDropdown
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var appearance = NotchAppearance.shared

    var body: some View {
        let visible = model.contentVisible
        Group {
            if let card = model.card {
                VStack(spacing: 0) {
                    ZStack {
                        Text(card.name)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 40)
                        HStack {
                            Spacer()
                            Button { model.dismiss() } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22, height: 22)
                                    .background(Circle().fill(.primary.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 14)
                    .padding(.horizontal, 16)

                    Spacer(minLength: 0)

                    let kind = AirPodsArt.kind(for: card.productID)
                    let split = kind == .buds && card.symbol == nil && card.splitsBuds
                    HStack(alignment: .bottom, spacing: split ? 26 : 40) {
                        if split {
                            // One bud charging in the case, the other out: each with its own battery.
                            ForEach(["L", "R"], id: \.self) { side in
                                let left = side == "L"
                                item(AirPodsArt.singleBud(for: card.productID, left: left),
                                     symbol: AirPodsArt.deviceSymbol(for: card.productID), height: 58,
                                     level: left ? card.leftLevel : card.rightLevel,
                                     charging: left ? card.leftCharging : card.rightCharging,
                                     visible: visible, delay: left ? 0 : 0.05, bounceKey: "split")
                                // The pair comes apart: each bud springs out sideways from the middle.
                                .transition(.asymmetric(
                                    insertion: .offset(x: left ? 34 : -34).combined(with: .scale(scale: 0.7, anchor: .bottom))
                                        .combined(with: .opacity),
                                    removal: .offset(x: left ? 34 : -34).combined(with: .opacity)))
                            }
                        } else {
                            let art = card.isThisMac ? AirPodsArt.thisMac
                                : card.side.map { AirPodsArt.singleBud(for: card.productID, left: $0 == "L") }
                                ?? AirPodsArt.frontPair(for: card.productID)
                                ?? AirPodsArt.device(for: card.productID, color: card.color)
                            let charging = card.side.map { $0 == "L" ? card.leftCharging : card.rightCharging }
                                ?? (card.leftCharging && card.rightCharging)
                            // The pair (not one bud) and the Max turn like macOS's own banner.
                            let video = card.side == nil && card.symbol == nil && !card.isThisMac
                                ? AirPodsArt.bannerVideo(for: card.productID, color: card.color) : nil
                            item(art, symbol: card.isThisMac ? "laptopcomputer"
                                    : card.symbol ?? AirPodsArt.deviceSymbol(for: card.productID),
                                 height: video != nil ? 100 : kind == .headphones || card.symbol != nil || card.isThisMac ? 92 : 58,
                                 video: video, level: card.level,
                                 charging: charging, visible: visible, delay: 0,
                                 bounceKey: card.side ?? "both")
                            .transition(.scale(scale: 0.75, anchor: .bottom).combined(with: .opacity))
                        }
                        if kind == .buds, let caseLevel = card.caseLevel {
                            let caseVideo = AirPodsArt.bannerVideo(for: card.productID, isCase: true, color: card.color)
                            item(AirPodsArt.chargingCase, symbol: "airpods.chargingcase",
                                 height: caseVideo != nil ? 100 : 62, video: caseVideo, level: caseLevel,
                                 charging: card.caseCharging, visible: visible, delay: 0.1)
                        }
                    }
                    // Splitting into L and R, or merging back into the pair, springs with a bounce.
                    .animation(.spring(response: 0.5, dampingFraction: 0.58), value: split)
                    .padding(.bottom, 16)
                }
                .opacity(visible ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: visible)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The panel takes clicks only once settled, when it is exactly the card.
        .contentShape(Rectangle())
        .onTapGesture { model.openBatteryTab() }
        // Pressed and pushed up toward the notch: back in it goes.
        .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { drag in
            if drag.translation.height < -12 { model.dismiss() }
        })
        .onHover { model.setHovering($0) }
        .environment(\.colorScheme, appearance.theme(settings).scheme)
    }

    private func item(_ image: NSImage?, symbol: String, height: CGFloat, video: URL? = nil, level: Int?,
                      charging: Bool = false, visible: Bool, delay: Double, bounceKey: String = "") -> some View {
        VStack(spacing: 6) {
            Group {
                if let video {
                    LoopingVideo(url: video).frame(width: height)
                } else if let image {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                } else {
                    Image(systemName: symbol).resizable().scaledToFit().foregroundStyle(.secondary)
                        .padding(height * 0.12)
                }
            }
            .frame(height: height)
            .scaleEffect(visible ? 1 : 0.82, anchor: .bottom)
            .offset(y: visible ? 0 : 8)
            .opacity(visible ? 1 : 0)
            .animation(.spring(response: 0.45, dampingFraction: 0.62).delay(delay), value: visible)
            // One bud in, then the second: the buds hop as the picture turns into the pair.
            .keyframeAnimator(initialValue: CGFloat(1), trigger: bounceKey) { view, scale in
                view.scaleEffect(scale, anchor: .bottom)
            } keyframes: { _ in
                SpringKeyframe(0.8, duration: 0.08)
                SpringKeyframe(1.16, duration: 0.18, spring: .snappy)
                SpringKeyframe(0.95, duration: 0.14)
                SpringKeyframe(1, duration: 0.3, spring: .bouncy)
            }

            if let level {
                AirPodsBatteryGlyph(level: level, charging: charging)
                Text("\(level)%")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// iOS's little battery: outline, fill to the level, nub. Same colours as the 기기 줄.
private struct AirPodsBatteryGlyph: View {
    let level: Int
    /// A dark grey bolt over the fill while charging.
    var charging = false

    private var bolt: some View {
        Image(systemName: "bolt.fill").font(.system(size: 10.5, weight: .heavy))
    }

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary, lineWidth: 1)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(level <= 20 ? Color.red : level <= 40 ? Color.yellow : Color.green)
                    .frame(width: max(2, 20 * CGFloat(min(level, 100)) / 100))   // inside: 24 - 2 × 2 padding
                    .padding(2)
            }
            .frame(width: 24, height: 11)
            .overlay {
                if charging {
                    // iOS's look: a big dark bolt as tall as the battery, cut out of the fill by a
                    // light rim (the same symbol drawn around it, a point out each way).
                    ZStack {
                        ForEach(0..<16, id: \.self) { i in
                            let angle = Double(i) * .pi / 8
                            bolt.foregroundStyle(Color(white: 0.95))
                                .offset(x: cos(angle), y: sin(angle))
                        }
                        bolt.foregroundStyle(Color(white: 0.22))
                    }
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: charging)
            RoundedRectangle(cornerRadius: 1).fill(.secondary).frame(width: 1.5, height: 4)
        }
    }
}

/// One of macOS's AirPods banner loops, playing round and round with no sound, transparent
/// where the video is (HEVC with alpha). It plays only while the card is up.
private struct LoopingVideo: NSViewRepresentable {
    let url: URL

    final class PlayerView: NSView {
        let player = AVQueuePlayer()
        var looper: AVPlayerLooper?
        var url: URL?
        private let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspect
            playerLayer.backgroundColor = NSColor.clear.cgColor
            layer?.addSublayer(playerLayer)
            player.isMuted = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }

        func play(_ url: URL) {
            guard url != self.url else { return }
            self.url = url
            player.removeAllItems()
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            player.play()
        }
    }

    func makeNSView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.play(url)
        return view
    }

    func updateNSView(_ view: PlayerView, context: Context) { view.play(url) }

    static func dismantleNSView(_ view: PlayerView, coordinator: ()) {
        view.player.pause()
        view.looper = nil
    }
}
