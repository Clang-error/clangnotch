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
                Label("SKT 공유 데이터", systemImage: "personalhotspot")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                if session.requiresLogin {
                    Button("로그인") { session.showLogin() }
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
                    Text("\(balance.remainingGB, specifier: "%.2f") GB 남음")
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
                    Text("\(balance.usedGB, specifier: "%.2f") GB 사용")
                    Spacer()
                    Text(balance.fetchedAt, style: .time)
                    Text("조회")
                    if let next = session.nextAutoRefresh {
                        Text("·")
                        Text(next, style: .time)
                        Text("갱신")
                    }
                }
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.65))
            } else if session.isRefreshing {
                Text("잔여량 확인 중…").font(.system(size: 10))
            } else if session.errorMessage == nil {
                Text("T world에 연결하면 공유 잔여량이 표시됩니다.")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.7))
            }
            if let error = session.errorMessage {
                Text((session.balance == nil ? "" : "이전 조회값 · ") + error)
                    .font(.system(size: 9))
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
        guard !session.canRefresh, let last = session.lastAttempt else { return "지금 다시 조회 · 10분마다 자동 조회" }
        return "수동 조회는 3분 간격 · \(max(0, Int(180 - now.timeIntervalSince(last))))초 남음"
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
            TextField(L("아이폰 핫스팟 SSID", "iPhone hotspot SSID"), text: $settings.tworldHotspotSSID)
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
        } header: {
            Text(L("SKT 공유 데이터", "SKT shared data"))
        } footer: {
            Text(L("SSID가 정확히 일치할 때만 Speed 아래에 표시됩니다. Wi-Fi 이름 및 위치 접근을 허용해 주세요. Speed를 열어 둔 동안 10분 간격으로 조회합니다. 빈 SSID는 기능을 끕니다. 테더링과 공유 기기의 합산량입니다. T ID 아이디와 비밀번호를 저장하면 세션이 만료될 때 자동으로 다시 로그인하며, 저장하지 않으면 만료 때마다 직접 로그인해야 합니다. 비밀번호는 이 Mac의 키체인에만 저장됩니다.", "Shown under Speed only when the SSID matches exactly; allow Wi-Fi name and location access. Checked every 10 minutes while Speed is open. An empty SSID turns the feature off. The total covers tethering and shared devices. Saving your T ID username and password lets the app sign in again automatically when the session expires; otherwise you sign in by hand each time. The password is stored only in this Mac's keychain."))
        }
        .task { await session.prepare() }
    }
}
