import Foundation

// What a Decision sheet shows for one page, as pure values: the ask, the
// reversibility reasons, the delivery preview, and the notes the trust model
// requires (a prompt option Page never offers; a prompt Page cannot read).
// Built from the page, its row and its live session; the sheet only draws it.

/// One option the prompt itself lists, read out of the page's text. Page never
/// sends a digit for these: Approve types 1 and nothing else does. An option
/// that would change what the agent may do from now on is shown, not offered.
struct PromptOption: Equatable, Identifiable {
    let number: Int
    let text: String
    /// "Yes, and don't ask again", "Yes, allow all edits during this session".
    let isStanding: Bool
    var id: Int { number }

    /// What the sheet says in place of an action for a standing option.
    var instead: String? { isStanding ? DeliveryPreview.openInTerminal : nil }

    /// Reads "1. Yes", "2) Yes, and don't ask again" style lines. Pure.
    static func parse(_ context: String) -> [PromptOption] {
        var out: [PromptOption] = []
        for raw in context.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let stripped = line.hasPrefix("❯") ? String(line.dropFirst()).trimmingCharacters(in: .whitespaces) : line
            guard let r = stripped.range(of: #"^(\d{1,2})[.)]\s+(.+)$"#, options: .regularExpression) else { continue }
            let body = String(stripped[r])
            let digits = body.prefix { $0.isNumber }
            guard let n = Int(digits) else { continue }
            let text = String(body.dropFirst(digits.count + 1)).trimmingCharacters(in: .whitespaces)
            out.append(PromptOption(number: n, text: text, isStanding: DeliveryPreview.isStandingPermissionOption(text)))
        }
        // A real option list counts up from 1.
        return out.enumerated().allSatisfy { $0.element.number == $0.offset + 1 } ? out : []
    }
}

struct DecisionContent: Equatable {
    enum AskKind: Equatable { case command, edit, plan, question, note }

    let id: String
    let sessionId: String
    let chip: ChipKind
    let section: NowRow.Section
    let project: String
    let agent: String
    /// "cmux › page", when known.
    let route: String?
    let headline: String
    /// One line above the ask ("Claude wants to do this. It can't be undone from your phone.").
    let blurb: String?
    let askKind: AskKind
    /// The command, the file, the plan or the question, in full.
    let ask: String
    /// Smaller text under the ask: the working directory, the reason.
    let detail: String?
    /// "~/projects/page".
    let cwd: String?
    /// The Mac's turn-summary line ("Changed 3 files (+120 −14) · tests passed") on a finished page.
    let turnSummary: String?
    /// Reversibility tags and the reason, with what undo would look like.
    let tags: [Reversibility.Tag]
    let reason: String
    let undoNote: String?
    let options: [PromptOption]
    /// "Couldn't tell what's on screen · Open on Mac" when Page can't read this agent's prompt.
    let screenNote: String?
    /// A v1 hook can only apply Approve or Deny.
    let decisionsOnly: Bool
    let isHook: Bool
    /// Under the actions: where Page types, or who gets the answer.
    let footer: String
    /// Everything the page said, for Copy.
    let rawContext: String
    /// The page is a forecast or a battery pause: nothing to answer.
    let informational: String?
    let stoppable: Bool
    let canTell: Bool
    /// A finished turn's last message ends on a plain yes/no question (`YesNoQuestion`): the sheet offers Yes and No.
    var yesNo: String? = nil

    /// What undoing would look like, per class. A hint, never a "safe" badge. Pure.
    static func undoNote(level: Reversibility?, tags: [Reversibility.Tag]) -> String? {
        guard let level else { return nil }
        switch level {
        case .undoable: return "Read-only, or easy to take back."
        case .considered:
            return tags.contains(.networkOutside) ? "Reaches outside the project. Check where." : "Changes files in your project. git can usually recover them."
        case .irreversible: return "No undo from your phone."
        }
    }

    static func build(iv: Intervention, row: NowRow, session: LiveSession?, macName: String) -> DecisionContent {
        let lines = iv.context.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let first = lines.first ?? ""
        let backendLabel = iv.backend?.displayName ?? (iv.hasUnknownBackend ? (iv.backendRaw ?? "Agent") : "Claude")
        let mac = DeliveryPreview.macLabel(macName)

        var kind = AskKind.note
        var ask = row.summary
        var detail: String? = nil
        var blurb: String? = nil
        var summary: String? = nil
        var yesNo: String? = nil
        switch iv.kind {
        case .approval:
            if iv.subtype == "plan" { kind = .plan; ask = iv.context.isEmpty ? "Plan ready for review" : iv.context }
            else if first.hasPrefix("[Bash]") {
                kind = .command
                ask = String(first.dropFirst("[Bash]".count)).trimmingCharacters(in: .whitespaces)
                if lines.count > 1 { detail = lines[1] }
            } else if first.hasPrefix("[Edit]") || first.hasPrefix("[Write]") || first.hasPrefix("[MultiEdit]") {
                kind = .edit
                ask = NowRowBuilder.stripTool(first)
            } else if first.hasPrefix("One of these is waiting") {
                kind = .command
                ask = lines.dropFirst().map { $0.hasPrefix("•") ? String($0.dropFirst()).trimmingCharacters(in: .whitespaces) : $0 }.joined(separator: "\n")
            } else {
                kind = .note
                ask = iv.context.isEmpty ? "\(backendLabel) is waiting for your approval" : iv.context
            }
            if row.chip == .irreversible { blurb = "\(backendLabel) wants to do this. It can't be undone from your phone." }
        case .userInput:
            kind = .question
            ask = iv.context.isEmpty ? "\(backendLabel) needs your input" : iv.context
        case .idle:
            let parts = TurnSummaryLine.split(iv.context)
            summary = parts.summary
            if row.section == .review { yesNo = YesNoQuestion.detect(parts.rest) }
            ask = row.section == .review ? (parts.rest.isEmpty ? (summary ?? "Finished a turn") : parts.rest.trimmingCharacters(in: .whitespacesAndNewlines)) : (iv.context.isEmpty ? row.summary : iv.context)
        case .rateLimit:
            ask = iv.context.isEmpty ? row.summary : iv.context
        }

        let isInfo: String?
        switch (iv.kind, iv.subtype) {
        case (.rateLimit, "battery_forecast"?): isInfo = "Nothing to answer. Plug your Mac in to keep the agents going."
        case (.rateLimit, "usage_forecast"?): isInfo = "Nothing to answer. Page keeps the Mac awake through the reset and can resume sessions when it resets."
        case (.rateLimit, _) where iv.backend == .codex: isInfo = "Nothing to answer. Codex picks up again once the limit resets."
        case (.idle, "low_battery"?): isInfo = "Page paused your agents at the battery cutoff. Plug the Mac in and they resume."
        default: isInfo = nil
        }

        let cwd = iv.cwd.isEmpty ? nil : PathDisplay.abbreviatingHome(iv.cwd)
        let footer: String
        if iv.isBlockingHook {
            footer = "Your answer goes straight to \(backendLabel)'s permission hook in session \(iv.sessionId.prefix(8)) on \(mac)."
        } else {
            var where_ = "session \(iv.sessionId.prefix(8))"
            if let source = iv.source, source != .unknown { where_ += " (\(source.label))" }
            footer = "Page types your reply into \(where_) on \(mac)."
        }
        let level = row.reversibility
        let unknownAgent = iv.hasUnknownBackend || (session.map { if case .other = $0.backend { return true } else { return false } } ?? false)
        return DecisionContent(
            id: iv.id, sessionId: iv.sessionId, chip: row.chip, section: row.section, project: iv.projectName, agent: backendLabel,
            route: DeliveryPreview.route(host: session?.host, project: session?.title ?? iv.projectName),
            headline: row.headline, blurb: blurb, askKind: kind, ask: ask, detail: detail, cwd: cwd, turnSummary: summary,
            tags: row.tags, reason: row.reason, undoNote: undoNote(level: level, tags: row.tags),
            options: iv.kind == .approval ? PromptOption.parse(iv.context) : [],
            screenNote: unknownAgent ? DeliveryPreview.unreadableNote : nil,
            decisionsOnly: iv.acceptsDecisionsOnly, isHook: iv.isBlockingHook, footer: footer, rawContext: iv.context,
            informational: isInfo, stoppable: PageSubtype.canStop(iv.subtype), canTell: !iv.acceptsDecisionsOnly, yesNo: yesNo)
    }
}
