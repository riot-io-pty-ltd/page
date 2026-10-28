#if DEBUG
import SwiftUI

// Render-harness screens for the Session Room, first run, problem states and
// widgets. Same rules as RenderHarness.swift: in-memory fixtures in the real
// wire shape, the very views the app uses, no stores, no Keychain, no
// network, no push.

enum RenderFixtures3 {
    static let now = RenderHarness.now
    static let mac = RenderFixtures.mac

    // MARK: sessions

    static func session(_ id: String, _ title: String, backend: String = "claude", provider: String? = "anthropic",
                        state: LiveSessionState, host: String = "cmux", canType: Bool = true, blocker: String? = nil,
                        ago: TimeInterval = 4, preview: String = "", page: String? = nil) -> LiveSession {
        LiveSession(id: id, backend: AgentBackend(wire: backend), title: title, cwd: "~/projects/\(title)", state: state, host: host,
                    canType: canType, typeBlocker: blocker, canInterrupt: true, provider: provider,
                    lastActivityAt: now.addingTimeInterval(-ago), interventionId: page, preview: preview)
    }

    static func entry(_ id: String, _ role: TranscriptRole, _ text: String, ago: TimeInterval, tool: String? = nil) -> TranscriptEntry {
        TranscriptEntry(id: id, role: role, text: text, at: now.addingTimeInterval(-ago), tool: tool)
    }

    /// The real wire shape: tool entries are "Name: input" one-liners with no result.
    static var claudeEntries: [TranscriptEntry] {
        [entry("e1", .user, "Group the sessions list: needs you on top, then working, then idle.", ago: 480),
         entry("e2", .assistant, "I'll add section headers to the list and sort by state. Then I'll run the iOS logic tests.", ago: 470),
         entry("e3", .tool, "Read: SessionsView.swift", ago: 460, tool: "Read"),
         entry("e4", .tool, "Grep: SessionGroup", ago: 450, tool: "Grep"),
         entry("e5", .tool, "Edit: Views/SessionsView.swift", ago: 400, tool: "Edit"),
         entry("e6", .tool, "Bash: swift build", ago: 300, tool: "Bash"),
         entry("e7", .tool, "Bash: iOS/Tests/run-logic-tests.sh", ago: 40, tool: "Bash")]
    }

    static var waitingEntries: [TranscriptEntry] {
        Array(claudeEntries.prefix(2)) + [entry("e8", .assistant, "Tests pass. I'd like to push the branch so CI runs the UI tests.", ago: 70)]
    }

    static var codexEntries: [TranscriptEntry] {
        [entry("c1", .user, "Add idempotency keys to POST /charges and cover it with a test.", ago: 200),
         entry("c2", .tool, "Shell: rg -n 'POST /charges' src", ago: 190, tool: "shell"),
         entry("c3", .tool, "Updated the plan", ago: 180, tool: "update_plan"),
         entry("c4", .tool, "Edit: src/charges.ts", ago: 150, tool: "apply_patch"),
         entry("c5", .tool, "Shell: npm test -- charges.idem", ago: 60, tool: "shell")]
    }

    static var localEntries: [TranscriptEntry] {
        [entry("l1", .user, "Explain why the BPE merge order breaks round-trips.", ago: 120),
         entry("l2", .assistant, "Merges are applied before the byte fallback, so a rare byte pair can be merged into a token the decoder never emits back. Apply the fallback first, then merges in rank order.", ago: 20)]
    }

    static var diff: SessionDiff {
        let patch = """
        diff --git a/Views/SessionsView.swift b/Views/SessionsView.swift
        index 1a2b3c4..5d6e7f8 100644
        --- a/Views/SessionsView.swift
        +++ b/Views/SessionsView.swift
        @@ -40,6 +40,18 @@ struct SessionsView
             var body: some View {
        -        List(sessions) { row($0) }
        +        ForEach(SessionGrouping.sections(sessions)) {
        +            SessionGroupHeader($0.group)
        +            ForEach($0.sessions) { row($0) }
        +        }
             }
        diff --git a/Models/LiveSessions.swift b/Models/LiveSessions.swift
        @@ -12,3 +12,8 @@ enum SessionGroup
        +    var title: String { ... }
        diff --git a/Tests/LogicTests.swift b/Tests/LogicTests.swift
        @@ -1,3 +1,4 @@
        +check(SessionGrouping.sections([]).isEmpty)
        """
        return SessionDiff(sessionId: "room-claude", clientId: nil, scope: "turn", repo: "mac-on-claude-code",
                           files: [.init(path: "Views/SessionsView.swift", added: 84, removed: 6, status: "modified"),
                                   .init(path: "Models/LiveSessions.swift", added: 32, removed: 8, status: "modified"),
                                   .init(path: "Tests/LogicTests.swift", added: 4, removed: 0, status: "modified")],
                           patch: patch, truncated: false, note: nil)
    }

    static var runs: [WorkflowRun] {
        func a(_ id: String, _ label: String, _ state: String, ago: TimeInterval, phase: String = "Verify") -> WorkflowRun.Agent {
            .init(id: id, label: label, phase: phase, state: state, lastActivityAt: now.addingTimeInterval(-ago))
        }
        let running = WorkflowRun(
            id: "wf1", name: "review-changes", summary: "Reviews this turn's changes in seven passes.", status: "running", phase: "Verify",
            done: 4, total: 7, startedAt: now.addingTimeInterval(-130), tokens: 184_000,
            agents: [a("a1", "verify: SessionsView sort order", "running", ago: 2), a("a2", "verify: iOS logic tests", "running", ago: 12),
                     a("a3", "verify: Android parity", "failed", ago: 40), a("a4", "review: InterventionDetector", "done", ago: 60, phase: "Review"),
                     a("a5", "review: SessionStore", "done", ago: 80, phase: "Review"), a("a6", "plan: split", "done", ago: 110, phase: "Plan"),
                     a("a7", "plan: scope", "done", ago: 120, phase: "Plan")])
        let done1 = WorkflowRun(id: "wf2", name: "design-pass", status: "completed", done: 12, total: 12,
                                startedAt: now.addingTimeInterval(-3_000), endedAt: now.addingTimeInterval(-1_800))
        let done2 = WorkflowRun(id: "wf3", name: "port-android", status: "completed", done: 9, total: 9,
                                startedAt: now.addingTimeInterval(-2_400), endedAt: now.addingTimeInterval(-900))
        return [running, done1, done2]
    }

    /// The Workflows lens's motion fixtures, as the run stands from each
    /// step's moment (`-NWTime` is seconds after the lens opened): running is
    /// the design's 4/7 (two running, one failed); finish has "verify: iOS
    /// logic tests" finish at 2.0 s; complete has its last agent finish at
    /// 2.0 s; done was already complete when the lens opened. live plays
    /// complete on the real clock, unpinned, so the lens's own clock runs
    /// (its last agent finishes 8 s in, time enough to see it running first).
    static func workflowScript(_ screen: String) -> [WorkflowMotion.Step]? {
        let design = runs[0]
        func with(_ r: WorkflowRun, status: String? = nil, _ states: [String: String], endedAt: Date? = nil) -> WorkflowRun {
            let agents = r.agents.map { a in
                states[a.id].map { WorkflowRun.Agent(id: a.id, label: a.label, phase: a.phase, state: $0, lastActivityAt: now) } ?? a
            }
            return WorkflowRun(id: r.id, name: r.name, summary: r.summary, status: status ?? r.status, phase: r.phase,
                               done: agents.filter { $0.state == "done" }.count, total: r.total, startedAt: r.startedAt,
                               endedAt: endedAt, tokens: r.tokens, agents: agents)
        }
        switch screen {
        case "room-workflows-running":
            return [.init(at: 0, run: design)]
        case "room-workflows-finish":
            return [.init(at: 0, run: design), .init(at: 2, run: with(design, ["a2": "done"]))]
        case "room-workflows-live":
            return workflowScript("room-workflows-complete").map { [$0[0], .init(at: 8, run: $0[1].run)] }
        case "room-workflows-complete":
            let last = with(design, ["a2": "done", "a3": "done"])
            return [.init(at: 0, run: last), .init(at: 2, run: with(last, status: "completed", ["a1": "done"], endedAt: now))]
        case "room-workflows-many":
            // A wide fan-out on the real clock, for the lens's cost: 80 agents, 20 running, 4 failed.
            let agents = (0..<80).map { i in
                WorkflowRun.Agent(id: "m\(i)", label: "verify: pass \(i + 1)", phase: "Verify",
                                  state: i < 20 ? "running" : (i < 24 ? "failed" : "done"), lastActivityAt: now.addingTimeInterval(-Double(i)))
            }
            return [.init(at: 0, run: WorkflowRun(id: "wf-many", name: "fan-out", summary: nil, status: "running", phase: "Verify",
                                                  done: 56, total: 80, startedAt: design.startedAt, tokens: design.tokens, agents: agents))]
        case "room-workflows-done":
            return [.init(at: 0, run: with(design, status: "completed", ["a1": "done", "a2": "done", "a3": "done"], endedAt: now.addingTimeInterval(-40)))]
        default:
            return nil
        }
    }

    static var screenLines: [String] {
        ["╭────────────────────────────╮",
         "│ ✻ Claude Code  v2.1.310    │",
         "╰────────────────────────────╯",
         "",
         "● Update(Views/SessionsView.swift)",
         "  ⎿  42 additions, 6 removals",
         "● Bash(swift build)",
         "  ⎿  Build complete (18s)",
         "● Bash(iOS/Tests/run-logic-tests.sh)",
         "  ⎿  passes=402 …",
         "",
         "✻ Testing… (esc to interrupt · 3m 20s)",
         "────────────────────────────────",
         "❯ ",
         "────────────────────────────────",
         "  ⏵⏵ auto mode on · 1 workflow · 1 shell",
         "  ○ review-changes   4/7 agents   2m",
         "  → mac-on-claude-code  main | ctx 62%"]
    }

    // MARK: rooms

    struct Room {
        var data: SessionRoomData
        var lens: RoomLens
        var draft = ""
        var runId: String? = nil
    }

    static func inputs(_ screen: String, time: Double = 3) -> SessionRoomData.Inputs {
        let fiveHour = RenderFixtures.status.usage?.fiveHour?.pct
        var i = SessionRoomData.Inputs(session: session("room-claude", "mac-on-claude-code", state: .active, preview: "Bash: iOS/Tests/run-logic-tests.sh"),
                                       macName: mac, now: now)
        i.timeZone = RenderHarness.timeZone
        i.transcript = SessionTranscript(sessionId: "room-claude", entries: claudeEntries, truncated: false)
        i.fiveHourPct = fiveHour
        i.screen = SessionScreen(sessionId: "room-claude", lines: screenLines, at: now.addingTimeInterval(-2))
        i.runs = runs
        // One run, as the board draws it (no picker), as it stands at the pinned time.
        if let script = workflowScript(screen), let at = WorkflowMotion.replay(script, until: time, now: now) { i.runs = [at.run] }
        i.diff = diff
        i.diffRequestedAt = now
        i.sent = [SentSessionCommand(clientId: "c-1", sessionId: "room-claude", kind: .input, text: claudeEntries[0].text,
                                     sentAt: now.addingTimeInterval(-482), state: .typed("Typed into cmux"))]
        switch screen {
        case "room-waiting":
            let pageIv = RenderFixtures.iv("c-push", "mac-on-claude-code", .approval,
                                           "[Bash] git push -u origin feat/sections\nPush this branch", ago: 70, session: "room-claude")
            i.session = session("room-claude", "mac-on-claude-code", state: .waitingOnApproval, ago: 70, page: "c-push")
            i.transcript = SessionTranscript(sessionId: "room-claude", entries: waitingEntries, truncated: false)
            i.pageRow = NowRowBuilder.row(for: pageIv, session: i.session, macName: mac)
        case "room-codex":
            i.session = session("room-codex", "payments-api", backend: "codex", provider: "unknown", state: .active, host: "Terminal",
                                preview: "Shell: npm test -- charges.idem")
            i.transcript = SessionTranscript(sessionId: "room-codex", entries: codexEntries, truncated: false)
            i.screen = nil; i.runs = []; i.fiveHourPct = nil; i.sent = []
            i.diff = SessionDiff(sessionId: "room-codex", clientId: nil, scope: "turn", repo: "payments-api",
                                 files: [.init(path: "src/charges.ts", added: 18, removed: 2, status: "modified")], patch: "", truncated: false, note: nil)
        case "room-local":
            i.session = session("room-local", "tokenizer-lab", backend: "opencode", provider: "ollama", state: .active, preview: "Generating…")
            i.transcript = SessionTranscript(sessionId: "room-local", entries: localEntries, truncated: false)
            i.screen = nil; i.runs = []; i.fiveHourPct = nil; i.sent = []; i.diff = nil
        case "room-yesno", "room-yesno-draft", "room-yesno-arm":
            // Idle, and Claude's last message asks a yes/no question: Yes and No lead the quick replies.
            i.session = session("room-claude", "mac-on-claude-code", state: .idle, ago: 120)
            i.transcript = SessionTranscript(sessionId: "room-claude", entries: [
                entry("y1", .user, "Fix the flaky ordering test.", ago: 900),
                entry("y2", .assistant, "The test sorted by timestamp, and two events can share one. I sort by id as well now, and ran the suite five times: all green.\n\nShould I go ahead and commit?", ago: 130)],
                truncated: false)
            i.screen = nil; i.runs = []; i.diff = nil; i.sent = []
            // Yes was tapped 0.4 s ago: the 1.2 s ring runs, and Cancel still works.
            if screen == "room-yesno-arm" { i.yesNoArm = YesNoArm(word: "Yes", startedAt: now.addingTimeInterval(-0.4)) }
        case "room-queue-choice", "room-queue-undo", "room-queue-held", "room-queue-bubbles":
            // A busy session on a Mac that holds messages (hold-v1) and takes them back (retract-v1).
            i.caps = ["hold-v1", "retract-v1"]
            i.session.canHold = true
            i.screen = nil; i.runs = []; i.diff = nil
            let target = SessionTarget(session: i.session, macName: mac)
            switch screen {
            case "room-queue-choice":
                i.choiceExplained = false
            case "room-queue-undo":
                // Send was tapped 3 s ago: 7 s left to Undo, and nothing has been sent.
                i.choiceExplained = true
                let cd = SendCountdown(startedAt: now.addingTimeInterval(-3))
                let c = SentSessionCommand(clientId: "c-3", sessionId: "room-claude", kind: .input, text: "Then run the linter",
                                           sentAt: now.addingTimeInterval(-3), state: .counting(cd), target: target)
                i.sent.append(c); i.latestInput = c
            default:
                // Two held messages from this phone, and one the Mac holds from another device. Delete on each.
                i.choiceExplained = true
                i.lastChoice = .whenFinished
                let a = SentSessionCommand(clientId: "c-3", sessionId: "room-claude", kind: .input, text: "Then run the linter",
                                           sentAt: now.addingTimeInterval(-200), state: .held(nil), target: target)
                let b = SentSessionCommand(clientId: "c-4", sessionId: "room-claude", kind: .input, text: "And update the changelog",
                                           sentAt: now.addingTimeInterval(-40), state: .held(nil), target: target)
                i.sent += [a, b]
                // Without a receipt above the field, each bubble carries its own Delete.
                if screen == "room-queue-held" { i.latestInput = b }
                i.session.held = [
                    HeldMessage(clientId: "other-1", text: "Bump the version after that", heldAt: now.addingTimeInterval(-300), state: .held, at: nil, detail: nil),
                    HeldMessage(clientId: "c-3", text: "Then run the linter", heldAt: now.addingTimeInterval(-200), state: .held, at: nil, detail: nil),
                    HeldMessage(clientId: "c-4", text: "And update the changelog", heldAt: now.addingTimeInterval(-40), state: .held, at: nil, detail: nil)]
            }
        case "room-photos-composer", "room-photos-path", "room-photos-busy", "room-photos-uploading", "room-photos-bubble":
            // A Mac that takes photos (images-v1) and a Claude row with a way for them to reach it.
            i.caps = ["hold-v1", "retract-v1", "images-v1"]
            i.screen = nil; i.runs = []; i.diff = nil; i.sent = []
            if screen != "room-photos-busy" { i.session = session("room-claude", "mac-on-claude-code", state: .idle, ago: 120) }
            i.session.attach = screen == "room-photos-path" ? "path" : "image"
            let target = SessionTarget(session: i.session, macName: mac)
            switch screen {
            case "room-photos-composer":
                i.photos = [RenderPhotos.item(0), RenderPhotos.item(1)]
            case "room-photos-path":
                i.photos = [RenderPhotos.item(2)]
            case "room-photos-busy":
                // The dimmed button was tapped: the reason is shown.
                i.composerProblem = PhotoOffer.busyReason
            case "room-photos-uploading":
                var c = SentSessionCommand(clientId: "c-5", sessionId: "room-claude", kind: .input, text: "What's wrong with this screen?",
                                           sentAt: now.addingTimeInterval(-4), state: .sending, target: target)
                c.photos = PhotoSend(count: 2, attach: "image", phase: .uploading(done: 7, total: 13), attached: nil)
                i.sent = [c]; i.latestInput = c
            default:
                i.transcript = SessionTranscript(sessionId: "room-claude", entries: [
                    entry("p1", .user, "Fix the flaky ordering test.", ago: 900),
                    entry("p2", .assistant, "Done: the test sorts by id as well now, and the suite is green five runs in a row.", ago: 600),
                    TranscriptEntry(id: "p3", role: .user, text: "[Image #1] [Image #2]What's wrong with this screen?", at: now.addingTimeInterval(-40), tool: nil, images: 2),
                    entry("p4", .assistant, "The second screenshot shows the Send button greyed out while the first has it lit: the draft is empty in the second.", ago: 20)], truncated: false)
                var c = SentSessionCommand(clientId: "c-5", sessionId: "room-claude", kind: .input, text: "What's wrong with this screen?",
                                           sentAt: now.addingTimeInterval(-45), state: .typed("Sent 2 photos to Claude in cmux"), target: target)
                c.photos = PhotoSend(count: 2, attach: "image", phase: .typing, attached: 2)
                i.sent = [c]
                i.latestInput = c
            }
        case "room-ended":
            i.session = session("room-claude", "mac-on-claude-code", state: .idle, ago: 400)
            i.ended = true
        case "room-blocked":
            i.session = session("room-claude", "mac-on-claude-code", state: .idle, host: "Ghostty", canType: false,
                                blocker: "Page can't type into Ghostty yet", ago: 300)
            i.screen = nil; i.runs = []
        case "room-receipt", "room-receipt-refused":
            // The receipt after a send: where it went, or why nothing did.
            let state: SessionDeliveryState = screen == "room-receipt"
                ? .queued(nil)
                : .refused(reason: "target_mismatch", message: "Nothing was typed. The room showed riot-io-teltonika, but that session is now in mac-on-claude-code. Close the room and open it again.")
            i.latestInput = SentSessionCommand(clientId: "c-2", sessionId: "room-claude", kind: .input, text: "Run the tests, then stop",
                                               sentAt: now.addingTimeInterval(-3), state: state,
                                               target: SessionTarget(session: i.session, macName: mac))
        case "room-changes", "room-review":
            i.session = session("room-claude", "mac-on-claude-code", state: .idle, ago: 120)
            let review = RenderFixtures.open[3]
            i.pageRow = NowRowBuilder.row(for: review, session: i.session, macName: mac)
        default: break
        }
        return i
    }

    static func room(_ screen: String, time: Double = 3) -> Room {
        let i = inputs(screen, time: time)
        var data = SessionRoomData.make(i)
        var lens = RoomLens.story
        switch screen {
        case "room-screen": lens = .screen
        case "room-changes", "room-review": lens = .changes
        case _ where screen.hasPrefix("room-workflows"): lens = .workflows
        case "room-stop": data.fixedStop = 0.62
        default: break
        }
        let draft = screen == "room-draft" ? "Run the tests, then stop" : screen == "room-yesno-draft" ? "Yes, and push it too"
            : screen == "room-queue-choice" ? "Then run the linter" : screen == "room-photos-composer" ? "What's wrong with this screen?" : ""
        return Room(data: data, lens: RoomLens.resolve(lens, offered: data.lenses), draft: draft,
                    runId: "wf1")
    }

    // MARK: problem states

    static func problem(_ screen: String) -> ProblemState? {
        var i = ProblemState.Inputs(macName: mac, presence: .online(lastSeen: now), authRejected: false, inboxFailure: nil, connected: true,
                                    relayHost: "page-relay.workers.dev", now: now)
        switch screen {
        case "problem-asleep":
            i.presence = .offline(lastSeen: now.addingTimeInterval(-14 * 60))
            i.battery = 12; i.onAC = false; i.cutoff = 10; i.pausedSessions = 3
        case "problem-gone":
            i.presence = .offline(lastSeen: now.addingTimeInterval(-3 * 3600))
        case "problem-stale":
            i.presence = .stale(lastSeen: now.addingTimeInterval(-4 * 60))
        case "problem-relay":
            i.inboxFailure = "The network connection was lost."; i.connected = false; i.lastKnownAt = now.addingTimeInterval(-6 * 60)
        case "problem-pairing":
            i.authRejected = true
        default: break
        }
        return ProblemState.build(i)
    }

    // MARK: widgets

    static var widgetStatus: WidgetStatus {
        WidgetStatus(macName: mac, presence: .online, needsYou: 2, working: 5, live: 9, batteryLine: nil, usageLine: nil,
                     fetchedAt: now, usage: RenderFixtures.status.usage, snapshot: RenderFixtures.status)
    }
}

// MARK: - Views

struct HarnessRoom: View {
    let screen: String
    @State private var lens: RoomLens
    @State private var draft: String
    @State private var runId: String?
    private let room: RenderFixtures3.Room
    /// The live fixture's step, moved on the real clock.
    @State private var step = 0

    init(screen: String, time: Double = 3) {
        self.screen = screen
        let r = RenderFixtures3.room(screen, time: time)
        room = r
        _lens = State(initialValue: r.lens)
        _draft = State(initialValue: r.draft)
        _runId = State(initialValue: r.runId)
    }

    var body: some View {
        if screen == "room-agent" {
            let run = RenderFixtures3.runs[0]
            let agent = run.agents[2]
            NWAgentRoomScreen(
                runName: "\(run.name) › agent 7", agentLabel: agent.label, state: .failed,
                model: AgentRoomModel.build(entries: [
                    RenderFixtures3.entry("g1", .user, "Check the Android port matches iOS usage-card logic exactly; run ./gradlew test.", ago: 200),
                    RenderFixtures3.entry("g2", .tool, "Read: UsageDisplay.swift", ago: 190, tool: "Read"),
                    RenderFixtures3.entry("g3", .tool, "Read: UsageDisplay.kt", ago: 180, tool: "Read"),
                    RenderFixtures3.entry("g4", .tool, "Bash: ./gradlew --offline test", ago: 100, tool: "Bash"),
                    RenderFixtures3.entry("g5", .assistant, "Couldn't run the build without the SDK path, so I'm stopping here and reporting it.", ago: 60)],
                    finished: true))
                .environment(\.nwTopInset, 54)
        } else if let script = RenderFixtures3.workflowScript(screen) {
            // The lens itself, where the eye lands: in the room the composer covers the
            // orbit on this short screen. The very view the room shows, on the room's data.
            NWRoomWorkflowsLens(data: live(script), actions: SessionRoomActions(), runId: $runId)
                .padding(.top, 20)
                .environment(\.nwWorkflowScript, script)
                .task {
                    // Unpinned, the script's steps arrive as a Mac's would: the lens diffs them itself.
                    guard screen == "room-workflows-live" else { return }
                    for (i, s) in script.enumerated().dropFirst() {
                        try? await Task.sleep(nanoseconds: UInt64((s.at - script[i - 1].at) * 1_000_000_000))
                        step = i
                    }
                }
        } else {
            NWSessionRoom(data: room.data, lens: $lens, draft: $draft, runId: $runId)
                .environment(\.nwTopInset, 54)
        }
    }

    private func live(_ script: [WorkflowMotion.Step]) -> SessionRoomData {
        guard screen == "room-workflows-live" else { return room.data }
        var d = room.data
        d.runs = [script[min(step, script.count - 1)].run]
        return d
    }
}

struct HarnessOnboarding: View {
    let screen: String
    var body: some View {
        switch screen {
        case "welcome":
            NWWelcomeScreen()
        case "welcome-notice":
            NWWelcomeScreen(notice: ("Pair again", "Your relay retired the old pairing token. Your old inbox and history were cleared."))
        case "scan", "scan-hint":
            NWScanScreen(hint: screen == "scan-hint" ? "That QR code isn't a Page pairing code." : nil) {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.20), Color(white: 0.13)], startPoint: .top, endPoint: .bottom))
            }
            .environment(\.nwTopInset, 54)
        case "pair-checking":
            NWPairStep(content: .checking(host: "page-relay.workers.dev"), onSecondary: {}, secondaryTitle: "Cancel")
        case "pair-confirm":
            NWPairStep(content: .confirm(mac: "Studio MBP", host: "page-relay.workers.dev", online: true, unused: false),
                       onPrimary: {}, primaryTitle: "Pair", onSecondary: {}, secondaryTitle: "Cancel")
        case "pair-problem":
            NWPairStep(content: .problem(title: "The relay rejected this code", message: "Show the pairing code on your Mac again and scan the new one."),
                       onSecondary: {}, secondaryTitle: "Start over")
        case "paired-denied":
            NWPairedScreen(model: PairedWelcome.build(macName: "Studio MBP", liveSessions: 14, isFirstMac: true, notifications: .off))
        default:
            NWPairedScreen(model: PairedWelcome.build(macName: "Studio MBP", liveSessions: 14, isFirstMac: true, notifications: .notSet))
        }
    }
}

struct HarnessProblem: View {
    let screen: String
    @State private var destination = NWDestination.now
    @State private var held: TimeInterval?

    private var data: NowScreenData {
        var d = RenderFixtures.nowData("now-quiet")
        d.problem = RenderFixtures3.problem(screen)
        if d.problem?.kind == .macAsleep { d.chip = MacChipModel(text: "\(RenderFixtures3.mac) · offline", tone: .offline) }
        d.banners = []
        return d
    }

    var body: some View {
        let d = data
        return NWShell(destination: $destination, decideCount: 0, workingCount: 0, stopPlan: StopPlan.build(sessions: [], hasSessionList: true),
                       held: $held) {
            NWNowScreen(data: d)
        } lanes: { EmptyView() }
            .environment(\.nwTopInset, 54)
    }
}

/// The widgets as the Home Screen draws them: a flat dark surface, rounded.
struct HarnessWidgets: View {
    private func frame<Content: View>(_ w: CGFloat, _ h: CGFloat, palette: NightWatch.AuroraPalette, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(width: w, height: h)
            .background(NWWidgetBackground(palette: palette))
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }

    private var offlineStatus: WidgetStatus {
        var o = RenderFixtures3.widgetStatus
        o.presence = .offline
        return o
    }

    var body: some View {
        let s = RenderFixtures3.widgetStatus
        let offline = offlineStatus
        let usage = UsageCardModel(RenderFixtures.status.usage, now: RenderHarness.now)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("WIDGETS").nwLabel()
                HStack(alignment: .top, spacing: 16) {
                    frame(170, 170, palette: s.facePalette) { NWWidgetStatusFace(status: s, size: .small, now: RenderHarness.now, timeZone: RenderHarness.timeZone) }
                    frame(170, 170, palette: .quiet) { NWWidgetUsageFace(model: usage, size: .small, now: RenderHarness.now, timeZone: RenderHarness.timeZone) }
                }
                frame(358, 170, palette: s.facePalette) { NWWidgetStatusFace(status: s, size: .medium, now: RenderHarness.now, timeZone: RenderHarness.timeZone) }
                frame(358, 170, palette: .quiet) { NWWidgetUsageFace(model: usage, size: .medium, now: RenderHarness.now, timeZone: RenderHarness.timeZone) }
                frame(358, 380, palette: s.facePalette) { NWWidgetStatusFace(status: s, size: .large, now: RenderHarness.now, timeZone: RenderHarness.timeZone) }
                HStack(alignment: .top, spacing: 16) {
                    frame(170, 170, palette: offline.facePalette) { NWWidgetStatusFace(status: offline, size: .small, now: RenderHarness.now, timeZone: RenderHarness.timeZone) }
                    frame(170, 170, palette: .asleep) { NWWidgetStatusFace(status: nil, problem: "Open Page to pair", size: .small) }
                }
            }
            .padding(.horizontal, 17).padding(.top, 60).padding(.bottom, 30)
        }
    }
}
/// Photos for the render harness: pictures drawn in code, then put through the real re-encoder.
enum RenderPhotos {
    static func item(_ seed: Int) -> PhotoDraftItem {
        let palettes: [[(CGFloat, CGFloat, CGFloat)]] = [[(0.10, 0.28, 0.55), (0.95, 0.62, 0.30)], [(0.08, 0.40, 0.36), (0.85, 0.85, 0.55)], [(0.35, 0.18, 0.50), (0.95, 0.45, 0.55)]]
        let c = palettes[seed % palettes.count]
        let w = 1600, h = 1200
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
            CGColor(red: c[0].0, green: c[0].1, blue: c[0].2, alpha: 1), CGColor(red: c[1].0, green: c[1].1, blue: c[1].2, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: h), options: [])
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.22))
        ctx.fillEllipse(in: CGRect(x: w / 5 + seed * 90, y: h / 4, width: h / 2, height: h / 2))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.18))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h / 5))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        guard case .success(let photo) = PhotoEncoder.prepare(out as Data) else { return PhotoDraftItem(id: "render-\(seed)", phase: .encoding) }
        return PhotoDraftItem(id: "render-\(seed)", phase: .ready(photo))
    }
}
#endif
