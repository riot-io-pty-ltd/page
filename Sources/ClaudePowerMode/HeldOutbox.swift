import CryptoKit
import Foundation

/// The one-way switch between typing a held message and deleting it: the
/// delivery flips it right before its first key (`commit`), a delete flips it
/// while the message waits (`cancel`), and whichever comes first wins. So a
/// held message is never both typed and deleted. Thread-safe: the delivery
/// runs on a backend's queue, the delete on the sessions queue.
final class HeldClaim {
    enum State: Equatable { case open, committed, cancelled }

    private let lock = NSLock()
    private var _state = State.open

    var state: State { lock.lock(); defer { lock.unlock() }; return _state }

    /// The delivery, right before its first key: true when it may type.
    /// After this a delete has to wait for the try to finish.
    func commit() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if _state == .open { _state = .committed }
        return _state == .committed
    }

    /// A delete: true when it got there first, so no key will be sent.
    func cancel() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if _state == .open { _state = .cancelled }
        return _state == .cancelled
    }
}

/// Messages a phone asked the Mac to type once a session's turn ends
/// ("Send when it finishes", SESSIONS-PROTOCOL.md §5 `hold-v1`), and the ones
/// settled in the last 15 minutes. Pure: `SessionRemote` owns one on its
/// queue, decides readiness from the sessions file, and does the I/O.
///
/// Every held message ends in exactly one outcome (typed, deleted, ended,
/// expired, failed), oldest first per session, one per idle period: typing
/// one starts a new turn, so the next waits for that turn to end.
struct HeldOutbox {
    static let maxPerSession = 10
    static let maxTotal = 50
    static let lifetime: TimeInterval = 6 * 3600
    /// A passing refusal is retried no sooner than this (times the tries, up to `maxRetryDelay`).
    static let retryAfter: TimeInterval = 5
    static let maxRetryDelay: TimeInterval = 60
    /// After one is typed, the session's next waits at least this long: the
    /// new turn needs a moment to show up as busy in the sessions file.
    static let typedGap: TimeInterval = 8
    /// "The session ended": absent from the Mac's list this long, over this many ticks.
    static let endedAfter: TimeInterval = 30
    static let endedTicks = 2
    static let settledKept: TimeInterval = 15 * 60
    static let maxSettledPerSession = 10
    static let rowTextLimit = 200

    static let deletedDetail = "Deleted — not sent"
    static let alreadyDeletedDetail = "Already deleted — not sent"
    static let tooLateDetail = "Too late — it was already typed"
    /// A delete that waited on a try that failed part way (some of it may be in the input box).
    static let tooLateFailedDetail = "Too late — Page had started typing it; check the session"
    static let notHeldDetail = "Page isn't holding that message"
    static let endedDetail = "Not sent — the session ended"
    static let expiredDetail = "Not sent — the turn didn't finish within 6 hours"
    static let stillBusyMessage = "Still working — Page holds it until the turn ends"
    static let unconfirmedDetail = "Page restarted while typing it — check the session before sending again"
    static let tooManyDetail = "Page is already holding \(maxPerSession) messages for this session — delete one first"
    static let tooManyInAllDetail = "Page is already holding \(maxTotal) messages — delete some first"

    static func heldDetail(agent: String) -> String { "Held — Page types it when \(agent) finishes this turn" }

    struct Message: Equatable {
        let clientId: String
        let sessionId: String
        let backend: AgentBackendID
        /// Validated (trimmed, 1–8000 characters).
        let text: String
        let heldAt: Date
        var expectCwd: String? = nil
        var expectTitle: String? = nil
        /// A try has gone to the backend. Set (and saved) before the call, so
        /// a restart in the middle of one never types it a second time.
        var typing = false
        /// The try made on arrival, because the turn already looked over: its
        /// outcome is the input's only result, unless it ends up held.
        var firstTry = false
        /// Tries refused for a passing reason so far.
        var tries = 0
        /// Why the last try didn't type it (shown in the row), if one was refused.
        var lastRefusal: String? = nil
    }

    enum Outcome: String, Equatable {
        case typed, deleted, ended, expired, failed, unconfirmed
    }

    struct Settled: Equatable {
        let clientId: String
        let sessionId: String
        /// Already redacted and clipped for the row.
        let text: String
        let heldAt: Date
        let outcome: Outcome
        let detail: String
        let at: Date
    }

    /// Whether a session's turn is over, as `SessionRemote` reads it.
    enum Readiness: Equatable {
        case ready, wait
        /// Not in the Mac's list.
        case gone
    }

    enum Step {
        /// Type it now. `claim` must be committed right before the first key.
        case type(Message, HeldClaim)
        /// It settled without a try (expired, the session ended): send `result`.
        case settle(Message, SessionCommandResult)
    }

    /// What a finished try means for the message.
    enum Verdict: Equatable { case typed, keep, final }

    struct Finish {
        /// The input's result due now: its final one, or (first try) its only one.
        var result: (clientId: String, result: SessionCommandResult)?
        /// Answers for deletes that waited on this try.
        var retracts: [(clientId: String, result: SessionCommandResult)] = []
    }

    enum Retract {
        /// Deleted: answer the delete at once, and send `final` to the input.
        case deleted(final: (clientId: String, result: SessionCommandResult))
        case alreadyDeleted
        /// A try has passed its switch: answered when the try finishes.
        case waits
        case tooLate
        case notFound
    }

    private(set) var messages: [Message] = []
    private(set) var settled: [Settled] = []
    /// The pairing the messages came in under (see `adopt(keyTag:)`).
    private(set) var keyTag: String?
    /// The switch of each message being typed right now, by its clientId.
    private var claims: [String: HeldClaim] = [:]
    /// Deletes that came after a try passed its switch, by the held clientId.
    private var waitingRetracts: [String: [String]] = [:]
    private var missing: [String: (since: Date, ticks: Int)] = [:]
    /// No try for the session before this.
    private var notBefore: [String: Date] = [:]

    init(messages: [Message] = [], settled: [Settled] = [], keyTag: String? = nil) {
        self.messages = messages
        self.settled = settled
        self.keyTag = keyTag
    }

    var isEmpty: Bool { messages.isEmpty }
    var sessionIds: [String] {
        var seen = Set<String>()
        return messages.map(\.sessionId).filter { seen.insert($0).inserted }
    }

    func waiting(sessionId: String) -> [Message] { messages.filter { $0.sessionId == sessionId } }

    // MARK: arrival

    /// Holds `m` (on arrival the try is the caller's: see `firstTry`). nil
    /// when added; otherwise the refusal for the input.
    mutating func add(_ m: Message) -> SessionCommandResult? {
        guard !messages.contains(where: { $0.clientId == m.clientId }) else { return .refused(.error, "Page already has that message") }
        if waiting(sessionId: m.sessionId).count >= Self.maxPerSession { return .refused(.error, Self.tooManyDetail) }
        if messages.count >= Self.maxTotal { return .refused(.error, Self.tooManyInAllDetail) }
        messages.append(m)
        return nil
    }

    /// The try made on arrival (the turn looked over): claims `clientId`.
    /// nil when it has to wait its turn: an older message for the session is
    /// still held or being typed, or one was typed moments ago.
    mutating func claimFirstTry(_ clientId: String, now: Date) -> (Message, HeldClaim)? {
        guard let i = messages.firstIndex(where: { $0.clientId == clientId }), !messages[i].typing else { return nil }
        let sid = messages[i].sessionId
        guard waiting(sessionId: sid).count == 1, notBefore[sid].map({ now >= $0 }) ?? true else { return nil }
        messages[i].typing = true
        messages[i].firstTry = true
        let claim = HeldClaim()
        claims[clientId] = claim
        return (messages[i], claim)
    }

    // MARK: the drain

    /// What to do now. `readiness` by session id (a session missing from it
    /// is `gone`); `tick` true when called for the Coordinator's tick (the
    /// list it reads is fresh), so "ended" needs a couple of them.
    mutating func plan(readiness: [String: Readiness], tick: Bool, now: Date) -> [Step] {
        var steps: [Step] = []
        prune(now: now)
        // Expired: never in the middle of a try.
        for m in messages where !m.typing && now.timeIntervalSince(m.heldAt) >= Self.lifetime {
            remove(m.clientId)
            steps.append(.settle(m, settle(m, .expired, detail: Self.expiredDetail, now: now,
                                           result: Self.fromHold(.refused(.expired, Self.expiredDetail)))))
        }
        for sid in sessionIds {
            let mine = waiting(sessionId: sid)
            switch readiness[sid] ?? .gone {
            case .gone:
                var mark = missing[sid] ?? (since: now, ticks: 0)
                if tick { mark.ticks += 1 }
                missing[sid] = mark
                guard now.timeIntervalSince(mark.since) >= Self.endedAfter, mark.ticks >= Self.endedTicks else { continue }
                for m in mine where !m.typing {
                    remove(m.clientId)
                    steps.append(.settle(m, settle(m, .ended, detail: Self.endedDetail, now: now,
                                                   result: Self.fromHold(.refused(.ended, Self.endedDetail)))))
                }
            case .wait:
                missing[sid] = nil
            case .ready:
                missing[sid] = nil
                guard !mine.contains(where: \.typing), notBefore[sid].map({ now >= $0 }) ?? true,
                      let head = mine.first, let i = messages.firstIndex(where: { $0.clientId == head.clientId }) else { continue }
                messages[i].typing = true
                let claim = HeldClaim()
                claims[head.clientId] = claim
                steps.append(.type(messages[i], claim))
            }
        }
        let live = Set(sessionIds)
        missing = missing.filter { live.contains($0.key) }
        notBefore = notBefore.filter { live.contains($0.key) }
        return steps
    }

    /// Pure. What a try's result means: typed, refused for a passing reason
    /// before any key (keep holding), or final (never retried: a `failed` may
    /// have typed part of it).
    static func verdict(_ r: SessionCommandResult) -> Verdict {
        switch r.code {
        case .delivered, .queued: return .typed
        case .failed, .cancelled: return .final
        case .refused: break
        }
        switch r.reason {
        case .busy?, .waiting?, .unknownState?, .draft?, .codexMidTurn?, .digitWhileBusy?:
            return .keep
        case .notTypable? where r.detail == InjectionExecutor.notForegroundMessage || r.detail == CodexInjector.notForegroundDetail:
            return .keep
        default:
            return .final
        }
    }

    /// A try came back with `r`.
    mutating func finish(clientId: String, result r: SessionCommandResult, now: Date) -> Finish {
        claims[clientId] = nil
        let waiters = waitingRetracts.removeValue(forKey: clientId) ?? []
        // Deleted before its keys: the switch refused the try, and the delete was answered then.
        guard let i = messages.firstIndex(where: { $0.clientId == clientId }) else { return Finish() }
        var m = messages[i]
        let verdict = Self.verdict(r)
        switch verdict {
        case .typed:
            remove(clientId)
            notBefore[m.sessionId] = now.addingTimeInterval(Self.typedGap)
            var out = Finish()
            if m.firstTry {
                out.result = (clientId, r)
            } else {
                var final = r
                final.fromHold = true
                out.result = (clientId, settle(m, .typed, detail: r.detail, now: now, result: final))
            }
            out.retracts = waiters.map { ($0, Self.retractResult(.tooLate)) }
            return out
        case .keep where waiters.isEmpty:
            m.typing = false
            m.tries += 1
            m.lastRefusal = r.detail.isEmpty ? nil : r.detail
            let wasFirst = m.firstTry
            m.firstTry = false
            messages[i] = m
            notBefore[m.sessionId] = now.addingTimeInterval(Self.retryDelay(tries: m.tries))
            guard wasFirst else { return Finish() }
            // The turn wasn't over after all: from now on it is held.
            return Finish(result: (clientId, Self.heldResult(backend: m.backend)))
        case .keep, .final:
            remove(clientId)
            // A refusal comes before any key; a `failed` may have typed part of it.
            if !waiters.isEmpty && r.code != .failed {
                // Nothing was typed, and someone asked to delete it.
                var final = SessionCommandResult(code: .cancelled, reason: .cancelled, detail: Self.deletedDetail)
                final.fromHold = !m.firstTry
                return Finish(result: (clientId, settle(m, .deleted, detail: Self.deletedDetail, now: now, result: final)),
                              retracts: waiters.map { ($0, Self.retractResult(.deleted)) })
            }
            let late = waiters.map { ($0, Self.retractResult(.tooLate, detail: Self.tooLateFailedDetail)) }
            if m.firstTry { return Finish(result: (clientId, r), retracts: late) }
            let ended = r.reason == .ended || r.reason == .notFound
            let detail = ended ? Self.endedDetail : Self.notSent(r.detail)
            var final = SessionCommandResult(code: r.code, reason: r.reason, detail: detail)
            final.fromHold = true
            return Finish(result: (clientId, settle(m, ended ? .ended : .failed, detail: detail, now: now, result: final)),
                          retracts: late)
        }
    }

    /// `r` as a held message's final result.
    static func fromHold(_ r: SessionCommandResult) -> SessionCommandResult {
        var out = r
        out.fromHold = true
        return out
    }

    static func retryDelay(tries: Int) -> TimeInterval {
        min(maxRetryDelay, retryAfter * Double(max(1, tries)))
    }

    static func notSent(_ detail: String) -> String {
        let d = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = d.first else { return "Not sent" }
        return "Not sent — " + first.lowercased() + d.dropFirst()
    }

    static func heldResult(backend: AgentBackendID) -> SessionCommandResult {
        var r = SessionCommandResult(code: .queued, reason: nil, detail: heldDetail(agent: backend == .codex ? "Codex" : "Claude"))
        r.held = true
        return r
    }

    // MARK: delete

    /// A delete for the held message `heldId`, from the retract `retractId`.
    mutating func retract(heldId: String, by retractId: String, now: Date) -> Retract {
        if let m = messages.first(where: { $0.clientId == heldId }) {
            if m.typing, let claim = claims[heldId], !claim.cancel() {
                // The try is past its switch: typed or not, it says so when it finishes.
                waitingRetracts[heldId, default: []].append(retractId)
                return .waits
            }
            // Waiting, or a try that hasn't reached its keys (it will come back
            // cancelled without typing anything).
            remove(heldId)
            var final = SessionCommandResult(code: .cancelled, reason: .cancelled, detail: Self.deletedDetail)
            final.fromHold = !m.firstTry
            return .deleted(final: (heldId, settle(m, .deleted, detail: Self.deletedDetail, now: now, result: final)))
        }
        switch settled.last(where: { $0.clientId == heldId })?.outcome {
        case .typed?, .unconfirmed?: return .tooLate
        case .deleted?: return .alreadyDeleted
        case .ended?, .expired?, .failed?, nil: return .notFound
        }
    }

    enum RetractAnswer { case deleted, alreadyDeleted, tooLate, notFound }

    /// The retract op's own result.
    static func retractResult(_ a: RetractAnswer, detail: String? = nil) -> SessionCommandResult {
        var r: SessionCommandResult
        switch a {
        case .deleted:
            r = SessionCommandResult(code: .delivered, reason: nil, detail: detail ?? deletedDetail)
            r.retract = "deleted"
        case .alreadyDeleted:
            r = SessionCommandResult(code: .delivered, reason: nil, detail: detail ?? alreadyDeletedDetail)
            r.retract = "deleted"
        case .tooLate:
            r = .refused(.tooLate, detail ?? tooLateDetail)
            r.retract = "too_late"
        case .notFound:
            r = .refused(.notFound, detail ?? notHeldDetail)
            r.retract = "not_found"
        }
        return r
    }

    // MARK: pairing

    /// The pairing the Mac is on now. Messages held under another pairing are
    /// dropped untyped (the phone that sent them is no longer trusted).
    /// Returns how many were dropped.
    mutating func adopt(keyTag tag: String) -> Int {
        defer { keyTag = tag }
        guard let old = keyTag, old != tag else { return 0 }
        let n = messages.count
        messages = []
        settled = []
        claims = [:]
        waitingRetracts = [:]
        return n
    }

    /// A short, one-way tag of the pairing's root key: enough to notice a new
    /// pairing, useless for recovering the key.
    static func keyTag(root: Data) -> String {
        let digest = SHA256.hash(data: Data("page-held-outbox-v1".utf8) + root)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: the row

    /// Pure. The row's `held` list (SESSIONS-PROTOCOL.md §4): waiting
    /// messages, then the ones settled in the last 15 minutes, oldest first.
    /// A first try isn't listed: it gets an ordinary result.
    func rowEntries(sessionId: String, now: Date) -> [[String: Any]] {
        let iso = SessionTranscript.isoFormatter
        let open = waiting(sessionId: sessionId).filter { !$0.firstTry }.prefix(Self.maxPerSession).map { m -> (Date, [String: Any]) in
            var o: [String: Any] = ["clientId": m.clientId, "text": Self.rowText(m.text), "heldAt": iso.string(from: m.heldAt),
                                    "state": m.typing ? "typing" : "held"]
            if let why = m.lastRefusal { o["detail"] = String(why.prefix(SessionCommandResult.maxDetail)) }
            return (m.heldAt, o)
        }
        let done = settled.filter { $0.sessionId == sessionId && now.timeIntervalSince($0.at) < Self.settledKept }
            .suffix(Self.maxSettledPerSession).map { s -> (Date, [String: Any]) in
                (s.heldAt, ["clientId": s.clientId, "text": s.text, "heldAt": iso.string(from: s.heldAt),
                            "state": s.outcome.rawValue, "at": iso.string(from: s.at),
                            "detail": String(s.detail.prefix(SessionCommandResult.maxDetail))])
            }
        return (Array(open) + done).sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// Pure. Redacted, then clipped, like a transcript entry.
    static func rowText(_ text: String) -> String {
        InterventionDetector.clip(ContextRedactor.redactedPrefix(text, rowTextLimit), rowTextLimit)
    }

    /// What the Mac's panel shows: the waiting messages, by session.
    func panelItems() -> [HeldMessageInfo] {
        messages.filter { !$0.firstTry }.map {
            HeldMessageInfo(clientId: $0.clientId, sessionId: $0.sessionId, text: Self.rowText($0.text), heldAt: $0.heldAt,
                            typing: $0.typing)
        }
    }

    // MARK: helpers

    private mutating func remove(_ clientId: String) {
        messages.removeAll { $0.clientId == clientId }
    }

    /// Records the outcome for the row and returns `result` unchanged.
    private mutating func settle(_ m: Message, _ outcome: Outcome, detail: String, now: Date,
                                 result: SessionCommandResult) -> SessionCommandResult {
        guard !m.firstTry || outcome == .deleted else { return result }
        settled.append(Settled(clientId: m.clientId, sessionId: m.sessionId, text: Self.rowText(m.text), heldAt: m.heldAt,
                               outcome: outcome, detail: detail, at: now))
        return result
    }

    private mutating func prune(now: Date) {
        settled.removeAll { now.timeIntervalSince($0.at) >= Self.settledKept }
        // Bounded per session (the newest kept).
        var perSession: [String: Int] = [:]
        settled = Array(settled.reversed().filter { s in
            perSession[s.sessionId, default: 0] += 1
            return perSession[s.sessionId]! <= Self.maxSettledPerSession
        }.reversed())
    }
}

/// A held message as the Mac's panel shows it.
struct HeldMessageInfo: Equatable {
    let clientId: String
    let sessionId: String
    /// Redacted and clipped.
    let text: String
    let heldAt: Date
    /// Being typed right now (Delete may come too late).
    var typing = false
}

// MARK: - On disk

/// `held_outbox.json`: the held messages and recent outcomes, so a Page
/// restart neither loses nor double-types them. Atomic 0600 writes; a failed
/// write only loses the messages across a restart, it never blocks one.
struct HeldOutboxStore {
    let url: URL
    static let maxBytes = 1024 * 1024

    func load(now: Date) -> HeldOutbox {
        guard let data = BoundedFileRead.read(url.path, maxBytes: Self.maxBytes) else { return HeldOutbox() }
        return Self.decode(data, now: now)
    }

    func save(_ box: HeldOutbox) {
        guard let data = Self.encode(box) else { return }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(tmp.path, url.path) != 0 { try? FileManager.default.removeItem(at: tmp) }
    }

    static func encode(_ box: HeldOutbox) -> Data? {
        let messages: [[String: Any]] = box.messages.map { m in
            var o: [String: Any] = ["clientId": m.clientId, "sessionId": m.sessionId, "backend": m.backend.rawValue,
                                    "text": m.text, "heldAt": m.heldAt.timeIntervalSince1970, "tries": m.tries]
            if let v = m.expectCwd { o["expectCwd"] = v }
            if let v = m.expectTitle { o["expectTitle"] = v }
            if m.typing { o["typing"] = true }
            if m.firstTry { o["firstTry"] = true }
            if let v = m.lastRefusal { o["lastRefusal"] = v }
            return o
        }
        let settled: [[String: Any]] = box.settled.map { s in
            ["clientId": s.clientId, "sessionId": s.sessionId, "text": s.text, "heldAt": s.heldAt.timeIntervalSince1970,
             "outcome": s.outcome.rawValue, "detail": s.detail, "at": s.at.timeIntervalSince1970]
        }
        var obj: [String: Any] = ["v": 1, "messages": messages, "settled": settled]
        if let tag = box.keyTag { obj["keyTag"] = tag }
        return try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }

    /// Pure. A message whose try had started settles as `unconfirmed` (never
    /// retyped); anything malformed is skipped; bounds are applied again.
    static func decode(_ data: Data, now: Date) -> HeldOutbox {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], obj["v"] as? Int == 1 else { return HeldOutbox() }
        var messages: [HeldOutbox.Message] = []
        var settled: [HeldOutbox.Settled] = []
        for o in obj["messages"] as? [[String: Any]] ?? [] {
            guard let cid = o["clientId"] as? String, !cid.isEmpty, cid.count <= SessionCommand.maxIdLength,
                  let sid = o["sessionId"] as? String, !sid.isEmpty, sid.count <= 256,
                  let backend = (o["backend"] as? String).flatMap(AgentBackendID.init(rawValue:)),
                  let text = o["text"] as? String, case .success(let clean) = SessionInputGate.validateText(text),
                  let at = (o["heldAt"] as? NSNumber)?.doubleValue,
                  !messages.contains(where: { $0.clientId == cid }) else { continue }
            var m = HeldOutbox.Message(clientId: cid, sessionId: sid, backend: backend, text: clean,
                                       heldAt: Date(timeIntervalSince1970: at))
            m.expectCwd = o["expectCwd"] as? String
            m.expectTitle = o["expectTitle"] as? String
            m.tries = (o["tries"] as? Int) ?? 0
            m.lastRefusal = o["lastRefusal"] as? String
            if o["typing"] as? Bool == true {
                settled.append(HeldOutbox.Settled(clientId: cid, sessionId: sid, text: HeldOutbox.rowText(clean), heldAt: m.heldAt,
                                                  outcome: .unconfirmed, detail: HeldOutbox.unconfirmedDetail, at: now))
                continue
            }
            guard messages.filter({ $0.sessionId == sid }).count < HeldOutbox.maxPerSession,
                  messages.count < HeldOutbox.maxTotal else { continue }
            messages.append(m)
        }
        for o in obj["settled"] as? [[String: Any]] ?? [] {
            guard let cid = o["clientId"] as? String, !cid.isEmpty, cid.count <= SessionCommand.maxIdLength,
                  let sid = o["sessionId"] as? String, !sid.isEmpty, sid.count <= 256,
                  let text = o["text"] as? String,
                  let heldAt = (o["heldAt"] as? NSNumber)?.doubleValue,
                  let outcome = (o["outcome"] as? String).flatMap(HeldOutbox.Outcome.init(rawValue:)),
                  let detail = o["detail"] as? String,
                  let at = (o["at"] as? NSNumber)?.doubleValue,
                  now.timeIntervalSince1970 - at < HeldOutbox.settledKept else { continue }
            settled.append(HeldOutbox.Settled(clientId: cid, sessionId: sid, text: String(text.prefix(HeldOutbox.rowTextLimit + 1)),
                                              heldAt: Date(timeIntervalSince1970: heldAt), outcome: outcome,
                                              detail: String(detail.prefix(SessionCommandResult.maxDetail)),
                                              at: Date(timeIntervalSince1970: at)))
        }
        settled.sort { $0.at < $1.at }
        return HeldOutbox(messages: messages, settled: settled, keyTag: obj["keyTag"] as? String)
    }
}

// MARK: - Replies a backend holds

/// Replies to relay pages that a backend holds instead of delivering at once
/// (SESSIONS-PROTOCOL.md §5 "Taking a message back"): a written reply to a
/// rate-limit page, typed once the limit resets, and a reply waiting for its
/// background run (`claude --resume --print` behind another, or Codex
/// `exec resume`). Pure; the backend keeps one under its own lock, so a
/// delete and the path that types it can never both win.
struct HeldReplies {
    struct ResetMessage: Equatable {
        let text: String
        let interventionId: String
    }

    enum Retract: Equatable {
        /// A reset message, deleted (its event id).
        case resetDeleted(eventId: String)
        /// A background run that hadn't started, deleted.
        case launchDeleted
        /// The reset path has already taken it to type.
        case resetTaken
        case notHeld
    }

    static let takenMemory = 100

    /// By rate-limit event id.
    private(set) var resetMessages: [String: ResetMessage] = [:]
    /// Reset messages the reset path took (intervention ids), newest last.
    private var resetTaken: [String] = []
    /// Replies waiting for their background run to start.
    private var launches = Set<String>()

    mutating func holdForReset(eventId: String, text: String, interventionId: String) {
        resetMessages[eventId] = ResetMessage(text: text, interventionId: interventionId)
    }

    /// The reset path takes the message to type it; a delete after this is too late.
    mutating func takeForReset(eventId: String) -> ResetMessage? {
        guard let m = resetMessages.removeValue(forKey: eventId) else { return nil }
        resetTaken.append(m.interventionId)
        if resetTaken.count > Self.takenMemory { resetTaken.removeFirst(resetTaken.count - Self.takenMemory) }
        return m
    }

    mutating func queueLaunch(_ interventionId: String) {
        launches.insert(interventionId)
    }

    /// The background run, right before it starts: true when it may go
    /// ahead, false when a delete took it first (already reported).
    mutating func claimLaunch(_ interventionId: String) -> Bool {
        launches.remove(interventionId) != nil
    }

    func isWaitingToLaunch(_ interventionId: String) -> Bool { launches.contains(interventionId) }

    mutating func retract(_ interventionId: String) -> Retract {
        if let (eventId, _) = resetMessages.first(where: { $0.value.interventionId == interventionId }) {
            resetMessages.removeValue(forKey: eventId)
            return .resetDeleted(eventId: eventId)
        }
        if launches.remove(interventionId) != nil { return .launchDeleted }
        if resetTaken.contains(interventionId) { return .resetTaken }
        return .notHeld
    }
}

/// What a backend says to a delete of a reply it may be holding.
enum HeldRetract: Equatable {
    case deleted(String)
    case tooLate(String)
    case notFound

    static let resetDeletedWithCarryOn = "Deleted — not sent. Page will type your carry-on prompt when the limit resets"
    static let resetDeletedNothing = "Deleted — not sent. Nothing will be typed at reset"
    static let resetTooLate = "Too late — Page was already typing it after the limit reset"
    static let alreadyRunning = "Too late — it's already running"
    static let alreadyDelivered = "Too late — it was already delivered"

    /// The retract op's result.
    var result: SessionCommandResult {
        switch self {
        case .deleted(let d): return HeldOutbox.retractResult(.deleted, detail: d)
        case .tooLate(let d): return HeldOutbox.retractResult(.tooLate, detail: d)
        case .notFound: return HeldOutbox.retractResult(.notFound)
        }
    }
}
