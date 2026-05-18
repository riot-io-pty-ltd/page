import Foundation
import Security
import CoreImage

/// Manages the relay token shared between the Mac and the paired iPhone.
///
/// Stored in a plain file at
///   `~/Library/Application Support/ClaudePowerMode/relay_token.txt`
/// rather than the macOS Keychain. Reason: Keychain ties access to the
/// binary's codesign identity, and our build pipeline ad-hoc re-signs the
/// app on every `./install.sh`. Each rebuild produces a different hash,
/// which revokes Keychain access, which makes us silently mint a NEW
/// token, which diverges from whatever the paired iPhone already knows.
/// A 0600-permission file survives rebuilds cleanly. The token is not
/// sensitive enough to warrant the Keychain dance — it can be rotated
/// freely from the menu bar.
enum PairingTokenManager {
    private static var tokenFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("ClaudePowerMode", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("relay_token.txt")
    }

    private static let legacyKeychainService = "local.ClaudePowerMode.relayToken"
    private static let legacyKeychainAccount = "default"

    /// Returns existing token, or generates + stores a fresh one. Migrates
    /// from Keychain on first run after the file-storage switch.
    static func currentToken() -> String {
        if let t = readFromFile() { return t }
        if let t = readFromKeychain() {
            // First-run migration from old storage.
            store(t)
            return t
        }
        let fresh = generate()
        store(fresh)
        return fresh
    }

    static func regenerate() -> String {
        let fresh = generate()
        store(fresh)
        Logger.shared.log("Pairing token regenerated — paired phones must re-scan")
        return fresh
    }

    /// JSON payload to embed in the QR. Includes everything an iOS app needs
    /// to start talking to the same Worker as this Mac.
    static func pairingPayloadJSON(relayURL: String) -> String {
        let payload: [String: Any] = [
            "v": 1,
            "token": currentToken(),
            "relay": relayURL,
            "host": Host.current().localizedName ?? "Mac"
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: file storage

    private static func readFromFile() -> String? {
        guard let data = try? Data(contentsOf: tokenFileURL),
              let s = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func store(_ token: String) {
        let url = tokenFileURL
        try? token.write(to: url, atomically: true, encoding: .utf8)
        // 0600 — owner read/write only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: legacy Keychain migration

    private static func readFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyKeychainService,
            kSecAttrAccount as String: legacyKeychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: token generation

    private static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

import AppKit

/// SwiftUI-free helper that produces an NSImage QR code from arbitrary text.
enum QRCode {
    static func image(from string: String, size: CGSize) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        let data = Data(string.utf8)
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ciImage = filter.outputImage else { return nil }
        let scaleX = size.width / ciImage.extent.size.width
        let scaleY = size.height / ciImage.extent.size.height
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
