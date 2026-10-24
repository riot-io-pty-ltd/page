import Foundation
import Security

/// Keychain-backed string storage for the relay token, relay URL, live-sessions
/// key, paired-Mac record and APNs device token.
///
/// Items use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: readable by
/// lock-screen notification actions and background pushes once the phone
/// has been unlocked after boot, and never included in backups. The relay
/// token is the only credential the Worker checks, and whoever holds it can
/// type into the Mac's agent sessions, so it must not live anywhere else.
///
/// Older builds also mirrored every value into UserDefaults (plaintext, and
/// included in iCloud/Finder backups). `get` migrates any such leftover into
/// the Keychain once and then deletes it, so existing installs stay paired.
enum KeychainStore {
    private static let keychainService = "page.app.secure"
    private static let legacyDefaultsPrefix = "page.app.secure."

    enum ReadError: Error {
        /// The device hasn't been unlocked since boot; try again later.
        case locked
        case other(OSStatus)
    }

    private static func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key
        ]
    }

    /// Update-then-add, so a failed write can never leave the old value
    /// deleted (the previous delete-then-add could silently unpair).
    @discardableResult
    static func set(_ value: String, for key: String) -> Bool {
        let data = Data(value.utf8)
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var status = SecItemUpdate(baseQuery(key) as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(key)
            add.merge(attrs) { _, new in new }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess {
            print("[KeychainStore] write \(key) failed: status=\(status)")
        }
        return status == errSecSuccess
    }

    /// The stored value, nil if there is none. Throws only when the Keychain
    /// can't be read right now, so callers can tell "not paired" apart from
    /// "phone still locked after reboot".
    static func read(_ key: String) throws -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            // Drop any plaintext leftover from older builds.
            UserDefaults.standard.removeObject(forKey: legacyDefaultsPrefix + key)
            guard let data = out as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return migrateLegacyValue(for: key)
        case errSecInteractionNotAllowed:
            throw ReadError.locked
        default:
            print("[KeychainStore] read \(key) status=\(status)")
            throw ReadError.other(status)
        }
    }

    /// Convenience for callers that treat "unreadable" like "absent".
    static func get(_ key: String) -> String? {
        (try? read(key)) ?? nil
    }

    static func delete(_ key: String) {
        SecItemDelete(baseQuery(key) as CFDictionary)
        UserDefaults.standard.removeObject(forKey: legacyDefaultsPrefix + key)
    }

    /// One-time move of a pre-hardening UserDefaults copy into the Keychain.
    /// The plaintext copy is removed only after the Keychain write succeeds,
    /// so a failure here can't unpair the user.
    private static func migrateLegacyValue(for key: String) -> String? {
        let defaultsKey = legacyDefaultsPrefix + key
        guard let legacy = UserDefaults.standard.string(forKey: defaultsKey) else { return nil }
        if set(legacy, for: key) {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
        return legacy
    }
}

/// The relay address and bearer token, read straight from the Keychain.
///
/// Every network path (including notification actions handled on a cold
/// background launch, before any SwiftUI view exists) reads credentials
/// through this one type, so there is no in-memory bridge to seed and nothing
/// to get out of sync.
struct RelayCredentials: Equatable {
    static let relayURLKey = "page.relayURL"
    static let relayTokenKey = "page.relayToken"

    let baseURL: URL
    let token: String

    static func current() -> RelayCredentials? {
        guard let token = KeychainStore.get(relayTokenKey), !token.isEmpty,
              let raw = KeychainStore.get(relayURLKey) else { return nil }
        // Stored values from older builds may be `wss://…/ws`; normalise the
        // same way pairing does. A stored URL that no longer validates (e.g.
        // the placeholder host) means we're effectively unpaired.
        guard case .success(let url) = PairingValidator.normaliseRelay(raw) else { return nil }
        return RelayCredentials(baseURL: url, token: token)
    }

    /// `url("reply", id)` -> `https://relay/reply/<percent-encoded id>`. Each
    /// segment is encoded on its own so an id can never inject a path.
    func url(_ segments: String..., query: [URLQueryItem] = []) -> URL? {
        guard var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        var segmentAllowed = CharacterSet.urlPathAllowed
        segmentAllowed.remove(charactersIn: "/")
        let encoded = segments.compactMap { $0.addingPercentEncoding(withAllowedCharacters: segmentAllowed) }
        guard encoded.count == segments.count else { return nil }
        comps.percentEncodedPath += "/" + encoded.joined(separator: "/")
        if !query.isEmpty { comps.queryItems = query }
        return comps.url
    }

    var webSocketURL: URL? {
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        comps?.scheme = "wss"
        comps?.percentEncodedPath += "/ws"
        return comps?.url
    }
}

/// The live-sessions key (`sk`) from the pairing QR, stored beside the relay
/// token with the same Keychain protection (never backed up, readable after
/// first unlock). Absent for pairings made with a Mac that predates live
/// sessions. Never logged.
enum SessionKeyStore {
    static let keychainKey = "page.sessionKey"

    static func current() -> Data? {
        KeychainStore.get(keychainKey).flatMap(Base64URL.decode).flatMap(SessionCrypto.validRootKey)
    }

    @discardableResult
    static func save(_ key: Data) -> Bool {
        guard SessionCrypto.validRootKey(key) != nil else { return false }
        return KeychainStore.set(Base64URL.encode(key), for: keychainKey)
    }

    static func clear() {
        KeychainStore.delete(keychainKey)
    }
}
