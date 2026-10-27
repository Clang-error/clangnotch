import SwiftUI

struct SidecarView: View {
    @ObservedObject var manager: SidecarManager
    @State private var displays = ArrangedDisplay.current()

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 10) {
                if let error = manager.errorMessage {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                }
                if manager.devices.isEmpty {
                    emptyState
                } else {
                    ForEach(manager.devices) { device in
                        SidecarCard(device: device, manager: manager)
                    }
                }
                if displays.count > 1 {
                    DisplayArrangementCard(displays: displays)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                }
            }
            // The iPad card folding and the 배치도 카드 arriving move the layout together.
            .animation(Self.spring, value: manager.devices)
            .animation(Self.spring, value: displays.count > 1)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            manager.start()
            displays = ArrangedDisplay.current()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            withAnimation(Self.spring) { displays = ArrangedDisplay.current() }
        }
    }

    static let spring = Animation.spring(response: 0.4, dampingFraction: 0.86)

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "ipad.and.arrow.forward")
                .font(.system(size: 30, weight: .light))
                .foregroundColor(.white.opacity(0.25))
            Text(L("연결할 수 있는 iPad 없음", "No available iPad"))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
            Text(L("같은 Apple 계정과 Wi-Fi가 필요합니다", "Same Apple Account & Wi-Fi required"))
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }
}

private struct SidecarCard: View {
    let device: SidecarDeviceInfo
    @ObservedObject var manager: SidecarManager

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    /// Ties the glyph, name, status and button of the two layouts so they slide into place.
    @Namespace private var morph

    private let accent = Color(red: 0.3, green: 0.85, blue: 0.55)   // connected (green)
    private let pending = Color(red: 1.0, green: 0.78, blue: 0.3)   // switching (amber)

    private var busy: Bool { manager.busyDeviceID == device.id }
    private var connecting: Bool { busy && manager.busyTarget == true }
    private var disconnecting: Bool { busy && manager.busyTarget == false }
    private var connected: Bool { device.isConnected }

    /// Primary accent: amber while switching, green when connected, dim otherwise.
    private var tone: Color { busy ? pending : (connected ? accent : Color.white.opacity(0.25)) }

    private var statusText: String {
        if connecting { return L("연결 중…", "Connecting…") }
        if disconnecting { return L("연결 해제 중…", "Disconnecting…") }
        return connected ? L("연결됨", "Connected") : L("연결 안 됨", "Not connected")
    }

    private var buttonText: String {
        if connecting { return L("연결 중…", "Connecting…") }
        if disconnecting { return L("연결 해제 중…", "Disconnecting…") }
        return connected ? L("연결 해제", "Disconnect") : L("연결", "Connect")
    }

    var body: some View {
        Group {
            // Connected, the card folds into one short row so the 배치도 카드 below fits.
            if connected {
                HStack(spacing: 12) {
                    compactGlyph
                        .matchedGeometryEffect(id: "glyph", in: morph)
                    VStack(alignment: .leading, spacing: 3) {
                        nameText
                            .matchedGeometryEffect(id: "name", in: morph)
                        statusRow
                            .matchedGeometryEffect(id: "status", in: morph)
                    }
                    Spacer(minLength: 8)
                    actionButton
                        .frame(width: 110)
                        .matchedGeometryEffect(id: "button", in: morph)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            } else {
                VStack(spacing: 12) {
                    iPadGlyph
                    VStack(spacing: 3) {
                        nameText
                            .matchedGeometryEffect(id: "name", in: morph)
                        statusRow
                            .matchedGeometryEffect(id: "status", in: morph)
                    }
                    actionButton
                        .matchedGeometryEffect(id: "button", in: morph)
                }
                .padding(14)
            }
        }
        .animation(reduceMotion ? nil : SidecarView.spring, value: connected)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke((busy || connected) ? tone.opacity(0.45) : Color.white.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal, 6)
    }

    private var nameText: some View {
        Text(device.name)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white)
            .lineLimit(1)
    }

    private var statusRow: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(busy ? pending : (connected ? accent : Color.white.opacity(0.3)))
                .frame(width: 6, height: 6)
            Text(statusText)
                .font(.system(size: 11, weight: busy ? .semibold : .regular))
                .foregroundColor(busy ? pending : (connected ? accent.opacity(0.9) : .white.opacity(0.5)))
        }
    }

    /// The iPad glyph at row size, without the halo.
    private var compactGlyph: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(tone.opacity(0.12))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(tone, lineWidth: 2)
            )
            .frame(width: 26, height: 36)
            .overlay {
                if busy {
                    ProgressView().controlSize(.mini).tint(pending)
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(accent)
                }
            }
    }

    private var iPadGlyph: some View {
        ZStack {
            // Breathing halo while switching or connected
            Circle()
                .fill(tone.opacity((busy || connected) ? 0.18 : 0))
                .frame(width: 96, height: 96)
                .blur(radius: 14)
                .scaleEffect(pulse ? 1.12 : 0.9)
                .opacity((busy || connected) ? (pulse ? 0.55 : 0.25) : 0)

            // iPad body
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill((busy || connected) ? tone.opacity(0.12) : Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(tone, lineWidth: 2.5)
                )
                .frame(width: 50, height: 68)
                .overlay(glyphCenter)
                .matchedGeometryEffect(id: "glyph", in: morph)
        }
        .frame(height: 96)
        .onAppear {
            // Reduce Motion: the halo stays at rest instead of breathing.
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    @ViewBuilder
    private var glyphCenter: some View {
        if busy {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(pending)
        } else if connected {
            Image(systemName: "checkmark")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(accent)
        } else {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .light))
                .foregroundColor(.white.opacity(0.35))
        }
    }

    private var actionButton: some View {
        Button {
            guard !busy else { return }
            manager.toggle(device)
        } label: {
            HStack(spacing: 6) {
                if busy {
                    ProgressView().controlSize(.mini).tint(pending)
                }
                Text(buttonText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(busy ? pending : (connected ? .white.opacity(0.9) : .black))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                busy ? pending.opacity(0.15) : (connected ? Color.white.opacity(0.12) : accent),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .disabled(manager.busyDeviceID != nil)
    }
}
