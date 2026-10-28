import Foundation

// Queued messages (docs/SESSIONS-PROTOCOL.md "Holding a message until the
// turn ends" and "Taking a message back", docs/PROTOCOL.md "DELETE
// /reply/:id"). A message to a busy session goes one of two ways, and
// anything not yet typed can be taken back, whichever layer holds it:
//
//   L0  the phone, a 10 s countdown before the POST (Undo)
//   L2  the relay, a reply queued for an offline Mac (DELETE /reply/<id>)
//   L3  the Mac, a message held until the turn ends, or a reply held until a
//       rate limit resets (`retract`)
//   L5  Claude Code's own input queue: already typed, Page can't take it back
//
// Foundation-only, so it runs in the plain-swiftc logic tests. The rules and
// copy are the Android app's (`model/QueuedSend.kt`, `model/HeldMessages.kt`
// and `model/Replies.kt`): change one, change the other.

// MARK: - How a message to a busy session goes

enum SendChoice: String, Equatable, CaseIterable {
    /// Claude reads it after its current step (today's behaviour, behind a 10 s Undo).
    case now
    /// The Mac holds it and types it when the turn ends (`hold-v1`).
    case whenFinished

    var title: String { self == .now ? "Now" : "When it finishes" }

    /// What VoiceOver says for the segment.
    var spokenTitle: String { self == .now ? "Send now" : "Send when it finishes" }

    /// One short line, shown under the choice until the person has used it.
    func explanation(agent: String) -> String {
        switch self {
        case .now: return "\(agent) reads it after its current step."
        case .whenFinished: return "Held on your Mac and typed when \(agent) finishes. Delete it any time before."
        }
    }
}

struct SendChoicePlan: Equatable {
    enum Mode: Equatable {
        /// Idle, or nothing to choose: sending is immediate (or the usual Now), no control.
        case none
        /// Busy and both ways work: the two-way control.
        case choice
        /// Busy, and Page can only hold (a Codex thread outside cmux): there is one way, said in words.
        case holdOnly
    }

    let mode: Mode
    /// The way this message will go.
    let selected: SendChoice
    /// The session is mid-turn.
    let busy: Bool

    init(mode: Mode, selected: SendChoice, busy: Bool = false) {
        self.mode = mode; self.selected = selected; self.busy = busy
    }

    var offersChoice: Bool { mode == .choice }
    /// The `input` carries `hold: true`.
    var holds: Bool { mode != .none && selected == .whenFinished }
    /// A Send now to a busy session waits the 10 s countdown before it leaves the phone. That is phone-only,
    /// so it applies with every Mac, including one that can't hold.
    var countsDown: Bool { busy && !holds }

    static let holdCap = "hold-v1"
    static let retractCap = "retract-v1"

    /// A phone offers holding only when the Mac says `hold-v1` and the row says `canHold`.
    static func holdAvailable(caps: Set<String>, canHold: Bool) -> Bool { canHold && caps.contains(holdCap) }

    /// `last` is the choice made last time (kept per device); it wins when it is still possible.
    static func build(busy: Bool, canType: Bool, canHold: Bool, caps: Set<String>, last: SendChoice?) -> SendChoicePlan {
        guard busy else { return SendChoicePlan(mode: .none, selected: .now) }
        let hold = holdAvailable(caps: caps, canHold: canHold)
        switch (canType, hold) {
        case (true, true): return SendChoicePlan(mode: .choice, selected: last ?? .now, busy: true)
        case (false, true): return SendChoicePlan(mode: .holdOnly, selected: .whenFinished, busy: true)
        case (true, false), (false, false): return SendChoicePlan(mode: .none, selected: .now, busy: true)
        }
    }
}

// MARK: - The 10 s Undo before a send

/// Sending in N s, from when the person tapped Send. Nothing has left the
/// phone until the deadline; Undo (any time before) puts the text back.
struct SendCountdown: Equatable {
    /// A message to a busy session, sent now.
    static let sendNow: TimeInterval = 10
    /// The room's Yes and No: the same 1.2 s ring the decision sheet uses.
    static let yesNo: TimeInterval = ArmSpec.duration
    /// A countdown the app slept through (backgrounded, suspended) by more than this is stale:
    /// the message is not sent, it comes back as a draft.
    static let staleGrace: TimeInterval = 30

    let startedAt: Date
    let duration: TimeInterval

    init(startedAt: Date, duration: TimeInterval = SendCountdown.sendNow) {
        self.startedAt = startedAt; self.duration = duration
    }

    var deadline: Date { startedAt.addingTimeInterval(duration) }

    func remaining(now: Date) -> TimeInterval { max(0, deadline.timeIntervalSince(now)) }

    /// Whole seconds left, 10 down to 0; never negative.
    func secondsLeft(now: Date) -> Int { Int(remaining(now: now).rounded(.up)) }

    /// 0...1.
    func progress(now: Date) -> Double { duration > 0 ? min(1, max(0, 1 - remaining(now: now) / duration)) : 1 }

    func isDue(now: Date) -> Bool { now >= deadline }

    enum Verdict: Equatable { case wait, send, stale }

    /// What the timer does when it wakes at `now`.
    func verdict(now: Date) -> Verdict {
        if !isDue(now: now) { return .wait }
        return now.timeIntervalSince(deadline) > Self.staleGrace ? .stale : .send
    }

    /// "Sending in 10 s · Undo".
    func label(now: Date) -> String { "Sending in \(secondsLeft(now: now)) s · Undo" }

    /// What a screen reader reads as the time passes (not every tick).
    func spoken(now: Date) -> String { "Sending in \(secondsLeft(now: now)) seconds. Undo is available." }
}

/// A Yes or No after its tap in the room: the same 1.2 s arm ring the decision sheet uses. Nothing has
/// been sent; Cancel puts it away, and it sends when the ring is full.
struct YesNoArm: Equatable {
    let word: String
    let countdown: SendCountdown

    init(word: String, startedAt: Date) {
        self.word = word
        self.countdown = SendCountdown(startedAt: startedAt, duration: SendCountdown.yesNo)
    }

    /// "Sending “Yes” in 0.8 s".
    func label(now: Date) -> String {
        "Sending “\(word)” in \(String(format: "%.1f", countdown.remaining(now: now))) s"
    }

    func isDue(now: Date) -> Bool { countdown.isDue(now: now) }
}

/// One message waiting out its countdown, in the app-level outbox. It is not
/// tied to a screen: leaving the room does not cancel it.
struct QueuedSend: Equatable, Identifiable {
    enum Phase: Equatable {
        case counting
        /// The deadline passed and the POST began: it can't be undone.
        case sent
        /// Undone: nothing was sent.
        case undone
        /// The app slept through it: nothing was sent, the text is a draft again.
        case stale
    }

    let id: String
    let sessionId: String
    let text: String
    /// `hold: true`: only a held message skips the countdown, so this is false for a countdown.
    let hold: Bool
    let countdown: SendCountdown
    private(set) var phase: Phase = .counting

    init(id: String, sessionId: String, text: String, hold: Bool = false, countdown: SendCountdown) {
        self.id = id; self.sessionId = sessionId; self.text = text; self.hold = hold; self.countdown = countdown
    }

    /// Undo before the deadline: true when the message was taken back. At or after the deadline the
    /// send is under way and Undo refuses.
    mutating func undo(now: Date) -> Bool {
        guard phase == .counting, !countdown.isDue(now: now) else { return false }
        phase = .undone
        return true
    }

    /// The timer woke. `.send`: post it now. `.stale`: the app slept through it, do not send.
    /// `.wait`: not yet. Once decided, later calls say `.wait`.
    mutating func fire(now: Date) -> SendCountdown.Verdict {
        guard phase == .counting else { return .wait }
        let v = countdown.verdict(now: now)
        switch v {
        case .wait: break
        case .send: phase = .sent
        case .stale: phase = .stale
        }
        return v
    }
}

/// What is written to disk while a countdown runs, so a message the app was
/// killed on is not lost: it is deleted when the message is sent or undone.
struct PersistedSend: Codable, Equatable {
    let id: String
    /// Where the draft goes back: "session:<id>" for the room, "page:<id>" for a decision sheet.
    let scope: String
    let text: String
    let startedAt: TimeInterval
}

/// A message the app was killed on, back as a draft.
struct RestoredDraft: Equatable {
    let scope: String
    let text: String
    /// Why it is back.
    var note = RestoredDraft.killedNote

    static let killedNote = "Not sent — Page closed before the countdown ended. Your message is back here."
    static let answeredNote = "Not sent — the page was answered or closed on your Mac first. Your message is back here."
    static let slept = "Not sent — Page was asleep when the countdown ended. Your message is back here."
    /// Undo on a card (Now, the room's page card) after the sheet that held the words has closed.
    static let undoneNote = "Not sent — you tapped Undo. Your message is back here."
}

enum OutboxRestore {
    /// Anything still on disk at launch never went out (sent and undone ones are removed first).
    /// Several messages for one place come back as one draft, oldest first.
    static func restore(_ items: [PersistedSend]) -> [RestoredDraft] {
        var order: [String] = []
        var texts: [String: [String]] = [:]
        for item in items.sorted(by: { $0.startedAt < $1.startedAt }) {
            let t = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if texts[item.scope] == nil { order.append(item.scope) }
            texts[item.scope, default: []].append(t)
        }
        return order.map { RestoredDraft(scope: $0, text: (texts[$0] ?? []).joined(separator: "\n\n")) }
    }

    static func scope(sessionId: String) -> String { "session:" + sessionId }
    static func scope(pageId: String) -> String { "page:" + pageId }
}

enum DraftRestore {
    /// Undo puts the text back: into an empty box as it was, above whatever was typed since.
    static func merge(restored: String, current: String) -> String {
        let back = restored.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if back.isEmpty { return current }
        if now.isEmpty { return back }
        if now == back || now.hasPrefix(back) { return current }
        return back + "\n\n" + now
    }
}

// MARK: - Held on the Mac (hold-v1)

enum HeldState: Equatable, Hashable {
    case held, typing
    case typed, deleted, ended, expired, failed, unconfirmed
    case unknown(String)

    init(wire raw: String?) {
        switch (raw ?? "").trimmingCharacters(in: .whitespaces) {
        case "held": self = .held
        case "typing": self = .typing
        case "typed": self = .typed
        case "deleted": self = .deleted
        case "ended": self = .ended
        case "expired": self = .expired
        case "failed": self = .failed
        case "unconfirmed": self = .unconfirmed
        case let other: self = .unknown(other)
        }
    }

    /// Still on the Mac, not yet typed.
    var isWaiting: Bool { self == .held || self == .typing }
}

/// One entry of a list row's `held` (the Mac holds it, or settled it in the last 15 minutes).
struct HeldMessage: Equatable, Hashable, Identifiable {
    let clientId: String
    /// Redacted and clipped to 200 characters by the Mac.
    let text: String
    let heldAt: Date?
    let state: HeldState
    let at: Date?
    let detail: String?

    var id: String { clientId }
    static let maxEntries = 20
}

extension HeldMessage: Decodable {
    private enum CodingKeys: String, CodingKey { case clientId, text, heldAt, state, at, detail }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = (c.lenientString(.clientId) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.count <= 200 else {
            throw DecodingError.dataCorruptedError(forKey: .clientId, in: c, debugDescription: "Bad held id")
        }
        clientId = id
        text = String((c.lenientString(.text) ?? "").prefix(200))
        heldAt = LenientDate.decode(c, .heldAt)
        state = HeldState(wire: c.lenientString(.state))
        at = LenientDate.decode(c, .at)
        let d = (c.lenientString(.detail) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        detail = d.isEmpty ? nil : String(d.prefix(200))
    }
}

extension SessionDeliveryState {
    /// "Held — sends when Claude finishes": the fallback when the Mac's own detail is missing.
    static func heldCopy(agent: String) -> String { "Held — sends when \(agent) finishes" }

    /// The Mac's own sentence for a hold ("Held — Page types it when Claude finishes this turn"), else ours.
    static func heldCopy(detail: String?, agent: String) -> String {
        if let d = detail, !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return d }
        return heldCopy(agent: agent)
    }

    /// While the Mac is typing a held message: nothing can take it back now.
    static let typingCopy = "Page is typing it into the session now."
    static let typingHeadline = "Typing it now"

    static let noLongerHeld = "No longer held — check the session"
    static let deletedCopy = "Deleted — not sent"

    /// How long a held message may be missing from a list that names its session, having never been in one,
    /// before it reads "No longer held": a list built just before the Mac accepted it never named it, but
    /// one that arrives this long after sending and still doesn't was never going to.
    static let heldGrace: TimeInterval = 30

    /// Settles a held message from the row's `held` list, which also reaches phones that were not
    /// connected for the `result`. `entry` is this clientId's entry; `seen` says it has been in a list
    /// before (so its absence now means something); `sessionListed` says the session is still on the
    /// Mac's list; `sentAt` / `now` time the fallback for an entry that was never seen (a list more than
    /// `heldGrace` after sending that names the session but not the message). A final `result` and the
    /// list agree, so whichever lands first wins and the other changes nothing. The caller doesn't ask
    /// while the Mac's list is turned off: that list is empty and says nothing.
    func reconciled(entry: HeldMessage?, seen: Bool, sessionListed: Bool, sentAt: Date? = nil, now: Date? = nil) -> SessionDeliveryState {
        switch self {
        case .sending, .noAnswer, .held: break
        default: return self
        }
        if let e = entry {
            switch e.state {
            case .held:
                if case .held(let detail, _, _) = self { return .held(detail, note: e.detail, typing: false) }
                return .held(nil, note: e.detail, typing: false)
            case .typing:
                if case .held(let detail, _, _) = self { return .held(detail, note: nil, typing: true) }
                return .held(nil, note: nil, typing: true)
            case .typed: return .typed(e.detail)
            case .deleted: return .deleted(e.detail ?? Self.deletedCopy)
            // Refused, as the final `result` for the same message reads (`refused` / `ended` or `expired`).
            case .ended: return .refused(reason: "ended", message: e.detail ?? "Not sent — the session ended")
            case .expired: return .refused(reason: "expired", message: e.detail ?? "Not sent — the turn didn't finish within 6 hours")
            case .failed: return .failed(e.detail ?? "Not sent — Page couldn't type it")
            case .unconfirmed:
                return .unconfirmed(e.detail ?? "Page restarted while typing this and won't retype it. Check the session.")
            case .unknown: return self
            }
        }
        // No entry. Only a message already held can vanish: one that is still sending has simply not
        // reached a list yet, and a list built just before the Mac accepted it never named it.
        guard case .held = self else { return self }
        if seen || !sessionListed { return .unconfirmed(Self.noLongerHeld) }
        if let sentAt, let now, now.timeIntervalSince(sentAt) > Self.heldGrace { return .unconfirmed(Self.noLongerHeld) }
        return self
    }
}

enum HeldTimeline {
    /// This phone's messages plus the Mac's held ones this phone has no command for (sent from
    /// another phone, or before a relaunch), as pending bubbles; oldest first once merged. Settled
    /// entries that are not ours are in the transcript, or gone, so they add nothing.
    static func pending(sent: [SentSessionCommand], held: [HeldMessage], sessionId: String) -> [SentSessionCommand] {
        let known = Set(sent.map(\.clientId))
        let extra = held.filter { $0.state.isWaiting && !known.contains($0.clientId) }.map { h in
            SentSessionCommand(clientId: h.clientId, sessionId: sessionId, kind: .input, text: h.text,
                               sentAt: h.heldAt ?? .distantPast, state: .held(nil, note: h.detail, typing: h.state == .typing))
        }
        return sent + extra
    }
}

// MARK: - Taking a message back

/// What a `retract` answered, keyed on its `retract` field: `deleted` arrives as `code: delivered`,
/// so reading the code would call a delete "Typed".
enum RetractOutcome: Equatable {
    case deleted(String)
    case tooLate(String)
    case notFound(String)

    static func from(_ r: CommandResult) -> RetractOutcome? {
        let kind = r.retract ?? {
            if r.reason == "too_late" { return "too_late" }
            if r.reason == "not_found" { return "not_found" }
            return r.ok && r.code == .delivered ? "deleted" : nil
        }()
        switch kind {
        case "deleted": return .deleted(r.detail ?? SessionDeliveryState.deletedCopy)
        case "too_late": return .tooLate(r.detail ?? "Too late — it was already typed")
        case "not_found": return .notFound(r.detail ?? "Page isn't holding that message")
        default: return nil
        }
    }

    var note: RetractNote {
        switch self {
        case .deleted(let t): return .deleted(t)
        case .tooLate(let t): return .tooLate(t)
        case .notFound(let t): return .notFound(t)
        }
    }

    /// The line under the message for a `retract`'s result. A value this build doesn't know (`retract: "someday"`),
    /// or a refusal for another reason (a stale clock, turned off, an error), is the Mac's own words, never a
    /// guess from `code`: the message may still be sent.
    static func note(for r: CommandResult, agent: String = "Claude") -> RetractNote {
        from(r)?.note ?? .failed(SessionResultCopy.refusal(reason: r.reason, detail: r.detail, agent: agent))
    }
}

/// A reply the relay says it already handed to the Mac (`DELETE /reply/<id>` answered 409 `too_late`), and what Page
/// does about it: stage `forwarded` means the Mac may still hold it (its rate-limit or resume queue), so Page asks
/// the Mac to take it back (`retract` with `interventionId`); stage `delivered` never does.
enum ForwardedRetract {
    static let askingCopy = "Asking your Mac…"
    static let tooLateCopy = "Too late — your Mac already has it"

    /// Ask the Mac only when the relay says `forwarded` and the Mac says it can take a message back.
    static func asksMac(stage: String?, macCaps: Set<String>) -> Bool {
        stage == "forwarded" && macCaps.contains(SendChoicePlan.retractCap)
    }

    /// What the line reads when the relay's answer is final without asking the Mac (`delivered`, or a Mac that
    /// doesn't advertise `retract-v1`).
    static let tooLate = RetractNote.tooLate(tooLateCopy)

    /// The Mac's answer, in the relay's words for it: deleted keeps the Mac's sentence ("Deleted — not sent"),
    /// too late and not found both read "Too late — your Mac already has it" (nothing of it is held any more).
    /// Anything else the Mac refused is its own words.
    static func note(for r: CommandResult, agent: String = "Claude") -> RetractNote {
        switch RetractOutcome.from(r) {
        case .deleted(let t)?: return .deleted(t)
        case .tooLate?, .notFound?: return tooLate
        case nil: return RetractOutcome.note(for: r, agent: agent)
        }
    }

    /// Nothing came back in 20 s (an older Mac ignores the op): the relay's last word stands.
    static let timeoutNote = tooLate

    /// A note this chain wrote, so a screen can keep showing it after the reply left the queue: the ask, the relay's
    /// "too late", or the Mac's refusal in its own words (`.failed`, as Android shows it; any other failure left under a
    /// reply that has since left the queue is still true: it may still be sent).
    static func isChainNote(_ n: RetractNote?) -> Bool {
        if case .failed? = n { return true }
        return n == .askingMac || n == tooLate
    }
}

/// Where a Delete stands, for the line under the message it was for.
enum RetractNote: Equatable {
    case deleting
    /// The relay said the Mac already has the reply: Page is asking the Mac to take it back (`ForwardedRetract`).
    case askingMac
    case deleted(String)
    case tooLate(String)
    case notFound(String)
    /// The Mac didn't answer within 20 s (an older Mac ignores the op).
    case unconfirmed
    case failed(String)

    static let unconfirmedCopy = "Couldn't confirm the delete — it may still be sent"
    static let offlineCopy = "Your Mac is offline — try again when it's back"

    /// The relay didn't forward the `retract` (nil when it did): an offline Mac is said plainly.
    static func postFailure(_ outcome: SessionCommandOutcome) -> RetractNote? {
        switch outcome {
        case .accepted: return nil
        case .macOffline: return .failed(offlineCopy)
        default: return .failed(outcome.failureMessage ?? unconfirmedCopy)
        }
    }
    /// Nothing happened for this long: the Mac ignored it.
    static let timeout: TimeInterval = 20

    var isBusy: Bool { self == .deleting || self == .askingMac }

    var text: String {
        switch self {
        case .deleting: return "Deleting…"
        case .askingMac: return ForwardedRetract.askingCopy
        case .deleted(let t), .tooLate(let t), .notFound(let t), .failed(let t): return t
        case .unconfirmed: return Self.unconfirmedCopy
        }
    }

    /// A Delete worked, or nothing is left to delete.
    var isFinal: Bool {
        switch self {
        case .deleted, .tooLate, .notFound: return true
        default: return false
        }
    }
}

// MARK: - The relay's queue (reply-retract-v1)

enum RelayQueue {
    static let feature = "reply-retract-v1"

    /// A page reply the relay is holding for an offline Mac. The relay doesn't store a queued flag:
    /// a reply that is pending, was never handed to a Mac socket (no `deliveryForwardedAt`) and is not
    /// one a blocking hook picks up itself is in its queue (docs/PROTOCOL.md "POST /reply/:id").
    static func isQueued(deliveryStatus: String?, forwardedAt: Date?, hookBlocking: Bool) -> Bool {
        deliveryStatus == "pending" && forwardedAt == nil && !hookBlocking
    }

    static func canDelete(features: Set<String>?) -> Bool { features?.contains(feature) == true }
}

/// What DELETE /reply/<id> answered.
enum RelayRetractOutcome: Equatable {
    case deleted
    case nothing
    case tooLate(stage: String?)
    case hookHeld
    /// 404 `not_found`: a relay from before the route existed.
    case oldRelay
    /// 404 `no_such_intervention`: the page is not pending any more (resolved, archived or tombstoned).
    case pageGone
    case failed(String)
    case retired(String)

    static let transportCopy = "Couldn't reach your relay — it may still be sent"

    static func from(status: Int, body: Data) -> RelayRetractOutcome {
        if let why = TokenRetirement.why(status: status, body: body) { return .retired(why) }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = json?["error"] as? String
        switch status {
        case 200..<300:
            return (json?["retracted"] as? Bool) == true ? .deleted : .nothing
        case 409:
            if error == "hook_held" { return .hookHeld }
            if error == "too_late" { return .tooLate(stage: json?["stage"] as? String) }
            return .failed("Couldn't take it back — it may still be sent")
        case 404:
            // An old relay answers an unknown path `not_found`; a new one says `no_such_intervention`.
            if error == "not_found" { return .oldRelay }
            if error == "no_such_intervention" { return .pageGone }
            return .failed("Couldn't take it back — it may still be sent")
        case 401, 403:
            return .failed("The relay no longer accepts this pairing. Re-pair with your Mac.")
        default:
            return .failed("Couldn't take it back — it may still be sent")
        }
    }

    /// What the line under the reply says.
    var note: RetractNote? {
        switch self {
        case .deleted: return .deleted("Deleted — not sent")
        case .nothing: return .notFound("Nothing to delete")
        case .tooLate(let stage):
            switch stage {
            case "forwarded", "delivered": return ForwardedRetract.tooLate
            default: return .failed("Couldn't take it back — it may still be sent")
            }
        case .hookHeld: return .failed("It's waiting on the hook, so it can't be deleted.")
        case .oldRelay: return .failed("Update your relay to delete queued replies")
        case .failed(let m): return .failed(m)
        // The reply's own state says it (`.gone`); nothing is added under it.
        case .retired, .pageGone: return nil
        }
    }
}

// MARK: - A reply that is queued, and what can be done about it

/// Delete, the one affordance for something queued and not yet sent: when there is none, and why, said up front so
/// nothing reads as deletable that isn't. The copy is the Android app's (`QueuedDelete.whyNot`).
enum QueuedDelete {
    static let hookCopy = "Waiting on the hook. It can't be deleted from here."
    static let oldRelayCopy = "Update your relay to delete queued replies."
    static let oldMacCopy = "Update Page on your Mac to delete a held reply."

    /// What a queued reply says when it can't be deleted from here: a hook-held page, an old relay (no
    /// `reply-retract-v1`), or an old Mac for a rate-limit hold (no `retract-v1`). nil when there is nothing worth
    /// saying. `hasList`: the Mac's caps arrive with its first list, so before it nothing can be said about the Mac
    /// (an empty `macCaps` then is "not known yet", not "old"). Likewise `relayFeatures` is nil until `/status` answered.
    static func whyNot(delivery: ReplyDelivery?, isHook: Bool, relayFeatures: Set<String>?, macCaps: Set<String>, hasList: Bool) -> String? {
        switch delivery {
        case .sent(let queued, _)?:
            guard queued else { return nil }
            if isHook { return hookCopy }
            if let features = relayFeatures, !features.contains(RelayQueue.feature) { return oldRelayCopy }
            return nil
        case .heldOnMac?:
            return hasList && !macCaps.contains(SendChoicePlan.retractCap) ? oldMacCopy : nil
        default:
            return nil
        }
    }
}

/// The status block under a reply that is waiting somewhere deletable: at the relay for an offline
/// Mac, or on the Mac until a rate limit resets. nil when the reply is not in either place (and Page
/// isn't asking the Mac about one the relay already handed over: see `ForwardedRetract`).
struct ReplyQueueStatus: Equatable {
    enum Layer: Equatable { case relay, macHold }

    let layer: Layer
    let headline: String
    let detail: String?
    let canDelete: Bool
    let deleting: Bool
    let note: RetractNote?
    /// Why there is no Delete, when it isn't about to appear (`QueuedDelete.whyNot`).
    var whyNot: String? = nil
    /// Page is asking the Mac (the headline says so): a spinner, no button.
    var asking = false

    static let relayHeadline = "Queued — your Mac is offline"

    struct Inputs {
        var delivery: ReplyDelivery?
        var isHook: Bool
        var relayFeatures: Set<String>?
        var macCaps: Set<String>
        var note: RetractNote?
        /// When the rate limit resets, if the session says (else the Mac's detail names the time).
        var resetsAt: Date? = nil
        var timeZone: TimeZone = .current
        /// A list has arrived, so `macCaps` is the Mac's own word.
        var hasList = true
    }

    static func build(_ i: Inputs) -> ReplyQueueStatus? {
        let whyNot = QueuedDelete.whyNot(delivery: i.delivery, isHook: i.isHook, relayFeatures: i.relayFeatures, macCaps: i.macCaps, hasList: i.hasList)
        switch i.delivery {
        case .sent(let queued, _)?:
            guard !i.isHook else { return nil }
            if !queued {
                // The relay already gave it to the Mac: nothing to delete at the relay, but the ask to the Mac
                // and its answer stay on screen until the reply moves on.
                guard let n = i.note, ForwardedRetract.isChainNote(n) else { return nil }
                return ReplyQueueStatus(layer: .relay, headline: n.text, detail: nil, canDelete: false, deleting: false, note: nil,
                                        asking: n.isBusy)
            }
            return ReplyQueueStatus(layer: .relay, headline: relayHeadline,
                                    detail: "It's typed in when your Mac reconnects, within an hour.",
                                    canDelete: RelayQueue.canDelete(features: i.relayFeatures) && i.note?.isBusy != true,
                                    deleting: i.note?.isBusy == true, note: i.note, whyNot: whyNot)
        case .heldOnMac(let detail)?:
            return ReplyQueueStatus(layer: .macHold, headline: HeldUntilReset.headline(detail: detail, resetsAt: i.resetsAt, timeZone: i.timeZone),
                                    detail: "Page types it when the limit resets.",
                                    canDelete: i.macCaps.contains(SendChoicePlan.retractCap) && i.note?.isBusy != true,
                                    deleting: i.note?.isBusy == true, note: i.note, whyNot: whyNot)
        default:
            return nil
        }
    }
}

enum HeldUntilReset {
    static let method = "held_until_reset"

    /// "Held on your Mac until 3:00 PM". The time is the session's own reset time when known, else the
    /// one the Mac wrote ("Will send it when the limit resets at 3:00 PM").
    static func headline(detail: String?, resetsAt: Date?, timeZone: TimeZone) -> String {
        if let at = resetsAt { return "Held on your Mac until \(NowFormat.clock(at, timeZone: timeZone))" }
        if let d = detail, let r = d.range(of: " at ", options: .backwards) {
            let t = d[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " .")).trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, t.count <= 12, t.contains(where: \.isNumber) { return "Held on your Mac until \(t)" }
        }
        return "Held on your Mac until the limit resets"
    }
}
