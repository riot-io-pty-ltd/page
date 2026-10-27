import Foundation
import Combine

/// A button on the panel that is not a row key.
enum NowCommand: Equatable {
    case resumePaused
    case newSession
    case preferences
    case more
    case openConfig
}

/// What the panel shows besides the model: the keyboard state, a hold in
/// progress, rows being answered, and the short line after an action. Views
/// read it; keys and clicks go through `handle` / `click` / `beginHold`, and
/// the effects they produce leave through `perform` — the store holds no
/// reference to the Coordinator, a terminal or the window, so the render
/// harness builds it with plain values.
final class NowStore: ObservableObject {
    struct Notice: Equatable {
        let text: String
        let failed: Bool
    }

    @Published var model: NowModel
    @Published private(set) var state = NowPanelState()
    /// 0...1 fill of the hold in progress (0 through its dead zone).
    @Published private(set) var holdProgress: Double = 0
    /// Rows whose reply is on its way (dimmed; their keys do nothing).
    @Published private(set) var sending: Set<String> = []
    /// The latest result of an action that has no receipt (Stop all, O).
    @Published var notice: Notice? {
        didSet {
            // A result line fades after a while; a newer one replaces it first.
            guard let n = notice else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                if self?.notice == n { self?.notice = nil }
            }
        }
    }
    /// What Stop all would do, named while the hold fills.
    @Published var stopScope: String = ""
    @Published var composerFocusToken = 0
    /// When each signature motion started (arrivals, receipt threads, the
    /// exhale, dusk, dawn, the hold's unwind and burst). Views turn these into
    /// frames with the pure models in SignatureMotion.swift.
    @Published private(set) var motion = NowMotion()
    /// What the list draws: the model's rows in an order that holds still under
    /// the pointer, plus the rows still folding away after a verified answer.
    @Published private(set) var shownRows: [DecideRow] = []
    /// Arrivals waiting behind the "New ↑" pill while the order is held.
    @Published private(set) var queuedNew = 0

    var perform: (NowEffect) -> Void = { _ in }
    var command: (NowCommand) -> Void = { _ in }
    var now: () -> Date = Date.init
    /// A hold crossed one of its ticks (25, 50, 75 %, full): the panel plays a
    /// haptic on a Force Touch trackpad.
    var haptic: (Double) -> Void = { _ in }
    /// The panel is on screen: arrivals, the exhale, dusk and dawn only play then.
    var animates = false
    /// The pointer is over the list: nothing re-sorts under it.
    var pointerInList = false {
        didSet { if pointerInList != oldValue { refreshShown() } }
    }

    private var timer: Timer?
    /// Row ids already on screen (or seen while the panel was closed), so only
    /// genuinely new ones fly in.
    private var knownIds: Set<String> = []
    /// The ids in the order last drawn.
    private var shownIds: [String] = []
    /// The paused agents, kept through dusk so dawn can relight their stars.
    private var lastPaused: [NowModel.PausedAgent] = []

    init(model: NowModel) {
        self.model = model
        shownRows = model.rows
        shownIds = model.rows.map(\.id)
        knownIds = Set(shownIds)
        if model.mood == .dusk { lastPaused = model.paused }
    }

    deinit { timer?.invalidate() }

    // MARK: model

    /// A new model after a snapshot. The selection stays by id, and is dropped
    /// when its row has gone.
    func update(_ model: NowModel) {
        let old = self.model
        if self.model != model { self.model = model }
        let reconciled = NowKeys.reconcile(state, rows: model.rows)
        if reconciled != state { state = reconciled }
        let still = sending.intersection(Set(model.rows.map(\.id)))
        if still != sending { sending = still }
        noteMotion(from: old, to: model)
        pruneSettledThreads()
        refreshShown()
    }

    var selectedId: String? { state.selectedId }
    var expanded: Bool { state.expanded }
    var composer: NowPanelState.Composer? { state.composer }
    var hold: HoldGesture? { state.hold }

    /// Rows the keys may act on: the ones drawn, not ones held behind the pill,
    /// folding away, or already being answered.
    private var keyRows: [DecideRow] {
        let live = Set(model.rows.map(\.id))
        return shownRows.filter { live.contains($0.id) && !sending.contains($0.id) }
    }

    // MARK: keys and clicks

    /// Feeds a key; true when the panel consumed it.
    @discardableResult
    func handle(_ press: NowKeyPress) -> Bool {
        let before = state
        let r = NowKeys.handle(press, state: state, rows: keyRows, now: now())
        apply(r.state, effect: r.effect)
        if press.phase == .up { return before.hold != nil }
        // ⌘N, ⌘. and ⌘, are ours; every other ⌘ combination (⌘Q, ⌘C, ⌘V …) goes on to the responders.
        if press.command {
            switch press.key {
            case .char("n"), .char("."), .char(","): return true
            default: return false
            }
        }
        // With the composer open, typing and editing belong to its text field:
        // only Esc, Return and Command combinations are ours.
        if before.composer != nil {
            switch press.key {
            case .esc, .ret: return true
            default: return false
            }
        }
        return true
    }

    func select(_ id: String) {
        guard model.rows.contains(where: { $0.id == id }), state.composer == nil else { return }
        var s = state
        s.selectedId = id
        s.hold = nil
        state = s
    }

    func setExpanded(_ on: Bool) {
        var s = state
        s.expanded = on
        state = s
    }

    /// A click on one of a row's key caps. A cap that types (1, Return, Esc)
    /// first selects its row, which shows what will be typed and where; it
    /// acts on the next click. T and O type nothing and act at once.
    func click(_ action: KeyHint.Action, on row: DecideRow) {
        // Not a row already answered, nor one still folding away after its page closed.
        guard !sending.contains(row.id), model.rows.contains(where: { $0.id == row.id }) else { return }
        let wasSelected = state.selectedId == row.id
        select(row.id)
        if !wasSelected, action == .approve || action == .deny { return }
        if action == .tellInstead {
            guard (row.keys + row.moreKeys).contains(where: { $0.action == .tellInstead }) else { return }
            var s = state
            s.composer = NowPanelState.Composer(rowId: row.id)
            state = s
            composerFocusToken += 1
            return
        }
        let effect = NowKeys.effect(forClickOn: action, row: row)
        if effect != .none { apply(state, effect: effect) }
    }

    var composerText: String {
        get { state.composer?.text ?? "" }
        set {
            guard var c = state.composer else { return }
            c.text = newValue
            var s = state
            s.composer = c
            state = s
        }
    }

    func cancelComposer() {
        var s = state
        s.composer = nil
        state = s
    }

    func submitComposer() {
        handle(NowKeyPress(key: .ret))
    }

    /// The panel closed (or is opening): nothing stays selected, held or
    /// half-typed, and nothing mid-motion. What is on screen now counts as seen,
    /// so opening the panel never flies the existing rows in.
    func reset() {
        endHold()
        state = NowPanelState()
        notice = nil
        // Threads still waiting on the Mac stay (the reply is still on its way).
        motion = NowMotion(threads: motion.threads.filter { $0.value.resolvedAt == nil })
        knownIds = Set(model.rows.map(\.id))
        shownIds = []
        pointerInList = false
        refreshShown()
    }

    // MARK: holds

    /// A press with the mouse (the hold-1 cap, the footer's stop). Armed once
    /// per press: moving the pointer while the button is down never starts a
    /// second hold, and a hold that has finished does not restart until the
    /// button has been released.
    private var mouseHoldLatched = false

    func mouseHoldBegan(_ kind: HoldGesture.Kind) {
        guard !mouseHoldLatched else { return }
        mouseHoldLatched = true
        if case .approve(let id) = kind { select(id) }
        beginHold(kind)
    }

    func mouseHoldEnded() {
        mouseHoldLatched = false
        endHold()
    }

    func beginHold(_ kind: HoldGesture.Kind) {
        guard state.hold == nil else { return }
        if case .approve(let id) = kind {
            // Only an Irreversible row that is still there and not already being answered.
            guard !sending.contains(id),
                  let row = model.rows.first(where: { $0.id == id }),
                  row.keys.contains(where: { $0.action == .approveHold }) else { return }
        }
        var s = state
        s.hold = HoldGesture(kind: kind, startedAt: now())
        state = s
        startTicking()
    }

    func endHold() {
        guard state.hold != nil else { return }
        var s = state
        s.hold = nil
        state = s
        stopTicking()
        refreshShown()
    }

    /// Drives the ring while a hold is on.
    func tick() {
        let before = holdProgress
        let r = NowKeys.tick(state: state, now: now())
        if let h = r.state.hold {
            holdProgress = h.progress(now: now())
        } else {
            holdProgress = 0
        }
        // The ticks at 25, 50 and 75 %, and full (the last one as it completes).
        let reached = r.state.hold == nil && r.effect != .none ? 1 : holdProgress
        for t in HoldRingModel.ticksCrossed(from: before, to: reached) { haptic(t) }
        if r.state != state { state = r.state }
        if r.effect != .none { apply(r.state, effect: r.effect) }
        if state.hold == nil { stopTicking() }
    }

    /// For the render harness: shows a hold part-way through without a timer.
    func previewHold(_ kind: HoldGesture.Kind, progress: Double) {
        let h = HoldGesture(kind: kind, startedAt: now())
        let at = h.deadZone + progress * (h.duration - h.deadZone)
        var s = state
        s.hold = HoldGesture(kind: kind, startedAt: now().addingTimeInterval(-at))
        state = s
        holdProgress = progress
        stopScope = StopScope.describe(working: model.stoppableCount)
    }

    /// The hold the timer is driving, for the unwind when it is let go early.
    private var tickingKind: HoldGesture.Kind?

    private func startTicking() {
        stopTicking()
        tickingKind = state.hold?.kind
        motion.unwind = nil
        stopScope = StopScope.describe(working: model.stoppableCount)
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    private func stopTicking() {
        timer?.invalidate()
        timer = nil
        // Let go early: the ring unwinds backwards from where it was (nothing is sent).
        if let kind = tickingKind, holdProgress > 0.001, holdProgress < 1 {
            let u = NowMotion.Unwind(kind: kind, from: holdProgress, at: now())
            motion.unwind = u
            DispatchQueue.main.asyncAfter(deadline: .now() + HoldRingModel.unwindDuration(from: u.from) + 0.05) { [weak self] in
                if self?.motion.unwind == u { self?.motion.unwind = nil }
            }
        }
        tickingKind = nil
        holdProgress = 0
    }

    // MARK: effects

    private func apply(_ new: NowPanelState, effect: NowEffect) {
        let holdChanged = (new.hold == nil) != (state.hold == nil)
        if state.composer == nil && new.composer != nil { composerFocusToken += 1 }
        if new != state { state = new }
        if holdChanged {
            if new.hold != nil { startTicking() } else { stopTicking() }
        }
        switch effect {
        case .none: break
        case .approve(let id), .deny(let id), .approveAfterAuth(let id):
            sending.insert(id)
            beginThread(rowId: id, authenticating: effect == .approveAfterAuth(rowId: id))
            perform(effect)
        case .send(let id, _):
            sending.insert(id)
            beginThread(rowId: id, authenticating: false)
            perform(effect)
        default:
            perform(effect)
        }
    }

    /// The delivery finished (or failed): the row is free again, or gone.
    /// `outcome` is what the Mac confirmed; nil when nothing was sent (Touch ID
    /// refused, the page had gone), which simply drops the thread.
    func finishSending(rowId: String, outcome: DeliveryReceipt.Outcome? = nil) {
        sending.remove(rowId)
        guard var thread = motion.threads[rowId] else { return }
        guard let outcome, thread.sentAt != nil else {
            motion.threads[rowId] = nil
            refreshShown()
            return
        }
        thread.resolvedAt = now()
        thread.resolution = NowMotion.resolution(for: outcome)
        motion.threads[rowId] = thread
        refreshShown()
        let linger: TimeInterval
        switch thread.resolution {
        case .verified?: linger = ReceiptThreadModel.resolveDuration + 0.05
        case .queued?: linger = 30
        default: linger = 4
        }
        let resolvedAt = thread.resolvedAt
        DispatchQueue.main.asyncAfter(deadline: .now() + linger) { [weak self] in
            self?.settleThread(rowId: rowId, resolvedAt: resolvedAt)
        }
    }

    // MARK: signature motions

    /// The reply has been handed to the Mac's reply path: the thread of light
    /// leaves the row. Called right before the delivery starts, so an
    /// Irreversible row only gets here after Touch ID passed (and bursts).
    func markSent(rowId: String) {
        var thread = motion.threads[rowId] ?? NowMotion.Thread(row: model.rows.first { $0.id == rowId }, index: indexShown(rowId))
        if thread.authenticating { motion.burst = NowMotion.Burst(rowId: rowId, at: now()) }
        thread.authenticating = false
        thread.sentAt = now()
        motion.threads[rowId] = thread
    }

    /// Power came back and these sessions' resumes were confirmed: their
    /// stars relight, one by one, in the dawn already rising (or a new one).
    func confirmResumed(sessionIds: [String]) {
        guard !sessionIds.isEmpty else { return }
        var dawn = motion.dawn ?? NowMotion.Dawn(stars: lastPaused, startedAt: now())
        for id in sessionIds where dawn.confirmed[id] == nil { dawn.confirmed[id] = now() }
        motion.dawn = dawn
    }

    /// For the render harness: sets motion state directly. Live, it only
    /// changes through the key handlers, `markSent` / `finishSending`,
    /// `update` and `confirmResumed`.
    func previewMotion(_ edit: (inout NowMotion) -> Void) {
        edit(&motion)
        refreshShown()
    }

    /// The "New ↑" pill: let the held arrivals in now.
    func showNew() {
        refreshShown(release: true)
    }

    /// The order is held still: the pointer is over the list, a hold is on or
    /// the composer is open.
    var orderFrozen: Bool { pointerInList || state.hold != nil || state.composer != nil }

    private func beginThread(rowId: String, authenticating: Bool) {
        guard let row = model.rows.first(where: { $0.id == rowId }) else { return }
        var t = NowMotion.Thread(row: row, index: indexShown(rowId))
        t.authenticating = authenticating
        motion.threads[rowId] = t
    }

    private func indexShown(_ id: String) -> Int {
        shownRows.firstIndex { $0.id == id } ?? model.rows.firstIndex { $0.id == id } ?? 0
    }

    /// A resolved thread has had its time. A failure (or "queued") is dropped.
    /// A verified row has folded away: the gap it leaves closes (the rows below
    /// glide up), and the thread stays, keeping the row hidden, until its page
    /// closes, so it never pops back; if the page is somehow still open after
    /// `settleLimit`, the row is shown again, because it is still waiting.
    private func settleThread(rowId: String, resolvedAt: Date?) {
        guard let t = motion.threads[rowId], t.resolvedAt == resolvedAt else { return }
        guard t.resolution == .verified else {
            motion.threads[rowId] = nil
            refreshShown()
            return
        }
        if let i = shownRows.firstIndex(where: { $0.id == rowId }) {
            let at = now()
            motion.gaps.append(NowMotion.Gap(index: i, rowId: rowId, at: at))
            DispatchQueue.main.asyncAfter(deadline: .now() + NowMotion.gapDuration + 0.05) { [weak self] in
                self?.motion.gaps.removeAll { $0.at == at }
            }
        }
        refreshShown()
        DispatchQueue.main.asyncAfter(deadline: .now() + NowMotion.settleLimit) { [weak self] in
            guard let self, self.motion.threads[rowId]?.resolvedAt == resolvedAt else { return }
            self.motion.threads[rowId] = nil
            self.refreshShown()
        }
    }

    /// Drops verified threads whose page has now closed (their rows are gone for good).
    private func pruneSettledThreads() {
        let live = Set(model.rows.map(\.id))
        let t = now()
        let done = motion.threads.filter { _, th in
            guard th.resolution == .verified, let at = th.resolvedAt else { return false }
            return t.timeIntervalSince(at) >= ReceiptThreadModel.resolveDuration && !live.contains(th.rowId)
        }.map(\.key)
        guard !done.isEmpty else { return }
        for id in done { motion.threads[id] = nil }
    }

    /// Notes what changed between two models while the panel is open: new
    /// rows (Final approach), the last waiting item clearing (the exhale),
    /// the cutoff pausing agents (dusk) and power coming back (dawn).
    private func noteMotion(from old: NowModel, to new: NowModel) {
        let t = now()
        let wasWaiting = old.needYouCount + old.lookCount
        let isWaiting = new.needYouCount + new.lookCount
        if new.mood == .dusk { lastPaused = new.paused }
        guard animates else { return }
        if wasWaiting > 0, isWaiting == 0, new.mood != .dusk {
            motion.clearedAt = t
            // The rings the pulse had out: one per decision (else per look), as it counts them.
            motion.clearedRings = PulseModel.ringCount(waiting: old.needYouCount > 0 ? old.needYouCount : old.lookCount)
        } else if isWaiting > 0, motion.clearedAt != nil {
            motion.clearedAt = nil
        }
        if old.mood != .dusk, new.mood == .dusk {
            motion.duskAt = t
            motion.dawn = nil
        } else if old.mood == .dusk, new.mood != .dusk {
            motion.duskAt = nil
            if motion.dawn == nil { motion.dawn = NowMotion.Dawn(stars: lastPaused, startedAt: t) }
            let started = motion.dawn?.startedAt
            DispatchQueue.main.asyncAfter(deadline: .now() + NowMotion.dawnLimit) { [weak self] in
                if self?.motion.dawn?.startedAt == started { self?.motion.dawn = nil }
            }
        }
    }

    /// Rebuilds `shownRows`: the stable order, the arrivals it lets in (each
    /// one flies from the pulse), rows still folding away, and rows already
    /// verified that the model has not dropped yet (hidden, so they do not
    /// pop back after folding).
    private func refreshShown(release: Bool = false) {
        let t = now()
        let merged = NowStableOrder.merge(shown: shownIds, ranked: model.rows, frozen: orderFrozen && !release)
        var rows = merged.rows
        // Verified and folded, but the page has not closed yet: keep it out.
        rows.removeAll { r in
            guard let th = motion.threads[r.id], th.resolution == .verified, let at = th.resolvedAt else { return false }
            return t.timeIntervalSince(at) >= ReceiptThreadModel.resolveDuration
        }
        // Its page closed while the reply was out: the row stays, as a ghost in
        // its old place, until the Mac has answered and the thread has played
        // (the fold after a verified delivery, the words after a failure).
        let live = Set(rows.map(\.id))
        for th in motion.threads.values.sorted(by: { $0.index < $1.index })
        where th.sentAt != nil && !live.contains(th.rowId) {
            guard let row = th.row, NowMotion.keepsGhost(th, now: t) else { continue }
            rows.insert(row, at: min(th.index, rows.count))
        }
        // Arrivals: rows never seen before, a little apart when several come at once.
        if animates {
            let fresh = rows.filter { !knownIds.contains($0.id) }.map(\.id)
            for (i, id) in fresh.enumerated() { motion.arrivals[id] = t.addingTimeInterval(Double(i) * NowMotion.arrivalStagger) }
            if !fresh.isEmpty {
                let ids = fresh
                DispatchQueue.main.asyncAfter(deadline: .now() + ApproachModel.duration + Double(ids.count) * NowMotion.arrivalStagger + 0.05) { [weak self] in
                    guard let self else { return }
                    for id in ids where (self.motion.arrivals[id].map { self.now().timeIntervalSince($0) >= ApproachModel.duration } ?? false) {
                        self.motion.arrivals[id] = nil
                    }
                }
            }
        }
        knownIds.formUnion(rows.map(\.id))
        shownIds = merged.rows.map(\.id)
        if rows != shownRows { shownRows = rows }
        if merged.queuedNew != queuedNew { queuedNew = merged.queuedNew }
    }
}

/// When each signature motion began, for the views to turn into frames.
struct NowMotion: Equatable {
    /// A reply's receipt thread.
    struct Thread: Equatable {
        /// The row as it was when answered (drawn as a ghost if its page closes first).
        let row: DecideRow?
        var rowId: String { row?.id ?? "" }
        /// Where it was in the list.
        let index: Int
        /// Waiting for Touch ID: nothing has been sent.
        var authenticating = false
        /// Handed to the Mac's reply path.
        var sentAt: Date?
        /// When the Mac answered, and what it said.
        var resolvedAt: Date?
        var resolution: ReceiptThreadModel.Resolution?

        init(row: DecideRow?, index: Int) {
            self.row = row
            self.index = index
        }
    }

    struct Dawn: Equatable {
        /// The agents that were paused: one star each.
        let stars: [NowModel.PausedAgent]
        let startedAt: Date
        /// Session id → when its resume was confirmed.
        var confirmed: [String: Date] = [:]
    }

    /// A hold let go early, unwinding.
    struct Unwind: Equatable {
        let kind: HoldGesture.Kind
        let from: Double
        let at: Date
    }

    /// Touch ID passed for an Irreversible row.
    struct Burst: Equatable {
        let rowId: String
        let at: Date
    }

    /// A folded row has gone: rows from `index` down glide up into its place.
    struct Gap: Equatable {
        let index: Int
        let rowId: String
        let at: Date
    }

    var arrivals: [String: Date] = [:]
    var threads: [String: Thread] = [:]
    var clearedAt: Date?
    var clearedRings = 0
    var duskAt: Date?
    var dawn: Dawn?
    var unwind: Unwind?
    var burst: Burst?
    var gaps: [Gap] = []

    static let arrivalStagger: TimeInterval = 0.09
    /// The longest a verified row stays hidden waiting for its page to close.
    static let settleLimit: TimeInterval = 6
    static let gapDuration: TimeInterval = 0.3
    /// A dawn whose resumes never confirm stops waiting after this.
    static let dawnLimit: TimeInterval = 20

    /// Pure. Whether a thread whose page has closed still shows its row: while
    /// the Mac has not answered, through the fold after a verified delivery,
    /// and for a few seconds of words after anything else.
    static func keepsGhost(_ th: Thread, now: Date) -> Bool {
        guard th.sentAt != nil else { return false }
        guard let at = th.resolvedAt else { return true }
        let e = now.timeIntervalSince(at)
        return th.resolution == .verified ? e < ReceiptThreadModel.resolveDuration : e < ghostWords
    }

    /// How long a closed page's row keeps its failure (or "queued") in words.
    static let ghostWords: TimeInterval = 4

    /// Pure. The Mac's delivery outcome as the thread's resolution: only a
    /// confirmed delivery is verified; queued has not landed yet.
    static func resolution(for outcome: DeliveryReceipt.Outcome) -> ReceiptThreadModel.Resolution {
        switch outcome {
        case .delivered: return .verified
        case .queued: return .queued
        default: return .failed(outcome.failureMessage ?? "Couldn't deliver the reply")
        }
    }
}
