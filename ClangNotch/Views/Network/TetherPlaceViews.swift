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
                Text(L("테더링", "Tethering"))
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
            Text(L("\(placeName)에서 아이폰 테더링 사용 중", "Tethering to iPhone at \(placeName)"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
            Text(L("Wi-Fi로 바꾸면 데이터를 아낄 수 있어요", "Switch to Wi-Fi to save data"))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bright = false

    var body: some View {
        Text(L("테더링 연결중 - 해제 권장", "Tethering on - disconnect advised"))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.red)
            .lineLimit(1)
            // Dims only to 0.6 so the text stays readable through the whole breath.
            .opacity(bright ? 1 : 0.6)
            .shadow(color: .red.opacity(bright ? 0.9 : 0), radius: bright ? 6 : 0)
            .onAppear {
                guard !reduceMotion else { bright = true; return }
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
    @State private var removalID: TetherPlace.ID?

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
                        removalID = place.id
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help(L("장소 삭제", "Delete place"))
                }
                // Re-adding a place means standing there again, so deleting asks first.
                .confirmationDialog(
                    L("'\(place.name)' 장소를 삭제할까요?", "Delete \u{201C}\(place.name)\u{201D}?"),
                    isPresented: Binding(
                        get: { removalID == place.id },
                        set: { if !$0 { removalID = nil } }
                    )
                ) {
                    Button(L("삭제", "Delete"), role: .destructive) { monitor.remove(place.id) }
                    Button(L("취소", "Cancel"), role: .cancel) {}
                } message: {
                    Text(L("다시 추가하려면 그 장소에서 '현재 위치 추가'를 눌러야 합니다.",
                           "To add it back you have to be there and use Add current location."))
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
