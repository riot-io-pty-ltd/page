import Foundation

/// THE RECEIPT THREAD: delivery truth made visible, the same on every
/// surface. Three nodes, the card (phone), the relay and the Mac, joined by a
/// thin thread of light:
///
/// - ARM (0-1.2 s): a ring winds round the card's dot. Nothing has left the
///   phone; a tap cancels. (An Irreversible approve's hold plus biometrics
///   is its arm, so it starts at SEND.)
/// - SEND: the thread leaves the card. While the request is in flight it
///   reaches towards the relay; once the relay has it ("sent") it rests at
///   the relay node and only a faint glint travels on. It cannot be
///   cancelled, and nothing says it can.
/// - RESOLVE, only when the Mac confirms the keystroke landed
///   (`ReplyDelivery.delivered`): the thread runs on to the Mac ("typed"),
///   then "verified ✓"; the dot turns from amber to teal, its rings contract
///   into it, and a card that has left the stream folds into a hairline and
///   drifts into Settled. The phone has no separate "typed" report, so
///   "typed" and "verified" are both played after the one confirmation, in
///   order, and never on a timer before it.
/// - FAILURE (failed, answered at the Mac, prompt closed, a local problem):
///   the thread snaps back, the card shakes once, softly, and the outcome is
///   said in words.
///
/// Pure: `derive` maps the real delivery state and the seconds since it last
/// changed to a frame.
struct ReceiptThread: Equatable {
    enum Stage: Equatable {
        case idle
        case arming
        /// The request is on its way to the relay.
        case sending
        /// The relay has it; waiting on the Mac.
        case sent
        /// The relay holds it until the Mac is back online.
        case queued
        /// Confirmed by the Mac: the thread has reached it.
        case typed
        /// Confirmed by the Mac, and the receipt has settled.
        case verified
        case failed(String)
    }

    var stage: Stage
    /// The arm ring round the dot, 0...1.
    var arm: Double = 0
    /// How far the solid thread reaches: 0 at the card, 0.5 at the relay, 1 at the Mac.
    var reach: Double = 0
    /// A faint glint travelling past the relay while the Mac is awaited (0.5...1), else nil.
    var glint: Double? = nil
    /// The relay node is lit (it has the reply).
    var relayLit = false
    /// The Mac node is lit (it confirmed).
    var macLit = false
    /// The card's dot: 0 amber ... 1 teal.
    var dotTeal: Double = 0
    /// The dot's rings: 1 open ... 0 contracted into the dot.
    var rings: Double = 1
    /// A card that has left the stream folds into a hairline: 0 ... 1.
    var fold: Double = 0
    /// ...then drifts down into Settled and fades: 0 ... 1.
    var drift: Double = 0
    /// One soft shake: -1 ... 1 (multiply by a few points).
    var shake: Double = 0
    /// The stage in the board's words: "arm", "sent", "typed", "verified ✓",
    /// or the failure in words.
    var word: String = ""
    /// Something on it is still moving: the view needs a clock.
    var moving = false

    // MARK: timings

    /// SEND: the thread reaches towards the relay over this long.
    static let reachRelay: TimeInterval = 0.5
    /// RESOLVE: relay to Mac ("typed") ...
    static let reachMac: TimeInterval = 0.36
    /// ... "verified ✓" ...
    static let verifiedAt: TimeInterval = 0.6
    /// ... the dot turns teal and its rings contract by ...
    static let contracted: TimeInterval = 1.0
    /// ... the card folds into a hairline by ...
    static let folded: TimeInterval = 1.3
    /// ... and has drifted into Settled by.
    static let resolveDuration: TimeInterval = 1.6
    /// FAILURE: snap back and shake.
    static let snapBack: TimeInterval = 0.24
    static let shakeDuration: TimeInterval = 0.42
    /// The glint stops travelling after this long (the words carry on).
    static let glintFor: TimeInterval = 12
    static let glintPeriod: TimeInterval = 1.4

    // MARK: derive

    /// The thread for one action. `changedAt` is when the delivery last
    /// changed on this phone (`APIClient.deliveryTimes`); unknown means the
    /// change is old news and the frame is drawn settled. Success is only
    /// ever drawn from `.delivered`. Pure.
    static func derive(pending: PendingAction?, delivery: ReplyDelivery?, localProblem: String? = nil,
                       changedAt: Date?, now: Date) -> ReceiptThread {
        let since = changedAt.map { max(0, now.timeIntervalSince($0)) } ?? .infinity
        if let why = localProblem { return failed(why, since: since) }
        if let p = pending, case .arming(let progress) = p.phase(now: now) {
            return ReceiptThread(stage: .arming, arm: progress, word: "arm", moving: true)
        }
        switch delivery {
        case nil:
            guard let p = pending else { return ReceiptThread(stage: .idle) }
            // Fired, and the request has not been answered yet. An approve
            // behind biometrics sent the moment it passed; anything else sent
            // when its arm ran out.
            let biometric = ActionGate.requiresBiometrics(kind: p.kind, commit: p.commit)
            let start = biometric ? p.startedAt : p.startedAt.addingTimeInterval(ArmSpec.duration)
            return sending(since: max(0, now.timeIntervalSince(start)))
        case .sending?:
            return sending(since: since)
        case .sent(let queued, let at)?:
            if queued { return ReceiptThread(stage: .queued, arm: 1, reach: 0.5, relayLit: true, word: "queued · Mac offline") }
            let waited = max(0, now.timeIntervalSince(at))
            let moving = waited < glintFor
            let glint = moving ? 0.5 + 0.5 * (waited / glintPeriod).truncatingRemainder(dividingBy: 1) : nil
            return ReceiptThread(stage: .sent, arm: 1, reach: 0.5, glint: glint, relayLit: true,
                                 word: waited > ReplyConfirmation.slowAfter ? "sent · waiting for your Mac" : "sent", moving: moving)
        case .delivered?:
            return resolved(since: since)
        case .failed(let why)?:
            return failed(why.isEmpty ? "Couldn't deliver the reply" : why, since: since)
        case .alreadyReplied?:
            return failed("Already answered at the Mac", since: since)
        case .gone?:
            return failed("Prompt closed before your answer", since: since)
        }
    }

    static func sending(since t: TimeInterval) -> ReceiptThread {
        // It reaches towards the relay but never touches it until the relay answers.
        let r = 0.42 * MotionCurve.easeOut(t / reachRelay)
        return ReceiptThread(stage: .sending, arm: 1, reach: r, word: "sending", moving: t < reachRelay)
    }

    /// RESOLVE, `t` seconds after the Mac's confirmation reached the phone. Pure.
    static func resolved(since t: TimeInterval) -> ReceiptThread {
        let reach = 0.5 + 0.5 * MotionCurve.easeOut(t / reachMac)
        let teal = MotionCurve.smooth(MotionCurve.progress(t, from: verifiedAt, to: contracted))
        let fold = MotionCurve.smooth(MotionCurve.progress(t, from: contracted, to: folded))
        let drift = MotionCurve.easeIn(MotionCurve.progress(t, from: 1.15, to: resolveDuration))
        let verified = t >= verifiedAt
        return ReceiptThread(stage: verified ? .verified : .typed, arm: 1, reach: reach, relayLit: true, macLit: t >= reachMac,
                             dotTeal: teal, rings: 1 - teal, fold: fold, drift: drift,
                             word: verified ? "verified ✓" : "typed", moving: t < resolveDuration)
    }

    /// FAILURE, `t` seconds after it was reported. Pure.
    static func failed(_ why: String, since t: TimeInterval) -> ReceiptThread {
        let reach = 0.5 * (1 - MotionCurve.easeIn(t / snapBack))
        return ReceiptThread(stage: .failed(why), arm: 0, reach: reach, shake: MotionCurve.shake(t, duration: shakeDuration),
                             word: why, moving: t < max(snapBack, shakeDuration))
    }

    var isSuccess: Bool { stage == .typed || stage == .verified }
    var isFailure: Bool { if case .failed = stage { return true } else { return false } }
}

/// Everything a card's thread is drawn from, so a view can re-derive the
/// frame on its own clock while something moves.
struct ReceiptThreadInput: Equatable {
    var pending: PendingAction?
    var delivery: ReplyDelivery?
    var localProblem: String? = nil
    /// When the delivery last changed on this phone (`APIClient.deliveryTimes`).
    var changedAt: Date? = nil

    /// Nothing to draw: no action under way and no delivery news.
    var isEmpty: Bool { pending == nil && delivery == nil && localProblem == nil }

    func frame(now: Date) -> ReceiptThread {
        ReceiptThread.derive(pending: pending, delivery: delivery, localProblem: localProblem, changedAt: changedAt, now: now)
    }

    /// Until when the thread keeps moving (a view runs a clock until then and
    /// no longer); nil or a past date when it is still. Pure.
    func movingUntil(now: Date) -> Date? {
        let T = ReceiptThread.self
        if localProblem != nil { return changedAt?.addingTimeInterval(max(T.snapBack, T.shakeDuration)) }
        if let p = pending, case .arming = p.phase(now: now) { return p.startedAt.addingTimeInterval(ArmSpec.duration) }
        switch delivery {
        case nil:
            guard let p = pending else { return nil }
            let biometric = ActionGate.requiresBiometrics(kind: p.kind, commit: p.commit)
            return (biometric ? p.startedAt : p.startedAt.addingTimeInterval(ArmSpec.duration)).addingTimeInterval(T.reachRelay)
        case .sending?: return changedAt?.addingTimeInterval(T.reachRelay)
        case .sent(let queued, let at)?: return queued ? nil : at.addingTimeInterval(T.glintFor)
        case .delivered?: return changedAt?.addingTimeInterval(T.resolveDuration)
        case .failed?, .alreadyReplied?, .gone?: return changedAt?.addingTimeInterval(max(T.snapBack, T.shakeDuration))
        }
    }
}

/// A card whose reply the Mac just confirmed leaves the inbox at the same
/// moment (the page closes as "replied"), which would cut the RESOLVE short.
/// Such a row stays in the stream as a ghost, in its old place, for the
/// length of the resolve, then goes. Pure.
enum DepartingRows {
    /// `previous` is the stream as last drawn; `current` the fresh one. A row
    /// that left with a confirmed delivery changed less than
    /// `ReceiptThread.resolveDuration` ago comes back at its old index.
    /// Returns the rows to draw and the ids that are ghosts.
    static func merge(previous: [NowRow], current: [NowRow], deliveries: [String: ReplyDelivery],
                      changedAt: [String: Date], now: Date) -> (rows: [NowRow], ghosts: Set<String>) {
        let live = Set(current.map(\.id))
        var rows = current
        var ghosts = Set<String>()
        for (index, row) in previous.enumerated() where !live.contains(row.id) {
            guard case .delivered? = deliveries[row.id], let at = changedAt[row.id] else { continue }
            let age = now.timeIntervalSince(at)
            guard age >= 0, age < ReceiptThread.resolveDuration else { continue }
            rows.insert(row, at: min(index, rows.count))
            ghosts.insert(row.id)
        }
        return (rows, ghosts)
    }

    /// When the next ghost expires, for a timer: nil with none. Pure.
    static func nextExpiry(ghosts: Set<String>, changedAt: [String: Date]) -> Date? {
        ghosts.compactMap { changedAt[$0]?.addingTimeInterval(ReceiptThread.resolveDuration) }.min()
    }
}
