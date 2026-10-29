import Foundation
import Security

/// Strings in the login keychain under this app's bundle id, one account per key.
enum KeychainHelper {
    private static let service = Bundle.main.bundleIdentifier ?? "com.clangerror.ClangNotch"

    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    /// Replaces rather than updates: an item an older build of this self-signed app wrote can
    /// make an update ask for keychain approval (see `ClaudeUsageManager.loadMirroredToken`).
    @discardableResult
    static func save(key: String, value: String) -> Bool {
        delete(key: key)
        var item = query(key)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func load(key: String) -> String? {
        var item = query(key)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(key: String) -> Bool {
        let status = SecItemDelete(query(key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func exists(key: String) -> Bool {
        load(key: key) != nil
    }
}
