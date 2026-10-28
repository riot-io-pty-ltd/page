import XCTest
@testable import ClaudePowerMode

/// `ImageDelivery` (SESSIONS-PROTOCOL.md "Images"): the whole run with every
/// I/O faked, plus its pure parts, the input-box reading, the transcript's
/// forward reader and each terminal's paste route. Nothing types anywhere.
final class ImageDeliveryTests: XCTestCase {
    typealias Box = InjectionExecutor.ClaudeInputContent
    private let sid = "6f1f2b2e-6a54-4b52-9d2c-3f1f7d7b8a90"
    private let path1 = "/private/var/folders/cd/x/T/page-images/6f1f2b2e-6a54-4b52-9d2c-3f1f7d7b8a90/a1.png"
    private let path2 = "/private/var/folders/cd/x/T/page-images/6f1f2b2e-6a54-4b52-9d2c-3f1f7d7b8a90/b2.jpg"

    static func box(_ typed: String, plain: String? = nil) -> Box {
        let all = plain ?? typed
        return Box(typed: typed, plain: all, chips: Box.countChips(all))
    }

    /// The terminal, the sessions file, the folder and the transcript, scripted.
    private final class Fake {
        var clock = Date(timeIntervalSince1970: 1_761_300_000)
        /// The sessions file's status: per read, the last one repeats.
        var statuses = ["idle"]
        var foreground = true
        var attach: TerminalCatalog.AttachSupport = .paste
        var host = InjectionExecutor.TerminalHost.tmux(tmuxPath: "/usr/bin/false", paneId: "%3", inMode: false)
        var target: InjectionExecutor.ClaudeTarget?
        /// Box reads before the paste, after it, and after Enter: per read, the last one repeats.
        var before: [Box?] = [ImageDeliveryTests.box("")]
        var afterPaste: [Box?] = []
        var afterEnter: [Box?] = [ImageDeliveryTests.box("")]
        var paths: [String] = []
        var writeFails = false
        var written: [String] = []
        var removed: [String] = []
        var keys: [Keystroke] = []
        var keyRefusal: String?
        /// Receipt reads that come up empty before `found` is returned.
        var receiptMisses = 1
        var found: TranscriptImageReceipt.Found? = .init(images: 1)
        var receipts = 0
        var delivered: [InjectionExecutor.ClaudeReplyRequest] = []
        var deliverResult = InjectionResult(method: .tmux, success: true, output: "ok", detail: "Typed into tmux pane %3")
        var resolved = 0
        let session: ClaudeLiveSession

        init(sessionId: String) {
            session = ClaudeLiveSession(pid: 4242, sessionId: sessionId, cwd: "/tmp/p", status: .idle, statusUpdatedAt: nil,
                                        tty: "ttys003", hasSessionFile: true)
        }

        private func next<T>(_ list: inout [T]) -> T? {
            guard let first = list.first else { return nil }
            if list.count > 1 { list.removeFirst() }
            return first
        }

        func io() -> ImageDelivery.IO {
            ImageDelivery.IO(
                resolve: { _ in self.resolved += 1; return self.target ?? .live(self.session, []) },
                currentRecord: { pid in ClaudeSessionRecord(pid: pid, status: self.next(&self.statuses)) },
                resolveHost: { _, _ in self.host },
                isForeground: { _ in self.foreground },
                attach: { _ in self.attach },
                readBox: { _ in
                    switch self.keys.count {
                    case 0: return self.next(&self.before) ?? nil
                    case 1: return self.next(&self.afterPaste) ?? nil
                    default: return self.next(&self.afterEnter) ?? nil
                    }
                },
                check: { data in data.isEmpty ? .failure(.init(detail: ImageCheck.notImageMessage)) : .success(.png) },
                write: { _, _, _ in
                    if self.writeFails, !self.written.isEmpty { return .failure(.init(detail: ImageStore.saveFailedMessage)) }
                    let p = self.paths[self.written.count]
                    self.written.append(p)
                    return .success(p)
                },
                remove: { self.removed += $0 },
                transcriptSize: { _ in 100 },
                receipt: { _, offset in
                    XCTAssertEqual(offset, 100)
                    self.receipts += 1
                    return self.receipts > self.receiptMisses ? self.found : nil
                },
                sendKey: { _, key in
                    if let why = self.keyRefusal { return why }
                    self.keys.append(key)
                    return nil
                },
                deliverText: { req, _, _ in self.delivered.append(req); return self.deliverResult },
                sleep: { self.clock = self.clock.addingTimeInterval($0) },
                now: { self.clock })
        }
    }

    private func fake(paths: [String]? = nil) -> Fake {
        let f = Fake(sessionId: sid)
        f.paths = paths ?? [path1]
        return f
    }

    private func photos(_ n: Int = 1) -> [AssembledImage] {
        (0..<n).map { AssembledImage(id: "imageAAAA\($0)", data: Data([1, 2, 3]), mime: "image/png") }
    }

    private func run(_ f: Fake, photos n: Int = 1, caption: String = "what is this?", interventionId: String? = nil) -> SessionCommandResult {
        ImageDelivery.run(sessionId: sid, clientId: "c1", images: photos(n), caption: caption, interventionId: interventionId, io: f.io())
    }

    // MARK: the paste route

    func testThePhotoIsPastedAndEnterWaitsForItsChip() {
        let f = fake()
        f.afterPaste = [nil, Self.box(""), Self.box("[Image #4]what is this?")]
        let r = run(f)
        XCTAssertEqual(r.code, .delivered, r.detail)
        XCTAssertEqual(r.detail, "Sent the photo to Claude in tmux pane %3")
        XCTAssertEqual(r.attached, 1)
        XCTAssertEqual(f.keys, [.paste(path1 + "\nwhat is this?"), .enter], "one paste, then Enter as its own key")
        XCTAssertEqual(f.receipts, 2, "the transcript is read until the record shows")
        XCTAssertTrue(f.removed.isEmpty)
    }

    func testTwoPhotosAndAWrappedCaptionMatch() {
        let f = fake(paths: [path1, path2])
        f.found = .init(images: 2)
        f.afterPaste = [Self.box("[Image #1] [Image #2]Name the two colours, in order. Reply on one line,  comma separated.")]
        let r = run(f, photos: 2, caption: "Name the two colours, in order.\nReply on one line, comma separated.")
        XCTAssertEqual(r.code, .delivered, r.detail)
        XCTAssertEqual(r.detail, "Sent 2 photos to Claude in tmux pane %3")
        XCTAssertEqual(r.attached, 2)
        XCTAssertEqual(f.keys.first, .paste("\(path1)\n\(path2)\nName the two colours, in order.\nReply on one line, comma separated."))
    }

    func testALongCaptionShownAsPastedTextCounts() {
        let f = fake()
        f.afterPaste = [Self.box("[Image #6][Pasted text #7 +14 lines]")]
        let r = run(f, caption: String(repeating: "filler line\n", count: 15))
        XCTAssertEqual(r.code, .delivered, r.detail)
        XCTAssertEqual(f.keys.count, 2)
    }

    func testAPhotoWithoutCaptionIsJustTheChip() {
        let f = fake()
        f.afterPaste = [Self.box("[Image #5]")]
        let r = run(f, caption: "")
        XCTAssertEqual(r.code, .delivered, r.detail)
        XCTAssertEqual(f.keys, [.paste(path1), .enter], "never an empty line, never an empty paste")
    }

    func testPathsTakenAsTextAreSentAndSaidSo() {
        let f = fake()
        f.afterPaste = [Self.box(path1 + " what is this?")]
        let r = run(f)
        XCTAssertEqual(r.code, .delivered, r.detail)
        XCTAssertEqual(r.attached, 0)
        XCTAssertEqual(r.detail, "Sent, but Claude took the photo as a file location, not an image")
        XCTAssertEqual(f.keys.last, .enter)
        XCTAssertEqual(f.receipts, 0)
    }

    func testAnUnreadableScreenNeverGetsEnter() {
        let f = fake()
        f.afterPaste = [nil]
        f.receiptMisses = 99
        let r = run(f)
        XCTAssertEqual(r.code, .failed)
        XCTAssertEqual(r.detail, ImageDelivery.leftInBoxMessage)
        XCTAssertEqual(f.keys.count, 1, "the paste only: no Enter")
    }

    func testMoreChipsThanPhotosNeverGetsEnter() {
        let f = fake()
        f.afterPaste = [Self.box("[Image #1] [Image #2]what is this?")]
        f.receiptMisses = 99
        let r = run(f)
        XCTAssertEqual(r.code, .failed)
        XCTAssertEqual(f.keys.count, 1)
    }

    func testOtherTextBesideTheChipNeverGetsEnter() {
        let f = fake()
        f.afterPaste = [Self.box("[Image #1]what is this? and something typed at the Mac")]
        f.receiptMisses = 99
        let r = run(f)
        XCTAssertEqual(r.code, .failed)
        XCTAssertEqual(f.keys.count, 1)
    }

    func testAReturnThatGotThereFirstIsReportedAsSent() {
        let f = fake()
        f.afterPaste = [Self.box("")]
        f.receiptMisses = 0
        let r = run(f)
        XCTAssertEqual(r.code, .delivered, r.detail)
        XCTAssertEqual(r.attached, 1)
        XCTAssertEqual(f.keys.count, 1, "Page didn't press Enter itself")
    }

    func testAPromptThatOpensBeforeEnterStopsTheRun() {
        let f = fake()
        f.statuses = ["idle", "idle", "waiting"]
        f.afterPaste = [Self.box("[Image #1]what is this?")]
        let r = run(f)
        XCTAssertEqual(r.code, .failed)
        XCTAssertEqual(r.detail, ImageDelivery.leftInBoxMessage)
        XCTAssertEqual(f.keys.count, 1, "Enter on a menu would accept it")
    }

    func testASwallowedEnterIsReported() {
        let f = fake()
        f.afterPaste = [Self.box("[Image #1]what is this?")]
        f.afterEnter = [Self.box("[Image #1]what is this?")]
        let r = run(f)
        XCTAssertEqual(r.code, .failed)
        XCTAssertEqual(r.detail, ImageDelivery.leftInBoxMessage)
        XCTAssertEqual(f.keys.count, 2)
    }

    func testClaudeGoingBusyCountsAsTheBoxClearing() {
        let f = fake()
        f.statuses = ["idle", "idle", "idle", "busy"]
        f.afterPaste = [Self.box("[Image #1]what is this?")]
        f.afterEnter = [nil]
        XCTAssertEqual(run(f).code, .delivered)
    }

    func testAnUnloggedMessageIsSentButNotConfirmed() {
        let f = fake()
        f.afterPaste = [Self.box("[Image #1]what is this?")]
        f.found = nil
        let r = run(f)
        XCTAssertEqual(r.code, .delivered)
        XCTAssertNil(r.attached)
        XCTAssertEqual(r.detail, "Sent the photo to Claude in tmux pane %3 — it hasn't logged it yet")
    }

    func testFewerImagesInTheTranscriptAreSaidSo() {
        let f = fake(paths: [path1, path2])
        f.afterPaste = [Self.box("[Image #1] [Image #2]what is this?")]
        f.found = .init(images: 1)
        let r = run(f, photos: 2)
        XCTAssertEqual(r.code, .delivered)
        XCTAssertEqual(r.attached, 1)
        XCTAssertEqual(r.detail, "Sent, but Claude received 1 of 2 photos")
    }

    // MARK: refusals before anything is typed

    func testAHalfTypedMessageIsRefusedBeforeAnythingIsWritten() {
        let f = fake()
        f.before = [Self.box("fix the build")]
        let r = run(f)
        XCTAssertEqual(r.reason, .draft)
        XCTAssertTrue(f.written.isEmpty)
        XCTAssertTrue(f.keys.isEmpty)
    }

    func testAnInputBoxPageCantSeeIsRefused() {
        let f = fake()
        f.before = [nil]
        let r = run(f)
        XCTAssertEqual(r.reason, .draft)
        XCTAssertEqual(r.detail, InjectionExecutor.inputUnverifiedMessage)
        XCTAssertTrue(f.keys.isEmpty)
    }

    func testABusySessionIsRefusedUntilTheTurnEnds() {
        let f = fake()
        f.statuses = ["busy"]
        let r = run(f)
        XCTAssertEqual(r.code, .refused)
        XCTAssertEqual(r.reason, .attachBusy)
        XCTAssertEqual(r.detail, ImageDelivery.busyMessage)
        XCTAssertTrue(f.written.isEmpty)
    }

    func testAWaitingSessionNamesItsPage() {
        let f = fake()
        f.statuses = ["waiting"]
        let r = run(f, interventionId: "page-1")
        XCTAssertEqual(r.reason, .waiting)
        XCTAssertEqual(r.interventionId, "page-1")
    }

    func testABusyTurnBetweenWriteAndPasteRemovesThePhoto() {
        let f = fake()
        f.statuses = ["idle", "busy"]
        let r = run(f)
        XCTAssertEqual(r.reason, .attachBusy)
        XCTAssertEqual(f.removed, [path1])
        XCTAssertTrue(f.keys.isEmpty)
    }

    func testAHostWithoutPhotosIsRefused() {
        let f = fake()
        f.attach = .notYet("Page can't type into Ghostty yet")
        let r = run(f)
        XCTAssertEqual(r.reason, .attachUnsupported)
        XCTAssertEqual(r.detail, "Page can't type into Ghostty yet")
    }

    func testEndedBackgroundedAndUnknownSessionsAreRefused() {
        let f = fake()
        f.target = .ended
        XCTAssertEqual(run(f).reason, .ended)
        let g = fake()
        g.foreground = false
        XCTAssertEqual(run(g).reason, .notTypable)
        let h = fake()
        h.statuses = ["nonsense"]
        XCTAssertEqual(run(h).reason, .unknownState)
        let u = fake()
        u.host = .unsupported("Ghostty")
        XCTAssertEqual(run(u).detail, "Page can't type into Ghostty yet")
    }

    func testABadPhotoIsRefusedBeforeTheSessionIsLookedUp() {
        let f = fake()
        let r = ImageDelivery.run(sessionId: sid, clientId: "c1", images: [AssembledImage(id: "imageAAAA0", data: Data(), mime: "image/png")],
                                  caption: "", interventionId: nil, io: f.io())
        XCTAssertEqual(r.reason, .attachmentInvalid)
        XCTAssertEqual(f.resolved, 0)
    }

    func testACaptionLineThatIsAnImagePathIsRefused() {
        let f = fake()
        let r = run(f, caption: "look\n/Users/me/a.png")
        XCTAssertEqual(r.code, .refused)
        XCTAssertEqual(r.detail, ImageDelivery.pathLineMessage)
        XCTAssertEqual(f.resolved, 0)
    }

    func testAFailedWriteRemovesTheOnesAlreadyWritten() {
        let f = fake(paths: [path1, path2])
        f.writeFails = true
        let r = run(f, photos: 2)
        XCTAssertEqual(r.code, .failed)
        XCTAssertEqual(r.detail, ImageStore.saveFailedMessage)
        XCTAssertEqual(f.removed, [path1])
    }

    func testAnUnsafePathIsNeverTyped() {
        let f = fake(paths: ["/tmp/a b.png"])
        let r = run(f)
        XCTAssertEqual(r.code, .failed)
        XCTAssertEqual(f.removed, ["/tmp/a b.png"])
        XCTAssertTrue(f.keys.isEmpty)
    }

    func testControlCharactersInTheCaptionAreStripped() {
        let f = fake()
        f.afterPaste = [Self.box("[Image #1]hi there")]
        _ = run(f, caption: "hi\u{1B}[201~ there")
        XCTAssertEqual(f.keys.first, .paste(path1 + "\nhi[201~ there"), "an ESC can't end the bracketed paste early")
    }

    // MARK: the path route

    func testPathOnlyHostsGetTheLocationAsAMessage() {
        let f = fake(paths: [path1, path2])
        f.attach = .pathOnly(TerminalCatalog.pathOnlyReason)
        let r = run(f, photos: 2)
        XCTAssertEqual(r.code, .delivered, r.detail)
        XCTAssertEqual(r.attached, 0)
        XCTAssertEqual(r.detail, "Sent as a file location — Claude opens 2 photos itself (not attached)")
        XCTAssertTrue(f.keys.isEmpty, "the ordinary input delivery types it")
        XCTAssertEqual(f.delivered.first?.text, "what is this?\nPhoto from my phone: \(path1)\nPhoto from my phone: \(path2)")
        XCTAssertEqual(f.delivered.first?.requireEmptyInput, true)
        XCTAssertEqual(f.delivered.first?.refuseWhileBusy, true)
    }

    func testARefusedPathMessageRemovesThePhotos() {
        let f = fake()
        f.attach = .pathOnly(TerminalCatalog.pathOnlyReason)
        f.deliverResult = InjectionResult(method: .none, success: false, output: "refused", detail: CmuxBridge.draftDetail)
        let r = run(f)
        XCTAssertEqual(r.reason, .draft)
        XCTAssertEqual(f.removed, [path1])
        f.removed = []
        f.written = []
        f.deliverResult = InjectionResult(method: .none, success: false, output: "refused", detail: InjectionExecutor.busyAgainMessage)
        XCTAssertEqual(run(f).reason, .attachBusy)
    }

    func testAPathMessageOverTheLimitIsRefused() {
        let f = fake()
        f.attach = .pathOnly(TerminalCatalog.pathOnlyReason)
        let r = run(f, caption: String(repeating: "x", count: 7990))
        XCTAssertEqual(r.detail, ImageDelivery.tooLongMessage)
        XCTAssertEqual(f.removed, [path1])
    }

    // MARK: pure parts

    func testNoPathLineEverStandsAlone() {
        let text = ImageDelivery.pathText(paths: [path1, path2], caption: "")
        for line in text.components(separatedBy: "\n") {
            XCTAssertTrue(line.hasPrefix(ImageDelivery.pathLinePrefix), line)
            XCTAssertNil(ImageDelivery.captionRefusal(line), "Claude Code would not attach: \(line)")
        }
        XCTAssertEqual(ImageDelivery.pastePayload(paths: [path1], caption: ""), path1)
    }

    func testCaptionLinesThatWouldAttachAreFound() {
        XCTAssertNil(ImageDelivery.captionRefusal("what is in /tmp/a.png?"))
        XCTAssertNil(ImageDelivery.captionRefusal("/tmp/notes.txt"))
        XCTAssertNil(ImageDelivery.captionRefusal("describe this /tmp/a.png"))
        XCTAssertNil(ImageDelivery.captionRefusal(""))
        XCTAssertNotNil(ImageDelivery.captionRefusal("/tmp/a.png"))
        XCTAssertNotNil(ImageDelivery.captionRefusal("  '/tmp/my photo.JPG'  "))
        XCTAssertNotNil(ImageDelivery.captionRefusal("hello\n/tmp/a.webp /tmp/b.txt"))
        XCTAssertNotNil(ImageDelivery.captionRefusal("~/Desktop/shot.png"))
    }

    func testTheBoxVerdict() {
        let paths = [path1]
        XCTAssertEqual(ImageDelivery.verdict(Self.box("[Image #9]hi"), expected: 1, paths: paths, caption: "hi"), .ready)
        XCTAssertEqual(ImageDelivery.verdict(Self.box("[Image #9] h i"), expected: 1, paths: paths, caption: "hi"), .ready)
        XCTAssertEqual(ImageDelivery.verdict(Self.box("[Image #9]"), expected: 1, paths: paths, caption: "hi"), .notYet)
        XCTAssertEqual(ImageDelivery.verdict(Self.box("[Image #9]hello"), expected: 1, paths: paths, caption: "hi"), .notYet)
        XCTAssertEqual(ImageDelivery.verdict(Self.box("[Image #1][Image #2]hi"), expected: 1, paths: paths, caption: "hi"), .wrong)
        XCTAssertEqual(ImageDelivery.verdict(Self.box(path1 + " hi"), expected: 1, paths: paths, caption: "hi"), .pastedAsText)
        XCTAssertEqual(ImageDelivery.verdict(nil, expected: 1, paths: paths, caption: "hi"), .notYet)
        XCTAssertEqual(ImageDelivery.verdict(Self.box("[Image #1][Pasted text #2]"), expected: 1, paths: paths, caption: ""), .notYet,
                       "a pasted-text placeholder with no caption sent is someone else's")
        XCTAssertEqual(ImageDelivery.verdict(Self.box("[Image #4]see [Image #2] again"), expected: 1, paths: paths,
                                             caption: "see [Image #2] again"), .ready, "a caption that spells a chip")
    }

    func testListRowsOfferPhotosByTerminal() {
        func host(_ h: String, canType: Bool = true) -> SessionHostInfo {
            SessionHostInfo(host: h, canType: canType, typeBlocker: canType ? nil : "no", canInterrupt: true)
        }
        XCTAssertEqual(ImageDelivery.rowFields(backend: .claude, host: host("tmux")).attach, "image")
        XCTAssertEqual(ImageDelivery.rowFields(backend: .claude, host: host(ClaudeSquad.hostName)).attach, "image")
        for h in ["Terminal", "iTerm", "cmux", "WezTerm", "kitty", "Herdr"] {
            XCTAssertEqual(ImageDelivery.rowFields(backend: .claude, host: host(h)).attach, "path", h)
        }
        let blocked = ImageDelivery.rowFields(backend: .claude, host: host("tmux", canType: false))
        XCTAssertNil(blocked.attach)
        XCTAssertNil(blocked.blocker, "no composer, so nothing to explain")
        let codex = ImageDelivery.rowFields(backend: .codex, host: host("tmux"))
        XCTAssertNil(codex.attach)
        XCTAssertEqual(codex.blocker, ImageDelivery.codexMessage)
        XCTAssertNil(ImageDelivery.rowFields(backend: .claude, host: host("Ghostty")).attach)
    }

    func testTheGateReadsTheSameCatalogAsTheList() {
        XCTAssertEqual(ImageDelivery.attachSupport(of: .tmux(tmuxPath: "t", paneId: "%1", inMode: false)), .paste)
        XCTAssertEqual(ImageDelivery.attachSupport(of: .tmux(tmuxPath: "t", paneId: "%1", inMode: false, session: "claudesquad_x")),
                       TerminalCatalog.entry(.claudeSquad).capabilities.attach)
        XCTAssertEqual(ImageDelivery.attachSupport(of: .terminalApp(tty: "/dev/ttys001")), .pathOnly(TerminalCatalog.pathOnlyReason))
        XCTAssertEqual(ImageDelivery.attachSupport(of: .unsupported("Warp")), .notYet("Page can't type into Warp yet"))
        XCTAssertEqual(ImageDelivery.attachSupport(of: .unknown), .notYet("Couldn't find the session's terminal"))
    }

    // MARK: reading the input box (rows captured from Claude Code 2.1.312 in tmux)

    private let rule = String(repeating: "─", count: 140)

    func testChipsAndCaptionAreReadFromTheBox() throws {
        let screen = "\u{1B}[38;5;244m\(rule)\n\u{1B}[39m❯ [Image #1]What colour is this square? Answer in one word.\n"
            + "\u{1B}[38;5;244m\(rule)\n\u{1B}[39m  \u{1B}[38;5;220m⏵⏵ auto mode on\u{1B}[38;5;246m (shift+tab to cycle)\u{1B}[39m\n\n\n"
        let box = try XCTUnwrap(InjectionExecutor.claudeInputContent(screen: screen, styled: true))
        XCTAssertEqual(box.chips, 1)
        XCTAssertEqual(box.textWithoutChips, "Whatcolouristhissquare?Answerinoneword.")
        XCTAssertFalse(box.isEmpty)
        XCTAssertEqual(InjectionExecutor.claudeInputRow(screen: screen, styled: true), .draft)
    }

    func testThePlaceholderIsAnEmptyBox() throws {
        let screen = "\(rule)\n❯ \u{1B}[38;5;246mTry \"write a test for <filepath>\"\u{1B}[39m\n\(rule)\n  ⏵⏵ auto mode on\n"
        let box = try XCTUnwrap(InjectionExecutor.claudeInputContent(screen: screen, styled: true))
        XCTAssertTrue(box.isEmpty)
        XCTAssertEqual(box.plain, "Try \"write a test for <filepath>\"")
    }

    func testAPathWrappedOverRowsComparesWhole() throws {
        let screen = "\(rule)\n❯ /private/var/folders/cd/x/T/page-images/6f1f2b2e-6a54-4b52-9d2c-3f1f7d7b8a90/a\n  1.png\n  what is this?\n\(rule)\n"
        let box = try XCTUnwrap(InjectionExecutor.claudeInputContent(screen: screen, styled: true))
        XCTAssertEqual(box.chips, 0)
        XCTAssertEqual(box.textWithoutChips, ImageDelivery.squeezed(path1 + "\nwhat is this?"))
    }

    func testABoxNearTheTopOfATallPaneIsFound() throws {
        let screen = " ▐▛███▛█   Claude Code\n\n\(rule)\n❯ \n\(rule)\n  ⏵⏵ auto mode on\n" + String(repeating: "\n", count: 60)
        XCTAssertEqual(InjectionExecutor.claudeInputRow(screen: screen, styled: false), .empty, "the padding rows don't push it out")
        XCTAssertNotNil(InjectionExecutor.claudeInputContent(screen: screen, styled: false))
        XCTAssertNil(InjectionExecutor.claudeInputContent(screen: "no box here\n", styled: false))
    }

    // MARK: the transcript, read forward

    private func record(_ fields: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: fields), encoding: .utf8)!
    }

    func testTheImageRecordIsFoundPastAHugeLine() throws {
        let base64 = String(repeating: "A", count: 1_500_000)
        let text = record(["type": "user", "message": ["role": "user", "content": "plain text"], "uuid": "u1"]) + "\n"
            + record(["type": "user", "isSidechain": true, "imagePasteIds": [1],
                      "message": ["content": [["type": "image", "source": ["data": "x"]]]]]) + "\n"
            + record(["type": "user", "imagePasteIds": [2, 3], "message": ["role": "user", "content": [
                ["type": "text", "text": "[Image #2] [Image #3]hi"],
                ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": base64]],
                ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": "QQ=="]]]]]) + "\n"
        XCTAssertEqual(TranscriptImageReceipt.scan(Data(text.utf8)), .init(images: 2))
        XCTAssertNil(TranscriptImageReceipt.scan(Data(text.utf8).dropLast()), "a line still being written doesn't count")
        XCTAssertNil(TranscriptImageReceipt.scan(Data((record(["type": "user", "message": ["content": "hi"]]) + "\n").utf8)))

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("page-receipt-\(UUID().uuidString.prefix(8)).jsonl")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let older = record(["type": "user", "imagePasteIds": [1], "message": ["content": [["type": "image"]]]]) + "\n"
        try (older + text).write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(TranscriptImageReceipt.read(path: file.path, from: UInt64(older.utf8.count)), .init(images: 2),
                       "only records after the offset")
        XCTAssertEqual(TranscriptImageReceipt.read(path: file.path, from: 0), .init(images: 1))
        XCTAssertNil(TranscriptImageReceipt.read(path: file.path, from: UInt64((older + text).utf8.count)))
        XCTAssertEqual(TranscriptImageReceipt.size(path: file.path), UInt64((older + text).utf8.count))
        XCTAssertNil(TranscriptImageReceipt.read(path: "/dev/zero", from: 0))
    }

    // MARK: each terminal's paste route

    func testEveryBridgePastesInBrackets() throws {
        let wez = try XCTUnwrap(WezTermBridge.sendArgs(paneId: "3", key: .paste("/a.png")))
        XCTAssertEqual(wez.args, ["send-text", "--pane-id", "3"], "no --no-paste: send-text pastes by default")
        XCTAssertEqual(wez.stdin, Data("/a.png".utf8))
        XCTAssertNil(WezTermBridge.sendArgs(paneId: "3", key: .paste("")))

        let kitty = KittyBridge.Target(kittenPath: "/k", socket: "unix:/tmp/k", windowId: "7")
        let k = try XCTUnwrap(KittyBridge.sendArgs(target: kitty, key: .paste("/a.png")))
        XCTAssertEqual(k.args, ["@", "--to", "unix:/tmp/k", "send-text", "--match", "id:7", "--bracketed-paste", "enable", "--stdin"])
        XCTAssertNil(KittyBridge.sendArgs(target: kitty, key: .paste("")))

        let herdr = try XCTUnwrap(HerdrBridge.sendRequest(id: "x", paneId: "p1", key: .paste("/a.png")))
        XCTAssertTrue(herdr.contains("\"pane.send_input\""), herdr)
        XCTAssertNil(HerdrBridge.sendRequest(id: "x", paneId: "p1", key: .paste("")))

        XCTAssertEqual(InjectionExecutor.tmuxPasteArgs(buffer: "b", paneId: "%1", keepNewlines: true),
                       ["paste-buffer", "-p", "-r", "-d", "-b", "b", "-t", "%1"])
        XCTAssertEqual(InjectionExecutor.tmuxPasteArgs(buffer: "b", paneId: "%1", keepNewlines: false),
                       ["paste-buffer", "-p", "-d", "-b", "b", "-t", "%1"])
    }

    func testHostsWithoutAMeasuredPasteRefuseIt() {
        let term = InjectionExecutor.sendViaTerminalApp([.paste("/a.png")], tty: "/dev/ttys999", awaitClosed: { true })
        XCTAssertFalse(term.success)
        XCTAssertEqual(term.detail, InjectionExecutor.pasteUnsupportedMessage("Terminal"))
        let iterm = InjectionExecutor.sendViaITerm([.paste("/a.png")], tty: "/dev/ttys999", awaitClosed: { true })
        XCTAssertFalse(iterm.success)
        XCTAssertEqual(iterm.detail, InjectionExecutor.pasteUnsupportedMessage("iTerm2"))
        XCTAssertEqual(InjectionExecutor.sendImageKey(.paste("/a.png"), to: .terminalApp(tty: "/dev/ttys999")),
                       InjectionExecutor.pasteUnsupportedMessage("Terminal"))
        var sent = 0
        let empty = InjectionExecutor.sendViaControlCLI([.paste("")], method: .wezterm, label: "WezTerm pane 1", awaitClosed: { true }) { _ in
            sent += 1
            return ProcessRunner.Result(status: 0, stdout: "", stderr: "", timedOut: false, launched: true)
        }
        XCTAssertFalse(empty.success)
        XCTAssertEqual(sent, 0, "an empty paste would make Claude Code read the clipboard")
    }
}
