import Foundation

// The Night Watch "Now" stream, row by row: what each page is, how reversible
// answering it is, which actions the phone offers, and the delivery preview
// that names what will be typed, where and on which Mac. Pure and
// Foundation-only (no clock, no services), mirroring the Mac's NowModel
// (Sources/ClaudePowerMode/UI/NowModel.swift) for the phone, so the plain
// swiftc LogicTests cover it and the widget target can compile it.

// MARK: - Chips

/// The label on a row: how reversible a pending action is, or why it is here.
enum ChipKind: String, Equatable, CaseIterable {
    case irreversible, considered, undoable
    case looksStuck, question, forecast, rateLimited, review

    /// All caps, as drawn.
    var title: String {
        switch self {
        case .irreversible: return "IRREVERSIBLE"
        case .considered: return "CONSIDERED"
        case .undoable: return "UNDOABLE"
        case .looksStuck: return "LOOKS STUCK"
        case .question: return "QUESTION"
        case .forecast: return "HEADS UP"
        case .rateLimited: return "RATE LIMITED"
        case .review: return "FINISHED"
        }
    }

    init(_ r: Reversibility) {
        switch r {
        case .undoable: self = .undoable
        case .considered: self = .considered
        case .irreversible: self = .irreversible
        }
    }
}

// MARK: - Reversibility on the phone

/// Which pages get a Reversibility class on the phone, and which class. The
/// phone sees only the page's `context` text (the same text the Mac's
/// classifier reads), so it runs the same classifier; when the text says
/// nothing about the action the answer is `.considered`, never `.undoable`.
enum PhoneReversibility {
    /// nil for pages with nothing to approve (questions, finished turns,
    /// forecasts) and for non-Claude agents, whose prompts are not written in
    /// the `[Tool] input` shape the classifier reads: those are `.considered`
    /// (see `NowRowBuilder`), never guessed at.
    static func verdict(for iv: Intervention) -> Reversibility.Verdict? {
        guard iv.kind == .approval else { return nil }
        if iv.hasUnknownBackend {
            return Reversibility.Verdict(level: .considered, tags: [], reason: DeliveryPreview.unreadableNote)
        }
        guard (iv.backend ?? .claude) == .claude else {
            return Reversibility.Verdict(level: .considered, tags: [], reason: "\(iv.agentName)'s prompt isn't one Page can read")
        }
        if iv.subtype == "plan" {
            return Reversibility.Verdict(level: .considered, tags: [], reason: "plan approval")
        }
        // The page's own (absolute) cwd, not a session's home-abbreviated one.
        return Reversibility.classify(context: iv.context, cwd: iv.cwd.isEmpty ? nil : iv.cwd)
    }
}

// MARK: - Actions and delivery previews

/// How a row's approve is committed: swipe (Undoable), tap (Considered) or
/// press-and-hold plus biometrics (Irreversible).
enum CommitGesture: String, Equatable {
    case swipe, tap, hold

    init(_ r: Reversibility) {
        switch r {
        case .undoable: self = .swipe
        case .considered: self = .tap
        case .irreversible: self = .hold
        }
    }

    /// The hint under the button.
    var hint: String {
        switch self {
        case .swipe: return "swipe to approve"
        case .tap: return "tap to approve"
        case .hold: return "hold to approve"
        }
    }
}

/// One thing the phone can do with a row.
struct RowAction: Equatable, Identifiable {
    enum Kind: String, Equatable {
        /// Approve: option 1, or the hook's allow.
        case approve
        /// Deny: Esc, or the hook's deny.
        case deny
        /// Stop a stuck session: Esc.
        case stop
        /// A written reply. On an open prompt it is Esc, then the text, then Return.
        case tellInstead
        /// "Carry on" on a finished turn.
        case carryOn
        /// Page cannot answer this from the phone.
        case openOnMac
    }

    let kind: Kind
    /// Button text.
    let label: String
    /// "Will type 1 · cmux › page · Studio MBP"; nil when nothing would be sent.
    let preview: String?
    var id: String { kind.rawValue }
}

/// The delivery preview strings. Every one names the Mac, so with several
/// Macs paired you cannot act on the wrong one.
enum DeliveryPreview {
    /// "your Mac" when the name is blank, so a preview never omits the Mac.
    static func macLabel(_ name: String) -> String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "your Mac" : t
    }

    /// "cmux › page": the terminal and the project. nil when neither is known.
    static func route(host: String?, project: String?) -> String? {
        let h = (host ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let hostName = h.isEmpty || h.lowercased() == "unknown" ? nil : h
        let p = (project ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch (hostName, p.isEmpty ? nil : p) {
        case let (h?, p?): return "\(h) › \(p)"
        case let (h?, nil): return h
        case let (nil, p?): return p
        default: return nil
        }
    }

    /// "<action> · <route> · <Mac>".
    static func line(_ action: String, route: String?, mac: String) -> String {
        [action, route, macLabel(mac)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func typeOne(route: String?, mac: String) -> String { line("Will type 1", route: route, mac: mac) }
    static func pressEsc(route: String?, mac: String) -> String { line("Will press Esc", route: route, mac: mac) }
    static func tellInstead(route: String?, mac: String) -> String { line("Esc, then your message", route: route, mac: mac) }
    /// A message to a busy or finished session: queued behind the turn; never Esc or 1.
    static func message(route: String?, mac: String) -> String { line("Your message, then Return", route: route, mac: mac) }
    static func carryOn(route: String?, mac: String) -> String { line("Will type your carry-on message, then Return", route: route, mac: mac) }
    static func cannotType(_ why: String, mac: String) -> String { line("Can't type here · \(why)", route: nil, mac: mac) }

    /// Phone-approval hook pages: nothing is typed, the hook receives the answer.
    static func hookAllow(mac: String) -> String { line("Will allow it through Claude's permission hook", route: nil, mac: mac) }
    static func hookDeny(mac: String) -> String { line("Will deny it through Claude's permission hook", route: nil, mac: mac) }
    static func hookTell(mac: String) -> String { line("Deny, with your message, through the hook", route: nil, mac: mac) }

    /// Codex answers approvals through its own adapter; Page does not type 1.
    static func codexAccept(mac: String) -> String { line("Asks Codex to accept", route: nil, mac: mac) }
    static func codexDecline(mac: String) -> String { line("Asks Codex to decline", route: nil, mac: mac) }

    /// What the one option Page never offers reads as.
    static let openInTerminal = "Open in terminal to choose this"

    /// An agent Page has no adapter for: nothing is typed, and the sheet says so.
    static let unreadableNote = "Couldn't tell what's on screen · Open on Mac"
    /// The same, as an action preview, which always names the Mac.
    static func unreadable(mac: String) -> String { line("Couldn't tell what's on screen", route: nil, mac: mac) }

    /// True for a prompt option such as "Yes, and don't ask again" or
    /// "Yes, allow all edits during this session": options that change what
    /// the agent may do from now on. Page never sends the key for these (and
    /// never sends 2); the phone shows `openInTerminal` instead. Pure.
    static func isStandingPermissionOption(_ text: String) -> Bool {
        let t = text.lowercased()
        let needles = ["don't ask again", "dont ask again", "do not ask again", "don\u{2019}t ask again",
                       "allow all", "always allow", "for this session", "during this session", "and remember",
                       "don't ask me again"]
        return needles.contains { t.contains($0) }
    }
}

// MARK: - Rows

/// One line in the Now stream: something that needs a decision, a look, or a
/// review.
struct NowRow: Equatable, Identifiable {
    enum Section: Int, Equatable, Comparable {
        /// Approvals, plan approvals, questions: the agent is blocked on you.
        case decide = 0
        /// Stuck, rate-limited, battery or usage forecasts.
        case look = 1
        /// A finished turn waiting for you.
        case review = 2
        static func < (a: Section, b: Section) -> Bool { a.rawValue < b.rawValue }

        var title: String {
            switch self {
            case .decide: return "DECIDE"
            case .look: return "LOOK"
            case .review: return "REVIEW"
            }
        }
    }

    let id: String
    let sessionId: String
    let projectName: String
    let agentName: String
    let section: Section
    let chip: ChipKind
    /// Verb-first title: "Delete every Dev build?".
    let headline: String
    /// The command, or a one-line summary: "rm -rf Builds/Dev/*.app".
    let summary: String
    let actions: [RowAction]
    /// How Approve is committed; nil when the row has no approve.
    let commit: CommitGesture?
    /// Return/primary is only ever Approve on an Undoable row.
    let waitingSince: Date
    let reversibility: Reversibility?
    let tags: [Reversibility.Tag]
    let reason: String

    func action(_ kind: RowAction.Kind) -> RowAction? { actions.first { $0.kind == kind } }
    /// The preview shown under the focused row: the approve line, else the
    /// first action that sends something.
    var focusPreview: String? {
        action(.approve)?.preview ?? actions.compactMap(\.preview).first
    }
}

enum NowRowBuilder {
    /// Which section a page belongs to; nil for pages that are not rows.
    static func section(of iv: Intervention) -> NowRow.Section {
        switch iv.kind {
        case .approval, .userInput: return .decide
        case .rateLimit: return .look
        case .idle:
            if PageSubtype.isStuck(iv.subtype) || iv.subtype == "low_battery" { return .look }
            return .review
        }
    }

    /// The row for a page. `session` is the live session behind it, when the
    /// phone has the list: it names the terminal and says whether Page can
    /// type there. `macName` is always shown in previews.
    static func row(for iv: Intervention, session: LiveSession?, macName: String) -> NowRow {
        let mac = DeliveryPreview.macLabel(macName)
        let section = section(of: iv)
        let backend = iv.backend ?? .claude
        let host = session?.host ?? (iv.source.flatMap { $0 == .unknown ? nil : $0.label })
        let route = DeliveryPreview.route(host: host, project: session?.title ?? iv.projectName)
        let blocker: String? = (session.map { !$0.canType } ?? false) ? session?.blockerText : nil
        let hook = iv.isBlockingHook
        // An agent Page has no adapter for (the relay named a backend that
        // is not Claude or Codex, or the live session says so): it never
        // types there, and says what to do instead.
        let unknownAgent = iv.hasUnknownBackend || (session.map { if case .other = $0.backend { return true } else { return false } } ?? false)

        func act(_ k: RowAction.Kind, _ label: String, _ preview: String?) -> RowAction {
            RowAction(kind: k, label: label, preview: preview)
        }
        var chip: ChipKind
        var verdict: Reversibility.Verdict?
        var actions: [RowAction] = []
        var commit: CommitGesture?

        switch iv.kind {
        case .approval:
            let v = PhoneReversibility.verdict(for: iv)
            verdict = v
            let level = v?.level ?? .considered
            chip = ChipKind(level)
            commit = CommitGesture(level)
            let planned = iv.subtype == "plan"
            let approveLabel = planned ? "Approve plan" : "Approve"
            let denyLabel = planned ? "Keep planning" : "Deny"
            if unknownAgent && !hook {
                actions = [act(.openOnMac, "Open on Mac", DeliveryPreview.unreadable(mac: mac))]
                commit = nil
            } else if hook {
                actions = [act(.approve, approveLabel, DeliveryPreview.hookAllow(mac: mac)),
                           act(.deny, denyLabel, DeliveryPreview.hookDeny(mac: mac))]
                if !iv.acceptsDecisionsOnly { actions.append(act(.tellInstead, "Tell it instead…", DeliveryPreview.hookTell(mac: mac))) }
            } else if backend == .codex {
                actions = [act(.approve, approveLabel, DeliveryPreview.codexAccept(mac: mac)),
                           act(.deny, denyLabel, DeliveryPreview.codexDecline(mac: mac))]
            } else if let blocker {
                actions = [act(.openOnMac, "Open on Mac", DeliveryPreview.cannotType(blocker, mac: mac))]
                commit = nil
            } else {
                actions = [act(.approve, approveLabel, DeliveryPreview.typeOne(route: route, mac: mac)),
                           act(.deny, denyLabel, DeliveryPreview.pressEsc(route: route, mac: mac)),
                           act(.tellInstead, "Tell it instead…", DeliveryPreview.tellInstead(route: route, mac: mac))]
            }
        case .userInput:
            chip = .question
            if unknownAgent && !hook {
                actions = [act(.openOnMac, "Open on Mac", DeliveryPreview.unreadable(mac: mac))]
            } else if backend == .claude, blocker == nil || hook {
                // A written answer to a Claude prompt is Esc, then the text, then Return.
                actions = [act(.tellInstead, "Answer", hook ? DeliveryPreview.hookTell(mac: mac) : DeliveryPreview.tellInstead(route: route, mac: mac))]
            } else if let blocker {
                actions = [act(.openOnMac, "Open on Mac", DeliveryPreview.cannotType(blocker, mac: mac))]
            } else {
                actions = [act(.tellInstead, "Answer", DeliveryPreview.line("Your answer, as Codex takes it", route: route, mac: mac))]
            }
        case .idle where PageSubtype.isStuck(iv.subtype):
            chip = .looksStuck
            if unknownAgent {
                actions = [act(.openOnMac, "Open on Mac", DeliveryPreview.unreadable(mac: mac))]
            } else if let blocker {
                actions = [act(.openOnMac, "Open on Mac", DeliveryPreview.cannotType(blocker, mac: mac))]
            } else {
                if PageSubtype.canStop(iv.subtype) {
                    actions.append(act(.stop, "Stop it", DeliveryPreview.pressEsc(route: route, mac: mac)))
                }
                actions.append(act(.tellInstead, "Steer", DeliveryPreview.message(route: route, mac: mac)))
            }
        case .idle where iv.subtype == "low_battery":
            chip = .forecast
            actions = []
        case .idle:
            chip = .review
            if unknownAgent {
                actions = [act(.openOnMac, "Open on Mac", DeliveryPreview.unreadable(mac: mac))]
            } else if let blocker {
                actions = [act(.openOnMac, "Open on Mac", DeliveryPreview.cannotType(blocker, mac: mac))]
            } else {
                actions = [act(.carryOn, "Carry on", DeliveryPreview.carryOn(route: route, mac: mac)),
                           act(.tellInstead, "Steer", DeliveryPreview.message(route: route, mac: mac))]
            }
        case .rateLimit:
            if PageSubtype.isForecast(iv.subtype) {
                chip = .forecast
                actions = []
            } else {
                chip = .rateLimited
                actions = backend == .claude
                    ? [act(.tellInstead, "Send after reset", DeliveryPreview.line("Your message, typed when the limit resets", route: route, mac: mac))]
                    : []
            }
        }

        return NowRow(
            id: iv.id, sessionId: iv.sessionId, projectName: iv.projectName, agentName: iv.agentName,
            section: section, chip: chip, headline: headline(for: iv), summary: summaryLine(for: iv),
            actions: actions, commit: commit, waitingSince: iv.openedAt,
            reversibility: iv.kind == .approval ? (verdict?.level ?? .considered) : nil,
            tags: verdict?.tags ?? [], reason: verdict?.reason ?? "")
    }

    /// Decide rows first, Irreversible before anything else, then the
    /// longest wait first; then Look, then Review, each longest wait first.
    /// (The Mac's ranking; `Intervention.urgencySorted` is untouched.)
    static func ranked(_ rows: [NowRow]) -> [NowRow] {
        rows.sorted { a, b in
            if a.section != b.section { return a.section < b.section }
            // A question has no class; it ranks with the Considered items.
            func rank(_ r: NowRow) -> Int {
                r.reversibility?.rawValue ?? (r.chip == .question ? Reversibility.considered.rawValue : -1)
            }
            if rank(a) != rank(b) { return rank(a) > rank(b) }
            if a.waitingSince != b.waitingSince { return a.waitingSince < b.waitingSince }
            return a.id < b.id
        }
    }

    // MARK: copy

    /// Verb-first title. A Bash approval uses the model's own one-line
    /// description when the page carries one ("Delete every Dev build?").
    static func headline(for iv: Intervention) -> String {
        if iv.kind == .idle, iv.subtype == "low_battery" { return "Paused for battery" }
        // A finished turn waiting for review.
        if iv.kind == .idle, !PageSubtype.isStuck(iv.subtype), iv.subtype != "workflow_stalled" { return "\((iv.backend ?? .claude).displayName) finished a turn" }
        if iv.kind == .approval, iv.subtype != "plan" {
            let lines = iv.context.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if lines.count >= 2, lines[0].hasPrefix("[Bash]") {
                let d = lines[1]
                if d.count <= 60, !d.hasSuffix("?"), let f = d.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(f) {
                    return d.hasSuffix(".") ? String(d.dropLast()) + "?" : d + "?"
                }
            }
        }
        return ReplyCopy.headline(for: iv)
    }

    /// The one line a row shows: the command for a Bash approval, the file
    /// for an edit, "cargo test failed 6×" for a loop, and so on.
    static func summaryLine(for iv: Intervention) -> String {
        let text = iv.context.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let first = lines.first ?? ""

        if let sub = iv.subtype {
            switch sub {
            case "looping":
                // "Looks stuck in a loop: this has failed 6 times.\n<label>"
                let count = first.range(of: #"failed (\d+) times"#, options: .regularExpression)
                    .flatMap { Int(first[$0].filter(\.isNumber)) }
                let label = lines.dropFirst().first
                if let label, let count { return clip("\(label) failed \(count)×") }
                if let label { return clip(label) }
            case "stuck":
                if let r = first.range(of: #"^No progress for \d+ min"#, options: .regularExpression) {
                    return "no progress for" + first[r].dropFirst("No progress for".count)
                }
            case "plan":
                return "plan ready for review"
            default: break
            }
        }
        if iv.kind == .idle || iv.kind == .rateLimit || iv.kind == .userInput { return clip(first.isEmpty ? "waiting for you" : first) }

        if first.hasPrefix("One of these is waiting for approval") {
            let n = text.components(separatedBy: "\n• ").count - 1
            return "\(max(n, 2)) tool calls waiting"
        }
        if first.hasPrefix("Plan ready for review") { return "plan ready for review" }
        if first.hasPrefix("A subagent is asking for approval") {
            return clip(lines.dropFirst().first.map { stripTool($0) } ?? "a subagent is asking")
        }
        if first.hasPrefix("["), first.contains("]") { return clip(stripTool(first)) }
        if first.isEmpty { return "waiting for you" }
        if first == "Claude is waiting for your approval" { return "waiting for your approval" }
        return clip(first)
    }

    /// "[Bash] rm -rf x" becomes "rm -rf x"; "[Edit] a.swift" becomes "edit a.swift".
    static func stripTool(_ line: String) -> String {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return line }
        let name = String(line[line.index(after: line.startIndex)..<close])
        let rest = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        switch name {
        case "Bash": return rest
        case "Edit", "MultiEdit", "NotebookEdit": return "edit \(rest)"
        case "Write": return "write \(rest)"
        case "Read": return "read \(rest)"
        case "WebFetch", "WebSearch": return rest
        default: return "\(name.lowercased()) \(rest)".trimmingCharacters(in: .whitespaces)
        }
    }

    private static func clip(_ s: String, _ limit: Int = 96) -> String {
        s.count <= limit ? s : String(s.prefix(limit - 1)) + "…"
    }
}
