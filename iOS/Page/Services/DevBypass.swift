#if DEBUG
import Foundation

/// Seeds in-memory mock state so you can navigate the inbox, reply and
/// sessions screens without a real Mac sending pages. Triggered by a "Skip pairing (DEV)"
/// button on the Pair screen; never writes credentials or touches the network.
@MainActor
enum DevBypass {
    static func fakeMac() -> PairedMac {
        PairedMac(name: "MacBook Pro (dev)", pairedAt: Date())
    }

    static func fakeInterventions() -> [Intervention] {
        let now = Date()
        return [
            Intervention(
                id: "dev-1",
                sessionId: "7f3a9c2b-1111-aaaa-bbbb-cccccccccccc",
                cwd: "/Users/you/projects/acme-web",
                projectName: "acme-web",
                kind: .approval,
                openedAt: now.addingTimeInterval(-12),
                context: "Bash command needs approval: `npm install bcrypt@5.1.1`",
                backend: .claude,
                source: .terminal
            ),
            Intervention(
                id: "dev-2",
                sessionId: "abcdef12-2222-bbbb-cccc-dddddddddddd",
                cwd: "/Users/you/projects/nova-firmware",
                projectName: "nova-firmware",
                kind: .userInput,
                openedAt: now.addingTimeInterval(-130),
                context: "Should I retry the cert download at 9600 baud instead of 38400?",
                backend: .codex,
                source: .vscode
            ),
            Intervention(
                id: "dev-3",
                sessionId: "12345678-3333-cccc-dddd-eeeeeeeeeeee",
                cwd: "/Users/you/projects/helix-mobile",
                projectName: "helix-mobile",
                kind: .approval,
                openedAt: now.addingTimeInterval(-310),
                context: "4-step plan for the Reply screen is ready — review before implementation?",
                backend: .claude,
                source: .terminal,
                subtype: "plan"
            ),
            Intervention(
                id: "dev-4",
                sessionId: "99999999-4444-dddd-eeee-ffffffffffff",
                cwd: "/Users/you/projects/orbit-api",
                projectName: "orbit-api",
                kind: .idle,
                openedAt: now.addingTimeInterval(-900),
                context: "Finished the migration and all tests pass. Waiting for your next instruction.",
                backend: .claude,
                source: .terminal
            )
        ]
    }

    /// Starts DEV mode: mock pages, mock live sessions and transcripts.
    /// Sessions are seeded after the inbox, whose reset clears them.
    static func start(pairing: PairingStore, api: APIClient) {
        pairing.adoptDev(fakeMac())
        api.seedDevInbox(fakeInterventions())
        SessionStore.shared.seedDev(macName: fakeMac().name, sessions: fakeSessions(), transcripts: fakeTranscripts())
    }

    static let activeSessionId = "5e551011-5555-eeee-ffff-000000000000"

    /// Mixed on purpose: every group, a non-typable host, a local-model
    /// backend, and sessions whose pages are in the mock inbox.
    static func fakeSessions() -> [LiveSession] {
        let now = Date()
        func s(_ id: String, _ backend: String, _ title: String, _ state: LiveSessionState, host: String,
               canType: Bool = true, blocker: String? = nil, canInterrupt: Bool = true, provider: String? = "anthropic",
               ago: TimeInterval, page: String? = nil, preview: String, attach: String? = nil) -> LiveSession {
            var row = LiveSession(id: id, backend: AgentBackend(wire: backend), title: title, cwd: "~/projects/\(title)",
                        state: state, host: host, canType: canType, typeBlocker: canType ? nil : blocker,
                        canInterrupt: canInterrupt, provider: provider, lastActivityAt: now.addingTimeInterval(-ago),
                        interventionId: page, preview: preview)
            row.attach = attach
            return row
        }
        return [
            s("7f3a9c2b-1111-aaaa-bbbb-cccccccccccc", "claude", "acme-web", .waitingOnApproval, host: "cmux",
              ago: 12, page: "dev-1", preview: "Bash: npm install bcrypt@5.1.1"),
            s("abcdef12-2222-bbbb-cccc-dddddddddddd", "codex", "nova-firmware", .waitingOnUser, host: "VS Code",
              canType: false, blocker: "Page can't type into VS Code yet", canInterrupt: false, provider: "cloudGateway",
              ago: 130, page: "dev-2", preview: "Should I retry the cert download at 9600 baud instead of 38400?"),
            s(activeSessionId, "claude", "page-ios", .active, host: "tmux",
              ago: 3, preview: "Bash: ./Tests/run-logic-tests.sh"),
            s("0110a4a1-6666-ffff-0000-111111111111", "ollama", "llm-play", .active, host: "Ghostty",
              canType: false, blocker: "Page can't type into Ghostty yet", canInterrupt: false, provider: "ollama",
              ago: 40, preview: "Edit: src/tokenizer.rs"),
            s("12345678-3333-cccc-dddd-eeeeeeeeeeee", "claude", "helix-mobile", .waitingOnApproval, host: "Terminal",
              canType: false, blocker: "Page can't type into Terminal yet", canInterrupt: false,
              ago: 310, page: "dev-3", preview: "4-step plan for the Reply screen is ready"),
            s("99999999-4444-dddd-eeee-ffffffffffff", "claude", "orbit-api", .idle, host: "iTerm",
              ago: 900, preview: "Finished the migration and all tests pass.", attach: "image"),
            s("ra7e1111-7777-0000-1111-222222222222", "codex", "docs-site", .rateLimited, host: "cmux",
              provider: "cloudGateway", ago: 1800, preview: "Rate limited until 3pm")
        ]
    }

    static func fakeTranscripts() -> [SessionTranscript] {
        let now = Date()
        func e(_ id: String, _ role: TranscriptRole, _ text: String, ago: TimeInterval, tool: String? = nil) -> TranscriptEntry {
            TranscriptEntry(id: id, role: role, text: text, at: now.addingTimeInterval(-ago), tool: tool)
        }
        return [
            SessionTranscript(sessionId: activeSessionId, entries: [
                e("1", .user, "Add a Sessions tab that lists every live agent session, with a composer.", ago: 600),
                e("2", .assistant, "I'll start with the models so the logic is testable, then the store, then the views.", ago: 590),
                e("3", .tool, "Read: iOS/Page/Models/Intervention.swift", ago: 585, tool: "Read"),
                e("4", .tool, "Write: iOS/Page/Models/LiveSessions.swift", ago: 400, tool: "Write"),
                e("5", .assistant, "Models are in. Running the logic tests before touching the UI.", ago: 120),
                e("6", .user, "Also check dark mode please", ago: 60),
                e("7", .tool, "Bash: ./Tests/run-logic-tests.sh", ago: 3, tool: "Bash")
            ], truncated: true),
            SessionTranscript(sessionId: "7f3a9c2b-1111-aaaa-bbbb-cccccccccccc", entries: [
                e("1", .user, "Switch password hashing to bcrypt.", ago: 300),
                e("2", .assistant, "I'll add bcrypt and migrate the hash helper.", ago: 280),
                e("3", .tool, "Bash: npm install bcrypt@5.1.1", ago: 12, tool: "Bash"),
                e("4", .system, "Waiting for approval", ago: 12)
            ], truncated: false),
            SessionTranscript(sessionId: "99999999-4444-dddd-eeee-ffffffffffff", entries: [
                e("1", .user, "Run the migration and fix whatever breaks.", ago: 2400),
                e("2", .tool, "Bash: npm run migrate", ago: 2300, tool: "Bash"),
                e("3", .tool, "Edit: src/db/schema.ts", ago: 1500, tool: "Edit"),
                e("4", .assistant, "Finished the migration and all tests pass. Waiting for your next instruction.", ago: 900)
            ], truncated: false)
        ]
    }
}
#endif
