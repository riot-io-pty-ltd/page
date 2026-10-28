import Foundation

/// Where sealed live-sessions updates go: the relay socket. Thread-safe;
/// `sendSessionsUpdate` drops the frame when the socket is down (never
/// queued, see `RelayClient.sendSessionsUpdate`).
protocol SessionsUpdateSink: AnyObject {
    var isConnected: Bool { get }
    func sendSessionsUpdate(_ envelope: SessionEnvelope)
}

/// Where a session runs, as the phone's list shows it.
struct SessionHostInfo: Equatable {
    /// Wire value: "cmux" | "tmux" | "Claude Squad" | "Terminal" | "iTerm" |
    /// "Ghostty" | "VS Code" | "desktop" | "unknown".
    var host: String
    var canType: Bool
    /// Why not, when `canType` is false (shown instead of the composer).
    var typeBlocker: String?
    var canInterrupt: Bool
    var provider: ModelProvider = .unknown

    /// Not probed yet.
    static let checking = SessionHostInfo(host: "unknown", canType: false,
                                          typeBlocker: "Checking where this session runs…", canInterrupt: false)

    static func blocked(_ host: String, _ why: String, provider: ModelProvider = .unknown) -> SessionHostInfo {
        SessionHostInfo(host: host, canType: false, typeBlocker: why, canInterrupt: false, provider: provider)
    }
}

struct SessionTranscriptFile: Equatable {
    let path: String
    let format: SessionTranscript.Format
}

/// What `SessionRemote` needs from the agent backends. The live
/// implementation is `LiveSessionBackends`; tests use a fake.
protocol SessionRemoteBackends: AnyObject {
    /// Where each session runs. Blocking (ps, tmux, lsof); called only on
    /// the probe queue, only while a phone is looking.
    func probeHosts(_ sessions: [AgentSession]) -> [String: SessionHostInfo]
    /// Fresh Claude statuses by session id (one small file read each), so
    /// the list doesn't lag a long check interval.
    func liveStatuses(_ sessions: [AgentSession]) -> [String: ClaudeSessionStatus]
    func transcriptFile(for session: AgentSession) -> SessionTranscriptFile?
    /// Where the session's screen can be read (tmux / cmux only), or nil.
    /// Blocking; called only on the probe queue, only for a watched session.
    func screenSource(for session: AgentSession) -> SessionScreen.Source?
    /// The screen's text, or nil. Blocking, as above.
    func readScreen(_ source: SessionScreen.Source) -> String?
    /// Runs the input gate and delivers, on the backend's own queue.
    /// `completion` may run on any queue.
    func input(_ session: AgentSession, clientId: String, text: String, interventionId: String?,
               completion: @escaping (SessionCommandResult) -> Void)
    func interrupt(_ session: AgentSession, interventionId: String?,
                   completion: @escaping (SessionCommandResult) -> Void)
    /// Answers the session's pending AskUserQuestion dialog (`AnswerDelivery`):
    /// the keys, each after a screen check. `completion` may run on any queue.
    func answer(_ session: AgentSession, request: AnswerRequest,
                completion: @escaping (SessionCommandResult) -> Void)
    /// Folders a phone may start a session in (`SessionStarter`).
    /// Blocking; probe queue only.
    func knownFolders(live: [AgentSession]) -> [SessionStarter.Folder]
    /// Starts a session. Blocking; probe queue only.
    func startSession(folder: SessionStarter.Folder, prompt: String) -> SessionCommandResult
    /// What a working session's card shows: its last steps and model, when its
    /// turn and the session began, the workflows running in it. Blocking; probe
    /// queue only (one caller at a time). Defaults to nothing.
    func flightFacts(_ sessions: [AgentSession]) -> [String: InFlightFacts]
    /// Types a held message (`hold-v1`) now that the turn looks over: the
    /// input gate, refusing anything but an idle session (`busy`, never
    /// queued behind a turn, never into a prompt), with `claim.commit()` right
    /// before the keys. `completion` may run on any queue.
    func typeHeld(_ session: AgentSession, clientId: String, text: String, claim: HeldClaim,
                  completion: @escaping (SessionCommandResult) -> Void)
    /// Takes back a reply a backend is holding for relay page `interventionId`
    /// (`retract-v1`): locks only, safe on the sessions queue.
    func retractReply(interventionId: String) -> HeldRetract
    /// Sends photos with a caption (`images-v1`, `ImageDelivery`), on the
    /// backend's own queue. `completion` may run on any queue.
    func inputImages(_ session: AgentSession, clientId: String, images: [AssembledImage], text: String,
                     interventionId: String?, completion: @escaping (SessionCommandResult) -> Void)
}

extension SessionRemoteBackends {
    func flightFacts(_ sessions: [AgentSession]) -> [String: InFlightFacts] { [:] }
}

/// One phone → Mac command, decrypted (SESSIONS-PROTOCOL.md §5).
struct SessionCommand: Equatable {
    let op: String
    let clientId: String
    /// ms since 1970, phone clock.
    let ts: Double
    let viewer: String?
    let sessionId: String?
    let text: String?
    /// `watch` only: a workflow agent inside the session (safe ids only).
    var runId: String? = nil
    var agentId: String? = nil
    /// `start` only: the folder to start in (checked against the list).
    var folder: String? = nil
    /// `input` and `interrupt`: the folder and title the phone's room showed,
    /// verbatim as this Mac listed them. Optional (older phones omit them);
    /// `SessionTargetCheck` refuses when they no longer match the session.
    var expectCwd: String? = nil
    var expectTitle: String? = nil
    /// `answer` only: the tool_use id of the question the phone showed, and its answers.
    var promptKey: String? = nil
    var answers: [AnswerPick]? = nil
    /// `input` only (`hold-v1`): type it once the session's turn ends.
    var hold = false
    /// `retract` only (`retract-v1`): the held `input`'s clientId, or the
    /// relay page whose reply the Mac is holding. Exactly one of the two.
    var heldId: String? = nil
    var interventionId: String? = nil
    /// `imagePart` only (`images-v1`): one piece of a photo.
    var imagePart: ImagePart? = nil
    /// `inputImages` only (`images-v1`): the photos the message carries
    /// (nil when absent or malformed: the whole list is dropped).
    var images: [ImageRef]? = nil
    /// Typed or clicked at this Mac (`SessionRemote.performLocal`), never
    /// parsed from the wire: `parse` cannot set it, so a phone command can
    /// never claim to be local.
    var local: Bool = false

    static let maxIdLength = 128

    /// nil unless the plaintext has a string `op`, a non-empty `clientId`
    /// and a numeric `ts`. Unknown fields are ignored.
    static func parse(_ data: Data) -> SessionCommand? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = obj["op"] as? String,
              let clientId = obj["clientId"] as? String, !clientId.isEmpty, clientId.count <= maxIdLength,
              let ts = (obj["ts"] as? NSNumber)?.doubleValue, ts.isFinite else { return nil }
        let viewer = (obj["viewer"] as? String).flatMap { $0.isEmpty || $0.count > maxIdLength ? nil : $0 }
        let sessionId = (obj["sessionId"] as? String).flatMap { $0.isEmpty || $0.count > 256 ? nil : $0 }
        var cmd = SessionCommand(op: op, clientId: clientId, ts: ts, viewer: viewer, sessionId: sessionId,
                                 text: obj["text"] as? String)
        cmd.runId = (obj["runId"] as? String).flatMap { SessionWorkflows.isSafeId($0) ? $0 : nil }
        cmd.agentId = (obj["agentId"] as? String).flatMap { SessionWorkflows.isSafeId($0) ? $0 : nil }
        cmd.folder = (obj["folder"] as? String).flatMap { $0.isEmpty || $0.count > 1024 ? nil : $0 }
        cmd.expectCwd = (obj["expectCwd"] as? String).flatMap { $0.isEmpty || $0.count > 1024 ? nil : $0 }
        cmd.expectTitle = (obj["expectTitle"] as? String).flatMap { $0.isEmpty || $0.count > 1024 ? nil : $0 }
        cmd.promptKey = (obj["promptKey"] as? String).flatMap { $0.isEmpty || $0.count > maxIdLength ? nil : $0 }
        cmd.answers = AnswerRequest.parseAnswers(obj["answers"])
        cmd.hold = obj["hold"] as? Bool == true
        cmd.heldId = (obj["heldId"] as? String).flatMap { $0.isEmpty || $0.count > maxIdLength ? nil : $0 }
        cmd.interventionId = (obj["interventionId"] as? String).flatMap { $0.isEmpty || $0.count > 256 ? nil : $0 }
        switch op {
        case "imagePart": cmd.imagePart = ImagePart.parse(obj)
        case "inputImages": cmd.images = ImageRef.parseList(obj["images"])
        default: break
        }
        return cmd
    }
}

extension SessionRemoteBackends {
    func answer(_ session: AgentSession, request: AnswerRequest, completion: @escaping (SessionCommandResult) -> Void) {
        completion(.refused(.answerUnsupported, "Answering questions isn't available here"))
    }
    func knownFolders(live: [AgentSession]) -> [SessionStarter.Folder] { [] }
    func startSession(folder: SessionStarter.Folder, prompt: String) -> SessionCommandResult {
        .refused(.notTypable, "Starting sessions isn't available")
    }
    func screenSource(for session: AgentSession) -> SessionScreen.Source? { nil }
    func readScreen(_ source: SessionScreen.Source) -> String? { SessionScreen.read(source) }
    func typeHeld(_ session: AgentSession, clientId: String, text: String, claim: HeldClaim,
                  completion: @escaping (SessionCommandResult) -> Void) {
        completion(.refused(.notTypable, "Page can't hold messages for this session"))
    }
    func retractReply(interventionId: String) -> HeldRetract { .notFound }
    func inputImages(_ session: AgentSession, clientId: String, images: [AssembledImage], text: String,
                     interventionId: String?, completion: @escaping (SessionCommandResult) -> Void) {
        completion(.refused(.attachUnsupported, "Page can't send photos to this session"))
    }
}

/// Client ids seen in the last 15 minutes (at most 2000): a replayed
/// command is dropped, never acted on twice. With a `storeURL` the ids are
/// also kept on disk, so a command captured by the relay (or by anyone with
/// the token) can't be replayed after Page restarts inside the freshness
/// window. Only ids and times are stored, never command content.
struct SessionReplayGuard {
    static let window: TimeInterval = 15 * 60
    static let capacity = 2000

    private var seen: [String: Date] = [:]
    private var order: [String] = []
    private let storeURL: URL?

    var count: Int { seen.count }

    init(storeURL: URL? = nil, now: Date = Date()) {
        self.storeURL = storeURL
        guard let storeURL, let data = BoundedFileRead.read(storeURL.path, maxBytes: 256 * 1024),
              let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Double] else { return }
        for (id, at) in stored.sorted(by: { $0.value < $1.value }) {
            let date = Date(timeIntervalSince1970: at)
            guard now.timeIntervalSince(date) <= Self.window, !id.isEmpty, id.count <= SessionCommand.maxIdLength else { continue }
            seen[id] = date
            order.append(id)
        }
        while order.count > Self.capacity { seen.removeValue(forKey: order.removeFirst()) }
    }

    /// True (and remembers `clientId`) the first time; false for a replay.
    mutating func admit(_ clientId: String, now: Date) -> Bool {
        while let oldest = order.first, let at = seen[oldest], now.timeIntervalSince(at) > Self.window {
            order.removeFirst()
            seen.removeValue(forKey: oldest)
        }
        guard seen[clientId] == nil else { return false }
        seen[clientId] = now
        order.append(clientId)
        while order.count > Self.capacity { seen.removeValue(forKey: order.removeFirst()) }
        persist()
        return true
    }

    /// Atomic 0600 write. A failed write only weakens the guard across a
    /// restart; it never blocks a command.
    private func persist() {
        guard let storeURL else { return }
        let obj = seen.mapValues { $0.timeIntervalSince1970 }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        let tmp = storeURL.deletingLastPathComponent().appendingPathComponent(".\(storeURL.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(tmp.path, storeURL.path) != 0 { try? FileManager.default.removeItem(at: tmp) }
    }
}

/// Which session each phone viewer is looking at, each for 90 s unless
/// re-sent (the phone re-sends every 30 s while the screen is open).
struct SessionWatchers {
    static let ttl: TimeInterval = 90
    static let maxViewers = 32

    /// A workflow agent the viewer opened inside a session.
    struct AgentRef: Hashable {
        let sessionId: String
        let runId: String
        let agentId: String
    }

    private var byViewer: [String: (sessionId: String, agent: AgentRef?, expires: Date)] = [:]

    /// `runId` + `agentId` (both safe ids, else ignored): the viewer is on
    /// that workflow agent's screen rather than the session's.
    mutating func set(viewer: String, sessionId: String?, runId: String? = nil, agentId: String? = nil, now: Date) {
        guard let sessionId else {
            byViewer.removeValue(forKey: viewer)
            return
        }
        var agent: AgentRef?
        if let runId, let agentId, SessionWorkflows.isSafeId(runId), SessionWorkflows.isSafeId(agentId) {
            agent = AgentRef(sessionId: sessionId, runId: runId, agentId: agentId)
        }
        byViewer[viewer] = (sessionId, agent, now.addingTimeInterval(Self.ttl))
        if byViewer.count > Self.maxViewers, let oldest = byViewer.min(by: { $0.value.expires < $1.value.expires })?.key {
            byViewer.removeValue(forKey: oldest)
        }
    }

    mutating func prune(now: Date) {
        byViewer = byViewer.filter { $0.value.expires > now }
    }

    func session(forViewer viewer: String, now: Date) -> String? {
        guard let w = byViewer[viewer], w.expires > now else { return nil }
        return w.sessionId
    }

    /// Sessions a viewer has open (its transcript, screen and workflows).
    func watched(now: Date) -> Set<String> {
        Set(byViewer.values.filter { $0.expires > now && $0.agent == nil }.map(\.sessionId))
    }

    /// Sessions whose workflows someone is looking at: on the session's
    /// screen or inside one of its agents.
    func watchedAny(now: Date) -> Set<String> {
        Set(byViewer.values.filter { $0.expires > now }.map(\.sessionId))
    }

    func agents(now: Date) -> Set<AgentRef> {
        Set(byViewer.values.filter { $0.expires > now }.compactMap(\.agent))
    }

    func agent(forViewer viewer: String, now: Date) -> AgentRef? {
        guard let w = byViewer[viewer], w.expires > now else { return nil }
        return w.agent
    }
}

/// When to send (pure; SESSIONS-PROTOCOL.md §4, §7).
enum SessionsSchedule {
    static let listThrottle: TimeInterval = 1
    static let liveness: TimeInterval = 20
    static let transcriptThrottle: TimeInterval = 1.5

    /// Nothing while no phone is looking. Otherwise: the first list right
    /// away, a changed list at most once a second, and the same list again
    /// every 20 s.
    static func listDue(phones: Int, changed: Bool, lastSentAt: Date?, now: Date) -> Bool {
        guard phones > 0 else { return false }
        guard let last = lastSentAt else { return true }
        let since = now.timeIntervalSince(last)
        return since >= liveness || (changed && since >= listThrottle)
    }

    /// A watched session's screen is re-read at most every 2.5 s, never
    /// while a read is still running.
    static func screenDue(phones: Int, lastCheckedAt: Date?, reading: Bool, now: Date) -> Bool {
        guard phones > 0, !reading else { return false }
        guard let last = lastCheckedAt else { return true }
        return now.timeIntervalSince(last) >= SessionScreen.interval
    }

    /// A watched session's transcript is re-checked at most every 1.5 s.
    static func transcriptDue(phones: Int, lastCheckedAt: Date?, now: Date) -> Bool {
        guard phones > 0 else { return false }
        guard let last = lastCheckedAt else { return true }
        return now.timeIntervalSince(last) >= transcriptThrottle
    }
}

/// What the Mac does with an incoming `sessions.command` envelope, decided
/// in the spec's order (§5 Acceptance).
enum SessionCommandAcceptance: Equatable {
    /// Dropped without a reply; the string is for the log (no content).
    case drop(String)
    case reply(clientId: String, SessionCommandResult)
    case accept(SessionCommand)
}

/// One row of the phone's list (SESSIONS-PROTOCOL.md §4 `list`).
struct RemoteSessionRow: Equatable {
    let id: String
    let backend: String
    let title: String
    let cwd: String?
    let state: AgentSessionState
    let host: SessionHostInfo
    let lastActivityAt: Date?
    let interventionId: String?
    let preview: String?
    /// The pending AskUserQuestion, when the session is waiting on one the
    /// phone can answer. Its presence is also how a phone knows this Mac
    /// accepts `answer`.
    var ask: AskedQuestionSet? = nil
    /// Optional fields of a working session (busySince, startedAt, model,
    /// recentSteps, workflows, health…): see `InFlightWire`.
    var working: WireFields? = nil
    /// Messages held until the turn ends, and recent outcomes (`hold-v1`).
    var held: WireList? = nil
    /// Page can type into this session's terminal once the turn ends, so the
    /// phone may offer "Send when it finishes" (`hold-v1`), even where
    /// `canType` is false only because Codex is mid-turn outside cmux.
    var canHold = false
    /// How a photo from the phone would reach this session (`images-v1`):
    /// "image" (attached) or "path" (its location typed). nil: no photo button.
    var attach: String? = nil
    /// Why not, when the row can be typed into but takes no photos.
    var attachBlocker: String? = nil

    var jsonObject: [String: Any] {
        var o: [String: Any] = [
            "id": id, "backend": backend, "title": title, "state": state.rawValue,
            "host": host.host, "canType": host.canType, "canInterrupt": host.canInterrupt,
            "provider": host.provider.rawValue
        ]
        if let cwd { o["cwd"] = cwd }
        if !host.canType { o["typeBlocker"] = host.typeBlocker ?? "Page can't type into this session" }
        if let lastActivityAt { o["lastActivityAt"] = SessionTranscript.isoFormatter.string(from: lastActivityAt) }
        if let interventionId { o["interventionId"] = interventionId }
        if let preview, !preview.isEmpty { o["preview"] = preview }
        if let ask { o["ask"] = ask.phoneObject }
        if let held { o["held"] = held.items }
        if canHold { o["canHold"] = true }
        if let attach { o["attach"] = attach }
        if let attachBlocker { o["attachBlocker"] = attachBlocker }
        // Added keys never replace one the row already has.
        if let working { o.merge(working.object) { mine, _ in mine } }
        return o
    }
}

/// A JSON-ready list in a row; equal when its JSON is.
struct WireList: Equatable {
    let items: [[String: Any]]

    /// nil for an empty list.
    init?(_ items: [[String: Any]]) {
        guard !items.isEmpty else { return nil }
        self.items = items
    }

    static func == (a: WireList, b: WireList) -> Bool {
        func bytes(_ o: [[String: Any]]) -> Data? { try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) }
        return bytes(a.items) == bytes(b.items)
    }
}

/// JSON-ready optional fields of a list row; equal when their JSON is.
struct WireFields: Equatable {
    let object: [String: Any]

    /// nil for no fields at all.
    init?(_ object: [String: Any]) {
        guard !object.isEmpty else { return nil }
        self.object = object
    }

    static func == (a: WireFields, b: WireFields) -> Bool {
        func bytes(_ o: [String: Any]) -> Data? { try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) }
        return bytes(a.object) == bytes(b.object)
    }
}

/// The Mac side of the phone's **Active sessions** view
/// (docs/SESSIONS-PROTOCOL.md): sends the encrypted session list and the
/// transcripts phones are watching, and acts on the phone's encrypted
/// commands through the input gate.
///
/// Only while someone is looking: nothing is built or sent while the
/// Worker reports no phone socket (old Workers never report one, so they
/// never see the feature). Host probes (ps, tmux, lsof) run on their own
/// queue and are cached per session; transcripts are read bounded and
/// cached by size and mtime. Nothing here ever runs on the Coordinator's
/// tick queue: the tick only hands over a value copy of the sessions.
///
/// Logs carry a session id prefix, the op, the outcome and lengths —
/// never titles, paths, transcript text or typed text.
///
/// Threading: all state is confined to `queue`. Public methods may be
/// called from any thread and never block.
final class SessionRemote {
    static let maxSessions = 100
    static let freshness: TimeInterval = 5 * 60
    static let hostTTL: TimeInterval = 30
    static let stepInterval: TimeInterval = 0.5
    /// A session's preview is re-read at most this often.
    static let previewInterval: TimeInterval = 2
    static let liveStatusInterval: TimeInterval = 1
    /// A working session's card facts are re-read at most this often.
    static let flightInterval: TimeInterval = 4
    static let maxTitle = 200
    static let maxCwd = 500
    /// The list plaintext's budget: sealed and base64url-encoded (×4/3 plus
    /// the envelope) it stays under the Worker's 256 KiB frame limit.
    static let maxListPlaintextBytes = 180 * 1024
    /// The list header's `caps`: what this Mac accepts beyond the base ops
    /// (SESSIONS-PROTOCOL.md §4). Features append their name here.
    static let capabilities = ["hold-v1", "retract-v1", "images-v1"]
    /// Held sessions' state is re-read this often while anything is held.
    static let outboxInterval: TimeInterval = 2
    /// How long an `inputImages` waits for its photos' last pieces (`images-v1`).
    static let imagePartWait: TimeInterval = 3
    /// Photos written for Claude are cleaned up this often (and on the first tick).
    static let imageCleanupInterval: TimeInterval = 3600

    let boot: String
    private let backends: SessionRemoteBackends
    private let now: () -> Date
    private let autoTimer: Bool
    private let queue = DispatchQueue(label: "ClaudePowerMode.sessions", qos: .utility)
    private let probeQueue = DispatchQueue(label: "ClaudePowerMode.sessions.probe", qos: .utility)
    private let macNameProvider: () -> String
    /// Claude sessions a Page hook is holding right now (see `HookHoldMarkers`).
    private let heldSessions: () -> Set<String>

    // Confined to `queue`.
    private var sink: SessionsUpdateSink?
    private var keys: SessionKeys?
    private var enabled = true
    /// "Let my phone start sessions" (off by default).
    private var startEnabled = false
    private var phones = 0
    private var sessions: [AgentSession] = []
    private var pending: [InterventionEvent] = []
    private var statuses: [String: ClaudeSessionStatus] = [:]
    private var statusesAt: Date?
    private var hosts: [String: (info: SessionHostInfo, at: Date)] = [:]
    private var probing = false
    /// What each working session's card shows, re-read every `flightInterval`
    /// while a phone is looking (probe queue), and the stuck watch's and rate
    /// limit's word on each session (from the tick).
    private var flightFacts: [String: InFlightFacts] = [:]
    private var flightChecked: Date?
    private var flightProbing = false
    private var rateLimited: [String: Date] = [:]
    private var previews: [String: (stamp: FileStamp?, checkedAt: Date, entries: [SessionTranscriptEntry])] = [:]
    private var transcripts: [String: (stamp: FileStamp, snapshot: SessionTranscript.Snapshot)] = [:]
    private var watchers = SessionWatchers()
    private var replay: SessionReplayGuard
    private var seq: Int64 = 0
    private var lastListAt: Date?
    private var lastListBody: Data?
    /// The pending question per waiting Claude session, by transcript stamp.
    private var asks: [String: (stamp: FileStamp, ask: AskedQuestionSet?)] = [:]
    private var lastTranscriptCheck: [String: Date] = [:]
    private var lastTranscriptBody: [String: Data] = [:]
    private var screenSources: [String: (source: SessionScreen.Source?, at: Date)] = [:]
    private var lastScreenCheck: [String: Date] = [:]
    private var lastScreenBody: [String: [String]] = [:]
    private var screensReading = Set<String>()
    private let workflowScanner = SessionWorkflowScanner()   // probe queue only
    private var lastWorkflowCheck: [String: Date] = [:]
    private var lastWorkflowBody: [String: Data] = [:]
    private var workflowsReading = Set<String>()
    /// Sessions whose next workflows read is sent even if empty or unchanged
    /// (just watched: the phone may hold an older list).
    private var workflowsResync = Set<String>()
    /// Each read session's transcript, so its scan state can be dropped.
    private var workflowTranscript: [String: String] = [:]
    private var lastAgentCheck: [SessionWatchers.AgentRef: Date] = [:]
    private var lastAgentBody: [SessionWatchers.AgentRef: Data] = [:]
    private var lastAgentStamp: [SessionWatchers.AgentRef: FileStamp] = [:]
    private var timer: DispatchSourceTimer?
    private var macName: String?
    private var stopped = false
    /// Where the result of a `performLocal` command goes (confined to `queue`).
    private var localResponders: [String: (SessionCommandResult) -> Void] = [:]
    /// Messages held until their session's turn ends (`hold-v1`), saved to
    /// `outboxStore` on every change. Worked on whether or not a phone is looking.
    private var outbox: HeldOutbox
    private let outboxStore: HeldOutboxStore?
    private var outboxTimer: DispatchSourceTimer?
    /// The panel's copy of the held messages (any thread, under `heldLock`).
    private let heldLock = NSLock()
    private var heldShared: [HeldMessageInfo] = []
    private var _onHeldChanged: (() -> Void)?
    /// Photos arriving in pieces (`images-v1`), and the `inputImages`
    /// commands waiting (at most `imagePartWait`) for their last pieces.
    private var images = ImageAssembler()
    private var imageWaits: [String: ImageWait] = [:]
    private let imagePartWait: TimeInterval
    /// Where photos are written for Claude (nil in tests: nothing is cleaned or wiped).
    private let imageStore: ImageStore?
    private var imageCleanedAt: Date?

    private struct ImageWait {
        let cmd: SessionCommand
        let refs: [ImageRef]
        let sessionId: String
        let text: String
    }

    struct FileStamp: Equatable {
        let size: UInt64
        let mtime: Date
    }

    /// `autoTimer` false (tests) leaves the periodic work to `step()`.
    /// `replayStore`: where seen command ids survive a restart (nil keeps
    /// them in memory only, for tests).
    /// `outboxStore`: where held messages survive a restart (nil keeps them
    /// in memory only, for tests).
    /// `imageStore`: the folder photos from the phone are written to, cleaned
    /// up hourly and wiped when the pairing changes (nil: left alone, for tests).
    init(backends: SessionRemoteBackends, now: @escaping () -> Date = Date.init, autoTimer: Bool = true,
         macName: @escaping () -> String = { Host.current().localizedName ?? "Mac" }, replayStore: URL? = nil,
         outboxStore: URL? = nil, imageStore: ImageStore? = nil, imagePartWait: TimeInterval = SessionRemote.imagePartWait,
         heldSessions: @escaping () -> Set<String> = { HookHoldMarkers.heldSessions(in: HookHoldMarkers.defaultDirectory) }) {
        self.heldSessions = heldSessions
        self.imageStore = imageStore
        self.imagePartWait = imagePartWait
        self.backends = backends
        self.replay = SessionReplayGuard(storeURL: replayStore, now: now())
        self.now = now
        self.autoTimer = autoTimer
        self.macNameProvider = macName
        let store = outboxStore.map(HeldOutboxStore.init(url:))
        self.outboxStore = store
        self.outbox = store?.load(now: now()) ?? HeldOutbox()
        var bytes = [UInt8](repeating: 0, count: 8)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<8).map { _ in UInt8.random(in: 0...255) }
        }
        boot = SessionCrypto.base64URLEncode(Data(bytes))
        if !outbox.isEmpty || !outbox.settled.isEmpty {
            Logger.shared.log("Sessions: \(outbox.messages.count) held message(s) restored")
            // A try that was under way when Page quit settled as unconfirmed: save that.
            store?.save(outbox)
        }
        queue.async {
            self.publishHeld()
            self.updateOutboxTimer()
        }
    }

    // MARK: inputs (any thread)

    /// The relay client (or nil when the relay is off) and the pairing's
    /// root key. A new client hasn't reported any phones yet.
    func attach(sink: SessionsUpdateSink?, rootKey: Data?) {
        queue.async {
            self.sink = sink
            self.keys = rootKey.flatMap(SessionKeys.init(root:))
            if sink != nil && self.keys == nil { Logger.shared.log("Sessions: no session key — the live sessions view is off") }
            if let rootKey, self.keys != nil {
                let before = self.outbox.keyTag
                let dropped = self.outbox.adopt(keyTag: HeldOutbox.keyTag(root: rootKey))
                if dropped > 0 { Logger.shared.log("Sessions: the pairing changed — dropped \(dropped) held message(s) untyped") }
                if self.outbox.keyTag != before {
                    self.outboxChanged()
                    // A new pairing: photos from the old phone go too, received or half-received.
                    if before != nil { self.forgetImages() }
                }
            }
            self.setPhonesLocked(0)
        }
    }

    /// Called (on any queue, never under a lock) when the held messages change.
    var onHeldChanged: (() -> Void)? {
        get { heldLock.lock(); defer { heldLock.unlock() }; return _onHeldChanged }
        set { heldLock.lock(); _onHeldChanged = newValue; heldLock.unlock() }
    }

    /// The messages held until their turn ends, for the Mac's panel. Any thread.
    func heldMessages() -> [HeldMessageInfo] {
        heldLock.lock()
        defer { heldLock.unlock() }
        return heldShared
    }

    func setEnabled(_ on: Bool) {
        queue.async {
            guard self.enabled != on else { return }
            self.enabled = on
            Logger.shared.log("Sessions: live sessions view \(on ? "enabled" : "disabled")")
            self.lastListBody = nil   // re-send at once in the new form
        }
    }

    func setStartEnabled(_ on: Bool) {
        queue.async {
            guard self.startEnabled != on else { return }
            self.startEnabled = on
            Logger.shared.log("Sessions: starting sessions from the phone \(on ? "enabled" : "disabled")")
        }
    }

    /// `phones.status` from the Worker, via `sink`. Ignored from a client
    /// that has since been replaced (its frames can land late).
    func setPhones(_ n: Int, from sink: SessionsUpdateSink) {
        queue.async {
            guard self.sink === sink else { return }
            self.setPhonesLocked(max(0, n))
        }
    }

    /// `sink`'s socket went up or down. Down means no phone can see us.
    func connectionChanged(_ connected: Bool, from sink: SessionsUpdateSink) {
        guard !connected else { return }
        queue.async {
            guard self.sink === sink else { return }
            self.setPhonesLocked(0)
        }
    }

    /// The merged sessions and open pages after a tick (value copies).
    /// `rateLimited`: session id → when its rate limit resets.
    func update(sessions: [AgentSession], pending: [InterventionEvent], rateLimited: [String: Date] = [:]) {
        queue.async {
            self.sessions = sessions
            self.pending = pending
            self.rateLimited = rateLimited
            self.flightFacts = self.flightFacts.filter { id, _ in sessions.contains { $0.sessionId == id } }
            let ids = Set(sessions.map(\.sessionId))
            self.hosts = self.hosts.filter { ids.contains($0.key) }
            self.previews = self.previews.filter { ids.contains($0.key) }
            self.statuses = self.statuses.filter { ids.contains($0.key) }
            self.lastTranscriptCheck = self.lastTranscriptCheck.filter { ids.contains($0.key) }
            self.lastTranscriptBody = self.lastTranscriptBody.filter { ids.contains($0.key) }
            // A fresh list: held messages may be due, or their session gone.
            self.drainOutbox(tick: true)
            self.cleanImagesIfDue()
        }
    }

    func handleCommand(_ envelope: SessionEnvelope) {
        queue.async { self.handleCommandLocked(envelope) }
    }

    /// A command from this Mac's own UI (the menu-bar panel): the same
    /// `perform` the phone's sealed commands reach, so it goes through the
    /// same gates and the same backend calls. There is no envelope to check
    /// (nothing crossed the relay), and the result comes back to `completion`
    /// instead of being sealed for a phone. Only ops that answer with a
    /// result ("input", "answer", "interrupt", "interruptAll", "start", "retract")
    /// belong here. A local `input` never holds: it is typed at once.
    func performLocal(_ cmd: SessionCommand, completion: @escaping (SessionCommandResult) -> Void) {
        queue.async {
            guard !self.stopped else {
                completion(.refused(.error, "Page is shutting down"))
                return
            }
            var local = cmd
            local.local = true
            self.localResponders[local.clientId] = completion
            self.perform(local, at: self.now())
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.timer?.cancel()
            self.timer = nil
            self.outboxTimer?.cancel()
            self.outboxTimer = nil
            self.sink = nil
        }
    }

    /// Runs the periodic work once (tests; production uses the timer).
    func step() {
        queue.sync { self.stepLocked() }
    }

    /// Runs the held-message work once (tests; production uses its timer and
    /// the tick). `tick`: as if a fresh list had just come in.
    func stepOutbox(tick: Bool = false) {
        queue.sync { self.drainOutbox(tick: tick) }
    }

    /// Waits until queued work, including a host probe, has run (tests).
    func waitUntilIdle() {
        queue.sync {}
        probeQueue.sync {}
        queue.sync {}
    }

    // MARK: acceptance (pure)

    /// The spec's order: decrypt (else drop), fresh (else `stale`), not a
    /// replay (else drop), enabled (else `disabled`).
    ///
    /// An `imagePart` (`images-v1`) never gets a `result`: a stale or
    /// disabled piece is dropped silently, and pieces skip the replay guard.
    /// That guard writes its whole table to disk on every id, and a photo's
    /// dozens of piece ids would push genuine commands' ids out while they
    /// are still fresh enough to replay. Pieces are idempotent instead
    /// (`ImageAssembler` keys them by photo and index, and remembers used
    /// photos for 15 minutes); the `inputImages` that uses them goes through
    /// the guard like every other command.
    static func accept(_ envelope: SessionEnvelope, keys: SessionKeys?, enabled: Bool, now: Date,
                       replay: inout SessionReplayGuard) -> SessionCommandAcceptance {
        guard let keys else { return .drop("no session key") }
        guard let plain = SessionCrypto.open(envelope, key: keys.phoneToMac, aad: SessionCrypto.commandAAD) else {
            return .drop("undecryptable")
        }
        guard let cmd = SessionCommand.parse(plain) else { return .drop("malformed") }
        let isPart = cmd.op == "imagePart"
        let age = now.timeIntervalSince1970 - cmd.ts / 1000
        guard abs(age) <= freshness else {
            if isPart { return .drop("stale image part") }
            return .reply(clientId: cmd.clientId, .refused(.stale, "That command is too old — check your phone's clock"))
        }
        if !isPart {
            guard replay.admit(cmd.clientId, now: now) else { return .drop("replay") }
        }
        guard enabled else {
            if isPart { return .drop("image part while disabled") }
            return .reply(clientId: cmd.clientId, .refused(.disabled, "Live sessions are turned off in Page's settings on your Mac"))
        }
        return .accept(cmd)
    }

    // MARK: list (pure parts)

    /// Needs-you first, then working, then most recent activity.
    static func ordered(_ rows: [RemoteSessionRow]) -> [RemoteSessionRow] {
        func rank(_ s: AgentSessionState) -> Int {
            switch s {
            case .waitingOnUser, .waitingOnApproval: return 0
            case .active: return 1
            default: return 2
            }
        }
        return rows.enumerated().sorted { a, b in
            let (ra, rb) = (rank(a.element.state), rank(b.element.state))
            if ra != rb { return ra < rb }
            let (ta, tb) = (a.element.lastActivityAt ?? .distantPast, b.element.lastActivityAt ?? .distantPast)
            if ta != tb { return ta > tb }
            return a.offset < b.offset
        }.map(\.element).prefix(maxSessions).map { $0 }
    }

    /// The list state with a fresh Claude status laid over the tick's.
    static func overlay(_ state: AgentSessionState, fresh: ClaudeSessionStatus?) -> AgentSessionState {
        switch fresh {
        case .busy?: return .active
        case .waiting?: return state == .waitingOnUser || state == .waitingOnApproval ? state : .waitingOnApproval
        case .idle?, .shell?: return state == .active || state == .waitingOnApproval ? .idle : state
        case .unknown?, nil: return state
        }
    }

    /// Codex can only be typed into mid-turn in cmux; elsewhere the phone
    /// says why instead of offering a composer that will be refused.
    static func effectiveHost(_ info: SessionHostInfo, backend: AgentBackendID, state: AgentSessionState) -> SessionHostInfo {
        guard backend == .codex, state == .active, info.canType, info.host != "cmux" else { return info }
        var out = info
        out.canType = false
        out.typeBlocker = SessionInputGate.codexMidTurnMessage
        return out
    }

    /// A session's folder as a title: its last component, except the root
    /// and home folders, whose last component ("/", the user name) says
    /// nothing.
    static func folderTitle(_ cwd: String?, home: String = NSHomeDirectory()) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let trimmed = cwd.count > 1 && cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        if trimmed == "/" { return "/ (root folder)" }
        if !home.isEmpty, home != "/", trimmed == home { return "~ (home folder)" }
        return (trimmed as NSString).lastPathComponent
    }

    static func homeAbbreviated(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    // MARK: periodic work (queue)

    private func setPhonesLocked(_ n: Int) {
        let before = phones
        phones = n
        if n > 0 && before == 0 {
            Logger.shared.log("Sessions: \(n) phone(s) looking — sending the session list")
            lastListAt = nil
            lastListBody = nil
            lastTranscriptCheck = [:]
            lastTranscriptBody = [:]
            startTimer()
            stepLocked()
        } else if n == 0 && before > 0 {
            Logger.shared.log("Sessions: no phone looking — stopped sending")
            timer?.cancel()
            timer = nil
        }
    }

    private func startTimer() {
        guard autoTimer, timer == nil, !stopped else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.stepInterval, repeating: Self.stepInterval, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.stepLocked() }
        t.resume()
        timer = t
    }

    private func stepLocked() {
        guard !stopped, phones > 0, sink != nil, keys != nil else { return }
        let t = now()
        watchers.prune(now: t)
        if enabled {
            refreshStatuses(t)
            probeIfNeeded(t)
            probeFlightIfNeeded(t)
        }
        let rows = enabled ? currentRows(t) : []
        let body = Self.listBody(rows, enabled: enabled)
        if SessionsSchedule.listDue(phones: phones, changed: body != lastListBody, lastSentAt: lastListAt, now: t) {
            sendList(rows, body: body, at: t)
        }
        guard enabled else { return }
        let watched = watchers.watched(now: t)
        for sid in watched
        where SessionsSchedule.transcriptDue(phones: phones, lastCheckedAt: lastTranscriptCheck[sid], now: t) {
            sendTranscript(sid, force: false, at: t)
        }
        for sid in watched
        where SessionsSchedule.screenDue(phones: phones, lastCheckedAt: lastScreenCheck[sid], reading: screensReading.contains(sid), now: t) {
            readScreen(sid, at: t)
        }
        // Forget screens nobody is watching any more.
        for sid in Set(screenSources.keys).union(lastScreenBody.keys) where !watched.contains(sid) {
            screenSources[sid] = nil
            lastScreenBody[sid] = nil
            lastScreenCheck[sid] = nil
        }
        let workflowSessions = watchers.watchedAny(now: t)
        for sid in workflowSessions where phones > 0 && !workflowsReading.contains(sid)
            && lastWorkflowCheck[sid].map({ t.timeIntervalSince($0) >= SessionWorkflows.interval }) ?? true {
            readWorkflows(sid, at: t)
        }
        for sid in Set(lastWorkflowBody.keys).union(lastWorkflowCheck.keys).union(workflowTranscript.keys)
        where !workflowSessions.contains(sid) {
            lastWorkflowBody[sid] = nil
            lastWorkflowCheck[sid] = nil
            workflowsResync.remove(sid)
            if let path = workflowTranscript.removeValue(forKey: sid) {
                // The scanner lives on the (serial) probe queue.
                let scanner = workflowScanner
                probeQueue.async { scanner.forget(transcript: path) }
            }
        }
        let agents = watchers.agents(now: t)
        for agent in agents
        where SessionsSchedule.transcriptDue(phones: phones, lastCheckedAt: lastAgentCheck[agent], now: t) {
            sendAgentTranscript(agent, force: false, at: t)
        }
        for agent in Set(lastAgentBody.keys).union(lastAgentCheck.keys) where !agents.contains(agent) {
            lastAgentBody[agent] = nil
            lastAgentCheck[agent] = nil
            lastAgentStamp[agent] = nil
        }
    }

    /// A watched Claude session's workflows, read on the probe queue (file
    /// reads only) and sent when they changed.
    private func readWorkflows(_ sessionId: String, at t: Date) {
        lastWorkflowCheck[sessionId] = t
        guard let s = sessions.first(where: { $0.sessionId == sessionId }), s.backend == .claude,
              let file = backends.transcriptFile(for: s) else { return }
        workflowsReading.insert(sessionId)
        workflowTranscript[sessionId] = file.path
        let scanner = workflowScanner
        probeQueue.async { [weak self] in
            let runs = scanner.runs(transcript: file.path)
            guard let self else { return }
            self.queue.async {
                self.workflowsReading.remove(sessionId)
                guard !self.stopped, self.phones > 0, self.watchers.watchedAny(now: self.now()).contains(sessionId) else { return }
                // A session that never ran a workflow sends nothing (an
                // empty list only once it had some, so the phone clears it).
                let resync = self.workflowsResync.contains(sessionId)
                if runs.isEmpty && self.lastWorkflowBody[sessionId] == nil && !resync { return }
                let body = (try? JSONSerialization.data(withJSONObject: runs.map(\.jsonObject), options: [.sortedKeys])) ?? Data()
                guard resync || body != self.lastWorkflowBody[sessionId] else { return }
                var head = self.header("workflows", at: self.now())
                head["sessionId"] = sessionId
                guard let data = SessionWorkflows.plaintext(header: head, runs: runs), self.seal(data) else { return }
                self.lastWorkflowBody[sessionId] = body
                self.workflowsResync.remove(sessionId)
            }
        }
    }

    /// A workflow agent's transcript, as a `transcript` frame carrying
    /// `runId` and `agentId`.
    private func sendAgentTranscript(_ agent: SessionWatchers.AgentRef, force: Bool, at t: Date) {
        lastAgentCheck[agent] = t
        guard phones > 0, let s = sessions.first(where: { $0.sessionId == agent.sessionId }), s.backend == .claude,
              let file = backends.transcriptFile(for: s),
              let path = SessionWorkflows.agentTranscript(transcript: file.path, runId: agent.runId, agentId: agent.agentId),
              let stamp = Self.fileStamp(path) else { return }
        // Agent transcripts run to tens of MB: unchanged, nothing is read.
        if !force && stamp == lastAgentStamp[agent] { return }
        lastAgentStamp[agent] = stamp
        guard let snapshot = SessionTranscript.read(path: path, format: .claude, keepSidechain: true) else { return }
        let body = (try? JSONSerialization.data(withJSONObject: ["e": snapshot.entries.map(\.jsonObject), "t": snapshot.truncated],
                                                options: [.sortedKeys])) ?? Data()
        if !force && body == lastAgentBody[agent] { return }
        var head = header("transcript", at: t)
        head["sessionId"] = agent.sessionId
        head["runId"] = agent.runId
        head["agentId"] = agent.agentId
        guard let data = SessionTranscript.plaintext(header: head, snapshot: snapshot), seal(data) else { return }
        lastAgentBody[agent] = body
    }

    /// Reads a watched session's screen on the probe queue and sends it
    /// when it changed. The source is re-resolved every `sourceTTL`.
    private func readScreen(_ sessionId: String, at t: Date) {
        lastScreenCheck[sessionId] = t
        guard let s = sessions.first(where: { $0.sessionId == sessionId }) else { return }
        let cached = screenSources[sessionId].flatMap { t.timeIntervalSince($0.at) < SessionScreen.sourceTTL ? $0 : nil }
        screensReading.insert(sessionId)
        let backends = self.backends
        probeQueue.async { [weak self] in
            let source = cached.map(\.source) ?? backends.screenSource(for: s)
            let raw = source.flatMap { backends.readScreen($0) }
            let lines = raw.map(SessionScreen.lines(from:))
            guard let self else { return }
            self.queue.async {
                self.screensReading.remove(sessionId)
                if cached == nil { self.screenSources[sessionId] = (source, t) }
                guard !self.stopped, self.phones > 0, let lines,
                      self.watchers.watched(now: self.now()).contains(sessionId),
                      lines != self.lastScreenBody[sessionId] else { return }
                var head = self.header("screen", at: self.now())
                head["sessionId"] = sessionId
                guard let data = SessionScreen.plaintext(header: head, lines: lines), self.seal(data) else { return }
                self.lastScreenBody[sessionId] = lines
            }
        }
    }

    private func refreshStatuses(_ t: Date) {
        if let at = statusesAt, t.timeIntervalSince(at) < Self.liveStatusInterval { return }
        statusesAt = t
        statuses = backends.liveStatuses(sessions.filter { $0.backend == .claude })
    }

    private func probeIfNeeded(_ t: Date) {
        guard !probing else { return }
        let due = sessions.filter { s in hosts[s.sessionId].map { t.timeIntervalSince($0.at) >= Self.hostTTL } ?? true }
        guard !due.isEmpty else { return }
        probing = true
        let backends = self.backends
        probeQueue.async { [weak self] in
            let found = backends.probeHosts(due)
            guard let self else { return }
            self.queue.async {
                self.probing = false
                self.hosts = Self.mergeProbe(found, due: due.map(\.sessionId), into: self.hosts,
                                             live: Set(self.sessions.map(\.sessionId)), at: self.now())
            }
        }
    }

    /// Re-reads the working sessions' card facts on the probe queue (files only),
    /// a few seconds apart.
    private func probeFlightIfNeeded(_ t: Date) {
        let working = sessions.filter { state(of: $0) == .active }
        guard !working.isEmpty else {
            if !flightFacts.isEmpty { flightFacts = [:] }
            return
        }
        guard !flightProbing, flightChecked.map({ t.timeIntervalSince($0) >= Self.flightInterval }) ?? true else { return }
        flightChecked = t
        flightProbing = true
        let backends = self.backends
        probeQueue.async { [weak self] in
            let found = backends.flightFacts(working)
            guard let self else { return }
            self.queue.async {
                self.flightProbing = false
                self.flightFacts = found
            }
        }
    }

    /// Pure. The optional fields a working session's row carries, from what the
    /// probe read and what the stuck watch and rate limit say about it.
    static func workingFields(facts: InFlightFacts?, pending: [InterventionEvent], sessionId: String,
                              rateLimitResetsAt: Date?, now: Date) -> WireFields? {
        let stuck = pending
            .filter { $0.sessionId == sessionId && StuckWatch.subtypes.contains($0.subtype ?? "") }
            .max { $0.openedAt < $1.openedAt }
            .map { NowModel.summaryLine(for: $0) }
        return WireFields(InFlightWire.fields(facts: facts, stuckDetail: stuck, rateLimitResetsAt: rateLimitResetsAt, now: now))
    }

    /// Pure. An empty `found` means the probe itself failed (no process
    /// table, e.g. `ps` timing out while the Mac is busy): every host keeps
    /// what it had and stays due, so a hiccup never flips the whole list to
    /// "Couldn't find the session's terminal". A session the probe skipped
    /// keeps its last host too; only one never seen falls back to unknown.
    static func mergeProbe(_ found: [String: SessionHostInfo], due: [String],
                           into hosts: [String: (info: SessionHostInfo, at: Date)],
                           live: Set<String>, at: Date) -> [String: (info: SessionHostInfo, at: Date)] {
        guard !found.isEmpty else { return hosts }
        var out = hosts
        for id in due where live.contains(id) {
            if let info = found[id] {
                out[id] = (info, at)
            } else if out[id] == nil {
                out[id] = (.blocked("unknown", "Couldn't find the session's terminal"), at)
            }
        }
        return out
    }

    private func state(of s: AgentSession) -> AgentSessionState {
        s.backend == .claude ? Self.overlay(s.state, fresh: statuses[s.sessionId]) : s.state
    }

    private func currentRows(_ t: Date) -> [RemoteSessionRow] {
        var seen = Set<String>()
        var rows: [RemoteSessionRow] = []
        var held: Set<String>?   // read once per list, and only if a session is working
        for s in sessions where seen.insert(s.sessionId).inserted {
            let st = state(of: s)
            let probed = hosts[s.sessionId]?.info
            let host = Self.effectiveHost(probed ?? .checking, backend: s.backend, state: st)
            let photos = ImageDelivery.rowFields(backend: s.backend, host: host)
            rows.append(RemoteSessionRow(
                id: s.sessionId,
                backend: s.backend.rawValue,
                title: String((s.title ?? Self.folderTitle(s.cwd) ?? s.backend.rawValue).prefix(Self.maxTitle)),
                cwd: s.cwd.map { String(Self.homeAbbreviated($0).prefix(Self.maxCwd)) },
                state: st,
                host: host,
                lastActivityAt: s.lastActivityAt,
                interventionId: openPage(for: s)?.id,
                preview: preview(for: s, state: st, at: t),
                ask: pendingQuestion(for: s, state: st, host: host, held: {
                    if held == nil { held = heldSessions() }
                    return held?.contains(s.sessionId) ?? false
                }),
                working: st == .active
                    ? Self.workingFields(facts: flightFacts[s.sessionId], pending: pending, sessionId: s.sessionId,
                                         rateLimitResetsAt: rateLimited[s.sessionId], now: t)
                    : nil,
                held: WireList(outbox.rowEntries(sessionId: s.sessionId, now: t)),
                canHold: Self.canHold(backend: s.backend, probed: probed),
                attach: photos.attach,
                attachBlocker: photos.blocker
            ))
        }
        return Self.ordered(rows)
    }

    /// The one AskUserQuestion a waiting Claude session is blocked on, read
    /// raw from its transcript (re-read only when the file changes). nil for
    /// anything else, so only sessions with a dialog on screen carry `ask`.
    /// A session whose question Page's own hook is holding shows no dialog (it reads `active`), but the
    /// hook wrote the tool call to the transcript first: the phone answers that page by text, mapped by
    /// the hook, with no keys. The `answer` op refuses such a session.
    /// A dialog on screen is answered by keys, so it carries `ask` only when Page can press keys in that
    /// session's terminal (`AnswerDelivery.takesAnswerKeys`); otherwise the phone keeps "Tell it instead".
    private func pendingQuestion(for s: AgentSession, state: AgentSessionState, host: SessionHostInfo, held: () -> Bool) -> AskedQuestionSet? {
        guard s.backend == .claude,
              state == .waitingOnUser || state == .waitingOnApproval || (state == .active && held()),
              let file = backends.transcriptFile(for: s), file.format == .claude,
              let stamp = Self.fileStamp(file.path) else {
            asks[s.sessionId] = nil
            return nil
        }
        let ask: AskedQuestionSet?
        if let cached = asks[s.sessionId], cached.stamp == stamp {
            ask = cached.ask
        } else {
            var found: AskedQuestionSet?
            if let tools = InterventionDetector.readTranscriptTail(URL(fileURLWithPath: file.path))?.pendingToolUses,
               tools.count == 1, tools[0].name == "AskUserQuestion" {
                found = tools[0].asked
            }
            asks[s.sessionId] = (stamp, found)
            ask = found
        }
        // The host is judged on every list (it can change without the transcript moving), so it is not cached.
        if state == .active { return ask }
        return AnswerDelivery.takesAnswerKeys(host) ? ask : nil
    }

    private func openPage(for s: AgentSession) -> InterventionEvent? {
        pending.filter { $0.sessionId == s.sessionId && $0.backend == s.backend }.max { $0.openedAt < $1.openedAt }
    }

    private func preview(for s: AgentSession, state: AgentSessionState, at t: Date) -> String? {
        if let cached = previews[s.sessionId], t.timeIntervalSince(cached.checkedAt) < Self.previewInterval {
            return SessionTranscript.preview(cached.entries, active: state == .active)
        }
        let file = backends.transcriptFile(for: s)
        let stamp = file.flatMap { Self.fileStamp($0.path) }
        var entries = previews[s.sessionId]?.entries ?? []
        if let file, let stamp, stamp != previews[s.sessionId]?.stamp {
            entries = SessionTranscript.read(path: file.path, format: file.format,
                                             tailBytes: SessionTranscript.previewTailBytes, extendTo: nil)?.entries ?? []
        } else if stamp == nil {
            entries = []
        }
        previews[s.sessionId] = (stamp, t, entries)
        return SessionTranscript.preview(entries, active: state == .active)
    }

    /// Size and mtime, or nil — never for a privacy-protected path (even a
    /// stat there can raise the macOS prompt).
    static func fileStamp(_ path: String) -> FileStamp? {
        guard !path.hasPrefix("/dev/"), !PrivacyProtectedPaths.contains(path) else { return nil }
        // A symlink into a protected folder counts as inside it (stat follows it).
        let resolved = (path as NSString).resolvingSymlinksInPath
        guard !resolved.hasPrefix("/dev/"), !PrivacyProtectedPaths.contains(resolved) else { return nil }
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
        return FileStamp(size: UInt64(max(0, st.st_size)), mtime: mtime)
    }

    static func listBody(_ rows: [RemoteSessionRow], enabled: Bool) -> Data {
        let obj: [String: Any] = ["sessions": rows.map(\.jsonObject), "disabled": !enabled]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    }

    // MARK: sending (queue)

    private func header(_ kind: String, at t: Date) -> [String: Any] {
        seq += 1
        return ["kind": kind, "boot": boot, "seq": seq, "ts": Int64((t.timeIntervalSince1970 * 1000).rounded())]
    }

    private func seal(_ plaintext: Data) -> Bool {
        guard let sink, let keys, sink.isConnected,
              let envelope = SessionCrypto.seal(plaintext, key: keys.macToPhone, aad: SessionCrypto.updateAAD) else { return false }
        sink.sendSessionsUpdate(envelope)
        return true
    }

    private func sendList(_ rows: [RemoteSessionRow], body: Data, at t: Date) {
        if macName == nil { macName = macNameProvider() }
        var head = header("list", at: t)
        head["macName"] = macName ?? "Mac"
        head["caps"] = Self.capabilities
        // Not in the spec: tells a phone that knows it why the list is
        // empty (others ignore unknown fields).
        if !enabled { head["disabled"] = true }
        guard let out = Self.listPlaintext(header: head, rows: rows) else { return }
        if out.kept < rows.count { Logger.shared.log("Sessions: list trimmed to fit (\(out.kept) of \(rows.count) rows)") }
        guard seal(out.data) else { return }
        lastListAt = t
        // The full list: a change in a trimmed-off row still counts.
        lastListBody = body
    }

    /// The `list` plaintext: `header` plus the rows, dropping the last
    /// (least urgent, `rows` is ordered) until it fits in `maxBytes`. A
    /// single row isn't byte-bounded (titles are capped in characters), so
    /// this can end at an empty list — never at no list. `kept` is the
    /// number of rows sent.
    static func listPlaintext(header: [String: Any], rows: [RemoteSessionRow],
                              maxBytes: Int = maxListPlaintextBytes) -> (data: Data, kept: Int)? {
        var objects = rows.map(\.jsonObject)
        while true {
            var obj = header
            obj["sessions"] = objects
            guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return nil }
            if data.count <= maxBytes || objects.isEmpty { return (data, objects.count) }
            // Drop a share proportional to the overshoot (at least one row).
            let excess = Double(data.count - maxBytes) / Double(data.count)
            objects.removeLast(max(1, min(objects.count, Int((Double(objects.count) * excess).rounded(.up)))))
        }
    }

    private func sendTranscript(_ sessionId: String, force: Bool, at t: Date) {
        lastTranscriptCheck[sessionId] = t
        guard phones > 0, let s = sessions.first(where: { $0.sessionId == sessionId }),
              let file = backends.transcriptFile(for: s), let stamp = Self.fileStamp(file.path) else { return }
        let snapshot: SessionTranscript.Snapshot
        if let cached = transcripts[file.path], cached.stamp == stamp {
            snapshot = cached.snapshot
        } else {
            guard let fresh = SessionTranscript.read(path: file.path, format: file.format) else { return }
            snapshot = fresh
            transcripts[file.path] = (stamp, fresh)
            // Only watched sessions' transcripts are kept.
            let watchedPaths = Set(watchers.watched(now: t).compactMap { sid in
                sessions.first { $0.sessionId == sid }.flatMap { backends.transcriptFile(for: $0)?.path }
            })
            transcripts = transcripts.filter { watchedPaths.contains($0.key) || $0.key == file.path }
        }
        let body = (try? JSONSerialization.data(withJSONObject: ["e": snapshot.entries.map(\.jsonObject), "t": snapshot.truncated],
                                                options: [.sortedKeys])) ?? Data()
        if !force && body == lastTranscriptBody[sessionId] { return }
        var head = header("transcript", at: t)
        head["sessionId"] = sessionId
        guard let data = SessionTranscript.plaintext(header: head, snapshot: snapshot), seal(data) else { return }
        lastTranscriptBody[sessionId] = body
    }

    /// The `folders` kind: where a session may be started, and whether
    /// starting is on at all.
    private func sendFolders(clientId: String) {
        let live = sessions
        let on = startEnabled
        let backends = self.backends
        probeQueue.async { [weak self] in
            let folders = on ? backends.knownFolders(live: live) : []
            self?.queue.async {
                guard let self, !self.stopped else { return }
                var obj = self.header("folders", at: self.now())
                obj["clientId"] = clientId
                obj["enabled"] = on
                obj["agents"] = ["claude"]
                obj["folders"] = folders.map(\.jsonObject)
                guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
                _ = self.seal(data)
            }
        }
    }

    private func sendResult(_ clientId: String, _ result: SessionCommandResult) {
        if let respond = localResponders.removeValue(forKey: clientId) {
            respond(result)
            return
        }
        var obj = header("result", at: now())
        obj.merge(result.fields(clientId: clientId)) { $1 }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        _ = seal(data)
    }

    // MARK: commands (queue)

    private func handleCommandLocked(_ envelope: SessionEnvelope) {
        guard !stopped else { return }
        let t = now()
        switch Self.accept(envelope, keys: keys, enabled: enabled, now: t, replay: &replay) {
        case .drop(let why):
            Logger.shared.log("Sessions: command dropped (\(why))")
        case .reply(let clientId, let result):
            Logger.shared.log("Sessions: command refused (\(result.reason?.rawValue ?? result.code.rawValue))")
            sendResult(clientId, result)
        case .accept(let cmd):
            perform(cmd, at: t)
        }
    }

    private func perform(_ cmd: SessionCommand, at t: Date) {
        let sid = cmd.sessionId.map { String($0.prefix(8)) } ?? "-"
        switch cmd.op {
        case "watch":
            guard let viewer = cmd.viewer else { return }
            watchers.set(viewer: viewer, sessionId: cmd.sessionId, runId: cmd.runId, agentId: cmd.agentId, now: t)
            if let agent = watchers.agent(forViewer: viewer, now: t) {
                sendAgentTranscript(agent, force: true, at: t)
                workflowsResync.insert(agent.sessionId)
            } else if let id = cmd.sessionId {
                sendTranscript(id, force: true, at: t)
                lastScreenBody[id] = nil   // the next read is sent even if unchanged
                workflowsResync.insert(id)
            }
        case "refresh":
            if phones > 0 {
                let rows = enabled ? currentRows(t) : []
                sendList(rows, body: Self.listBody(rows, enabled: enabled), at: t)
            }
            if let viewer = cmd.viewer, let agent = watchers.agent(forViewer: viewer, now: t) {
                sendAgentTranscript(agent, force: true, at: t)
                workflowsResync.insert(agent.sessionId)
            } else if let viewer = cmd.viewer, let id = watchers.session(forViewer: viewer, now: t) {
                sendTranscript(id, force: true, at: t)
                lastScreenBody[id] = nil
                workflowsResync.insert(id)
            }
        case "input":
            let length = cmd.text?.count ?? 0
            guard let id = cmd.sessionId, let s = sessions.first(where: { $0.sessionId == id }) else {
                Logger.shared.log("Sessions: input \(sid) → refused/not_found (\(length) chars)")
                return sendResult(cmd.clientId, .refused(.notFound, "That session isn't running any more"))
            }
            if let refusal = SessionTargetCheck.verify(cmd, against: s) {
                Logger.shared.log("Sessions: input \(sid) → refused/target_mismatch (\(length) chars)")
                return sendResult(cmd.clientId, refusal)
            }
            let text: String
            switch SessionInputGate.validateText(cmd.text ?? "") {
            case .failure(let refusal):
                Logger.shared.log("Sessions: input \(sid) → refused/\(refusal.reason?.rawValue ?? "error") (\(length) chars)")
                return sendResult(cmd.clientId, refusal)
            case .success(let t): text = t
            }
            if cmd.hold && !cmd.local { return holdInput(cmd, session: s, text: text, at: t) }
            Logger.shared.log("Sessions: input \(sid) (\(length) chars)")
            let clientId = cmd.clientId
            backends.input(s, clientId: clientId, text: cmd.text ?? "", interventionId: openPage(for: s)?.id) { [weak self] r in
                guard let self else { return }
                self.queue.async {
                    Logger.shared.log("Sessions: input \(sid) → \(r.code.rawValue)\(r.reason.map { "/\($0.rawValue)" } ?? "") (\(length) chars)")
                    self.sendResult(clientId, r)
                }
            }
        case "answer":
            guard let id = cmd.sessionId, let s = sessions.first(where: { $0.sessionId == id }) else {
                Logger.shared.log("Sessions: answer \(sid) → refused/not_found")
                return sendResult(cmd.clientId, .refused(.notFound, "That session isn't running any more"))
            }
            if let refusal = SessionTargetCheck.verify(cmd, against: s) {
                Logger.shared.log("Sessions: answer \(sid) → refused/target_mismatch")
                return sendResult(cmd.clientId, refusal)
            }
            guard s.backend == .claude, let promptKey = cmd.promptKey, let answers = cmd.answers else {
                Logger.shared.log("Sessions: answer \(sid) → refused/answer_unsupported")
                return sendResult(cmd.clientId, .refused(.answerUnsupported, "Page can't answer that question from here"))
            }
            Logger.shared.log("Sessions: answer \(sid) (\(answers.count) question(s))")
            let clientId = cmd.clientId
            backends.answer(s, request: AnswerRequest(promptKey: promptKey, answers: answers)) { [weak self] r in
                guard let self else { return }
                self.queue.async {
                    Logger.shared.log("Sessions: answer \(sid) → \(r.code.rawValue)\(r.reason.map { "/\($0.rawValue)" } ?? "")")
                    self.sendResult(clientId, r)
                    // The dialog closed (or changed): let the list say so now.
                    self.lastListBody = nil
                }
            }
        case "interrupt":
            guard let id = cmd.sessionId, let s = sessions.first(where: { $0.sessionId == id }) else {
                Logger.shared.log("Sessions: interrupt \(sid) → refused/not_found")
                return sendResult(cmd.clientId, .refused(.notFound, "That session isn't running any more"))
            }
            if let refusal = SessionTargetCheck.verify(cmd, against: s) {
                Logger.shared.log("Sessions: interrupt \(sid) → refused/target_mismatch")
                return sendResult(cmd.clientId, refusal)
            }
            let st = state(of: s)
            if st != .active || hosts[id]?.info.canInterrupt == false {
                let r: SessionCommandResult = st == .active
                    ? .refused(.interruptUnsupported, "Page can't press Esc where this session runs")
                    : .refused(.interruptUnsupported, SessionInputGate.notIdleMessage)
                Logger.shared.log("Sessions: interrupt \(sid) → refused/interrupt_unsupported")
                return sendResult(cmd.clientId, r)
            }
            Logger.shared.log("Sessions: interrupt \(sid)")
            let clientId = cmd.clientId
            backends.interrupt(s, interventionId: openPage(for: s)?.id) { [weak self] r in
                guard let self else { return }
                self.queue.async {
                    Logger.shared.log("Sessions: interrupt \(sid) → \(r.code.rawValue)\(r.reason.map { "/\($0.rawValue)" } ?? "")")
                    self.sendResult(clientId, r)
                }
            }
        case "folders":
            sendFolders(clientId: cmd.clientId)
        case "interruptAll":
            // Siri / Shortcuts "Stop my agents": Esc in every session that is
            // working, each through the same gate as the Stop button.
            let targets = sessions.filter { state(of: $0) == .active && hosts[$0.sessionId]?.info.canInterrupt != false }
            Logger.shared.log("Sessions: interruptAll (\(targets.count) working)")
            guard !targets.isEmpty else {
                return sendResult(cmd.clientId, SessionCommandResult(code: .delivered, reason: nil, detail: "No agents were working"))
            }
            let clientId = cmd.clientId
            let group = DispatchGroup()
            let lock = NSLock()
            var stopped = 0
            for s in targets {
                group.enter()
                backends.interrupt(s, interventionId: openPage(for: s)?.id) { r in
                    if r.code == .delivered || r.code == .queued { lock.lock(); stopped += 1; lock.unlock() }
                    group.leave()
                }
            }
            group.notify(queue: queue) { [weak self] in
                let n = targets.count
                let detail = stopped == n ? "Stopped \(n) agent\(n == 1 ? "" : "s")" : "Stopped \(stopped) of \(n) agents"
                self?.sendResult(clientId, SessionCommandResult(code: stopped > 0 ? .delivered : .refused,
                                                                reason: stopped > 0 ? nil : .interruptUnsupported, detail: detail))
            }
        case "start":
            // "Let my phone start sessions" gates the phone; someone at this
            // Mac dispatching from its own panel is not the phone.
            guard startEnabled || cmd.local else {
                Logger.shared.log("Sessions: start → refused/disabled")
                return sendResult(cmd.clientId, .refused(.disabled, SessionStarter.disabledMessage))
            }
            let prompt: String
            switch SessionStarter.cleanPrompt(cmd.text) {
            case .success(let p): prompt = p
            case .failure(let r): return sendResult(cmd.clientId, r)
            }
            let live = sessions
            let folder = cmd.folder
            let clientId = cmd.clientId
            let backends = self.backends
            probeQueue.async { [weak self] in
                let r: SessionCommandResult
                switch SessionStarter.allowed(folder, in: backends.knownFolders(live: live)) {
                case .success(let f): r = backends.startSession(folder: f, prompt: prompt)
                case .failure(let refusal): r = refusal
                }
                self?.queue.async {
                    guard let self else { return }
                    Logger.shared.log("Sessions: start → \(r.code.rawValue)\(r.reason.map { "/\($0.rawValue)" } ?? "")")
                    self.sendResult(clientId, r)
                    // The new session shows up on the next ticks; ask the
                    // list to go out then even if nothing else changed.
                    self.lastListBody = nil
                }
            }
        case "diff":
            guard let id = cmd.sessionId, let s = sessions.first(where: { $0.sessionId == id }) else {
                return sendResult(cmd.clientId, .refused(.notFound, "That session isn't running any more"))
            }
            Logger.shared.log("Sessions: diff \(sid)")
            let file = backends.transcriptFile(for: s)
            let transcript = file?.format == .claude ? file?.path : nil
            let clientId = cmd.clientId
            // git can take a moment; the frame is built and sealed back on
            // the sessions queue so its seq is in order.
            probeQueue.async { [weak self] in
                let fields = TurnSummary.diffFields(transcript: transcript, cwd: s.cwd)
                self?.queue.async {
                    guard let self, !self.stopped else { return }
                    var obj = self.header("diff", at: self.now())
                    obj.merge(fields) { a, _ in a }
                    obj["sessionId"] = id
                    obj["clientId"] = clientId
                    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
                    _ = self.seal(data)
                }
            }
        case "imagePart":
            receiveImagePart(cmd, at: t)
        case "inputImages":
            let length = cmd.text?.count ?? 0
            guard let id = cmd.sessionId, let s = sessions.first(where: { $0.sessionId == id }) else {
                Logger.shared.log("Sessions: inputImages \(sid) → refused/not_found")
                return sendResult(cmd.clientId, .refused(.notFound, "That session isn't running any more"))
            }
            if let refusal = SessionTargetCheck.verify(cmd, against: s) {
                Logger.shared.log("Sessions: inputImages \(sid) → refused/target_mismatch")
                return sendResult(cmd.clientId, refusal)
            }
            guard let refs = cmd.images else {
                Logger.shared.log("Sessions: inputImages \(sid) → refused/attachment_invalid (no usable photo list)")
                return sendResult(cmd.clientId, .refused(.attachmentInvalid, "The photos didn't arrive in a form Page understands"))
            }
            let text = (cmd.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count <= SessionInputGate.maxTextLength else {
                return sendResult(cmd.clientId, .refused(.error, "The message is too long (8000 characters at most)"))
            }
            Logger.shared.log("Sessions: inputImages \(sid) (\(refs.count) photo(s), \(refs.reduce(0) { $0 + $1.bytes }) B, \(length) chars)")
            let clientId = cmd.clientId
            imageWaits[clientId] = ImageWait(cmd: cmd, refs: refs, sessionId: id, text: text)
            deliverImagesIfReady(clientId, final: false, at: t)
            if imageWaits[clientId] != nil {
                // The relay forwards in order, so the pieces are normally here already; stragglers get a moment.
                queue.asyncAfter(deadline: .now() + imagePartWait) { [weak self] in
                    guard let self, !self.stopped else { return }
                    self.deliverImagesIfReady(clientId, final: true, at: self.now())
                }
            }
        case "retract":
            switch (cmd.heldId, cmd.interventionId) {
            case (let heldId?, nil):
                retractHeld(heldId, by: cmd.clientId)
            case (nil, let pageId?):
                let r = backends.retractReply(interventionId: pageId)
                Logger.shared.log("Sessions: retract reply → \(r.result.retract ?? "-")")
                sendResult(cmd.clientId, r.result)
            default:
                Logger.shared.log("Sessions: retract → refused/error (names \(cmd.heldId == nil ? "nothing" : "two messages"))")
                sendResult(cmd.clientId, .refused(.error, "Say which one message to delete"))
            }
        default:
            // Unknown ops are ignored (forward compatibility).
            Logger.shared.log("Sessions: ignoring unknown op")
        }
    }

    // MARK: photos (queue)

    /// One piece of a photo: kept, never answered (a phone gets one `result`
    /// per message, for its `inputImages`). Logged only when it completes a
    /// photo or is dropped: ids and sizes, never data.
    private func receiveImagePart(_ cmd: SessionCommand, at t: Date) {
        let sid = cmd.sessionId.map { String($0.prefix(8)) } ?? "-"
        guard let part = cmd.imagePart, let sessionId = cmd.sessionId else {
            Logger.shared.log("Sessions: image part \(sid) dropped (malformed)")
            return
        }
        let tag = "\(sid)/\(part.imageId.prefix(6)) \(part.index + 1)/\(part.total)"
        switch images.add(part, sessionId: sessionId, viewer: cmd.viewer, now: t) {
        case .stored, .duplicate:
            break
        case .complete:
            Logger.shared.log("Sessions: image \(tag) complete (\(part.bytes) B)")
            for (clientId, wait) in imageWaits where images.hasAllPieces(wait.refs) {
                deliverImagesIfReady(clientId, final: false, at: t)
            }
        case .dropped(let why):
            Logger.shared.log("Sessions: image part \(tag) dropped (\(why), \(part.data.count) B)")
        case .spoiled(let why):
            Logger.shared.log("Sessions: image \(tag) spoiled (\(why))")
        }
    }

    /// Hands a waiting `inputImages` its photos once every piece is in; a
    /// `final` look (the wait is over) answers `attachment_missing` instead.
    private func deliverImagesIfReady(_ clientId: String, final: Bool, at t: Date) {
        guard let w = imageWaits[clientId] else { return }
        let sid = String(w.sessionId.prefix(8))
        switch images.take(w.refs, sessionId: w.sessionId, viewer: w.cmd.viewer, now: t) {
        case .missing(let ids):
            guard final else { return }
            imageWaits[clientId] = nil
            Logger.shared.log("Sessions: inputImages \(sid) → refused/attachment_missing (\(ids.count) of \(w.refs.count))")
            var r = SessionCommandResult.refused(.attachmentMissing, "Part of a photo didn't reach your Mac — send it again")
            r.missing = ids
            sendResult(clientId, r)
        case .invalid(let why):
            imageWaits[clientId] = nil
            Logger.shared.log("Sessions: inputImages \(sid) → refused/attachment_invalid")
            sendResult(clientId, .refused(.attachmentInvalid, why))
        case .ready(let photos):
            imageWaits[clientId] = nil
            guard let s = sessions.first(where: { $0.sessionId == w.sessionId }) else {
                Logger.shared.log("Sessions: inputImages \(sid) → refused/not_found")
                return sendResult(clientId, .refused(.notFound, "That session isn't running any more"))
            }
            backends.inputImages(s, clientId: clientId, images: photos, text: w.text, interventionId: openPage(for: s)?.id) { [weak self] r in
                guard let self else { return }
                self.queue.async {
                    Logger.shared.log("Sessions: inputImages \(sid) → \(r.code.rawValue)\(r.reason.map { "/\($0.rawValue)" } ?? "")"
                                      + (r.attached.map { " (attached \($0))" } ?? ""))
                    self.sendResult(clientId, r)
                }
            }
        }
    }

    /// Drops every photo, piece and waiting command, and deletes the files (a new pairing).
    private func forgetImages() {
        images.reset()
        imageWaits = [:]
        guard let store = imageStore else { return }
        Logger.shared.log("Sessions: the pairing changed — deleting photos received from the phone")
        probeQueue.async { store.wipeAll() }
    }

    /// Deletes old photos (24 h) and ended sessions' folders, hourly.
    private func cleanImagesIfDue() {
        guard let store = imageStore else { return }
        let t = now()
        if let last = imageCleanedAt, t.timeIntervalSince(last) < Self.imageCleanupInterval { return }
        imageCleanedAt = t
        let live = Set(sessions.map { ImageStore.folderName(forSession: $0.sessionId) })
        probeQueue.async { store.cleanup(now: t, live: live) }
    }

    // MARK: held messages (queue)

    /// `input` with `hold` (SESSIONS-PROTOCOL.md §5 "Holding a message until
    /// the turn ends"). Answers at once: held, or (the turn already over, and
    /// nothing else waiting for the session) the result of typing it now.
    /// Pure. Whether a phone may ask Page to hold a message for this session: the probed host, before the
    /// Codex mid-turn rule. Not Codex in Terminal.app: that path brings Terminal to the front to press Return,
    /// and a held message is typed unattended, maybe hours later.
    static func canHold(backend: AgentBackendID, probed: SessionHostInfo?) -> Bool {
        guard let probed, probed.canType else { return false }
        return !(backend == .codex && probed.host == "Terminal")
    }

    private func holdInput(_ cmd: SessionCommand, session s: AgentSession, text: String, at t: Date) {
        let sid = String(s.sessionId.prefix(8))
        // A terminal Page can't type into would only refuse it later.
        if let info = hosts[s.sessionId]?.info, !info.canType {
            Logger.shared.log("Sessions: input \(sid) hold → refused/not_typable (\(text.count) chars)")
            return sendResult(cmd.clientId, .refused(.notTypable, info.typeBlocker ?? "Page can't type into this session"))
        }
        if let info = hosts[s.sessionId]?.info, !Self.canHold(backend: s.backend, probed: info) {
            Logger.shared.log("Sessions: input \(sid) hold → refused/not_typable (Codex in Terminal)")
            return sendResult(cmd.clientId, .refused(.notTypable,
                "Page can't hold messages for Codex in Terminal — it would bring Terminal to the front later. Send it now instead"))
        }
        var m = HeldOutbox.Message(clientId: cmd.clientId, sessionId: s.sessionId, backend: s.backend, text: text, heldAt: t)
        m.expectCwd = cmd.expectCwd
        m.expectTitle = cmd.expectTitle
        if let refusal = outbox.add(m) {
            Logger.shared.log("Sessions: input \(sid) hold → refused (\(outbox.waiting(sessionId: s.sessionId).count) held)")
            return sendResult(cmd.clientId, refusal)
        }
        if heldReadiness()[s.sessionId] == .ready, let (first, claim) = outbox.claimFirstTry(cmd.clientId, now: t) {
            outboxChanged()
            Logger.shared.log("Sessions: input \(sid) hold → the turn is over, typing now (\(text.count) chars)")
            startHeldTry(first, claim: claim)
        } else {
            outboxChanged()
            Logger.shared.log("Sessions: input \(sid) → held \(cmd.clientId.prefix(8)) (\(text.count) chars)")
            sendResult(cmd.clientId, HeldOutbox.heldResult(backend: s.backend))
        }
        updateOutboxTimer()
    }

    /// Pure. Whether a session's turn is over, for a held message. Claude by
    /// its sessions file (`idle` or `shell`), not by the list state: an idle
    /// page is open after every finished turn. Codex by its state. Never
    /// while the session is rate limited.
    static func heldReadiness(backend: AgentBackendID, state: AgentSessionState, fresh: ClaudeSessionStatus?,
                              rateLimitedUntil: Date?, now: Date) -> HeldOutbox.Readiness {
        if state == .rateLimited || (rateLimitedUntil.map { $0 > now } ?? false) { return .wait }
        switch backend {
        case .claude:
            switch fresh {
            case .idle?, .shell?: return .ready
            case .busy?, .waiting?, .unknown?, nil: return .wait
            }
        case .codex:
            return state == .idle || state == .interrupted || state == .failed ? .ready : .wait
        }
    }

    /// The held sessions' readiness, from a fresh read of their sessions
    /// files (one small file each). A session not in the list is `gone`;
    /// nothing is ready while live sessions are turned off.
    private func heldReadiness() -> [String: HeldOutbox.Readiness] {
        let ids = Set(outbox.sessionIds)
        guard !ids.isEmpty else { return [:] }
        var seen = Set<String>()
        let held = sessions.filter { ids.contains($0.sessionId) && seen.insert($0.sessionId).inserted }
        let fresh = backends.liveStatuses(held.filter { $0.backend == .claude })
        let t = now()
        var out: [String: HeldOutbox.Readiness] = [:]
        for s in held {
            out[s.sessionId] = enabled
                ? Self.heldReadiness(backend: s.backend, state: s.state, fresh: fresh[s.sessionId],
                                     rateLimitedUntil: rateLimited[s.sessionId], now: t)
                : .wait
        }
        return out
    }

    /// Types what is due, and settles what expired or lost its session.
    private func drainOutbox(tick: Bool) {
        guard !stopped, !outbox.isEmpty || !outbox.settled.isEmpty else { return updateOutboxTimer() }
        let settledBefore = outbox.settled.count
        let steps = outbox.plan(readiness: heldReadiness(), tick: tick, now: now())
        // Saved before any try starts: a restart mid-try must never retype it.
        if !steps.isEmpty || outbox.settled.count != settledBefore { outboxChanged() }
        for step in steps {
            switch step {
            case .settle(let m, let r):
                Logger.shared.log("Sessions: held \(m.sessionId.prefix(8))/\(m.clientId.prefix(8)) → \(r.reason?.rawValue ?? r.code.rawValue)")
                sendResult(m.clientId, r)
            case .type(let m, let claim):
                startHeldTry(m, claim: claim)
            }
        }
        updateOutboxTimer()
    }

    private func startHeldTry(_ m: HeldOutbox.Message, claim: HeldClaim) {
        let tag = "\(m.sessionId.prefix(8))/\(m.clientId.prefix(8))"
        guard let s = sessions.first(where: { $0.sessionId == m.sessionId }) else {
            return finishHeldTry(m.clientId, .refused(.notFound, SessionInputGate.endedMessage))
        }
        // The folder and title the phone showed, checked again now.
        if let refusal = SessionTargetCheck.verify(expectCwd: m.expectCwd, expectTitle: m.expectTitle, cwd: s.cwd,
                                                   title: s.title ?? Self.folderTitle(s.cwd) ?? s.backend.rawValue) {
            return finishHeldTry(m.clientId, refusal)
        }
        Logger.shared.log("Sessions: held \(tag) → typing (\(m.text.count) chars)")
        backends.typeHeld(s, clientId: m.clientId, text: m.text, claim: claim) { [weak self] r in
            guard let self else { return }
            self.queue.async { self.finishHeldTry(m.clientId, r) }
        }
    }

    private func finishHeldTry(_ clientId: String, _ r: SessionCommandResult) {
        let f = outbox.finish(clientId: clientId, result: r, now: now())
        outboxChanged()
        Logger.shared.log("Sessions: held \(clientId.prefix(8)) → \(r.code.rawValue)\(r.reason.map { "/\($0.rawValue)" } ?? "")"
                          + " (\(HeldOutbox.verdict(r)))")
        if let (cid, result) = f.result { sendResult(cid, result) }
        for (rid, result) in f.retracts { sendResult(rid, result) }
        updateOutboxTimer()
    }

    /// `retract` with a `heldId`.
    private func retractHeld(_ heldId: String, by retractId: String) {
        let tag = heldId.prefix(8)
        switch outbox.retract(heldId: heldId, by: retractId, now: now()) {
        case .deleted(let final):
            outboxChanged()
            Logger.shared.log("Sessions: held \(tag) → deleted")
            sendResult(final.clientId, final.result)
            sendResult(retractId, HeldOutbox.retractResult(.deleted))
        case .alreadyDeleted:
            sendResult(retractId, HeldOutbox.retractResult(.alreadyDeleted))
        case .waits:
            // Answered when the try under way finishes.
            Logger.shared.log("Sessions: held \(tag) → delete waits for the try under way")
        case .tooLate:
            Logger.shared.log("Sessions: held \(tag) → delete too late")
            sendResult(retractId, HeldOutbox.retractResult(.tooLate))
        case .notFound:
            sendResult(retractId, HeldOutbox.retractResult(.notFound))
        }
        updateOutboxTimer()
    }

    /// Saves the outbox and tells the panel.
    private func outboxChanged() {
        outboxStore?.save(outbox)
        publishHeld()
    }

    private func publishHeld() {
        let items = outbox.panelItems()
        heldLock.lock()
        let changed = items != heldShared
        heldShared = items
        let callback = _onHeldChanged
        heldLock.unlock()
        if changed { callback?() }
    }

    /// Re-reads held sessions every `outboxInterval` while anything is held,
    /// phone or no phone (the tick alone can be minutes apart).
    private func updateOutboxTimer() {
        let wanted = autoTimer && !stopped && !outbox.isEmpty
        if wanted, outboxTimer == nil {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + Self.outboxInterval, repeating: Self.outboxInterval, leeway: .milliseconds(250))
            t.setEventHandler { [weak self] in self?.drainOutbox(tick: false) }
            t.resume()
            outboxTimer = t
        } else if !wanted, let t = outboxTimer {
            t.cancel()
            outboxTimer = nil
        }
    }
}

// MARK: - live backends

/// `SessionRemoteBackends` over the real Claude and Codex backends.
final class LiveSessionBackends: SessionRemoteBackends {
    private let claude: ClaudeBackend
    private let codex: CodexBackend
    /// Reads working sessions' card facts; probe queue only.
    private let flightProbe = FlightProbe()

    init(claude: ClaudeBackend, codex: CodexBackend) {
        self.claude = claude
        self.codex = codex
    }

    func probeHosts(_ sessions: [AgentSession]) -> [String: SessionHostInfo] {
        let table = ProcessRunner.processTable()
        guard !table.isEmpty else { return [:] }
        // Whether cmux lets Page in, once per cmux channel per probe: a
        // cmux session Page can't reach is shown as such, not as typable.
        var cmuxChecked: [String: String?] = [:]
        let cmuxBlocker: (CmuxBridge.Target) -> String? = { target in
            if let known = cmuxChecked[target.cliPath] { return known }
            let why: String?
            switch CmuxBridge.connect(cliPath: target.cliPath) {
            case .success: why = nil
            case .failure(let f): why = Self.cmuxBlockerText(f.detail)
            }
            cmuxChecked[target.cliPath] = why
            return why
        }
        let live = Dictionary(grouping: claude.remoteLiveSessions, by: \.sessionId)
        var codexProcesses: [CodexProcess]?
        var out: [String: SessionHostInfo] = [:]
        for s in sessions {
            switch s.backend {
            case .claude:
                out[s.sessionId] = Self.claudeHost(candidates: live[s.sessionId] ?? [], table: table, cmuxBlocker: cmuxBlocker)
            case .codex:
                guard let t = codex.remoteThread(s.sessionId) else {
                    out[s.sessionId] = .blocked("unknown", "Page no longer knows this Codex session")
                    continue
                }
                let provider = ModelProviderClassifier.codex(argv: [], threadModelProvider: t.modelProvider)
                let source = CodexBackend.mapSource(t.source)
                if let fixed = Self.codexHostForSource(source, provider: provider) {
                    out[s.sessionId] = fixed
                    continue
                }
                guard let cwd = t.cwd, !cwd.isEmpty else {
                    out[s.sessionId] = .blocked("unknown", "Codex didn't say where this session runs", provider: provider)
                    continue
                }
                if codexProcesses == nil { codexProcesses = CodexProcessScanner.liveSessions(table: table) }
                let target = CodexInjector.resolveTarget(cwd: CodexProcessScanner.canonicalPath(cwd), rolloutPath: t.path,
                                                         processes: codexProcesses ?? [], cwdFallback: .forSource(source))
                guard case .tty(let tty, let pid) = target else {
                    let why = SessionInputGate.codexTargetProblem(target, project: CodexInjector.projectName(forCwd: cwd))?.detail
                    out[s.sessionId] = .blocked("unknown", why ?? "Couldn't find the Codex session's terminal", provider: provider)
                    continue
                }
                let terminal = CodexInjector.terminal(tty: tty, pid: pid, threadId: t.id, table: table)
                out[s.sessionId] = Self.codexHost(terminal, appHost: CodexInjector.host(ofPid: pid, table: table), provider: provider,
                                                  cmuxBlocker: cmuxBlocker)
            }
        }
        return out
    }

    /// Pure given the host resolver. One process with a terminal, or the
    /// phone is told why not.
    static func claudeHost(candidates: [ClaudeLiveSession], table: [ProcessRunner.ProcessInfoRow],
                           resolveHost: (ClaudeLiveSession, [ProcessRunner.ProcessInfoRow]) -> InjectionExecutor.TerminalHost
                               = { InjectionExecutor.resolveHost(for: $0, processTable: $1) },
                           cmuxBlocker: (CmuxBridge.Target) -> String? = { _ in nil },
                           squadPaused: (ClaudeLiveSession, InjectionExecutor.TerminalHost) -> Bool
                               = { ClaudeSquad.isPausedLive(session: $0, host: $1) }) -> SessionHostInfo {
        guard !candidates.isEmpty else { return .blocked("unknown", "Page can't tell which Claude session this is") }
        switch InjectionExecutor.pickSession(candidates, pagePid: nil, pageStateStart: nil) {
        case .failure(let f):
            return .blocked("unknown", f.detail)
        case .success(let s):
            // No terminal: a headless run (claude -p, an SDK script).
            guard s.tty != nil else { return .blocked("background", "A background run with no terminal — nothing to type into", provider: s.provider) }
            let host = resolveHost(s, table)
            return claudeHostInfo(host, provider: s.provider, cmuxBlocker: cmuxBlocker, squadPaused: squadPaused(s, host))
        }
    }

    /// `cmuxBlocker`: why Page can't reach that cmux (nil: it can).
    /// `squadPaused`: the session is a paused Claude Squad instance.
    static func claudeHostInfo(_ host: InjectionExecutor.TerminalHost, provider: ModelProvider,
                               cmuxBlocker: (CmuxBridge.Target) -> String? = { _ in nil },
                               squadPaused: Bool = false) -> SessionHostInfo {
        switch host {
        case .tmux(_, _, _, let session):
            // A Claude Squad agent is a tmux pane like any other; the phone
            // just names it.
            guard let session, ClaudeSquad.isSquadSession(session) else {
                return SessionHostInfo(host: "tmux", canType: true, canInterrupt: true, provider: provider)
            }
            if squadPaused { return .blocked(ClaudeSquad.hostName, ClaudeSquad.pausedMessage, provider: provider) }
            return SessionHostInfo(host: ClaudeSquad.hostName, canType: true, canInterrupt: true, provider: provider)
        case .terminalApp: return SessionHostInfo(host: "Terminal", canType: true, canInterrupt: false, provider: provider)
        case .iTerm: return SessionHostInfo(host: "iTerm", canType: true, canInterrupt: true, provider: provider)
        case .cmux(let target):
            if let why = cmuxBlocker(target) { return .blocked("cmux", why, provider: provider) }
            return SessionHostInfo(host: "cmux", canType: true, canInterrupt: true, provider: provider)
        case .wezterm: return SessionHostInfo(host: "WezTerm", canType: true, canInterrupt: true, provider: provider)
        case .kitty: return SessionHostInfo(host: "kitty", canType: true, canInterrupt: true, provider: provider)
        case .herdr: return SessionHostInfo(host: "Herdr", canType: true, canInterrupt: true, provider: provider)
        case .unreachable(let why):
            // The host app is known but the exact pane isn't: name the app
            // the reason mentions (cmux unless it's WezTerm, kitty or Herdr).
            let app = why.contains("kitty") ? "kitty" : why.contains("WezTerm") ? "WezTerm" : why.contains("Herdr") ? "Herdr" : "cmux"
            return .blocked(app, why, provider: provider)
        case .unsupported(let app): return .blocked(wireHost(app: app), "Page can't type into \(app) yet", provider: provider)
        case .unknown: return .blocked("unknown", "Couldn't find the session's terminal", provider: provider)
        }
    }

    /// Desktop / editor / exec threads have no terminal to type into.
    static func codexHostForSource(_ source: AgentSessionSource, provider: ModelProvider) -> SessionHostInfo? {
        switch source {
        case .desktop: return .blocked("desktop", "Page can't type into the Codex app — use the Codex CLI in tmux or cmux", provider: provider)
        case .vscode: return .blocked("VS Code", "Page can't type into Codex in VS Code yet", provider: provider)
        case .exec: return .blocked("unknown", "A background codex exec run — there's nothing to type into", provider: provider)
        case .remote: return .blocked("unknown", "This session runs somewhere else", provider: provider)
        case .terminal, .unknown: return nil
        }
    }

    static func codexHost(_ terminal: CodexInjector.Terminal, appHost: CodexInjector.Host, provider: ModelProvider,
                          cmuxBlocker: (CmuxBridge.Target) -> String? = { _ in nil }) -> SessionHostInfo {
        switch terminal {
        case .tmux: return SessionHostInfo(host: "tmux", canType: true, canInterrupt: true, provider: provider)
        case .cmux(let target):
            if let why = cmuxBlocker(target) { return .blocked("cmux", why, provider: provider) }
            return SessionHostInfo(host: "cmux", canType: true, canInterrupt: true, provider: provider)
        case .terminalApp: return .blocked("Terminal", SessionInputGate.codexTerminalAppBlocker, provider: provider)
        case .unavailable(let why):
            let host: String
            switch appHost {
            case .tmux: host = "tmux"
            case .terminalApp: host = "Terminal"
            case .app(let name): host = wireHost(app: name)
            case .unknown: host = "unknown"
            }
            return .blocked(host, why, provider: provider)
        }
    }

    /// The phone shows this instead of the composer: the Mac-side fix, in
    /// words that make sense on the phone.
    static func cmuxBlockerText(_ detail: String) -> String {
        switch detail {
        case CmuxBridge.blockedDetail, CmuxBridge.needsPasswordDetail, CmuxBridge.passwordRejectedDetail:
            return "cmux isn't letting Page type yet — on your Mac, open Page ▸ Integrations ▸ Set up cmux… and click “Let Page type into cmux”"
        default:
            return detail
        }
    }

    /// The spec's host values; anything else is "unknown" (the blocker
    /// names the app).
    static func wireHost(app: String) -> String {
        let lower = app.lowercased()
        if lower == "cmux" || lower.hasPrefix("cmux ") { return "cmux" }
        switch app {
        case "Terminal": return "Terminal"
        case "iTerm2", "iTerm": return "iTerm"
        case "Ghostty": return "Ghostty"
        case "VS Code", "Code", "Visual Studio Code": return "VS Code"
        default: return "unknown"
        }
    }

    func liveStatuses(_ sessions: [AgentSession]) -> [String: ClaudeSessionStatus] {
        let wanted = Set(sessions.map(\.sessionId))
        var out: [String: ClaudeSessionStatus] = [:]
        for s in claude.remoteLiveSessions where wanted.contains(s.sessionId) && s.hasSessionFile && out[s.sessionId] == nil {
            if let status = claude.remoteStatus(pid: s.pid) { out[s.sessionId] = status }
        }
        return out
    }

    func flightFacts(_ sessions: [AgentSession]) -> [String: InFlightFacts] {
        flightProbe.facts(for: sessions, live: claude.remoteLiveSessions, transcriptFile: { [self] in transcriptFile(for: $0) })
    }

    func transcriptFile(for session: AgentSession) -> SessionTranscriptFile? {
        switch session.backend {
        case .claude:
            return claude.remoteTranscriptURL(sessionId: session.sessionId, cwd: session.cwd)
                .map { SessionTranscriptFile(path: $0.path, format: .claude) }
        case .codex:
            return codex.remoteThread(session.sessionId)?.path
                .flatMap { $0.isEmpty ? nil : SessionTranscriptFile(path: $0, format: .codex) }
        }
    }

    func screenSource(for session: AgentSession) -> SessionScreen.Source? {
        let table = ProcessRunner.processTable()
        guard !table.isEmpty else { return nil }
        switch session.backend {
        case .claude:
            let candidates = claude.remoteLiveSessions.filter { $0.sessionId == session.sessionId }
            guard case .success(let s) = InjectionExecutor.pickSession(candidates, pagePid: nil, pageStateStart: nil),
                  s.tty != nil else { return nil }
            return SessionScreen.source(for: InjectionExecutor.resolveHost(for: s, processTable: table))
        case .codex:
            guard let t = codex.remoteThread(session.sessionId), let cwd = t.cwd, !cwd.isEmpty else { return nil }
            let target = CodexInjector.resolveTarget(cwd: CodexProcessScanner.canonicalPath(cwd), rolloutPath: t.path,
                                                     processes: CodexProcessScanner.liveSessions(table: table),
                                                     cwdFallback: .forSource(CodexBackend.mapSource(t.source)))
            guard case .tty(let tty, let pid) = target else { return nil }
            return SessionScreen.source(for: CodexInjector.terminal(tty: tty, pid: pid, threadId: t.id, table: table))
        }
    }

    func input(_ session: AgentSession, clientId: String, text: String, interventionId: String?,
               completion: @escaping (SessionCommandResult) -> Void) {
        switch session.backend {
        case .claude:
            claude.remoteInput(sessionId: session.sessionId, clientId: clientId, text: text,
                               interventionId: interventionId, completion: completion)
        case .codex:
            codex.remoteInput(threadId: session.sessionId, text: text, interventionId: interventionId, completion: completion)
        }
    }

    func answer(_ session: AgentSession, request: AnswerRequest, completion: @escaping (SessionCommandResult) -> Void) {
        switch session.backend {
        case .claude:
            claude.remoteAnswer(sessionId: session.sessionId, request: request, completion: completion)
        case .codex:
            completion(.refused(.answerUnsupported, "Page can't answer Codex's questions from here"))
        }
    }

    func interrupt(_ session: AgentSession, interventionId: String?, completion: @escaping (SessionCommandResult) -> Void) {
        switch session.backend {
        case .claude:
            claude.remoteInterrupt(sessionId: session.sessionId, interventionId: interventionId, completion: completion)
        case .codex:
            codex.remoteInterrupt(threadId: session.sessionId, interventionId: interventionId, completion: completion)
        }
    }

    func typeHeld(_ session: AgentSession, clientId: String, text: String, claim: HeldClaim,
                  completion: @escaping (SessionCommandResult) -> Void) {
        switch session.backend {
        case .claude:
            claude.remoteInput(sessionId: session.sessionId, clientId: clientId, text: text, interventionId: nil,
                               held: claim, completion: completion)
        case .codex:
            codex.remoteInput(threadId: session.sessionId, text: text, interventionId: nil, held: claim, completion: completion)
        }
    }

    func inputImages(_ session: AgentSession, clientId: String, images: [AssembledImage], text: String,
                     interventionId: String?, completion: @escaping (SessionCommandResult) -> Void) {
        switch session.backend {
        case .claude:
            claude.remoteImages(sessionId: session.sessionId, clientId: clientId, images: images, text: text,
                                interventionId: interventionId, completion: completion)
        case .codex:
            completion(.refused(.attachUnsupported, ImageDelivery.codexMessage))
        }
    }

    func retractReply(interventionId: String) -> HeldRetract {
        let claudeSays = claude.retractHeld(interventionId: interventionId)
        guard claudeSays == .notFound else { return claudeSays }
        return codex.retractHeld(interventionId: interventionId)
    }

    func knownFolders(live: [AgentSession]) -> [SessionStarter.Folder] {
        let recent = SessionStarter.recentFolders(projectsDirectory: claude.config.transcriptDirectory)
        return SessionStarter.merge(live: live.filter { $0.backend == .claude }.compactMap(\.cwd), recent: recent, now: Date())
    }

    func startSession(folder: SessionStarter.Folder, prompt: String) -> SessionCommandResult {
        SessionStarter.start(folder: folder, prompt: prompt)
    }
}
