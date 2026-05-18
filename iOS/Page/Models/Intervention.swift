import Foundation
import SwiftUI

/// New vocab (approval / user_input / idle / rate_limit) is the Phase 4
/// canonical set. Legacy Claude vocab (permission / plan / question) is
/// decoded into the canonical set so old pages still render.
enum InterventionKind: String, Codable, CaseIterable {
    case approval
    case userInput = "user_input"
    case idle
    case rateLimit = "rate_limit"

    var label: String {
        switch self {
        case .approval:   return "APPROVAL"
        case .userInput:  return "QUESTION"
        case .idle:       return "IDLE"
        case .rateLimit:  return "RATE LIMIT"
        }
    }

    /// Ring colour for the chip and matching footer dot. Same hue used in
    /// both places so the eye links them at a glance.
    var color: Color {
        switch self {
        case .approval:   return Theme.Colour.kindApproval
        case .userInput:  return Theme.Colour.kindUserInput
        case .idle:       return Theme.Colour.kindIdle
        case .rateLimit:  return Theme.Colour.kindRateLimit
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "approval":   self = .approval
        case "user_input": self = .userInput
        case "idle":       self = .idle
        case "rate_limit": self = .rateLimit
        // Back-compat with pre-Phase-4 Worker payloads:
        case "permission", "plan": self = .approval
        case "question":           self = .userInput
        default:
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unknown intervention kind: \(raw)"
            )
        }
    }
}

enum InterventionBackend: String, Codable {
    case claude, codex

    var badge: String {
        switch self {
        case .claude: return "CLAUDE"
        case .codex:  return "CODEX"
        }
    }

    /// Brand tint for the backend pill.
    var tint: Color {
        switch self {
        case .claude: return Theme.Colour.backendClaude
        case .codex:  return Theme.Colour.backendCodex
        }
    }
}

enum InterventionSource: String, Codable {
    case terminal, desktop, vscode, exec, remote, unknown

    /// Always returns a human label — "Terminal" reads as fast as "VS Code"
    /// and the user wants to tell every surface apart at a glance.
    var label: String {
        switch self {
        case .terminal: return "Terminal"
        case .desktop:  return "Desktop"
        case .vscode:   return "VS Code"
        case .exec:     return "Exec"
        case .remote:   return "Remote"
        case .unknown:  return "Unknown"
        }
    }
}

struct Intervention: Identifiable, Codable, Hashable {
    let id: String
    let sessionId: String
    let cwd: String
    let projectName: String
    let kind: InterventionKind
    let openedAt: Date
    let context: String
    var closedAt: Date?
    var closeReason: String?
    var repliedAt: Date?
    var repliedText: String?
    var repliedAction: String?
    /// Worker fills in "claude" if a pre-Phase-4 Mac didn't send one.
    var backend: InterventionBackend?
    var source: InterventionSource?
    var subtype: String?

    var pagedAgo: String { Self.relative(from: openedAt, prefix: "Paged") }
    var closedAgo: String? {
        guard let c = closedAt else { return nil }
        return Self.relative(from: c, prefix: "Closed")
    }
    /// Time between page open and resolution.
    var responseTimeSeconds: Int? {
        guard let c = closedAt else { return nil }
        return max(0, Int(c.timeIntervalSince(openedAt)))
    }

    private static func relative(from date: Date, prefix: String) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "\(prefix) \(s)s ago" }
        if s < 3600 { return "\(prefix) \(s / 60)m ago" }
        if s < 86_400 { return "\(prefix) \(s / 3600)h ago" }
        return "\(prefix) \(s / 86_400)d ago"
    }
}

struct PairedMac: Codable, Hashable {
    let name: String
    let hostname: String
    let activeSessions: Int
    let pingMs: Int
    let connected: Bool
}

struct PairingPayload: Codable {
    let v: Int
    let token: String
    let relay: String
    let host: String?
}
