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

    var perform: (NowEffect) -> Void = { _ in }
    var command: (NowCommand) -> Void = { _ in }
    var now: () -> Date = Date.init

    private var timer: Timer?

    init(model: NowModel) {
        self.model = model
    }

    deinit { timer?.invalidate() }

    // MARK: model

    /// A new model after a snapshot. The selection stays by id, and is dropped
    /// when its row has gone.
    func update(_ model: NowModel) {
        if self.model != model { self.model = model }
        let reconciled = NowKeys.reconcile(state, rows: model.rows)
        if reconciled != state { state = reconciled }
        let still = sending.intersection(Set(model.rows.map(\.id)))
        if still != sending { sending = still }
    }

    var selectedId: String? { state.selectedId }
    var expanded: Bool { state.expanded }
    var composer: NowPanelState.Composer? { state.composer }
    var hold: HoldGesture? { state.hold }

    /// Rows the keys may act on: not the ones already being answered.
    private var keyRows: [DecideRow] { model.rows.filter { !sending.contains($0.id) } }

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
        guard !sending.contains(row.id) else { return }
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

    /// The panel closed: nothing stays selected, held or half-typed.
    func reset() {
        endHold()
        state = NowPanelState()
        notice = nil
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
    }

    /// Drives the ring while a hold is on.
    func tick() {
        let r = NowKeys.tick(state: state, now: now())
        if let h = r.state.hold {
            holdProgress = h.progress(now: now())
        } else {
            holdProgress = 0
        }
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

    private func startTicking() {
        stopTicking()
        stopScope = StopScope.describe(working: model.stoppableCount)
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    private func stopTicking() {
        timer?.invalidate()
        timer = nil
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
            perform(effect)
        case .send(let id, _):
            sending.insert(id)
            perform(effect)
        default:
            perform(effect)
        }
    }

    /// The delivery finished (or failed): the row is free again, or gone.
    func finishSending(rowId: String) {
        sending.remove(rowId)
    }
}
