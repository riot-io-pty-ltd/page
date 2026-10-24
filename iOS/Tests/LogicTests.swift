// Plain-swiftc tests for the Foundation-only logic in Page/Models (wire
// decoding, ordering, pairing validation, notification-action decisions,
// presence, stats). No simulator or XCTest needed: run ./Tests/run-logic-tests.sh

import Foundation

var failures = 0
var passes = 0
func check(_ cond: Bool, _ msg: String, file: String = #file, line: Int = #line) {
    if cond { passes += 1 } else { failures += 1; print("FAIL line \(line): \(msg)") }
}

// Dates
check(PageDate.parse("2026-10-24T01:02:03.456Z") != nil, "fractional")
check(PageDate.parse("2026-10-24T01:02:03Z") != nil, "plain")
check(PageDate.parse("2026-10-24T11:02:03+10:00") == PageDate.parse("2026-10-24T01:02:03Z"), "offset")
check(PageDate.parse("garbage") == nil, "garbage")
check(PageDate.parse(any: NSNumber(value: 1_700_000_000_000.0)) == Date(timeIntervalSince1970: 1_700_000_000), "ms epoch")

// Lossy decode
let json = """
[
 {"id":"a","sessionId":"s1","cwd":"/Users/x/p","projectName":"p","kind":"permission","openedAt":"2026-10-24T01:02:03.456Z","context":"Bash: ls"},
 {"id":"b","sessionId":"s2","kind":"weird_new_kind","openedAt":"2026-10-24T01:02:04Z","context":5,"backend":"gemini","source":"phone"},
 {"id":"c","kind":"question","openedAt":"2026-10-24T01:02:04Z"},
 {"id":"d","sessionId":"s4","kind":"idle","openedAt":"not a date"},
 null,
 {"id":"e","sessionId":"s5","kind":"question","openedAt":"2026-10-24T01:02:05Z","closedAt":"bad","deliveryStatus":"failed","deliveryDetail":"nope","cwd":"/Users/me/code/thing"}
]
"""
let lossy = try! JSONDecoder.page().decode(LossyList<Intervention>.self, from: Data(json.utf8))
check(lossy.elements.map(\.id) == ["a","b","e"], "lossy ids \(lossy.elements.map(\.id))")
check(lossy.droppedCount == 3, "dropped \(lossy.droppedCount)")
check(lossy.elements[0].kind == .approval, "permission->approval")
check(lossy.elements[1].kind == .userInput, "unknown->userInput")
check(lossy.elements[1].context == "", "non-string context defaults")
check(lossy.elements[1].backend == nil, "unknown backend nil")
check(lossy.elements[1].source == .unknown, "unknown source")
check(lossy.elements[1].projectName == "Unknown project", "project fallback")
check(lossy.elements[2].projectName == "thing", "project from cwd")
check(lossy.elements[2].closedAt == nil && lossy.elements[2].deliveryStatus == "failed", "bad optional date tolerated")

// Sorting
func iv(_ id: String, _ kind: InterventionKind, _ t: TimeInterval, replied: TimeInterval? = nil, project: String = "p") -> Intervention {
    var x = Intervention(id: id, sessionId: id, cwd: "", projectName: project, kind: kind, openedAt: Date(timeIntervalSince1970: t), context: "")
    if let r = replied { x.repliedAt = Date(timeIntervalSince1970: r) }
    return x
}
let sorted = Intervention.urgencySorted([iv("i1", .idle, 100), iv("q1", .userInput, 50), iv("a1", .approval, 10), iv("a2", .approval, 20), iv("r", .rateLimit, 999)])
check(sorted.map(\.id) == ["a2","a1","q1","i1","r"], "urgency \(sorted.map(\.id))")

// Relative
let now = Date(timeIntervalSince1970: 10_000)
check(RelativeTime.string("Paged", since: now.addingTimeInterval(3), now: now) == "Paged just now", "future clamps")
check(RelativeTime.string("Paged", since: now.addingTimeInterval(-12), now: now) == "Paged 12s ago", "12s")
check(RelativeTime.string("Paged", since: now.addingTimeInterval(-300), now: now) == "Paged 5m ago", "5m")
check(RelativeTime.compact(seconds: 90_000) == "1d", "1d")

// Path
check(PathDisplay.abbreviatingHome("/Users/roy/projects/x") == "~/projects/x", "path")
check(PathDisplay.abbreviatingHome("/Users/roy") == "~", "home only")
check(PathDisplay.abbreviatingHome("/opt/x") == "/opt/x", "non-home")

// Pairing
let good = #"{"v":1,"token":"abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG","relay":"wss://page.example.workers.dev/ws","host":"Roy's Mac"}"#
if case .success(let p) = PairingValidator.validate(good) {
    check(p.relayBaseURL.absoluteString == "https://page.example.workers.dev", "normalised \(p.relayBaseURL)")
    check(p.macName == "Roy's Mac", "name")
} else { check(false, "good payload") }
let curly = "{\u{201C}v\u{201D}:1,\u{201C}token\u{201D}:\u{201C}abcdefghijklmnopqrstuvwxyz\u{201D},\u{201C}relay\u{201D}:\u{201C}https://r.example.com/\u{201D}}"
if case .success(let p) = PairingValidator.validate(curly) { check(p.relayBaseURL.absoluteString == "https://r.example.com", "curly \(p.relayBaseURL)"); check(p.macName == "Your Mac", "default name") } else { check(false, "curly quotes") }
check(PairingValidator.validate("") == .failure(.empty), "empty")
check(PairingValidator.validate("https://example.com") == .failure(.notPageCode), "url qr")
check(PairingValidator.validate(#"{"ssid":"x"}"#) == .failure(.notPageCode), "other json")
check(PairingValidator.validate(#"{"v":2,"token":"abcdefghijklmnopqrstuvwxyz","relay":"https://a.b"}"#) == .failure(.unsupportedVersion(2)), "v2")
check(PairingValidator.validate(#"{"v":1,"token":"short","relay":"https://a.b"}"#) == .failure(.missingToken), "short token")
check(PairingValidator.validate(#"{"v":1,"token":"abcdefghij klmnopqrstuvwxyz","relay":"https://a.b"}"#) == .failure(.missingToken), "space token")
check(PairingValidator.validate(#"{"v":1,"token":"abcdefghijklmnopqrstuvwxyz","relay":"http://a.b"}"#) == .failure(.insecureRelay), "http")
check(PairingValidator.validate(#"{"v":1,"token":"abcdefghijklmnopqrstuvwxyz","relay":"https://your-page-relay.workers.dev"}"#) == .failure(.placeholderRelay), "placeholder")
check(PairingValidator.validate(#"{"v":1,"token":"abcdefghijklmnopqrstuvwxyz","relay":"nonsense"}"#) == .failure(.invalidRelay), "invalid")
check(PairingValidator.validate(#"{"v":1,"token":"abcdefghijklmnopqrstuvwxyz"}"#) == .failure(.invalidRelay), "missing relay")

// Push env
let prov = Data("garbage\u{0}<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>Entitlements</key><dict><key>aps-environment</key><string>development</string></dict></dict></plist>trailer".utf8)
check(PushEnvironment.apsEnvironment(fromProvision: prov) == "development", "prov parse")
check(PushEnvironment.current(provisionData: nil, isDebugBuild: false) == "production", "no profile release")
check(PushEnvironment.current(provisionData: nil, isDebugBuild: true) == "development", "no profile debug")

// Reply outcomes
check(ReplyOutcome.from(status: 200, body: Data(#"{"ok":true,"queued":true}"#.utf8)) == .accepted(queued: true), "200 queued")
check(ReplyOutcome.from(status: 200, body: Data()) == .accepted(queued: false), "200 empty")
check(ReplyOutcome.from(status: 409, body: Data()) == .alreadyReplied, "409")
check(ReplyOutcome.from(status: 410, body: Data()) == .gone, "410")
check(ReplyOutcome.from(status: 404, body: Data("Not found".utf8)) == .gone, "404")
check(ReplyOutcome.from(status: 401, body: Data()) == .unauthorized, "401")
if case .failed = ReplyOutcome.from(status: 500, body: Data()) {} else { check(false, "500") }
check(ReplyOutcome.validate(text: "  ", action: .custom) != nil, "empty custom refused")
check(ReplyOutcome.validate(text: "", action: .approve) == nil, "approve empty ok")

// Notification decisions
check(NotificationDecision.decide(.open, userText: nil, kind: "permission") == .open, "tap opens")
check(NotificationDecision.decide(.dismiss, userText: nil, kind: "permission") == .ignore, "dismiss")
check(NotificationDecision.decide(.action("APPROVE"), userText: nil, kind: "permission") == .send(text: "", action: .approve), "approve")
check(NotificationDecision.decide(.action("APPROVE"), userText: nil, kind: nil) == .send(text: "", action: .approve), "approve unknown kind (legacy)")
if case .refuse = NotificationDecision.decide(.action("APPROVE"), userText: nil, kind: "idle") {} else { check(false, "approve idle refused") }
if case .refuse = NotificationDecision.decide(.action("CARRY_ON"), userText: nil, kind: "plan") {} else { check(false, "carry on approval refused") }
check(NotificationDecision.decide(.action("CARRY_ON"), userText: nil, kind: "idle") == .send(text: "", action: .carryOn), "carry on")
check(NotificationDecision.decide(.action("REPLY"), userText: "   ", kind: "question") == .ignore, "empty reply ignored")
check(NotificationDecision.decide(.action("REPLY"), userText: " use v2 ", kind: "question") == .send(text: "use v2", action: .custom), "reply")
check(NotificationDecision.decide(.action("SOMETHING"), userText: nil, kind: "question") == .ignore, "unknown action")

// Deep link
check(DeepLink.interventionId(from: URL(string: "page://intervention/abc-123")!) == "abc-123", "deeplink")
check(DeepLink.interventionId(from: URL(string: "page://pair?x=1")!) == nil, "other link")
check(DeepLink.interventionId(from: URL(string: "page://intervention/")!) == nil, "empty id")

// Backoff
check(ReconnectBackoff.delay(attempt: 0, jitter: 0) == 0.5, "b0 \(ReconnectBackoff.delay(attempt: 0, jitter: 0))")
check(ReconnectBackoff.delay(attempt: 10, jitter: 1) == 30, "cap")
check(ReconnectBackoff.delay(attempt: 3, jitter: 0.5) == 6, "mid")

// Presence
let hbOld = MacStatusSnapshot(macConnected: nil, lastHeartbeatAt: now.addingTimeInterval(-200))
check(MacPresence.evaluate(nil, now: now) == .unknown, "nil")
check(MacPresence.evaluate(hbOld, now: now) == .offline(lastSeen: now.addingTimeInterval(-200)), "old worker stale -> offline")
check(MacPresence.evaluate(MacStatusSnapshot(macConnected: nil, lastHeartbeatAt: now.addingTimeInterval(-10)), now: now).isReachable, "old worker fresh")
check(MacPresence.evaluate(MacStatusSnapshot(macConnected: true, lastHeartbeatAt: now.addingTimeInterval(-200)), now: now) == .stale(lastSeen: now.addingTimeInterval(-200)), "stale")
check(MacPresence.evaluate(MacStatusSnapshot(macConnected: true), now: now) == .online(lastSeen: nil), "connected no hb")
check(MacPresence.evaluate(MacStatusSnapshot(macConnected: false, lastHeartbeatAt: now), now: now) == .offline(lastSeen: now), "offline")
check(MacStatusSnapshot(battery: 0).batteryPercent == nil && MacStatusSnapshot(battery: -1).batteryPercent == nil && MacStatusSnapshot(battery: 54).batteryPercent == 54, "battery")
let st = MacStatusSnapshot.from(json: ["macConnected": true, "lastHeartbeatAt": "2026-10-24T01:02:03.456Z", "battery": 80, "onAC": false, "activeSessions": 3])
check(st.macConnected == true && st.lastHeartbeatAt != nil && st.activeSessions == 3 && st.onAC == false, "status json")

// Stats
var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!; cal.firstWeekday = 2
let wed = cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12))!  // Wednesday
let mon = cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 1))!
let lastSun = cal.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 23))!
let t = wed.timeIntervalSince1970
let hist = [iv("h1", .approval, t - 60, replied: t - 30, project: "a"), iv("h2", .idle, mon.timeIntervalSince1970, project: "a"), iv("h3", .idle, lastSun.timeIntervalSince1970, project: "b")]
let stats = PageStats.compute(history: hist, inbox: [iv("h1", .approval, t - 60, project: "a"), iv("n1", .userInput, t - 5, project: "c")], now: wed, calendar: cal)
check(stats.today == 2, "today \(stats.today)")
check(stats.thisWeek == 3, "week \(stats.thisWeek)")
check(stats.avgResponseSeconds == 30, "avg \(String(describing: stats.avgResponseSeconds))")
check(stats.topProjects.first == PageStats.ProjectCount(name: "a", count: 2), "top")

// Headlines
var cmd = iv("x", .approval, 0)
check(ReplyCopy.headline(for: Intervention(id: "x", sessionId: "s", cwd: "", projectName: "p", kind: .approval, openedAt: now, context: "Bash command needs approval")) == "Run this command?", "cmd headline")
check(ReplyCopy.headline(for: Intervention(id: "x", sessionId: "s", cwd: "", projectName: "p", kind: .userInput, openedAt: now, context: "?", backend: .codex)) == "Codex needs your input", "q headline")
cmd.subtype = "plan"
check(ReplyCopy.headline(for: cmd) == "Approve the plan?", "plan")

// 409 bodies (F3/IOS-4): a reply still waiting on the Mac is not "already answered".
check(ReplyOutcome.from(status: 409, body: Data(#"{"error":"already_replied","repliedAt":"2026-10-24T01:02:03Z","deliveryStatus":"pending"}"#.utf8)) == .inFlight, "409 pending -> inFlight")
check(ReplyOutcome.from(status: 409, body: Data(#"{"error":"reply_in_flight","deliveryStatus":"pending"}"#.utf8)) == .inFlight, "409 reply_in_flight")
check(ReplyOutcome.from(status: 409, body: Data(#"{"error":"already_replied","deliveryStatus":"delivered"}"#.utf8)) == .alreadyReplied, "409 delivered")
check(ReplyOutcome.from(status: 409, body: Data(#"{"error":"already_replied"}"#.utf8)) == .alreadyReplied, "409 v1 body")

// Confirmation window matches the Worker's 20-minute ack timeout.
let sentAt = Date(timeIntervalSince1970: 50_000)
check(!ReplyConfirmation.isUnconfirmed(sentAt: sentAt, queued: false, now: sentAt.addingTimeInterval(61), legacyRelay: false), "v2: 61s still waiting")
check(!ReplyConfirmation.isUnconfirmed(sentAt: sentAt, queued: false, now: sentAt.addingTimeInterval(19 * 60), legacyRelay: false), "v2: 19m still waiting")
check(ReplyConfirmation.isUnconfirmed(sentAt: sentAt, queued: false, now: sentAt.addingTimeInterval(20 * 60 + 1), legacyRelay: false), "v2: retry after ack window")
check(ReplyConfirmation.isUnconfirmed(sentAt: sentAt, queued: false, now: sentAt.addingTimeInterval(61), legacyRelay: true), "legacy relay: 60s")
check(!ReplyConfirmation.isUnconfirmed(sentAt: sentAt, queued: true, now: sentAt.addingTimeInterval(3 * 3600), legacyRelay: false), "queued never unconfirmed")
check(ReplyConfirmation.workerAckTimeout == 1200, "matches DELIVERY_ACK_TIMEOUT_MS")

// Delivery state merges (IOS-6).
check(ReplyDelivery.afterAccepted(.sending, queued: true, at: sentAt) == .sent(queued: true, at: sentAt), "accepted from sending")
check(ReplyDelivery.afterAccepted(.failed("The prompt is no longer showing"), queued: false, at: sentAt) == .failed("The prompt is no longer showing"), "fast failure survives POST response")
check(ReplyDelivery.afterAccepted(.delivered(detail: "x"), queued: false, at: sentAt) == .delivered(detail: "x"), "fast success survives POST response")
let repAt = Date(timeIntervalSince1970: 60_000)
check(ReplyDelivery.synced(local: .failed("Couldn't reach your relay"), deliveryStatus: "pending", deliveryDetail: nil, repliedAt: repAt, now: now) == .sent(queued: false, at: repAt), "pending replaces stale local failure")
check(ReplyDelivery.synced(local: .alreadyReplied, deliveryStatus: "pending", deliveryDetail: nil, repliedAt: repAt, now: now) == .sent(queued: false, at: repAt), "pending un-sticks alreadyReplied")
check(ReplyDelivery.synced(local: .sent(queued: true, at: sentAt), deliveryStatus: "pending", deliveryDetail: nil, repliedAt: repAt, now: now) == .sent(queued: true, at: sentAt), "pending keeps local sent")
check(ReplyDelivery.synced(local: nil, deliveryStatus: "pending", deliveryDetail: nil, repliedAt: nil, now: now) == .sent(queued: false, at: now), "pending seeds")
check(ReplyDelivery.synced(local: .sending, deliveryStatus: "failed", deliveryDetail: "no", repliedAt: nil, now: now) == .sending, "failed never clobbers an in-progress send")
check(ReplyDelivery.synced(local: .sent(queued: false, at: sentAt), deliveryStatus: "failed", deliveryDetail: nil, repliedAt: nil, now: now) == .failed("Your Mac couldn't deliver the reply."), "failed default detail")
check(ReplyDelivery.synced(local: .sent(queued: false, at: sentAt), deliveryStatus: "delivered", deliveryDetail: "Typed", repliedAt: repAt, now: now) == .delivered(detail: "Typed"), "delivered")
check(ReplyDelivery.synced(local: nil, deliveryStatus: nil, deliveryDetail: nil, repliedAt: nil, now: now) == nil, "v1 no reply")
check(ReplyDelivery.synced(local: nil, deliveryStatus: nil, deliveryDetail: nil, repliedAt: repAt, now: now) == .sent(queued: false, at: repAt), "v1 repliedAt seeds")

// Closed reply screen (IOS-5): an unknown reason after our own reply is looked up, not invented.
check(ClosedReplyPhase.decide(reason: nil, hadOwnReply: true, lookupFinished: false) == .checking, "unknown close after reply -> check")
check(ClosedReplyPhase.decide(reason: nil, hadOwnReply: true, lookupFinished: true) == .resolved("Resolved on your Mac."), "lookup found nothing")
check(ClosedReplyPhase.decide(reason: "replied", hadOwnReply: true, lookupFinished: false) == .delivered, "replied -> delivered")
check(ClosedReplyPhase.decide(reason: nil, hadOwnReply: false, lookupFinished: false) == .resolved("Resolved on your Mac."), "no reply of ours -> resolved")
check(ClosedReplyPhase.decide(reason: "user_resolved_in_terminal", hadOwnReply: true, lookupFinished: false) == .resolved("Answered in the terminal."), "known reason")

// Close ids from pushes (F5/IOS-1).
check(PushPayload.closedIds(from: ["interventionClosedId": "a", "interventionClosedIds": ["a", "b", "c"]]) == ["a", "b", "c"], "every closed id")
check(PushPayload.closedIds(from: ["interventionClosedId": "a"]) == ["a"], "v1 single id")
check(PushPayload.closedIds(from: ["interventionClosedIds": ["", "b", 5]]) == ["b"], "empty and non-string dropped")
check(PushPayload.closedIds(from: ["interventionId": "new", "interventionClosedIds": ["old", "new"]]) == ["old"], "alert never closes itself")
check(PushPayload.closedIds(from: ["aps": ["content-available": 1]]).isEmpty, "no ids")

// Project name for local notices (IOS-7).
check(PushPayload.projectName(userInfo: ["projectName": "acme-web"], title: "Reply to acme-web not delivered") == "acme-web", "payload key wins")
check(PushPayload.projectName(userInfo: [:], title: "acme-web paged you") == "acme-web", "legacy alert title")
check(PushPayload.projectName(userInfo: [:], title: "Reply to acme-web not delivered") == "acme-web", "legacy reply-failed title")
check(PushPayload.projectName(userInfo: [:], title: "Something else") == "", "unknown title -> empty")
check(PushPayload.projectName(userInfo: ["projectName": "  "], title: "x paged you") == "x", "blank key falls back")

// Socket liveness (IOS-8).
check(!SocketLiveness.isDead(lastInboundAt: now.addingTimeInterval(-25), now: now, pingInterval: 25), "pong one tick ago is alive")
check(SocketLiveness.isDead(lastInboundAt: now.addingTimeInterval(-50), now: now, pingInterval: 25), "missed pong -> dead")

// Never-connected pairing (IOS-2).
let unseen = MacStatusSnapshot.from(json: ["macConnected": false, "macEverSeen": false, "pendingCount": 0])
check(unseen.macEverSeen == false && unseen.pendingCount == 0, "status json v2 fields")
check(MacPresence.evaluate(unseen, now: now) == .neverConnected, "never connected")
check(MacPresence.evaluate(unseen, now: now).suggestsRepair(now: now), "never connected suggests re-pair")
check(unseen.looksUnused, "probe: unused")
let seenOffline = MacStatusSnapshot(macConnected: false, lastHeartbeatAt: now.addingTimeInterval(-600), macEverSeen: true)
check(MacPresence.evaluate(seenOffline, now: now) == .offline(lastSeen: now.addingTimeInterval(-600)), "seen before -> offline")
check(!MacPresence.evaluate(seenOffline, now: now).suggestsRepair(now: now), "short offline: no re-pair hint")
check(MacPresence.evaluate(MacStatusSnapshot(macConnected: false, lastHeartbeatAt: now.addingTimeInterval(-7200)), now: now).suggestsRepair(now: now), "long offline: re-pair hint")
check(MacPresence.evaluate(MacStatusSnapshot(macConnected: false, lastHeartbeatAt: now.addingTimeInterval(-60), macEverSeen: false), now: now) == .offline(lastSeen: now.addingTimeInterval(-60)), "heartbeat on record overrides macEverSeen=false")
check(MacPresence.evaluate(MacStatusSnapshot(macConnected: false), now: now) == .offline(lastSeen: nil), "old relay without macEverSeen -> plain offline")
check(MacStatusSnapshot(macConnected: false, pendingCount: 0).looksUnused, "probe heuristic for relays without macEverSeen")
check(!MacStatusSnapshot(macConnected: false, pendingCount: 2).looksUnused, "pending pages -> used")
check(!MacStatusSnapshot(macConnected: false).looksUnused, "unknown -> not flagged")
check(!MacStatusSnapshot(macConnected: true, macEverSeen: false).looksUnused, "connected -> fine")

// Token retirement (shared definition: 410 token_retired anywhere, relay.retired frame).
let retiredBody = Data(#"{"error":"token_retired","why":"This pairing was replaced on your Mac — scan the new QR code"}"#.utf8)
check(TokenRetirement.why(status: 410, body: retiredBody) == "This pairing was replaced on your Mac — scan the new QR code", "410 token_retired -> why")
check(TokenRetirement.why(status: 410, body: Data(#"{"error":"token_retired"}"#.utf8)) == TokenRetirement.defaultWhy, "410 token_retired without why -> default")
check(TokenRetirement.why(status: 410, body: Data(#"{"error":"token_retired","why":"   "}"#.utf8)) == TokenRetirement.defaultWhy, "blank why -> default")
check(TokenRetirement.why(status: 410, body: Data(#"{"error":"token_retired","why":5}"#.utf8)) == TokenRetirement.defaultWhy, "non-string why -> default")
check(TokenRetirement.why(status: 410, body: Data(#"{"error":"gone","why":"superseded"}"#.utf8)) == nil, "410 gone is a closed page, not a retired token")
check(TokenRetirement.why(status: 410, body: Data()) == nil, "410 empty body not retired")
check(TokenRetirement.why(status: 410, body: Data("token_retired".utf8)) == nil, "non-JSON body not retired")
check(TokenRetirement.why(status: 401, body: retiredBody) == nil, "only 410 counts")
check(TokenRetirement.why(status: 200, body: retiredBody) == nil, "2xx never retired")
let longWhy = String(repeating: "x", count: 1000)
check((TokenRetirement.why(status: 410, body: try! JSONSerialization.data(withJSONObject: ["error": "token_retired", "why": longWhy])) ?? "").count <= TokenRetirement.maxWhyLength + 1, "why capped")
check(TokenRetirement.why(frameType: "relay.retired", payload: [:]) == TokenRetirement.defaultWhy, "relay.retired frame")
check(TokenRetirement.why(frameType: "relay.retired", payload: ["why": "Replaced on Roy's Mac"]) == "Replaced on Roy's Mac", "relay.retired frame why")
check(TokenRetirement.why(frameType: "intervention.closed", payload: ["why": "x"]) == nil, "other frames ignored")
check(TokenRetirement.why(frameType: "mac.status", payload: ["reason": "token_retired"]) == nil, "mac.status not retirement")
check(TokenRetirement.handshakeNeedsCheck(status: 410) && TokenRetirement.handshakeNeedsCheck(status: 401) && TokenRetirement.handshakeNeedsCheck(status: 403), "refused upgrades are confirmed over REST")
check(!TokenRetirement.handshakeNeedsCheck(status: 101) && !TokenRetirement.handshakeNeedsCheck(status: 404) && !TokenRetirement.handshakeNeedsCheck(status: 502), "other upgrade statuses just reconnect")
check(TokenRetirement.socketCloseNeedsCheck(code: 4410, reason: nil), "close 4410 -> confirm retirement")
check(TokenRetirement.socketCloseNeedsCheck(code: 1000, reason: Data("token_retired".utf8)), "close reason token_retired -> confirm")
check(!TokenRetirement.socketCloseNeedsCheck(code: 1001, reason: nil) && !TokenRetirement.socketCloseNeedsCheck(code: 1006, reason: Data("bye".utf8)), "ordinary closes just reconnect")
check(TokenRetirement.sentence("Scan the new code") == "Scan the new code.", "sentence adds period")
check(TokenRetirement.sentence("Done.") == "Done.", "sentence keeps period")

// Reply outcomes for a retired token vs a closed page.
check(ReplyOutcome.from(status: 410, body: retiredBody) == .retired("This pairing was replaced on your Mac — scan the new QR code"), "reply 410 token_retired -> retired")
check(ReplyOutcome.from(status: 410, body: Data(#"{"error":"gone","why":"prompt_closed","closeReason":"replied"}"#.utf8)) == .gone, "reply 410 gone -> gone")
check(ReplyOutcome.from(status: 410, body: Data(#"{"error":"gone","why":"expired"}"#.utf8)) == .gone, "reply 410 expired page -> gone")

// 422 approve_or_deny_only: show the relay's why, not the code.
let v1Why = "This page comes from an older Page hook that can only apply Approve or Deny. Update it in Page → Phone approvals."
check(ReplyOutcome.from(status: 422, body: try! JSONSerialization.data(withJSONObject: ["error": "approve_or_deny_only", "why": v1Why])) == .failed(v1Why), "422 -> why text")
check(ReplyOutcome.from(status: 422, body: Data(#"{"error":"approve_or_deny_only"}"#.utf8)) == .failed(ReplyOutcome.decisionsOnlyMessage), "422 without why -> built-in copy")
check(ReplyOutcome.from(status: 422, body: Data(#"{"error":"approve_or_deny_only","why":"  "}"#.utf8)) == .failed(ReplyOutcome.decisionsOnlyMessage), "422 blank why -> built-in copy")
check(ReplyOutcome.from(status: 422, body: Data(#"{"error":"something_new"}"#.utf8)) == .failed("The relay refused the reply (something_new)."), "422 other error")
check(ReplyOutcome.from(status: 422, body: Data()) == .failed("The relay returned an error (HTTP 422)."), "422 empty")
if case .failed(let m) = ReplyOutcome.from(status: 422, body: Data(#"{"error":"approve_or_deny_only"}"#.utf8)) {
    check(!m.contains("approve_or_deny_only"), "no raw error code in UI copy")
} else { check(false, "422 is failed") }

// v1 blocking-hook pages (hookBlocking) only take Approve/Deny.
let hb = try! JSONDecoder.page().decode(Intervention.self, from: Data(#"{"id":"hook-1","sessionId":"s","kind":"permission","openedAt":"2026-10-24T01:02:03Z","hookBlocking":true}"#.utf8))
check(hb.hookBlocking == true && hb.isBlockingHook && hb.acceptsDecisionsOnly, "hookBlocking decoded")
let hbBad = try! JSONDecoder.page().decode(Intervention.self, from: Data(#"{"id":"hook-2","sessionId":"s","kind":"permission","openedAt":"2026-10-24T01:02:03Z","hookBlocking":"yes"}"#.utf8))
check(hbBad.hookBlocking == nil && !hbBad.acceptsDecisionsOnly, "malformed hookBlocking ignored")
let hp = try! JSONDecoder.page().decode(Intervention.self, from: Data(#"{"id":"hookpre-1","sessionId":"s","kind":"question","openedAt":"2026-10-24T01:02:03Z"}"#.utf8))
check(hp.isBlockingHook && !hp.acceptsDecisionsOnly, "v2 hookpre pages keep text replies")
check(!lossy.elements[0].acceptsDecisionsOnly && !lossy.elements[0].isBlockingHook, "ordinary page unaffected")

// Close reasons (labels + history) for hook_lost, expired, agent_exited, too_late, token_retired.
for r in ["hook_lost", "expired", "agent_exited", "too_late", "token_retired"] {
    check(CloseReason.description(r) != CloseReason.description(nil), "\(r) has its own label")
    check(!CloseReason.description(r).hasSuffix("."), "\(r) label takes the reply screen's period")
}
for r in ["hook_lost", "expired", "agent_exited", "too_late"] {
    check(CloseReason.historyWorthy.contains(r) && CloseReason.isHistoryWorthy(r), "\(r) is archived to history")
}
check(!CloseReason.historyWorthy.contains("token_retired") && !CloseReason.isHistoryWorthy("token_retired"), "token_retired not added to history")
for r in ["stale", "superseded", "evicted"] { check(!CloseReason.isHistoryWorthy(r), "\(r) hidden from history like the Worker") }
check(CloseReason.historyWorthy.allSatisfy(CloseReason.isHistoryWorthy), "named list agrees with the rule")
check(CloseReason.historyWorthy.isDisjoint(with: CloseReason.hiddenFromHistory), "no reason both shown and hidden")
check(CloseReason.isHistoryWorthy("some_future_reason"), "unknown archived reasons still show, as on the Worker")
check(!CloseReason.isHistoryWorthy(""), "empty reason")
check(CloseReason.description("too_late").contains("too late"), "too_late says the reply missed")
check(!CloseReason.description("too_late").lowercased().contains("answered"), "too_late doesn't claim success")
check(ClosedReplyPhase.decide(reason: "hook_lost", hadOwnReply: true, lookupFinished: false) == .resolved(CloseReason.description("hook_lost") + "."), "hook_lost on reply screen")
check(ClosedReplyPhase.decide(reason: "agent_exited", hadOwnReply: false, lookupFinished: true) == .resolved(CloseReason.description("agent_exited") + "."), "agent_exited on reply screen")

// Top-level projectName (alert and reply-failed pushes) beats both title shapes.
check(PushPayload.projectName(userInfo: ["projectName": "api"], title: "web paged you") == "api", "top-level projectName preferred over alert title")

// macEverSeen from /status (Worker: true once any Mac traffic or heartbeat is on record).
check(MacPresence.evaluate(MacStatusSnapshot.from(json: ["macConnected": false, "macEverSeen": true, "pendingCount": 0]), now: now) == .offline(lastSeen: nil), "macEverSeen true -> offline, not never-connected")
check(!MacStatusSnapshot.from(json: ["macConnected": false, "macEverSeen": true, "pendingCount": 0]).looksUnused, "macEverSeen true wins over the pending heuristic")

print("passes=\(passes) failures=\(failures)")
exit(failures == 0 ? 0 : 1)
