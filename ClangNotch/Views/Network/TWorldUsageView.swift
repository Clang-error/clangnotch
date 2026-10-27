import SwiftUI

struct TWorldUsageView: View {
    @ObservedObject private var session = TWorldSession.shared
    @State private var spinning = false
    /// Nothing publishes when the manual cooldown expires, so the view has to re-evaluate on its own.
    @State private var now = Date()
    private let accent = Color(red: 0.3, green: 0.85, blue: 0.55)

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(L("SKT 공유 데이터", "SKT shared data"), systemImage: "personalhotspot")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                if session.requiresLogin {
                    Button(L("로그인", "Sign in")) { session.showLogin() }
                        .font(.system(size: 10, weight: .semibold))
                } else {
                    Button(action: refresh) {
                        Image(systemName: "arrow.clockwise")
                            .rotationEffect(.degrees(spinning ? 360 : 0))
                            .opacity(session.canRefresh ? 1 : 0.3)
                    }
                    .disabled(!session.canRefresh)
                    .help(refreshHelp)
                }
            }
            if let balance = session.balance {
                HStack(alignment: .firstTextBaseline) {
                    Text(L(String(format: "%.2f GB 남음", balance.remainingGB), String(format: "%.2f GB left", balance.remainingGB)))
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundColor(remainingColor(balance.remainingFraction))
                    Spacer(minLength: 4)
                    Text("/ \(balance.totalGB, specifier: "%.2f") GB")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.7))
                }
                // Drawn by hand: macOS ProgressView ignores .tint and paints the system accent.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.1))
                        Capsule()
                            .fill(remainingColor(balance.remainingFraction))
                            .frame(width: max(3, geo.size.width * balance.remainingFraction))
                    }
                }
                .frame(height: 4)
                HStack(spacing: 4) {
                    Text(L(String(format: "%.2f GB 사용", balance.usedGB), String(format: "%.2f GB used", balance.usedGB)))
                    Spacer()
                    Text(balance.fetchedAt, style: .time)
                    Text(L("조회", "checked"))
                    if let next = session.nextAutoRefresh {
                        Text("·")
                        Text(next, style: .time)
                        Text(L("갱신", "next"))
                    }
                }
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.65))
            } else if session.isRefreshing {
                Text(L("잔여량 확인 중…", "Checking balance…")).font(.system(size: 10))
            } else if session.errorMessage == nil {
                Text(L("T world에 연결하면 공유 잔여량이 표시됩니다.", "Connect T world to see the shared balance."))
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.7))
            }
            if let error = session.errorMessage {
                Text((session.balance == nil ? "" : L("이전 조회값 · ", "Last reading · ")) + error)
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(.plain)
        .foregroundColor(.white.opacity(0.92))
        .padding(10)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1)))
        .task {
            // Speed shows this only on the configured SSID; the menu bar popover shows it whenever
            // connected. Either way the session's 10-minute cooldown bounds the traffic.
            while !Task.isCancelled {
                await session.refresh()
                now = Date()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }

    /// The shared pool's size changes month to month, so warn by share left, not by GB.
    private func remainingColor(_ fraction: Double) -> Color {
        if fraction <= 0.2 { return .red }
        if fraction <= 0.4 { return .yellow }
        return accent
    }

    private var refreshHelp: String {
        guard !session.canRefresh, let last = session.lastAttempt else { return L("지금 다시 조회 · 10분마다 자동 조회", "Check now · auto-checks every 10 min") }
        let wait = max(0, Int(180 - now.timeIntervalSince(last)))
        return L("수동 조회는 3분 간격 · \(wait)초 남음", "Manual checks every 3 min · \(wait)s left")
    }

    private func refresh() {
        Task {
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { spinning = true }
            await session.refresh(force: true)
            // The query itself takes about half a second, too short to read as feedback.
            try? await Task.sleep(for: .milliseconds(400))
            withAnimation(.linear(duration: 0.2)) { spinning = false }
        }
    }
}

struct TWorldSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var session = TWorldSession.shared
    @State private var loginID = ""
    @State private var password = ""

    var body: some View {
        Section {
            Toggle(L("사용", "Enabled"), isOn: $settings.enableTWorld)
                .onChange(of: settings.enableTWorld) { _, _ in Task { await session.syncWithSettings() } }
            // Tethering detection reads the same SSID, so it stays editable with the switch off.
            TextField(L("아이폰 핫스팟 SSID", "iPhone hotspot SSID"), text: $settings.tworldHotspotSSID)
            if settings.enableTWorld {
                HStack {
                    TextField(L("T ID 아이디", "T ID username"), text: $loginID)
                    SecureField(L("비밀번호", "Password"), text: $password)
                    Button(L("저장", "Save")) {
                        Task {
                            await session.saveCredentials(id: loginID, password: password)
                            password = ""
                        }
                    }
                    .disabled(loginID.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty || session.isRefreshing)
                }
                if session.hasCredentials {
                    Text(L("자동 로그인 저장됨 · 세션이 만료되면 T ID에 다시 로그인합니다.", "Auto-login saved · signs in to T ID again when the session expires."))
                        .font(.caption).foregroundColor(.secondary)
                }
                HStack {
                    Text(session.requiresLogin ? L("로그인 필요", "Login required") : L("저장된 로그인 사용", "Using saved login"))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(session.requiresLogin ? L("T world 로그인…", "Sign in to T world…") : L("다시 로그인…", "Sign in again…")) { session.showLogin() }
                    if !session.requiresLogin || session.balance != nil {
                        Button(L("연결 해제", "Disconnect")) { Task { await session.disconnect() } }
                            .disabled(session.isRefreshing)
                    }
                }
                if let error = session.errorMessage {
                    Text(error).font(.caption).foregroundColor(.orange)
                }
            }
        } header: {
            Text(L("SKT 공유 데이터", "SKT shared data"))
        }
        .task { await session.prepare() }
    }
}
