import Foundation

// What a Decision sheet is showing, derived from live state on every render.
// This is the reply screen's phase logic (ReplyView, which it replaces),
// moved out of the view so the logic tests cover it: sending, sent, slow,
// unconfirmed, checking a close, delivered, failed, already answered and
// resolved, with the sheet closing itself after a result.

enum DecisionPhase: Equatable {
    case loading
    case missing
    case open
    case sending
    /// `slow`: past `ReplyConfirmation.slowAfter` without confirmation.
    case sent(queued: Bool, slow: Bool)
    /// Accepted by the relay but never confirmed by the Mac within the
    /// relay's ack window, so a second answer is accepted again. Input
    /// re-opens so the page can't get stuck.
    case unconfirmed
    /// Closed with no reason known yet while a reply was out: checking the
    /// archive before saying what happened.
    case checkingClose
    case delivered(String?)
    case failed(String)
    case alreadyReplied
    case resolved(String)

    var acceptsInput: Bool {
        switch self {
        case .open, .failed, .unconfirmed: return true
        default: return false
        }
    }

    /// States after which the sheet closes on its own.
    var autoCloseDelay: Double? {
        switch self {
        case .delivered: return 1.4
        case .resolved, .alreadyReplied: return 2.2
        default: return nil
        }
    }

    /// A confirmed delivery is the only success.
    var isDelivered: Bool { if case .delivered = self { return true } else { return false } }

    struct Inputs {
        var delivery: ReplyDelivery?
        /// The page is in the live inbox.
        var isLive: Bool
        /// A last known copy exists (so the content stays readable after it closes).
        var hasSnapshot: Bool
        var lookupFinished: Bool
        var closeReason: String?
        var closeLookupFinished: Bool
        var now: Date
        var legacyRelay: Bool

        init(delivery: ReplyDelivery?, isLive: Bool, hasSnapshot: Bool, lookupFinished: Bool, closeReason: String?,
             closeLookupFinished: Bool, now: Date, legacyRelay: Bool) {
            self.delivery = delivery; self.isLive = isLive; self.hasSnapshot = hasSnapshot
            self.lookupFinished = lookupFinished; self.closeReason = closeReason
            self.closeLookupFinished = closeLookupFinished; self.now = now; self.legacyRelay = legacyRelay
        }
    }

    /// Pure.
    static func derive(_ i: Inputs) -> DecisionPhase {
        func closed(hadOwnReply: Bool) -> DecisionPhase {
            switch ClosedReplyPhase.decide(reason: i.closeReason, hadOwnReply: hadOwnReply, lookupFinished: i.closeLookupFinished) {
            case .delivered: return .delivered(nil)
            case .resolved(let why): return .resolved(why)
            case .checking: return .checkingClose
            }
        }
        switch i.delivery {
        case .sending?: return .sending
        case .sent(let queued, let at)?:
            if !i.isLive { return closed(hadOwnReply: true) }
            if ReplyConfirmation.isUnconfirmed(sentAt: at, queued: queued, now: i.now, legacyRelay: i.legacyRelay) { return .unconfirmed }
            return .sent(queued: queued, slow: i.now.timeIntervalSince(at) > ReplyConfirmation.slowAfter)
        case .delivered(let detail)?: return .delivered(detail)
        case .failed(let message)?: return i.isLive ? .failed(message) : closed(hadOwnReply: true)
        case .alreadyReplied?: return .alreadyReplied
        case .gone?: return .resolved("This page was already resolved.")
        case nil:
            if i.isLive { return .open }
            if i.hasSnapshot { return closed(hadOwnReply: false) }
            return i.lookupFinished ? .missing : .loading
        }
    }

    // MARK: words

    enum Tone: Equatable { case neutral, good, warn, problem }

    /// The strip under the ask, in the trust model's words. nil while open.
    func statusLine(legacyRelay: Bool) -> (text: String, tone: Tone)? {
        switch self {
        case .open, .loading, .missing: return nil
        case .sending: return ("Sending…", .neutral)
        case .sent(let queued, let slow):
            if queued { return ("Queued · your Mac is offline. It'll be typed in when the Mac reconnects (within an hour).", .warn) }
            if slow {
                return (legacyRelay ? "Sent · waiting for your Mac to confirm…"
                        : "Sent · waiting for your Mac. It hasn't confirmed this yet; if it reports a failure, or hasn't confirmed within 20 minutes, you can answer again.", .neutral)
            }
            return ("Sent · waiting for your Mac to confirm…", .neutral)
        case .checkingClose: return ("This page closed · checking whether your reply landed…", .neutral)
        case .delivered(let detail): return ("Delivered · \(detail ?? "typed into the session on your Mac").", .good)
        case .failed(let message): return (message, .problem)
        case .unconfirmed: return ("Your Mac never confirmed this. If the session is still waiting, you can answer again.", .warn)
        case .alreadyReplied: return ("Already answered at the Mac", .neutral)
        case .resolved(let why): return ("Resolved · \(why)", .neutral)
        }
    }
}

/// The text of the discard-draft question: a quick action never carries a
/// half-typed note, so with a draft present Page asks what to do with it.
enum DraftQuestion {
    static func title(for action: ReplyAction) -> String {
        switch action {
        case .approve: return "Approve without your note?"
        case .deny: return "Deny with your note?"
        case .carryOn: return "Send your note instead?"
        case .custom: return ""
        }
    }
}
