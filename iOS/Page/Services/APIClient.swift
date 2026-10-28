import Foundation
import Combine

/// Client for the Cloudflare Worker relay:
/// - REST: GET /interventions, /history, /status; POST /reply/:id,
///   /device/register, /device/unregister, /sessions/command
/// - WebSocket /ws: live `intervention.opened` / `intervention.closed`,
///   `heartbeat`, `mac.status`, `reply.result` and `relay.retired` frames,
///   plus encrypted `sessions.update` frames, which go to `SessionStore`
///
/// Credentials are read from the Keychain on every call (`RelayCredentials`),
/// so this works the same from a lock-screen action on a cold background
/// launch as it does from the UI. All published state is main-actor.
@MainActor
final class APIClient: NSObject, ObservableObject {
    static let shared = APIClient()

    enum ConnectionState: Equatable {
        case disconnected, connecting, connected
    }

    enum LoadState: Equatable {
        case idle, loading, loaded, failed(String)

        var failureMessage: String? {
            if case .failed(let m) = self { return m }
            return nil
        }
    }

    /// Where a reply to one intervention stands (see `ReplyDelivery`).
    typealias DeliveryState = ReplyDelivery

    @Published private(set) var inbox: [Intervention] = [] {
        // Only a fresh inbox is the truth. On a cold launch nothing is
        // loaded yet; after the app was suspended the in-memory list misses
        // every page that opened meanwhile (the relay's alert pushes set the
        // badge from its own pending count then). Recounting a stale list
        // would undercount, so the badge waits for the next successful fetch.
        didSet {
            if inboxLoad == .loaded, inboxIsFresh {
                NotificationService.shared.setBadge(inbox.count)
                WidgetShare.reload(needsYou: inbox.count, working: macStatus?.working)
            }
        }
    }
    /// True from a successful inbox fetch until the socket is closed for
    /// the background (or the pairing changes): while it holds, socket
    /// events keep `inbox` current.
    private var inboxIsFresh = false
    @Published private(set) var history: [Intervention] = []
    @Published private(set) var connection: ConnectionState = .disconnected
    @Published private(set) var inboxLoad: LoadState = .idle
    @Published private(set) var historyLoad: LoadState = .idle
    @Published private(set) var macStatus: MacStatusSnapshot?
    /// The relay answered 401/403: the pairing token is no longer accepted.
    @Published private(set) var authRejected = false
    /// The relay says the Mac replaced this pairing (410 `token_retired` or
    /// a `relay.retired` frame): the relay's explanation. While set, nothing
    /// talks to the relay; PairingStore unpairs and shows the re-pair screen.
    @Published private(set) var retiredWhy: String?
    @Published private(set) var deliveries: [String: DeliveryState] = [:]
    /// When each entry of `deliveries` last changed, so a failure can age out of Now.
    private(set) var deliveryTimes: [String: Date] = [:]
    /// Close reasons for pages that closed while the app was watching, so an
    /// open reply sheet can say *why* it closed.
    @Published private(set) var recentCloseReasons: [String: String] = [:]

    #if DEBUG
    /// "Skip pairing (DEV)": mock data only, never touches the network.
    private(set) var isDevMode = false
    #endif

    // REST requests fail fast instead of waiting for connectivity: a lock-
    // screen action only has ~30s of background time, and the UI should show
    // "can't reach your relay" rather than spin.
    private lazy var restSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 30
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpAdditionalHeaders = ["User-Agent": "page-ios/\(Self.appVersion)"]
        return URLSession(configuration: cfg)
    }()

    private lazy var wsSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    // WebSocket state. Every callback checks `task === wsTask` so events from
    // a socket we already replaced (re-pair, reconnect) are ignored.
    private var wsTask: URLSessionWebSocketTask?
    private var wsCredentials: RelayCredentials?
    private var wantsConnection = false
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private static let pingInterval: TimeInterval = 25
    /// Last frame or pong from the current socket (see `SocketLiveness`).
    private var lastInboundAt = Date()

    // Inbox race protection: WS events that arrive while a GET is in flight
    // are replayed on top of the GET result, so nothing is lost or resurrected.
    private enum InboxEvent {
        case opened(Intervention)
        case closed(String)
    }
    private var inboxEvents: [(seq: Int, event: InboxEvent)] = []
    private var inboxSeq = 0
    /// `inboxSeq` at the last local change to each reply's delivery state
    /// (our POST, a `reply.result` frame). A fetch that started earlier
    /// carries older delivery news for that id and must not overwrite it.
    private var deliveryTouchedSeq: [String: Int] = [:]
    private var inboxFetchCounter = 0
    private var lastAppliedInboxFetch = 0
    /// nil until we know; false once an old Worker answered 404 to /status.
    private var statusEndpointAvailable: Bool?

    /// The relay is known to predate delivery reporting (it answered 404 to
    /// /status), so an unconfirmed reply never turns into "failed" and a
    /// second answer isn't blocked by an ack window.
    var relayIsLegacy: Bool { statusEndpointAvailable == false }

    private override init() {
        super.init()
    }

    static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    private func credentials() -> RelayCredentials? {
        #if DEBUG
        if isDevMode { return nil }
        #endif
        // A retired token gets 410 for everything: stop calling and
        // reconnecting until the pairing is replaced.
        if retiredWhy != nil { return nil }
        return RelayCredentials.current()
    }

    #if DEBUG
    /// Inject mock interventions for development. Bypasses the network entirely.
    func seedDevInbox(_ list: [Intervention]) {
        reset()
        isDevMode = true
        inboxLoad = .loaded
        inboxIsFresh = true
        inbox = Intervention.urgencySorted(list)
        historyLoad = .loaded
        macStatus = MacStatusSnapshot(macConnected: true, lastHeartbeatAt: Date(), activeSessions: list.count, battery: 82, onAC: true)
        connection = .connected
    }

    /// Walks a DEV reply through the same states a real one goes through.
    private func simulateDevReply(_ id: String) async -> ReplyOutcome {
        deliveries[id] = .sending
        try? await Task.sleep(nanoseconds: 400_000_000)
        deliveries[id] = .sent(queued: false, at: Date())
        Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard self.isDevMode else { return }
            self.deliveries[id] = .delivered(detail: "Typed into tmux pane %3 (simulated)")
            self.applyClose(id: id, reason: "replied")
        }
        return .accepted(queued: false)
    }
    #endif

    // MARK: Lifecycle

    /// Clears everything tied to the current pairing. Called on unpair and
    /// before adopting a new pairing, so data from one relay can never leak
    /// into another.
    func reset() {
        disconnect()
        #if DEBUG
        isDevMode = false
        #endif
        inboxIsFresh = false
        inbox = []
        history = []
        inboxLoad = .idle
        historyLoad = .idle
        macStatus = nil
        authRejected = false
        retiredWhy = nil
        deliveries = [:]
        deliveryTimes = [:]
        deliveryTouchedSeq = [:]
        recentCloseReasons = [:]
        inboxEvents = []
        statusEndpointAvailable = nil
        reconnectAttempt = 0
        // The live-sessions key belongs to the pairing being reset. Adopting
        // a new pairing calls this before it writes its own key, so a pairing
        // without `sk` can't inherit the previous Mac's.
        SessionKeyStore.clear()
        SessionStore.shared.reset()
    }

    /// Foreground + paired: open the socket and pull fresh state.
    func activate() {
        connect()
        Task {
            await refreshInbox()
            await refreshStatus()
        }
    }

    /// Pull-to-refresh: everything the current screen might show.
    func refreshAll() async {
        connect()
        await refreshInbox()
        await refreshStatus()
        if historyLoad != .idle { await refreshHistory() }
    }

    // MARK: REST

    private func request(_ url: URL, method: String = "GET", token: String, json: [String: Any]? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        return req
    }

    private func perform(_ req: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await restSession.data(for: req)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    func refreshInbox() async {
        guard let creds = credentials(), let url = creds.url("interventions") else { return }
        inboxFetchCounter += 1
        let fetchId = inboxFetchCounter
        let startSeq = inboxSeq
        if inboxLoad != .loaded { inboxLoad = .loading }
        do {
            let (data, status) = try await perform(request(url, token: creds.token))
            guard creds == credentials() else { return }  // unpaired / re-paired meanwhile
            guard (200..<300).contains(status) else {
                handleHTTPFailure(status, body: data, into: &inboxLoad)
                return
            }
            let decoded = try JSONDecoder.page().decode(LossyList<Intervention>.self, from: data)
            if decoded.droppedCount > 0 {
                print("[APIClient] skipped \(decoded.droppedCount) undecodable intervention(s)")
            }
            // An older request finishing after a newer one must not win.
            guard fetchId > lastAppliedInboxFetch else { return }
            lastAppliedInboxFetch = fetchId
            inboxLoad = .loaded
            inboxIsFresh = true
            applyFetchedInbox(decoded.elements, since: startSeq)
            authRejected = false
            NotificationService.shared.removeDelivered(notIn: Set(inbox.map(\.id)))
        } catch {
            guard creds == credentials() else { return }
            inboxLoad = .failed(Self.describe(error))
        }
    }

    private func applyFetchedInbox(_ fetched: [Intervention], since startSeq: Int) {
        var byId: [String: Intervention] = [:]
        for iv in fetched { byId[iv.id] = iv }
        for entry in inboxEvents where entry.seq > startSeq {
            switch entry.event {
            case .opened(let iv): byId[iv.id] = iv
            case .closed(let id): byId[id] = nil
            }
        }
        inbox = Intervention.urgencySorted(Array(byId.values))
        syncDeliveries(from: inbox, since: startSeq)
    }

    /// Fold the Worker's view of each reply (v2 `deliveryStatus`, or v1
    /// `repliedAt`) into local state — covers replies sent from the lock
    /// screen or before a relaunch. Ids whose delivery changed locally after
    /// the fetch started keep their newer local state.
    private func syncDeliveries(from list: [Intervention], since startSeq: Int) {
        let now = Date()
        for iv in list {
            if let touched = deliveryTouchedSeq[iv.id], touched > startSeq { continue }
            let local = deliveries[iv.id]
            let next = ReplyDelivery.synced(local: local, deliveryStatus: iv.deliveryStatus,
                                            deliveryDetail: iv.deliveryDetail, deliveryMethod: iv.deliveryMethod,
                                            repliedAt: iv.repliedAt, forwardedAt: iv.deliveryForwardedAt,
                                            hookBlocking: iv.isBlockingHook, now: now)
            if next != local { deliveries[iv.id] = next; deliveryTimes[iv.id] = now }
        }
    }

    /// Records a local delivery change so an in-flight fetch can't undo it.
    private func setDelivery(_ id: String, _ state: DeliveryState) {
        inboxSeq += 1
        deliveryTouchedSeq[id] = inboxSeq
        if deliveryTouchedSeq.count > 200 {
            deliveryTouchedSeq = deliveryTouchedSeq.filter { $0.value > inboxSeq - 200 }
        }
        deliveries[id] = state
        deliveryTimes[id] = Date()
    }

    func refreshHistory() async {
        guard let creds = credentials(),
              let url = creds.url("history", query: [URLQueryItem(name: "limit", value: "500")]) else { return }
        if historyLoad != .loaded { historyLoad = .loading }
        do {
            let (data, status) = try await perform(request(url, token: creds.token))
            guard creds == credentials() else { return }
            guard (200..<300).contains(status) else {
                handleHTTPFailure(status, body: data, into: &historyLoad)
                return
            }
            let decoded = try JSONDecoder.page().decode(LossyList<Intervention>.self, from: data)
            history = decoded.elements.sorted { ($0.closedAt ?? $0.openedAt) > ($1.closedAt ?? $1.openedAt) }
            historyLoad = .loaded
        } catch {
            guard creds == credentials() else { return }
            historyLoad = .failed(Self.describe(error))
        }
    }

    /// GET /status (v2 Workers). Old Workers answer 404, in which case Mac
    /// presence comes from heartbeat frames alone.
    func refreshStatus() async {
        guard statusEndpointAvailable != false,
              let creds = credentials(), let url = creds.url("status") else { return }
        do {
            let (data, status) = try await perform(request(url, token: creds.token))
            guard creds == credentials() else { return }
            switch status {
            case 200..<300:
                statusEndpointAvailable = true
                if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    // `features` tells "relay too old" apart from "no sessions".
                    SessionStore.shared.relayFeaturesUpdated((json["features"] as? [Any])?.compactMap { $0 as? String } ?? [])
                    let wasConnected = macStatus?.macConnected == true
                    var snap = MacStatusSnapshot.from(json: json)
                    // Keep a newer heartbeat we got over the socket.
                    if let mine = macStatus?.lastHeartbeatAt, mine > (snap.lastHeartbeatAt ?? .distantPast) {
                        snap.lastHeartbeatAt = mine
                    }
                    macStatus = snap
                    if snap.macConnected == true, !wasConnected { SessionStore.shared.macCameOnline() }
                }
            case 404:
                statusEndpointAvailable = false
                // Predates /status, so it predates live sessions too. Set
                // here: later refreshes return early once this is known.
                SessionStore.shared.relayFeaturesUpdated([])
            case 401, 403:
                authRejected = true
            default:
                if let why = TokenRetirement.why(status: status, body: data) { markRetired(why) }
            }
        } catch {
            // Transport errors surface through the inbox load / socket state.
        }
    }

    /// Only called for responses to the current credentials (callers check
    /// `creds == credentials()` first), so a late 410 for an old token can
    /// never retire a pairing adopted meanwhile.
    private func handleHTTPFailure(_ status: Int, body: Data, into state: inout LoadState) {
        if let why = TokenRetirement.why(status: status, body: body) {
            markRetired(why)
            return
        }
        switch status {
        case 401, 403:
            authRejected = true
            state = .failed("The relay no longer accepts this pairing.")
        case 404:
            state = .failed("The relay doesn't recognise this request (HTTP 404). Is the relay URL on your Mac right?")
        default:
            state = .failed("The relay returned an error (HTTP \(status)).")
        }
    }

    /// Sends a reply. Never removes the card optimistically: it stays until
    /// the Mac closes the page, and `deliveries` shows the progress.
    @discardableResult
    func reply(to interventionId: String, text: String, action: ReplyAction) async -> ReplyOutcome {
        if let problem = ReplyOutcome.validate(text: text, action: action) {
            return .failed(problem)
        }
        #if DEBUG
        if isDevMode { return await simulateDevReply(interventionId) }
        #endif
        guard let creds = credentials(), let url = creds.url("reply", interventionId) else {
            let outcome = ReplyOutcome.failed("Page isn't paired with a Mac.")
            setDelivery(interventionId, .failed("Page isn't paired with a Mac."))
            return outcome
        }
        setDelivery(interventionId, .sending)
        let req = request(url, method: "POST", token: creds.token, json: ["text": text, "action": action.rawValue])
        let outcome: ReplyOutcome
        do {
            let (data, status) = try await perform(req)
            outcome = ReplyOutcome.from(status: status, body: data)
        } catch {
            outcome = .failed("Couldn't reach your relay: \(Self.describe(error))")
        }
        guard creds == credentials() else { return outcome }
        switch outcome {
        case .accepted(let queued):
            // A fast Mac can report the result (success or failure) before
            // our POST returns; that newer news wins.
            let next = ReplyDelivery.afterAccepted(deliveries[interventionId], queued: queued, at: Date())
            if next != deliveries[interventionId] { setDelivery(interventionId, next) }
        case .inFlight:
            // An earlier reply (ours, or a lock-screen action) is still
            // waiting for the Mac to confirm it. The relay refuses another
            // answer until it does or its ack window runs out, so show
            // "waiting" from now rather than a terminal "already answered".
            setDelivery(interventionId, .sent(queued: false, at: Date()))
        case .alreadyReplied:
            setDelivery(interventionId, .alreadyReplied)
        case .gone:
            setDelivery(interventionId, .gone)
            applyClose(id: interventionId, reason: recentCloseReasons[interventionId])
        case .unauthorized:
            authRejected = true
            setDelivery(interventionId, .failed("The relay no longer accepts this pairing. Re-pair with your Mac."))
        case .retired(let why):
            markRetired(why)
        case .failed(let message):
            setDelivery(interventionId, .failed(message))
        }
        return outcome
    }

    /// DELETE /reply/<id>: takes back a reply the relay is holding for an offline Mac. Offered only when
    /// `/status` lists `reply-retract-v1`; an old relay would answer 404 `not_found`. The answer is said
    /// in words under the reply (`SessionStore.retractNotes`), and a deleted reply frees the page.
    func retractReply(_ id: String) async {
        let store = SessionStore.shared
        guard RelayQueue.canDelete(features: store.relayFeatures), store.retractNotes[id]?.isBusy != true else { return }
        #if DEBUG
        if isDevMode {
            store.noteRelayRetract(id: id, .deleting)
            try? await Task.sleep(nanoseconds: 600_000_000)
            setDelivery(id, .retracted(SessionDeliveryState.deletedCopy))
            store.noteRelayRetract(id: id, .deleted(SessionDeliveryState.deletedCopy))
            return
        }
        #endif
        guard let creds = credentials(), let url = creds.url("reply", id) else {
            store.noteRelayRetract(id: id, .failed("Page isn't paired with a Mac."))
            return
        }
        store.noteRelayRetract(id: id, .deleting)
        let outcome: RelayRetractOutcome
        do {
            let (data, status) = try await perform(request(url, method: "DELETE", token: creds.token))
            outcome = RelayRetractOutcome.from(status: status, body: data)
        } catch {
            outcome = .failed(RelayRetractOutcome.transportCopy)
        }
        guard creds == credentials() else { return }
        // "forwarded": the relay handed it to the Mac, which may still hold it (rate-limit or resume queue), so the
        // note is Page's ask to the Mac, not the relay's last word. "delivered" never asks.
        var askMac = false
        if case .tooLate(let stage) = outcome, ForwardedRetract.asksMac(stage: stage, macCaps: store.macCaps) { askMac = true }
        store.noteRelayRetract(id: id, askMac ? .askingMac : outcome.note)
        switch outcome {
        case .deleted:
            setDelivery(id, .retracted(SessionDeliveryState.deletedCopy))
        case .tooLate(let stage):
            // The Mac has it: no longer queued, so it waits for the Mac's own word.
            if stage == "forwarded" || stage == "delivered" { setDelivery(id, .sent(queued: false, at: Date())) }
            if askMac, let sessionId = (inbox + history).first(where: { $0.id == id })?.sessionId {
                store.askMacToRetractForwarded(interventionId: id, sessionId: sessionId)
            } else if askMac {
                store.noteRelayRetract(id: id, ForwardedRetract.timeoutNote)
            }
        case .nothing:
            // The relay holds nothing for this page: look again at what it says happened.
            Task { await refreshInbox() }
        case .pageGone:
            // The page isn't pending any more: nothing of it is left to answer or delete.
            setDelivery(id, .gone)
        case .retired(let why):
            markRetired(why)
        case .hookHeld, .oldRelay, .failed:
            break
        }
    }

    /// The Mac deleted a reply it was holding (a `retract` answered `deleted`): the page takes a new reply.
    func markRetracted(interventionId id: String, detail: String) {
        switch deliveries[id] {
        case .heldOnMac?, .sent?, .delivered?: setDelivery(id, .retracted(detail))
        default: break
        }
    }

    /// POST /sessions/command with an already-encrypted `{"e": …}` body.
    /// The relay only forwards it; what the Mac did arrives later as a
    /// `result` inside `sessions.update`. 401/403 and 410 `token_retired`
    /// are handled like every other call.
    func postSessionCommand(body: Data) async -> SessionCommandOutcome {
        guard let creds = credentials(), let url = creds.url("sessions", "command") else {
            return .failed("Page isn't paired with a Mac.")
        }
        var req = request(url, method: "POST", token: creds.token)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let outcome: SessionCommandOutcome
        do {
            let (data, status) = try await perform(req)
            outcome = SessionCommandOutcome.from(status: status, body: data)
        } catch {
            outcome = .failed("Couldn't reach your relay: \(Self.describe(error))")
        }
        guard creds == credentials() else { return outcome }  // unpaired / re-paired meanwhile
        switch outcome {
        case .unauthorized: authRejected = true
        case .retired(let why): markRetired(why)
        default: break
        }
        return outcome
    }

    /// POST /device/register. Returns true on 2xx.
    func registerDevice(apnsToken: String, environment: String) async -> Bool {
        guard let creds = credentials(), let url = creds.url("device", "register") else { return false }
        let req = request(url, method: "POST", token: creds.token, json: [
            "apnsToken": apnsToken,
            "appVersion": Self.appVersion,
            "apnsEnv": environment
        ])
        do {
            let (data, status) = try await perform(req)
            guard creds == credentials() else { return false }  // unpaired / re-paired meanwhile
            if status == 401 || status == 403 { authRejected = true }
            if let why = TokenRetirement.why(status: status, body: data) { markRetired(why) }
            return (200..<300).contains(status)
        } catch {
            return false
        }
    }

    /// POST /device/unregister with credentials captured before they were
    /// deleted. Best effort: older Workers answer 404, which is fine.
    func unregisterDevice(apnsToken: String, using creds: RelayCredentials) async {
        guard let url = creds.url("device", "unregister") else { return }
        let req = request(url, method: "POST", token: creds.token, json: ["apnsToken": apnsToken])
        _ = try? await perform(req)
    }

    enum ProbeResult: Equatable {
        case ok(MacStatusSnapshot?)
        case unreachable(String)
        case notPageRelay
        case unauthorized
        /// The Mac replaced this code (410 `token_retired`), e.g. an old
        /// screenshot. Carries the relay's explanation.
        case retired(String)
    }

    /// Checks a candidate pairing before it is saved: the host must be a
    /// Page relay (/health) and accept the token (/status, or /interventions
    /// on Workers that predate /status).
    func probe(_ pairing: ValidatedPairing) async -> ProbeResult {
        let creds = RelayCredentials(baseURL: pairing.relayBaseURL, token: pairing.token)
        guard let health = creds.url("health"), let status = creds.url("status"),
              let list = creds.url("interventions") else { return .notPageRelay }
        do {
            let (hData, hResponse) = try await restSession.data(for: URLRequest(url: health))
            let hJSON = (try? JSONSerialization.jsonObject(with: hData)) as? [String: Any]
            guard (hResponse as? HTTPURLResponse)?.statusCode == 200,
                  hJSON?["service"] as? String == "page-relay" else { return .notPageRelay }

            let (sData, sStatus) = try await perform(request(status, token: creds.token))
            // A candidate pairing: report it, never retire the current one.
            if let why = TokenRetirement.why(status: sStatus, body: sData) { return .retired(why) }
            switch sStatus {
            case 200..<300:
                let json = (try? JSONSerialization.jsonObject(with: sData)) as? [String: Any]
                return .ok(json.map(MacStatusSnapshot.from(json:)))
            case 401, 403:
                return .unauthorized
            case 404:
                let (lData, lStatus) = try await perform(request(list, token: creds.token))
                if (200..<300).contains(lStatus) { return .ok(nil) }
                if let why = TokenRetirement.why(status: lStatus, body: lData) { return .retired(why) }
                return lStatus == 401 || lStatus == 403 ? .unauthorized : .notPageRelay
            default:
                return .notPageRelay
            }
        } catch {
            return .unreachable(Self.describe(error))
        }
    }

    // MARK: Closes from outside the socket

    /// Silent close push (app suspended or not running): every id in
    /// `interventionClosedIds`, falling back to the v1 `interventionClosedId`.
    func handleClosePush(interventionIds: Set<String>) async {
        guard !interventionIds.isEmpty else { return }
        // Without a live socket the list may miss pages opened since the
        // last fetch (even one made by an earlier close push), so these
        // closes must not recount the badge from it.
        if connection != .connected { inboxIsFresh = false }
        for id in interventionIds { applyClose(id: id, reason: nil) }
        await NotificationService.shared.removeDelivered(interventionIds: interventionIds)
        // The in-memory inbox is stale after a suspension (it misses pages
        // opened meanwhile) or empty after a cold launch, so recount the
        // badge from the relay's list while we have background time.
        await refreshInbox()
    }

    /// Ids an alert push says it replaced (`interventionClosedIds`:
    /// superseded or evicted pages), seen when the app runs for that alert
    /// (foreground, or the user acting on it). Without a Notification
    /// Service Extension a backgrounded app never sees them; the relay's
    /// close push and the next foreground refresh cover that case.
    func handleClosedIdsFromAlert(_ ids: Set<String>) async {
        guard !ids.isEmpty else { return }
        if connection != .connected { inboxIsFresh = false }
        for id in ids { applyClose(id: id, reason: nil) }
        await NotificationService.shared.removeDelivered(interventionIds: ids)
    }

    /// A page closed without a reason reaching us (silent push, or the
    /// close happened while the socket was down): learn it from the
    /// relay's archive, so a reply that landed isn't reported as "resolved
    /// on your Mac". Hidden reasons (stale, superseded) stay unknown.
    func resolveCloseReason(_ id: String) async {
        guard recentCloseReasons[id] == nil else { return }
        if !history.contains(where: { $0.id == id }) { await refreshHistory() }
        guard recentCloseReasons[id] == nil, inbox.first(where: { $0.id == id }) == nil,
              let reason = history.first(where: { $0.id == id })?.closeReason else { return }
        recentCloseReasons[id] = reason
        if reason == "replied" {
            switch deliveries[id] {
            case .sending?, .sent?, nil: setDelivery(id, .delivered(detail: nil))
            default: break
            }
        }
    }

    private func applyClose(id: String, reason: String?) {
        inboxSeq += 1
        inboxEvents.append((inboxSeq, .closed(id)))
        trimEvents()
        let closing = inbox.first { $0.id == id }
        // Never invent a reason: unknown stays unknown, so the reply screen
        // can look it up instead of claiming the Mac resolved it.
        if let reason {
            recentCloseReasons[id] = reason
        } else if recentCloseReasons[id] == nil, let known = closing?.closeReason {
            recentCloseReasons[id] = known
        }
        if recentCloseReasons.count > 200 { recentCloseReasons = [:] }
        inbox.removeAll { $0.id == id }
        // Our own reply landing: older Workers never send reply.result, the
        // Mac's "replied" close is the success signal.
        if reason == "replied" {
            switch deliveries[id] {
            case .sending?, .sent?, nil: setDelivery(id, .delivered(detail: nil))
            default: break
            }
        }
        // Keep History live without a refetch, mirroring the Worker's rules.
        if var archived = closing, let reason, CloseReason.isHistoryWorthy(reason),
           historyLoad == .loaded, !history.contains(where: { $0.id == id }) {
            archived.closedAt = Date()
            archived.closeReason = reason
            history.insert(archived, at: 0)
        }
    }

    private func trimEvents() {
        if inboxEvents.count > 200 { inboxEvents.removeFirst(inboxEvents.count - 200) }
    }

    // MARK: WebSocket lifecycle

    /// Idempotent. Opens the socket if there isn't one for the current
    /// credentials; replaces a socket that belongs to an old pairing.
    func connect() {
        wantsConnection = true
        guard let creds = credentials() else { return }
        if let task = wsTask, wsCredentials == creds,
           task.state == .running || task.state == .suspended {
            return
        }
        reconnectTask?.cancel()
        reconnectTask = nil
        openSocket(creds)
    }

    /// Background / unpair: close the socket and stop reconnecting.
    func disconnect() {
        wantsConnection = false
        // Socket events stop, so the in-memory inbox starts going stale.
        inboxIsFresh = false
        reconnectTask?.cancel()
        reconnectTask = nil
        teardownSocket()
        connection = .disconnected
    }

    private func openSocket(_ creds: RelayCredentials) {
        teardownSocket()
        guard let url = creds.webSocketURL else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        req.setValue("page-ios/\(Self.appVersion)", forHTTPHeaderField: "User-Agent")
        let task = wsSession.webSocketTask(with: req)
        wsTask = task
        wsCredentials = creds
        connection = .connecting
        task.resume()
        receive(on: task)
        // `connected` flips only when the delegate confirms the handshake.
    }

    private func teardownSocket() {
        pingTask?.cancel()
        pingTask = nil
        let old = wsTask
        // Clear first so callbacks triggered by cancel() fail the identity check.
        wsTask = nil
        wsCredentials = nil
        old?.cancel(with: .goingAway, reason: nil)
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, task === self.wsTask else { return }
                switch result {
                case .failure(let err):
                    print("[APIClient] WS receive error: \(err.localizedDescription)")
                    self.socketDidEnd(task)
                case .success(let msg):
                    self.lastInboundAt = Date()
                    self.handleMessage(msg)
                    self.receive(on: task)
                }
            }
        }
    }

    /// The single path for every kind of socket loss.
    private func socketDidEnd(_ task: URLSessionTask, closeSaysRetired: Bool = false) {
        guard task === wsTask else { return }
        // Read before teardown: a refused upgrade (no 101) says why it was
        // refused only through its status. A retired token or a rejected
        // one is confirmed over REST, where the body is readable; /status
        // then marks it, which also stops the reconnects.
        let handshakeStatus = (task.response as? HTTPURLResponse)?.statusCode
        // The receive error usually beats the didCloseWith callback here,
        // so read the close frame off the task too.
        var closeSaysRetired = closeSaysRetired
        if let ws = task as? URLSessionWebSocketTask, ws.closeCode != .invalid,
           TokenRetirement.socketCloseNeedsCheck(code: ws.closeCode.rawValue, reason: ws.closeReason) {
            closeSaysRetired = true
        }
        teardownSocket()
        connection = .disconnected
        if closeSaysRetired || handshakeStatus.map(TokenRetirement.handshakeNeedsCheck(status:)) == true {
            Task { await self.confirmRefusedUpgrade() }
        }
        scheduleReconnect()
    }

    /// GET /status classifies 401/403 and 410 `token_retired`. On a relay
    /// without /status, /interventions does the same through
    /// handleHTTPFailure.
    private func confirmRefusedUpgrade() async {
        if statusEndpointAvailable == false {
            await refreshInbox()
        } else {
            await refreshStatus()
        }
    }

    /// The Mac replaced this pairing. Everything from it is now dead: drop
    /// the socket, the inbox, history, deliveries and every banner, and stop
    /// talking to the relay. PairingStore (watching `retiredWhy`) unpairs
    /// and shows the re-pair screen with `why`.
    private func markRetired(_ why: String) {
        guard retiredWhy == nil else { return }
        #if DEBUG
        if isDevMode { return }
        #endif
        print("[APIClient] pairing retired by the relay: \(why)")
        reset()
        retiredWhy = why
        NotificationService.shared.clearAll()
    }

    private func scheduleReconnect() {
        guard wantsConnection, reconnectTask == nil, credentials() != nil else { return }
        let delay = ReconnectBackoff.delay(attempt: reconnectAttempt, jitter: Double.random(in: 0...1))
        reconnectAttempt += 1
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.reconnectTask = nil
            if self.wantsConnection { self.connect() }
        }
    }

    private func socketDidOpen(_ task: URLSessionWebSocketTask) {
        guard task === wsTask else { return }
        connection = .connected
        reconnectAttempt = 0
        lastInboundAt = Date()
        startPinging(task)
        SessionStore.shared.socketOpened()
        // Anything broadcast while we were disconnected is gone; resync.
        Task {
            await refreshInbox()
            await refreshStatus()
            if historyLoad == .loaded { await refreshHistory() }
        }
    }

    /// Keepalive: detects half-open sockets (Wi-Fi to cellular, NAT timeouts)
    /// that would otherwise sit "connected" while delivering nothing. A pong
    /// error ends the socket at once; a pong that simply never comes is
    /// caught by the liveness deadline (no frame or pong for a ping interval
    /// plus 15s), since URLSession only fails it when TCP gives up.
    private func startPinging(_ task: URLSessionWebSocketTask) {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.pingInterval * 1_000_000_000))
                guard !Task.isCancelled, let self, task === self.wsTask else { return }
                if SocketLiveness.isDead(lastInboundAt: self.lastInboundAt, now: Date(), pingInterval: Self.pingInterval) {
                    print("[APIClient] WS silent past the pong deadline; reconnecting")
                    self.socketDidEnd(task)
                    return
                }
                task.sendPing { [weak self] error in
                    Task { @MainActor in
                        guard let self, task === self.wsTask else { return }
                        if error != nil {
                            self.socketDidEnd(task)
                        } else {
                            self.lastInboundAt = Date()
                        }
                    }
                }
            }
        }
    }

    private func handleMessage(_ msg: URLSessionWebSocketTask.Message) {
        let data: Data
        switch msg {
        case .data(let d): data = d
        case .string(let s): data = Data(s.utf8)
        @unknown default: return
        }
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = envelope["type"] as? String else { return }
        let payload = envelope["payload"] as? [String: Any] ?? [:]
        if let why = TokenRetirement.why(frameType: type, payload: payload) {
            markRetired(why)
            return
        }
        switch type {
        case "intervention.opened":
            guard let pdata = try? JSONSerialization.data(withJSONObject: payload),
                  let iv = try? JSONDecoder.page().decode(Intervention.self, from: pdata) else { return }
            inboxSeq += 1
            inboxEvents.append((inboxSeq, .opened(iv)))
            trimEvents()
            var next = inbox.filter { $0.id != iv.id }
            next.append(iv)
            inbox = Intervention.urgencySorted(next)

        case "intervention.closed":
            guard let id = payload["id"] as? String else { return }
            applyClose(id: id, reason: payload["reason"] as? String)
            Task { await NotificationService.shared.removeDelivered(interventionIds: [id]) }

        case "heartbeat":
            var snap = macStatus ?? MacStatusSnapshot()
            snap.lastHeartbeatAt = PageDate.parse(any: payload["ts"]) ?? Date()
            if let n = payload["activeSessions"] as? NSNumber { snap.activeSessions = n.intValue }
            if let n = payload["battery"] as? NSNumber { snap.battery = n.intValue }
            if let ac = payload["onAC"] as? Bool { snap.onAC = ac }
            snap.applyExtras(payload)
            // A live heartbeat proves the Mac is connected right now.
            if statusEndpointAvailable == true { snap.macConnected = true }
            snap.macEverSeen = true
            macStatus = snap

        case "mac.status":
            var snap = macStatus ?? MacStatusSnapshot()
            let wasConnected = snap.macConnected == true
            if let connected = payload["macConnected"] as? Bool {
                snap.macConnected = connected
                if connected { snap.macEverSeen = true }
            }
            if let hb = PageDate.parse(any: payload["lastHeartbeatAt"]) { snap.lastHeartbeatAt = hb }
            macStatus = snap
            if snap.macConnected == true, !wasConnected { SessionStore.shared.macCameOnline() }

        case "sessions.update":
            // Opaque to the relay; SessionStore decrypts and applies it.
            SessionStore.shared.handleUpdate(payload: payload)

        case "reply.result":
            guard let id = payload["interventionId"] as? String else { return }
            let detail = (payload["detail"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let method = payload["method"] as? String
            if (payload["success"] as? Bool) == true {
                // Held on the Mac until a rate limit resets: not typed yet, and still deletable.
                setDelivery(id, method == HeldUntilReset.method ? .heldOnMac(detail: detail) : .delivered(detail: detail))
            } else if (payload["cancelled"] as? Bool) == true || method == RetractedReply.method {
                // Taken back, from this phone or another: nothing was typed.
                setDelivery(id, .retracted(detail ?? SessionDeliveryState.deletedCopy))
                SessionStore.shared.noteRelayRetract(id: id, nil)
            } else {
                setDelivery(id, .failed(detail ?? "Your Mac couldn't deliver the reply."))
            }

        default:
            break
        }
    }

    // MARK: Errors

    static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "Your iPhone is offline."
            case .cannotFindHost, .dnsLookupFailed:
                return "The relay's address can't be found."
            case .cannotConnectToHost:
                return "The relay isn't accepting connections."
            case .timedOut:
                return "The relay didn't respond in time."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
                return "A secure connection to the relay couldn't be made."
            default:
                return urlError.localizedDescription
            }
        }
        if error is DecodingError {
            return "The relay sent data this version of Page doesn't understand."
        }
        return error.localizedDescription
    }
}

// MARK: - URLSessionWebSocketDelegate

extension APIClient: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession,
                                webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol protocol: String?) {
        Task { @MainActor in self.socketDidOpen(webSocketTask) }
    }

    nonisolated func urlSession(_ session: URLSession,
                                webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                                reason: Data?) {
        let saysRetired = TokenRetirement.socketCloseNeedsCheck(code: closeCode.rawValue, reason: reason)
        Task { @MainActor in self.socketDidEnd(webSocketTask, closeSaysRetired: saysRetired) }
    }

    nonisolated func urlSession(_ session: URLSession,
                                task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard error != nil else { return }
        Task { @MainActor in self.socketDidEnd(task) }
    }
}
