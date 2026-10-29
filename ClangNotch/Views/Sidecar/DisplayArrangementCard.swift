import AppKit
import SwiftUI

/// One screen as macOS lays it out: global coordinates, origin at the top left of the main
/// display, y down (`CGDisplayBounds`), which is also SwiftUI's orientation.
struct ArrangedDisplay: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let frame: CGRect
    let isSidecar: Bool
    let isBuiltin: Bool
    let isMain: Bool

    static func current() -> [ArrangedDisplay] {
        // Demo: a MacBook with a monitor above it and an iPad on Sidecar to its right.
        if DemoMode.isActive {
            return [
                ArrangedDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), isSidecar: false, isBuiltin: true, isMain: true),
                ArrangedDisplay(id: 2, frame: CGRect(x: -524, y: -1440, width: 2560, height: 1440), isSidecar: false, isBuiltin: false, isMain: false),
                ArrangedDisplay(id: 3, frame: CGRect(x: 1512, y: 0, width: 1366, height: 1024), isSidecar: true, isBuiltin: false, isMain: false),
            ]
        }
        return NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return nil }
            return ArrangedDisplay(id: id, frame: CGDisplayBounds(id),
                                   isSidecar: screen.localizedName.contains("Sidecar"),
                                   isBuiltin: CGDisplayIsBuiltin(id) != 0,
                                   isMain: CGDisplayIsMain(id) != 0)
        }
    }
}

/// 배치도 카드: the screens drawn like System Settings › Displays › Arrange. Any screen can be
/// dragged; the one last touched is the selected screen, shown green (the iPad until then).
/// Dropping snaps it against the nearest edge of another screen and applies the move the way
/// System Settings does, so macOS keeps it.
struct DisplayArrangementCard: View {
    let displays: [ArrangedDisplay]

    @State private var selected: CGDirectDisplayID?
    @State private var drag: CGSize = .zero
    /// A dropped screen's new origin, drawn until macOS reports the new layout.
    @State private var placed: (id: CGDirectDisplayID, origin: CGPoint)?

    private let accent = Color(red: 0.3, green: 0.85, blue: 0.55)
    private static let mapHeight: CGFloat = 160

    private var focus: CGDirectDisplayID? {
        if let selected, displays.contains(where: { $0.id == selected }) { return selected }
        return displays.first(where: \.isSidecar)?.id
    }

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                map(in: geometry.size)
            }
            .frame(height: Self.mapHeight)
            Text(L("화면을 끌어 위치를 바꿉니다", "Drag a screen to move it"))
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.5))
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal, 6)
        .onChange(of: displays) { _, _ in placed = nil }
    }

    private func origin(of display: ArrangedDisplay) -> CGPoint {
        placed?.id == display.id ? placed!.origin : display.frame.origin
    }

    private func map(in size: CGSize) -> some View {
        // All screens plus half the largest one's size on every side, so there's room to drag
        // any of them past the edge of the others.
        let largest = displays.map(\.frame.size).reduce(CGSize.zero) {
            CGSize(width: max($0.width, $1.width), height: max($0.height, $1.height))
        }
        let room = displays.map(\.frame).reduce(CGRect.null) { $0.union($1) }
            .insetBy(dx: -largest.width / 2, dy: -largest.height / 2)
        let scale = min(size.width / room.width, size.height / room.height)
        let inset = CGPoint(x: (size.width - room.width * scale) / 2, y: (size.height - room.height * scale) / 2)
        func place(_ origin: CGPoint) -> CGPoint {
            CGPoint(x: inset.x + (origin.x - room.minX) * scale, y: inset.y + (origin.y - room.minY) * scale)
        }
        let moving = drag != .zero ? displays.first { $0.id == focus } : nil

        return ZStack(alignment: .topLeading) {
            // Where the dragged screen lands if dropped now.
            if let moving {
                let target = place(Self.snapped(dragged(moving, scale: scale), to: others(than: moving)))
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(accent.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .frame(width: moving.frame.width * scale, height: moving.frame.height * scale)
                    .position(x: target.x + moving.frame.width * scale / 2, y: target.y + moving.frame.height * scale / 2)
            }
            ForEach(displays) { display in
                let topLeft = place(origin(of: display))
                let width = display.frame.width * scale, height = display.frame.height * scale
                screen(display, focused: display.id == focus)
                    .frame(width: width, height: height)
                    .contextMenu {
                        Button(L("주 화면으로 사용", "Use as Main Display")) {
                            let layout = displays
                            Task.detached(priority: .userInitiated) { Self.makeMain(display.id, in: layout) }
                        }
                        .disabled(display.isMain)
                    }
                    .offset(display.id == moving?.id ? drag : .zero)
                    .position(x: topLeft.x + width / 2, y: topLeft.y + height / 2)
                    .zIndex(display.id == focus ? 1 : 0)
                    .gesture(dragGesture(display, scale: scale))
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func others(than display: ArrangedDisplay) -> [CGRect] {
        displays.filter { $0.id != display.id }.map(\.frame)
    }

    /// The screen's frame in global coordinates where the drag has it right now.
    private func dragged(_ display: ArrangedDisplay, scale: CGFloat) -> CGRect {
        let start = origin(of: display)
        return CGRect(origin: CGPoint(x: start.x + drag.width / scale, y: start.y + drag.height / scale),
                      size: display.frame.size)
    }

    private func screen(_ display: ArrangedDisplay, focused: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        let symbol = display.isSidecar ? "ipad.landscape" : (display.isBuiltin ? "laptopcomputer" : "display")
        return shape
            .fill(focused ? accent.opacity(0.22) : Color.white.opacity(0.12))
            .overlay(shape.stroke(focused ? accent : Color.white.opacity(0.3), lineWidth: 1.5))
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(focused ? accent : .white.opacity(0.6))
            )
            // The menu bar, as System Settings draws it on the main screen.
            .overlay(alignment: .top) {
                if display.isMain {
                    Capsule().fill(Color.white.opacity(0.85))
                        .frame(height: 2.5)
                        .padding(.horizontal, 4)
                        .padding(.top, 3)
                }
            }
            .animation(.easeOut(duration: 0.15), value: focused)
    }

    /// A press selects the screen; a drag moves it.
    private func dragGesture(_ display: ArrangedDisplay, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                selected = display.id
                drag = value.translation
            }
            .onEnded { value in
                guard hypot(value.translation.width, value.translation.height) > 3 else {
                    drag = .zero
                    return
                }
                drag = value.translation
                let origin = Self.snapped(dragged(display, scale: scale), to: others(than: display))
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    placed = (display.id, origin)
                    drag = .zero
                }
                let layout = displays
                Task.detached(priority: .userInitiated) { Self.move(display.id, to: origin, in: layout) }
            }
    }

    /// The closest spot where the iPad rests against one side of another screen, sharing at
    /// least a quarter of the shorter edge, without overlapping any screen.
    static func snapped(_ rect: CGRect, to others: [CGRect]) -> CGPoint {
        var best = rect.origin
        var bestDistance = CGFloat.infinity
        for other in others {
            let marginX = min(rect.width, other.width) / 4
            let marginY = min(rect.height, other.height) / 4
            let x = min(max(rect.minX, other.minX - rect.width + marginX), other.maxX - marginX)
            let y = min(max(rect.minY, other.minY - rect.height + marginY), other.maxY - marginY)
            let candidates = [
                CGPoint(x: x, y: other.minY - rect.height),  // above
                CGPoint(x: x, y: other.maxY),                // below
                CGPoint(x: other.minX - rect.width, y: y),   // left
                CGPoint(x: other.maxX, y: y),                // right
            ]
            for candidate in candidates {
                let moved = CGRect(origin: candidate, size: rect.size).insetBy(dx: 1, dy: 1)
                guard !others.contains(where: { $0.intersects(moved) }) else { continue }
                let distance = hypot(candidate.x - rect.minX, candidate.y - rect.minY)
                if distance < bestDistance { best = candidate; bestDistance = distance }
            }
        }
        return CGPoint(x: best.x.rounded(), y: best.y.rounded())
    }

    /// Puts `id` at (0, 0), which makes it the main screen, and shifts the rest to match.
    private nonisolated static func makeMain(_ id: CGDirectDisplayID, in layout: [ArrangedDisplay]) {
        guard !DemoMode.isActive, let target = layout.first(where: { $0.id == id })?.frame.origin else { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        for display in layout {
            CGConfigureDisplayOrigin(config, display.id, Int32(display.frame.minX - target.x),
                                     Int32(display.frame.minY - target.y))
        }
        CGCompleteDisplayConfiguration(config, .permanently)
    }

    /// The main screen is whichever sits at (0, 0), so moving it directly would hand the menu
    /// bar to another screen (seen 2026-10-15). It stays put and the others move the other way.
    private nonisolated static func move(_ id: CGDirectDisplayID, to origin: CGPoint, in layout: [ArrangedDisplay]) {
        guard !DemoMode.isActive else { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        if CGDisplayIsMain(id) != 0 {
            for other in layout where other.id != id {
                CGConfigureDisplayOrigin(config, other.id, Int32(other.frame.minX - origin.x),
                                         Int32(other.frame.minY - origin.y))
            }
        } else {
            CGConfigureDisplayOrigin(config, id, Int32(origin.x), Int32(origin.y))
        }
        CGCompleteDisplayConfiguration(config, .permanently)
    }
}
