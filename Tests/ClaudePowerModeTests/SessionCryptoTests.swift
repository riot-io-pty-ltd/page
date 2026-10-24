import CryptoKit
import XCTest
@testable import ClaudePowerMode

/// SESSIONS-PROTOCOL.md §1–§2: the pairing's session key and the envelope
/// both apps must agree on byte for byte.
final class SessionCryptoTests: XCTestCase {
    private let root = Data((0...31).map { UInt8($0) })
    private let nonce = Data((0xa0...0xab).map { UInt8($0) })

    private func keyBytes(_ k: SymmetricKey) -> Data { k.withUnsafeBytes { Data($0) } }

    // MARK: test vector

    func testVectorSubkeys() {
        XCTAssertEqual(SessionCrypto.base64URLEncode(root), "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
        XCTAssertEqual(SessionCrypto.base64URLEncode(nonce), "oKGio6Slpqeoqaqr")
        XCTAssertEqual(SessionCrypto.base64URLEncode(keyBytes(SessionCrypto.subkey(root: root, .macToPhone))),
                       "ofSfPY2KtPqbs29ecqGVJzfSrP61BvMETQTitpTwtYE")
        XCTAssertEqual(SessionCrypto.base64URLEncode(keyBytes(SessionCrypto.subkey(root: root, .phoneToMac))),
                       "s_XovkSs3InwR9tqHVrGlT_dVvTJeDPPtd0r-wC1qp4")
    }

    func testVectorMacToPhone() throws {
        let plaintext = #"{"kind":"list","seq":1,"ts":1761300000000,"sessions":[]}"#
        let e = try XCTUnwrap(SessionCrypto.seal(Data(plaintext.utf8), key: SessionCrypto.subkey(root: root, .macToPhone),
                                                 aad: "sessions.update", nonce: nonce))
        XCTAssertEqual(e.v, 1)
        XCTAssertEqual(e.n, "oKGio6Slpqeoqaqr")
        XCTAssertEqual(e.c, "izpLGj9N9Rpxuzq00howYI0D93aMC4vbU3Un38nzkzaX6rpd2wEiAvuseOahsZ9_zyivF1z2cuLwWX3k6Coa8QEvrfguLaN3")
        let opened = SessionCrypto.open(e, key: try XCTUnwrap(SessionKeys(root: root)).macToPhone, aad: SessionCrypto.updateAAD)
        XCTAssertEqual(opened.map { String(decoding: $0, as: UTF8.self) }, plaintext)
    }

    func testVectorPhoneToMac() throws {
        let plaintext = #"{"op":"input","clientId":"c1","ts":1761300000000,"sessionId":"s1","text":"hi","viewer":"v1"}"#
        let e = try XCTUnwrap(SessionCrypto.seal(Data(plaintext.utf8), key: SessionCrypto.subkey(root: root, .phoneToMac),
                                                 aad: "sessions.command", nonce: nonce))
        XCTAssertEqual(e.c, "sfJ3_bSsO7l16uEp6oH6PFnwlSLI8D_5PtVk8-InyYs-UxcC40NUQDmbHrttBjpm5nJaeQFIgITtiHUF1c6EvBs3hEB0DiBSSIlItp7XAqPjYgLckNcOihF1sKMrZVv8vgUfNIaRAtrMrd_k")
        // The phone's frame, as the Mac receives it.
        let fromPhone = try XCTUnwrap(SessionEnvelope(json: ["v": 1, "n": "oKGio6Slpqeoqaqr", "c": e.c]))
        let opened = try XCTUnwrap(SessionCrypto.open(fromPhone, key: try XCTUnwrap(SessionKeys(root: root)).phoneToMac,
                                                      aad: SessionCrypto.commandAAD))
        XCTAssertEqual(SessionCommand.parse(opened),
                       SessionCommand(op: "input", clientId: "c1", ts: 1761300000000, viewer: "v1", sessionId: "s1", text: "hi"))
    }

    // MARK: properties

    func testRoundTripUsesAFreshNonceEachTime() throws {
        let keys = try XCTUnwrap(SessionKeys(root: root))
        let msg = Data("hello".utf8)
        let a = try XCTUnwrap(SessionCrypto.seal(msg, key: keys.macToPhone, aad: SessionCrypto.updateAAD))
        let b = try XCTUnwrap(SessionCrypto.seal(msg, key: keys.macToPhone, aad: SessionCrypto.updateAAD))
        XCTAssertNotEqual(a.n, b.n)
        XCTAssertNotEqual(a.c, b.c)
        XCTAssertEqual(SessionCrypto.base64URLDecode(a.n)?.count, 12)
        XCTAssertEqual(SessionCrypto.open(a, key: keys.macToPhone, aad: SessionCrypto.updateAAD), msg)
        XCTAssertFalse(a.n.contains("=") || a.c.contains("=") || a.c.contains("+") || a.c.contains("/"))
    }

    func testWrongDirectionKeyFails() throws {
        let keys = try XCTUnwrap(SessionKeys(root: root))
        // A Mac frame reflected back at the Mac as a command doesn't open.
        let e = try XCTUnwrap(SessionCrypto.seal(Data("x".utf8), key: keys.macToPhone, aad: SessionCrypto.commandAAD))
        XCTAssertNil(SessionCrypto.open(e, key: keys.phoneToMac, aad: SessionCrypto.commandAAD))
        let other = try XCTUnwrap(SessionKeys(root: Data(repeating: 7, count: 32)))
        XCTAssertNil(SessionCrypto.open(e, key: other.macToPhone, aad: SessionCrypto.commandAAD))
    }

    func testAADMismatchFails() throws {
        let keys = try XCTUnwrap(SessionKeys(root: root))
        let e = try XCTUnwrap(SessionCrypto.seal(Data("x".utf8), key: keys.phoneToMac, aad: SessionCrypto.updateAAD))
        XCTAssertNil(SessionCrypto.open(e, key: keys.phoneToMac, aad: SessionCrypto.commandAAD), "relabelled frame")
        XCTAssertNotNil(SessionCrypto.open(e, key: keys.phoneToMac, aad: SessionCrypto.updateAAD))
    }

    func testTamperedOrMalformedEnvelopesFail() throws {
        let keys = try XCTUnwrap(SessionKeys(root: root))
        let e = try XCTUnwrap(SessionCrypto.seal(Data("payload".utf8), key: keys.phoneToMac, aad: SessionCrypto.commandAAD))
        var bytes = try XCTUnwrap(SessionCrypto.base64URLDecode(e.c))
        bytes[0] ^= 1
        let tampered = try XCTUnwrap(SessionEnvelope(json: ["v": 1, "n": e.n, "c": SessionCrypto.base64URLEncode(bytes)]))
        XCTAssertNil(SessionCrypto.open(tampered, key: keys.phoneToMac, aad: SessionCrypto.commandAAD))
        for bad in [["v": 1, "n": "short", "c": e.c], ["v": 1, "n": e.n, "c": "AAAA"], ["v": 1, "n": "!!", "c": "??"]] {
            let env = try XCTUnwrap(SessionEnvelope(json: bad))
            XCTAssertNil(SessionCrypto.open(env, key: keys.phoneToMac, aad: SessionCrypto.commandAAD))
        }
        XCTAssertNil(SessionEnvelope(json: ["v": 2, "n": e.n, "c": e.c]))
        XCTAssertNil(SessionEnvelope(json: ["v": 1, "n": 5, "c": e.c]))
        XCTAssertNil(SessionEnvelope(json: "nope"))
    }

    func testBase64URLAcceptsPadding() {
        XCTAssertEqual(SessionCrypto.base64URLDecode("oKGio6Slpqeoqaqr"), nonce)
        XCTAssertEqual(SessionCrypto.base64URLDecode("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="), root)
        XCTAssertEqual(SessionCrypto.base64URLDecode("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"), root)
        XCTAssertNil(SessionCrypto.base64URLDecode("A"))
        XCTAssertNil(SessionCrypto.base64URLDecode("AB=C"))
    }

    func testSessionKeysNeedExactly32Bytes() {
        XCTAssertNil(SessionKeys(root: Data(repeating: 1, count: 31)))
        XCTAssertNil(SessionKeys(root: Data(repeating: 1, count: 33)))
        XCTAssertNotNil(SessionKeys(root: Data(repeating: 1, count: 32)))
    }
}

/// The session key file, always in a throwaway directory (never the real
/// Application Support file).
final class SessionKeyStorageTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("page-sk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    func testGeneratedOnceStoredOwnerOnlyAndStable() throws {
        let url = dir.appendingPathComponent("session_key.txt")
        let key = try XCTUnwrap(PairingTokenManager.currentSessionKey(at: url))
        XCTAssertEqual(key.count, 32)
        XCTAssertEqual(PairingTokenManager.currentSessionKey(at: url), key, "the same key until rotated")
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let stored = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(SessionCrypto.base64URLDecode(stored), key)
        XCTAssertFalse(stored.contains("="))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testRotateReplacesTheKey() throws {
        let url = dir.appendingPathComponent("session_key.txt")
        let first = try XCTUnwrap(PairingTokenManager.currentSessionKey(at: url))
        let second = try XCTUnwrap(PairingTokenManager.rotateSessionKey(at: url))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(PairingTokenManager.currentSessionKey(at: url), second)
    }

    func testCorruptFileIsReplaced() throws {
        let url = dir.appendingPathComponent("session_key.txt")
        try "not-a-key\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(PairingTokenManager.readSessionKey(at: url))
        let key = try XCTUnwrap(PairingTokenManager.currentSessionKey(at: url))
        XCTAssertEqual(key.count, 32)
        XCTAssertEqual(PairingTokenManager.readSessionKey(at: url), key)
    }

    func testPairingPayloadCarriesSk() throws {
        let base = try Config.validatedRelayURL("https://page.me.workers.dev").get()
        let key = Data((0...31).map { UInt8($0) })
        let json = PairingTokenManager.pairingPayloadJSON(relayBaseURL: base, token: "t0k3n", sessionKey: key)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["v"] as? Int, 1, "the payload stays v1")
        XCTAssertEqual(obj["sk"] as? String, "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
        // A key of the wrong length is never put in the QR.
        let bad = PairingTokenManager.pairingPayloadJSON(relayBaseURL: base, token: "t", sessionKey: Data(repeating: 1, count: 16))
        XCTAssertFalse(bad.contains("\"sk\""))
    }
}

/// RelayClient's sessions-v1 frames.
final class RelaySessionsFrameTests: XCTestCase {
    private let env: [String: Any] = ["v": 1, "n": "oKGio6Slpqeoqaqr", "c": "AAAAAAAAAAAAAAAAAAAAAA"]

    func testInboundFrames() throws {
        XCTAssertEqual(RelayClient.sessionsFrame(type: "sessions.command", payload: ["e": env]),
                       .command(try XCTUnwrap(SessionEnvelope(json: env))))
        XCTAssertEqual(RelayClient.sessionsFrame(type: "phones.status", payload: ["phones": 2]), .phones(2))
        XCTAssertEqual(RelayClient.sessionsFrame(type: "phones.status", payload: ["phones": 0]), .phones(0))
        XCTAssertEqual(RelayClient.sessionsFrame(type: "phones.status", payload: ["phones": -1]), .malformed)
        XCTAssertEqual(RelayClient.sessionsFrame(type: "phones.status", payload: [:]), .malformed)
        XCTAssertEqual(RelayClient.sessionsFrame(type: "sessions.command", payload: ["e": ["v": 9]]), .malformed)
        XCTAssertEqual(RelayClient.sessionsFrame(type: "sessions.command", payload: nil), .malformed)
        XCTAssertNil(RelayClient.sessionsFrame(type: "reply", payload: [:]))
        XCTAssertNil(RelayClient.sessionsFrame(type: "sessions.update", payload: ["e": env]))
    }

    func testOutboundFrameShape() throws {
        let e = try XCTUnwrap(SessionEnvelope(json: env))
        let data = try XCTUnwrap(RelayClient.sessionsUpdateFrame(e))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "sessions.update")
        let payload = try XCTUnwrap(obj["payload"] as? [String: Any])
        XCTAssertEqual(SessionEnvelope(json: payload["e"]), e)
        XCTAssertEqual(payload.count, 1, "nothing but the envelope reaches the relay")
    }

    func testSessionsUpdatesAreNeverQueuedOrRequeued() {
        var q = OutboundQueue(capacity: 5)
        let now = Date()
        for _ in 0..<50 {
            q.enqueue(.init(type: "sessions.update", key: nil, data: Data("x".utf8), enqueuedAt: now))
        }
        XCTAssertEqual(q.count, 0)
        q.requeueFailed(.init(type: "sessions.update", key: nil, data: Data(), enqueuedAt: now), now: now)
        XCTAssertEqual(q.count, 0)
        // Other frames still queue as before.
        q.enqueue(.init(type: "reply.injected", key: "a", data: Data(), enqueuedAt: now))
        XCTAssertEqual(q.count, 1)
    }

    func testOfflineClientDropsUpdates() throws {
        let client = RelayClient(url: URL(string: "ws://127.0.0.1:9/ws")!, token: "t")
        defer { client.stop() }
        let e = try XCTUnwrap(SessionEnvelope(json: env))
        client.sendSessionsUpdate(e)   // not started: nothing to send to, nothing kept
        XCTAssertFalse(client.isConnected)
    }

    /// Over a real local socket (127.0.0.1 only): inbound sessions frames
    /// reach the callbacks, and an update goes out as one frame.
    func testFramesOverALocalSocket() throws {
        let server = try LocalWebSocketServer()
        defer { server.stop() }
        let port = try XCTUnwrap(server.waitForPort(timeout: 5))
        let client = RelayClient(url: URL(string: "ws://127.0.0.1:\(port)/ws")!, token: "t")
        defer { client.stop() }
        let gotPhones = expectation(description: "phones.status")
        let gotCommand = expectation(description: "sessions.command")
        var phones: Int?
        var command: SessionEnvelope?
        client.onPhonesStatus = { phones = $0; gotPhones.fulfill() }
        client.onSessionsCommand = { command = $0; gotCommand.fulfill() }
        client.start()
        let deadline = Date().addingTimeInterval(5)
        while !client.isConnected && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(client.isConnected, "local socket didn't connect")

        server.send(try JSONSerialization.data(withJSONObject: ["type": "phones.status", "payload": ["phones": 1]]))
        server.send(try JSONSerialization.data(withJSONObject: ["type": "sessions.command", "payload": ["e": env]]))
        wait(for: [gotPhones, gotCommand], timeout: 5)
        XCTAssertEqual(phones, 1)
        XCTAssertEqual(command, SessionEnvelope(json: env))

        client.sendSessionsUpdate(try XCTUnwrap(SessionEnvelope(json: env)))
        let sent = Date().addingTimeInterval(3)
        var frame: [String: Any]?
        while frame == nil && Date() < sent {
            frame = server.receivedMessages.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .first { $0["type"] as? String == "sessions.update" }
            if frame == nil { Thread.sleep(forTimeInterval: 0.05) }
        }
        XCTAssertEqual(SessionEnvelope(json: (frame?["payload"] as? [String: Any])?["e"]), SessionEnvelope(json: env))
    }
}

final class RemoteSessionsConfigTests: XCTestCase {
    func testDefaultOnAndDecoding() throws {
        XCTAssertTrue(Config().remoteSessionsEnabled)
        XCTAssertTrue(try JSONDecoder().decode(Config.self, from: Data("{}".utf8)).remoteSessionsEnabled)
        XCTAssertFalse(try JSONDecoder().decode(Config.self, from: Data(#"{"remoteSessionsEnabled": false}"#.utf8)).remoteSessionsEnabled)
        XCTAssertTrue(try JSONDecoder().decode(Config.self, from: Data(#"{"remoteSessionsEnabled": "no"}"#.utf8)).remoteSessionsEnabled)
        var c = Config()
        c.remoteSessionsEnabled = false
        let round = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        XCTAssertFalse(round.remoteSessionsEnabled)
    }

    func testPreferencesSaveOnlyWhenChanged() {
        let base = Config()
        let baseline = PreferencesForm(base)
        var form = baseline
        form.remoteSessionsEnabled = false
        XCTAssertFalse(form.merged(onto: base, changedFrom: baseline).remoteSessionsEnabled)
        var edited = base
        edited.remoteSessionsEnabled = false
        XCTAssertFalse(baseline.merged(onto: edited, changedFrom: baseline).remoteSessionsEnabled,
                       "an untouched checkbox doesn't overwrite config.json")
    }
}
