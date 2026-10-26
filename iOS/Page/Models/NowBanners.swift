import Foundation

// The problems the Now stream surfaces above everything else, and the
// session-availability copy Sky shows when live sessions can't load. These
// are the inbox banners and the Sessions availability cards, as pure values:
// nothing is lost in the move, only restyled.

struct NowBanner: Equatable, Identifiable {
    enum Tone: Equatable { case error, warning, info }
    enum Action: Equatable {
        /// Unpair, then scan a new code on the Mac.
        case repair
        /// Pull the lists again.
        case retry
        case openNotificationSettings
        case retryPush
        case switchMac(String)
    }

    let id: String
    let tone: Tone
    let symbol: String
    let title: String
    let message: String
    let actionTitle: String?
    let action: Action?

    struct Inputs {
        var authRejected: Bool
        /// The inbox failed to load, with the relay's reason.
        var inboxFailure: String?
        var connected: Bool
        var presence: MacPresence
        var notifications: NotificationsState
        var push: PushStatus
        var now: Date

        init(authRejected: Bool, inboxFailure: String?, connected: Bool, presence: MacPresence,
             notifications: NotificationsState, push: PushStatus, now: Date) {
            self.authRejected = authRejected; self.inboxFailure = inboxFailure; self.connected = connected
            self.presence = presence; self.notifications = notifications; self.push = push; self.now = now
        }
    }

    /// Most important first. Pure.
    static func build(_ i: Inputs) -> [NowBanner] {
        var out: [NowBanner] = []
        if i.authRejected {
            out.append(NowBanner(id: "auth", tone: .error, symbol: "key.slash", title: "This pairing no longer works",
                                 message: "Your relay rejected this iPhone's pairing token. The Mac probably generated a new one. Unpair and scan the new code.",
                                 actionTitle: "Re-pair…", action: .repair))
        } else if let failure = i.inboxFailure, !i.connected {
            out.append(NowBanner(id: "relay", tone: .error, symbol: "wifi.exclamationmark", title: "Can't reach your relay",
                                 message: "\(failure) The list may be out of date.", actionTitle: "Try again", action: .retry))
        } else {
            switch i.presence {
            case .neverConnected:
                out.append(NowBanner(id: "never", tone: .error, symbol: "key.slash", title: "Your Mac hasn't connected with this pairing",
                                     message: "The relay has never seen Page on your Mac use this pairing code, so no pages can reach this iPhone. If you regenerated the token on your Mac, re-pair with the new code.",
                                     actionTitle: "Re-pair…", action: .repair))
            case .offline(let seen):
                let repair = i.presence.suggestsRepair(now: i.now)
                let last = seen.map { "Last seen \(RelativeTime.ago(since: $0, now: i.now)). " } ?? ""
                out.append(NowBanner(id: "offline", tone: .warning, symbol: "desktopcomputer.trianglebadge.exclamationmark", title: "Your Mac is offline",
                                     message: last + "New pages can't reach you until Page on your Mac reconnects to the relay."
                                        + (repair ? " If you regenerated the token on your Mac, re-pair this iPhone." : ""),
                                     actionTitle: repair ? "Re-pair…" : nil, action: repair ? .repair : nil))
            case .stale(let seen):
                out.append(NowBanner(id: "stale", tone: .warning, symbol: "desktopcomputer.trianglebadge.exclamationmark", title: "Your Mac stopped checking in",
                                     message: "Last heartbeat \(RelativeTime.ago(since: seen, now: i.now)). It may be asleep or busy; pages may be delayed.",
                                     actionTitle: nil, action: nil))
            default: break
            }
        }
        if i.notifications == .off {
            out.append(NowBanner(id: "notifications", tone: .warning, symbol: "bell.slash", title: "Notifications are off",
                                 message: "You won't be paged while Page is closed.", actionTitle: "Open Settings", action: .openNotificationSettings))
        } else if case .problem(let why) = i.push {
            out.append(NowBanner(id: "push", tone: .warning, symbol: "bell.badge.slash", title: "Push notifications unavailable",
                                 message: why, actionTitle: "Retry", action: .retryPush))
        }
        return out
    }

    /// "Studio is holding 2 that need you", for each other Mac with pages waiting.
    static func otherMacs(_ rows: [TowerMacRow]) -> [NowBanner] {
        rows.filter { !$0.isActive && $0.needsYou > 0 }.map { m in
            NowBanner(id: "other-\(m.id)", tone: .info, symbol: "desktopcomputer", title: "\(m.name): \(m.needsYou) need\(m.needsYou == 1 ? "s" : "") you",
                      message: "Pages from your other Macs show here once you switch to them.",
                      actionTitle: "Switch to \(m.name)", action: .switchMac(m.id))
        }
    }
}

/// What Sky says when live sessions can't load, and the step that fixes it.
struct SessionAvailabilityCopy: Equatable {
    enum Action: Equatable { case repair, retry }
    enum Tone: Equatable { case warning, error, info }

    let systemImage: String
    let tone: Tone
    let title: String
    let message: String
    let actionTitle: String?
    let action: Action?
    /// For the status line.
    let shortStatus: String

    init(_ availability: SessionAvailability) {
        switch availability {
        case .relayTooOld:
            self.init("arrow.triangle.2.circlepath", .warning, "Update your relay",
                      "Your relay (the Cloudflare Worker) doesn't support live sessions yet. Redeploy it from the latest Page release, then pull down to refresh. Pages keep working meanwhile.",
                      "Check again", .retry, "Relay needs an update")
        case .needsRepair(let mismatch):
            if mismatch {
                self.init("key.slash", .error, "Re-pair with your Mac",
                          "Live updates from your Mac can't be unlocked with this iPhone's key, so the pairing was probably regenerated on the Mac. Unpair, then on your Mac open Page → Pair phone… and scan the code.",
                          "Re-pair…", .repair, "Pairing key changed")
            } else {
                self.init("key", .warning, "Re-pair with your Mac to see live sessions",
                          "This pairing has no session key: it came from an older Page on your Mac, or was made before live sessions existed. Update Page on your Mac, unpair here, then open Page → Pair phone… on the Mac and scan the new code. Pages keep working meanwhile.",
                          "Re-pair…", .repair, "Re-pair needed")
            }
        case .macOffline:
            self.init("desktopcomputer.trianglebadge.exclamationmark", .warning, "Your Mac is offline",
                      "Live sessions show up while Page on your Mac is connected to the relay. Wake the Mac, or check that Page is running there.",
                      "Try again", .retry, "Mac offline")
        case .clockSkew:
            self.init("clock.badge.exclamationmark", .warning, "Your clocks disagree",
                      "Updates from your Mac arrive more than 10 minutes old by this iPhone's clock, so they're ignored. Turn on Set Automatically in Date & Time on both your iPhone and your Mac.",
                      "Try again", .retry, "Clock mismatch")
        case .macTooOld:
            self.init("arrow.down.app", .warning, "Update Page on your Mac",
                      "Your Mac is online but isn't sending live sessions. Update Page on your Mac to the latest version, and check that remote sessions are turned on in its Preferences.",
                      "Check again", .retry, "Mac needs an update")
        case .macDisabled:
            self.init("eye.slash", .warning, "Live sessions are off on your Mac",
                      "Page on your Mac isn't sharing its sessions. Turn them back on in Page → Preferences → Phone on the Mac.",
                      "Check again", .retry, "Off on your Mac")
        case .waiting:
            self.init("hourglass", .info, "Connecting to your Mac…", "", nil, nil, "Connecting…")
        case .ready:
            self.init("checkmark.circle", .info, "Live", "", nil, nil, "Live")
        }
    }

    private init(_ image: String, _ tone: Tone, _ title: String, _ message: String,
                 _ actionTitle: String?, _ action: Action?, _ shortStatus: String) {
        systemImage = image
        self.tone = tone
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
        self.shortStatus = shortStatus
    }
}
