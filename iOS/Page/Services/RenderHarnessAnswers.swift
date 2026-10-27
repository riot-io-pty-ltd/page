import SwiftUI

#if DEBUG

/// Render-harness screens for answering the terminal's questions
/// (Models/QuestionDraft.swift): the Story card at each step, the Screen
/// lens with the picker over the live screen, and the Decision sheet. Real
/// views over in-memory fixtures; the drafts are put in the shared draft
/// store, exactly where the live room reads them.
enum RenderHarnessAnswers {
    static let screens = [
        "ask-story-q1", "ask-story-q2", "ask-story-other", "ask-story-review", "ask-story-sending", "ask-story-refused",
        "ask-story-answered", "ask-screen", "ask-screen-review", "ask-decision", "ask-hook-q2", "ask-hook-review",
    ]

    /// A page Claude's question hook is holding: no dialog on screen, answers go as text through the hook.
    static func isHook(_ screen: String) -> Bool { screen.hasPrefix("ask-hook") }

    static let now = RenderHarness.now
    static let mac = RenderFixtures.mac

    /// Three questions as Claude Code asks them: a single choice, a multi-select, a single choice.
    static var ask: SessionAsk {
        SessionAsk(id: "toolu_ask", questions: [
            AskQuestion(text: "Which branch should I base this on?", header: "Branch", multi: false, options: [
                AskOption(label: "main", detail: "The released code."),
                AskOption(label: "feat/relay-v2", detail: "The relay rewrite, still in review."),
                AskOption(label: "release/2.4", detail: "Only fixes, no new features.")]),
            AskQuestion(text: "Which checks should I run before pushing?", header: "Checks", multi: true, options: [
                AskOption(label: "Unit tests", detail: "swift test and the iOS logic tests."),
                AskOption(label: "Simulator build", detail: "xcodebuild for the iPhone simulator."),
                AskOption(label: "Render harness", detail: "Screenshots of every Night Watch screen."),
                AskOption(label: "Lint", detail: "")]),
            AskQuestion(text: "How should I name the commit?", header: "Commit", multi: false, options: [
                AskOption(label: "feat: answer questions from the phone", detail: ""),
                AskOption(label: "fix: question picker", detail: "")]),
        ], hasPreview: false)
    }

    /// The draft each screen shows, built with the real state machine.
    static func sheet(_ screen: String) -> AnswerSheet {
        var s = AnswerSheet(ask: ask, allowsOther: !isHook(screen))
        switch screen {
        case "ask-story-q1", "ask-decision":
            break
        case "ask-story-q2", "ask-screen", "ask-hook-q2":
            s.tap(option: 1)                 // feat/relay-v2 → on to question 2
            s.tap(option: 0); s.tap(option: 2)
        case "ask-story-other":
            s.toggleOther(); s.setOther("develop, but rebase onto main first")
        default:   // the review steps
            s.tap(option: 1)
            s.tap(option: 0); s.tap(option: 2)
            s.toggleOther(); s.setOther("also run the Mac tests")   // no effect through the hook
            s.next()
            s.tap(option: 0)
        }
        return s
    }

    static func delivery(_ screen: String) -> SentSessionCommand? {
        let state: SessionDeliveryState
        switch screen {
        case "ask-story-sending": state = .sending
        case "ask-story-refused":
            state = .refused(reason: "question_changed", message: "That question changed — look at your phone for the new one")
        case "ask-story-answered": state = .typed("Answered 3 questions in tmux pane %1")
        default: return nil
        }
        return SentSessionCommand(clientId: "ans-1", sessionId: "room-claude", kind: .answer, text: "", sentAt: now.addingTimeInterval(-2),
                                  state: state, promptKey: "toolu_ask")
    }

    /// The terminal as it shows the dialog (Claude Code 2.1.311's layout).
    static var terminalLines: [String] {
        ["● Before I push, a few questions.", "",
         "←  ☒ Branch  ☐ Checks  ☐ Commit  ✔ Submit  →", "Which checks should I run before pushing?",
         "❯ 1. [✔] Unit tests", "     swift test and the iOS logic tests.", "  2. [ ] Simulator build", "  3. [✔] Render harness",
         "  4. [ ] Lint", "  5. [ ] Type something", "     Next", "────────────────────────────────────────",
         "  6. Chat about this", "Enter to select · Tab/Arrow keys to navigate · Esc to cancel"]
    }

    static func decisionState() -> DecisionScreenState {
        let page = RenderFixtures.iv("q-ask", "mac-on-claude-code", .userInput,
            "Which branch should I base this on?\n1. main — The released code.\n2. feat/relay-v2 — The relay rewrite, still in review.\n3. release/2.4 — Only fixes, no new features.",
            ago: 70, session: "room-claude")
        let session = RenderHarnessAnswers.roomInputs("ask-decision").session
        let row = NowRowBuilder.row(for: page, session: session, macName: mac)
        let content = DecisionContent.build(iv: page, row: row, session: session, macName: mac)
        var state = DecisionScreenState(content: content, row: row, phase: .open, now: now, hasSession: true)
        state.ask = ask
        state.macName = mac
        return state
    }

    static func roomInputs(_ screen: String) -> SessionRoomData.Inputs {
        var i = RenderFixtures3.inputs("room-waiting")
        let hook = isHook(screen)
        let page = RenderFixtures.iv(hook ? "hookpre-q-ask" : "q-ask", "mac-on-claude-code", .userInput, "Which branch should I base this on?", ago: 70, session: "room-claude")
        // Held by the hook: the session reads working and no page of the Mac's is open for it.
        var session = RenderFixtures3.session("room-claude", "mac-on-claude-code", state: hook ? .active : .waitingOnUser, host: "tmux",
                                              ago: 70, page: hook ? nil : "q-ask")
        session.ask = ask
        i.session = session
        i.pageIsHook = hook
        // What the hook sent as the page's text: every question with its numbered options.
        i.pageContext = hook ? ask.questions.enumerated().map { n, q in
            "Q\(n + 1). \(q.text)\n" + q.options.enumerated().map { "\($0 + 1). \($1.label)" }.joined(separator: "\n")
        }.joined(separator: "\n\n") : nil
        i.pageRow = NowRowBuilder.row(for: page, session: session, macName: mac)
        i.screen = SessionScreen(sessionId: "room-claude", lines: terminalLines, at: now.addingTimeInterval(-2))
        i.answerDelivery = delivery(screen)
        return i
    }
}

struct HarnessAnswers: View {
    let screen: String
    @State private var lens: RoomLens
    @State private var draft = ""
    @State private var runId: String?

    init(screen: String) {
        self.screen = screen
        _lens = State(initialValue: screen.hasPrefix("ask-screen") ? .screen : .story)
    }

    var body: some View {
        if screen == "ask-decision" {
            decision
        } else {
            let _ = RenderHarnessAnswers.seed(screen)
            let data = SessionRoomData.make(RenderHarnessAnswers.roomInputs(screen))
            NWSessionRoom(data: data, lens: $lens, draft: $draft, runId: $runId)
                .environment(\.nwTopInset, 54)
        }
    }

    @ViewBuilder private var decision: some View {
        let _ = RenderHarnessAnswers.seed(screen)
        let state = RenderHarnessAnswers.decisionState()
        NWDecisionScreen(state: state, draft: .constant(""), composerOpen: .constant(false))
            .background(NWDecisionBackground(tint: state.row.tint).ignoresSafeArea())
    }
}

extension RenderHarnessAnswers {
    /// Puts the screen's draft where the live room reads it.
    @MainActor static func seed(_ screen: String) {
        AnswerDraftStore.shared.binding(for: ask, allowsOther: !isHook(screen)).wrappedValue = sheet(screen)
    }
}

#endif
