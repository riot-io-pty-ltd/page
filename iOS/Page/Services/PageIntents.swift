import AppIntents
import Foundation

/// Siri and Shortcuts: ask what the agents are doing, stop them all, or
/// jump to the Sessions tab. No entitlement needed; the first two run
/// without opening the app.

struct AgentsStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "What are my agents doing?"
    static let description = IntentDescription("Says how many sessions need you, how many agents are working, and your Mac's battery.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let creds = RelayCredentials.current(), let url = creds.url("status") else {
            return .result(dialog: "Page isn't paired with a Mac yet.")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .result(dialog: "Your relay didn't answer.")
            }
            let status = WidgetStatus.from(json: json, macName: PairingStore.currentMacName(), now: Date(),
                                           format: { $0.formatted(date: .omitted, time: .shortened) })
            return .result(dialog: IntentDialog(stringLiteral: AgentsStatusIntent.sentence(status)))
        } catch {
            return .result(dialog: "I couldn't reach your relay.")
        }
    }

    /// "2 sessions need you and 3 agents are working on Studio. Battery 30%,
    /// cutoff in about 50 min."
    static func sentence(_ s: WidgetStatus) -> String {
        if s.presence == .offline { return "\(s.macName) is offline." }
        var parts: [String] = []
        parts.append(s.needsYou == 0 ? "Nothing needs you" : "\(s.needsYou) session\(s.needsYou == 1 ? " needs" : "s need") you")
        if let w = s.working { parts.append(w == 0 ? "no agents are working" : "\(w) agent\(w == 1 ? " is" : "s are") working") }
        var out = parts.joined(separator: " and ") + " on \(s.macName)."
        if let b = s.batteryLine { out += " \(b)." }
        if let u = s.usageLine { out += " \(u)." }
        return out
    }
}

struct StopAgentsIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop my agents"
    static let description = IntentDescription("Presses Esc in every agent session that's working on your Mac.")
    static let openAppWhenRun = false
    /// Never from a locked phone (like the notification actions).
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard RelayCredentials.current() != nil else { return .result(dialog: "Page isn't paired with a Mac yet.") }
        try await requestConfirmation(result: .result(dialog: "Stop every agent that's working on your Mac?"))
        let outcome = await SessionStore.shared.interruptAll()
        if let why = outcome.failureMessage { return .result(dialog: IntentDialog(stringLiteral: why)) }
        return .result(dialog: "Asked your Mac to stop your working agents.")
    }
}

struct OpenSessionsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Page sessions"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.tab = .sessions
        return .result()
    }
}

struct PageShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AgentsStatusIntent(), phrases: [
            "What are my agents doing in \(.applicationName)",
            "Ask \(.applicationName) what my agents are doing",
            "\(.applicationName) status",
        ], shortTitle: "Agent status", systemImageName: "waveform")
        AppShortcut(intent: StopAgentsIntent(), phrases: [
            "Stop my agents with \(.applicationName)",
            "\(.applicationName) stop my agents",
        ], shortTitle: "Stop agents", systemImageName: "stop.circle")
        AppShortcut(intent: OpenSessionsIntent(), phrases: [
            "Open \(.applicationName) sessions",
        ], shortTitle: "Sessions", systemImageName: "rectangle.stack")
    }
}
