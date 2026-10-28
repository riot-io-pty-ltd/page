import Foundation

// The model behind Night Watch's Now screen on the phone: the headline, the
// Runway, the ranked rows, the day's rings and the receipt line. Built from
// what the phone already holds (inbox pages, live sessions, the Mac's status
// and history) with no clock, calendar or service calls inside: callers pass
// `now`, the time zone and everything else, so tests can feed any situation.

// MARK: - Receipts

/// The receipt for a keystroke Page delivered (or could not).
struct DeliveryReceipt: Equatable {
    enum Verb: String, Equatable { case approved = "Approved", denied = "Denied", replied = "Replied to", stopped = "Stopped" }

    /// What happened, in the words the trust model fixes for each outcome.
    enum Outcome: Equatable {
        case delivered
        case timedOut
        case sessionEnded
        case notTypable
        case queued
        case promptClosed
        case answeredAtMac
        case unknownState
        /// The Mac was offline: the relay holds the reply until it is back.
        case macOffline
        /// Held on the Mac until a rate limit resets (`held_until_reset`): not typed, and it can be deleted.
        case heldUntilReset(String)
        /// Taken back: nothing was typed.
        case deleted
        /// A failure the Mac described in its own words.
        case other(String)

        /// The sentence for anything but a confirmed delivery; nil for `.delivered`.
        var failureMessage: String? {
            switch self {
            case .delivered: return nil
            case .timedOut: return "Didn't confirm in time · Check on Mac"
            case .sessionEnded: return "Session ended"
            case .notTypable: return "This terminal can't take input · Open on Mac"
            case .queued: return "Queued after this turn"
            case .promptClosed: return "Prompt closed before your answer"
            case .answeredAtMac: return "Already answered at the Mac"
            case .unknownState: return "Review again"
            case .macOffline: return "Waiting for your Mac to come back online"
            case .heldUntilReset(let when): return when
            case .deleted: return SessionDeliveryState.deletedCopy
            case .other(let why): return why.isEmpty ? "Couldn't deliver the reply" : why
            }
        }
    }

    let verb: Verb
    /// "npm test".
    let subject: String
    /// "cmux › page".
    let route: String
    let at: Date
    var outcome: Outcome = .delivered
    /// The page this was a reply to, so a receipt for a reply still waiting can offer Delete.
    var pageId: String? = nil

    /// "Approved npm test → cmux › page · verified 23:47:12"; anything but a
    /// confirmed delivery reads "<subject> · <what went wrong and what to do>".
    func line(timeZone: TimeZone = .current) -> String {
        if let why = outcome.failureMessage { return "\(subject) · \(why)" }
        let to = route.isEmpty ? "" : " → \(route)"
        return "\(verb.rawValue) \(subject)\(to) · verified \(NowFormat.clock(at, seconds: true, timeZone: timeZone))"
    }
}

enum ReceiptBuilder {
    /// The receipt for a page's reply, or nil while it is still in flight:
    /// "sent" is not "delivered", so success is only ever a confirmed
    /// `.delivered`. Pure.
    ///
    /// `changedAt` is when the phone last saw this delivery change state. A
    /// failure, an answered-at-the-Mac or a closed prompt is stamped with it
    /// (or the page's own reply time) rather than the rebuild time, so it ages
    /// out of Now like a delivered receipt does.
    static func receipt(for iv: Intervention, delivery: ReplyDelivery, route: String?, now: Date, changedAt: Date? = nil,
                        retractNote: RetractNote? = nil) -> DeliveryReceipt? {
        let verb: DeliveryReceipt.Verb
        switch iv.repliedAction {
        case "approve": verb = .approved
        case "deny": verb = PageSubtype.canStop(iv.subtype) ? .stopped : .denied
        default: verb = .replied
        }
        let subject = verb == .replied && iv.kind != .approval ? iv.projectName : NowRowBuilder.summaryLine(for: iv)
        func make(_ outcome: DeliveryReceipt.Outcome, at: Date) -> DeliveryReceipt {
            DeliveryReceipt(verb: verb, subject: subject, route: route ?? "", at: at, outcome: outcome, pageId: iv.id)
        }
        let stamp = iv.repliedAt ?? changedAt ?? now
        switch delivery {
        case .sending: return nil
        case .sent(let queued, let at):
            if queued { return make(.macOffline, at: at) }
            // The relay already gave it to the Mac and Delete went on asking it: that stays on the line until the
            // Mac answers (a reply with no Delete under way is still just in flight).
            if let n = retractNote, ForwardedRetract.isChainNote(n) { return make(.other(n.text), at: changedAt ?? at) }
            return nil
        case .delivered: return make(.delivered, at: iv.repliedAt ?? now)
        case .failed(let why): return make(.other(why), at: stamp)
        case .alreadyReplied: return make(.answeredAtMac, at: stamp)
        case .gone: return make(.promptClosed, at: stamp)
        case .heldOnMac(let detail):
            return make(.heldUntilReset(HeldUntilReset.headline(detail: detail, resetsAt: nil, timeZone: .current)), at: iv.repliedAt ?? changedAt ?? now)
        case .retracted: return make(.deleted, at: stamp)
        }
    }
}

// MARK: - Runway

/// A deadline or event on the next six hours.
struct RunwayMarker: Equatable, Identifiable {
    enum Kind: String, Equatable { case batteryCutoff, usageLimit, usageReset, weeklyReset, resume }
    enum Tone: String, Equatable { case amber, green, blue }

    let id: String
    let kind: Kind
    /// "5h 02:40", "reset 03:00", "resume 04:10", "cutoff 03:40".
    let label: String
    let at: Date
    /// 0 (now) ... 1 (end of the window), clamped.
    let fraction: Double
    let tone: Tone
    /// 0, 1 or 2: another row when two labels would overlap.
    var lane: Int = 0
}

struct RunwayModel: Equatable {
    /// How far ahead the runway looks.
    static let window: TimeInterval = 6 * 3600

    var markers: [RunwayMarker]
    /// On AC (or no battery) the runway is a full horizon line: no cutoff.
    var onAC: Bool
    /// Earliest deadline (battery cutoff or 5h limit hit), if any.
    var clearUntil: Date?
    /// What the phone does not know and so does not draw (scheduled resumes,
    /// which the Mac does not report to the phone yet).
    static let empty = RunwayModel(markers: [], onAC: true, clearUntil: nil)

    /// Position of `at` across the window: 0 now, 1 at the end; nil when it is
    /// already past or beyond the window. Pure.
    static func fraction(of at: Date, now: Date, window: TimeInterval = RunwayModel.window) -> Double? {
        let dt = at.timeIntervalSince(now)
        guard dt >= 0, dt <= window else { return nil }
        return dt / window
    }

    /// Gives a marker whose label would overlap the previous one in lane 0 a
    /// second lane, or a third when both are taken.
    /// `minGap` is the least fraction between labels in a lane: about one
    /// label width on a phone (92 pt of roughly 330). Pure.
    static func assignLanes(_ markers: [RunwayMarker], minGap: Double = 0.28) -> [RunwayMarker] {
        var lastInLane: [Int: Double] = [:]
        var out: [RunwayMarker] = []
        for var m in markers.sorted(by: { $0.fraction < $1.fraction }) {
            func free(_ lane: Int) -> Bool { lastInLane[lane].map { m.fraction - $0 >= minGap } ?? true }
            // The first lane with room; with none, the one whose last label is furthest away.
            let lane = (0..<3).first(where: free)
                ?? (0..<3).max { (m.fraction - (lastInLane[$0] ?? -1)) < (m.fraction - (lastInLane[$1] ?? -1)) } ?? 0
            m.lane = lane
            lastInLane[lane] = m.fraction
            out.append(m)
        }
        return out
    }

    /// The Runway from the Mac's status: battery cutoff (only on battery),
    /// the 5-hour limit hit and resets. Usage older than six hours is ignored
    /// (the same rule as the usage card). Pure.
    static func build(status: MacStatusSnapshot?, now: Date, timeZone: TimeZone) -> RunwayModel {
        guard let s = status else { return .empty }
        var markers: [RunwayMarker] = []
        var deadlines: [Date] = []

        func add(_ id: String, _ kind: RunwayMarker.Kind, _ prefix: String, _ at: Date, _ tone: RunwayMarker.Tone) {
            guard let f = fraction(of: at, now: now) else { return }
            markers.append(RunwayMarker(id: id, kind: kind, label: "\(prefix) \(NowFormat.clock(at, timeZone: timeZone))",
                                        at: at, fraction: f, tone: tone))
        }

        let onAC = s.onAC != false
        if !onAC, let f = s.forecast {
            let at = now.addingTimeInterval(TimeInterval(f.minutes) * 60)
            deadlines.append(at)
            add("battery-cutoff", .batteryCutoff, "cutoff", at, .amber)
        }
        if let u = s.usage, !(u.updatedAt.map { now.timeIntervalSince($0) > UsageCardModel.hideAfter } ?? false) {
            if let hit = u.hitAt, hit > now {
                deadlines.append(hit)
                add("usage-limit", .usageLimit, "5h", hit, .amber)
            }
            if let reset = u.fiveHour?.resetsAt { add("usage-reset", .usageReset, "reset", reset, .green) }
            if let weekly = u.sevenDay?.resetsAt { add("weekly-reset", .weeklyReset, "7d reset", weekly, .green) }
        }
        return RunwayModel(markers: assignLanes(markers), onAC: onAC, clearUntil: deadlines.min())
    }
}

// MARK: - Day rings

/// "Unblocked, Shipped, Calm": three daily rings.
struct RingStat: Equatable, Identifiable {
    enum Kind: String, Equatable { case unblocked = "Unblocked", shipped = "Shipped", calm = "Calm" }
    let kind: Kind
    /// 0...1.
    let progress: Double
    /// "11 / 12", "7 / 10", "4 h 10 min".
    let detail: String
    var id: String { kind.rawValue }
}

/// What the day's pages say.
struct DayStats: Equatable {
    /// Decisions answered in under two minutes, of all decisions.
    var unblockedFast = 0
    var decisions = 0
    /// Turns that finished, of all finished or stuck turns.
    var shipped = 0
    var finished = 0
    /// Seconds agents ran without you. The Mac does not report this to the
    /// phone, so it is nil there and the ring reads "not tracked".
    var calmSeconds: TimeInterval?
    var calmGoal: TimeInterval = 4 * 3600

    /// Fast means answered within this many seconds.
    static let fastSeconds = 120

    var rings: [RingStat] {
        func frac(_ a: Int, _ b: Int) -> Double { b > 0 ? min(1, Double(a) / Double(b)) : 0 }
        return [
            RingStat(kind: .unblocked, progress: frac(unblockedFast, decisions),
                     detail: decisions > 0 ? "\(unblockedFast) / \(decisions)" : "none yet"),
            RingStat(kind: .shipped, progress: frac(shipped, finished),
                     detail: finished > 0 ? "\(shipped) / \(finished)" : "none yet"),
            RingStat(kind: .calm, progress: calmSeconds.map { calmGoal > 0 ? min(1, max(0, $0 / calmGoal)) : 0 } ?? 0,
                     detail: calmSeconds.map { NowFormat.duration(seconds: $0) } ?? "not tracked")
        ]
    }

    /// Today's rings from the archived pages and the open ones. `history`
    /// is the Mac's resolved pages. Pure.
    static func today(history: [Intervention], now: Date, calendar: Calendar) -> DayStats {
        let start = calendar.startOfDay(for: now)
        var s = DayStats()
        for iv in history where SettledLog.isDecision(iv) {
            guard let at = iv.repliedAt, at >= start else { continue }
            s.decisions += 1
            if let t = iv.responseTimeSeconds, t < fastSeconds { s.unblockedFast += 1 }
        }
        for iv in history where SettledLog.isFinishedTurn(iv) || SettledLog.isStuck(iv) {
            guard (iv.closedAt ?? iv.openedAt) >= start else { continue }
            s.finished += 1
            if SettledLog.isFinishedTurn(iv) { s.shipped += 1 }
        }
        return s
    }
}

// MARK: - Now

struct NowInputs {
    /// How the inbox stands: "All quiet" is only true after a successful load.
    enum InboxState: Equatable { case loading, loaded, failed }

    /// Open pages (`APIClient.inbox`).
    var interventions: [Intervention] = []
    var inbox: InboxState = .loaded
    /// Live sessions, when the list has arrived.
    var sessions: [LiveSession] = []
    var hasSessionList = false
    var status: MacStatusSnapshot?
    /// Resolved pages (`APIClient.history`).
    var history: [Intervention] = []
    /// Where each reply stands (`APIClient.deliveries`).
    var deliveries: [String: ReplyDelivery] = [:]
    /// When each delivery last changed on this phone (`APIClient.deliveryTimes`).
    var deliveryTimes: [String: Date] = [:]
    var now: Date
    /// "Studio MBP": every action names the Mac it will act on.
    var macName: String
    var timeZone: TimeZone = .current
    var calendar: Calendar = .current
    /// `GET /status` features (nil until known) and the Mac's `caps`: Delete is offered only when they say so.
    var relayFeatures: Set<String>? = nil
    var macCaps: Set<String> = []
    /// Where each Delete stands, by page id (`SessionStore.retractNotes`).
    var retractNotes: [String: RetractNote] = [:]
}

/// The latest receipt is a reply still waiting where it can be taken back: Delete, and which layer holds it.
struct ReceiptRetract: Equatable {
    let pageId: String
    let sessionId: String
    let layer: ReplyQueueStatus.Layer
}

struct NowModel: Equatable {
    /// Which aurora and pulse colour the header uses.
    enum Mood: String, Equatable { case needsYou, working, quiet, dusk }

    var mood: Mood
    /// "2 need you", "All quiet", "Paused for battery".
    var headline: String
    /// "5 working · runway clear till 03:40", "nothing needs you".
    var subline: String
    var needYouCount: Int
    var lookCount: Int
    var reviewCount: Int
    var workingCount: Int
    /// Decide rows first (Irreversible first), then Look, then Review.
    var rows: [NowRow]
    var runway: RunwayModel
    /// The latest receipt, as a line; nil when none is recent.
    var receiptLine: String?
    /// The latest receipt is not a confirmed delivery (drawn amber, not teal).
    var receiptFailed: Bool
    /// The latest receipt is a reply queued at the relay (Mac offline) or held on the Mac until a limit resets,
    /// and the relay or Mac can take it back: its line carries a Delete.
    var receiptRetract: ReceiptRetract? = nil
    /// An open "paused for battery" page: agents are paused at the cutoff.
    var paused: Bool
    var rings: [RingStat]
    var macName: String
    /// Spoken for the header.
    var accessibilityLabel: String

    var attentionCount: Int { needYouCount + lookCount }

    /// What the pulse counts, one ring per item, on every surface (the
    /// Horizon, the capsule, the Mac's popover and menu-bar glyph): the
    /// decisions, else the looks, which is the count the headline names.
    var pulseWaiting: Int { Self.pulseWaiting(need: needYouCount, look: lookCount) }

    /// The pulse's count from the two section counts. Pure.
    static func pulseWaiting(need: Int, look: Int) -> Int { need > 0 ? max(0, need) : max(0, look) }

    /// The rows the pulse counts (the decisions, else the looks; never the
    /// finished turns): their oldest wait sets the ripple's pace, as on the
    /// Mac (`PulseModel.longestWait(rows:now:)`).
    var pulseRows: [NowRow] {
        let decide = rows.filter { $0.section == .decide }
        return decide.isEmpty ? rows.filter { $0.section == .look } : decide
    }

    /// The pulse straight from the open pages, for the capsule, which has no
    /// model of its own: how many it counts and the oldest wait among them.
    /// The same rule as `pulseWaiting` and `pulseRows`. Pure.
    static func pulse(inbox: [Intervention], now: Date) -> (waiting: Int, longestWait: TimeInterval) {
        let decide = inbox.filter { NowRowBuilder.section(of: $0) == .decide }
        let counted = decide.isEmpty ? inbox.filter { NowRowBuilder.section(of: $0) == .look } : decide
        return (counted.count, PulseModel.longestWait(since: counted.map(\.openedAt), now: now))
    }

    /// Receipts older than this are not shown.
    static let receiptWindow: TimeInterval = 15 * 60

    /// Counts follow the board: "need you" is approvals, plans and questions
    /// (the agent is blocked); "look" is stuck agents, rate limits and
    /// forecasts; "review" is finished turns. "Working" is the live sessions
    /// the Mac reports as active, or its heartbeat count before the list
    /// arrives. Pure.
    static func build(_ i: NowInputs) -> NowModel {
        let tz = i.timeZone
        let rows = NowRowBuilder.ranked(i.interventions.map { iv in
            NowRowBuilder.row(for: iv, session: i.sessions.first { $0.id == iv.sessionId }, macName: i.macName)
        })
        let need = rows.filter { $0.section == .decide }.count
        let look = rows.filter { $0.section == .look }.count
        let review = rows.filter { $0.section == .review }.count
        let working = i.hasSessionList ? i.sessions.filter { $0.state == .active }.count : (i.status?.working ?? 0)

        let runway = RunwayModel.build(status: i.status, now: i.now, timeZone: tz)
        let paused = i.interventions.contains { $0.kind == .idle && $0.subtype == "low_battery" }
        let reachable = MacPresence.evaluate(i.status, now: i.now).isReachable

        let mood: Mood = paused ? .dusk : (need + look > 0 ? .needsYou : (working > 0 ? .working : .quiet))

        let headline: String
        let subline: String
        if paused {
            headline = "Paused for battery"
            subline = i.status?.onAC == true ? "plugged in · agents resume soon" : "plug the Mac in to resume"
        } else if need > 0 {
            headline = "\(need) \(need == 1 ? "needs" : "need") you"
            subline = ([working > 0 ? "\(working) working" : nil, runwayLine(status: i.status, runway: runway, timeZone: tz)]
                .compactMap { $0 }).joined(separator: " · ")
        } else if look > 0 {
            headline = "\(look) \(look == 1 ? "needs" : "need") a look"
            subline = ([working > 0 ? "\(working) working" : nil, runwayLine(status: i.status, runway: runway, timeZone: tz)]
                .compactMap { $0 }).joined(separator: " · ")
        } else if i.inbox == .loading {
            headline = "Checking…"
            subline = "asking \(DeliveryPreview.macLabel(i.macName)) what's happening"
        } else if i.inbox == .failed || !reachable {
            // Silence has to be earned: an unreachable Mac or a failed load
            // is not "All quiet".
            headline = "Nothing waiting"
            subline = i.inbox == .failed ? "the list may be out of date" : "\(DeliveryPreview.macLabel(i.macName)) isn't connected"
        } else {
            headline = "All quiet"
            subline = working > 0 ? "\(working) working · nothing needs you" : "no agents running · nothing needs you"
        }

        // Receipt: the newest page whose reply has a verdict.
        var receipts: [(DeliveryReceipt, Date)] = []
        var seen = Set<String>()
        for iv in i.history + i.interventions where seen.insert(iv.id).inserted {
            guard let d = i.deliveries[iv.id] else { continue }
            let session = i.sessions.first { $0.id == iv.sessionId }
            let route = DeliveryPreview.route(host: session?.host, project: session?.title ?? iv.projectName)
            if let r = ReceiptBuilder.receipt(for: iv, delivery: d, route: route, now: i.now, changedAt: i.deliveryTimes[iv.id],
                                              retractNote: i.retractNotes[iv.id]),
               i.now.timeIntervalSince(r.at) < receiptWindow, r.at <= i.now.addingTimeInterval(60) {
                receipts.append((r, r.at))
            }
        }
        let latest = receipts.max { $0.1 < $1.1 }?.0
        var retract: ReceiptRetract?
        if let latest, let id = latest.pageId, let iv = (i.interventions + i.history).first(where: { $0.id == id }), !iv.isBlockingHook {
            switch latest.outcome {
            case .macOffline where RelayQueue.canDelete(features: i.relayFeatures):
                retract = ReceiptRetract(pageId: id, sessionId: iv.sessionId, layer: .relay)
            case .heldUntilReset where i.macCaps.contains(SendChoicePlan.retractCap):
                retract = ReceiptRetract(pageId: id, sessionId: iv.sessionId, layer: .macHold)
            default: break
            }
        }

        return NowModel(
            mood: mood, headline: headline, subline: subline,
            needYouCount: need, lookCount: look, reviewCount: review, workingCount: working,
            rows: rows, runway: runway, receiptLine: latest?.line(timeZone: tz),
            receiptFailed: latest.map { $0.outcome != .delivered } ?? false, receiptRetract: retract, paused: paused,
            rings: DayStats.today(history: i.history, now: i.now, calendar: i.calendar).rings,
            macName: i.macName, accessibilityLabel: "Page, \(headline)")
    }

    /// "runway clear till 03:40 · 41%", "on battery · 41%", "runway clear".
    static func runwayLine(status: MacStatusSnapshot?, runway: RunwayModel, timeZone: TimeZone) -> String {
        var parts: [String] = []
        let onBattery = status?.onAC == false
        if let end = runway.clearUntil {
            parts.append("runway clear till \(NowFormat.clock(end, timeZone: timeZone))")
            if onBattery, let b = status?.batteryPercent { parts.append("\(b)%") }
        } else if onBattery {
            parts.append("on battery" + (status?.batteryPercent.map { " · \($0)%" } ?? ""))
        } else {
            parts.append("runway clear")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Time

enum NowFormat {
    /// 24-hour "03:40" (or "23:47:12" with seconds), as the boards show. Pure.
    static func clock(_ date: Date, seconds: Bool = false, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.hour, .minute, .second], from: date)
        let hm = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        return seconds ? hm + String(format: ":%02d", c.second ?? 0) : hm
    }

    /// "52 min", "1 h 52 min", "4 h": minutes under an hour, else hours and
    /// minutes. `upper` gives "52 MIN" for labels. Pure.
    static func duration(seconds: TimeInterval, upper: Bool = false) -> String {
        let total = max(0, Int((seconds / 60).rounded()))
        let h = total / 60, m = total % 60
        let text: String
        if h == 0 { text = "\(max(1, m)) min" }
        else if m == 0 { text = "\(h) h" }
        else { text = "\(h) h \(m) min" }
        return upper ? text.uppercased() : text
    }
}
