import AppKit
import SwiftUI

/// 설정 › 노치 › 노치 색. Stored as the raw value in `AppSettings.notchAppearance`.
enum NotchAppearanceMode: String, CaseIterable {
    case wallpaper, auto, light, dark
}

/// What the notch is painted with, closed wings included. `surface == nil` is the original
/// dark look (black notch, black-to-slate open notch).
struct NotchTheme: Equatable {
    var surface: Color?
    var scheme: ColorScheme

    static let dark = NotchTheme(surface: nil, scheme: .dark)
    static let light = NotchTheme(surface: Color(white: 0.96), scheme: .light)
}

/// Resolves the 노치 색 setting. "배경 따라" uses the wallpaper's colour just under the notch,
/// or a colour picked with the eyedropper; "자동" follows the system's light/dark appearance.
@MainActor
final class NotchAppearance: ObservableObject {
    static let shared = NotchAppearance()

    @Published private(set) var systemIsDark = NotchAppearance.readSystemIsDark()
    @Published private(set) var wallpaperColor: NSColor?
    /// The wallpaper is a rotating folder (or something without a file), so its colour can't
    /// be read: macOS records only the folder, not the picture on screen.
    @Published private(set) var wallpaperUnreadable = false
    private var sampledKey: String?

    private init() {
        // The global setting, not NSApp's appearance: the notch's own preferredColorScheme
        // could feed back into that and pin 자동 to whatever it picked first.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { _ in
            Task { @MainActor in NotchAppearance.shared.systemIsDark = NotchAppearance.readSystemIsDark() }
        }
        // Each Space can have its own wallpaper.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in NotchAppearance.shared.refreshWallpaper() }
        }
    }

    func theme(_ settings: AppSettings) -> NotchTheme {
        switch NotchAppearanceMode(rawValue: settings.notchAppearance) ?? .dark {
        case .dark: return .dark
        case .light: return .light
        case .auto: return systemIsDark ? .dark : .light
        case .wallpaper:
            let color = settings.notchWallpaperSource == "custom"
                ? Self.color(hex: settings.notchCustomColor) : wallpaperColor
            guard let color = color?.usingColorSpace(.sRGB) else { return .dark }
            // Relative luminance: dark ink on a light colour, white ink on a dark one.
            let luminance = 0.2126 * color.redComponent + 0.7152 * color.greenComponent
                + 0.0722 * color.blueComponent
            return NotchTheme(surface: Color(nsColor: color), scheme: luminance > 0.55 ? .light : .dark)
        }
    }

    /// Reads the wallpaper again if it changed. Runs on launch, on a Space switch, when the
    /// setting changes and as the notch opens; only does work in "배경 따라 › 바탕화면에서".
    func refreshWallpaper() {
        let settings = AppSettings.shared
        guard settings.notchAppearance == NotchAppearanceMode.wallpaper.rawValue,
              settings.notchWallpaperSource != "custom",
              let screen = NotchDetector.notchScreen else { return }
        let url = NSWorkspace.shared.desktopImageURL(for: screen)
        let values = try? url?.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
        guard let url, values?.isDirectory == false else {
            if !wallpaperUnreadable { wallpaperUnreadable = true }
            if wallpaperColor != nil { wallpaperColor = nil }
            sampledKey = nil
            return
        }
        if wallpaperUnreadable { wallpaperUnreadable = false }
        let size = screen.frame.size
        let key = "\(url.path)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(size)"
        guard key != sampledKey else { return }
        sampledKey = key
        Task.detached(priority: .utility) {
            let color = Self.sampleTopCentre(of: url, screenSize: size)
            await MainActor.run {
                let shared = NotchAppearance.shared
                guard shared.sampledKey == key else { return }
                shared.wallpaperColor = color
            }
        }
    }

    nonisolated private static func readSystemIsDark() -> Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    // MARK: - Hex

    nonisolated static func hex(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "" }
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }

    nonisolated static func color(hex: String) -> NSColor? {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    // MARK: - Wallpaper sample

    /// Average colour of the 600×80 pt band under the notch, as the picture sits on a screen
    /// of `screenSize` with "Fill Screen" (scaled to cover, overflow cropped evenly).
    /// The wallpaper window itself can't be captured: on 27.2 it reads back as flat grey,
    /// with or without Screen Recording permission (checked 2026-11-06).
    nonisolated private static func sampleTopCentre(of url: URL, screenSize: CGSize) -> NSColor? {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: 512] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let scale = max(screenSize.width / width, screenSize.height / height)
        let cropX = (width * scale - screenSize.width) / 2
        let cropY = (height * scale - screenSize.height) / 2
        let band = CGRect(x: (screenSize.width / 2 - 300 + cropX) / scale, y: cropY / scale,
                          width: 600 / scale, height: 80 / scale)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
        guard !band.isEmpty, let cropped = image.cropping(to: band) else { return nil }
        return averageColor(of: cropped)
    }

    nonisolated private static func averageColor(of image: CGImage) -> NSColor? {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var r = 0, g = 0, b = 0
        for i in stride(from: 0, to: width * height * 4, by: 4) {
            r += Int(pixels[i]); g += Int(pixels[i + 1]); b += Int(pixels[i + 2])
        }
        let n = CGFloat(width * height) * 255
        return NSColor(srgbRed: CGFloat(r) / n, green: CGFloat(g) / n, blue: CGFloat(b) / n, alpha: 1)
    }
}
