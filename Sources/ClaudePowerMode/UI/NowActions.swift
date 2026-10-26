import Foundation

// The pure rules behind the panel's actions: which pages the Mac may answer,
// what a delivery result means, what each key does, and how a press-and-hold
// fills. No clock, I/O or AppKit in here; the store and controller supply
// those. Keystroke truth is unchanged: approve types 1, deny presses Esc, a
// written reply is Esc then text then Return, and nothing here can send "2".

// MARK: - What the Mac may answer

enum MacReplyGate {
    /// Pure. Why a reply typed at the Mac must not go to this page, or nil.
    /// The same pages the phone's replies are refused for (`Coordinator.route`),
    /// plus the actions Page never sends: only approve, deny and a written
    /// reply exist.
    static func refusal(forPageId id: String, action: String) -> String? {
        guard ["approve", "deny", "custom"].contains(action) else {
            return "Page only sends approve, deny or a written reply"
        }
        if id.hasPrefix("hookpre-") {
            return "Page's phone-approval hook is handling this prompt — answer it at the Mac"
        }
        if BatteryForecast.isPageId(id) || UsageForecast.isPageId(id) || BatteryPolicy.isLowBatteryPageId(id)
            || id.hasPrefix("ratelimit-") {
            return "Nothing to answer here"
        }
        return nil
    }

    /// Pure. Pages the panel shows keys for.
    static func isAnswerable(pageId id: String) -> Bool {
        refusal(forPageId: id, action: "approve") == nil
    }
}

// MARK: - Delivery results

enum ReplyOutcomeMapper {
    /// Pure. Maps a backend's delivery result to the receipt's outcome, in the
    /// trust model's words. Anything unrecognised keeps the backend's own
    /// sentence rather than a guess.
    static func outcome(for f: ReplyFinished) -> DeliveryReceipt.Outcome {
        if f.method == "timeout" { return .timedOut }
        let d = f.detail.lowercased()
        if f.success { return d.contains("queued") ? .queued : .delivered }

        if d.contains("session ended") || d.contains("session has ended") || d.contains("the session exited") {
            return .sessionEnded
        }
        // "The prompt is no longer showing", "That page already closed…": answered already.
        if d.contains("no longer showing") || d.contains("page already closed") { return .answeredAtMac }
        if d.contains("prompt closed") || d.contains("digit") { return .promptClosed }
        // A newer prompt, or one Page cannot identify: look again.
        if d.contains("newer one is waiting") || d.contains("open the new page") || d.contains("can't confirm which prompt")
            || d.contains("couldn't confirm") || d.contains("can't see which question") {
            return .unknownState
        }
        if d.contains("can type into") || d.contains("can't type") || d.contains("can't press esc")
            || d.contains("couldn't find the session's terminal") || d.contains("suspended or in the background")
            || d.contains("more than one terminal") || d.contains("allow page to control")
            || d.contains("isn't running in a terminal") || d.contains("background job")
            || d.contains("answer it at the mac") || d.contains("answer at the mac") || d.contains("reply at the mac") {
            return .notTypable
        }
        return .other(f.detail.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

enum ReceiptFactory {
    /// Pure. "approve" / "deny" / "custom" → the receipt's verb.
    static func verb(forAction action: String) -> DeliveryReceipt.Verb {
        switch action {
        case "approve": return .approved
        case "deny": return .denied
        default: return .replied
        }
    }

    /// Pure. The receipt for a delivery: what was answered, where it went, and
    /// whether it was confirmed.
    static func receipt(action: String, row: DecideRow, route: String?, finished: ReplyFinished, at: Date) -> DeliveryReceipt {
        DeliveryReceipt(verb: verb(forAction: action), subject: subject(for: row), route: route ?? row.projectName,
                        at: at, outcome: ReplyOutcomeMapper.outcome(for: finished))
    }

    /// Pure. A short subject: the command or summary, else the session name.
    static func subject(for row: DecideRow) -> String {
        let s = row.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = s.isEmpty ? row.projectName : s
        return text.count <= 48 ? text : String(text.prefix(47)) + "…"
    }
}

// MARK: - Press and hold

/// A press-and-hold with a visible ring: the approve of an Irreversible item
/// (1.2 s), or Stop all (a 0.3 s dead zone, then a fill, 1.5 s in all). Red
/// appears only in the last third of the ring.
struct HoldGesture: Equatable {
    enum Kind: Equatable {
        case approve(rowId: String)
        case stopAll
    }

    let kind: Kind
    let startedAt: Date

    static let approveDuration: TimeInterval = 1.2
    static let stopDeadZone: TimeInterval = 0.3
    static let stopDuration: TimeInterval = 1.5

    var deadZone: TimeInterval { kind == .stopAll ? Self.stopDeadZone : 0 }
    var duration: TimeInterval { kind == .stopAll ? Self.stopDuration : Self.approveDuration }

    /// Pure. 0 through the dead zone, then 0...1 up to the end of the hold.
    func progress(now: Date) -> Double {
        let t = now.timeIntervalSince(startedAt)
        guard t > deadZone, duration > deadZone else { return 0 }
        return min(1, (t - deadZone) / (duration - deadZone))
    }

    func isComplete(now: Date) -> Bool { progress(now: now) >= 1 }

    /// Pure. The last third of the ring is red.
    static func isRed(progress: Double) -> Bool { progress >= 2.0 / 3.0 }
}

enum StopScope {
    /// Pure. What Stop all will do, named before it does it.
    static func describe(working: Int) -> String {
        switch working {
        case ..<1: return "No agents are working"
        case 1: return "Press Esc in 1 busy session"
        default: return "Press Esc in \(working) busy sessions"
        }
    }

    /// Pure. The line after the result: "Stopped 4 agents" comes from the
    /// planner's own detail; an empty detail gets a plain fallback.
    static func resultLine(detail: String, success: Bool) -> String {
        let d = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !d.isEmpty { return d }
        return success ? "Stopped your agents" : "Couldn't stop your agents"
    }
}

// MARK: - Keys

/// One key event, as the panel sees it. Built by the controller from NSEvent.
struct NowKeyPress: Equatable {
    enum Key: Equatable {
        case up, down, ret, esc
        case char(Character)
    }
    enum Phase: Equatable { case down, up }

    var key: Key
    var phase: Phase = .down
    var command = false
    var option = false
    var control = false
    var isRepeat = false

    var hasModifiers: Bool { command || option || control }
}

/// The panel's keyboard state.
struct NowPanelState: Equatable {
    struct Composer: Equatable {
        let rowId: String
        var text: String = ""
    }

    /// The row the keys act on. nil: nothing selected, so Esc closes the panel
    /// and 1, Return and the rest do nothing.
    var selectedId: String?
    /// All rows shown (otherwise the first `NowModel.visibleRows`).
    var expanded = false
    var composer: Composer?
    var hold: HoldGesture?
}

/// What the controller should do after a key.
enum NowEffect: Equatable {
    case none
    case close
    /// Type option 1.
    case approve(rowId: String)
    /// A finished hold on an Irreversible item: authenticate, then type 1.
    case approveAfterAuth(rowId: String)
    /// Press Esc.
    case deny(rowId: String)
    /// Focus the exact terminal pane; types nothing.
    case openTerminal(rowId: String)
    /// Esc, then `text`, then Return.
    case send(rowId: String, text: String)
    case newSession
    /// ⌘, : Preferences (the Tower).
    case preferences
    /// M: the classic menu (Pair phone, Open Log, Reload Config, Quit …).
    case more
    /// A finished Stop-all hold.
    case stopAll
}

enum NowKeys {
    /// Pure. The selection after the rows change: kept by id, and dropped (never
    /// moved to a neighbour) when its row is gone, so a key can never act on a
    /// row the person did not choose. An open composer for a vanished row closes.
    static func reconcile(_ state: NowPanelState, rows: [DecideRow]) -> NowPanelState {
        var s = state
        let ids = Set(rows.map(\.id))
        if let id = s.selectedId, !ids.contains(id) { s.selectedId = nil }
        if let c = s.composer, !ids.contains(c.rowId) { s.composer = nil }
        if let h = s.hold, case .approve(let id) = h.kind, !ids.contains(id) { s.hold = nil }
        if rows.count <= NowModel.visibleRows { s.expanded = false }
        return s
    }

    /// Pure. A key against the panel's state and the current rows.
    static func handle(_ press: NowKeyPress, state: NowPanelState, rows: [DecideRow],
                       now: Date) -> (state: NowPanelState, effect: NowEffect) {
        var s = reconcile(state, rows: rows)
        let selected = s.selectedId.flatMap { id in rows.first { $0.id == id } }

        // Releasing the key (or Command) ends a hold that has not filled.
        if press.phase == .up {
            if let h = s.hold {
                switch (h.kind, press.key) {
                case (.stopAll, .char(".")), (.approve, .char("1")): s.hold = nil
                default: break
                }
            }
            return (s, .none)
        }

        // Command combinations work with or without a composer open.
        if press.command {
            switch press.key {
            case .char("n"):
                return (s, press.isRepeat ? .none : .newSession)
            case .char(","):
                return (s, press.isRepeat ? .none : .preferences)
            case .char("."):
                // Never reaches the row keys: Command-period must not read as Esc.
                if !press.isRepeat && s.hold == nil { s.hold = HoldGesture(kind: .stopAll, startedAt: now) }
                return (s, .none)
            default:
                return (s, .none)
            }
        }

        // The composer owns the keyboard: a typed "1" is text, not an approval.
        if let c = s.composer {
            switch press.key {
            case .esc:
                s.composer = nil
                return (s, .none)
            case .ret:
                let text = c.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, !press.isRepeat else { return (s, .none) }
                s.composer = nil
                s.selectedId = nil
                return (s, .send(rowId: c.rowId, text: text))
            default:
                return (s, .none)
            }
        }
        if press.hasModifiers { return (s, .none) }

        switch press.key {
        case .up, .down:
            // Moving cancels a hold: it was for the row you left.
            s.hold = nil
            let ids = rows.map(\.id)
            guard !ids.isEmpty else { return (s, .none) }
            let current = s.selectedId.flatMap { ids.firstIndex(of: $0) }
            let next: Int
            switch (press.key, current) {
            case (.down, nil): next = 0
            case (.up, nil): next = ids.count - 1
            case (.down, let i?): next = min(ids.count - 1, i + 1)
            case (_, let i?): next = max(0, i - 1)
            default: next = 0
            }
            s.selectedId = ids[next]
            // Reaching a row past the compact list opens the rest.
            if next >= NowModel.visibleRows { s.expanded = true }
            return (s, .none)

        case .esc:
            if s.hold != nil { s.hold = nil; return (s, .none) }
            guard let row = selected else { return (s, .close) }
            if row.keys.contains(where: { $0.action == .deny }) || row.moreKeys.contains(where: { $0.action == .deny }) {
                s.selectedId = nil
                return (s, press.isRepeat ? .none : .deny(rowId: row.id))
            }
            // Nothing to deny on this row (stuck, rate limit, finished): Esc lets go of it.
            s.selectedId = nil
            return (s, .none)

        case .ret:
            guard let row = selected, !press.isRepeat else { return (s, .none) }
            switch row.returnAction {
            case .approve?:
                s.selectedId = nil
                return (s, .approve(rowId: row.id))
            case .openTerminal?:
                return (s, .openTerminal(rowId: row.id))
            default:
                return (s, .none)
            }

        case .char(let raw):
            // Not tied to a row, so the footer's menu is reachable from the keyboard.
            if raw.lowercased() == "m" { return (s, press.isRepeat ? .none : .more) }
            guard let c = raw.lowercased().first, let row = selected else { return (s, .none) }
            let all = row.keys + row.moreKeys
            switch c {
            case "1":
                guard !press.isRepeat else { return (s, .none) }
                if row.keys.contains(where: { $0.action == .approveHold }) {
                    if s.hold == nil { s.hold = HoldGesture(kind: .approve(rowId: row.id), startedAt: now) }
                    return (s, .none)
                }
                if all.contains(where: { $0.action == .approve }) && row.reversibility != .irreversible {
                    s.selectedId = nil
                    return (s, .approve(rowId: row.id))
                }
                return (s, .none)
            case "t":
                guard all.contains(where: { $0.action == .tellInstead }) else { return (s, .none) }
                s.composer = NowPanelState.Composer(rowId: row.id)
                return (s, .none)
            case "o":
                guard all.contains(where: { $0.action == .openTerminal }) else { return (s, .none) }
                return (s, press.isRepeat ? .none : .openTerminal(rowId: row.id))
            default:
                return (s, .none)
            }
        }
    }

    /// Pure. A hold that has filled turns into its effect (and ends); one that
    /// has not is left running.
    static func tick(state: NowPanelState, now: Date) -> (state: NowPanelState, effect: NowEffect) {
        guard let h = state.hold, h.isComplete(now: now) else { return (state, .none) }
        var s = state
        s.hold = nil
        switch h.kind {
        case .stopAll: return (s, .stopAll)
        case .approve(let id):
            s.selectedId = nil
            return (s, .approveAfterAuth(rowId: id))
        }
    }

    /// Pure. A row's key by action, for a click on a key cap (same checks as
    /// the keyboard: a cap the row does not offer does nothing).
    static func effect(forClickOn action: KeyHint.Action, row: DecideRow) -> NowEffect {
        let all = row.keys + row.moreKeys
        guard all.contains(where: { $0.action == action }) else { return .none }
        switch action {
        case .approve: return .approve(rowId: row.id)
        case .approveHold: return .none   // a click is not a hold
        case .deny: return .deny(rowId: row.id)
        case .openTerminal: return .openTerminal(rowId: row.id)
        case .tellInstead: return .none   // opens the composer; the store handles it
        }
    }
}

// MARK: - Dusk: did the agent write its summary?

enum PauseEvidence {
    /// Pure. True when `transcriptTail` (JSONL, the end of a session's
    /// transcript) holds an assistant record written after `pausedAt`. That is
    /// the "summary" Page asked for when it paused the agent; without that
    /// record the panel says "asked to summarise", never a check mark.
    static func hasSummary(transcriptTail: String, after pausedAt: Date) -> Bool {
        for line in transcriptTail.split(separator: "\n").reversed() {
            guard line.contains("\"assistant\""),
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["type"] as? String) == "assistant" || (obj["message"] as? [String: Any])?["role"] as? String == "assistant",
                  let stamp = obj["timestamp"] as? String,
                  let at = TranscriptParser.parseISODate(stamp) else { continue }
            if at > pausedAt { return true }
        }
        return false
    }
}
