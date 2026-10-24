import Foundation

/// A pairing payload that passed validation: safe to probe and adopt.
struct ValidatedPairing: Equatable {
    let token: String
    /// Normalised HTTPS base URL of the relay (no trailing `/ws` or slash).
    let relayBaseURL: URL
    let macName: String

    var relayHost: String { relayBaseURL.host ?? relayBaseURL.absoluteString }
}

enum PairingValidationError: Error, Equatable {
    case empty
    case notPageCode
    case unsupportedVersion(Int)
    case missingToken
    case invalidRelay
    case insecureRelay
    case placeholderRelay

    var message: String {
        switch self {
        case .empty:
            return "Paste the pairing code from your Mac first."
        case .notPageCode:
            return "That isn't a Page pairing code. On your Mac, click the Page menu-bar icon → Pair phone… and scan the code shown there."
        case .unsupportedVersion(let v):
            return "This pairing code uses a newer format (v\(v)) than this app understands. Update Page on your iPhone."
        case .missingToken:
            return "The pairing code has no relay token. Open Pair phone… on your Mac again and use the new code."
        case .invalidRelay:
            return "The relay address in the pairing code isn't a valid URL. Check relayURL in your Mac's Page settings."
        case .insecureRelay:
            return "The relay address must start with https:// (or wss://). Update relayURL in your Mac's Page settings."
        case .placeholderRelay:
            return "Your Mac is still using the example relay address. Deploy your Cloudflare Worker, set relayURL in your Mac's Page settings, then show the pairing code again."
        }
    }
}

/// Parses and validates the JSON the Mac shows as a QR code or copies to the
/// clipboard: `{"v":1,"token":"…","relay":"https://…","host":"Roy's MacBook"}`.
///
/// There is deliberately no allow-list of relay hosts: every deployment is
/// self-hosted and its URL only arrives through this payload. What we can
/// check is shape, version, TLS, and that the Mac isn't still on the
/// placeholder relay (which would pair the phone to a dead host).
enum PairingValidator {
    static let supportedVersion = 1
    static let placeholderHostFragment = "your-page-relay"

    static func validate(_ rawText: String) -> Result<ValidatedPairing, PairingValidationError> {
        let text = normaliseQuotes(rawText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              dict["token"] != nil || dict["relay"] != nil else {
            return .failure(.notPageCode)
        }

        // `v` is an Int on every Mac build so far; accept "1" too.
        let version: Int? = (dict["v"] as? NSNumber)?.intValue ?? (dict["v"] as? String).flatMap(Int.init)
        guard let v = version else { return .failure(.notPageCode) }
        guard v == supportedVersion else { return .failure(.unsupportedVersion(v)) }

        let token = ((dict["token"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // The token goes into an Authorization header: no whitespace or
        // control characters, and it must look like a real secret.
        guard !token.isEmpty,
              token.count >= 16,
              token.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) })
        else { return .failure(.missingToken) }

        let relayRaw = ((dict["relay"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let relay: URL
        switch normaliseRelay(relayRaw) {
        case .success(let url): relay = url
        case .failure(let err): return .failure(err)
        }

        let host = ((dict["host"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = host.isEmpty ? "Your Mac" : String(host.prefix(60))
        return .success(ValidatedPairing(token: token, relayBaseURL: relay, macName: name))
    }

    /// `wss://x/ws` and `https://x` both mean the same relay; REST needs the
    /// HTTPS base without the `/ws` suffix.
    static func normaliseRelay(_ raw: String) -> Result<URL, PairingValidationError> {
        guard !raw.isEmpty, var comps = URLComponents(string: raw),
              let scheme = comps.scheme?.lowercased() else {
            return .failure(.invalidRelay)
        }
        switch scheme {
        case "https", "wss": comps.scheme = "https"
        case "http", "ws":   return .failure(.insecureRelay)
        default:             return .failure(.invalidRelay)
        }
        guard let host = comps.host?.lowercased(), !host.isEmpty, host.contains(".") || host == "localhost" else {
            return .failure(.invalidRelay)
        }
        if host.contains(placeholderHostFragment) { return .failure(.placeholderRelay) }
        var path = comps.path
        if path.hasSuffix("/ws") { path = String(path.dropLast(3)) }
        while path.hasSuffix("/") { path = String(path.dropLast()) }
        comps.path = path
        comps.query = nil
        comps.fragment = nil
        guard let url = comps.url else { return .failure(.invalidRelay) }
        return .success(url)
    }

    /// Typing JSON on iOS turns quotes into curly quotes; undo that.
    private static func normaliseQuotes(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
    }
}

/// Which APNs gateway this build's device token belongs to. The Worker needs
/// it per device: Xcode/development-signed builds get sandbox tokens,
/// TestFlight/App Store builds get production tokens, and sending to the
/// wrong gateway fails with BadDeviceToken.
enum PushEnvironment {
    /// Reads `aps-environment` from the embedded provisioning profile, which
    /// is the authoritative answer for this exact build. App Store builds
    /// have no embedded profile, so fall back on the build configuration.
    static func current(provisionData: Data?, isDebugBuild: Bool) -> String {
        if let data = provisionData, let env = apsEnvironment(fromProvision: data) {
            return env
        }
        return isDebugBuild ? "development" : "production"
    }

    /// The profile is a CMS-signed plist; the XML plist sits in the clear
    /// between `<?xml` and `</plist>`.
    static func apsEnvironment(fromProvision data: Data) -> String? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else { return nil }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let env = entitlements["aps-environment"] as? String,
              env == "development" || env == "production"
        else { return nil }
        return env
    }
}
