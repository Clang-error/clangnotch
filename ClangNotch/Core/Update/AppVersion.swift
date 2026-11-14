import Foundation

/// A ClangNotch version as the releases number it: "1.4.0", "1.4.1-beta.3", with or without the
/// tag's "v". A beta comes after everything before its number and before the release of it:
/// 1.4.0 < 1.4.1-beta.2 < 1.4.1-beta.3 < 1.4.1. Missing parts count as 0 ("1.4" = "1.4.0").
struct AppVersion: Comparable, CustomStringConvertible {
    let core: [Int]
    /// The beta's number; nil for a release.
    let beta: Int?
    let description: String

    init(_ text: String) {
        description = text
        let trimmed = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = trimmed.split(separator: "-", maxSplits: 1)
        core = parts.first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? [0]
        // "beta.3", "beta3", "rc.1": the number at its end, 0 when there is none.
        beta = parts.count > 1 ? Int(parts[1].reversed().prefix { $0.isNumber }.reversed().map(String.init).joined()) ?? 0 : nil
    }

    var isBeta: Bool { beta != nil }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.core.count, b.core.count) {
            let l = i < a.core.count ? a.core[i] : 0, r = i < b.core.count ? b.core[i] : 0
            if l != r { return l < r }
        }
        switch (a.beta, b.beta) {
        case let (x?, y?): return x < y
        case (_?, nil): return true      // a beta before its release
        default: return false
        }
    }

    static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
}
