import Foundation

// First-run, as plain values: what the Welcome and Scan screens say, what the
// Paired screen offers, and the problems Page can truly detect and the one
// obvious fix for each ("Never a false 'all quiet'"). Foundation-only, so the
// logic tests cover it and the macOS proxy renderer can draw the views.

// MARK: - Welcome and Scan

enum OnboardingCopy {
    static let eyebrow = "PAGE"
    static let welcomeTitle = "Keep watch over your agents."
    static let welcomeBody = "Your Mac stays awake while they work, and pages you here the moment one needs you. Everything is end-to-end encrypted."
    static let pairButton = "Pair with your Mac"

    static let scanTitle = "Scan the code on your Mac"
    static let scanHint = "Page menu → Pair phone…"
    static let scanFacts: [(symbol: String, text: String)] = [
        ("lock", "The code holds your relay address and an encryption key"),
        ("checkmark.shield", "Only this phone can read your sessions"),
    ]
    static let pasteInstead = "Paste a pairing link instead"

    /// The warning that stays on the confirm step: whoever runs the relay sees pages and replies.
    static let confirmWarning = "Only pair with a code from your own Mac: whoever runs this relay sees your pages and replies."
}

// MARK: - Paired

/// What the Paired screen shows, once a Mac has been saved.
struct PairedWelcome: Equatable {
    /// What the one big button does. Asking for notifications is a choice
    /// made here, once, never an unprompted system dialog.
    enum Action: Equatable {
        case allowNotifications
        case openSettings
        case continueToNow

        var title: String {
            switch self {
            case .allowNotifications: return "Allow notifications"
            case .openSettings: return "Open Settings"
            case .continueToNow: return "Open Now"
            }
        }
    }

    let title: String
    let subtitle: String
    let promiseTitle: String
    let promises: [String]
    let action: Action
    /// A quiet second choice under the button, when notifications are still undecided.
    let skipTitle: String?

    static let promiseLines = [
        "Approvals and questions — always",
        "Looks stuck, finished turns — only when you're away",
        "Never to pull you back in",
    ]

    /// "Your first star. 14 sessions are live right now." The count is what
    /// the Mac has reported by now; with none yet the line says what happens next.
    static func subtitle(liveSessions: Int?, isFirstMac: Bool) -> String {
        let lead = isFirstMac ? "Your first star. " : ""
        switch liveSessions {
        case nil: return lead + "Sessions appear as soon as your Mac reports them."
        case 0?: return lead + "Start an agent on your Mac and it appears here."
        case 1?: return lead + "1 session is live right now."
        case let n?: return lead + "\(n) sessions are live right now."
        }
    }

    static func build(macName: String, liveSessions: Int?, isFirstMac: Bool, notifications: NotificationsState) -> PairedWelcome {
        let action: Action
        switch notifications {
        case .allowed: action = .continueToNow
        case .off: action = .openSettings
        case .notSet, .checking: action = .allowNotifications
        }
        return PairedWelcome(
            title: "\(DeliveryPreview.macLabel(macName).replacingOccurrences(of: "your Mac", with: "Your Mac")) is paired",
            subtitle: subtitle(liveSessions: liveSessions, isFirstMac: isFirstMac),
            promiseTitle: "Only when you're needed", promises: promiseLines, action: action,
            skipTitle: action == .allowNotifications ? "Not now" : nil)
    }
}

// MARK: - Problem states

/// A thing Page can see is wrong, as a calm full statement: a hollow pulse,
/// a sentence that tells the truth, what it means, and one obvious fix. Red
/// is reserved for the two hold rings, so even a replaced pairing is amber.
struct ProblemState: Equatable, Identifiable {
    enum Kind: String, Equatable {
        case macAsleep, relayUnreachable, pairingReplaced
    }

    enum Tone: Equatable { case slate, amber }

    /// What the button does. The container routes each to an existing path.
    enum Action: Equatable {
        /// Pull the lists again.
        case recheck
        /// Unpair, then scan the new code.
        case repair

        var isRepair: Bool { self == .repair }
    }

    struct Detail: Equatable, Identifiable {
        let symbol: String
        let text: String
        var id: String { text }
    }

    let kind: Kind
    let tone: Tone
    let title: String
    let subtitle: String
    let details: [Detail]
    let actionTitle: String
    let action: Action
    /// A quieter second choice, when there is one (re-pair, for a Mac that has been gone a long time).
    var secondaryTitle: String? = nil
    var secondaryAction: Action? = nil
    /// The banner ids this replaces, so the stream does not say it twice.
    let replacesBanners: Set<String>

    var id: String { kind.rawValue }

    struct Inputs: Equatable {
        var macName: String
        var presence: MacPresence
        var authRejected: Bool
        /// The relay refused as "token retired".
        var retired: Bool = false
        /// The inbox failed to load, with the relay's reason.
        var inboxFailure: String?
        var connected: Bool
        var relayHost: String?
        var battery: Int?
        var onAC: Bool?
        var cutoff: Int?
        /// Sessions Page paused at the cutoff (open "paused for battery" pages).
        var pausedSessions: Int = 0
        /// When the lists last loaded, for "Showing what we last knew".
        var lastKnownAt: Date?
        var now: Date
    }

    /// The most important thing wrong, or nil. A rejected or replaced
    /// pairing beats an unreachable relay, which beats a quiet Mac, because
    /// each of those makes the next one meaningless. Pure.
    static func build(_ i: Inputs) -> ProblemState? {
        let mac = DeliveryPreview.macLabel(i.macName)
        let macTitle = mac == "your Mac" ? "Your Mac" : mac

        if i.authRejected || i.retired || i.presence == .neverConnected {
            let replaced = i.authRejected || i.retired
            return ProblemState(
                kind: .pairingReplaced, tone: .amber,
                title: replaced ? "This pairing was replaced" : "Your Mac hasn't used this pairing",
                subtitle: replaced ? "Your Mac made a new pairing code" : "The relay has never seen it connect",
                details: [
                    Detail(symbol: "key.slash", text: replaced ? "The old code can't be used again" : "A code from an old screenshot, or a regenerated token, looks like this"),
                    Detail(symbol: "qrcode", text: "On your Mac, open Page menu → Pair phone…"),
                ],
                actionTitle: "Scan the new code", action: .repair, replacesBanners: ["auth", "never"])
        }
        if let failure = i.inboxFailure, !i.connected {
            var details = [Detail(symbol: "wifi.slash", text: "Your phone may be offline"),
                           Detail(symbol: "exclamationmark.bubble", text: failure)]
            if let last = i.lastKnownAt {
                details.append(Detail(symbol: "tray", text: "Showing what we last knew, \(RelativeTime.compact(seconds: Int(max(0, i.now.timeIntervalSince(last))))) ago"))
            }
            return ProblemState(
                kind: .relayUnreachable, tone: .amber, title: "Can't reach your relay",
                subtitle: (i.relayHost.map { "\($0) isn't answering" } ?? "The relay isn't answering") + " · retrying",
                details: details, actionTitle: "Try again now", action: .recheck, replacesBanners: ["relay"])
        }
        let seen: Date?
        let stale: Bool
        switch i.presence {
        case .offline(let s): seen = s; stale = false
        case .stale(let s): seen = s; stale = true
        default: return nil
        }
        var details = [Detail(symbol: "moon.zzz", text: stale
                              ? "Pages may be late until it checks in again"
                              : "Pages can't reach you until it wakes or Page reconnects")]
        if i.onAC == false, let b = i.battery, b > 0, b <= (i.cutoff ?? 10) + 3 {
            details.append(Detail(symbol: "battery.25", text: "It was at \(b)% — probably the cutoff"))
        }
        if i.pausedSessions > 0 {
            details.append(Detail(symbol: "clock.arrow.circlepath",
                                  text: "Your \(i.pausedSessions) session\(i.pausedSessions == 1 ? " was" : "s were") paused with summaries"))
        }
        // Gone a long time: a regenerated token answers exactly like an offline Mac, so offer the re-pair.
        let repair = i.presence.suggestsRepair(now: i.now)
        if repair {
            details.append(Detail(symbol: "key", text: "If you regenerated the token on your Mac, re-pair this iPhone"))
        }
        let when = seen.map { "Last heartbeat \(RelativeTime.compact(seconds: Int(max(0, i.now.timeIntervalSince($0))))) ago" }
        return ProblemState(
            kind: .macAsleep, tone: .slate,
            title: stale ? "\(macTitle) stopped checking in" : "\(macTitle) is offline",
            subtitle: when ?? "No heartbeat on record",
            details: details, actionTitle: "Check again", action: .recheck,
            secondaryTitle: repair ? "Re-pair…" : nil, secondaryAction: repair ? .repair : nil,
            replacesBanners: ["offline", "stale"])
    }
}
