import Foundation

/// Every Mac this phone is paired with. One is active (its credentials are
/// the ones every network path reads, `RelayCredentials`); the others are
/// kept here, in the Keychain with the same protection, so switching is one
/// tap and their status can be checked in the background.
struct SavedMac: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    let relayURL: String
    let token: String
    /// The live-sessions key (base64url), absent for older Macs.
    let sessionKey: String?
    let pairedAt: Date

    var relayHost: String? { URL(string: relayURL)?.host }
}

enum SavedMacs {
    static let keychainKey = "page.savedMacs"
    static let maxMacs = 8

    /// Adds `mac`, replacing an entry with the same token (the same
    /// pairing scanned again). Newest first, at most `maxMacs`.
    static func upsert(_ list: [SavedMac], _ mac: SavedMac) -> [SavedMac] {
        var out = list.filter { $0.token != mac.token && $0.id != mac.id }
        out.insert(mac, at: 0)
        return Array(out.prefix(maxMacs))
    }

    static func removing(_ id: String, from list: [SavedMac]) -> [SavedMac] {
        list.filter { $0.id != id }
    }

    /// Which Mac to make active after the active one goes: the most
    /// recently paired of the rest.
    static func next(in list: [SavedMac], excluding id: String?) -> SavedMac? {
        list.filter { $0.id != id }.max { $0.pairedAt < $1.pairedAt }
    }

    static func decode(_ json: String?) -> [SavedMac] {
        guard let data = json?.data(using: .utf8) else { return [] }
        return (try? JSONDecoder.saved.decode([SavedMac].self, from: data)) ?? []
    }

    static func encode(_ list: [SavedMac]) -> String? {
        (try? JSONEncoder.saved.encode(list)).flatMap { String(data: $0, encoding: .utf8) }
    }
}

private extension JSONDecoder {
    static var saved: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }
}

private extension JSONEncoder {
    static var saved: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }
}
