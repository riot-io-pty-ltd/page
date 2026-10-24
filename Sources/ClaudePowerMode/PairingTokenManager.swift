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
/// A 0600-permission file survives rebuilds cleanly (the notification
/// hook also reads it).
///
/// Rotating the token retires the old one on the Worker: the Coordinator
/// sends `relay.retire` with the old token before switching, and the Worker
/// then refuses that token (410 `token_retired`), so phones still paired
/// with it are told to re-pair and a leaked old token reads nothing more.
/// (A Worker older than that ignores the frame; there the old token keeps
/// working until it is unused.)
enum PairingTokenManager {
    /// Posted (on the thread that called `regenerate()`) after a new token
    /// has been written. The Coordinator retires the old token (see
    /// `previousTokenKey`) and reconnects the relay with the new one.
    static let tokenDidChange = Notification.Name("PagePairingTokenDidChange")
    /// `tokenDidChange` userInfo: the token that was replaced. Present only
    /// when the new token was written and differs from it, so a failed
    /// write never retires the pairing still in use.
    static let previousTokenKey = "previousToken"

    private static let lock = NSLock()

    static var tokenFileURL: URL {
        storageDirectory.appendingPathComponent("relay_token.txt")
    }

    /// The live-sessions root key (`sk` in the pairing QR,
    /// SESSIONS-PROTOCOL.md §1), next to the token with the same 0600
    /// atomic write. It is what lets the phone read session content and
    /// type into a session, so it is regenerated with the token.
    static var sessionKeyFileURL: URL {
        storageDirectory.appendingPathComponent("session_key.txt")
    }

    private static var storageDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("ClaudePowerMode", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static let legacyKeychainService = "local.ClaudePowerMode.relayToken"
    private static let legacyKeychainAccount = "default"

    /// Returns existing token, or generates + stores a fresh one. Migrates
    /// from Keychain on first run after the file-storage switch.
    static func currentToken() -> String {
        lock.lock()
        defer { lock.unlock() }
        if let t = readFromFile() { return t }
        if let t = readFromKeychain(), store(t) {
            // First-run migration from old storage. Delete the Keychain copy
            // so a missing file can never resurrect a rotated-away token.
            deleteFromKeychain()
            return t
        }
        let fresh = generate()
        store(fresh)
        return fresh
    }

    /// Mints and stores a new token, then posts `tokenDidChange`. Paired
    /// phones must re-scan.
    @discardableResult
    static func regenerate() -> String {
        lock.lock()
        let previous = readFromFile()
        let fresh = generate()
        let ok = store(fresh)
        deleteFromKeychain()
        // A new pairing gets a new session key too: a phone holding the
        // old one must not keep reading (or typing into) sessions.
        if ok { rotateSessionKey(at: sessionKeyFileURL) }
        lock.unlock()
        Logger.shared.log(ok
            ? "Pairing token regenerated — paired phones must re-scan"
            : "Pairing token regeneration FAILED to write the token file")
        NotificationCenter.default.post(name: tokenDidChange, object: nil,
                                        userInfo: changeUserInfo(previous: previous, fresh: fresh, stored: ok))
        return fresh
    }

    /// Pure: the `tokenDidChange` userInfo for a regenerate.
    static func changeUserInfo(previous: String?, fresh: String, stored: Bool) -> [String: String]? {
        guard stored, let previous, !previous.isEmpty, previous != fresh else { return nil }
        return [previousTokenKey: previous]
    }

    /// JSON payload to embed in the QR. Includes everything an iOS app needs
    /// to start talking to the same Worker as this Mac. `relayBaseURL` must
    /// already be validated (`Config.relayBaseURL`) — it is always https
    /// (or http for a local `wrangler dev`), never ws/wss or the placeholder.
    ///
    /// `sessionKey` is the live-sessions root key (`currentSessionKey()`),
    /// sent as `sk`; nil leaves it out (older phones ignore it either way).
    /// Explicit rather than defaulted, so nothing builds a payload — a
    /// test, say — without deciding which key goes in it.
    static func pairingPayloadJSON(relayBaseURL: URL, token: String = currentToken(), sessionKey: Data?) -> String {
        var payload: [String: Any] = [
            "v": 1,
            "token": token,
            "relay": relayBaseURL.absoluteString,
            "host": Host.current().localizedName ?? "Mac"
        ]
        if let sessionKey, sessionKey.count == SessionCrypto.rootKeyLength {
            payload["sk"] = SessionCrypto.base64URLEncode(sessionKey)
        }
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: session key

    /// The live-sessions root key, generated and stored the first time it's
    /// needed. nil only when a fresh key couldn't be written (it is never
    /// handed out unsaved: the phone would get a key the Mac forgets).
    static func currentSessionKey(at url: URL = sessionKeyFileURL) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if let key = readSessionKey(at: url) { return key }
        return rotateSessionKey(at: url)
    }

    /// The stored key if the file holds exactly 32 base64url bytes.
    static func readSessionKey(at url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url),
              let s = String(data: data, encoding: .utf8),
              let key = SessionCrypto.base64URLDecode(s.trimmingCharacters(in: .whitespacesAndNewlines)),
              key.count == SessionCrypto.rootKeyLength else { return nil }
        return key
    }

    /// Writes a fresh key (caller holds `lock`). If the write fails the old
    /// file is removed, so a key that belonged to a replaced pairing is
    /// never used again; the next `currentSessionKey` tries once more.
    @discardableResult
    static func rotateSessionKey(at url: URL) -> Data? {
        let key = Data(randomBytes(SessionCrypto.rootKeyLength))
        guard store(SessionCrypto.base64URLEncode(key), at: url) else {
            unlink(url.path)
            Logger.shared.log("Couldn't write the live-sessions key file")
            return nil
        }
        return key
    }

    // MARK: file storage

    private static func readFromFile() -> String? {
        guard let data = try? Data(contentsOf: tokenFileURL),
              let s = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Writes the token so it is never readable by anyone else, not even
    /// for an instant: the temp file is created with mode 0600 (O_EXCL, so
    /// we never follow a planted file), fsynced, then renamed over the real
    /// one. `String.write(atomically:)` created it with the umask (0644)
    /// and chmod-ed afterwards, leaving a window.
    @discardableResult
    static func store(_ token: String, at url: URL = tokenFileURL) -> Bool {
        let dir = url.deletingLastPathComponent().path
        let tmp = "\(dir)/.\(url.lastPathComponent).\(getpid()).\(UInt32.random(in: 0...UInt32.max)).tmp"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            Logger.shared.log("Couldn't create token temp file: errno \(errno)")
            return false
        }
        let bytes = Array((token + "\n").utf8)
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        let synced = fsync(fd) == 0
        close(fd)
        guard written == bytes.count, synced, rename(tmp, url.path) == 0 else {
            Logger.shared.log("Couldn't write token file: errno \(errno)")
            unlink(tmp)
            return false
        }
        return true
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

    private static func deleteFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyKeychainService,
            kSecAttrAccount as String: legacyKeychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: token generation

    private static func generate() -> String {
        SessionCrypto.base64URLEncode(Data(randomBytes(32)))
    }

    private static func randomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // Never hand out a predictable secret; fall back to the system CSPRNG.
            var rng = SystemRandomNumberGenerator()
            bytes = (0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) }
        }
        return bytes
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
