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
