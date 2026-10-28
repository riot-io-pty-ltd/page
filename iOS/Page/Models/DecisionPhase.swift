import Foundation
import CoreGraphics

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
    /// The Mac holds the reply until a rate limit resets; it can be deleted while it waits.
    case heldOnMac(String?)
    /// Taken back: nothing was typed, and the page takes a new reply.
    case retracted(String)

    var acceptsInput: Bool {
        switch self {
        case .open, .failed, .unconfirmed, .retracted: return true
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
        // Held on the Mac, the page has closed as "replied": the sheet stays, so the reply can still be deleted.
        case .heldOnMac(let detail)?: return .heldOnMac(detail)
        case .retracted(let why)?: return i.isLive ? .retracted(why) : closed(hadOwnReply: true)
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
        case .heldOnMac: return ("Held on your Mac until the rate limit resets. Page types it then.", .warn)
        case .retracted(let why): return (why, .neutral)
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

// MARK: - The sheet's layout and its draft

/// Which of the Decision sheet's two layouts is drawn, as one pure decision.
/// The height it is given is the sheet's height with the keyboard ignored:
/// the keyboard shrinks the space the sheet has, and a layout chosen from
/// that space would swap while a message is being typed, rebuilding the
/// field under the person's thumbs. While the composer is up the choice that
/// was in force when it opened is kept, whatever the height does after.
enum DecisionLayout {
    /// Below this sheet height there is no room to pin the command, the preview
    /// and the controls and still read the headline above them.
    static let pinnedMinHeight: CGFloat = 580

    /// Pinned when the sheet is tall enough. The answer picker is as tall as a
    /// screenful: it flows with the rest instead of being pinned.
    static func pinned(height: CGFloat, questionPicker: Bool) -> Bool {
        height >= pinnedMinHeight && !questionPicker
    }

    /// The layout to draw: the latched one while composing, else by height.
    static func pinned(height: CGFloat, questionPicker: Bool, latched: Bool?, composing: Bool) -> Bool {
        if composing, let latched { return latched }
        return pinned(height: height, questionPicker: questionPicker)
    }

    /// What to remember when the composer opens (the layout in force), and to forget when it closes.
    static func latch(current: Bool, composing: Bool) -> Bool? { composing ? current : nil }

    /// The same from the sheet's height. A composer that opens before the sheet was ever measured (height 0)
    /// has no layout in force yet: nothing is latched until the first measurement (`relatch`).
    static func latch(height: CGFloat, questionPicker: Bool, composing: Bool) -> Bool? {
        guard composing, height > 0 else { return nil }
        return pinned(height: height, questionPicker: questionPicker)
    }

    /// A new height arrived. When the composer is up and nothing was latched because the sheet had not been
    /// measured, the first real height decides the layout, so it can't swap under the field later.
    static func relatch(latched: Bool?, composing: Bool, oldHeight: CGFloat, newHeight: CGFloat, questionPicker: Bool) -> Bool? {
        guard composing else { return nil }
        if latched != nil { return latched }
        guard oldHeight <= 0, newHeight > 0 else { return nil }
        return pinned(height: newHeight, questionPicker: questionPicker)
    }
}

/// What happens to a message being written when the sheet is asked to go
/// away: by a swipe, or because its page resolved underneath it.
enum DecisionDraftGuard {
    private static func hasText(_ draft: String) -> Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// A swipe-down must not eat a message: while there is text, or a send is in flight (arming, or on its way to the relay).
    static func blocksSwipeDismiss(draft: String, sendPending: Bool, phase: DecisionPhase, countdownPending: Bool = false) -> Bool {
        if countdownPending { return false }
        if hasText(draft) { return true }
        if sendPending { return true }
        if case .sending = phase { return true }
        return false
    }

    /// The page resolved (answered at the Mac, superseded) while there is text: the sheet stays, with the text,
    /// and says so, instead of closing itself after 2.2 s and dropping it. A delivered reply closes as ever
    /// (its text was handed off and cleared).
    static func keepsDraft(phase: DecisionPhase, draft: String) -> Bool {
        guard hasText(draft) else { return false }
        switch phase {
        case .resolved, .alreadyReplied: return true
        default: return false
        }
    }

    /// The delay before the sheet closes itself, or nil to stay (a kept draft).
    static func autoCloseDelay(phase: DecisionPhase, draft: String) -> Double? {
        keepsDraft(phase: phase, draft: draft) ? nil : phase.autoCloseDelay
    }

    /// The row stopped offering a reply under a message being written (its actions changed: the session
    /// moved on, or the page now has to be answered on the Mac): the dock stays, locked, with the
    /// text and the kept-draft note, rather than the sheet showing no controls at all.
    static func keepsDock(composerOpen: Bool, draft: String, rowTakesReply: Bool) -> Bool {
        composerOpen && hasText(draft) && !rowTakesReply
    }

    /// Leaving the sheet (the X, Open session, View changes, or another sheet asked for by the app)
    /// asks first while there is a message written that is not on its way. One that is waiting out its
    /// countdown is already the app's: it sends (or is undone from the receipt) whether the sheet stays.
    static func needsConfirm(draft: String, countdownPending: Bool) -> Bool {
        hasText(draft) && !countdownPending
    }
}
