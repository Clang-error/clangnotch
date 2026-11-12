import AppKit
import Combine
import CoreAudio
import SwiftUI

/// 음파 막대: bars that follow the sound of what plays (`NowPlayingLevels`), in the artwork's
/// colour. Core Animation draws them, so the closed notch costs no SwiftUI redraws while they
/// move (a SwiftUI `repeatForever` redrew at display rate: the 2026-10-04 usage-card CPU fix).
/// With no levels (audio capture not allowed, or Bluetooth output with the mic in use) they
/// bounce by themselves.
struct MediaWaveform: NSViewRepresentable {
    struct Style: Equatable {
        let bars: Int
        let barWidth: CGFloat
        let spacing: CGFloat
        let height: CGFloat

        var width: CGFloat { CGFloat(bars) * barWidth + CGFloat(bars - 1) * spacing }

        /// The right wing next to the artwork, as in the Dynamic Island.
        static let wing = Style(bars: 5, barWidth: 1.8, spacing: 2.2, height: 14)
        /// At the right wing's edge while the agents or tethering hold the wings.
        static let mini = Style(bars: 3, barWidth: 1.4, spacing: 1.6, height: 10)
        static let card = Style(bars: 6, barWidth: 2.4, spacing: 2.6, height: 22)
        /// Over the 노치 띠's artwork, in white on a darkened bottom (the user picked it from
        /// renders, 2026-11-12).
        static let onArtwork = Style(bars: 4, barWidth: 1.7, spacing: 1.3, height: 9)
    }

    let style: Style
    var playing = true
    /// The artwork's colour; nil is the notch's own text colour.
    var color: NSColor? = nil
    @Environment(\.colorScheme) private var scheme

    func makeNSView(context: Context) -> WaveformView { WaveformView() }

    func updateNSView(_ view: WaveformView, context: Context) {
        let ink: NSColor = scheme == .dark ? .white : .black
        view.update(style: style, color: color ?? ink, playing: playing)
    }

    final class WaveformView: NSView {
        private var bars: [CALayer] = []
        private var current: (style: Style, color: NSColor, playing: Bool)?
        private var levels: [Float]?
        private var subscription: AnyCancellable?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            subscription = NowPlayingLevels.shared.bands.sink { [weak self] levels in
                self?.receive(levels)
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var intrinsicContentSize: NSSize {
            current.map { NSSize(width: $0.style.width, height: $0.style.height) } ?? .zero
        }

        func update(style: Style, color: NSColor, playing: Bool) {
            if let current, current.style == style, current.color == color, current.playing == playing { return }
            let rebuild = current?.style != style
            current = (style, color, playing)
            if rebuild {
                invalidateIntrinsicContentSize()
                bars.forEach { $0.removeFromSuperlayer() }
                bars = (0..<style.bars).map { _ in
                    let bar = CALayer()
                    bar.cornerRadius = style.barWidth / 2
                    layer?.addSublayer(bar)
                    return bar
                }
            }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.35)
            for bar in bars { bar.backgroundColor = color.withAlphaComponent(0.92).cgColor }
            CATransaction.commit()
            needsLayout = true
        }

        /// How low a bar goes: down to about a dot, so a beat has room to jump.
        private func rest(_ style: Style) -> CGFloat { max(style.barWidth / style.height, 0.12) }

        /// A bar's level: bars spread evenly from the lowest band to the highest, between two
        /// bands when they don't line up (five or three bars over six bands).
        private func level(for index: Int, of count: Int, in levels: [Float]) -> CGFloat {
            guard levels.count > 1, count > 1 else { return CGFloat(levels.first ?? 0) }
            let position = Float(index) * Float(levels.count - 1) / Float(count - 1)
            let low = Int(position), high = min(low + 1, levels.count - 1)
            let mix = position - Float(low)
            return CGFloat(levels[low] * (1 - mix) + levels[high] * mix)
        }

        private func receive(_ new: [Float]?) {
            let wasMetered = levels != nil
            levels = new
            guard let current else { return }
            guard let new, current.playing else {
                if wasMetered { needsLayout = true }   // back to bouncing
                return
            }
            if !wasMetered { bars.forEach { $0.removeAnimation(forKey: "bounce") } }
            CATransaction.begin()
            // About the 50 ms between levels, eased out: a beat snaps up, then the next level
            // takes over before it settles.
            CATransaction.setAnimationDuration(0.08)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            let floor = rest(current.style)
            for (index, bar) in bars.enumerated() {
                let level = self.level(for: index, of: bars.count, in: new)
                bar.transform = CATransform3DMakeScale(1, floor + (1 - floor) * level, 1)
            }
            CATransaction.commit()
        }

        override func layout() {
            super.layout()
            guard let (style, _, playing) = current else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let x0 = (bounds.width - style.width) / 2
            let floor = rest(style)
            for (index, bar) in bars.enumerated() {
                bar.bounds = CGRect(x: 0, y: 0, width: style.barWidth, height: style.height)
                bar.position = CGPoint(x: x0 + CGFloat(index) * (style.barWidth + style.spacing) + style.barWidth / 2,
                                       y: bounds.midY)
                guard playing else {
                    bar.removeAllAnimations()
                    bar.transform = CATransform3DMakeScale(1, floor, 1)
                    continue
                }
                // Levels move the bars directly; without them they bounce on their own.
                guard levels == nil else { continue }
                bar.transform = CATransform3DMakeScale(1, floor, 1)
                let middle = CGFloat(style.bars - 1) / 2
                let reach = 1 - abs(CGFloat(index) - middle) / max(middle, 1) * 0.35
                let bounce = CABasicAnimation(keyPath: "transform.scale.y")
                bounce.fromValue = floor
                bounce.toValue = reach
                // Different periods so the bars never line up into one pulse.
                bounce.duration = [0.42, 0.55, 0.37, 0.61, 0.48, 0.52][index % 6]
                bounce.autoreverses = true
                bounce.repeatCount = .infinity
                bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                bounce.timeOffset = Double(index) * 0.17
                bar.add(bounce, forKey: "bounce")
            }
            CATransaction.commit()
        }
    }
}

/// The track's artwork, or the playing app's icon when it has none. With `keepsShape` a wide
/// picture (a video thumbnail) sits whole in a fixed box, 1.6 times as wide as tall, with room
/// above and below, instead of the box growing with its width (user, 2026-11-12); square album
/// covers fill a square as before.
struct MediaArtwork: View {
    let playing: NowPlaying
    let size: CGFloat
    var keepsShape = false

    private var isWide: Bool {
        guard keepsShape, let artwork = playing.artwork, artwork.size.height > 0 else { return false }
        return artwork.size.width / artwork.size.height > 1.15
    }

    var body: some View {
        if isWide, let artwork = playing.artwork {
            Image(nsImage: artwork).resizable().interpolation(.high).scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: size * 0.14, style: .continuous))
                .frame(width: size * 1.6, height: size)
        } else {
            Group {
                if let artwork = playing.artwork {
                    Image(nsImage: artwork).resizable().interpolation(.high).scaledToFill()
                } else if let icon = playing.picture {
                    Image(nsImage: icon).resizable().interpolation(.high).scaledToFit()
                } else {
                    Image(systemName: "music.note").resizable().scaledToFit().padding(size * 0.22)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        }
    }
}

/// The 미디어 드롭다운's content, after the Dynamic Island's player (the user's design,
/// 2026-11-12): artwork in its own shape, title and artist with the bars in the artwork's colour,
/// a thick time line, and large white buttons with the output picker in grey.
struct MediaDropdownCardContent: View {
    let playing: NowPlaying
    let visible: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                MediaArtwork(playing: playing, size: 40, keepsShape: true)
                VStack(alignment: .leading, spacing: 1) {
                    FadingLine(text: playing.title, font: .system(size: 15, weight: .semibold), color: .primary)
                    FadingLine(text: playing.artist?.isEmpty == false ? playing.artist! : (playing.appName ?? ""),
                               font: .system(size: 15), color: .secondary)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                MediaWaveform(style: .card, playing: playing.isPlaying, color: playing.accent)
                    .frame(width: MediaWaveform.Style.card.width, height: MediaWaveform.Style.card.height)
            }
            Spacer(minLength: 14)
            if playing.duration != nil {
                MediaTimeline(playing: playing)
            }
            Spacer(minLength: 10)
            ZStack {
                HStack(spacing: 34) {
                    control("backward.fill", size: 19) { NowPlayingMonitor.shared.send(.prev) }
                    control(playing.isPlaying ? "pause.fill" : "play.fill", size: 25) { NowPlayingMonitor.shared.send(.toggle) }
                    control("forward.fill", size: 19) { NowPlayingMonitor.shared.send(.next) }
                }
                HStack {
                    PinButton()
                    Spacer()
                    AudioOutputMenu()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .scaleEffect(visible ? 1 : 0.94)
        .opacity(visible ? 1 : 0)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: visible)
    }

    private func control(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.primary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 40, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The card's 핀: pinned, it stays and can be dragged anywhere; unpinned, back under the notch.
private struct PinButton: View {
    @ObservedObject private var dropdown = AirPodsDropdown.media

    var body: some View {
        Button { dropdown.togglePin() } label: {
            Image(systemName: dropdown.pinned ? "pin.fill" : "pin")
                .font(.system(size: 17, weight: .regular))
                .rotationEffect(.degrees(dropdown.pinned ? 0 : 45))
                .foregroundStyle(dropdown.pinned ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 32, height: 30)
                .contentShape(Rectangle())
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: dropdown.pinned)
        }
        .buttonStyle(.plain)
        .help(dropdown.pinned ? L("핀 풀기: 원래 자리로", "Unpin: back under the notch")
                              : L("핀 꽂기: 접히지 않고 끌어서 옮길 수 있음", "Pin: stays up and can be dragged anywhere"))
    }
}

/// One line. Text longer than the room keeps flowing left with a copy of itself following
/// after a gap, so its start comes round again behind its end (user, 2026-11-12: jumping back
/// to the start looked like being dragged back). Edges fade while it moves; it moves only
/// while the card is up.
struct FadingLine: View {
    let text: String
    let font: Font
    let color: HierarchicalShapeStyle
    @State private var textWidth: CGFloat = 0
    @State private var room: CGFloat = 0
    @State private var shift: CGFloat = 0
    @State private var moving = false

    private static let gap: CGFloat = 36
    private static let speed: CGFloat = 30   // points a second
    private var overflows: Bool { textWidth > room + 0.5 }

    private var line: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    var body: some View {
        HStack(spacing: Self.gap) {
            line.background(GeometryReader { Color.clear.preference(key: WidthKey.self, value: $0.size.width) })
            if overflows { line }
        }
        .onPreferenceChange(WidthKey.self) { textWidth = $0 }
        .offset(x: -shift)
        // minWidth 0: without it the frame took the whole title's width, and a long title
        // pushed the card's content out past both its edges (user's screenshot, 2026-11-12).
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(GeometryReader { geometry in
            Color.clear.onAppear { room = geometry.size.width }
                .onChange(of: geometry.size.width) { _, width in room = width }
        })
        .clipped()
        .mask(LinearGradient(stops: [.init(color: moving ? .clear : .black, location: 0),
                                     .init(color: .black, location: moving ? 0.06 : 0),
                                     .init(color: .black, location: overflows ? 0.88 : 1),
                                     .init(color: overflows ? .clear : .black, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
        .task(id: "\(text)|\(overflows)|\(Int(textWidth))") { await flow() }
    }

    /// A moment to read the start, then one copy's length at a time, each starting where the
    /// last left the text (the copy stands exactly where the original began, so the reset is
    /// not seen).
    private func flow() async {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { shift = 0; moving = false }
        guard overflows else { return }
        try? await Task.sleep(for: .seconds(1.4))
        let distance = textWidth + Self.gap
        let duration = Double(distance / Self.speed)
        while !Task.isCancelled {
            withAnimation(.easeOut(duration: 0.3)) { moving = true }
            withAnimation(.linear(duration: duration)) { shift = distance }
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            withTransaction(still) { shift = 0 }
        }
    }

    private struct WidthKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }
}

/// Elapsed time, the bar, and the time left. Clicking or dragging on the bar moves playback.
private struct MediaTimeline: View {
    let playing: NowPlaying
    @State private var scrub: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = playing.duration ?? 0
            let position = scrub.map { $0 * duration } ?? playing.position(at: context.date) ?? 0
            let fraction = duration > 0 ? min(1, position / duration) : 0
            HStack(spacing: 10) {
                Text(Self.clock(position))
                    .frame(width: 38, alignment: .leading)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.primary.opacity(0.16))
                        Capsule().fill(.secondary)
                            .frame(width: max(6, geometry.size.width * fraction))
                    }
                    .frame(height: scrub == nil ? 6 : 8)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { scrub = min(1, max(0, $0.location.x / geometry.size.width)) }
                        .onEnded { value in
                            let target = min(1, max(0, value.location.x / geometry.size.width)) * duration
                            NowPlayingMonitor.shared.seek(to: target)
                            scrub = nil
                        })
                }
                .frame(height: 16)
                Text("\u{2212}" + Self.clock(max(0, duration - position)))
                    .frame(width: 42, alignment: .trailing)
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .animation(.easeOut(duration: 0.15), value: scrub == nil)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The output picker at the card's right: macOS's audio outputs, the current one checked.
/// Picking one makes it the default output, as the menu bar's sound menu does. A plain button
/// that opens an `NSMenu`: a SwiftUI `Menu` draws its label at the system's own size and the
/// icon stayed small whatever font it was given (user, 2026-11-12).
struct AudioOutputMenu: View {
    var size: CGFloat = 19

    var body: some View {
        Button { AudioOutputPicker.shared.show() } label: {
            Image(systemName: "airplayaudio")
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: size + 13, height: size + 11)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("소리 출력 장치", "Sound output"))
    }
}

/// 노치 띠: the open notch's top row, beside the camera housing, where nothing else goes.
/// While something plays it shows what, where the closed notch's wings had it: the artwork with
/// the bars over it and the title flowing on the left; the output button and previous ·
/// play/pause · next on the right.
struct NotchBandNowPlaying: View {
    @ObservedObject private var monitor = NowPlayingMonitor.shared
    /// The camera housing's width, kept clear in the middle.
    let housingWidth: CGFloat

    var body: some View {
        if let playing = monitor.nowPlaying, !monitor.pausedLong {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Button { NowPlayingMonitor.openApp(of: playing) } label: {
                        HStack(spacing: 7) {
                            ZStack(alignment: .bottom) {
                                MediaArtwork(playing: playing, size: 22)
                                // Darkens the cover's bottom so white bars show on a light one.
                                LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
                                    .clipShape(RoundedRectangle(cornerRadius: 22 * 0.24, style: .continuous))
                                MediaWaveform(style: .onArtwork, playing: playing.isPlaying, color: .white)
                                    .frame(width: MediaWaveform.Style.onArtwork.width, height: MediaWaveform.Style.onArtwork.height)
                                    .padding(.bottom, 2.5)
                            }
                            .frame(width: 22, height: 22)
                            FadingLine(text: playing.artist?.isEmpty == false ? "\(playing.title) · \(playing.artist!)" : playing.title,
                                       font: .system(size: 11.5, weight: .medium), color: .primary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(playing.appName.map { L("\($0)에서 보기", "Show in \($0)") } ?? "")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: housingWidth + 16)
                HStack(spacing: 4) {
                    AudioOutputMenu(size: 13)
                    control("backward.fill", size: 11) { NowPlayingMonitor.shared.send(.prev) }
                    control(playing.isPlaying ? "pause.fill" : "play.fill", size: 13) { NowPlayingMonitor.shared.send(.toggle) }
                    control("forward.fill", size: 11) { NowPlayingMonitor.shared.send(.next) }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .transition(.opacity)
        }
    }

    private func control(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

@MainActor
final class AudioOutputPicker: NSObject {
    static let shared = AudioOutputPicker()

    func show() {
        let menu = NSMenu()
        let current = AudioOutputs.defaultOutput()
        for output in AudioOutputs.all() {
            let item = NSMenuItem(title: output.name, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: output.id)
            item.state = output.id == current ? .on : .off
            menu.addItem(item)
        }
        // The card would fold under the open menu: the cursor has left it.
        AirPodsDropdown.media.setHovering(true)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        AirPodsDropdown.media.setHovering(false)
    }

    @objc private func pick(_ item: NSMenuItem) {
        guard let id = (item.representedObject as? NSNumber)?.uint32Value else { return }
        AudioOutputs.setDefault(AudioObjectID(id))
    }
}

enum AudioOutputs {
    struct Output { let id: AudioObjectID; let name: String }

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func all() -> [Output] {
        var where_ = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &where_, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &where_, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0,
                  let name = AudioMixerManager.strProp(id, kAudioObjectPropertyName),
                  // Private aggregate devices (ours, other apps' taps) aren't outputs to pick.
                  !name.hasPrefix("ClangNotch"), !isHidden(id) else { return nil }
            return Output(id: id, name: name)
        }
    }

    private static func isHidden(_ id: AudioObjectID) -> Bool {
        var hidden = address(kAudioDevicePropertyIsHidden)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &hidden, 0, nil, &size, &value) == noErr && value != 0
    }

    static func defaultOutput() -> AudioObjectID? {
        AudioMixerManager.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    }

    static func setDefault(_ id: AudioObjectID) {
        var where_ = address(kAudioHardwarePropertyDefaultOutputDevice)
        var value = id
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &where_, 0, nil,
                                   UInt32(MemoryLayout<AudioObjectID>.size), &value)
    }
}
