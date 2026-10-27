import Foundation
import SwiftUI

// Fixtures and surfaces for the In-flight cards, buttons in words and the
// header's jump: one waiting, a finished row, and working sessions with
// workflows, a stuck one and a long step. Built as snapshots so they run
// through the same `NowModel.build` as live data.

extension NightWatchFixtures {
    /// One decision waiting, a finished turn (in the root folder, to show its
    /// name never reads "/"), and `working` sessions in flight with their card
    /// facts: "page" (two workflows, normal), "llm-play" (looks stuck),
    /// "payments-api" (a long step), "docs" (rate limited).
    static func cardsScene(now: Date = boardNow(), working: Int = 2, irreversible: Bool = false) -> NowInputs {
        func at(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func claude(_ name: String, cwd: String? = nil, state: AgentSessionState = .active) -> AgentSession {
            AgentSession(backend: .claude, sessionId: "sess-\(name)", cwd: cwd ?? "/Users/roy/projects/\(name)", title: nil,
                         source: .terminal, state: state, lastActivityAt: at(1), activeFlags: [], supportsRemoteReply: true)
        }
        var sessions = [claude("bottle-flip", state: .waitingOnApproval), claude("root-shell", cwd: "/", state: .idle),
                        claude("page"), claude("llm-play")]
        var facts: [String: InFlightFacts] = [
            "sess-page": InFlightFacts(
                steps: [InFlightStep(text: "Edit: /Users/roy/projects/page/Sources/ClaudePowerMode/StuckWatch.swift", at: at(9)),
                        InFlightStep(text: "Read: /Users/roy/projects/page/Package.swift", at: at(4)),
                        InFlightStep(text: "Bash: swift test --filter StuckWatchTests", at: at(0.6))],
                currentStepIsNewest: true, model: "claude-opus-4-7",
                startedAt: at(130), busySince: at(12),
                workflows: [InFlightWorkflow(name: "Review changes", phase: "Reviewing", done: 3, total: 5, agentsRunning: 2),
                            InFlightWorkflow(name: "Test matrix", phase: "Phase 2", done: 1, total: 4, agentsRunning: 3)]),
            "sess-llm-play": InFlightFacts(
                steps: [InFlightStep(text: "Edit: Sources/Agent/Planner.swift", at: at(30)),
                        InFlightStep(text: "Bash: cargo test", at: at(22)),
                        InFlightStep(text: "Bash: cargo test", at: at(16))],
                currentStepIsNewest: true, model: "claude-sonnet-4-5-20250929",
                startedAt: at(310), busySince: at(52))
        ]
        var hosts: [String: SessionHostInfo] = [
            "sess-page": SessionHostInfo(host: "cmux", canType: true, typeBlocker: nil, canInterrupt: true),
            "sess-llm-play": SessionHostInfo(host: "tmux", canType: true, typeBlocker: nil, canInterrupt: true)
        ]
        var pending = [
            event("bottle-flip", kind: .permission,
                  context: irreversible ? "[Bash] rm -rf Builds/Dev/*.app\nDelete the dev builds"
                                        : "[Bash] git push origin feat/alerts\nPush the branch",
                  openedAt: at(1.2)),
            event("root-shell", kind: .idle, context: "Finished the cleanup: removed 14 stale logs", openedAt: at(3)),
            event("llm-play", kind: .idle, context: "No progress for 15 min — it may be hung.\nLast step: cargo test",
                  openedAt: at(1), subtype: "stuck")
        ]
        // The finished page of a session started in the root folder: its project came out as "/".
        pending[1] = InterventionEvent(
            id: "sess-root-shell-idle-\(Int(at(3).timeIntervalSince1970))", sessionId: "sess-root-shell", cwd: "/",
            projectName: "/", kind: .idle, openedAt: at(3), context: "Finished the cleanup: removed 14 stale logs",
            transcriptPath: "", backend: .claude, source: .terminal)
        var rateLimit: RateLimitEvent?
        if working >= 3 {
            sessions.append(claude("payments-api"))
            hosts["sess-payments-api"] = SessionHostInfo(host: "cmux", canType: true, typeBlocker: nil, canInterrupt: true)
            facts["sess-payments-api"] = InFlightFacts(
                steps: [InFlightStep(text: "Read: Package.swift", at: at(8)),
                        InFlightStep(text: "Bash: xcodebuild -scheme Page -sdk iphonesimulator build", at: at(6))],
                currentStepIsNewest: true, model: "claude-opus-4-7", startedAt: at(75), busySince: at(21))
        }
        if working >= 4 {
            sessions.append(claude("docs"))
            hosts["sess-docs"] = SessionHostInfo(host: "cmux", canType: true, typeBlocker: nil, canInterrupt: true)
            facts["sess-docs"] = InFlightFacts(
                steps: [InFlightStep(text: "Write: docs/SESSIONS-PROTOCOL.md", at: at(5))],
                currentStepIsNewest: false, model: "claude-haiku-4-5", startedAt: at(40), busySince: at(6))
            rateLimit = RateLimitEvent(sessionId: "sess-docs", cwd: "/Users/roy/projects/docs", projectName: "docs",
                                       eventTime: at(1), resetTime: now.addingTimeInterval(100 * 60), resetTimeText: "03:00",
                                       transcriptPath: "")
        }
        let snap = snapshot(sessions: sessions, activeRateLimit: rateLimit, pending: pending)
        var i = NowInputs(snapshot: snap, now: now, macName: "Studio MBP", idleSeconds: 5)
        i.route = route
        i.hosts = hosts
        i.facts = facts
        return i
    }
}

extension RenderSurfaces {
    @MainActor
    private static func cardsStore(_ inputs: NowInputs, tip: Bool = false, budget: CGFloat = 1500) -> NowStore {
        let prefs = NowPrefs.ephemeral()
        prefs.tipDismissed = !tip
        let st = NowStore(model: NowModel.build(inputs), prefs: prefs)
        st.now = { inputs.now }
        // A tall screen, so the cards show whole; `popover-cards-short-screen` is the small one.
        st.bodyBudget = budget
        return st
    }

    @MainActor
    static func inFlightSurfaces() -> [Surface] {
        let w = NightWatch.Space.popoverWidth + 56
        func popover(_ st: NowStore, name: String) -> Surface {
            Surface(name: name, width: w, view: AnyView(NWNowPopover(store: st).padding(28).background(NWBackdrop())))
        }
        let scene = NightWatchFixtures.cardsScene()
        let pageRow = InFlightRow.idPrefix + "sess-page"

        let rest = cardsStore(scene)
        let shortScreen = cardsStore(scene, budget: 700)
        let irreversible = cardsStore(NightWatchFixtures.cardsScene(irreversible: true))
        let composer = cardsStore(scene)
        composer.hoverFlight(pageRow)
        composer.handle(NowKeyPress(key: .char("t")))
        composer.composerText = "also run the Terminals tests when this is green"
        let queued = cardsStore(scene)
        queued.hoverFlight(pageRow)
        queued.previewFlightReceipt(InFlightReceipt(outcome: .queued, route: "cmux › page", at: scene.now), forSessionId: "sess-page")
        let refused = cardsStore(scene)
        refused.previewFlightReceipt(
            InFlightReceipt(outcome: .refused("A prompt is waiting — answer it first"), route: "cmux › page", at: scene.now),
            forSessionId: "sess-llm-play")
        let many = cardsStore(NightWatchFixtures.cardsScene(working: 4))
        let manyExpanded = cardsStore(NightWatchFixtures.cardsScene(working: 4))
        manyExpanded.setInFlightExpanded(true)
        let collapsed = cardsStore(scene)
        collapsed.setInFlightCollapsed(true)
        let jumped = cardsStore(scene)
        jumped.setInFlightCollapsed(true)
        jumped.jumpToInFlight()
        let sheet = cardsStore(scene)
        sheet.toggleShortcuts()
        var quietInputs = NightWatchFixtures.cardsScene()
        quietInputs.snapshot = NightWatchFixtures.snapshot(
            sessions: quietInputs.snapshot.sessions.filter { $0.state == .active })
        let quiet = cardsStore(quietInputs)
        let blocked = cardsStore(NightWatchFixtures.cardsScene())
        blocked.hoverFlight(InFlightRow.idPrefix + "sess-llm-play")

        return [
            popover(rest, name: "popover-cards-rest"),
            popover(shortScreen, name: "popover-cards-short-screen"),
            popover(irreversible, name: "popover-cards-irreversible"),
            popover(composer, name: "popover-cards-composer"),
            popover(queued, name: "popover-cards-receipt-queued"),
            popover(refused, name: "popover-cards-receipt-refused"),
            popover(many, name: "popover-cards-show-all"),
            popover(manyExpanded, name: "popover-cards-expanded"),
            popover(collapsed, name: "popover-cards-collapsed"),
            popover(jumped, name: "popover-cards-jumped"),
            popover(sheet, name: "popover-cards-shortcuts"),
            popover(quiet, name: "popover-cards-all-quiet"),
            popover(blocked, name: "popover-cards-selected")
        ]
    }
}
