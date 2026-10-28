import Foundation

/// Sends photos from the phone into a Claude session (`images-v1`,
/// SESSIONS-PROTOCOL.md "Images"), once SessionRemote has put them back
/// together (`ImageAssembler`). Modelled on `AnswerDelivery`: one step at a
/// time, every I/O behind `IO` so the whole sequence is tested with fakes,
/// run on the Claude backend's injection queue so it never interleaves with
/// a reply, a held message or a battery pause.
///
/// Paste route (a terminal TerminalCatalog marks `.paste`):
///  1. the gate: the session live and idle (busy is refused `attach_busy`:
///     whether Claude keeps a queued message's photos is unmeasured), in
///     front of its terminal, not a paused Claude Squad instance;
///  2. the input box read empty;
///  3. the photos checked (`ImageCheck`) and written (`ImageStore`), and the
///     transcript's size noted;
///  4. one bracketed paste: the paths, one per line, then the caption.
///     Claude Code puts the chips first, so the caption is never the start of
///     the box (a leading "/" or "!" can't start a command);
///  5. the screen polled until the box holds exactly one `[Image #n]` chip
///     per photo plus the caption, and nothing else;
///  6. Enter, as its own key and only then: Claude Code drops a Return that
///     arrives while a photo is still loading (measured);
///  7. the box seen to empty (or Claude busy), then the transcript read
///     forward for the user record with `imagePasteIds`, which says how many
///     images Claude really received.
/// Anything Page can't confirm before Enter stops the run and leaves the
/// photo and caption in the box (`failed`: "…in Claude's input box at your
/// Mac, not sent"). The caption is never typed without the photo.
///
/// Path route (every other terminal): the caption, then one "Photo from my
/// phone: <path>" line per photo, through the ordinary input delivery; Claude
/// opens the file itself. Each path line starts with words, because Claude
/// Code attaches a pasted line that is only a path, and the Return typed
/// right after it would then be dropped while the photo loads.
enum ImageDelivery {
    static let pollInterval: TimeInterval = 0.1
    /// How long the chips may take to show after the paste.
    static let chipWait: TimeInterval = 5
    /// How long the box may take to empty after Enter.
    static let clearWait: TimeInterval = 2
    /// How long Claude may take to log the message.
    static let confirmWait: TimeInterval = 4

    static let busyMessage = "Claude is working — send the photo when it finishes"
    static let leftInBoxMessage = "Your photo and message are in Claude's input box at your Mac, not sent"
    static let codexMessage = "Page can't send photos to Codex yet"
    static let pathLinePrefix = "Photo from my phone: "
    static let pathLineMessage = "A line of your message is a photo's file path, which Claude would try to open as a photo — add a word before it"
    static let tooLongMessage = "The message is too long with the photos (8000 characters at most)"

    struct IO {
        var resolve: (String) -> InjectionExecutor.ClaudeTarget
        var currentRecord: (Int32) -> ClaudeSessionRecord?
        var resolveHost: (ClaudeLiveSession, [ProcessRunner.ProcessInfoRow]) -> InjectionExecutor.TerminalHost
        var squadPaused: (ClaudeLiveSession, InjectionExecutor.TerminalHost) -> Bool = { _, _ in false }
        var isForeground: (Int32) -> Bool?
        /// TerminalCatalog's word on the host. Only the DEBUG `--probe-image`
        /// tool swaps it, to measure a host that isn't marked yet.
        var attach: (InjectionExecutor.TerminalHost) -> TerminalCatalog.AttachSupport = ImageDelivery.attachSupport(of:)
        /// The session's input box (with colours where the host gives them);
        /// nil when it isn't on screen or the screen can't be read.
        var readBox: (InjectionExecutor.TerminalHost) -> InjectionExecutor.ClaudeInputContent?
        var check: (Data) -> Result<ImageCheck.Kind, ImageCheck.Failure> = ImageCheck.check
        /// Writes one photo for the session; the canonical path.
        var write: (Data, ImageCheck.Kind, String) -> Result<String, ImageCheck.Failure>
        var remove: ([String]) -> Void
        /// The session transcript's size now (where the forward read starts).
        var transcriptSize: (ClaudeLiveSession) -> UInt64?
        /// The first user record with pasted images after that offset.
        var receipt: (ClaudeLiveSession, UInt64) -> TranscriptImageReceipt.Found?
        /// One key. nil: sent; otherwise the phone-safe reason it wasn't.
        var sendKey: (InjectionExecutor.TerminalHost, Keystroke) -> String?
        /// The path route: the ordinary input delivery (input box required empty).
        var deliverText: (InjectionExecutor.ClaudeReplyRequest, ClaudeLiveSession, [ProcessRunner.ProcessInfoRow]) -> InjectionResult
        var sleep: (TimeInterval) -> Void = { usleep(useconds_t($0 * 1_000_000)) }
        var now: () -> Date = Date.init
    }

    // MARK: pure parts

    /// Pure. TerminalCatalog's `attach` for the host a session runs in.
    static func attachSupport(of host: InjectionExecutor.TerminalHost) -> TerminalCatalog.AttachSupport {
        let id: TerminalCatalog.ID
        switch host {
        case .tmux(_, _, _, let session): id = session.map(ClaudeSquad.isSquadSession) == true ? .claudeSquad : .tmux
        case .terminalApp: id = .terminal
        case .iTerm: id = .iTerm
        case .cmux: id = .cmux
        case .wezterm: id = .wezterm
        case .kitty: id = .kitty
        case .herdr: id = .herdr
        case .unreachable(let why): return .notYet(why)
        case .unsupported(let app): return .notYet("Page can't type into \(app) yet")
        case .unknown: return .notYet("Couldn't find the session's terminal")
        }
        return TerminalCatalog.entry(id).capabilities.attach
    }

    /// Pure. A list row's `attach` and `attachBlocker` (SESSIONS-PROTOCOL.md
    /// §4): only for a row Page can type into; Claude by its terminal's
    /// catalog entry, Codex not yet.
    static func rowFields(backend: AgentBackendID, host: SessionHostInfo) -> (attach: String?, blocker: String?) {
        guard host.canType else { return (nil, nil) }
        guard backend == .claude else { return (nil, codexMessage) }
        guard let id = TerminalCatalog.id(forWireHost: host.host) else { return (nil, nil) }
        let support = TerminalCatalog.entry(id).capabilities.attach
        if case .notYet(let why) = support { return (nil, why) }
        return (support.wire, nil)
    }

    /// Pure. Why the caption can't go in: one of its lines is (only) an
    /// absolute image path, which Claude Code's paste detector would try to
    /// attach. Every line is split the way Claude Code splits it (on a space
    /// before "/" or a drive letter, optionally quoted).
    static func captionRefusal(_ caption: String) -> String? {
        let splitter = try? NSRegularExpression(pattern: #" (?=["']?(?:/|[A-Za-z]:\\))"#)
        let imageExt = try? NSRegularExpression(pattern: #"\.(png|jpe?g|gif|webp)$"#, options: [.caseInsensitive])
        for raw in caption.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, let splitter, let imageExt else { continue }
            let ns = line as NSString
            var pieces: [String] = []
            var start = 0
            for m in splitter.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                pieces.append(ns.substring(with: NSRange(location: start, length: m.range.location - start)))
                start = m.range.location + m.range.length
            }
            pieces.append(ns.substring(from: start))
            func unquoted(_ p: String) -> String {
                var t = p.trimmingCharacters(in: .whitespaces)
                if t.count >= 2, let f = t.first, f == t.last, f == "'" || f == "\"" { t = String(t.dropFirst().dropLast()) }
                return t.replacingOccurrences(of: "\\ ", with: " ")
            }
            let paths = pieces.map(unquoted)
            let allPaths = paths.allSatisfy { p in
                p.hasPrefix("/") || p.hasPrefix("~/") || p.range(of: #"^[A-Za-z]:\\"#, options: .regularExpression) != nil
            }
            let anyImage = paths.contains { imageExt.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
            if allPaths && anyImage { return pathLineMessage }
        }
        return nil
    }

    /// Pure. The one paste: the paths, one per line, then the caption.
    static func pastePayload(paths: [String], caption: String) -> String {
        (paths + (caption.isEmpty ? [] : [caption])).joined(separator: "\n")
    }

    /// Pure. The path route's message: the caption, then one line per photo
    /// that starts with words, so no line is only a path.
    static func pathText(paths: [String], caption: String) -> String {
        ((caption.isEmpty ? [] : [caption]) + paths.map { pathLinePrefix + $0 }).joined(separator: "\n")
    }

    /// Pure. Whitespace removed, to compare text that wrapped across rows.
    static func squeezed(_ s: String) -> String {
        String(s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
    }

    /// Claude Code shows a long paste as one placeholder instead of its text.
    static let pastedTextPattern = #"^\[Pastedtext#[0-9]+(\+[0-9]+lines)?\]$"#

    enum BoxVerdict: Equatable {
        /// Exactly the photos' chips and the caption: press Enter.
        case ready
        /// No chip, and the box holds exactly what was pasted, as text: Claude
        /// took the paths as text (a Read deny rule, an unreadable file, a
        /// Claude Code change). Enter sends it as a plain message.
        case pastedAsText
        /// Not there yet, or not what was pasted (polled again until the
        /// deadline; still this at the deadline means no Enter).
        case notYet
        /// More chips than photos: something else is in the box. No Enter.
        case wrong
    }

    /// Pure. Reads the box after the paste. `.pastedAsText` doesn't end the
    /// polling (the text may show before Claude turns it into chips); only
    /// the last reading at the deadline counts.
    static func verdict(_ box: InjectionExecutor.ClaudeInputContent?, expected: Int, paths: [String], caption: String) -> BoxVerdict {
        guard let box else { return .notYet }
        // A caption that itself spells "[Image #2]" shows that text too.
        let chipPattern = InjectionExecutor.ClaudeInputContent.chipPattern
        let chips = expected + InjectionExecutor.ClaudeInputContent.countChips(caption)
        if box.chips > chips { return .wrong }
        let text = box.textWithoutChips
        let want = squeezed(caption.replacingOccurrences(of: chipPattern, with: "", options: .regularExpression))
        let captionShown = text == want || (!want.isEmpty && text.range(of: pastedTextPattern, options: .regularExpression) != nil)
        if box.chips == chips { return captionShown ? .ready : .notYet }
        if box.chips == 0, text == squeezed(pastePayload(paths: paths, caption: caption)) { return .pastedAsText }
        return .notYet
    }

    static func photos(_ n: Int) -> String { n == 1 ? "the photo" : "\(n) photos" }

    // MARK: the run

    /// Fresh lookup → gate → write → paste → chips → Enter → confirm. Blocking.
    static func run(sessionId: String, clientId: String, images: [AssembledImage], caption raw: String,
                    interventionId: String?, io: IO) -> SessionCommandResult {
        guard (1...ImageRef.maxImages).contains(images.count) else {
            return .refused(.attachmentInvalid, "Send 1 to 4 photos at a time")
        }
        let caption = InjectionExecutor.sanitize(raw)
        if let why = captionRefusal(caption) { return .refused(.error, why) }
        var kinds: [ImageCheck.Kind] = []
        for image in images {
            switch io.check(image.data) {
            case .failure(let f): return .refused(.attachmentInvalid, f.detail)
            case .success(let k): kinds.append(k)
            }
        }

        let session: ClaudeLiveSession
        let table: [ProcessRunner.ProcessInfoRow]
        switch io.resolve(sessionId) {
        case .ended: return .refused(.ended, SessionInputGate.endedMessage)
        case .failed(let f): return .refused(.notTypable, f.detail)
        case .live(let s, let t): session = s; table = t
        }
        guard session.tty != nil else { return .refused(.notTypable, "This session isn't running in a terminal Page can type into") }

        /// The session as it is now: nil when photos may go in.
        func gate() -> SessionCommandResult? {
            guard session.hasSessionFile, let rec = io.currentRecord(session.pid) else {
                return .refused(.unknownState, SessionInputGate.unknownStateMessage)
            }
            switch ClaudeSessionStatus(raw: rec.status) {
            case .idle, .shell: return nil
            case .waiting: return .refused(.waiting, SessionInputGate.waitingMessage, interventionId: interventionId)
            case .busy: return .refused(.attachBusy, busyMessage)
            case .unknown: return .refused(.unknownState, SessionInputGate.unknownStateMessage)
            }
        }
        if let refusal = gate() { return refusal }

        let host = io.resolveHost(session, table)
        switch host {
        case .tmux, .terminalApp, .iTerm, .cmux, .wezterm, .kitty, .herdr: break
        case .unsupported(let app): return .refused(.notTypable, "Page can't type into \(app) yet")
        case .unreachable(let why): return .refused(.notTypable, why)
        case .unknown: return .refused(.notTypable, "Couldn't find the session's terminal")
        }
        if io.squadPaused(session, host) { return .refused(.notTypable, ClaudeSquad.pausedMessage) }
        let support = io.attach(host)
        if case .notYet(let why) = support { return .refused(.attachUnsupported, why) }
        guard io.isForeground(session.pid) == true else { return .refused(.notTypable, InjectionExecutor.notForegroundMessage) }

        if case .pathOnly = support {
            return pathRoute(sessionId: sessionId, clientId: clientId, images: images, kinds: kinds, caption: caption,
                             session: session, table: table, host: host, interventionId: interventionId, io: io)
        }

        // 2. The box must read empty before anything is written or pasted.
        guard let before = io.readBox(host) else { return .refused(.draft, InjectionExecutor.inputUnverifiedMessage) }
        guard before.isEmpty else { return .refused(.draft, CmuxBridge.draftDetail) }

        // 3. Write the photos; note where the transcript ends.
        var paths: [String] = []
        for (image, kind) in zip(images, kinds) {
            switch io.write(image.data, kind, session.sessionId) {
            case .failure(let f):
                io.remove(paths)
                return .failed(f.detail)
            case .success(let p):
                guard ImageStore.isSafePath(p) else {
                    io.remove(paths + [p])
                    return .failed(ImageStore.saveFailedMessage)
                }
                paths.append(p)
            }
        }
        let offset = io.transcriptSize(session)
        Logger.shared.log("Images session=\(session.sessionId.prefix(8)) host=\(host.label) photos=\(paths.count) caption=\(caption.count) chars")

        /// Right before a key: in front of its terminal, and still idle.
        func precheck() -> SessionCommandResult? {
            guard io.isForeground(session.pid) == true else { return .refused(.notTypable, InjectionExecutor.notForegroundMessage) }
            return gate()
        }

        // 4. One paste.
        if let refusal = precheck() {
            io.remove(paths)
            return refusal
        }
        if let why = io.sendKey(host, .paste(pastePayload(paths: paths, caption: caption))) {
            return .failed(why)
        }

        // 5. Wait for the chips.
        let deadline = io.now().addingTimeInterval(chipWait)
        var verdict = BoxVerdict.notYet
        repeat {
            io.sleep(pollInterval)
            verdict = Self.verdict(io.readBox(host), expected: paths.count, paths: paths, caption: caption)
            if verdict == .ready || verdict == .wrong { break }
        } while io.now() < deadline
        guard verdict == .ready || verdict == .pastedAsText else {
            // A Return that got there first (someone at the Mac) sends the message with its photos and
            // empties the box: the transcript says so. Otherwise the photo is still in the box.
            if let offset, let found = io.receipt(session, offset) {
                return SessionCommandResult(code: .delivered, reason: nil,
                                            detail: "Sent \(photos(paths.count)) to Claude in \(host.label)", attached: found.images)
            }
            Logger.shared.log("Images session=\(session.sessionId.prefix(8)) no Enter: the box didn't show the photos (\(verdict))")
            return .failed(leftInBoxMessage)
        }

        // 6. Enter, only now.
        if precheck() != nil { return .failed(leftInBoxMessage) }
        if io.sendKey(host, .enter) != nil { return .failed(leftInBoxMessage) }

        // 7. The box empties (or Claude starts), then the transcript says what Claude got.
        let clearBy = io.now().addingTimeInterval(clearWait)
        var cleared = false
        repeat {
            io.sleep(pollInterval)
            if let rec = io.currentRecord(session.pid), ClaudeSessionStatus(raw: rec.status) == .busy { cleared = true; break }
            if let box = io.readBox(host), box.isEmpty { cleared = true; break }
        } while io.now() < clearBy
        guard cleared else { return .failed(leftInBoxMessage) }

        let n = paths.count
        if verdict == .pastedAsText {
            return SessionCommandResult(code: .delivered, reason: nil,
                                        detail: "Sent, but Claude took \(photos(n)) as a file location, not an image", attached: 0)
        }
        var found: TranscriptImageReceipt.Found?
        if let offset {
            let confirmBy = io.now().addingTimeInterval(confirmWait)
            repeat {
                found = io.receipt(session, offset)
                if found != nil { break }
                io.sleep(0.3)
            } while io.now() < confirmBy
        }
        guard let found else {
            return SessionCommandResult(code: .delivered, reason: nil,
                                        detail: "Sent \(photos(n)) to Claude in \(host.label) — it hasn't logged it yet")
        }
        if found.images >= n {
            return SessionCommandResult(code: .delivered, reason: nil, detail: "Sent \(photos(n)) to Claude in \(host.label)",
                                        attached: found.images)
        }
        return SessionCommandResult(code: .delivered, reason: nil,
                                    detail: "Sent, but Claude received \(found.images) of \(n) photos", attached: found.images)
    }

    /// The caption and the photos' locations as one ordinary message.
    private static func pathRoute(sessionId: String, clientId: String, images: [AssembledImage], kinds: [ImageCheck.Kind],
                                  caption: String, session: ClaudeLiveSession, table: [ProcessRunner.ProcessInfoRow],
                                  host: InjectionExecutor.TerminalHost, interventionId: String?, io: IO) -> SessionCommandResult {
        var paths: [String] = []
        for (image, kind) in zip(images, kinds) {
            switch io.write(image.data, kind, session.sessionId) {
            case .failure(let f):
                io.remove(paths)
                return .failed(f.detail)
            case .success(let p):
                guard ImageStore.isSafePath(p) else {
                    io.remove(paths + [p])
                    return .failed(ImageStore.saveFailedMessage)
                }
                paths.append(p)
            }
        }
        let text = pathText(paths: paths, caption: caption)
        guard text.count <= SessionInputGate.maxTextLength else {
            io.remove(paths)
            return .refused(.error, tooLongMessage)
        }
        Logger.shared.log("Images session=\(session.sessionId.prefix(8)) host=\(host.label) photos=\(paths.count) as file locations")
        var req = SessionInputGate.claudeRequest(sessionId: sessionId, clientId: clientId, text: text)
        req.refuseWhileBusy = true
        let r = SessionInputGate.claudeResult(io.deliverText(req, session, table), queued: false, interventionId: interventionId)
        switch r.code {
        case .delivered:
            let n = paths.count
            return SessionCommandResult(code: .delivered, reason: nil,
                                        detail: "Sent as a file location — Claude opens \(photos(n)) itself (not attached)", attached: 0)
        case .refused:
            io.remove(paths)
            return r.reason == .busy ? .refused(.attachBusy, busyMessage) : r
        default:
            return r
        }
    }
}

// MARK: - reading the transcript forward

/// What Claude logged for the pasted message: Claude Code writes it as one
/// `type: "user"` record whose `message.content` holds a text block and one
/// `image` block (base64) per photo, with a top-level `imagePasteIds`
/// (checked on this Mac's transcripts). Such lines run to megabytes, so this
/// reads forward from the offset noted before the paste, bounded, instead of
/// using the tail readers.
enum TranscriptImageReceipt {
    static let maxBytes = 16 * 1024 * 1024

    struct Found: Equatable {
        /// Image blocks in the record.
        let images: Int
    }

    /// Pure. The first complete line in `data` that is a main-thread user
    /// record with `imagePasteIds`, and its image count. A partial last line
    /// (still being written) is skipped.
    static func scan(_ data: Data) -> Found? {
        let marker = Data("\"imagePasteIds\"".utf8)
        var start = data.startIndex
        while start < data.endIndex, let nl = data[start...].firstIndex(of: 0x0A) {
            let line = data[start..<nl]
            start = data.index(after: nl)
            guard line.first == UInt8(ascii: "{"), line.range(of: marker) != nil,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  obj["type"] as? String == "user", obj["isSidechain"] as? Bool != true,
                  let ids = obj["imagePasteIds"] as? [Any], !ids.isEmpty else { continue }
            let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return Found(images: content.filter { $0["type"] as? String == "image" }.count)
        }
        return nil
    }

    /// The transcript's size, or nil (same guards as `read`).
    static func size(path: String) -> UInt64? {
        SessionRemote.fileStamp(path)?.size
    }

    /// Reads at most `maxBytes` from `offset` on and scans them. Never a
    /// FIFO, device or privacy-protected path.
    static func read(path: String, from offset: UInt64, maxBytes: Int = maxBytes) -> Found? {
        guard maxBytes > 0, !path.hasPrefix("/dev/"), !PrivacyProtectedPaths.contains(path) else { return nil }
        let resolved = (path as NSString).resolvingSymlinksInPath
        guard !resolved.hasPrefix("/dev/"), !PrivacyProtectedPaths.contains(resolved) else { return nil }
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size >= 0, UInt64(st.st_size) > offset else { return nil }
        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: maxBytes) else { return nil }
            return scan(data)
        } catch {
            return nil
        }
    }
}

// MARK: - live wiring

extension ImageDelivery {
    /// The real registry, terminal, folder and transcript behind `IO`.
    static func liveIO(registry: ClaudeSessionRegistry, store: ImageStore = .standard) -> IO {
        func transcript(_ s: ClaudeLiveSession) -> String? { registry.transcriptURL(forSessionId: s.sessionId, cwdHint: s.cwd)?.path }
        return IO(
            resolve: { id in
                InjectionExecutor.resolveClaudeTarget(
                    InjectionExecutor.ClaudeReplyRequest(interventionId: "\(id)-images", sessionId: id, action: nil, text: "", kind: .idle,
                                                         pagePid: nil, pageStateStart: nil, pagePromptKey: nil, hookCreatedAt: nil),
                    registry: registry)
            },
            currentRecord: { pid in
                if let r = registry.currentRecord(forPid: pid) { return r }
                usleep(50_000)
                return registry.currentRecord(forPid: pid)
            },
            resolveHost: { InjectionExecutor.resolveHost(for: $0, processTable: $1) },
            squadPaused: { ClaudeSquad.isPausedLive(session: $0, host: $1) },
            isForeground: { ProcessRunner.isForeground(pid: $0) },
            readBox: { InjectionExecutor.inputBox(of: $0) },
            write: { data, kind, sid in store.write(data, kind: kind, sessionId: sid) },
            remove: { store.remove($0) },
            // No transcript yet (a fresh session writes it with its first message): it starts at 0.
            transcriptSize: { s in transcript(s).flatMap(TranscriptImageReceipt.size(path:)) ?? 0 },
            receipt: { s, offset in transcript(s).flatMap { TranscriptImageReceipt.read(path: $0, from: offset) } },
            sendKey: { host, key in InjectionExecutor.sendImageKey(key, to: host) },
            deliverText: { InjectionExecutor.deliverToLiveSession($0, session: $1, processTable: $2, registry: registry) })
    }
}

extension InjectionExecutor {
    /// The session's input box as read off its screen: with colours where
    /// the host gives them (tmux, WezTerm, kitty, Herdr), so placeholder text
    /// isn't taken for typing. nil when the screen can't be read or the box
    /// isn't on it.
    static func inputBox(of host: TerminalHost) -> ClaudeInputContent? {
        switch host {
        case .tmux(let tmux, let pane, _, _):
            let r = ProcessRunner.run(tmux, ["capture-pane", "-p", "-e", "-t", pane], timeout: 3)
            return r.succeeded ? claudeInputContent(screen: r.stdout, styled: true) : nil
        case .wezterm(let target):
            return WezTermBridge.screen(target, styled: true).flatMap { claudeInputContent(screen: $0, styled: true) }
        case .kitty(let target):
            return KittyBridge.screen(target, styled: true).flatMap { claudeInputContent(screen: $0, styled: true) }
        case .herdr(let target):
            return HerdrBridge.screen(target, styled: true).flatMap { claudeInputContent(screen: $0, styled: true) }
        case .terminalApp, .iTerm:
            return screenReader(for: host)?().flatMap { claudeInputContent(screen: $0, styled: false) }
        case .cmux(let target):
            return CmuxBridge.screen(target).flatMap { claudeInputContent(screen: $0, styled: false) }
        case .unreachable, .unsupported, .unknown:
            return nil
        }
    }

    /// One key of a photo delivery (the paste, then Enter). cmux and
    /// Terminal.app have no measured paste route, so they never get here
    /// (their catalog entry is path-only); iTerm2's transport refuses a paste.
    static func sendImageKey(_ key: Keystroke, to host: TerminalHost) -> String? {
        switch host {
        case .cmux: return pasteUnsupportedMessage("cmux")
        case .terminalApp: return pasteUnsupportedMessage("Terminal")
        default: return sendOneKey(key, to: host)
        }
    }
}
