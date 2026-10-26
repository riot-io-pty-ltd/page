import Foundation
import Security

/// What the widget needs to read the relay's `GET /status`: the relay URL
/// and token, plus the Mac's name, copied by the app into a Keychain access
/// group the widget extension shares (`PageSharedKeychainGroup` in both
/// Info.plists). Free Personal Team signing allows Keychain Sharing but not
/// App Groups, so this is the one channel between them.
///
/// Same protection as the app's own items (after first unlock, this device
/// only, never backed up). The app keeps it in step with the pairing:
/// written on pair and launch, deleted on unpair and retirement.
struct SharedWidgetCredentials: Codable, Equatable {
    let url: String
    let token: String
    let macName: String?
}

enum SharedWidgetStore {
    static let service = "page.widget.shared"
    static let account = "relay"

    static var accessGroup: String? {
        guard let g = Bundle.main.object(forInfoDictionaryKey: "PageSharedKeychainGroup") as? String,
              !g.isEmpty, !g.contains("$(") else { return nil }
        return g
    }

    private static func query() -> [String: Any]? {
        guard let group = accessGroup else { return nil }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: group
        ]
    }

    /// Writes (or with nil, deletes) the shared copy. Skips the write when
    /// nothing changed.
    static func save(_ creds: SharedWidgetCredentials?) {
        guard let q = query() else { return }
        guard let creds, let data = try? JSONEncoder().encode(creds) else {
            SecItemDelete(q as CFDictionary)
            return
        }
        if load() == creds { return }
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var status = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add.merge(attrs) { _, new in new }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess { print("[SharedWidgetStore] write failed: \(status)") }
    }

    static func load() -> SharedWidgetCredentials? {
        guard var q = query() else { return nil }
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(SharedWidgetCredentials.self, from: data)
    }
}

/// What the widget shows, from a `GET /status` body. Pure, so it's tested
/// with the logic tests.
struct WidgetStatus: Equatable {
    enum Presence: Equatable { case online, stale, offline, unknown }

    var macName: String
    var presence: Presence
    var needsYou: Int
    var working: Int?
    var live: Int?
    var batteryLine: String?
    var usageLine: String?
    var fetchedAt: Date
    /// The raw usage, for the rings (nil without usage tracking).
    var usage: MacUsage? = nil
    /// The whole reading, for the Runway on the medium widget.
    var snapshot: MacStatusSnapshot? = nil

    static func from(json: [String: Any], macName: String?, now: Date, format: (Date) -> String) -> WidgetStatus {
        let snap = MacStatusSnapshot.from(json: json)
        let presence: Presence
        switch MacPresence.evaluate(snap, now: now) {
        case .online: presence = .online
        case .stale: presence = .stale
        case .offline, .neverConnected: presence = .offline
        case .unknown: presence = .unknown
        }
        return WidgetStatus(macName: macName ?? "Your Mac", presence: presence, needsYou: snap.pendingCount ?? 0,
                            working: snap.working, live: snap.activeSessions,
                            batteryLine: snap.batteryLine, usageLine: snap.usageLine(now: now, format: format),
                            fetchedAt: now, usage: snap.usage, snapshot: snap)
    }

    /// The next six hours as the app's Runway shows them: battery cutoff,
    /// 5-hour limit and resets. Empty when the relay sent no forecast or usage.
    func runway(now: Date, timeZone: TimeZone = .current) -> RunwayModel {
        RunwayModel.build(status: snapshot, now: now, timeZone: timeZone)
    }

    /// "Studio MBP · on battery 41%": the Mac's name and its power, whatever is known.
    var macLine: String {
        var parts = [macName]
        if let s = snapshot {
            if s.onAC == true { parts.append("on power") }
            else if s.onAC == false { parts.append(s.batteryPercent.map { "on battery \($0)%" } ?? "on battery") }
        }
        return parts.joined(separator: " · ")
    }

    /// "2 need you" / "All quiet".
    var headline: String {
        needsYou == 0 ? "All quiet" : "\(needsYou) need\(needsYou == 1 ? "s" : "") you"
    }

    /// What the widget's first line says. Silence has to be earned: a Mac that
    /// is offline or not checking in is never "All quiet".
    var faceHeadline: String {
        switch presence {
        case .offline: return "Mac offline"
        case .stale: return "Not checking in"
        default: return headline
        }
    }

    /// The Mac cannot be reached right now (offline or not checking in).
    var isUnreachable: Bool { presence == .offline || presence == .stale }

    /// "3 working · 9 live" (whatever is known).
    var detail: String? {
        var parts: [String] = []
        if let w = working { parts.append("\(w) working") }
        if let l = live { parts.append("\(l) live") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static let placeholder = WidgetStatus(macName: "Your Mac", presence: .online, needsYou: 1, working: 2, live: 5,
                                          batteryLine: nil, usageLine: nil, fetchedAt: Date())
}
