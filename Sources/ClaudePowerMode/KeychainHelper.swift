import Foundation
import Security
import LocalAuthentication

/// Outcome of reading one secret.
enum SecretReadResult: Equatable {
    case found(String)
    case notFound
    /// The item exists but macOS wants to ask the user first (the app was
    /// re-signed since the item was saved, so its access list no longer
    /// names this binary). Only returned for reads with `allowUI: false`.
    case interactionRequired
    case failed(OSStatus)
}

/// A single secret (one service/account pair). Behind a protocol so unit
/// tests never touch the user's real Keychain.
protocol SecretStore: AnyObject {
    /// `allowUI: false` never shows a Keychain prompt: background work (a
    /// phone reply on the injection queue, a low-battery pause with nobody at
    /// the Mac) must fail fast rather than block on a dialog nobody answers.
    func read(allowUI: Bool) -> SecretReadResult
    /// Replaces the stored secret. Returns nil on success, else a short
    /// human-readable error.
    func write(_ secret: String) -> String?
    /// Removes the secret. Missing is not an error.
    @discardableResult
    func delete() -> Bool
}

/// Generic-password item in the login Keychain.
///
/// Why the legacy (file-based) login keychain and not the data-protection
/// keychain: the latter needs a keychain-access-group entitlement, which an
/// ad-hoc or development-signed menu-bar app doesn't carry. The login
/// keychain's per-item access list is tied to the code signature, so after
/// a re-sign macOS would prompt on the next read — background reads opt
/// out of that prompt (`allowUI: false`) and report `.interactionRequired`;
/// saving again from the setup window (user present) rewrites the item with
/// an access list for the current binary.
final class KeychainSecretStore: SecretStore {
    let service: String
    let account: String
    private let label: String

    /// The cmux socket password (see CmuxBridge).
    static let cmuxSocketPassword = KeychainSecretStore(
        service: CmuxBridge.keychainService,
        account: CmuxBridge.keychainAccount,
        label: "Page — cmux socket password"
    )

    init(service: String, account: String, label: String? = nil) {
        self.service = service
        self.account = account
        self.label = label ?? service
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func read(allowUI: Bool) -> SecretReadResult {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowUI { Self.disallowUI(&query) }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let s = String(data: data, encoding: .utf8) else { return .failed(errSecDecode) }
            return s.isEmpty ? .notFound : .found(s)
        case errSecItemNotFound:
            return .notFound
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            return .interactionRequired
        default:
            return .failed(status)
        }
    }

    /// Whether an item is saved, without reading the secret: an attributes-only
    /// query never returns the password and never shows a prompt.
    func exists() -> Bool {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        Self.disallowUI(&query)
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    func write(_ secret: String) -> String? {
        guard !secret.isEmpty else { return "The password is empty" }
        // Delete + add (not update) so the item's access list is rebuilt for
        // the binary that's running now — that is what fixes a re-signed app.
        SecItemDelete(baseQuery as CFDictionary)
        var attrs = baseQuery
        attrs[kSecValueData as String] = Data(secret.utf8)
        attrs[kSecAttrLabel as String] = label
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status == errSecSuccess { return nil }
        let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
        return "Couldn't save to the Keychain (\(message))"
    }

    @discardableResult
    func delete() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Makes a query fail with errSecInteractionNotAllowed instead of
    /// showing a Keychain prompt. Two switches, because the two keychains
    /// honour different ones: an LAContext with `interactionNotAllowed`
    /// (data-protection items), and `kSecUseAuthenticationUI` =
    /// `kSecUseAuthenticationUIFail` (the file-based login keychain, whose
    /// access-list prompt is what a re-signed Page would hit). The latter is
    /// deprecated in favour of the former but still the only one the legacy
    /// keychain reads, so it's set by its stable raw values ("u_AuthUI" /
    /// "u_AuthUIF", checked by a unit test) to keep the build warning-free.
    static func disallowUI(_ query: inout [String: Any]) {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        query[legacyAuthenticationUIKey] = legacyAuthenticationUIFail
    }

    static let legacyAuthenticationUIKey = "u_AuthUI"
    static let legacyAuthenticationUIFail = "u_AuthUIF"
}
