import Foundation

// Pure decision logic shared by the services and views. Foundation-only so it
// can be compiled and exercised outside the app target (see iOS/README.md,
// "Testing the pure logic").

// MARK: - Inbox ordering

extension Intervention {
    /// Approvals first, then questions, then idle, then informational; newest
    /// first within a kind. The single ordering used everywhere (refresh, WS
    /// insert, badge) so the list never reshuffles depending on the source.
    static func urgencySorted(_ list: [Intervention]) -> [Intervention] {
        list.sorted { a, b in
            if a.kind.urgencyRank != b.kind.urgencyRank { return a.kind.urgencyRank < b.kind.urgencyRank }
            if a.openedAt != b.openedAt { return a.openedAt > b.openedAt }
            return a.id < b.id
        }
    }

    /// Time from page to the user's reply. Nil when the user never replied
    /// (timeouts and terminal resolutions aren't the user's response time).
    var responseTimeSeconds: Int? {
        guard let r = repliedAt else { return nil }
        return max(0, Int(r.timeIntervalSince(openedAt)))
    }
}

// MARK: - Relative time

enum RelativeTime {
    /// "Paged just now", "Paged 12s ago", "Paged 4m ago". Clamped so a Mac
    /// clock slightly ahead of the phone never yields "-3s ago".
    static func string(_ prefix: String, since date: Date, now: Date) -> String {
        "\(prefix) \(ago(since: date, now: now))"
    }

    static func ago(since date: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 5 { return "just now" }
        return "\(compact(seconds: s)) ago"
    }

    static func compact(seconds s: Int) -> String {
        let s = max(0, s)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }
}

// MARK: - Display helpers

enum PathDisplay {
    /// `/Users/roy/projects/x` -> `~/projects/x`. The Mac's home directory is
    /// unknown on the phone (NSHomeDirectory() is the app sandbox), so match
    /// the conventional macOS/Linux home prefixes instead.
    static func abbreviatingHome(_ path: String) -> String {
        for prefix in ["/Users/", "/home/"] where path.hasPrefix(prefix) {
            let rest = path.dropFirst(prefix.count)
            guard let slash = rest.firstIndex(of: "/") else { return "~" }
            return "~" + rest[slash...]
        }
        return path
    }
}

enum CloseReason {
    /// Close reasons the Worker archives but hides from GET /history
    /// (bookkeeping, not resolutions), plus `stale`, which it never archives,
    /// and `token_retired`, whose pairing (and history) is gone anyway.
    static let hiddenFromHistory: Set<String> = ["stale", "superseded", "evicted", "token_retired"]

    /// Close reasons the Worker archives to history. It archives every reason
    /// except the hidden ones above; these are the ones Page knows by name.
    static let historyWorthy: Set<String> = [
        "replied", "session_resolved", "user_resolved_in_terminal", "timeout",
        "hook_lost", "expired", "agent_exited", "too_late",
        "hook_exited", "hook_fallback", "user_returned", "resolved_elsewhere", "not_a_decision"
    ]

    /// Mirrors the Worker: anything it doesn't hide shows up in history, so
    /// a close reason added later still lands there without an app update.
    static func isHistoryWorthy(_ reason: String) -> Bool {
        !reason.isEmpty && !hiddenFromHistory.contains(reason)
    }

    /// Reads on its own (History) and after "Resolved — " (reply screen).
    static func description(_ reason: String?) -> String {
        switch reason {
        case "replied":                   return "Answered from Page"
        case "user_resolved_in_terminal": return "Answered in the terminal"
        case "superseded":                return "Replaced by a newer page from this session"
        case "evicted":                   return "Removed to make room for newer pages"
        case "timeout":                   return "Timed out"
        case "stale":                     return "The session is no longer waiting"
        case "session_resolved":          return "Resolved on your Mac"
        case "hook_lost":                 return "Lost contact with the hook on your Mac, so the prompt went back to the terminal"
        case "expired":                   return "Expired after a day without an answer"
        case "agent_exited":              return "The agent exited before your answer could be applied"
        case "too_late":                  return "Your reply arrived too late to apply, so the prompt went back to the terminal"
        case "token_retired":             return "This pairing was replaced on your Mac"
        case "hook_exited":               return "The hook on your Mac stopped waiting"
        case "hook_fallback":             return "Handed back to the terminal on your Mac"
        case "user_returned":             return "You came back to your Mac, so it's waiting there"
        case "resolved_elsewhere":        return "Answered somewhere else"
        case "not_a_decision":            return "That reply wasn't an approve or deny, so the prompt went back to the terminal"
        default:                          return "Resolved on your Mac"
        }
    }
}

// MARK: - Token retirement

/// The Mac regenerated its pairing token and retired the old one. The relay
/// then answers every request on the old token with
/// `410 {error:"token_retired", why}` and sends `relay.retired` to phone
/// sockets. Either means this pairing is dead for good: re-pair.
enum TokenRetirement {
    static let defaultWhy = "This pairing was replaced on your Mac — scan the new QR code"
    static let maxWhyLength = 300

    /// The why text when this HTTP response says the token was retired.
    /// Only a 410 whose body says `token_retired` counts: a plain 410
    /// (`{error:"gone"}` from /reply) is a closed page, not a dead pairing.
    static func why(status: Int, body: Data) -> String? {
        guard status == 410,
              let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              json["error"] as? String == "token_retired" else { return nil }
        return cleaned(json["why"]) ?? defaultWhy
    }

    /// The why text when a socket frame announces the retirement.
    static func why(frameType: String, payload: [String: Any]) -> String? {
        guard frameType == "relay.retired" else { return nil }
        return cleaned(payload["why"]) ?? defaultWhy
    }

    /// A WebSocket upgrade refused with this status. The upgrade's body
    /// isn't visible to URLSession, so these are confirmed with a REST call
    /// (which classifies 401/403 and `token_retired`) instead of trusted.
    static func handshakeNeedsCheck(status: Int) -> Bool {
        status == 401 || status == 403 || status == 410
    }

    /// `why` ending in sentence punctuation, for copy that continues after it.
    static func sentence(_ why: String) -> String {
        guard let last = why.last else { return why }
        return ".!?…".contains(last) ? why : why + "."
    }

    /// The relay closes every socket of a retired token with this code
    /// (4410 mirrors HTTP 410) and reason "token_retired", right after the
    /// `relay.retired` frame. If that frame was missed, the close is
    /// confirmed over REST like a refused upgrade.
    static let socketCloseCode = 4410

    static func socketCloseNeedsCheck(code: Int, reason: Data?) -> Bool {
        if code == socketCloseCode { return true }
        guard let reason, let text = String(data: reason, encoding: .utf8) else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) == "token_retired"
    }

    private static func cleaned(_ raw: Any?) -> String? {
        guard let s = raw as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return t.count > maxWhyLength ? String(t.prefix(maxWhyLength)) + "…" : t
    }
}

/// v4 page subtypes: what they mean for the chip, headline and actions.
enum PageSubtype {
    static func isStuck(_ subtype: String?) -> Bool {
        subtype == "looping" || subtype == "stuck" || subtype == "workflow_stalled"
    }

    /// Stop (Deny → Esc) applies to a busy session, not a stalled workflow.
    static func canStop(_ subtype: String?) -> Bool { subtype == "looping" || subtype == "stuck" }

    static func isForecast(_ subtype: String?) -> Bool {
        subtype == "battery_forecast" || subtype == "usage_forecast"
    }

    static func chip(kind: InterventionKind, subtype: String?) -> String {
        switch (kind, subtype) {
        case (.approval, "plan"): return "PLAN APPROVAL"
        case (.idle, "looping"), (.idle, "stuck"): return "LOOKS STUCK"
        case (.idle, "workflow_stalled"): return "WORKFLOW STALLED"
        case (.idle, "low_battery"): return "PAUSED"
        case (.rateLimit, "battery_forecast"): return "BATTERY"
        case (.rateLimit, "usage_forecast"): return "USAGE"
        default: return kind.label
        }
    }
}

/// An idle page that starts "Changed 3 files (+12 −4) · tests passed" and a
/// blank line (the Mac's turn summary): that line, and the reply after it.
enum TurnSummaryLine {
    static func split(_ context: String) -> (summary: String?, rest: String) {
        guard let r = context.range(of: "\n\n") else { return (nil, context) }
        let first = String(context[..<r.lowerBound])
        let looksLikeSummary = (first.hasPrefix("Changed ") && first.contains(" file"))
            || first == "tests passed" || first == "tests failed"
        guard looksLikeSummary, first.count <= 120, !first.contains("\n") else { return (nil, context) }
        return (first, String(context[r.upperBound...]))
    }
}

enum ReplyCopy {
    static func headline(for iv: Intervention) -> String {
        switch (iv.kind, iv.subtype) {
        case (.idle, "looping"), (.idle, "stuck"): return "\(iv.agentName) looks stuck"
        case (.idle, "workflow_stalled"): return "A workflow stopped making progress"
        case (.rateLimit, "battery_forecast"): return "Battery cutoff soon"
        case (.rateLimit, "usage_forecast"): return "Claude limit soon"
        default: break
        }
        switch iv.kind {
        case .approval:
            if iv.subtype == "plan" { return "Approve the plan?" }
            let c = iv.context.lowercased()
            if c.contains("bash") || c.contains("command") || c.contains("shell") { return "Run this command?" }
            if c.contains("edit") || c.contains("write") || c.contains("file") { return "Allow this change?" }
            return "Allow this action?"
        case .userInput: return "\(iv.agentName) needs your input"
        case .idle:      return "\(iv.agentName) is waiting for you"
        case .rateLimit: return "Rate limit reached"
        }
    }

    static func actionLabel(_ action: String?) -> String? {
        switch action {
        case "approve":  return "Approved"
        case "deny":     return "Denied"
        case "carry_on": return "Carry on"
        default:         return nil
        }
    }
}

// MARK: - Replies

/// What the phone can send to POST /reply/:id. Raw values are the wire vocab.
enum ReplyAction: String, Equatable {
    case approve
    case deny
    case carryOn = "carry_on"
    case custom
}

enum ReplyOutcome: Equatable {
    /// 200: the Worker stored it and forwarded (or queued) it for the Mac.
    case accepted(queued: Bool)
    /// 409: something already answered this page (e.g. a lock-screen action)
    /// and the Mac confirmed it, or the relay is too old to say.
    case alreadyReplied
    /// 409 while an earlier reply is still on its way: the Worker has
    /// forwarded or queued it but the Mac hasn't confirmed it yet
    /// (`deliveryStatus: "pending"`). Nothing new was sent, and nothing is
    /// known to have been delivered either, so this must not read as "done".
    case inFlight
    /// 404/410: the page is gone (resolved, superseded or expired).
    case gone
    /// 401/403: the relay rejected our token.
    case unauthorized
    /// 410 `token_retired`: the Mac replaced this pairing; re-pair. Carries
    /// the relay's explanation.
    case retired(String)
    /// Transport error, 5xx, or a client-side refusal; the message is shown.
    case failed(String)

    /// Fallback for a 422 `approve_or_deny_only` without a `why`.
    static let decisionsOnlyMessage = "This page comes from an older Page hook that can only apply Approve or Deny. Use one of those, or update the hook in Page → Phone approvals on your Mac."

    static func from(status: Int, body: Data) -> ReplyOutcome {
        // Before the 410 arm below: a retired token also answers 410.
        if let why = TokenRetirement.why(status: status, body: body) { return .retired(why) }
        switch status {
        case 200..<300:
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            return .accepted(queued: (json?["queued"] as? Bool) ?? false)
        case 409:
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            if json?["error"] as? String == "reply_in_flight" || json?["deliveryStatus"] as? String == "pending" {
                return .inFlight
            }
            return .alreadyReplied
        case 404, 410: return .gone
        case 401, 403: return .unauthorized
        case 422:
            // The relay explains what it can't do (e.g. a v1 blocking hook
            // that only applies Approve/Deny); show that, not the code.
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            if let why = (json?["why"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !why.isEmpty {
                return .failed(why)
            }
            if json?["error"] as? String == "approve_or_deny_only" { return .failed(decisionsOnlyMessage) }
            if let err = json?["error"] as? String { return .failed("The relay refused the reply (\(err)).") }
            return .failed("The relay returned an error (HTTP 422).")
        default:
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            if let err = json?["error"] as? String {
                return .failed("The relay refused the reply (\(err)).")
            }
            return .failed("The relay returned an error (HTTP \(status)).")
        }
    }

    /// A reply that would make the Mac guess (empty text with no explicit
    /// action used to become "carry on"). Never send these.
    static func validate(text: String, action: ReplyAction) -> String? {
        if action == .custom && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Type a reply first."
        }
        return nil
    }
}

/// Where a reply to one intervention stands, as far as the phone knows.
enum ReplyDelivery: Equatable {
    case sending
    /// The Worker accepted it at `at`; `queued` means the Mac was offline.
    case sent(queued: Bool, at: Date)
    /// The Mac reported success (`reply.result`), or closed the page as
    /// "replied" (older Workers).
    case delivered(detail: String?)
    /// Transport/HTTP failure or the Mac reported a failed injection.
    /// The page is still open, so the user can retry.
    case failed(String)
    case alreadyReplied
    case gone
    /// The Mac accepted it and holds it until a rate limit resets (`reply.injected` method `held_until_reset`).
    /// Not typed yet, and it can be taken back while it waits.
    case heldOnMac(detail: String?)
    /// Taken back (a `retracted` result, or the page's own record): nothing was typed, and the page takes a new reply.
    case retracted(String)

    /// State after the relay accepted our POST. Only a send still in
    /// progress becomes `.sent`: a `reply.result` that beat the HTTP response
    /// (delivered *or* failed) is newer news and is kept.
    static func afterAccepted(_ current: ReplyDelivery?, queued: Bool, at: Date) -> ReplyDelivery {
        switch current {
        case .sending?, nil: return .sent(queued: queued, at: at)
        case let other?: return other
        }
    }

    /// Folds the Worker's view of a reply (v2 `deliveryStatus`, or v1
    /// `repliedAt`) into local state. The caller must skip ids whose local
    /// state changed after the fetch started, so a stale list can't undo a
    /// newer local event.
    ///
    /// `forwardedAt` and `hookBlocking` tell a reply the relay is holding for an offline Mac from one
    /// the Mac has: the relay doesn't store the queued flag (see `RelayQueue.isQueued`).
    static func synced(local: ReplyDelivery?, deliveryStatus: String?, deliveryDetail: String?, deliveryMethod: String?,
                       repliedAt: Date?, forwardedAt: Date?, hookBlocking: Bool, now: Date) -> ReplyDelivery? {
        switch deliveryStatus {
        case "failed":
            if local == .sending { return local }
            if deliveryMethod == RetractedReply.method { return .retracted(deliveryDetail ?? SessionDeliveryState.deletedCopy) }
            return .failed(deliveryDetail ?? "Your Mac couldn't deliver the reply.")
        case "delivered":
            if deliveryMethod == HeldUntilReset.method { return .heldOnMac(detail: deliveryDetail) }
            return .delivered(detail: deliveryDetail)
        case "pending":
            let queued = RelayQueue.isQueued(deliveryStatus: deliveryStatus, forwardedAt: forwardedAt, hookBlocking: hookBlocking)
            switch local {
            // The Worker clears repliedAt when a delivery fails, so
            // "pending" means a reply newer than any local failure exists
            // (a retry from another device, or a POST whose response we
            // lost). A local "already answered" is likewise just a reply in
            // flight, and must not stay terminal on a page that's still open.
            case nil, .failed?, .alreadyReplied?, .retracted?:
                return .sent(queued: queued, at: repliedAt ?? now)
            // Queued or forwarded, whichever the relay says now: the queue flushing takes Delete away.
            case .sent(let wasQueued, let at)?:
                return wasQueued == queued ? local : .sent(queued: queued, at: at)
            default:
                return local
            }
        default:
            if local == nil, let at = repliedAt { return .sent(queued: false, at: at) }
            return local
        }
    }
}

enum RetractedReply {
    /// `deliveryMethod` / `reply.result` method of a reply that was taken back.
    static let method = "retracted"
}

/// When a reply the relay accepted but the Mac never confirmed may be
/// answered again.
enum ReplyConfirmation {
    /// The Worker's DELIVERY_ACK_TIMEOUT_MS (Cloudflare/src/logic.ts): a
    /// reply it forwarded stays "taken" — a second answer gets 409 — until
    /// the Mac reports a result or this much time passes. Inviting a retry
    /// earlier only produces a refusal.
    static let workerAckTimeout: TimeInterval = 20 * 60
    /// Relays that predate delivery reporting (no /status, no
    /// `deliveryStatus`) never report failures and have no ack window, so
    /// input re-opens after a minute rather than leaving the page stuck.
    static let legacyTimeout: TimeInterval = 60
    /// After this long without confirmation the "waiting" copy explains
    /// that a retry opens up later, instead of just spinning.
    static let slowAfter: TimeInterval = 60

    static func timeout(legacyRelay: Bool) -> TimeInterval {
        legacyRelay ? legacyTimeout : workerAckTimeout
    }

    /// Queued replies (Mac offline) are never "unconfirmed": the Worker
    /// fails them itself when its queue TTL runs out.
    static func isUnconfirmed(sentAt: Date, queued: Bool, now: Date, legacyRelay: Bool) -> Bool {
        !queued && now.timeIntervalSince(sentAt) > timeout(legacyRelay: legacyRelay)
    }
}

/// What a reply screen shows once its page has closed.
enum ClosedReplyPhase: Equatable {
    case delivered
    case resolved(String)
    /// The close arrived without a reason (silent push, or the close happened
    /// while the socket was down) and we had sent a reply: look the archived
    /// record up before claiming the Mac resolved it some other way.
    case checking

    static func decide(reason: String?, hadOwnReply: Bool, lookupFinished: Bool) -> ClosedReplyPhase {
        if reason == "replied" { return .delivered }
        if reason == nil, hadOwnReply, !lookupFinished { return .checking }
        return .resolved(CloseReason.description(reason) + ".")
    }
}

// MARK: - Push payloads

enum PushPayload {
    /// Every page id a push says is closed: the v2 `interventionClosedIds`
    /// array (cascades, sync closes, and superseded pages riding on an alert)
    /// plus the v1 `interventionClosedId`. Never includes the push's own
    /// `interventionId`, so an alert can't close the page it announces.
    static func closedIds(from userInfo: [AnyHashable: Any]) -> Set<String> {
        var ids = Set<String>()
        if let list = userInfo["interventionClosedIds"] as? [Any] {
            for case let id as String in list where !id.isEmpty && id.count <= 200 { ids.insert(id) }
        }
        if let one = userInfo["interventionClosedId"] as? String, !one.isEmpty, one.count <= 200 {
            ids.insert(one)
        }
        if let own = userInfo["interventionId"] as? String { ids.remove(own) }
        return ids
    }

    /// The project a push is about, for local notices. Prefers the
    /// `projectName` payload key; older Workers only put it in the title
    /// ("<project> paged you", "Reply to <project> not delivered"). Anything
    /// else yields "" so callers say "your Mac" instead of quoting a title.
    static func projectName(userInfo: [AnyHashable: Any], title: String) -> String {
        if let name = userInfo["projectName"] as? String {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let pagedSuffix = " paged you"
        if title.hasSuffix(pagedSuffix) {
            return String(title.dropLast(pagedSuffix.count)).trimmingCharacters(in: .whitespaces)
        }
        let failedPrefix = "Reply to ", failedSuffix = " not delivered"
        if title.hasPrefix(failedPrefix), title.hasSuffix(failedSuffix),
           title.count > failedPrefix.count + failedSuffix.count {
            return String(title.dropFirst(failedPrefix.count).dropLast(failedSuffix.count))
                .trimmingCharacters(in: .whitespaces)
        }
        return ""
    }
}

// MARK: - Socket liveness

enum SocketLiveness {
    /// The phone pings every `pingInterval`, and a connected Mac's heartbeat
    /// is relayed every ~15s, so a healthy socket always has a frame or pong
    /// newer than this. Older means half-open (a NAT dropped it, Wi-Fi to
    /// cellular): URLSession only notices when TCP gives up, minutes later.
    static func isDead(lastInboundAt: Date, now: Date, pingInterval: TimeInterval) -> Bool {
        now.timeIntervalSince(lastInboundAt) > pingInterval + 15
    }
}

// MARK: - Notification actions

enum NotificationActionID {
    static let approve = "APPROVE"
    static let deny = "DENY"
    static let reply = "REPLY"
    static let carryOn = "CARRY_ON"
}

enum NotificationCategoryID {
    static let approval = "PAGE_APPROVAL"
    static let input = "PAGE_INPUT"
    static let idle = "PAGE_IDLE"
    static let info = "PAGE_INFO"
    /// Pre-v2 Workers send this for every kind; keep it registered.
    static let legacy = "PAGE"
}

/// How a notification response was triggered, already mapped from the
/// UserNotifications identifiers by the caller.
enum NotificationResponseKind: Equatable {
    case open          // default action: tap on the banner body
    case dismiss
    case action(String)
}

enum NotificationDecision: Equatable {
    /// Open the app on this intervention. Never sends anything.
    case open
    case ignore
    case send(text: String, action: ReplyAction)
    /// The action doesn't make sense for this page; tell the user why.
    case refuse(String)

    /// `kind` is the raw wire kind from the push payload (may be nil on very
    /// old Workers). Approve/Deny are only honoured for approval kinds, so a
    /// legacy "PAGE" category showing Approve on an idle page can't type
    /// "yes, proceed" into a session that never asked.
    ///
    /// `approveLevel` is how reversible the page's action is, as the phone
    /// classifies it, or nil when the page is not in the inbox (a cold launch,
    /// another Mac). Approve is sent from a banner only for `.undoable`:
    /// a Considered action is a tap and an Irreversible one is a hold plus
    /// Face ID, neither of which a banner can offer, so those open the app on
    /// the Decision sheet instead. Deny and replies are safe from a banner.
    static func decide(_ response: NotificationResponseKind, userText: String?, kind rawKind: String?,
                       approveLevel: Reversibility?) -> NotificationDecision {
        let kind: InterventionKind? = rawKind.map { InterventionKind(wire: $0) }
        switch response {
        case .open:
            return .open
        case .dismiss:
            return .ignore
        case .action(let id):
            switch id {
            case NotificationActionID.approve, NotificationActionID.deny:
                if let kind, kind != .approval {
                    return .refuse("Approve and Deny only apply to approval requests. Open Page to answer this one.")
                }
                if id == NotificationActionID.approve, approveLevel != .undoable { return .open }
                return .send(text: "", action: id == NotificationActionID.approve ? .approve : .deny)
            case NotificationActionID.carryOn:
                if kind == .approval {
                    return .refuse("This session is waiting for an approval. Open Page to approve or deny it.")
                }
                return .send(text: "", action: .carryOn)
            case NotificationActionID.reply:
                let text = (userText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return .ignore }
                return .send(text: text, action: .custom)
            default:
                return .ignore
            }
        }
    }
}

// MARK: - Deep links

enum DeepLink {
    /// `page://intervention/<id>` -> id.
    static func interventionId(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "page", url.host?.lowercased() == "intervention" else { return nil }
        let id = url.pathComponents.filter { $0 != "/" }.first ?? ""
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200 else { return nil }
        return trimmed
    }
}

// MARK: - Reconnect backoff

enum ReconnectBackoff {
    /// Exponential (1, 2, 4 … capped at 30s) with "equal jitter" so a fleet
    /// of phones doesn't reconnect in lockstep after a Worker deploy.
    /// `jitter` is a random value in 0...1.
    static func delay(attempt: Int, jitter: Double) -> TimeInterval {
        let base = min(30, pow(2, Double(max(0, min(attempt, 10)))))
        let j = min(max(jitter, 0), 1)
        return max(0.5, base / 2 + (base / 2) * j)
    }
}

// MARK: - Mac presence

/// What the phone knows about the Mac, merged from GET /status, `mac.status`
/// frames and `heartbeat` frames. Every field is optional because old
/// Workers only ever send heartbeats.
struct MacStatusSnapshot: Equatable {
    var macConnected: Bool?
    var lastHeartbeatAt: Date?
    var activeSessions: Int?
    var battery: Int?
    var onAC: Bool?
    /// v2 /status: whether any Mac has ever connected to the relay with this
    /// pairing token. Absent on relays that predate it.
    var macEverSeen: Bool?
    var pendingCount: Int?
    /// v4 heartbeat / status extras (absent from older Macs and relays).
    var working: Int?
    var forecast: MacBatteryForecast?
    var usage: MacUsage?

    /// A Mac has provably never used this pairing: the relay says so and
    /// has no heartbeat on record. Requiring the missing heartbeat as well
    /// keeps a merely sleeping Mac from being reported as "never connected"
    /// if a relay only starts tracking `macEverSeen` on new connections.
    var macNeverConnected: Bool {
        macConnected == false && lastHeartbeatAt == nil && macEverSeen == false
    }

    /// The pairing probe's looser check, which also covers relays that
    /// predate `macEverSeen`: offline, no heartbeat ever stored, and nothing
    /// pending. Typical of an old QR screenshot or a regenerated token.
    var looksUnused: Bool {
        guard macConnected == false, lastHeartbeatAt == nil else { return false }
        if let seen = macEverSeen { return !seen }
        return pendingCount == 0
    }

    /// Battery is only meaningful in 1...100: v2 Macs send -1 for unknown and
    /// older Macs hard-coded 0.
    var batteryPercent: Int? {
        guard let b = battery, b > 0, b <= 100 else { return nil }
        return b
    }

    static func from(json: [String: Any]) -> MacStatusSnapshot {
        var s = MacStatusSnapshot(
            macConnected: json["macConnected"] as? Bool,
            lastHeartbeatAt: PageDate.parse(any: json["lastHeartbeatAt"]),
            activeSessions: (json["activeSessions"] as? NSNumber)?.intValue,
            battery: (json["battery"] as? NSNumber)?.intValue,
            onAC: json["onAC"] as? Bool,
            macEverSeen: json["macEverSeen"] as? Bool,
            pendingCount: (json["pendingCount"] as? NSNumber)?.intValue
        )
        s.applyExtras(json)
        return s
    }

    /// The v4 fields of a heartbeat or /status body. Each replaces the old
    /// value (a heartbeat without `forecast` means there is none now).
    mutating func applyExtras(_ json: [String: Any]) {
        working = (json["working"] as? NSNumber)?.intValue
        forecast = MacBatteryForecast(json["forecast"])
        usage = MacUsage(json["usage"])
    }

    /// "Battery 42% · cutoff in about 35 min" while a forecast applies.
    var batteryLine: String? {
        guard onAC != true, let f = forecast else { return nil }
        let pct = batteryPercent.map { "Battery \($0)% · " } ?? ""
        return f.minutes == 0 ? pct + "at the \(f.cutoff)% cutoff" : pct + "cutoff in about \(MacBatteryForecast.duration(f.minutes))"
    }

    /// "Claude 5-hour 62% · resets 5:00 PM · limit ~4:10 PM".
    func usageLine(now: Date, format: (Date) -> String) -> String? {
        guard let u = usage, let five = u.fiveHour else { return nil }
        if let updated = u.updatedAt, now.timeIntervalSince(updated) > 6 * 3600 { return nil }
        var parts = ["Claude 5-hour \(Int(five.pct.rounded()))%"]
        if let r = five.resetsAt, r > now { parts.append("resets \(format(r))") }
        if let hit = u.hitAt, hit > now { parts.append("limit ~\(format(hit))") }
        return parts.joined(separator: " · ")
    }
}

struct MacBatteryForecast: Equatable {
    let cutoff: Int
    let minutes: Int
    let drainPerHour: Double

    init(cutoff: Int, minutes: Int, drainPerHour: Double) {
        self.cutoff = cutoff
        self.minutes = minutes
        self.drainPerHour = drainPerHour
    }

    init?(_ raw: Any?) {
        guard let o = raw as? [String: Any], let c = (o["cutoff"] as? NSNumber)?.intValue,
              let m = (o["minutes"] as? NSNumber)?.intValue, m >= 0 else { return nil }
        self.init(cutoff: c, minutes: m, drainPerHour: (o["drainPerHour"] as? NSNumber)?.doubleValue ?? 0)
    }

    static func duration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(max(1, minutes)) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }
}

struct MacUsage: Equatable {
    struct Window: Equatable {
        let pct: Double
        let resetsAt: Date?
    }

    var fiveHour: Window?
    var sevenDay: Window?
    var hitAt: Date?
    var updatedAt: Date?

    init(fiveHour: Window? = nil, sevenDay: Window? = nil, hitAt: Date? = nil, updatedAt: Date? = nil) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.hitAt = hitAt
        self.updatedAt = updatedAt
    }

    init?(_ raw: Any?) {
        guard let o = raw as? [String: Any] else { return nil }
        func window(_ v: Any?) -> Window? {
            guard let w = v as? [String: Any], let pct = (w["pct"] as? NSNumber)?.doubleValue else { return nil }
            return Window(pct: pct, resetsAt: PageDate.parse(any: w["resetsAt"]))
        }
        self.init(fiveHour: window(o["fiveHour"]), sevenDay: window(o["sevenDay"]),
                  hitAt: PageDate.parse(any: o["hitAt"]), updatedAt: PageDate.parse(any: o["updatedAt"]))
        if fiveHour == nil && sevenDay == nil { return nil }
    }
}

enum MacPresence: Equatable {
    case unknown
    case online(lastSeen: Date?)
    /// The relay still has a socket but heartbeats stopped (asleep, wedged).
    case stale(lastSeen: Date)
    case offline(lastSeen: Date?)
    /// No Mac has ever connected with this pairing token: usually the Mac
    /// regenerated its token, or the code came from an old screenshot.
    case neverConnected

    /// Heartbeats arrive roughly every 15s while the Mac's relay is up;
    /// several missed in a row means something is wrong.
    static let staleAfter: TimeInterval = 90

    static func evaluate(_ s: MacStatusSnapshot?, now: Date) -> MacPresence {
        guard let s else { return .unknown }
        let fresh: Bool? = s.lastHeartbeatAt.map { now.timeIntervalSince($0) <= staleAfter }
        switch s.macConnected {
        case .some(false):
            if s.macNeverConnected { return .neverConnected }
            return .offline(lastSeen: s.lastHeartbeatAt)
        case .some(true):
            if fresh == false, let seen = s.lastHeartbeatAt { return .stale(lastSeen: seen) }
            return .online(lastSeen: s.lastHeartbeatAt)
        case .none:
            // Old Worker: heartbeats are the only signal.
            guard let seen = s.lastHeartbeatAt else { return .unknown }
            return fresh == true ? .online(lastSeen: seen) : .offline(lastSeen: seen)
        }
    }

    var isReachable: Bool {
        if case .online = self { return true }
        return false
    }

    /// Offline long enough (or with no heartbeat on record) that a token
    /// regenerated on the Mac is a plausible cause worth offering a re-pair
    /// for. The relay can't tell: an abandoned token still answers.
    static let repairHintAfter: TimeInterval = 60 * 60

    func suggestsRepair(now: Date) -> Bool {
        switch self {
        case .neverConnected: return true
        case .offline(let seen):
            guard let seen else { return true }
            return now.timeIntervalSince(seen) > Self.repairHintAfter
        default: return false
        }
    }
}

// MARK: - Stats

struct PageStats: Equatable {
    let today: Int
    let thisWeek: Int
    let avgResponseSeconds: Int?
    let repliedCount: Int
    let topProjects: [ProjectCount]

    struct ProjectCount: Equatable {
        let name: String
        let count: Int
    }

    /// "This week" is the calendar week containing `now` (locale's first
    /// weekday). Average response only counts pages the user actually
    /// answered. History and inbox are de-duplicated by id.
    static func compute(history: [Intervention], inbox: [Intervention], now: Date, calendar: Calendar = .current) -> PageStats {
        var byId: [String: Intervention] = [:]
        for iv in history { byId[iv.id] = iv }
        for iv in inbox where byId[iv.id] == nil { byId[iv.id] = iv }
        let all = Array(byId.values)

        let dayStart = calendar.startOfDay(for: now)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? dayStart
        let times = all.compactMap(\.responseTimeSeconds)

        var counts: [String: Int] = [:]
        for iv in all { counts[iv.projectName, default: 0] += 1 }
        let top = counts
            .map { ProjectCount(name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }

        return PageStats(
            today: all.filter { $0.openedAt >= dayStart }.count,
            thisWeek: all.filter { $0.openedAt >= weekStart }.count,
            avgResponseSeconds: times.isEmpty ? nil : times.reduce(0, +) / times.count,
            repliedCount: times.count,
            topProjects: Array(top.prefix(5))
        )
    }
}
