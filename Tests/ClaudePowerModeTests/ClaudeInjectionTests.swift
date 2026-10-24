import XCTest
@testable import ClaudePowerMode

final class ClaudeInjectionPlanTests: XCTestCase {
    typealias IE = InjectionExecutor

    private func keys(_ p: KeystrokePlan) -> [Keystroke]? {
        if case .send(let k, _) = p { return k }
        return nil
    }

    private func isRefused(_ p: KeystrokePlan) -> Bool {
        if case .refuse = p { return true }
        return false
    }

    // MARK: waiting (menu on screen)

    func testWaitingApproveApprovalSendsOneWithoutEnter() {
        XCTAssertEqual(keys(IE.plan(action: "approve", kind: .approval, status: .waiting, text: "")), [.text("1")])
        // Any text sent along with approve is ignored: it's still just "1".
        XCTAssertEqual(keys(IE.plan(action: "approve", kind: .approval, status: .waiting, text: "yes please")), [.text("1")])
    }

    func testWaitingDenyIsEscapeOnlyNeverEnter() {
        XCTAssertEqual(keys(IE.plan(action: "deny", kind: .approval, status: .waiting, text: "")), [.escape])
        XCTAssertEqual(keys(IE.plan(action: "deny", kind: .question, status: .waiting, text: "")), [.escape])
        XCTAssertEqual(keys(IE.plan(action: "deny", kind: .approval, status: .waiting, text: "no, stop")), [.escape])
    }

    func testWaitingCustomTextEscapesWaitsThenTypes() {
        XCTAssertEqual(keys(IE.plan(action: "custom", kind: .approval, status: .waiting, text: "use pnpm instead")),
                       [.escape, .awaitPromptClosed, .text("use pnpm instead"), .enter])
        XCTAssertEqual(keys(IE.plan(action: nil, kind: .question, status: .waiting, text: "option B")),
                       [.escape, .awaitPromptClosed, .text("option B"), .enter])
    }

    func testWaitingApproveOnQuestionRefused() {
        XCTAssertTrue(isRefused(IE.plan(action: "approve", kind: .question, status: .waiting, text: "")))
    }

    func testWaitingCarryOnRefused() {
        XCTAssertEqual(IE.plan(action: "carry_on", kind: .idle, status: .waiting, text: ""), .refuse(IE.newPageMessage))
        XCTAssertTrue(isRefused(IE.plan(action: "carry_on", kind: .approval, status: .waiting, text: "")))
    }

    func testWaitingRepliesToNonPromptPagesRefused() {
        // An idle page answered after the session moved on to a new prompt:
        // Esc would deny a prompt the user never saw.
        for action in ["approve", "deny", "custom", "carry_on"] {
            XCTAssertEqual(IE.plan(action: action, kind: .idle, status: .waiting, text: "hi"), .refuse(IE.newPageMessage), action)
            XCTAssertEqual(IE.plan(action: action, kind: .other, status: .waiting, text: "hi"), .refuse(IE.newPageMessage), action)
        }
    }

    // MARK: idle

    func testIdleTypesTextOrPhraseWithEnter() {
        XCTAssertEqual(keys(IE.plan(action: "custom", kind: .idle, status: .idle, text: "run the tests")), [.text("run the tests"), .enter])
        // Prompt already answered (found live: a late phone Approve was typed
        // as the chat message "yes, proceed"). Refused, like busy.
        XCTAssertEqual(IE.plan(action: "approve", kind: .approval, status: .idle, text: ""), .refuse(IE.promptGoneMessage))
        XCTAssertEqual(IE.plan(action: "deny", kind: .approval, status: .idle, text: ""), .refuse(IE.promptGoneMessage))
        XCTAssertEqual(IE.plan(action: "approve", kind: .question, status: .idle, text: ""), .refuse(IE.promptGoneMessage))
        // A real idle page still gets the phrase; free text is still a message.
        XCTAssertEqual(keys(IE.plan(action: "approve", kind: .idle, status: .idle, text: "")), [.text("yes, proceed"), .enter])
        XCTAssertEqual(keys(IE.plan(action: "custom", kind: .approval, status: .idle, text: "use the other file")), [.text("use the other file"), .enter])
        XCTAssertEqual(keys(IE.plan(action: "deny", kind: .idle, status: .idle, text: "")), [.text("no, stop"), .enter])
        XCTAssertEqual(keys(IE.plan(action: "carry_on", kind: .idle, status: .idle, text: "")), [.text("carry on"), .enter])
        // No action and no text (an old phone's banner tap) is not "carry on".
        XCTAssertEqual(IE.plan(action: nil, kind: .idle, status: .idle, text: ""), .refuse(IE.emptyReplyMessage))
        XCTAssertEqual(IE.plan(action: "", kind: .idle, status: .busy, text: "  "), .refuse(IE.emptyReplyMessage))
    }

    // MARK: busy

    func testBusyApproveDenyRefused() {
        XCTAssertEqual(IE.plan(action: "approve", kind: .approval, status: .busy, text: ""), .refuse(IE.promptGoneMessage))
        XCTAssertEqual(IE.plan(action: "deny", kind: .approval, status: .busy, text: ""), .refuse(IE.promptGoneMessage))
    }

    func testBusyTextIsQueuedNeverEscaped() {
        XCTAssertEqual(keys(IE.plan(action: "custom", kind: .approval, status: .busy, text: "also fix lint")), [.text("also fix lint"), .enter])
        XCTAssertEqual(keys(IE.plan(action: "carry_on", kind: .idle, status: .busy, text: "")), [.text("carry on"), .enter])
    }

    // MARK: unknown status (older Claude Code)

    func testUnknownStatusTrustsPageKind() {
        XCTAssertEqual(keys(IE.plan(action: "approve", kind: .approval, status: .unknown, text: "")), [.text("1")])
        XCTAssertEqual(keys(IE.plan(action: "deny", kind: .approval, status: .unknown, text: "")), [.escape])
        // Never a blind pause before the Enter: the gate waits for the menu to go.
        XCTAssertEqual(keys(IE.plan(action: "custom", kind: .approval, status: .unknown, text: "no")),
                       [.escape, .awaitPromptClosed, .text("no"), .enter])
        XCTAssertTrue(isRefused(IE.plan(action: "approve", kind: .question, status: .unknown, text: "")))
        XCTAssertEqual(keys(IE.plan(action: "custom", kind: .idle, status: .unknown, text: "go on")), [.text("go on"), .enter])
        XCTAssertEqual(keys(IE.plan(action: "approve", kind: .idle, status: .unknown, text: "")), [.text("yes, proceed"), .enter])
    }

    func testEmptyCustomRefused() {
        XCTAssertTrue(isRefused(IE.plan(action: "custom", kind: .idle, status: .idle, text: "   \n ")))
        XCTAssertTrue(isRefused(IE.plan(action: "custom", kind: .idle, status: .idle, text: "\u{1b}\u{03}")))
    }

    /// Invariants over every combination, so a future edit can't
    /// reintroduce "Enter while a menu is up" (which approves).
    func testExhaustiveSafetyInvariants() {
        let actions: [String?] = ["approve", "deny", "carry_on", "custom", nil, "bogus"]
        let kinds: [ReplyPromptKind] = [.approval, .question, .idle, .other]
        let statuses: [ClaudeSessionStatus] = [.busy, .waiting, .idle, .unknown]
        let texts = ["", "hello", "!rm -rf ~", "line1\nline2", "\u{1b}[A"]
        for a in actions { for k in kinds { for s in statuses { for t in texts {
            let p = IE.plan(action: a, kind: k, status: s, text: t)
            let label = "\(a ?? "nil")/\(k)/\(s)/\(t.debugDescription)"
            guard let steps = keys(p) else { continue }

            if s == .waiting || (s == .unknown && k.isPrompt) {
                // An Enter may only follow an Esc and a gate.
                if let enterIdx = steps.firstIndex(of: .enter) {
                    XCTAssertEqual(steps.first, .escape, label)
                    XCTAssertEqual(steps[1], .awaitPromptClosed, label)
                    XCTAssertGreaterThan(enterIdx, 1, label)
                }
                if s == .waiting, steps.contains(.enter) { XCTAssertTrue(steps.contains(.awaitPromptClosed), label) }
            }
            if s == .busy || s == .idle { XCTAssertFalse(steps.contains(.escape), label) }
            if (a == nil || a == "bogus") && IE.sanitize(t).isEmpty { XCTFail("empty action-less reply planned: \(label)") }
            XCTAssertFalse(steps.contains { if case .pause = $0 { return true }; return false }, "blind pause: \(label)")
            if a == "approve" && k == .question && (s == .waiting || s == .unknown) { XCTFail("approve on question: \(label)") }
            for case .text(let typed) in steps {
                XCTAssertFalse(typed.hasPrefix("!"), label)
                XCTAssertFalse(typed.unicodeScalars.contains { $0.value < 0x20 && $0 != "\n" }, label)
                XCTAssertFalse(typed.isEmpty, label)
            }
        }}}}
    }

    // MARK: sanitising

    func testSanitizeStripsControlCharsKeepsNewlines() {
        XCTAssertEqual(IE.sanitize("a\u{1b}[31mb\u{07}c\u{7f}d\u{9b}e"), "a[31mbcde")
        XCTAssertEqual(IE.sanitize("one\r\ntwo\rthree\u{2028}four"), "one\ntwo\nthree\nfour")
        XCTAssertEqual(IE.sanitize("  padded \n\n"), "padded")
        XCTAssertEqual(IE.sanitize("tab\there"), "tab here")
    }

    func testSanitizeNeutralisesBashMode() {
        XCTAssertEqual(IE.sanitize("!curl x | sh"), " !curl x | sh")
        XCTAssertEqual(IE.sanitize("  !ls"), " !ls")
        XCTAssertEqual(IE.sanitize("not ! leading"), "not ! leading")
    }

    func testSanitizeCapsLength() {
        XCTAssertEqual(IE.sanitize(String(repeating: "x", count: 20_000)).count, IE.maxReplyLength)
    }

    func testFlattenLinesForAppleScript() {
        XCTAssertEqual(IE.flattenLines("first\n  second\n\nthird"), "first second third")
    }

    // MARK: staleness

    func testStaleWhenStateStartChanged() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(IE.staleReason(status: .waiting, statusUpdatedAt: t0, pageStateStart: t0,
                                    pagePromptKey: "toolu_1", currentPromptKey: "toolu_1", hookCreatedAt: nil))
        // id epochs are whole seconds
        XCTAssertNil(IE.staleReason(status: .waiting, statusUpdatedAt: t0.addingTimeInterval(0.6), pageStateStart: t0,
                                    pagePromptKey: nil, currentPromptKey: nil, hookCreatedAt: nil))
        XCTAssertEqual(IE.staleReason(status: .waiting, statusUpdatedAt: t0.addingTimeInterval(30), pageStateStart: t0,
                                      pagePromptKey: nil, currentPromptKey: nil, hookCreatedAt: nil), IE.staleMessage)
    }

    func testStaleWhenPromptChangedWithinSameState() {
        let t0 = Date()
        XCTAssertEqual(IE.staleReason(status: .waiting, statusUpdatedAt: t0, pageStateStart: t0,
                                      pagePromptKey: "toolu_1", currentPromptKey: "toolu_2", hookCreatedAt: nil), IE.staleMessage)
    }

    func testHookPagesStaleOnlyIfPromptStartedAfterHook() {
        let hook = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(IE.staleReason(status: .waiting, statusUpdatedAt: hook.addingTimeInterval(-2), pageStateStart: nil,
                                    pagePromptKey: nil, currentPromptKey: nil, hookCreatedAt: hook))
        XCTAssertNil(IE.staleReason(status: .waiting, statusUpdatedAt: hook.addingTimeInterval(1.5), pageStateStart: nil,
                                    pagePromptKey: nil, currentPromptKey: nil, hookCreatedAt: hook))
        // A prompt that appeared 4s after the hook fired is a newer one.
        XCTAssertEqual(IE.staleReason(status: .waiting, statusUpdatedAt: hook.addingTimeInterval(4), pageStateStart: nil,
                                      pagePromptKey: nil, currentPromptKey: nil, hookCreatedAt: hook), IE.staleMessage)
        XCTAssertEqual(IE.staleReason(status: .waiting, statusUpdatedAt: hook.addingTimeInterval(60), pageStateStart: nil,
                                      pagePromptKey: nil, currentPromptKey: nil, hookCreatedAt: hook), IE.staleMessage)
    }

    func testNotStaleUnlessWaiting() {
        let t0 = Date()
        XCTAssertNil(IE.staleReason(status: .idle, statusUpdatedAt: t0, pageStateStart: t0.addingTimeInterval(-100),
                                    pagePromptKey: nil, currentPromptKey: nil, hookCreatedAt: nil))
    }

    func testActsOnPrompt() {
        XCTAssertTrue(IE.actsOnPrompt(action: "approve", kind: .idle))
        XCTAssertTrue(IE.actsOnPrompt(action: "deny", kind: .approval))
        XCTAssertTrue(IE.actsOnPrompt(action: "custom", kind: .question))
        XCTAssertFalse(IE.actsOnPrompt(action: "custom", kind: .idle))
        XCTAssertFalse(IE.actsOnPrompt(action: "carry_on", kind: .approval))
    }

    func testReplyPromptKindMapping() {
        XCTAssertEqual(ReplyPromptKind.from(wireKind: "permission"), .approval)
        XCTAssertEqual(ReplyPromptKind.from(wireKind: "plan"), .approval)
        XCTAssertEqual(ReplyPromptKind.from(wireKind: "approval"), .approval)
        XCTAssertEqual(ReplyPromptKind.from(wireKind: "question"), .question)
        XCTAssertEqual(ReplyPromptKind.from(wireKind: "user_input"), .question)
        XCTAssertEqual(ReplyPromptKind.from(wireKind: "idle"), .idle)
        XCTAssertEqual(ReplyPromptKind.from(wireKind: "rate_limit"), .other)
        XCTAssertNil(ReplyPromptKind.from(wireKind: nil))
    }
}

final class ClaudeInjectionTargetTests: XCTestCase {
    typealias IE = InjectionExecutor
    typealias Row = ProcessRunner.ProcessInfoRow

    private func session(_ pid: Int32, tty: String?, since: Date? = nil, status: ClaudeSessionStatus = .idle) -> ClaudeLiveSession {
        ClaudeLiveSession(pid: pid, sessionId: "455cd6af-046c-4468-9d9b-5de46c4d8194", cwd: "/tmp",
                          status: status, statusUpdatedAt: since, tty: tty, hasSessionFile: true)
    }

    func testPickSessionPrefersPagePidThenStateThenSoleTTY() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let a = session(10, tty: nil, since: t0)
        let b = session(20, tty: "ttys001", since: t0.addingTimeInterval(500))
        XCTAssertEqual(try IE.pickSession([a, b], pagePid: 10, pageStateStart: nil).get(), a)
        XCTAssertEqual(try IE.pickSession([a, b], pagePid: nil, pageStateStart: t0.addingTimeInterval(500)).get(), b)
        // Duplicate session ids (headless bridge + terminal): the terminal one.
        XCTAssertEqual(try IE.pickSession([a, b], pagePid: 99, pageStateStart: nil).get(), b)
    }

    func testPickSessionAmbiguousTerminalsFail() {
        let a = session(10, tty: "ttys001")
        let b = session(20, tty: "ttys002")
        guard case .failure = IE.pickSession([a, b], pagePid: nil, pageStateStart: nil) else {
            return XCTFail("two terminals must not be guessed between")
        }
    }

    func testTmuxPaneMatchesExactTTY() {
        let listing = "%0\t/dev/ttys010\t0\n%3\t/dev/ttys004\t1\n%4\t/dev/ttys0040\t0\n"
        let pane = IE.tmuxPane(forTTY: "/dev/ttys004", listing: listing)
        XCTAssertEqual(pane?.id, "%3")
        XCTAssertEqual(pane?.inMode, true)
        XCTAssertNil(IE.tmuxPane(forTTY: "/dev/ttys099", listing: listing))
        XCTAssertNil(IE.tmuxPane(forTTY: "/dev/ttys004", listing: "no server running on /tmp/tmux-501/default"))
    }

    func testHostAppWalksAncestors() {
        let table = [
            Row(pid: 1, ppid: 0, tty: "??", command: "/sbin/launchd"),
            Row(pid: 100, ppid: 1, tty: "??", command: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
            Row(pid: 200, ppid: 100, tty: "ttys001", command: "login -pf me"),
            Row(pid: 201, ppid: 200, tty: "ttys001", command: "-zsh"),
            Row(pid: 202, ppid: 201, tty: "ttys001", command: "claude"),
            Row(pid: 300, ppid: 1, tty: "??", command: "/Applications/iTerm.app/Contents/MacOS/iTerm2"),
            Row(pid: 301, ppid: 300, tty: "ttys002", command: "-zsh"),
            Row(pid: 302, ppid: 301, tty: "ttys002", command: "claude"),
            Row(pid: 400, ppid: 1, tty: "??", command: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"),
            Row(pid: 401, ppid: 400, tty: "ttys003", command: "/bin/zsh -il"),
            Row(pid: 402, ppid: 401, tty: "ttys003", command: "claude"),
            Row(pid: 500, ppid: 1, tty: "??", command: "tmux new -s work"),
            Row(pid: 501, ppid: 500, tty: "ttys004", command: "-zsh"),
            Row(pid: 502, ppid: 501, tty: "ttys004", command: "claude"),
        ]
        XCTAssertEqual(IE.hostApp(forPid: 202, processTable: table), "Terminal")
        XCTAssertEqual(IE.hostApp(forPid: 302, processTable: table), "iTerm2")
        XCTAssertEqual(IE.hostApp(forPid: 402, processTable: table), "VS Code")
        XCTAssertNil(IE.hostApp(forPid: 502, processTable: table))
        XCTAssertEqual(IE.sessionSource(pid: 402, processTable: table), .vscode)
        XCTAssertEqual(IE.sessionSource(pid: 202, processTable: table), .terminal)
    }

    func testUnknownAppBundleIsNamed() {
        XCTAssertEqual(IE.appName(forCommand: "/Applications/cmux.app/Contents/MacOS/cmux"), "cmux")
        XCTAssertNil(IE.appName(forCommand: "/usr/bin/login -flp me"))
        XCTAssertNil(IE.appName(forCommand: "tmux new -s work"))
    }

    func testHostAppSurvivesParentCycle() {
        let table = [Row(pid: 5, ppid: 6, tty: "??", command: "a"), Row(pid: 6, ppid: 5, tty: "??", command: "b")]
        XCTAssertNil(IE.hostApp(forPid: 5, processTable: table))
    }

    func testHostLabels() {
        XCTAssertEqual(IE.TerminalHost.tmux(tmuxPath: "/x", paneId: "%3", inMode: false).label, "tmux pane %3")
        XCTAssertEqual(IE.TerminalHost.terminalApp(tty: "/dev/ttys004").label, "Terminal tab ttys004")
        XCTAssertEqual(IE.TerminalHost.iTerm(tty: "/dev/ttys004").label, "iTerm2 session ttys004")
    }

    // MARK: Terminal.app deny digit

    func testDenyDigitFromPermissionPrompt() {
        let screen = """
        ⏺ Bash(npm install bcrypt)
        ╭──────────────────────────────────────────────╮
        │ Bash command                                 │
        │   npm install bcrypt                         │
        │ Do you want to proceed?                      │
        │ ❯ 1. Yes                                     │
        │   2. Yes, and don't ask again for npm install │
        │   3. No, and tell Claude what to do differently (esc) │
        ╰──────────────────────────────────────────────╯
        """
        XCTAssertEqual(IE.denyOptionDigit(screen: screen), "3")
    }

    func testDenyDigitTwoOptionPromptAndPlanPrompt() {
        XCTAssertEqual(IE.denyOptionDigit(screen: " ❯ 1. Yes\n   2. No\n"), "2")
        XCTAssertEqual(IE.denyOptionDigit(screen: "Ready to code?\n❯ 1. Yes, and auto-accept edits\n  2. Yes, and manually approve edits\n  3. No, keep planning\n"), "3")
    }

    func testDenyDigitFailsClosed() {
        // No menu
        XCTAssertNil(IE.denyOptionDigit(screen: "> type here\n"))
        // Question menu (no Yes/No)
        XCTAssertNil(IE.denyOptionDigit(screen: "Which one?\n❯ 1. Postgres\n  2. SQLite\n  3. Type something\n"))
        // "No" before any "1. Yes"
        XCTAssertNil(IE.denyOptionDigit(screen: "2. No\n"))
        // Two candidates
        XCTAssertNil(IE.denyOptionDigit(screen: "1. Yes\n2. No\n3. No, other\n"))
        // Old prompt in scrollback is out of the bottom window
        let old = "1. Yes\n2. No\n" + String(repeating: "output line\n", count: 40)
        XCTAssertNil(IE.denyOptionDigit(screen: old))
        // "Nothing" is not "No"
        XCTAssertNil(IE.denyOptionDigit(screen: "1. Yes\n2. Nothing\n"))
    }
}
