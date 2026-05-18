import Foundation

/// Codable shapes for the `codex app-server` JSON-RPC-ish protocol.
///
/// Empirical notes from the 2026-05-13 spike against codex-cli 0.130.0:
///   - Wire format is newline-delimited JSON. No `jsonrpc: "2.0"` field.
///   - The documented `initialize` response is flatter than the docs imply
///     (no `serverInfo` wrapper).
///   - We decode permissively: every field that isn't required for routing
///     is optional, and unknown fields are ignored by Decoder.
///   - The protocol is `[experimental]` — pin to a known-good `codex`
///     version range and expect occasional drift.
///
/// Only the message shapes we actively use are typed. Anything else stays
/// as raw `JSON` (an enum holding the JSON value tree) so we can log and
/// reason about it without committing to a struct shape that may change.
enum AppServerProtocol {

    // MARK: Initialize

    struct InitializeParams: Codable {
        let clientInfo: ClientInfo
        let capabilities: Capabilities

        struct ClientInfo: Codable {
            let name: String
            let title: String
            let version: String
        }

        struct Capabilities: Codable {
            let experimentalApi: Bool
        }
    }

    struct InitializeResult: Codable {
        let userAgent: String?
        let codexHome: String?
        let platformFamily: String?
        let platformOs: String?
    }

    // MARK: Account

    struct AccountReadParams: Codable {
        let refreshToken: Bool
    }

    struct AccountReadResult: Codable {
        let account: Account?
        let requiresOpenaiAuth: Bool?
    }

    struct Account: Codable {
        let type: String?
        let email: String?
        let planType: String?
    }

    // MARK: Threads

    struct ThreadListParams: Codable {
        let limit: Int?
        let cursor: String?

        init(limit: Int? = 50, cursor: String? = nil) {
            self.limit = limit
            self.cursor = cursor
        }
    }

    struct ThreadListResult: Codable {
        let data: [ThreadSummary]
        let nextCursor: String?
        let backwardsCursor: String?
    }

    struct ThreadSummary: Codable, Equatable {
        let id: String
        let sessionId: String?
        let cwd: String?
        let path: String?
        let source: String?
        let name: String?
        let preview: String?
        let cliVersion: String?
        let modelProvider: String?
        let createdAt: Int?
        let updatedAt: Int?
        let status: ThreadStatusEnvelope?

        var displayTitle: String {
            if let n = name, !n.isEmpty { return n }
            if let p = preview, !p.isEmpty {
                let trimmed = p.prefix(60)
                return String(trimmed)
            }
            return String(id.prefix(8))
        }

        var projectName: String {
            guard let cwd = cwd, !cwd.isEmpty else { return "Codex" }
            return URL(fileURLWithPath: cwd).lastPathComponent
        }
    }

    struct ThreadStatusEnvelope: Codable, Equatable {
        /// e.g. "notLoaded", "loaded", "active", ...
        let type: String?
        /// Free-form flags from `thread/status/changed` notifications.
        let activeFlags: [String]?
    }

    struct ThreadReadParams: Codable {
        let threadId: String
    }

    // MARK: Errors

    /// `-32001` is "server overloaded, retry later" per the protocol docs.
    /// We back off and retry on this specifically.
    static let errorCodeServerOverloaded = -32001

    struct RPCError: Codable, Error {
        let code: Int
        let message: String?
        let data: JSON?
    }

    // MARK: JSON tree

    /// A permissive JSON value, used wherever we want to pass through a
    /// payload without committing to a typed schema. Keeps Decoder happy
    /// when the protocol grows new fields between Codex releases.
    indirect enum JSON: Codable, Equatable {
        case null
        case bool(Bool)
        case int(Int64)
        case double(Double)
        case string(String)
        case array([JSON])
        case object([String: JSON])

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null; return }
            if let v = try? c.decode(Bool.self) { self = .bool(v); return }
            if let v = try? c.decode(Int64.self) { self = .int(v); return }
            if let v = try? c.decode(Double.self) { self = .double(v); return }
            if let v = try? c.decode(String.self) { self = .string(v); return }
            if let v = try? c.decode([JSON].self) { self = .array(v); return }
            if let v = try? c.decode([String: JSON].self) { self = .object(v); return }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrecognised JSON value")
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .null: try c.encodeNil()
            case .bool(let v): try c.encode(v)
            case .int(let v): try c.encode(v)
            case .double(let v): try c.encode(v)
            case .string(let v): try c.encode(v)
            case .array(let v): try c.encode(v)
            case .object(let v): try c.encode(v)
            }
        }

        /// Convenience accessor for nested string fields:
        /// `json["payload", "sessionId"].string`
        subscript(path: String...) -> JSON {
            var node = self
            for key in path {
                guard case .object(let dict) = node, let next = dict[key] else { return .null }
                node = next
            }
            return node
        }

        var stringValue: String? { if case .string(let s) = self { return s }; return nil }
        var intValue: Int? {
            switch self {
            case .int(let v): return Int(v)
            case .double(let v): return Int(v)
            default: return nil
            }
        }
        var arrayValue: [JSON]? { if case .array(let a) = self { return a }; return nil }
        var objectValue: [String: JSON]? { if case .object(let o) = self { return o }; return nil }
    }
}
