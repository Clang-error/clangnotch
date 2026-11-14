import Foundation

/// Whether macOS lets this app capture other apps' sound (앱별 볼륨 믹서, the 음파 막대). There
/// is no public way to ask without making a tap, which may put up the prompt, so this reads TCC's
/// own preflight, as other audio-tap apps do. If the call isn't there, it counts as not allowed:
/// the settings then keep their "오디오 캡처 권한 필요" note, which is all this decides.
enum AudioCapturePermission {
    static var isGranted: Bool {
        guard let preflight else { return false }
        return preflight("kTCCServiceAudioCapture" as CFString, nil) == 0
    }

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private static let preflight: Preflight? = {
        guard let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
              let symbol = dlsym(tcc, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(symbol, to: Preflight.self)
    }()
}
