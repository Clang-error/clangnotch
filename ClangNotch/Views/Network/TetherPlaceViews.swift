import SwiftUI

private let tetherAccent = Color(red: 1.0, green: 0.62, blue: 0.2)

/// Wings of the dropdown: what is happening on the left, where on the right.
struct TetherPeekHeader: View {
    let placeName: String

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "personalhotspot")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(tetherAccent)
                Text("테더링")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                Spacer(minLength: 0)
            }
            .padding(.leading, 12)

            Spacer()

            Text(placeName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 90, alignment: .trailing)
                .padding(.trailing, 14)
        }
    }
}

struct TetherPeekContent: View {
    let placeName: String

    var body: some View {
        VStack(spacing: 2) {
            Text("\(placeName)에서 아이폰 테더링 사용 중")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
            Text("Wi-Fi로 바꾸면 데이터를 아낄 수 있어요")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.55))
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

/// Open-notch header warning; breathes so it catches the eye while tethering lasts.
struct TetherWarningLabel: View {
    @State private var bright = false

    var body: some View {
        Text("테더링 연결중 - 해제 권장")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.red)
            .lineLimit(1)
            .opacity(bright ? 1 : 0.35)
            .shadow(color: .red.opacity(bright ? 0.9 : 0), radius: bright ? 6 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    bright = true
                }
            }
    }
}

struct TetherPlacesSettingsView: View {
    @ObservedObject private var monitor = TetherPlaceMonitor.shared
    @ObservedObject private var network = NetworkInfoManager.shared
    @State private var newName = ""

    private let radiusOptions: [Double] = [100, 200, 500, 1000]

    private var trimmedName: String { newName.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        Section {
            ForEach(monitor.places) { place in
                HStack {
                    TextField(L("장소 이름", "Place name"), text: Binding(
                        get: { place.name },
                        set: { monitor.rename($0, for: place.id) }
                    ))
                    Button {
                        openInMaps(place)
                    } label: {
                        Image(systemName: "map")
                    }
                    .buttonStyle(.borderless)
                    .help(L("지도에서 보기", "Show in Maps"))
                    Picker(L("반경", "Radius"), selection: Binding(
                        get: { place.radius },
                        set: { monitor.setRadius($0, for: place.id) }
                    )) {
                        ForEach(radiusOptions, id: \.self) { Text("\(Int($0))m").tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button {
                        monitor.remove(place.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField(L("장소 이름 (집, 회사…)", "Place name (home, office…)"), text: $newName)
                if network.hasLocationAccess {
                    Button(monitor.isLocating ? L("위치 확인 중…", "Locating…") : L("현재 위치 추가", "Add current location")) {
                        monitor.addCurrentLocation(named: trimmedName.isEmpty ? L("장소 \(monitor.places.count + 1)", "Place \(monitor.places.count + 1)") : trimmedName)
                        newName = ""
                    }
                    .disabled(monitor.isLocating)
                } else {
                    Button(L("위치 권한 허용…", "Allow location access…")) { network.requestAccess() }
                }
            }
            if let error = monitor.lastError {
                Text(error).font(.caption).foregroundColor(.secondary)
            }
        } header: {
            Text(L("테더링 장소 알림", "Tethering place alerts"))
        } footer: {
            Text(L("""
            위의 아이폰 핫스팟 SSID에 연결된 채 등록한 장소의 반경 안에 있으면, \
            연결되는 즉시 그리고 이후 10분마다 노치로 알립니다. 위치 서비스 권한이 필요합니다.
            """, """
            While connected to the iPhone hotspot SSID above inside a saved place's radius, \
            the notch alerts you right away and every 10 minutes after. Needs Location Services access.
            """))
        }
    }

    private func openInMaps(_ place: TetherPlace) {
        var components = URLComponents()
        components.scheme = "maps"
        components.queryItems = [
            URLQueryItem(name: "ll", value: "\(place.latitude),\(place.longitude)"),
            URLQueryItem(name: "q", value: place.name)
        ]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}
