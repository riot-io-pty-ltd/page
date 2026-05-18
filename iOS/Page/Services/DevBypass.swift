#if DEBUG
import Foundation

/// Seeds in-memory mock state so you can navigate the inbox/reply screens
/// without a real Mac sending pages. Triggered by a "Skip pairing (DEV)"
/// button on the Pair screen.
@MainActor
enum DevBypass {
    static func fakeMac() -> PairedMac {
        PairedMac(name: "MacBook Pro",
                  hostname: "studio.local",
                  activeSessions: 3,
                  pingMs: 4,
                  connected: true)
    }

    static func fakePairingPayload() -> PairingPayload {
        PairingPayload(v: 1, token: "DEV-TOKEN", relay: AppConstants.workerBaseURL.absoluteString, host: "MacBook Pro")
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
            )
        ]
    }
}
#endif
