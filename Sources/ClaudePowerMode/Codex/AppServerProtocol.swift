import Foundation

/// Codable shapes for the `codex app-server` JSON-RPC protocol.
///
/// Empirical notes (2026-05-13 spike against codex-cli 0.130.0, re-checked
/// against the strings in the 0.142.5 binary):
///   - Wire format is newline-delimited JSON. No `jsonrpc: "2.0"` field.
///   - Three inbound message shapes share one envelope: responses to our
///     requests (`id` + `result`|`error`), server→client *requests*
///     (`id` + `method` — approvals, user-input prompts) and notifications
///     (`method`, no `id`). `InboundMessage.classify` is the one place that
///     tells them apart.
///   - The documented `initialize` response is flatter than the docs imply
///     (no `serverInfo` wrapper).
///   - We decode permissively: every field that isn't required for routing
///     is optional, unknown fields are ignored, and one malformed thread in
///     a `thread/list` page doesn't sink the whole page.
///   - The protocol is `[experimental]` — expect occasional drift.
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
        /// `"created_at" | "updated_at" | "recency_at"` (snake_case on the
        /// wire, unlike everything else). Older servers don't know it, so the
        /// caller drops it after an RPC error.
        let sortKey: String?
        /// `"asc" | "desc"`. The server default is unverified, so always send
        /// it alongside `sortKey`.
        let sortDirection: String?

        init(limit: Int? = 50, cursor: String? = nil, sortKey: String? = nil, sortDirection: String? = nil) {
            self.limit = limit
            self.cursor = cursor
            self.sortKey = sortKey
            self.sortDirection = sortDirection
        }
    }

    struct ThreadListResult: Decodable {
        let data: [ThreadSummary]
        let nextCursor: String?

        enum CodingKeys: String, CodingKey { case data, nextCursor }

        init(data: [ThreadSummary], nextCursor: String?) {
            self.data = data
            self.nextCursor = nextCursor
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Lossy: skip threads we can't decode instead of failing the page.
            let raw = try c.decodeIfPresent([Lossy<ThreadSummary>].self, forKey: .data) ?? []
            self.data = raw.compactMap(\.value)
            self.nextCursor = try? c.decodeIfPresent(String.self, forKey: .nextCursor)
        }
    }

    struct ThreadSummary: Decodable, Equatable {
        let id: String
        let cwd: String?
        /// Absolute path of the thread's rollout JSONL — the file Page tails.
        let path: String?
        /// "cli" | "vscode" | "exec" | "appServer" | ... For sub-agent
        /// threads the server sends an object here instead of a string.
        let source: String?
        let name: String?
        let preview: String?
        let createdAt: Int?
        let updatedAt: Int?
        let status: ThreadStatusEnvelope?
        /// True for threads spawned by another thread (sub-agents). Their
        /// `task_complete` is not "the user's agent is waiting on them".
        let isSubAgent: Bool
        /// The thread's model provider id ("openai", "ollama", "lmstudio",
        /// "ollama-launch", …). Optional and lenient: older servers omit it,
        /// and a non-string value decodes as nil.
        let modelProvider: String?

        enum CodingKeys: String, CodingKey {
            case id, cwd, path, source, name, preview, createdAt, updatedAt, status, parentThreadId, modelProvider
        }

        init(id: String, cwd: String?, path: String?, source: String? = nil, name: String? = nil,
             preview: String? = nil, createdAt: Int? = nil, updatedAt: Int?,
             status: ThreadStatusEnvelope? = nil, isSubAgent: Bool = false, modelProvider: String? = nil) {
            self.id = id
            self.cwd = cwd
            self.path = path
            self.source = source
            self.name = name
            self.preview = preview
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.status = status
            self.isSubAgent = isSubAgent
            self.modelProvider = modelProvider
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(String.self, forKey: .id)
            self.cwd = try? c.decodeIfPresent(String.self, forKey: .cwd)
            self.path = try? c.decodeIfPresent(String.self, forKey: .path)
            self.name = try? c.decodeIfPresent(String.self, forKey: .name)
            self.preview = try? c.decodeIfPresent(String.self, forKey: .preview)
            self.createdAt = (try? c.decodeIfPresent(JSON.self, forKey: .createdAt))?.intValue
            self.updatedAt = (try? c.decodeIfPresent(JSON.self, forKey: .updatedAt))?.intValue
            self.status = try? c.decodeIfPresent(ThreadStatusEnvelope.self, forKey: .status)
            let rawSource = try? c.decodeIfPresent(JSON.self, forKey: .source)
            self.source = rawSource?.stringValue
            let parent = try? c.decodeIfPresent(String.self, forKey: .parentThreadId)
            self.isSubAgent = parent != nil || rawSource?.objectValue != nil
            self.modelProvider = (try? c.decodeIfPresent(String.self, forKey: .modelProvider)) ?? nil
        }

        var displayTitle: String {
            if let n = name, !n.isEmpty { return n }
            if let p = preview, !p.isEmpty {
                let trimmed = p.prefix(60)
                return String(trimmed)
            }
            return String(id.prefix(8))
        }
    }

    struct ThreadStatusEnvelope: Codable, Equatable {
        /// Internally tagged: "notLoaded" | "idle" | "systemError" | "active".
        let type: String?
        /// Only on `active`: e.g. "waitingOnApproval", "waitingOnUserInput".
        let activeFlags: [String]?
    }

    struct ThreadReadParams: Codable {
        let threadId: String
        /// Don't ship the whole turn history back; we only need the metadata.
        let includeTurns: Bool?

        init(threadId: String, includeTurns: Bool? = false) {
            self.threadId = threadId
            self.includeTurns = includeTurns
        }
    }

    struct ThreadReadResult: Decodable {
        let thread: ThreadSummary?
    }

    // MARK: Server → client requests

    /// Methods of server requests Page knows how to answer. Everything else
    /// (`item/tool/requestUserInput`, MCP elicitations, auth refresh, ...)
    /// gets a -32601 so the server never waits on us.
    enum ServerRequestMethod {
        static let commandExecutionApproval = "item/commandExecution/requestApproval"
        static let fileChangeApproval = "item/fileChange/requestApproval"
    }

    /// Response body for the two approval requests above.
    struct ApprovalResponse: Codable, Equatable {
        /// "accept" | "acceptForSession" | "decline" | "cancel"
        let decision: String
    }

    /// A JSON-RPC id. Our own requests use integers, but the server is free
    /// to use strings for its requests, and the reply must echo the id
    /// exactly as received.
    enum RequestID: Hashable, Codable, CustomStringConvertible {
        case int(Int64)
        case string(String)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let v = try? c.decode(Int64.self) { self = .int(v); return }
            if let v = try? c.decode(String.self) { self = .string(v); return }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "JSON-RPC id must be an integer or a string")
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .int(let v): try c.encode(v)
            case .string(let v): try c.encode(v)
            }
        }

        init?(json: JSON) {
            switch json {
            case .int(let v): self = .int(v)
            case .string(let v): self = .string(v)
            case .double(let d) where d == d.rounded(): self = .int(Int64(d))
            default: return nil
            }
        }

        var description: String {
            switch self {
            case .int(let v): return String(v)
            case .string(let v): return v
            }
        }
    }

    // MARK: Inbound classification

    /// Every line the server writes, classified. Kept pure so the routing
    /// rules are unit-tested rather than discovered in production.
    enum InboundMessage: Equatable {
        /// Reply to one of our requests.
        case response(id: RequestID, result: JSON, error: RPCError?)
        /// The server is asking *us* something and waits for a reply.
        case serverRequest(id: RequestID, method: String, params: JSON)
        case notification(method: String, params: JSON)
        case invalid(reason: String)

        private struct Envelope: Decodable {
            let id: RequestID?
            let method: String?
            let params: JSON?
            let result: JSON?
            let error: RPCError?
        }

        static func classify(_ line: Data) -> InboundMessage {
            let envelope: Envelope
            do {
                envelope = try JSONDecoder().decode(Envelope.self, from: line)
            } catch {
                return .invalid(reason: "undecodable envelope")
            }
            // `method` decides first: a server request carries an id too, and
            // treating it as a response would either drop it or resolve an
            // unrelated in-flight call whose integer id happens to collide.
            switch (envelope.id, envelope.method) {
            case let (id?, method?):
                return .serverRequest(id: id, method: method, params: envelope.params ?? .null)
            case let (nil, method?):
                return .notification(method: method, params: envelope.params ?? .null)
            case let (id?, nil):
                return .response(id: id, result: envelope.result ?? .null, error: envelope.error)
            case (nil, nil):
                return .invalid(reason: envelope.error != nil ? "error without id" : "no id and no method")
            }
        }
    }

    // MARK: Errors

    /// `-32001` is "server overloaded, retry later" per the protocol docs.
    /// We back off and retry on this specifically.
    static let errorCodeServerOverloaded = -32001
    /// Standard JSON-RPC "method not found" — our answer to server requests
    /// Page doesn't implement.
    static let errorCodeMethodNotFound = -32601

    struct RPCError: Codable, Error, Equatable {
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

        /// Nested lookup that never traps: `json["status", "type"].stringValue`.
        subscript(path: String...) -> JSON {
            var node = self
            for key in path {
                guard case .object(let dict) = node, let next = dict[key] else { return .null }
                node = next
            }
            return node
        }

        /// First present (non-null) key among `keys` — for fields Codex spells
        /// in snake_case in rollouts and camelCase over the protocol.
        func first(_ keys: String...) -> JSON {
            for key in keys {
                let v = self[key]
                if v != .null { return v }
            }
            return .null
        }

        var isNull: Bool { self == .null }
        var stringValue: String? { if case .string(let s) = self { return s }; return nil }
        var intValue: Int? {
            switch self {
            case .int(let v): return Int(v)
            case .double(let v) where v.isFinite: return Int(v)
            default: return nil
            }
        }
        var doubleValue: Double? {
            switch self {
            case .int(let v): return Double(v)
            case .double(let v): return v
            default: return nil
            }
        }
        var arrayValue: [JSON]? { if case .array(let a) = self { return a }; return nil }
        var objectValue: [String: JSON]? { if case .object(let o) = self { return o }; return nil }
    }

    /// Decodes `T` or yields nil, so one bad element can't fail an array.
    struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws {
            value = try? T(from: decoder)
        }
    }
}
