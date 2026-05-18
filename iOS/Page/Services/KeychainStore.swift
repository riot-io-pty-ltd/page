import Foundation
import Security

/// Persistent string storage for the relay token + pairing state. Writes to
/// both Keychain (preferred) and UserDefaults (fallback). Reads try Keychain
/// first, then UserDefaults, then writes the value back to whichever was
/// missing so they stay in sync.
///
/// Why two backends: in iOS Simulator, Keychain items sometimes don't survive
/// `xcrun simctl uninstall` or device wipes the way they do on real devices.
/// For a non-secret-grade token (it can be rotated from the Mac at any time),
/// UserDefaults is a perfectly acceptable fallback that's never failed.
enum KeychainStore {
    private static let keychainService = "page.app.secure"
    private static let userDefaultsPrefix = "page.app.secure."

    static func set(_ value: String, for key: String) {
        let data = Data(value.utf8)

        // Keychain
        let delQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(delQuery as CFDictionary)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status != errSecSuccess {
            print("[KeychainStore] SecItemAdd \(key) failed: status=\(status)")
        }

        // UserDefaults — always also write here so we have a fallback.
        UserDefaults.standard.set(value, forKey: userDefaultsPrefix + key)
    }

    static func get(_ key: String) -> String? {
        // Try Keychain first
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecSuccess, let data = out as? Data, let s = String(data: data, encoding: .utf8) {
            return s
        }
        if status != errSecItemNotFound {
            print("[KeychainStore] SecItemCopyMatching \(key) status=\(status)")
        }

        // Fall back to UserDefaults
        if let s = UserDefaults.standard.string(forKey: userDefaultsPrefix + key) {
            print("[KeychainStore] fell back to UserDefaults for \(key)")
            // Re-prime Keychain so future reads are fast
            set(s, for: key)
            return s
        }

        return nil
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: userDefaultsPrefix + key)
    }
}
