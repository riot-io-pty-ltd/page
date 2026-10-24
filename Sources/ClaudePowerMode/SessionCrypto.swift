import CryptoKit
import Foundation

/// The opaque envelope a `sessions.update` / `sessions.command` frame
/// carries (SESSIONS-PROTOCOL.md §2): `{"v":1,"n":"<nonce>","c":"<ciphertext‖tag>"}`,
/// both base64url. It is the only part of a live-sessions frame the relay
/// sees.
struct SessionEnvelope: Equatable {
    let v: Int
    /// base64url 12-byte nonce.
    let n: String
    /// base64url ciphertext followed by the 16-byte GCM tag.
    let c: String

    /// Accepts only the shape the spec defines (`v == 1`, `n` and `c`
    /// strings); anything else is nil.
    init?(json: Any?) {
        guard let obj = json as? [String: Any],
              let v = (obj["v"] as? NSNumber)?.intValue, v == 1,
              let n = obj["n"] as? String, let c = obj["c"] as? String else { return nil }
        self.v = v
        self.n = n
        self.c = c
    }

    init(nonce: Data, sealed: Data) {
        v = 1
        n = SessionCrypto.base64URLEncode(nonce)
        c = SessionCrypto.base64URLEncode(sealed)
    }

    var jsonObject: [String: Any] { ["v": v, "n": n, "c": c] }
}

/// End-to-end encryption for the live-sessions view. The Mac and the phone
/// share a 32-byte root key from the pairing QR (`sk`); each direction has
/// its own HKDF subkey, so the relay can't reflect a Mac frame back to the
/// Mac as a command, and the frame type is the AAD, so it can't relabel one
/// either. Decrypting with the phone→Mac key is also what authorises a
/// command to type into a session: a leaked relay token alone can't.
enum SessionCrypto {
    enum Direction: String {
        case macToPhone = "mac->phone"
        case phoneToMac = "phone->mac"
    }

    static let salt = "page-sessions-v1"
    /// AAD of Mac → phone frames.
    static let updateAAD = "sessions.update"
    /// AAD of phone → Mac frames.
    static let commandAAD = "sessions.command"
    static let rootKeyLength = 32
    static let nonceLength = 12

    /// `HKDF-SHA256(ikm: root, salt: "page-sessions-v1", info: direction, 32 bytes)`.
    static func subkey(root: Data, _ direction: Direction) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: root),
                               salt: Data(salt.utf8),
                               info: Data(direction.rawValue.utf8),
                               outputByteCount: 32)
    }

    /// AES-256-GCM with a fresh random nonce. `nonce` exists only so the
    /// test vector can be reproduced; production never passes it (a reused
    /// nonce under one key breaks GCM).
    static func seal(_ plaintext: Data, key: SymmetricKey, aad: String, nonce: Data? = nil) -> SessionEnvelope? {
        do {
            let n = try nonce.map { try AES.GCM.Nonce(data: $0) } ?? AES.GCM.Nonce()
            let box = try AES.GCM.seal(plaintext, using: key, nonce: n, authenticating: Data(aad.utf8))
            return SessionEnvelope(nonce: n.withUnsafeBytes { Data($0) }, sealed: box.ciphertext + box.tag)
        } catch {
            return nil
        }
    }

    /// The plaintext, or nil for anything that doesn't authenticate under
    /// `key` and `aad` (wrong key or direction, relabelled frame, tampered,
    /// malformed). Callers never learn why.
    static func open(_ envelope: SessionEnvelope, key: SymmetricKey, aad: String) -> Data? {
        guard envelope.v == 1,
              let nonce = base64URLDecode(envelope.n), nonce.count == nonceLength,
              let sealed = base64URLDecode(envelope.c), sealed.count >= 16 else { return nil }
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
                                            ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
            return try AES.GCM.open(box, using: key, authenticating: Data(aad.utf8))
        } catch {
            return nil
        }
    }

    /// base64url without padding.
    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// base64url, with or without padding (the spec says readers accept both).
    static func base64URLDecode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.hasSuffix("=") { b.removeLast() }
        guard !b.contains("=") else { return nil }
        switch b.count % 4 {
        case 0: break
        case 2: b += "=="
        case 3: b += "="
        default: return nil
        }
        return Data(base64Encoded: b)
    }
}

/// Both directional subkeys of one pairing's root key.
struct SessionKeys {
    let macToPhone: SymmetricKey
    let phoneToMac: SymmetricKey

    /// nil unless `root` is exactly 32 bytes.
    init?(root: Data) {
        guard root.count == SessionCrypto.rootKeyLength else { return nil }
        macToPhone = SessionCrypto.subkey(root: root, .macToPhone)
        phoneToMac = SessionCrypto.subkey(root: root, .phoneToMac)
    }
}
