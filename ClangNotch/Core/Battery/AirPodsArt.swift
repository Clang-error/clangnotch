import AppKit

/// Apple's own AirPods renders, read at run time from macOS's private headphone frameworks.
/// They are never copied into the app or the repo. A model with no render falls back to an
/// SF Symbol, and so does every model if a macOS update moves the files.
/// Model codes and product IDs come from CoreBluetoothUI's `AssetPaths-*.plist`.
@MainActor
enum AirPodsArt {
    nonisolated enum Kind { case buds, headphones }

    nonisolated static func kind(for productID: UInt16) -> Kind? {
        switch productID {
        case 0x200A, 0x200D, 0x201F, 0x202D: return .headphones
        case 0x2002, 0x200F, 0x2013, 0x200E, 0x2014, 0x2024, 0x2027,
             0x2019, 0x201B, 0x2030, 0x2032, 0x2036, 0x2037: return .buds
        default: return nil
        }
    }

    /// The pair of buds, or the whole headphones.
    /// `color` is the AirPods Max colour code from its advertisement: 0x12–0x16 are the renders
    /// B515d-18…22 (midnight, starlight, blue, orange, purple).
    static func device(for productID: UInt16, color: UInt8? = nil) -> NSImage? {
        switch productID {
        case 0x2027:                         return translateRender("B788")
        case 0x2014, 0x2024:                 return translateRender("B698")
        case 0x2019, 0x201B:                 return translateRender("B768")
        case 0x2030, 0x2032, 0x2036, 0x2037: return translateRender("B868")
        case 0x200A, 0x200D, 0x201F, 0x202D:
            if let color, (0x12...0x16).contains(color) { return catalogImage("B515d-\(color)", in: headphoneAssets) }
            return catalogImage("B515d-Default", in: headphoneAssets)
        default:                             return nil
        }
    }

    /// A front-facing bud with its L/R on the stem, where the Mac has one (the Pros only).
    static func frontBud(for productID: UInt16, left: Bool) -> NSImage? {
        switch productID {
        case 0x2014, 0x2024: return catalogImage(left ? "airpod_left" : "airpod_right", in: headphoneAssets)
        case 0x2027:         return catalogImage(left ? "B788_airpod_left" : "B788_airpod_right", in: headphoneSettingsUI)
        default:             return nil
        }
    }

    /// Both front-facing buds side by side, left on the left.
    static func frontPair(for productID: UInt16) -> NSImage? {
        cached("\(productID)-front-pair") {
            guard let left = frontBud(for: productID, left: true), let right = frontBud(for: productID, left: false) else { return nil }
            let gap = left.size.width * 0.12
            let size = NSSize(width: left.size.width + gap + right.size.width, height: max(left.size.height, right.size.height))
            return NSImage(size: size, flipped: false) { _ in
                left.draw(in: NSRect(x: 0, y: 0, width: left.size.width, height: left.size.height))
                right.draw(in: NSRect(x: left.size.width + gap, y: 0, width: right.size.width, height: right.size.height))
                return true
            }
        }
    }

    /// One bud: the front-facing render, else cut from the pair render (left bud on the left).
    static func singleBud(for productID: UInt16, left: Bool) -> NSImage? {
        if let front = frontBud(for: productID, left: left) { return front }
        return cached("\(productID)-\(left ? "L" : "R")") {
            guard let pair = device(for: productID),
                  let cg = pair.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            let half = cg.width / 2
            let rect = CGRect(x: left ? 0 : half, y: 0, width: cg.width - half, height: cg.height)
            return cg.cropping(to: rect).map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        }
    }

    /// The only case render on the Mac is the newest AirPods Pro's; every model borrows it.
    static var chargingCase: NSImage? { catalogImage("B788_case-closed-charged", in: headphoneSettingsUI) }

    // MARK: - Banner videos

    /// The turning 3D loops macOS shows in its own AirPods banner: 6 s, 168 px, one per model
    /// (product ID in decimal), a case loop beside most, a Max per colour code
    /// (Banner-PID-8223-18-Loop.mov = midnight). Models without one borrow their nearest
    /// sibling's; nil leaves the still render.
    private static let banners = "/System/Library/CoreServices/BluetoothUIService.app/Contents/Resources"

    static func bannerVideo(for productID: UInt16, isCase: Bool = false, color: UInt8? = nil) -> URL? {
        let ids: [Int]
        switch productID {
        case 0x2024:         ids = [0x2024, 0x2014]   // Pro 2 USB-C → Lightning's
        case 0x201B:         ids = [0x201B, 0x2019]   // AirPods 4 ANC → AirPods 4's
        case 0x202D, 0x200D: ids = [Int(productID), 0x201F, 0x200A]   // Max USB-C → Max's
        default:             ids = [Int(productID)]
        }
        let suffix = isCase ? "-Case" : ""
        for id in ids {
            let folder = "\(banners)/Banner-PID-\(id)\(suffix)-mov"
            var names: [String] = []
            if let color { names.append("Banner-PID-\(id)-\(color)\(suffix)-Loop.mov") }
            names.append("Banner-PID-\(id)\(suffix)-Loop.mov")
            for name in names where FileManager.default.fileExists(atPath: "\(folder)/\(name)") {
                return URL(fileURLWithPath: "\(folder)/\(name)")
            }
        }
        return nil
    }

    // MARK: - This Mac

    /// This Mac's picture from ProductKitCore (what the Finder sidebar uses), by its marketing
    /// name: MacBook Pro / Air with a notch on Apple silicon, the older shapes on Intel.
    static var thisMac: NSImage? {
        guard let name = thisMacImageName else { return nil }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return cached("mac-\(name)-\(dark)") {
            guard let mac = Bundle(path: "/System/Library/PrivateFrameworks/ProductKitCore.framework")?.image(forResource: name)
            else { return nil }
            return osWallpaper(dark: dark).flatMap { withScreen(mac, showing: $0) } ?? mac
        }
    }

    /// The default wallpaper of the macOS this runs on, so the Mac on the card shows what a new
    /// Mac of this OS shows, not the Sequoia picture ProductKitCore drew it with. Wallpaper
    /// extensions keep it as a large HEIC; a 600 px thumbnail is plenty for the screen.
    private static func osWallpaper(dark: Bool) -> CGImage? {
        let extensions = "/System/Library/ExtensionKit/Extensions"
        let file = dark ? "TahoeDark.heic" : "TahoeLight.heic"
        // Newest first: a later macOS's default wallpaper extension goes on top of this list.
        let candidates = ["NeptuneOneWallpaper.appex"].map { "\(extensions)/\($0)/Contents/Resources/\(file)" }
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 600,
        ] as CFDictionary)
    }

    /// Paints `wallpaper` over the screen of a Mac picture. The screen is where the old wallpaper
    /// is colourful; inside it, only pixels that aren't near-black are replaced, so the bezel,
    /// the notch and the rounded corners stay.
    private static func withScreen(_ mac: NSImage, showing wallpaper: CGImage) -> NSImage? {
        let best = mac.representations.max { $0.pixelsWide < $1.pixelsWide }
        var rect = CGRect(x: 0, y: 0, width: best?.pixelsWide ?? 0, height: best?.pixelsHigh ?? 0)
        guard let cg = mac.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let w = cg.width, h = cg.height
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let base = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: info),
              let paper = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: info)
        else { return nil }
        base.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let px = base.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        func saturated(_ i: Int) -> Bool {
            let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
            return px[i + 3] > 200 && max(r, g, b) - min(r, g, b) > 60
        }
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h { for x in 0..<w where saturated((y * w + x) * 4) {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX > minX + 20, maxY > minY + 20 else { return nil }
        // Rows in memory run top-down; CG draws bottom-up.
        let screen = CGRect(x: minX, y: h - 1 - maxY, width: maxX - minX + 1, height: maxY - minY + 1)
        let scale = max(screen.width / CGFloat(wallpaper.width), screen.height / CGFloat(wallpaper.height))
        let size = CGSize(width: CGFloat(wallpaper.width) * scale, height: CGFloat(wallpaper.height) * scale)
        paper.interpolationQuality = .high
        paper.draw(wallpaper, in: CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                                         width: size.width, height: size.height))
        guard let wp = paper.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        for y in minY...maxY { for x in minX...maxX {
            let i = (y * w + x) * 4
            let lum = (Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2])) / 3
            guard lum > 22 else { continue }   // bezel, notch, corner shadow
            px[i] = wp[i]; px[i + 1] = wp[i + 1]; px[i + 2] = wp[i + 2]; px[i + 3] = 255
        } }
        guard let out = base.makeImage() else { return nil }
        return NSImage(cgImage: out, size: NSSize(width: w, height: h))
    }

    /// "MacBook Pro", from system_profiler once (the model identifier alone doesn't say Pro or Air).
    nonisolated static let thisMacName: String = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPHardwareDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "Mac" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let item = (root?["SPHardwareDataType"] as? [[String: Any]])?.first
        return item?["machine_name"] as? String ?? "Mac"
    }()

    private static var thisMacImageName: String? {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return macImageName(identifier: String(cString: model), name: thisMacName)
    }

    /// ProductKitCore's picture for a Mac model. Identifiers before 2023 name the line
    /// ("MacBookPro18,3"); later ones are just "Mac15,6", so the marketing name says Pro or Air.
    /// - MacBookPro17,1 (M1 13") has no notch → the silver one without; 18,x (M1 Pro/Max 14/16")
    ///   and every "MacXX" Pro have one → space black; 16 and before (Intel) → the Touch Bar shape.
    /// - MacBookAir10,1 (M1) and Intel → the wedge; Mac14/15 Airs (M2, M3) → notch, midnight;
    ///   Mac16,12 on (M4 and later) → the 2025 Air.
    nonisolated static func macImageName(identifier: String, name: String) -> String? {
        func numbers(after prefix: String) -> (Int, Int)? {
            guard identifier.hasPrefix(prefix) else { return nil }
            let parts = identifier.dropFirst(prefix.count).split(separator: ",").compactMap { Int($0) }
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
        if let (major, _) = numbers(after: "MacBookPro") {
            switch major {
            case 18...:  return "MacBookProBlack"
            case 17:     return "MacBookPro2"
            default:     return "MacBookPro"
            }
        }
        if numbers(after: "MacBookAir") != nil { return "MacBookAir" }
        if numbers(after: "MacBook") != nil { return "MacBook" }
        if let (major, minor) = numbers(after: "Mac") {
            switch name {
            // Mac14,7, the M2 13", kept the Touch Bar body.
            case "MacBook Pro": return identifier == "Mac14,7" ? "MacBookPro" : "MacBookProBlack"
            case "MacBook Air": return major > 16 || (major == 16 && minor >= 12) ? "MacBookAir2025" : "MacBookAir2"
            case "MacBook Neo": return "MacBookNeo"
            case let other where other.hasPrefix("MacBook"): return "MacBook"
            default: return nil   // a desktop Mac: no battery card anyway
            }
        }
        return nil
    }

    nonisolated static func deviceSymbol(for productID: UInt16) -> String {
        switch productID {
        case 0x200A, 0x200D, 0x201F, 0x202D: return "airpodsmax"
        case 0x200E, 0x2014, 0x2024, 0x2027: return "airpodspro"
        case 0x2013:                         return "airpods.gen3"
        default:                             return "airpods"
        }
    }

    // MARK: - Loading

    private static let headphoneAssets = "/System/Library/PrivateFrameworks/HeadphoneAssets.framework"
    private static let headphoneSettingsUI = "/System/Library/PrivateFrameworks/HeadphoneSettingsUI.framework"
    private static var cache: [String: NSImage?] = [:]

    private static func cached(_ key: String, _ load: () -> NSImage?) -> NSImage? {
        if let hit = cache[key] { return hit }
        let image = load().flatMap(trimmed)
        cache[key] = image
        return image
    }

    private static func catalogImage(_ name: String, in framework: String) -> NSImage? {
        cached(name) { Bundle(path: framework)?.image(forResource: name) }
    }

    /// The Live Translation intro's photo of the pair: `<code>_Translate.ca/assets/<file>.png`,
    /// next to a `Gradient_sq.png` that isn't the buds.
    private static func translateRender(_ code: String) -> NSImage? {
        cached(code) {
            let assets = "\(headphoneAssets)/Resources/\(code)_Translate.ca/assets"
            let file = (try? FileManager.default.contentsOfDirectory(atPath: assets))?
                .sorted().first { $0.hasSuffix(".png") && !$0.hasPrefix("Gradient") }
            return file.flatMap { NSImage(contentsOfFile: "\(assets)/\($0)") }
        }
    }

    /// The renders sit in wide transparent margins (the buds fill about half of theirs), so
    /// crop to the drawn pixels to size them by what is visible.
    private static func trimmed(_ image: NSImage) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = cg.width, height = cg.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return image }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 10 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, let full = context.makeImage(),
              let crop = full.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
        else { return image }
        return NSImage(cgImage: crop, size: NSSize(width: crop.width, height: crop.height))
    }
}
