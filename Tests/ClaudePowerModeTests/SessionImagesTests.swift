import XCTest
@testable import ClaudePowerMode

/// `images-v1` through `SessionRemote` (SESSIONS-PROTOCOL.md "Images"): the
/// phone's sealed `imagePart` / `inputImages` in, the list's `caps` and
/// `attach` and the sealed results out, with the backends faked. Nothing types.
final class SessionImagesTests: XCTestCase {
    private let root = Data((0...31).map { UInt8($0 &* 5) })
    private lazy var keys = SessionKeys(root: root)!
    private let t0 = Date(timeIntervalSince1970: 1_761_300_000)

    private final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private final class Sink: SessionsUpdateSink {
        private let lock = NSLock()
        private var _sent: [SessionEnvelope] = []
        var isConnected = true
        var sent: [SessionEnvelope] { lock.lock(); defer { lock.unlock() }; return _sent }
        func sendSessionsUpdate(_ envelope: SessionEnvelope) {
            lock.lock(); _sent.append(envelope); lock.unlock()
        }
    }

    private final class Backends: SessionRemoteBackends {
        var hosts: [String: SessionHostInfo] = [:]
        var calls: [(sessionId: String, clientId: String, images: [AssembledImage], text: String)] = []
        var result = SessionCommandResult(code: .delivered, reason: nil, detail: "Sent the photo to Claude in tmux pane %3", attached: 1)

        func probeHosts(_ sessions: [AgentSession]) -> [String: SessionHostInfo] {
            hosts.filter { id, _ in sessions.contains { $0.sessionId == id } }
        }
        func liveStatuses(_ sessions: [AgentSession]) -> [String: ClaudeSessionStatus] { [:] }
        func transcriptFile(for session: AgentSession) -> SessionTranscriptFile? { nil }
        func input(_ session: AgentSession, clientId: String, text: String, interventionId: String?,
                   completion: @escaping (SessionCommandResult) -> Void) {
            completion(.failed("not in this test"))
        }
        func interrupt(_ session: AgentSession, interventionId: String?, completion: @escaping (SessionCommandResult) -> Void) {
            completion(.failed("not in this test"))
        }
        func inputImages(_ session: AgentSession, clientId: String, images: [AssembledImage], text: String,
                         interventionId: String?, completion: @escaping (SessionCommandResult) -> Void) {
            calls.append((session.sessionId, clientId, images, text))
            completion(result)
        }
    }

    private var clock: Clock!
    private var sink: Sink!
    private var backends: Backends!
    private var remote: SessionRemote!

    override func setUp() {
        clock = Clock(t0)
        sink = Sink()
        backends = Backends()
        remote = makeRemote()
    }

    override func tearDown() {
        remote?.stop()
        remote?.waitUntilIdle()
    }

    private func makeRemote(wait: TimeInterval = 1, store: ImageStore? = nil) -> SessionRemote {
        let c = clock!
        let r = SessionRemote(backends: backends, now: { c.now }, autoTimer: false, macName: { "Test Mac" },
                              imageStore: store, imagePartWait: wait, heldSessions: { [] })
        r.attach(sink: sink, rootKey: root)
        r.waitUntilIdle()
        return r
    }

    // MARK: helpers

    private func session(_ id: String, backend: AgentBackendID = .claude) -> AgentSession {
        AgentSession(backend: backend, sessionId: id, cwd: NSHomeDirectory() + "/projects/\(id)", title: id,
                     source: .terminal, state: .idle, lastActivityAt: t0, activeFlags: [], supportsRemoteReply: true)
    }

    private func decoded(_ e: SessionEnvelope) -> [String: Any]? {
        SessionCrypto.open(e, key: keys.macToPhone, aad: SessionCrypto.updateAAD)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private var frames: [[String: Any]] { sink.sent.compactMap(decoded) }
    private func results(_ clientId: String) -> [[String: Any]] {
        frames.filter { $0["kind"] as? String == "result" && $0["clientId"] as? String == clientId }
    }

    private func sealed(_ fields: [String: Any]) -> SessionEnvelope {
        var obj = fields
        if obj["ts"] == nil { obj["ts"] = clock.now.timeIntervalSince1970 * 1000 }
        if obj["clientId"] == nil { obj["clientId"] = UUID().uuidString }
        if obj["viewer"] == nil { obj["viewer"] = "v1" }
        return SessionCrypto.seal(try! JSONSerialization.data(withJSONObject: obj), key: keys.phoneToMac, aad: SessionCrypto.commandAAD)!
    }

    private func send(_ fields: [String: Any]) {
        remote.handleCommand(sealed(fields))
        remote.waitUntilIdle()
    }

    private func setSessions(_ s: [AgentSession]) {
        remote.update(sessions: s, pending: [])
        remote.waitUntilIdle()
    }

    private func lastList() -> [String: Any]? {
        remote.setPhones(1, from: sink)
        remote.waitUntilIdle()
        send(["op": "refresh"])
        return frames.last { $0["kind"] as? String == "list" }
    }

    private func row(_ id: String) -> [String: Any]? {
        (lastList()?["sessions"] as? [[String: Any]])?.first { $0["id"] as? String == id }
    }

    private let photo = Data((0..<70).map { UInt8($0) })

    private func partFields(_ data: Data, id: String = "imageAAAA1", size: Int = 32, sha: String? = nil,
                            session: String = "s1") -> [[String: Any]] {
        let chunks = stride(from: 0, to: data.count, by: size).map { data.subdata(in: $0..<min($0 + size, data.count)) }
        return chunks.enumerated().map { i, c in
            ["op": "imagePart", "sessionId": session, "imageId": id, "index": i, "total": chunks.count, "bytes": data.count,
             "sha256": sha ?? ImageWire.sha256Hex(data), "mime": "image/png", "data": c.base64EncodedString()]
        }
    }

    private func inputImages(_ clientId: String, _ data: Data, id: String = "imageAAAA1", text: String = "what is this?",
                             session: String = "s1", sha: String? = nil) {
        send(["op": "inputImages", "clientId": clientId, "sessionId": session, "text": text,
              "images": [["id": id, "sha256": sha ?? ImageWire.sha256Hex(data), "bytes": data.count, "mime": "image/png"]]])
    }

    // MARK: capabilities

    func testTheListAdvertisesPhotosAndEachRowSaysHow() {
        backends.hosts = [
            "tmux1": SessionHostInfo(host: "tmux", canType: true, canInterrupt: true),
            "term1": SessionHostInfo(host: "Terminal", canType: true, canInterrupt: false),
            "ghost": .blocked("Ghostty", "Page can't type into Ghostty yet"),
            "codex1": SessionHostInfo(host: "tmux", canType: true, canInterrupt: true),
        ]
        setSessions([session("tmux1"), session("term1"), session("ghost"), session("codex1", backend: .codex)])
        _ = lastList()   // the first list starts the host probe
        let list = lastList()
        XCTAssertEqual(list?["caps"] as? [String], ["hold-v1", "retract-v1", "images-v1"])
        XCTAssertEqual(row("tmux1")?["attach"] as? String, "image")
        XCTAssertNil(row("tmux1")?["attachBlocker"])
        XCTAssertEqual(row("term1")?["attach"] as? String, "path")
        XCTAssertNil(row("ghost")?["attach"])
        XCTAssertNil(row("ghost")?["attachBlocker"], "no composer there, so nothing to explain")
        XCTAssertNil(row("codex1")?["attach"])
        XCTAssertEqual(row("codex1")?["attachBlocker"] as? String, ImageDelivery.codexMessage)
    }

    // MARK: acceptance

    func testPiecesSkipTheReplayGuardAndNeverGetAResult() {
        var replay = SessionReplayGuard()
        let part = sealed(partFields(photo)[0].merging(["clientId": "p1"]) { $1 })
        guard case .accept(let cmd) = SessionRemote.accept(part, keys: keys, enabled: true, now: t0, replay: &replay) else {
            return XCTFail("a piece is accepted")
        }
        XCTAssertNotNil(cmd.imagePart)
        XCTAssertEqual(replay.count, 0, "pieces never take a place in the replay guard")
        guard case .accept = SessionRemote.accept(part, keys: keys, enabled: true, now: t0, replay: &replay) else {
            return XCTFail("the same piece again is accepted (the assembler makes it harmless)")
        }

        let stale = sealed(partFields(photo)[0].merging(["ts": (t0.timeIntervalSince1970 - 600) * 1000]) { $1 })
        XCTAssertEqual(SessionRemote.accept(stale, keys: keys, enabled: true, now: t0, replay: &replay), .drop("stale image part"))
        XCTAssertEqual(SessionRemote.accept(part, keys: keys, enabled: false, now: t0, replay: &replay), .drop("image part while disabled"))

        let final = sealed(["op": "inputImages", "clientId": "i1", "sessionId": "s1", "text": ""])
        guard case .accept = SessionRemote.accept(final, keys: keys, enabled: true, now: t0, replay: &replay) else {
            return XCTFail("inputImages is accepted")
        }
        XCTAssertEqual(replay.count, 1, "inputImages goes through the guard")
        XCTAssertEqual(SessionRemote.accept(final, keys: keys, enabled: true, now: t0, replay: &replay), .drop("replay"))
        let staleFinal = sealed(["op": "inputImages", "clientId": "i2", "ts": (t0.timeIntervalSince1970 - 600) * 1000])
        guard case .reply(_, let r) = SessionRemote.accept(staleFinal, keys: keys, enabled: true, now: t0, replay: &replay) else {
            return XCTFail("a stale inputImages is answered")
        }
        XCTAssertEqual(r.reason, .stale)
    }

    // MARK: delivery

    func testPiecesThenTheMessageReachTheBackendWhole() {
        setSessions([session("s1")])
        for p in partFields(photo) { send(p) }
        XCTAssertTrue(frames.filter { $0["kind"] as? String == "result" }.isEmpty, "pieces are never answered")
        inputImages("c1", photo, text: "  what is this?  ")
        XCTAssertEqual(backends.calls.count, 1)
        XCTAssertEqual(backends.calls.first?.images, [AssembledImage(id: "imageAAAA1", data: photo, mime: "image/png")])
        XCTAssertEqual(backends.calls.first?.text, "what is this?")
        let r = results("c1")
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.first?["code"] as? String, "delivered")
        XCTAssertEqual(r.first?["attached"] as? Int, 1)
    }

    func testTheMessageWaitsForAStragglingPiece() {
        setSessions([session("s1")])
        let ps = partFields(photo)
        for p in ps.dropLast() { send(p) }
        inputImages("c1", photo)
        XCTAssertTrue(backends.calls.isEmpty)
        XCTAssertTrue(results("c1").isEmpty, "still waiting")
        send(ps.last!)
        XCTAssertEqual(backends.calls.count, 1, "the last piece sends it")
        XCTAssertEqual(results("c1").count, 1)
    }

    func testPiecesThatNeverArriveAreReportedMissing() {
        remote.stop()
        remote = makeRemote(wait: 0.05)
        setSessions([session("s1")])
        send(partFields(photo)[0])
        inputImages("c1", photo)
        let deadline = Date().addingTimeInterval(2)
        while results("c1").isEmpty && Date() < deadline { usleep(20_000); remote.waitUntilIdle() }
        let r = results("c1").first
        XCTAssertEqual(r?["reason"] as? String, "attachment_missing")
        XCTAssertEqual(r?["missing"] as? [String], ["imageAAAA1"])
        XCTAssertTrue(backends.calls.isEmpty)
    }

    func testAPhotoWhoseHashDoesntMatchIsRefused() {
        setSessions([session("s1")])
        let wrong = String(repeating: "c", count: 64)
        for p in partFields(photo, sha: wrong) { send(p) }
        inputImages("c1", photo, sha: wrong)
        XCTAssertEqual(results("c1").first?["reason"] as? String, "attachment_invalid")
        XCTAssertTrue(backends.calls.isEmpty)
    }

    func testAMalformedPhotoListOrAnUnknownSessionIsRefused() {
        setSessions([session("s1")])
        send(["op": "inputImages", "clientId": "c1", "sessionId": "s1", "text": "hi", "images": [["id": "x"]]])
        XCTAssertEqual(results("c1").first?["reason"] as? String, "attachment_invalid")
        inputImages("c2", photo, session: "nope")
        XCTAssertEqual(results("c2").first?["reason"] as? String, "not_found")
        send(["op": "inputImages", "clientId": "c3", "sessionId": "s1", "text": String(repeating: "x", count: 8001),
              "images": [["id": "imageAAAA1", "sha256": ImageWire.sha256Hex(photo), "bytes": photo.count, "mime": "image/png"]]])
        XCTAssertEqual(results("c3").first?["reason"] as? String, "error")
        XCTAssertTrue(backends.calls.isEmpty)
    }

    func testImageResultFieldsAreOptional() {
        let r = SessionCommandResult(code: .refused, reason: .attachUnsupported, detail: "x")
        XCTAssertEqual(r.fields(clientId: "c")["reason"] as? String, "attach_unsupported")
        var withMissing = SessionCommandResult.refused(.attachmentMissing, "gone")
        withMissing.missing = ["imageAAAA1"]
        XCTAssertEqual(withMissing.fields(clientId: "c")["missing"] as? [String], ["imageAAAA1"])
        XCTAssertNil(SessionCommandResult.refused(.attachBusy, "busy").fields(clientId: "c")["attached"])
    }

    /// The `imagePart` test vector in SESSIONS-PROTOCOL.md "Images" (the §2 key and nonce).
    func testTheProtocolDocsImagePartVector() throws {
        let docRoot = Data((0...31).map { UInt8($0) })
        let docKeys = try XCTUnwrap(SessionKeys(root: docRoot))
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        XCTAssertEqual(ImageWire.sha256Hex(png), "4c4b6a3be1314ab86138bef4314dde022e600960d8689a2c8f8631802d20dab6")
        let plain = #"{"op":"imagePart","clientId":"p1","ts":1761300000000,"viewer":"v1","sessionId":"s1","imageId":"img_0001","index":0,"total":1,"bytes":8,"sha256":"4c4b6a3be1314ab86138bef4314dde022e600960d8689a2c8f8631802d20dab6","mime":"image/png","data":"iVBORw0KGgo="}"#
        let nonce = Data((0xa0...0xab).map { UInt8($0) })
        let e = try XCTUnwrap(SessionCrypto.seal(Data(plain.utf8), key: docKeys.phoneToMac, aad: SessionCrypto.commandAAD, nonce: nonce))
        XCTAssertEqual(e.c, "sfJ3_bSsO7l2-_M4mMyqKxe10i_Q0D61cL5j4Popm85vXQ9Hp1dfQj6dH7htBjpm-mAZLF4Zn4LmtnRVzdbV-wg5ihZiEycDG8ROltjZGvf5NleVwJxZyQAh27rd_icoECLTsVeB0dO1byIYo8XlndG-KezuqN-17JSE65Aqpgg-31jI_KaizgNnnPsfF_on_Lfg0ibBnsPwNg2xNJz4GSO8b_2SX1kn36Es7xohPMngqJBCjeKMBY9wpMiFKBeRqKqf_VIC-foBtzPDdgnuD4lX2XIMHhcC6T-z_7YqiViBEha8t23VoCHhAO6F-Bvzy8CmL9jZmO4L2Ck9rm_TTTsE1TF1_uaPBnrB-Q")
        let cmd = try XCTUnwrap(SessionCommand.parse(Data(plain.utf8)))
        XCTAssertEqual(cmd.imagePart?.data, png)
        XCTAssertEqual(cmd.imagePart?.imageId, "img_0001")
    }

    // MARK: a new pairing

    func testANewPairingDeletesThePhotosReceived() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("page-imgwipe-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ImageStore(base: base)
        remote.stop()
        remote = makeRemote(store: store)
        let path = try store.write(ImageInboxTests.image(), kind: .png, sessionId: "s1").get()
        remote.attach(sink: sink, rootKey: root)
        remote.waitUntilIdle()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "the same pairing keeps them")
        remote.attach(sink: sink, rootKey: Data(repeating: 9, count: 32))
        remote.waitUntilIdle()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}
