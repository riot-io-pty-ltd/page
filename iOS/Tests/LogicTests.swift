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


// MARK: - Live sessions (docs/SESSIONS-PROTOCOL.md)

// Base64URL: no padding written, padding and the standard alphabet accepted.
check(Base64URL.encode(Data([0xfb, 0xff])) == "-_8", "b64url alphabet, no padding")
check(Base64URL.decode("-_8") == Data([0xfb, 0xff]), "b64url decode unpadded")
check(Base64URL.decode("-_8=") == Data([0xfb, 0xff]), "b64url decode padded")
check(Base64URL.decode("+/8=") == Data([0xfb, 0xff]), "standard alphabet accepted")
check(Base64URL.decode("A") == nil, "impossible length")

// Spec test vector (§2): both directions, byte for byte.
let vecRoot = Data((0...31).map { UInt8($0) })
let vecNonce = Data((0xa0...0xab).map { UInt8($0) })
check(Base64URL.encode(vecRoot) == "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8", "vector root")
check(Base64URL.encode(vecNonce) == "oKGio6Slpqeoqaqr", "vector nonce")
check(SessionCrypto.subkey(root: vecRoot, direction: .macToPhone).withUnsafeBytes { Base64URL.encode(Data($0)) } == "ofSfPY2KtPqbs29ecqGVJzfSrP61BvMETQTitpTwtYE", "mac->phone subkey")
check(SessionCrypto.subkey(root: vecRoot, direction: .phoneToMac).withUnsafeBytes { Base64URL.encode(Data($0)) } == "s_XovkSs3InwR9tqHVrGlT_dVvTJeDPPtd0r-wC1qp4", "phone->mac subkey")
let vecListPT = #"{"kind":"list","seq":1,"ts":1761300000000,"sessions":[]}"#
let vecListC = "izpLGj9N9Rpxuzq00howYI0D93aMC4vbU3Un38nzkzaX6rpd2wEiAvuseOahsZ9_zyivF1z2cuLwWX3k6Coa8QEvrfguLaN3"
let vecCmdPT = #"{"op":"input","clientId":"c1","ts":1761300000000,"sessionId":"s1","text":"hi","viewer":"v1"}"#
let vecCmdC = "sfJ3_bSsO7l16uEp6oH6PFnwlSLI8D_5PtVk8-InyYs-UxcC40NUQDmbHrttBjpm5nJaeQFIgITtiHUF1c6EvBs3hEB0DiBSSIlItp7XAqPjYgLckNcOihF1sKMrZVv8vgUfNIaRAtrMrd_k"
if let e = try? SessionCrypto.seal(Data(vecListPT.utf8), root: vecRoot, direction: .macToPhone, aad: SessionFrameType.update, nonce: vecNonce) {
    check(Base64URL.encode(e.sealed) == vecListC, "vector mac->phone ciphertext")
    check(e.json["n"] as? String == "oKGio6Slpqeoqaqr" && (e.json["v"] as? Int) == 1, "envelope shape")
} else { check(false, "vector seal mac->phone") }
if let e = try? SessionCrypto.seal(Data(vecCmdPT.utf8), root: vecRoot, direction: .phoneToMac, aad: SessionFrameType.command, nonce: vecNonce) {
    check(Base64URL.encode(e.sealed) == vecCmdC, "vector phone->mac ciphertext")
} else { check(false, "vector seal phone->mac") }

// Opening: the vector decrypts, and every wrong key, direction or AAD fails.
let vecEnv = SessionCrypto.Envelope(json: ["v": 1, "n": "oKGio6Slpqeoqaqr", "c": vecListC])
check(vecEnv != nil, "vector envelope parses")
if let env = vecEnv {
    check(SessionCrypto.open(env, root: vecRoot, direction: .macToPhone, aad: SessionFrameType.update) == Data(vecListPT.utf8), "vector opens")
    check(SessionCrypto.open(env, root: vecRoot, direction: .phoneToMac, aad: SessionFrameType.update) == nil, "wrong direction fails")
    check(SessionCrypto.open(env, root: vecRoot, direction: .macToPhone, aad: SessionFrameType.command) == nil, "relabelled frame type fails")
    check(SessionCrypto.open(env, root: Data(repeating: 7, count: 32), direction: .macToPhone, aad: SessionFrameType.update) == nil, "wrong key fails")
    var tampered = env.sealed; tampered[0] ^= 1
    check(SessionCrypto.open(SessionCrypto.Envelope(nonce: env.nonce, sealed: tampered), root: vecRoot, direction: .macToPhone, aad: SessionFrameType.update) == nil, "tampered fails")
}
check(SessionCrypto.Envelope(json: ["v": 1, "n": "oKGio6Slpqeoqaqr=", "c": vecListC + "=="]) != nil, "padded envelope accepted")
check(SessionCrypto.Envelope(json: ["v": 2, "n": "oKGio6Slpqeoqaqr", "c": vecListC]) == nil, "v2 envelope rejected")
check(SessionCrypto.Envelope(json: ["v": 1, "n": "oKGio6Sl", "c": vecListC]) == nil, "short nonce rejected")
check(SessionCrypto.Envelope(json: ["v": 1, "n": "oKGio6Slpqeoqaqr", "c": "AAAA"]) == nil, "ciphertext shorter than a tag rejected")
check(SessionCrypto.Envelope(json: ["v": 1, "n": 5, "c": vecListC]) == nil, "non-string nonce rejected")
// Production nonces are random.
let r1 = try! SessionCrypto.seal(Data("x".utf8), root: vecRoot, direction: .phoneToMac, aad: SessionFrameType.command)
let r2 = try! SessionCrypto.seal(Data("x".utf8), root: vecRoot, direction: .phoneToMac, aad: SessionFrameType.command)
check(r1.nonce.count == 12 && r1.nonce != r2.nonce, "random nonce per message")
check(SessionCrypto.open(r1, root: vecRoot, direction: .phoneToMac, aad: SessionFrameType.command) == Data("x".utf8), "round trip")

// Command plaintext + request body: the Mac's side of the vector decrypts it.
let cmdNow = Date(timeIntervalSince1970: 1_761_300_000)
let inputPT = SessionCommand.input(sessionId: "s1", text: "hi").plaintext(clientId: "c1", viewer: "v1", now: cmdNow)
let inputObj = (try? JSONSerialization.jsonObject(with: inputPT)) as? [String: Any]
check(inputObj?["op"] as? String == "input" && inputObj?["text"] as? String == "hi" && inputObj?["sessionId"] as? String == "s1", "input plaintext")
check((inputObj?["ts"] as? NSNumber)?.int64Value == 1_761_300_000_000 && inputObj?["viewer"] as? String == "v1" && inputObj?["clientId"] as? String == "c1", "ts ms + viewer + clientId")
let watchNull = (try? JSONSerialization.jsonObject(with: SessionCommand.watch(sessionId: nil).plaintext(clientId: "c", viewer: "v", now: cmdNow))) as? [String: Any]
check(watchNull?["sessionId"] is NSNull && watchNull?["op"] as? String == "watch", "watch null stops viewing")
let refreshObj = (try? JSONSerialization.jsonObject(with: SessionCommand.refresh.plaintext(clientId: "c", viewer: "v", now: cmdNow))) as? [String: Any]
check(refreshObj?["op"] as? String == "refresh" && refreshObj?["sessionId"] == nil, "refresh has no session")
let interruptObj = (try? JSONSerialization.jsonObject(with: SessionCommand.interrupt(sessionId: "s9").plaintext(clientId: "c", viewer: "v", now: cmdNow))) as? [String: Any]
check(interruptObj?["op"] as? String == "interrupt" && interruptObj?["sessionId"] as? String == "s9", "interrupt plaintext")
if let body = try? SessionCommand.requestBody(plaintext: inputPT, root: vecRoot),
   let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
   let e = obj["e"] as? [String: Any], let env = SessionCrypto.Envelope(json: e) {
    check(SessionCrypto.open(env, root: vecRoot, direction: .phoneToMac, aad: SessionFrameType.command) == inputPT, "request body round-trips")
    check(obj.count == 1, "body is only {e}")
} else { check(false, "request body") }

// Pairing `sk`: optional, exactly 32 bytes, ignored otherwise.
let skGood = Base64URL.encode(Data(repeating: 9, count: 32))
func pairingJSON(_ sk: String?) -> String {
    var s = #"{"v":1,"token":"abcdefghijklmnopqrstuvwxyz","relay":"https://r.example.com""#
    if let sk { s += #","sk":"# + sk }
    return s + "}"
}
if case .success(let p) = PairingValidator.validate(pairingJSON("\"\(skGood)\"")) { check(p.sessionKey == Data(repeating: 9, count: 32), "sk read") } else { check(false, "sk pairing") }
if case .success(let p) = PairingValidator.validate(pairingJSON("\"\(skGood)=\"")) { check(p.sessionKey?.count == 32, "padded sk read") } else { check(false, "padded sk pairing") }
if case .success(let p) = PairingValidator.validate(pairingJSON(nil)) { check(p.sessionKey == nil, "no sk: still pairs") } else { check(false, "no sk pairing") }
if case .success(let p) = PairingValidator.validate(pairingJSON("\"\(Base64URL.encode(Data(repeating: 1, count: 31)))\"")) { check(p.sessionKey == nil, "31-byte sk ignored") } else { check(false, "31 sk pairing") }
if case .success(let p) = PairingValidator.validate(pairingJSON("\"\(Base64URL.encode(Data(repeating: 1, count: 33)))\"")) { check(p.sessionKey == nil, "33-byte sk ignored") } else { check(false, "33 sk pairing") }
if case .success(let p) = PairingValidator.validate(pairingJSON("\"not base64 !!\"")) { check(p.sessionKey == nil, "garbage sk ignored") } else { check(false, "garbage sk pairing") }
if case .success(let p) = PairingValidator.validate(pairingJSON("12345")) { check(p.sessionKey == nil, "numeric sk ignored") } else { check(false, "numeric sk pairing") }
check(SessionCrypto.validRootKey(Data(count: 32)) != nil && SessionCrypto.validRootKey(nil) == nil, "validRootKey")
// PairedMac stays decodable from older Keychain records.
check((try? JSONDecoder().decode(PairedMac.self, from: Data(#"{"name":"Mac","hostname":"x","connected":true}"#.utf8)))?.name == "Mac", "old PairedMac decodes")

// Plaintext decoding: the spec's list (no `boot`) decodes.
if let p = SessionsPlaintext.decode(Data(vecListPT.utf8)) {
    check(p.seq == 1 && p.boot == "" && p.ts == Date(timeIntervalSince1970: 1_761_300_000), "vector list header")
    check(p.update == .list(macName: nil, sessions: []), "vector list empty")
} else { check(false, "vector list decodes") }

let listJSON = """
{"kind":"list","boot":"b1","seq":12,"ts":1761300000000,"macName":"Roy's MacBook","futureField":{"x":1},
 "sessions":[
  {"id":"s-claude","backend":"claude","title":"mac-on-claude-code","cwd":"~/projects/mac-on-claude-code","state":"waitingOnApproval","host":"cmux","canType":true,"typeBlocker":"ignored when typable","canInterrupt":true,"provider":"anthropic","lastActivityAt":"2026-10-24T12:00:00Z","interventionId":"iv-1","preview":"Bash: npm test"},
  {"id":"s-ollama","backend":"ollama","cwd":"~/code/llm-play","state":"thinkingHard","host":"Ghostty","canType":false,"typeBlocker":"Page can't type into Ghostty yet","canInterrupt":"yes","lastActivityAt":"bad"},
  {"id":"s-min"},
  {"id":""},
  {"title":"no id"},
  {"id":"s-codex","backend":"CODEX","title":5,"cwd":"~","state":"active","canType":true,"canInterrupt":false,"lastActivityAt":"2026-10-24T11:00:00.123Z","interventionId":""}
 ]}
"""
if let p = SessionsPlaintext.decode(Data(listJSON.utf8)), case .list(let name, let ss) = p.update {
    check(p.boot == "b1" && p.seq == 12, "list header")
    check(name == "Roy's MacBook", "macName")
    check(ss.map(\.id) == ["s-claude", "s-ollama", "s-min", "s-codex"], "bad sessions dropped, rest kept \(ss.map(\.id))")
    let a = ss[0], b = ss[1], m = ss[2], x = ss[3]
    check(a.backend == .known(.claude) && a.state == .waitingOnApproval && a.canType && a.typeBlocker == nil, "claude session")
    check(a.openPageId == "iv-1" && a.lastActivityAt == PageDate.parse("2026-10-24T12:00:00Z") && a.preview == "Bash: npm test", "claude fields")
    check(b.backend == .other("ollama") && b.backend.badge == "OLLAMA" && b.backend.displayName == "Ollama", "other backend kept raw")
    check(b.state == .unknown && b.state.group == .idle, "unknown state -> unknown, grouped idle")
    check(b.title == "llm-play", "title from cwd")
    check(!b.canType && b.blockerText == "Page can't type into Ghostty yet", "type blocker")
    check(!b.canInterrupt && !b.isStoppable, "non-bool canInterrupt -> false")
    check(b.lastActivityAt == nil, "bad date tolerated")
    check(m.title == "Session s-min" && !m.canType && m.blockerText == LiveSession.defaultBlocker && m.host == "unknown" && m.hostLabel == "Unknown host", "minimal session safe defaults")
    check(m.backend == .other("unknown") && m.backend.displayName == "Your agent", "missing backend")
    check(x.backend == .known(.codex) && x.title == "Session s-codex" && x.interventionId == nil, "codex: case-insensitive backend, ~ cwd, empty intervention id")
    check(x.isStoppable == false && x.state == .active, "active but not interruptible")
} else { check(false, "list decodes") }

check(SessionsPlaintext.decode(Data(#"{"kind":"list","seq":1,"ts":1761300000000}"#.utf8)) == nil, "list without sessions is malformed, not empty")
check(SessionsPlaintext.decode(Data(#"{"kind":"sparkles","seq":1,"ts":1761300000000}"#.utf8)) == nil, "unknown kind ignored")
check(SessionsPlaintext.decode(Data(#"{"kind":"list","ts":1761300000000,"sessions":[]}"#.utf8)) == nil, "missing seq rejected")
check(SessionsPlaintext.decode(Data(#"{"kind":"list","seq":1,"sessions":[]}"#.utf8)) == nil, "missing ts rejected")
check(SessionsPlaintext.decode(Data("not json".utf8)) == nil, "garbage")
let many = "{\"kind\":\"list\",\"seq\":1,\"ts\":1761300000000,\"sessions\":[" + (0..<150).map { "{\"id\":\"s\($0)\"}" }.joined(separator: ",") + "]}"
if let p = SessionsPlaintext.decode(Data(many.utf8)), case .list(_, let ss) = p.update { check(ss.count == 100, "capped at 100 sessions") } else { check(false, "many sessions") }

let transcriptJSON = """
{"kind":"transcript","boot":"b1","seq":13,"ts":1761300000000,"sessionId":"s-claude","truncated":true,
 "entries":[{"id":"u1","role":"user","text":"run the tests","at":"2026-10-24T12:00:00Z"},
            {"id":42,"role":"tool","text":"Bash: npm test","tool":"Bash"},
            {"id":"a1","role":"assistant","text":"All green."},
            {"id":"x1","role":"narrator","text":"odd role"},
            {"role":"user","text":"no id"}]}
"""
if let p = SessionsPlaintext.decode(Data(transcriptJSON.utf8)), case .transcript(let t) = p.update {
    check(t.sessionId == "s-claude" && t.truncated, "transcript header")
    check(t.entries.map(\.id) == ["u1", "42", "a1", "x1"], "entries \(t.entries.map(\.id))")
    check(t.entries[0].role == .user && t.entries[0].at != nil, "user entry")
    check(t.entries[1].role == .tool && t.entries[1].tool == "Bash", "tool entry, numeric id")
    check(t.entries[3].role == .system, "unknown role -> system, never user")
} else { check(false, "transcript decodes") }
check(SessionsPlaintext.decode(Data(#"{"kind":"transcript","seq":1,"ts":1761300000000,"entries":[]}"#.utf8)) == nil, "transcript needs sessionId")

let resultJSON = #"{"kind":"result","boot":"b1","seq":14,"ts":1761300000000,"clientId":"c1","ok":false,"code":"refused","reason":"waiting","detail":"Answer the prompt","interventionId":"iv-1"}"#
if let p = SessionsPlaintext.decode(Data(resultJSON.utf8)), case .result(let r) = p.update {
    check(r == CommandResult(clientId: "c1", ok: false, code: .refused, reason: "waiting", detail: "Answer the prompt", interventionId: "iv-1"), "result decodes")
} else { check(false, "result decodes") }
if let p = SessionsPlaintext.decode(Data(#"{"kind":"result","seq":1,"ts":1761300000000,"clientId":"c2","ok":true,"code":"teleported"}"#.utf8)), case .result(let r) = p.update {
    check(r.code == .delivered, "unknown code with ok -> delivered")
} else { check(false, "unknown code") }
check(SessionsPlaintext.decode(Data(#"{"kind":"result","seq":1,"ts":1761300000000,"ok":true}"#.utf8)) == nil, "result needs clientId")

// Acceptance: ts guard, per-boot list seq, boot reset, per-session transcripts.
func pt(_ update: SessionsUpdate, boot: String = "b1", seq: Int, age: TimeInterval = 0, now: Date = cmdNow) -> SessionsPlaintext {
    SessionsPlaintext(boot: boot, seq: seq, ts: now.addingTimeInterval(-age), update: update)
}
let emptyList = SessionsUpdate.list(macName: nil, sessions: [])
var gate = SessionUpdateGate()
check(gate.admit(pt(emptyList, seq: 5), now: cmdNow) == .accept, "first list")
check(gate.admit(pt(emptyList, seq: 5), now: cmdNow) == .outOfOrder, "same seq dropped")
check(gate.admit(pt(emptyList, seq: 4), now: cmdNow) == .outOfOrder, "older seq dropped")
check(gate.admit(pt(emptyList, seq: 6), now: cmdNow) == .accept, "newer seq")
check(gate.admit(pt(emptyList, seq: 7, age: 601), now: cmdNow) == .tooOld, "older than 10 min dropped")
check(gate.admit(pt(emptyList, seq: 7, age: 599), now: cmdNow) == .accept, "just under 10 min ok")
check(gate.admit(pt(emptyList, seq: 99, age: -3600), now: cmdNow) == .accept, "Mac clock ahead is not a replay")
check(gate.admit(pt(emptyList, boot: "b2", seq: 900, age: 700), now: cmdNow) == .tooOld && gate.boot == "b1", "stale frame from a new boot doesn't reset tracking")
check(gate.admit(pt(emptyList, boot: "b2", seq: 1), now: cmdNow) == .accept && gate.boot == "b2", "new boot resets seq")
check(gate.admit(pt(emptyList, boot: "b2", seq: 2), now: cmdNow) == .accept, "new boot continues")
let tA = SessionsUpdate.transcript(SessionTranscript(sessionId: "A", entries: [], truncated: false))
let tB = SessionsUpdate.transcript(SessionTranscript(sessionId: "B", entries: [], truncated: false))
check(gate.admit(pt(tA, boot: "b2", seq: 10), now: cmdNow) == .accept, "transcript A")
check(gate.admit(pt(tB, boot: "b2", seq: 8), now: cmdNow) == .accept, "transcript B tracked separately")
check(gate.admit(pt(tA, boot: "b2", seq: 9), now: cmdNow) == .outOfOrder, "older transcript A dropped")
check(gate.admit(pt(emptyList, boot: "b2", seq: 3), now: cmdNow) == .accept, "list seq independent of transcripts")
let res = SessionsUpdate.result(CommandResult(clientId: "c", ok: true, code: .delivered, reason: nil, detail: nil, interventionId: nil))
check(gate.admit(pt(res, boot: "b2", seq: 1), now: cmdNow) == .accept, "results aren't seq-gated")
check(gate.admit(pt(res, boot: "b2", seq: 1, age: 1200), now: cmdNow) == .tooOld, "results are age-gated")
check(gate.admit(pt(tA, boot: "b3", seq: 1), now: cmdNow) == .accept, "new boot resets transcript tracking")
// Screens (the Mac's terminal mirror): per-session seq, independent of transcripts.
let scrA = SessionsUpdate.screen(SessionScreen(sessionId: "A", lines: ["x"], at: cmdNow))
check(gate.admit(pt(scrA, boot: "b3", seq: 1), now: cmdNow) == .accept, "screen A, same seq as transcript A is fine")
check(gate.admit(pt(scrA, boot: "b3", seq: 1), now: cmdNow) == .outOfOrder, "repeated screen dropped")
check(gate.admit(pt(scrA, boot: "b3", seq: 2), now: cmdNow) == .accept, "newer screen")
if let p = SessionsPlaintext.decode(Data(#"{"kind":"screen","seq":3,"ts":1761300000000,"sessionId":"S","lines":["❯ hi","  ○ wf 11/23"]}"#.utf8)),
   case .screen(let sc) = p.update {
    check(sc.sessionId == "S" && sc.lines == ["❯ hi", "  ○ wf 11/23"], "screen decodes")
} else { check(false, "screen decodes") }
check(SessionsPlaintext.decode(Data(#"{"kind":"screen","seq":3,"ts":1761300000000,"lines":["x"]}"#.utf8)) == nil, "screen without sessionId rejected")
check(SessionsPlaintext.decode(Data(#"{"kind":"screen","seq":3,"ts":1761300000000,"sessionId":"S"}"#.utf8)) == nil, "screen without lines rejected")
let longScreen = "{\"kind\":\"screen\",\"seq\":3,\"ts\":1761300000000,\"sessionId\":\"S\",\"lines\":[" + (0..<200).map { "\"\(String(repeating: "a", count: 500))\($0)\"" }.joined(separator: ",") + "]}"
if let p = SessionsPlaintext.decode(Data(longScreen.utf8)), case .screen(let sc) = p.update {
    check(sc.lines.count == SessionScreen.maxLines && sc.lines.allSatisfy { $0.count <= SessionScreen.maxLineChars }, "screen capped on the phone too")
} else { check(false, "long screen decodes") }
// Workflows: decode, agent transcripts keyed apart, footer rows → runs.
let wfJSON = #"{"kind":"workflows","seq":20,"ts":1761300000000,"sessionId":"S","runs":[{"id":"wf_1","name":"design-pass-ch1-8-opus","status":"running","phase":"Fix B","done":28,"total":30,"startedAt":1761290000000,"endedAt":null,"tokens":null,"agents":[{"id":"a1","label":"ch5: fix","phase":"Fix B","state":"running","lastActivityAt":1761299990000},{"label":"no id"}]},{"id":"wf_2","name":"finish-act-opus","status":"running","done":0,"total":1},{"id":"wf_3","name":"finish-act-opus","status":"running","done":0,"total":1},{"name":"no id"}]}"#
if let p = SessionsPlaintext.decode(Data(wfJSON.utf8)), case .workflows(let sid, let runs) = p.update {
    check(sid == "S" && runs.map(\.id) == ["wf_1", "wf_2", "wf_3"], "workflows decode, bad runs dropped")
    check(runs[0].agents.map(\.id) == ["a1"] && runs[0].agents[0].running, "agents decode, bad agents dropped")
    check(runs[0].progress(now: Date(timeIntervalSince1970: 1761300000)).hasPrefix("28/30 · 2h46m"), "progress like the footer")
    let footer = ["  ○ design-pass-ch1-8-opus      28/30 · 2h34m", "  ○ finish-act-opus   0/1", "  ○ finish-act-opus   0/1", "plain text design-pass-ch1-8-opus", "  ○ design-pass-ch1-8-opus-extra"]
    let links = TerminalRunLinks.match(lines: footer, runs: runs)
    check(links[0]?.id == "wf_1" && links[1]?.id == "wf_2" && links[2]?.id == "wf_3", "footer rows open their runs, same names in order")
    check(links[3] == nil && links[4] == nil, "only footer-style rows, whole names")
    let chatty = ["● design-pass-ch1-8-opus is going well", "  ○ design-pass-ch1-8-opus      28/30"]
    let l2 = TerminalRunLinks.match(lines: chatty, runs: runs)
    check(l2[1]?.id == "wf_1" && l2[0] == nil, "the footer row (bottom) takes the run, not a chat line above")
} else { check(false, "workflows decode") }
if let p = SessionsPlaintext.decode(Data(#"{"kind":"workflows","seq":22,"ts":1761300000000,"sessionId":"S","runs":[{"id":"wf_k","name":"k","status":"killed","done":1,"total":3,"agents":[{"id":"a1","label":"x","state":"failed"},{"id":"a2","label":"y","state":"stopped"},{"id":"a3","label":"z","state":"done"},{"id":"a4","label":"w"}]}]}"#.utf8)),
   case .workflows(_, let runs) = p.update {
    check(!runs[0].agents.contains(where: \.running), "failed, stopped, done and unstated agents are not running")
    check(runs[0].agents.map(\.state) == ["failed", "stopped", "done", "done"], "agent states kept")
} else { check(false, "killed run decodes") }
check(WorkflowRun.duration(45) == "45s" && WorkflowRun.duration(23 * 60 + 8) == "23m" && WorkflowRun.duration(9240) == "2h34m", "durations")
check(WorkflowRun.tokens(6_300_000) == "6.3m tokens" && WorkflowRun.tokens(985_100) == "985.1k tokens", "tokens")
if let p = SessionsPlaintext.decode(Data(#"{"kind":"transcript","seq":21,"ts":1761300000000,"sessionId":"S","runId":"wf_1","agentId":"a1","entries":[]}"#.utf8)),
   case .transcript(let t) = p.update {
    check(t.key == "S|wf_1|a1" && t.runId == "wf_1", "agent transcript keyed apart from the session's")
    let sessionT = SessionsUpdate.transcript(SessionTranscript(sessionId: "S", entries: [], truncated: false))
    check(gate.admit(pt(.transcript(t), boot: "b3", seq: 30), now: cmdNow) == .accept
          && gate.admit(pt(sessionT, boot: "b3", seq: 29), now: cmdNow) == .accept, "agent and session transcripts have separate seq")
} else { check(false, "agent transcript decodes") }
let wa = SessionCommand.watchAgent(sessionId: "S", runId: "wf_1", agentId: "a1").plaintext(clientId: "c", viewer: "v", now: cmdNow)
if let o = try? JSONSerialization.jsonObject(with: wa) as? [String: Any] {
    check(o["op"] as? String == "watch" && o["runId"] as? String == "wf_1" && o["agentId"] as? String == "a1" && o["sessionId"] as? String == "S", "watchAgent is a watch with run and agent")
} else { check(false, "watchAgent encodes") }
gate.reset()
check(gate.boot == nil && gate.lastListSeq == nil && gate.admit(pt(emptyList, boot: "b3", seq: 1), now: cmdNow) == .accept, "reset clears")

// Grouping and ordering.
func ls(_ id: String, _ state: LiveSessionState, _ t: TimeInterval?, title: String = "p") -> LiveSession {
    LiveSession(id: id, backend: .known(.claude), title: title, cwd: "", state: state, host: "cmux", canType: true,
                typeBlocker: nil, canInterrupt: true, provider: nil,
                lastActivityAt: t.map { Date(timeIntervalSince1970: $0) }, interventionId: nil, preview: "")
}
let sections = SessionGrouping.sections([
    ls("idle-old", .idle, 10), ls("act", .active, 50), ls("wait-u", .waitingOnUser, 20), ls("rl", .rateLimited, 90),
    ls("wait-a", .waitingOnApproval, 30), ls("unk", .unknown, nil), ls("act2", .active, 60), ls("off", .offline, 70)
])
check(sections.map(\.group) == [.needsYou, .working, .idle], "group order")
check(sections[0].sessions.map(\.id) == ["wait-a", "wait-u"], "needs you by recency")
check(sections[1].sessions.map(\.id) == ["act2", "act"], "working by recency")
check(sections[2].sessions.map(\.id) == ["rl", "off", "idle-old", "unk"], "idle by recency, undated last")
check(SessionGrouping.sections([ls("a", .idle, 1)]).map(\.group) == [.idle], "empty groups left out")
check(SessionGrouping.sections([]).isEmpty, "no sessions")
check(SessionGrouping.needsYouCount([ls("a", .waitingOnUser, 1), ls("b", .active, 1), ls("c", .waitingOnApproval, 1)]) == 2, "needs-you count")
check(LiveSessionState.allCases.allSatisfy { !$0.label.isEmpty }, "every state has a label")
check(ls("x", .active, 1).isStoppable && !ls("x", .idle, 1).isStoppable, "Stop only while active")
check(ls("x", .idle, 1).openPageId == nil, "open page only while waiting")

// Delivery state machine.
let cmdSentAt = cmdNow
func result(_ code: CommandResult.Code, reason: String? = nil, detail: String? = nil) -> CommandResult {
    CommandResult(clientId: "c", ok: code == .delivered || code == .queued, code: code, reason: reason, detail: detail, interventionId: nil)
}
var d = SessionDeliveryState.sending
check(d.isPending && d.label(.input) == "Sending…" && d.label(.interrupt) == "Stopping…", "sending labels")
check(d.timedOut(sentAt: cmdSentAt, now: cmdSentAt.addingTimeInterval(19.9)) == .sending, "not yet timed out")
check(d.timedOut(sentAt: cmdSentAt, now: cmdSentAt.addingTimeInterval(20)) == .noAnswer, "no answer after 20 s")
check(d.applying(result(.delivered, detail: "Typed into cmux"), agent: "Claude") == .typed("Typed into cmux"), "delivered -> typed")
check(d.applying(result(.queued), agent: "Claude") == .queued(nil), "queued")
check(SessionDeliveryState.queued(nil).explanation(.input, agent: "Claude") == "Queued — Claude reads it after the current step.", "queued copy")
if case .refused(let reason, let message) = d.applying(result(.refused, reason: "digit_while_busy"), agent: "Claude") {
    check(reason == "digit_while_busy" && message == "Starts with a number: wait for Claude to finish, or add a word first.", "digit refusal copy")
} else { check(false, "refused") }
check(d.applying(result(.failed, detail: "tmux went away"), agent: "Claude") == .failed("tmux went away"), "failed uses detail")
check(SessionDeliveryState.noAnswer.applying(result(.delivered), agent: "Claude") == .typed(nil), "late result beats giving up")
check(SessionDeliveryState.failed("lost").applying(result(.queued), agent: "Claude") == .queued(nil), "result beats a lost HTTP response")
check(SessionDeliveryState.typed(nil).applying(result(.refused, reason: "replay"), agent: "Claude") == .typed(nil), "first result wins")
check(SessionDeliveryState.typed(nil).timedOut(sentAt: cmdSentAt, now: cmdSentAt.addingTimeInterval(99)) == .typed(nil), "settled never times out")
check(d.afterPost(.accepted) == .sending, "202 keeps waiting for the result")
check(d.afterPost(.macOffline) == .failed(SessionCommandOutcome.macOffline.failureMessage!), "503 -> not sent")
check(SessionDeliveryState.typed(nil).afterPost(.macOffline) == .typed(nil), "result that beat the POST is kept")
check(SessionDeliveryState.typed(nil).label(.interrupt) == "Stopped" && SessionDeliveryState.noAnswer.label(.input) == "No answer from your Mac", "labels")
d = .noAnswer
check(d.explanation(.input, agent: "Claude")?.contains("20 seconds") == true, "no-answer copy")
// VoiceOver hears the same status and explanation the bubble shows.
let draftRefusal = SessionDeliveryState.sending.applying(result(.refused, reason: "draft"), agent: "Claude")
check(draftRefusal.spokenBubbleStatus(.input, agent: "Claude") == "Refused. " + SessionResultCopy.refusal(reason: "draft", detail: nil, agent: "Claude"), "spoken refusal says why")
check(SessionDeliveryState.noAnswer.spokenBubbleStatus(.input, agent: "Claude").hasPrefix("No answer from your Mac. ") && SessionDeliveryState.noAnswer.spokenBubbleStatus(.input, agent: "Claude").contains("check the transcript"), "spoken no-answer guidance")
check(SessionDeliveryState.failed("tmux went away").spokenBubbleStatus(.input, agent: "Claude") == "Not sent. tmux went away", "spoken failure")
check(SessionDeliveryState.typed("Typed into cmux").bubbleExplanation(.input, agent: "Claude") == nil && SessionDeliveryState.typed("Typed into cmux").spokenBubbleStatus(.input, agent: "Claude") == "Typed", "typed detail not shown or spoken")
check(SessionDeliveryState.sending.spokenBubbleStatus(.input, agent: "Claude") == "Sending…", "spoken sending")

// HTTP outcomes for POST /sessions/command.
check(SessionCommandOutcome.from(status: 202, body: Data(#"{"ok":true}"#.utf8)) == .accepted, "202")
check(SessionCommandOutcome.from(status: 503, body: Data(#"{"error":"mac_offline"}"#.utf8)) == .macOffline, "503")
check(SessionCommandOutcome.from(status: 400, body: Data(#"{"error":"invalid_envelope"}"#.utf8)) == .invalid, "400")
check(SessionCommandOutcome.from(status: 413, body: Data(#"{"error":"too_large"}"#.utf8)) == .tooLarge, "413")
check(SessionCommandOutcome.from(status: 429, body: Data(#"{"error":"rate_limited"}"#.utf8)) == .rateLimited, "429")
check(SessionCommandOutcome.from(status: 401, body: Data()) == .unauthorized, "401")
check(SessionCommandOutcome.from(status: 410, body: Data(#"{"error":"token_retired","why":"Replaced"}"#.utf8)) == .retired("Replaced"), "410 token_retired")
check(SessionCommandOutcome.from(status: 404, body: Data("Not found".utf8)) == .relayTooOld, "404 old relay")
if case .failed = SessionCommandOutcome.from(status: 500, body: Data()) {} else { check(false, "500") }
check(SessionCommandOutcome.accepted.failureMessage == nil, "accepted has no failure copy")

// Composer: 1–8000 characters after trimming, and a body the relay takes.
check(SessionComposer.validate("  \n ") == .failure(.empty), "blank refused")
check(SessionComposer.validate("  hi \n") == .success("hi"), "trimmed")
check(SessionComposer.validate(String(repeating: "a", count: 8000)) == .success(String(repeating: "a", count: 8000)), "8000 ok")
check(SessionComposer.validate(String(repeating: "a", count: 8001)) == .failure(.tooLong(count: 8001)), "8001 refused")
check(SessionComposer.validate(" " + String(repeating: "a", count: 8000) + "  ") != .failure(.tooLong(count: 8003)), "limit counts trimmed text")
let family = String(repeating: "👨‍👩‍👧‍👦", count: 8000)
check(SessionComposer.validate(family) == .success(family), "8000 family emoji are 8000 characters")
let familyBody = try! SessionCommand.requestBody(plaintext: SessionCommand.input(sessionId: "s", text: family).plaintext(clientId: UUID().uuidString, viewer: "v", now: cmdNow), root: vecRoot)
check(!SessionComposer.fitsRelay(familyBody), "but too large for the relay's 64 KiB body")
let asciiBody = try! SessionCommand.requestBody(plaintext: SessionCommand.input(sessionId: UUID().uuidString, text: String(repeating: "a", count: 8000)).plaintext(clientId: UUID().uuidString, viewer: UUID().uuidString, now: cmdNow), root: vecRoot)
check(SessionComposer.fitsRelay(asciiBody), "8000 ASCII characters fit")
check(SessionComposer.Problem.tooLarge.message.contains("too large"), "too-large copy")

// Reason copy: every protocol reason has its own text with a next step.
let reasons = ["waiting", "unknown_state", "not_typable", "draft", "digit_while_busy", "ended", "codex_mid_turn",
               "disabled", "stale", "replay", "not_found", "interrupt_unsupported", "error"]
let fallback = SessionResultCopy.refusal(reason: "brand_new", detail: nil, agent: "Claude")
for r in reasons {
    check(SessionResultCopy.refusal(reason: r, detail: nil, agent: "Claude") != fallback, "\(r) has its own copy")
}
check(Set(reasons.map { SessionResultCopy.refusal(reason: $0, detail: nil, agent: "Claude") }).count == reasons.count, "reason copy is distinct")
check(SessionResultCopy.refusal(reason: "brand_new", detail: "Mac says no", agent: "Claude") == "Mac says no", "unknown reason uses the Mac's detail")
check(SessionResultCopy.refusal(reason: "waiting", detail: nil, agent: "Codex").hasPrefix("Codex"), "agent name in copy")
check(SessionResultCopy.refusal(reason: "codex_mid_turn", detail: nil, agent: "Codex") == "Codex is mid-turn — Page can type once the turn ends.", "codex mid-turn copy")

// Transcript timeline: echoes attach the delivery to the user entry.
func te(_ id: String, _ role: TranscriptRole, _ text: String, at: TimeInterval? = nil) -> TranscriptEntry {
    TranscriptEntry(id: id, role: role, text: text, at: at.map { cmdNow.addingTimeInterval($0) }, tool: nil)
}
func sent(_ cid: String, _ text: String, _ state: SessionDeliveryState, at: TimeInterval = 0, kind: SessionCommandKind = .input) -> SentSessionCommand {
    SentSessionCommand(clientId: cid, sessionId: "s", kind: kind, text: text, sentAt: cmdNow.addingTimeInterval(at), state: state)
}
check(TranscriptTimeline.normalise("  !run\u{7}  the\n\ntests ") == "run the tests", "normalise")
check(TranscriptTimeline.echoes("run the tests", "!run  the tests"), "guarded bang still echoes")
check(!TranscriptTimeline.echoes("run the tests", "run the test suite"), "different text doesn't echo")
let longText = String(repeating: "word ", count: 600)
check(TranscriptTimeline.echoes(String(longText.prefix(2000)) + "…", longText), "capped entry echoes by prefix")
let tl = TranscriptTimeline.merge(
    entries: [te("u0", .user, "yes", at: -600), te("a0", .assistant, "ok"), te("u1", .user, "yes", at: 2), te("t1", .tool, "Bash: ls")],
    sent: [sent("c1", "yes", .typed(nil)), sent("c2", "nope", .refused(reason: "draft", message: "m")),
           sent("c3", "later", .sending, at: 5), sent("c4", "", .sending, kind: .interrupt)])
check(tl.map(\.id) == ["e:u0", "e:a0", "e:u1", "e:t1", "p:c2", "p:c3"], "timeline order \(tl.map(\.id))")
if case .entry(_, let del) = tl[2] { check(del?.clientId == "c1", "echo attached to the entry after the send") } else { check(false, "u1") }
if case .entry(_, let del) = tl[0] { check(del == nil, "older identical prompt not claimed") } else { check(false, "u0") }
let refusedTwin = TranscriptTimeline.merge(entries: [te("u", .user, "nope")], sent: [sent("c", "nope", .refused(reason: nil, message: "m"))])
check(refusedTwin.map(\.id) == ["e:u", "p:c"], "refused message never claims an entry")
let twice = TranscriptTimeline.merge(entries: [te("u1", .user, "go"), te("u2", .user, "go")],
                                     sent: [sent("c1", "go", .typed(nil), at: 0), sent("c2", "go", .typed(nil), at: 1)])
if case .entry(_, let d1) = twice[0], case .entry(_, let d2) = twice[1] {
    check(d1?.clientId == "c1" && d2?.clientId == "c2" && twice.count == 2, "repeated text matched in order")
} else { check(false, "twice") }
let redacted = TranscriptTimeline.merge(entries: [te("u", .user, "token [REDACTED]")], sent: [sent("c", "token sk-123", .typed(nil))])
check(redacted.count == 2, "unmatched echo shows a duplicate rather than losing the status")

// An identical message already in the transcript when this one was sent is
// never its echo, even inside the clock window or without a timestamp.
var yesSent = sent("c-yes", "yes", .sending, at: 0)
yesSent.priorEntryIds = ["old-yes", "old-undated"]
let before = TranscriptTimeline.merge(entries: [te("old-yes", .user, "yes", at: -120), te("old-undated", .user, "yes")], sent: [yesSent])
check(before.map(\.id) == ["e:old-yes", "e:old-undated", "p:c-yes"], "pending message doesn't claim an older identical entry \(before.map(\.id))")
yesSent.state = .typed(nil)
let after = TranscriptTimeline.merge(entries: [te("old-yes", .user, "yes", at: -120), te("old-undated", .user, "yes"), te("new-yes", .user, "yes", at: 1)], sent: [yesSent])
if case .entry(let e, let del) = after[2] { check(e.id == "new-yes" && del?.clientId == "c-yes" && after.count == 3, "the real echo is claimed") } else { check(false, "real echo") }
if case .entry(_, let del) = after[0] { check(del == nil, "old entry stays unclaimed") } else { check(false, "old entry") }

// Availability (§6), most fundamental problem first.
let online = MacPresence.online(lastSeen: cmdNow)
func avail(_ f: (inout SessionAvailability.Inputs) -> Void, now: Date = cmdNow) -> SessionAvailability {
    var i = SessionAvailability.Inputs(hasKey: true, relayFeatures: ["sessions-v1"], presence: online,
                                       socketConnected: true, waitStartedAt: cmdNow.addingTimeInterval(-1), hasList: false)
    f(&i)
    return SessionAvailability.evaluate(i, now: now)
}
check(avail { $0.relayFeatures = [] } == .relayTooOld, "relay without feature")
check(avail { $0.relayFeatures = []; $0.hasKey = false } == .relayTooOld, "relay first: re-pairing wouldn't help")
check(avail { $0.relayFeatures = nil } == .waiting, "features unknown yet: don't block")
check(avail { $0.hasKey = false } == .needsRepair(keyMismatch: false), "no sk")
check(avail { $0.keyMismatch = true; $0.hasList = true } == .needsRepair(keyMismatch: true), "undecryptable frames")
check(avail { $0.presence = .offline(lastSeen: nil) } == .macOffline, "Mac offline")
check(avail { $0.presence = .offline(lastSeen: nil); $0.hasList = true } == .macOffline, "offline hides a stale list")
check(avail { $0.presence = .stale(lastSeen: cmdNow) } == .macOffline, "Mac stopped checking in")
check(avail { $0.macOfflineHint = true; $0.hasList = true } == .macOffline, "503 hint")
check(avail { $0.hasList = true } == .ready, "ready")
check(avail { $0.hasList = true; $0.macDisabled = true } == .macDisabled, "list says off on the Mac")
check(avail { $0.macDisabled = true } == .waiting, "disabled only counts once a list arrived")
if let p = SessionsPlaintext.decode(Data(#"{"kind":"list","seq":5,"ts":1761300000000,"boot":"b","sessions":[],"disabled":true}"#.utf8)) { check(p.macDisabled, "disabled flag decoded") } else { check(false, "disabled list") }
if let p = SessionsPlaintext.decode(Data(#"{"kind":"list","seq":6,"ts":1761300000000,"boot":"b","sessions":[]}"#.utf8)) { check(!p.macDisabled, "no flag: enabled") } else { check(false, "plain list") }
check(avail { $0.onlyStaleFrames = true } == .clockSkew, "only stale frames")
check(avail { _ in } == .waiting, "inside the 5 s window")
check(avail({ _ in }, now: cmdNow.addingTimeInterval(4.5)) == .macTooOld, "no list 5 s after connecting while online")
check(avail({ $0.presence = .unknown }, now: cmdNow.addingTimeInterval(30)) == .waiting, "presence unknown: keep waiting")
check(avail({ $0.socketConnected = false }, now: cmdNow.addingTimeInterval(30)) == .waiting, "socket down: connecting")
check(avail({ $0.waitStartedAt = nil }, now: cmdNow.addingTimeInterval(30)) == .waiting, "no wait start yet")
check(AgentBackend(wire: "  ") == .other("unknown") && AgentBackend(wire: "Claude") == .known(.claude), "backend wire mapping")

// MARK: v4 — diff, folders, start, Mac status extras

let diffJSON = #"{"kind":"diff","seq":9,"ts":1761300000000,"boot":"b","sessionId":"s1","clientId":"c1","scope":"turn","repo":"page","files":[{"path":"a.swift","added":12,"removed":3,"status":"modified"},{"path":"n.md","added":4,"removed":0,"status":"added"},{"path":"x","status":"changed","weird":{"a":1}},{"nopath":1}],"patch":"diff --git a/a.swift b/a.swift\nindex 1..2\n--- a/a.swift\n+++ b/a.swift\n@@ -1 +1 @@\n-old\n+new\ndiff --git a/n.md b/n.md\nnew file\n--- /dev/null\n+++ b/n.md\n@@ -0,0 +1,1 @@\n+hi","truncated":true}"#
if let p = SessionsPlaintext.decode(Data(diffJSON.utf8)), case .diff(let d) = p.update {
    check(d.sessionId == "s1" && d.clientId == "c1" && d.scope == "turn" && d.repo == "page", "diff header")
    check(d.files.map(\.path) == ["a.swift", "n.md", "x"], "diff files (no path dropped, odd field ignored)")
    check(d.added == 16 && d.removed == 3, "diff totals")
    check(d.files[2].added == nil, "changed file has no counts")
    check(d.truncated, "diff truncated")
    let secs = d.sections
    check(secs.map(\.path) == ["a.swift", "n.md"], "diff sections by file")
    check(secs[0].lines == ["@@ -1 +1 @@", "-old", "+new"], "headers dropped, hunks kept")
    check(secs[1].lines == ["@@ -0,0 +1,1 @@", "+hi"], "new file section")
} else { check(false, "diff decodes") }
check(SessionsPlaintext.decode(Data(#"{"kind":"diff","seq":1,"ts":1761300000000}"#.utf8)) == nil, "diff needs a session")

let foldersJSON = #"{"kind":"folders","seq":10,"ts":1761300000000,"boot":"b","clientId":"f1","enabled":true,"agents":["claude"],"folders":[{"path":"/Users/me/p","name":"p","lastUsedAt":1761290000000},{"path":"relative","name":"bad"}]}"#
if let p = SessionsPlaintext.decode(Data(foldersJSON.utf8)), case .folders(let f) = p.update {
    check(f.enabled && f.clientId == "f1", "folders header")
    check(f.folders.map(\.path) == ["/Users/me/p"], "only absolute folders")
    check(f.folders.first?.lastUsedAt == Date(timeIntervalSince1970: 1_761_290_000), "folder lastUsedAt")
} else { check(false, "folders decodes") }
if let p = SessionsPlaintext.decode(Data(#"{"kind":"folders","seq":11,"ts":1761300000000,"enabled":false}"#.utf8)), case .folders(let f) = p.update {
    check(!f.enabled && f.folders.isEmpty, "folders off")
} else { check(false, "folders off decodes") }

func cmdJSON(_ c: SessionCommand) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: c.plaintext(clientId: "id", viewer: "v", now: Date(timeIntervalSince1970: 1)))) as? [String: Any] ?? [:]
}
check(cmdJSON(.diff(sessionId: "s1"))["op"] as? String == "diff" && cmdJSON(.diff(sessionId: "s1"))["sessionId"] as? String == "s1", "diff op")
check(cmdJSON(.folders)["op"] as? String == "folders", "folders op")
let startCmd = cmdJSON(.start(folder: "/p", prompt: "fix it"))
check(startCmd["op"] as? String == "start" && startCmd["folder"] as? String == "/p" && startCmd["text"] as? String == "fix it", "start op")

var gate4 = SessionUpdateGate()
if let p = SessionsPlaintext.decode(Data(diffJSON.utf8)) {
    check(gate4.admit(p, now: Date(timeIntervalSince1970: 1_761_300_000)) == .accept, "diff admitted")
    check(gate4.admit(p, now: Date(timeIntervalSince1970: 1_761_300_000)) == .accept, "answers aren't seq-gated")
}

var st4 = MacStatusSnapshot.from(json: ["macConnected": true, "battery": 42, "onAC": false, "working": 2,
    "forecast": ["cutoff": 10, "minutes": 35, "drainPerHour": 40.0],
    "usage": ["fiveHour": ["pct": 62.4, "resetsAt": "2026-10-25T17:00:00Z"], "hitAt": "2026-10-25T16:10:00Z", "updatedAt": "2026-10-25T15:00:00Z"]])
check(st4.working == 2, "working count")
check(st4.batteryLine == "Battery 42% · cutoff in about 35 min", "battery line")
let fmt: (Date) -> String = { d in String(Int(d.timeIntervalSince1970)) }
let usageNow = PageDate.parse("2026-10-25T15:30:00Z")!
check(st4.usageLine(now: usageNow, format: fmt) == "Claude 5-hour 62% · resets \(Int(PageDate.parse("2026-10-25T17:00:00Z")!.timeIntervalSince1970)) · limit ~\(Int(PageDate.parse("2026-10-25T16:10:00Z")!.timeIntervalSince1970))", "usage line")
check(st4.usageLine(now: usageNow.addingTimeInterval(7 * 3600), format: fmt) == nil, "stale usage hidden")
st4.onAC = true
check(st4.batteryLine == nil, "no forecast line on AC")
st4.applyExtras(["battery": 50])
check(st4.forecast == nil && st4.usage == nil && st4.working == nil, "a heartbeat without extras clears them")
check(MacUsage(["fiveHour": ["pct": "x"]]) == nil, "bad usage ignored")
check(MacBatteryForecast(["cutoff": 10]) == nil, "incomplete forecast ignored")

// MARK: widget

let wNow = PageDate.parse("2026-10-25T15:30:00Z")!
let wJSON: [String: Any] = ["macConnected": true, "lastHeartbeatAt": "2026-10-25T15:29:50Z", "pendingCount": 2,
                            "working": 3, "activeSessions": 9, "battery": 30, "onAC": false,
                            "forecast": ["cutoff": 10, "minutes": 50, "drainPerHour": 24]]
let w = WidgetStatus.from(json: wJSON, macName: "Studio", now: wNow, format: { _ in "t" })
check(w.presence == .online, "widget online")
check(w.headline == "2 need you", "widget headline")
check(w.detail == "3 working · 9 live", "widget detail")
check(w.batteryLine == "Battery 30% · cutoff in about 50 min", "widget battery line")
check(w.macName == "Studio", "widget mac name")
let w1 = WidgetStatus.from(json: ["macConnected": false, "pendingCount": 1, "lastHeartbeatAt": "2026-10-25T10:00:00Z"],
                           macName: nil, now: wNow, format: { _ in "t" })
check(w1.headline == "1 needs you" && w1.presence == .offline && w1.macName == "Your Mac", "widget offline, singular")
check(WidgetStatus.from(json: [:], macName: nil, now: wNow, format: { _ in "t" }).headline == "All quiet", "widget quiet")

// MARK: several Macs

let mA = SavedMac(id: "a", name: "Studio", relayURL: "https://r.example", token: "tokA", sessionKey: nil, pairedAt: Date(timeIntervalSince1970: 100))
let mB = SavedMac(id: "b", name: "Laptop", relayURL: "https://r.example", token: "tokB", sessionKey: "k", pairedAt: Date(timeIntervalSince1970: 200))
var macs = SavedMacs.upsert([], mA)
macs = SavedMacs.upsert(macs, mB)
check(macs.map(\.id) == ["b", "a"], "newest first")
let mA2 = SavedMac(id: "a2", name: "Studio", relayURL: "https://r.example", token: "tokA", sessionKey: "k2", pairedAt: Date(timeIntervalSince1970: 300))
macs = SavedMacs.upsert(macs, mA2)
check(macs.map(\.id) == ["a2", "b"], "same token replaces the old entry")
check(SavedMacs.next(in: macs, excluding: "a2")?.id == "b", "next after removing the active one")
check(SavedMacs.next(in: [mA], excluding: "a") == nil, "no other Mac")
check(SavedMacs.decode(SavedMacs.encode(macs)) == macs, "round trip")
check(SavedMacs.decode("not json").isEmpty && SavedMacs.decode(nil).isEmpty, "bad stored list is empty")
check(SavedMacs.removing("b", from: macs).map(\.id) == ["a2"], "remove")
var manyMacs: [SavedMac] = []
for i in 0..<12 { manyMacs = SavedMacs.upsert(manyMacs, SavedMac(id: "\(i)", name: "M\(i)", relayURL: "https://r", token: "t\(i)", sessionKey: nil, pairedAt: Date())) }
check(manyMacs.count == SavedMacs.maxMacs && manyMacs.first?.id == "11", "capped, newest kept")
check(mA.relayHost == "r.example", "relay host")

print("passes=\(passes) failures=\(failures)")
exit(failures == 0 ? 0 : 1)
