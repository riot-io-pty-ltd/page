import Foundation

/// New vocab (approval / user_input / idle / rate_limit) is the canonical
/// set. Legacy Claude vocab (permission / plan / question) is decoded into
/// the canonical set so pages from older Macs and hooks still render.
///
/// Foundation-only on purpose (colours live in NWTheme.swift) so the model and
/// its decoding can be compiled and tested outside the app target.
enum InterventionKind: String, CaseIterable {
    case approval
    case userInput = "user_input"
    case idle
    case rateLimit = "rate_limit"

    /// Maps any wire value to a kind. Unknown values become `.userInput`,
    /// matching the Worker's own coercion ("unknown kind -> question"): a
    /// text-only reply screen is the safe default because it never offers
    /// Approve/Deny for something we don't understand.
    init(wire raw: String?) {
        switch raw {
        case "approval", "permission", "plan": self = .approval
        case "idle":                           self = .idle
        case "rate_limit":                     self = .rateLimit
        default:                               self = .userInput
        }
    }

    var label: String {
        switch self {
        case .approval:   return "APPROVAL"
        case .userInput:  return "QUESTION"
        case .idle:       return "IDLE"
        case .rateLimit:  return "RATE LIMIT"
        }
    }

    /// Spoken name for VoiceOver ("Approval request", not "APPROVAL").
    var accessibilityName: String {
        switch self {
        case .approval:   return "Approval request"
        case .userInput:  return "Question"
        case .idle:       return "Idle session"
        case .rateLimit:  return "Rate limit"
        }
    }

    /// Inbox ordering: things that block an agent on a yes/no come first,
    /// then questions, then idle sessions, then informational pages.
    var urgencyRank: Int {
        switch self {
        case .approval:   return 0
        case .userInput:  return 1
        case .idle:       return 2
        case .rateLimit:  return 3
        }
    }
}

enum InterventionBackend: String {
    case claude, codex

    var badge: String {
        switch self {
        case .claude: return "CLAUDE"
        case .codex:  return "CODEX"
        }
    }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        }
    }
}

enum InterventionSource: String {
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

struct Intervention: Identifiable, Hashable {
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
    /// The `backend` string as the relay sent it, kept so an agent Page does
    /// not know (a value `backend` could not decode) is not mistaken for
    /// Claude. Decode-only; the wire is unchanged.
    var backendRaw: String?
    var source: InterventionSource?
    var subtype: String?
    /// v2 (Worker-managed): "pending" | "delivered" | "failed".
    var deliveryStatus: String?
    /// v2: short human-readable delivery result from the Mac.
    var deliveryDetail: String?
    var deliveryMethod: String?
    /// Worker-managed: a page from a v1 blocking hook (`hook-` id). The hook
    /// polls for the answer itself and can only apply Approve or Deny.
    var hookBlocking: Bool?

    /// Hook-owned pages: the hook polls for the answer itself, the Mac never
    /// types anything for these.
    var isBlockingHook: Bool { id.hasPrefix("hookpre-") || hookBlocking == true }

    /// Only Approve/Deny can be applied (the relay answers anything else
    /// with 422 `approve_or_deny_only`), so don't offer a text reply.
    var acceptsDecisionsOnly: Bool { hookBlocking == true && !id.hasPrefix("hookpre-") && kind == .approval }

    /// Name of the agent for copy ("Claude needs your input").
    var agentName: String { backend?.displayName ?? "Your agent" }

    /// The relay named an agent Page has no adapter for. A page with no
    /// backend at all is an older Mac's Claude page, not this.
    var hasUnknownBackend: Bool {
        backend == nil && !(backendRaw ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }
}

extension Intervention: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, sessionId, cwd, projectName, kind, openedAt, context
        case closedAt, closeReason, repliedAt, repliedText, repliedAction
        case backend, source, subtype, deliveryStatus, deliveryDetail, deliveryMethod
        case hookBlocking
    }

    /// Lenient by design: only `id`, `sessionId` and `openedAt` are required.
    /// Everything else is optional or defaulted, and a malformed optional
    /// field is treated as missing instead of failing the whole page — one
    /// odd hook payload must never blank the inbox.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        openedAt = try c.decode(Date.self, forKey: .openedAt)
        cwd = c.lenientString(.cwd) ?? ""
        let project = c.lenientString(.projectName) ?? ""
        projectName = ProjectLabel.clean(project, cwd: cwd)
        kind = InterventionKind(wire: c.lenientString(.kind))
        context = c.lenientString(.context) ?? ""
        closedAt = try? c.decodeIfPresent(Date.self, forKey: .closedAt)
        closeReason = c.lenientString(.closeReason)
        repliedAt = try? c.decodeIfPresent(Date.self, forKey: .repliedAt)
        repliedText = c.lenientString(.repliedText)
        repliedAction = c.lenientString(.repliedAction)
        backendRaw = c.lenientString(.backend)
        backend = backendRaw.flatMap(InterventionBackend.init(rawValue:))
        source = c.lenientString(.source).map { InterventionSource(rawValue: $0) ?? .unknown }
        subtype = c.lenientString(.subtype)
        deliveryStatus = c.lenientString(.deliveryStatus)
        deliveryDetail = c.lenientString(.deliveryDetail)
        deliveryMethod = c.lenientString(.deliveryMethod)
        hookBlocking = (try? c.decodeIfPresent(Bool.self, forKey: .hookBlocking)) ?? nil
    }
}

extension KeyedDecodingContainer {
    /// A string if present and actually a string; nil for missing, null or
    /// the wrong type.
    func lenientString(_ key: Key) -> String? {
        (try? decodeIfPresent(String.self, forKey: key)) ?? nil
    }
}

/// What we persist about the paired Mac. Older builds stored extra fields
/// (hostname, activeSessions, pingMs, connected); JSONDecoder ignores unknown
/// keys, so existing Keychain entries still decode. Any new field must stay
/// optional for the same reason.
struct PairedMac: Codable, Hashable {
    let name: String
    var pairedAt: Date?
}
