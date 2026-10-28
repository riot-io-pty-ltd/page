import Foundation

// Steer safety, as plain values. Typing into the wrong session is the worst
// thing this app can do, so three small decisions live here where the logic
// tests can see them:
//
//   SessionTarget  what a room showed the user: the session, its folder, its
//                  terminal and Mac. Sent with every message and Stop so the
//                  Mac can refuse if the session behind the id is not that one.
//   RoomSend       what Send does for a given room, including every refusal:
//                  no Send path returns without a reason.
//   SendReceipt    the line under the room that names exactly where a message
//                  went (or why it did not).
//   DraftSubmit    the keyboard's Return/Send key.
//
// Foundation-only.

// MARK: - Target

/// What a room showed the user about the session it types into.
struct SessionTarget: Equatable {
    let sessionId: String
    /// The folder's last component ("riot-io-teltonika"); the title when the folder says nothing.
    let project: String
    let title: String
    /// As the Mac listed it (home-abbreviated), verbatim: this is what travels.
    let cwd: String
    /// The terminal, "cmux"; empty when unknown.
    let host: String
    let macName: String
    let agent: String

    init(session s: LiveSession, macName: String) {
        sessionId = s.id
        project = SkyModel.projectName(cwd: s.cwd, fallback: s.title)
        title = s.title
        cwd = s.cwd
        let h = s.host.trimmingCharacters(in: .whitespacesAndNewlines)
        host = h.lowercased() == "unknown" ? "" : h
        self.macName = macName
        agent = s.backend.displayName
    }

    /// First four characters of the id: tells two sessions in one project apart.
    var shortId: String { String(sessionId.prefix(4)) }

    /// "~/projects/riot-io-teltonika · #d8a3": the room's header line, so no two rooms read alike.
    var whereLine: String {
        let folder = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        return folder.isEmpty ? "#\(shortId)" : "\(folder) · #\(shortId)"
    }

    /// What goes on the wire as `expectCwd`: only a folder the Mac really listed.
    var expectCwd: String? {
        let c = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        return c.isEmpty ? nil : c
    }

    /// What goes on the wire as `expectTitle`: the title the Mac sent (not one this phone made up).
    var expectTitle: String? {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t == "Session \(sessionId.prefix(8))" ? nil : t
    }

    /// "riot-io-teltonika · cmux · Studio MBP": what a receipt and a preview name.
    var route: String {
        [project, host.isEmpty ? nil : host, DeliveryPreview.macLabel(macName)].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - What Send does

enum RoomSend {
    enum Decision: Equatable {
        /// Type into this session (text plus Return), carrying what the room showed.
        case input(SessionTarget)
        /// The page's own path: Esc, then the text, then Return.
        case tellInstead
        /// Nothing is sent; say why.
        case refuse(String)
    }

    /// One pure decision for Send, from the keyboard or the button. `shown` is
    /// the session the header drew; `routeSessionId` is the id the room was
    /// opened for. They are always the same unless something is badly wrong,
    /// and then nothing is typed. Every outcome that is not a send carries its
    /// reason.
    /// `photos`: how many photos go with it (`images-v1`); the caption may then be empty, and only an idle session takes them.
    static func decide(mode: RoomComposerMode, text: String, shown: LiveSession, routeSessionId: String,
                       live: LiveSession?, ended: Bool, hasReplyAction: Bool, macName: String, photos: Int = 0) -> Decision {
        guard shown.id == routeSessionId else {
            return .refuse("This room is showing a different session than it would type into, so nothing was sent. Close it and open the session again.")
        }
        switch mode {
        case .locked(let why), .blocked(let why), .disabled(let why):
            return .refuse(why)
        case .tellInstead where photos > 0:
            return .refuse(PhotoOffer.waitingReason)
        case .steer where photos > 0:
            return .refuse(PhotoOffer.busyReason)
        case .tellInstead:
            guard hasReplyAction else { return .refuse("This prompt's page isn't loaded yet, so nothing was sent. Answer on your Mac, or try again in a moment.") }
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .refuse(SessionComposer.Problem.empty.message) : .tellInstead
        case .steer, .nextTask:
            if ended || live == nil { return .refuse("This session isn't on your Mac's list any more, so nothing was sent.") }
            if photos > 0 {
                // Words are optional with photos; a caption line that is only a path would be taken for another photo.
                if let why = PhotoCaption.problem(text) { return .refuse(why) }
            } else if case .failure(let problem) = SessionComposer.validate(text) { return .refuse(problem.message) }
            return .input(SessionTarget(session: shown, macName: macName))
        }
    }
}

// MARK: - The keyboard's Send key

enum DraftSubmit {
    /// True when a draft change is exactly one Return typed at the end: how the
    /// keyboard's Send key reaches a multi-line field. A paste (more than one
    /// character) or a newline in the middle is not a send.
    static func isReturnKey(old: String, new: String) -> Bool { new == old + "\n" }

    /// One Return can reach `send` twice (the field's submit and the trailing newline): the same text
    /// again within this window is that echo, not a second message.
    static let duplicateWindow: TimeInterval = 1.0

    static func isDuplicate(text: String, last: (text: String, at: Date)?, now: Date) -> Bool {
        guard let last else { return false }
        let a = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return a == last.text.trimmingCharacters(in: .whitespacesAndNewlines) && now.timeIntervalSince(last.at) >= 0
            && now.timeIntervalSince(last.at) < duplicateWindow
    }

    /// The draft without that trailing Return.
    static func withoutReturn(_ s: String) -> String { s.hasSuffix("\n") ? String(s.dropLast()) : s }
}

// MARK: - The receipt

/// The line under the room after a send: where the message went, in the
/// project's own name, on which terminal and Mac, or why it did not.
struct SendReceipt: Equatable, Identifiable {
    enum Tone: Equatable { case working, good, problem, held, neutral }

    let id: String
    let headline: String
    /// The target (or what was not done to it), as a second line.
    let detail: String?
    let tone: Tone
    /// Waiting out its Undo: the view draws the live "Sending in N s · Undo" from this, with an Undo button.
    var countdown: SendCountdown? = nil
    /// The message is held on the Mac and can be deleted (`retract-v1`): a Delete button.
    var canDelete = false
    /// Where a Delete stands (deleting, too late, couldn't confirm), under the headline.
    var note: RetractNote? = nil
    /// An upload in progress, 0...1 (a photo message): the view draws a thin bar.
    var progress: Double? = nil

    /// Typed and queued fade after this long; a problem stays until dismissed or replaced.
    static let goodVisibleFor: TimeInterval = 60
    static let problemVisibleFor: TimeInterval = 10 * 60

    /// The receipt for the newest message sent from this room, nil once it is no longer news. Pure.
    /// `canRetract`: the Mac advertises `retract-v1`. `note`: the Delete's own progress for a held message.
    static func build(_ c: SentSessionCommand?, agent: String, now: Date, canRetract: Bool = false, note: RetractNote? = nil) -> SendReceipt? {
        guard let c, c.kind == .input else { return nil }
        let age = now.timeIntervalSince(c.sentAt)
        let route = c.target?.route
        let place = route ?? "the session"
        if let photos = c.photos, let receipt = photoReceipt(c, photos: photos, age: age, route: route, place: place) { return receipt }
        switch c.state {
        case .counting(let countdown):
            return SendReceipt(id: c.id, headline: countdown.label(now: now), detail: "Nothing has been sent yet.", tone: .working,
                               countdown: countdown)
        case .sending:
            return SendReceipt(id: c.id, headline: "Sending to \(place)…", detail: nil, tone: .working)
        case .held(let detail, let heldNote, let typing):
            // Typing right now: nothing can take it back. Otherwise the Mac's sentence, and (under it) why its last try
            // didn't type it, when the row said.
            return SendReceipt(id: c.id, headline: typing ? SessionDeliveryState.typingHeadline : SessionDeliveryState.heldCopy(detail: detail, agent: agent),
                               detail: heldNote ?? route, tone: .held,
                               canDelete: canRetract && !typing && note?.isBusy != true, note: note)
        case .deleted(let detail):
            guard age < goodVisibleFor else { return nil }
            return SendReceipt(id: c.id, headline: detail ?? SessionDeliveryState.deletedCopy, detail: nil, tone: .neutral)
        case .unconfirmed(let message):
            guard age < problemVisibleFor else { return nil }
            return SendReceipt(id: c.id, headline: message, detail: "Target: \(place)", tone: .problem)
        case .typed:
            guard age < goodVisibleFor else { return nil }
            return SendReceipt(id: c.id, headline: "Typed into \(place)", detail: nil, tone: .good)
        case .queued:
            guard age < goodVisibleFor else { return nil }
            return SendReceipt(id: c.id, headline: SessionDeliveryState.alreadyQueued(agent: agent), detail: route, tone: .good)
        case .refused(_, let message):
            guard age < problemVisibleFor else { return nil }
            return SendReceipt(id: c.id, headline: "Refused: \(message)", detail: "Target: \(place)", tone: .problem)
        case .failed(let message):
            guard age < problemVisibleFor else { return nil }
            return SendReceipt(id: c.id, headline: "Not sent: \(message)", detail: "Target: \(place)", tone: .problem)
        case .noAnswer:
            guard age < problemVisibleFor else { return nil }
            return SendReceipt(id: c.id, headline: "No answer from \(DeliveryPreview.macLabel(c.target?.macName ?? ""))",
                               detail: "It may still arrive in \(place). Check the story before sending again.", tone: .problem)
        }
    }

    /// A photo message's receipt: where the upload stands, then what the Mac says it did with them. Refusals,
    /// failures and the rest read as for any message (nil here).
    private static func photoReceipt(_ c: SentSessionCommand, photos: PhotoSend, age: TimeInterval, route: String?, place: String) -> SendReceipt? {
        let n = PhotoDraft.countLabel(photos.count)
        switch c.state {
        case .sending:
            switch photos.phase {
            case .uploading(let done, let total):
                return SendReceipt(id: c.id, headline: PhotoCopy.uploading(done, total), detail: "\(n) to \(place)", tone: .working,
                                   progress: total > 0 ? Double(done) / Double(total) : nil)
            case .typing:
                return SendReceipt(id: c.id, headline: PhotoCopy.typing(host: c.target?.host), detail: route, tone: .working)
            }
        case .typed(let detail):
            guard age < goodVisibleFor else { return nil }
            return SendReceipt(id: c.id, headline: PhotoCopy.delivered(detail: detail, attached: photos.attached, count: photos.count, attach: photos.attach),
                               detail: nil, tone: photos.attached == 0 || (photos.attached ?? photos.count) < photos.count ? .neutral : .good)
        case .noAnswer:
            return SendReceipt(id: c.id, headline: "No answer from \(DeliveryPreview.macLabel(c.target?.macName ?? ""))",
                               detail: "It may still arrive in \(place). Check the story before sending again.", tone: .problem)
        default:
            return nil
        }
    }

    /// A message still counting down offers Undo on its own bubble, unless the receipt above the field is its own
    /// (that one carries the Undo, so it isn't offered twice).
    static func bubbleOffersUndo(_ c: SentSessionCommand, receiptId: String?) -> Bool {
        c.kind == .input && c.state.isCounting && receiptId != c.clientId
    }

    /// Stop's line: names the same target.
    static func stopLine(_ c: SentSessionCommand, agent: String) -> String? {
        guard c.kind == .interrupt else { return nil }
        let place = c.target?.route ?? "the session"
        switch c.state {
        case .sending: return "Stopping \(place)…"
        case .typed, .queued: return "Stopped · pressed Esc in \(place)"
        case .counting, .held, .deleted, .unconfirmed: return nil
        case .refused, .failed, .noAnswer:
            return "Couldn't stop \(place): \(c.state.explanation(.interrupt, agent: agent) ?? "")"
        }
    }
}
