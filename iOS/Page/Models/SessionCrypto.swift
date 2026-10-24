import Foundation
import CryptoKit

// End-to-end encryption for live sessions (docs/SESSIONS-PROTOCOL.md §2).
// The relay only ever sees `{"v":1,"n":…,"c":…}`; the Mac and this phone
// share the 32-byte session key from the pairing QR. Foundation/CryptoKit
// only, so the test vector runs in the plain-swiftc logic tests.

/// base64url without padding, as the sessions protocol writes it. Readers
/// accept padding (and the standard alphabet) too.
enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ raw: String) -> Data? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.hasSuffix("=") { s.removeLast() }
        switch s.count % 4 {
        case 1: return nil
        case 2: s += "=="
        case 3: s += "="
        default: break
        }
        return Data(base64Encoded: s)
    }
}

/// The two frame types that carry an envelope. Each is also the AAD, so the
/// relay can't relabel a Mac frame as a phone command or vice versa.
enum SessionFrameType {
    static let update = "sessions.update"
    static let command = "sessions.command"
}

enum SessionCrypto {
    static let keyLength = 32
    static let nonceLength = 12
    static let tagLength = 16
    static let envelopeVersion = 1
    static let salt = Data("page-sessions-v1".utf8)

    /// Per-direction subkeys: the relay can't reflect a Mac frame back to
    /// the Mac as a command.
    enum Direction: String {
        case macToPhone = "mac->phone"
        case phoneToMac = "phone->mac"
    }

    /// `sk` from the pairing payload: exactly 32 bytes, anything else is
    /// ignored (the pairing still works, just without live sessions).
    static func validRootKey(_ data: Data?) -> Data? {
        guard let data, data.count == keyLength else { return nil }
        return data
    }

    static func subkey(root: Data, direction: Direction) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: root), salt: salt,
                               info: Data(direction.rawValue.utf8), outputByteCount: keyLength)
    }

    struct Envelope: Equatable {
        let nonce: Data
        /// Ciphertext followed by the 16-byte GCM tag.
        let sealed: Data

        var json: [String: Any] {
            ["v": SessionCrypto.envelopeVersion, "n": Base64URL.encode(nonce), "c": Base64URL.encode(sealed)]
        }

        /// Strict shape: `v == 1`, a 12-byte nonce and at least a tag's worth
        /// of ciphertext. Anything else is dropped before decrypting.
        init?(json: [String: Any]) {
            guard (json["v"] as? NSNumber)?.intValue == SessionCrypto.envelopeVersion,
                  let n = (json["n"] as? String).flatMap(Base64URL.decode), n.count == SessionCrypto.nonceLength,
                  let c = (json["c"] as? String).flatMap(Base64URL.decode), c.count >= SessionCrypto.tagLength
            else { return nil }
            nonce = n
            sealed = c
        }

        init(nonce: Data, sealed: Data) {
            self.nonce = nonce
            self.sealed = sealed
        }
    }

    /// Encrypts `plaintext` under the `direction` subkey with `aad` (the
    /// frame type). `nonce` is for the spec test vector only: production
    /// callers leave it nil and get a fresh random nonce every time.
    static func seal(_ plaintext: Data, root: Data, direction: Direction, aad: String,
                     nonce fixedNonce: Data? = nil) throws -> Envelope {
        let key = subkey(root: root, direction: direction)
        let nonce = try fixedNonce.map { try AES.GCM.Nonce(data: $0) } ?? AES.GCM.Nonce()
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: Data(aad.utf8))
        return Envelope(nonce: Data(nonce), sealed: box.ciphertext + box.tag)
    }

    /// The plaintext, or nil if the envelope doesn't authenticate under this
    /// key, direction and frame type.
    static func open(_ envelope: Envelope, root: Data, direction: Direction, aad: String) -> Data? {
        guard envelope.sealed.count >= tagLength,
              let nonce = try? AES.GCM.Nonce(data: envelope.nonce) else { return nil }
        let split = envelope.sealed.count - tagLength
        let ciphertext = envelope.sealed.prefix(split)
        let tag = envelope.sealed.suffix(tagLength)
        guard let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag) else { return nil }
        return try? AES.GCM.open(box, using: subkey(root: root, direction: direction),
                                 authenticating: Data(aad.utf8))
    }
}
