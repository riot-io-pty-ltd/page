import Foundation

// How an action leaves a card: the three phases of the Receipt thread (Arm,
// Send, Resolve) as pure decisions, and the mapping from a row's action to the
// reply the relay already understands. Nothing here sends anything; the live
// coordinator calls `APIClient.reply`, the only path to the Mac.

/// ARM: a local 1.2 s ring after a tap or a swipe. Nothing has left the
/// phone, and tapping the ring cancels. Once SEND begins there is no cancel,
/// because keystrokes cannot be taken back.
enum ArmSpec {
    static let duration: TimeInterval = 1.2

    /// 0...1 after `elapsed`. Pure.
    static func progress(elapsed: TimeInterval) -> Double { min(1, max(0, elapsed / duration)) }
    static func isComplete(elapsed: TimeInterval) -> Bool { elapsed >= duration }
    /// Seconds left to cancel, never negative.
    static func remaining(elapsed: TimeInterval) -> TimeInterval { max(0, duration - elapsed) }
}

/// What a commit gesture needs before the send.
enum ActionGate {
    /// Every action runs Arm, then Send, then Resolve: a 1.2 s local ring
    /// during which nothing has left the phone and Cancel works. The one
    /// exception is an Irreversible approve, where the press-and-hold plus
    /// biometrics *is* the arm. Deny (Esc), Stop, carry on and a written reply
    /// arm like the rest, and the ring names exactly what will be typed. Pure.
    static func requiresArm(kind: RowAction.Kind, commit: CommitGesture?) -> Bool {
        guard isSendable(kind) else { return false }
        return !requiresBiometrics(kind: kind, commit: commit)
    }

    /// Only an Irreversible approve asks for Face ID / Touch ID / passcode.
    static func requiresBiometrics(kind: RowAction.Kind, commit: CommitGesture?) -> Bool {
        kind == .approve && commit == .hold
    }

    /// An action that exists on the row and can be sent from the phone.
    static func isSendable(_ kind: RowAction.Kind) -> Bool { kind != .openOnMac }

    /// The backstop: a row only ever sends what it offers. A row Page can't
    /// type into offers only Open on Mac, so it has no Approve (or Deny) to begin,
    /// whatever its chip says or a view asks for. Pure.
    static func canBegin(row: NowRow, kind: RowAction.Kind) -> Bool { row.action(kind) != nil }

    /// The same backstop for a banner action, which never goes through the
    /// coordinator: a send the page's row doesn't offer (a session Page can't
    /// type into, an agent it has no adapter for, a hook that takes decisions
    /// only) opens the app on the page instead, where Open on Mac is shown.
    /// `row` is nil when the page is not in the inbox: there is nothing to
    /// check against, and the decision stands. Pure.
    static func banner(_ decision: NotificationDecision, row: NowRow?) -> NotificationDecision {
        guard case .send(_, let action) = decision, let row else { return decision }
        let kinds: [RowAction.Kind]
        switch action {
        case .approve: kinds = [.approve]
        case .deny: kinds = [.deny, .stop]
        case .carryOn: kinds = [.carryOn]
        case .custom: kinds = [.tellInstead]
        }
        return kinds.contains { canBegin(row: row, kind: $0) } ? decision : .open
    }
}

/// The relay reply for a row action.
struct ReplyRequest: Equatable {
    let action: ReplyAction
    /// Empty for approve, deny and carry on. The user's own words for a written reply.
    let text: String
}

enum ReplyMapping {
    /// approve is option 1; deny (and Stop it) is Esc; a written reply is
    /// Esc, then the text, then Return (the Mac's reply planner); carry on is
    /// the configured carry-on message. Never "2", never a standing
    /// permission. nil for an action that is not sent from the phone, and for
    /// a written reply with no words. Pure.
    static func request(for kind: RowAction.Kind, text: String = "") -> ReplyRequest? {
        switch kind {
        case .approve: return ReplyRequest(action: .approve, text: "")
        case .deny, .stop: return ReplyRequest(action: .deny, text: "")
        case .carryOn: return ReplyRequest(action: .carryOn, text: "")
        case .tellInstead:
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : ReplyRequest(action: .custom, text: t)
        case .openOnMac: return nil
        }
    }

    /// A quick action never carries a half-typed note (the Mac uses non-empty
    /// text in place of the action, so Deny would silently become a prompt).
    /// With a draft present, ask first.
    static func needsDraftDecision(draft: String) -> Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// One action in flight from a card.
struct PendingAction: Equatable {
    let rowId: String
    let kind: RowAction.Kind
    let text: String
    let commit: CommitGesture?
    let startedAt: Date
    /// The 1.2 s cancel ring is running (false once sent, or when none applies).
    var armed: Bool
    /// What will be typed, where, on which Mac ("Will press Esc · cmux › builds · Studio MBP").
    var preview: String? = nil

    /// The local phase at `now`.
    enum Phase: Equatable {
        /// Ring running, 0...1. Tapping it cancels.
        case arming(progress: Double)
        /// The arm time is up: the coordinator sends now.
        case ready
    }

    func phase(now: Date) -> Phase {
        guard armed else { return .ready }
        let e = now.timeIntervalSince(startedAt)
        return ArmSpec.isComplete(elapsed: e) ? .ready : .arming(progress: ArmSpec.progress(elapsed: e))
    }

    /// What the card says while the ring runs.
    func armLabel(now: Date) -> String {
        guard case .arming = phase(now: now) else { return "Sending…" }
        let left = ArmSpec.remaining(elapsed: now.timeIntervalSince(startedAt))
        return "Sending in \(String(format: "%.1f", left)) s · tap to cancel"
    }
}

/// Which word a row's card should use for the receipt after a send.
enum CardOutcome: Equatable {
    case none
    case arming(progress: Double)
    case sending
    /// The Mac confirmed the keystroke landed. The only success.
    case delivered(String)
    /// Anything else, in words, with a next step.
    case problem(String)

    static func from(pending: PendingAction?, delivery: ReplyDelivery?, now: Date) -> CardOutcome {
        if let p = pending, case .arming(let progress) = p.phase(now: now) { return .arming(progress: progress) }
        switch delivery {
        case nil: return pending == nil ? .none : .sending
        case .sending?: return .sending
        case .sent?: return .sending
        case .delivered(let detail)?: return .delivered(detail ?? "typed into the session on your Mac")
        case .failed(let why)?: return .problem(why)
        case .alreadyReplied?: return .problem("Already answered at the Mac")
        case .gone?: return .problem("Prompt closed before your answer")
        }
    }
}
