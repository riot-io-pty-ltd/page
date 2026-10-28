import Foundation
import CryptoKit
import CoreGraphics
import ImageIO

// Photos into a session's chat (docs/SESSIONS-PROTOCOL.md "Images (images-v1)").
// From the room's composer a phone sends up to 4 photos with a caption into a
// Claude session. Each photo is decoded and re-encoded here (so no EXIF, GPS
// or XMP ever leaves the phone, and HEIC never does either), cut into pieces
// of at most 32 KiB (each its own sealed `imagePart`, never answered), and
// named by one `inputImages` that carries the caption and gets the one result.
//
//   PhotoLimits      every number on the wire, in one place
//   PhotoOffer       when the photo button shows, and what it says when it can't
//   PhotoCaption     the caption line the Mac would refuse
//   PhotoPieces      the chunking math and the SHA-256
//   PhotoEncoder     decode, shrink, re-encode, strip: the phone's half of the contract
//   PhotoUploadMachine  at most 3 pieces in flight, 429 backoff, 503 stop, one resend of 'missing'
//   PhotoDraft       the composer's thumbnails
//   PhotoSend / PhotoCopy / PhotoEcho   how a sent message reads and how its transcript row is recognised
//
// Foundation, CryptoKit and ImageIO only (no UIKit), so it runs in the plain-swiftc logic tests and
// compiles into the widget. The rules and copy are the Android app's (`model/Photos.kt` and
// `model/PhotoUpload.kt`): change one, change the other.

// MARK: - Numbers

enum PhotoLimits {
    /// The list header `caps` name for `imagePart` / `inputImages`.
    static let capability = "images-v1"
    static let maxPhotos = 4
    /// Claude Code's own cap on the long edge.
    static let maxEdge = 2000
    /// 1 MiB each, 2.5 MiB for the message.
    static let maxBytesEach = 1024 * 1024
    static let maxBytesTotal = 5 * 512 * 1024
    /// Below this a photo is not worth sending: the picture would be mush (the room left is `overTotal`).
    static let minBudget = 96 * 1024
    /// Raw bytes per piece: 32 KiB, which keeps the sealed body under the Worker's 64 KiB.
    static let pieceBytes = 32 * 1024
    /// A photo of 1 MiB is 32 pieces.
    static let maxPieces = 32
    static let maxInFlight = 3
    /// From sending `inputImages`: a delivery that waits for Claude's chips can take 12-15 s.
    static let resultTimeout: TimeInterval = 30
    static let maxCaption = 8000
}

// MARK: - Whether the button shows

/// The photo button, from what the Mac says (`caps`, the row's `attach` / `attachBlocker`) and what the room is doing.
/// It shows only when `caps` has `images-v1` AND the row has `attach`. While the session works or waits it shows
/// dimmed and says why when tapped (it stays tappable, so the reason can be read).
struct PhotoOffer: Equatable {
    enum Mode: Equatable {
        case hidden
        case available
        /// Dimmed; the reason is shown when it is tapped.
        case unavailable(String)
    }

    let mode: Mode
    /// "image" (pasted, attached) or "path" (typed as a file location). Nil with no button.
    let attach: String?
    /// A one-line note under the field: the path route's, or the row's `attachBlocker`.
    let note: String?

    static let hidden = PhotoOffer(mode: .hidden, attach: nil, note: nil)

    static let busyReason = "Claude is working — send the photo when it finishes"
    static let waitingReason = "Answer the prompt first"
    static let goneReason = "Your Mac can't take photos any more"
    static let pathNote = "Terminal can't paste photos — Claude gets the file's location and opens it itself"

    var showsButton: Bool { mode != .hidden }
    var isAvailable: Bool { mode == .available }
    var reason: String? { if case .unavailable(let why) = mode { return why }; return nil }

    /// What the line under the field says about the way the photos go (nil with no photos to send).
    var previewTail: String? {
        switch attach {
        case "image": return "pasted as images, then Return"
        case "path": return "typed as file locations, then Return"
        default: return nil
        }
    }

    /// `staged`: photos already in the composer, so a Mac that stopped offering them is said out loud.
    static func build(caps: Set<String>, attach: String?, attachBlocker: String?, composer: RoomComposerMode, ended: Bool, staged: Int = 0) -> PhotoOffer {
        let route = (attach == "image" || attach == "path") ? attach : nil
        guard caps.contains(PhotoLimits.capability), let route else {
            if staged > 0 && !ended { return PhotoOffer(mode: .unavailable(goneReason), attach: nil, note: nil) }
            // No button, but a row Page can type into may say why photos aren't offered (Codex, a terminal not proven).
            let blocker = attachBlocker?.trimmingCharacters(in: .whitespacesAndNewlines)
            let note = caps.contains(PhotoLimits.capability) && !ended && composer.acceptsText && !composer.routesThroughPage ? blocker : nil
            return PhotoOffer(mode: .hidden, attach: nil, note: (note?.isEmpty ?? true) ? nil : note)
        }
        if ended { return .hidden }
        switch composer {
        case .disabled, .blocked: return .hidden
        case .locked, .tellInstead: return PhotoOffer(mode: .unavailable(waitingReason), attach: route, note: nil)
        case .steer: return PhotoOffer(mode: .unavailable(busyReason), attach: route, note: nil)
        case .nextTask: return PhotoOffer(mode: .available, attach: route, note: route == "path" ? pathNote : nil)
        }
    }
}

// MARK: - The caption

enum PhotoCaption {
    /// The Mac's wording, so the same sentence reaches the phone from either side.
    static let pathLineMessage = "A line of your message is a photo's file path, which Claude would try to open as a photo — add a word before it"
    static let tooLongMessage = "The message is too long with the photos (8000 characters at most)"

    /// Why the caption can't go in: one of its lines is (only) an absolute image path, which Claude Code's paste
    /// detector would try to attach. Split the way Claude Code splits a line (on a space before "/" or a drive
    /// letter, optionally quoted); the same rule the Mac applies, so the Mac never has to say it.
    static func problem(_ caption: String) -> String? {
        if caption.trimmingCharacters(in: .whitespacesAndNewlines).count > PhotoLimits.maxCaption { return tooLongMessage }
        guard let splitter = try? NSRegularExpression(pattern: #" (?=["']?(?:/|[A-Za-z]:\\))"#),
              let imageExt = try? NSRegularExpression(pattern: #"\.(png|jpe?g|gif|webp)$"#, options: [.caseInsensitive]) else { return nil }
        for raw in caption.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
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
}

// MARK: - Pieces

enum PhotoPieces {
    /// ceil(bytes / 32 KiB): 1 for a tiny photo, at most 32 for 1 MiB.
    static func count(bytes: Int) -> Int { bytes <= 0 ? 0 : (bytes + PhotoLimits.pieceBytes - 1) / PhotoLimits.pieceBytes }

    /// The raw bytes of piece `index` (0-based) of a photo `bytes` long.
    static func range(index: Int, bytes: Int) -> Range<Int> {
        let lo = min(bytes, index * PhotoLimits.pieceBytes)
        return lo..<min(bytes, lo + PhotoLimits.pieceBytes)
    }

    /// Lowercase hex SHA-256 of the whole photo.
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `[A-Za-z0-9_-]{8,64}`, unique per photo.
    static func newImageId() -> String {
        "img_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16)
    }
}

// MARK: - A photo ready to send

struct PreparedPhoto: Equatable, Identifiable {
    let id: String
    /// The re-encoded bytes: JPEG or PNG, no metadata.
    let data: Data
    /// "image/jpeg" or "image/png".
    let mime: String
    let sha256: String
    let width: Int
    let height: Int
    /// A small JPEG for the composer (never sent).
    let thumb: Data?

    var bytes: Int { data.count }
    var pieceCount: Int { PhotoPieces.count(bytes: data.count) }
}

/// What `inputImages` names for each photo.
struct PhotoRef: Equatable {
    let id: String
    let sha256: String
    let bytes: Int
    let mime: String

    init(_ p: PreparedPhoto) { id = p.id; sha256 = p.sha256; bytes = p.bytes; mime = p.mime }

    var json: [String: Any] { ["id": id, "sha256": sha256, "bytes": bytes, "mime": mime] }
}

// MARK: - Re-encoding

/// Every photo is decoded and re-encoded on the phone, even a small JPEG that already fits: picker data carries
/// the original bytes, GPS included, and those are never sent. The output is written by ImageIO from the pixels
/// alone (only the quality is given), so there is no EXIF, GPS, XMP or IPTC in it, and the orientation is baked
/// into the pixels (the thumbnail transform) because nothing is left to say it.
enum PhotoEncoder {
    enum Failure: Error, Equatable {
        case unreadable
        /// Even the smallest step doesn't fit the room left for this photo.
        case tooBig
        /// It would fit alone, but not beside the photos already added (2.5 MiB for the message).
        case overTotal

        var message: String {
            switch self {
            case .unreadable: return "Page couldn't read that photo."
            case .tooBig: return "That photo is too large to send. Try a smaller one."
            case .overTotal: return "The photos are too large together (2.5 MB at most). Remove one and try again."
            }
        }
    }

    struct Output: Equatable {
        let data: Data
        let mime: String
        let width: Int
        let height: Int

        var bytes: Int { data.count }
    }

    /// JPEG: quality 0.8, stepping down to 0.6, then a 1600 and a 1280 px long edge, then a last small step.
    static let ladder: [(edge: Int, quality: Double)] = [(2000, 0.8), (2000, 0.6), (1600, 0.6), (1280, 0.6), (1024, 0.5)]
    /// A screenshot whose PNG doesn't fit goes as JPEG at 0.9 first (docs: "else JPEG at 0.9"), then down the ladder.
    static let screenshotStep: (edge: Int, quality: Double) = (2000, 0.9)

    /// Re-encodes `input` (JPEG, PNG, HEIC, anything ImageIO reads) to at most `budget` bytes.
    /// A screenshot (a PNG source) or a picture with alpha goes as PNG when that fits, else as JPEG starting at 0.9;
    /// anything else is a JPEG down the ladder (alpha flattened onto white).
    static func encode(_ input: Data, budget: Int = PhotoLimits.maxBytesEach) -> Result<Output, Failure> {
        let cap = min(budget, PhotoLimits.maxBytesEach)
        // No room worth using beside the photos already added.
        if cap < PhotoLimits.minBudget { return .failure(.overTotal) }
        guard let source = CGImageSourceCreateWithData(input as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) >= 1,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, w > 0, h > 0 else { return .failure(.unreadable) }
        // The orientation swaps the sides: the long edge is the same either way.
        let longest = max(w, h)
        let hasAlpha = (props[kCGImagePropertyHasAlpha] as? Bool) ?? false
        let pngFirst = hasAlpha || (CGImageSourceGetType(source) as String?) == "public.png"

        func scaled(_ edge: Int) -> CGImage? {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: min(edge, longest),
                kCGImageSourceShouldCacheImmediately: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }

        if pngFirst, let image = scaled(PhotoLimits.maxEdge), let png = write(image, type: "public.png", quality: nil), png.count <= cap {
            return .success(Output(data: png, mime: "image/png", width: image.width, height: image.height))
        }
        var tried = Set<String>()
        for step in pngFirst ? [screenshotStep] + ladder : ladder {
            let edge = min(step.edge, longest)
            guard tried.insert("\(edge)/\(step.quality)").inserted, let raw = scaled(edge) else { continue }
            guard let image = hasAlpha || raw.alphaInfo.hasAlpha ? flattened(raw) : raw,
                  let jpeg = write(image, type: "public.jpeg", quality: step.quality) else { continue }
            if jpeg.count <= cap { return .success(Output(data: jpeg, mime: "image/jpeg", width: image.width, height: image.height)) }
        }
        return .failure(cap < PhotoLimits.maxBytesEach ? .overTotal : .tooBig)
    }

    /// Encodes and wraps it for sending: id, SHA-256 and a composer thumbnail.
    static func prepare(_ input: Data, budget: Int = PhotoLimits.maxBytesEach) -> Result<PreparedPhoto, Failure> {
        switch encode(input, budget: budget) {
        case .failure(let f): return .failure(f)
        case .success(let out):
            return .success(PreparedPhoto(id: PhotoPieces.newImageId(), data: out.data, mime: out.mime, sha256: PhotoPieces.sha256Hex(out.data),
                                          width: out.width, height: out.height, thumb: thumbnail(of: out.data)))
        }
    }

    /// What `budget` is left for the next photo given what is already prepared.
    static func budget(used: Int) -> Int { min(PhotoLimits.maxBytesEach, PhotoLimits.maxBytesTotal - used) }

    /// A small JPEG of the prepared photo, for the composer.
    static func thumbnail(of data: Data, edge: Int = 240) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: edge, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        return write(image.alphaInfo.hasAlpha ? flattened(image) ?? image : image, type: "public.jpeg", quality: 0.7)
    }

    private static func write(_ image: CGImage, type: String, quality: Double?) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type as CFString, 1, nil) else { return nil }
        // Only the quality: nothing else is ever given, so nothing else is written.
        let options = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(dest, image, options)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// The picture on an opaque white background (JPEG has no alpha).
    private static func flattened(_ image: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }
}

private extension CGImageAlphaInfo {
    var hasAlpha: Bool {
        switch self {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }
}

// MARK: - The composer's thumbnails

struct PhotoDraftItem: Identifiable, Equatable {
    enum Phase: Equatable {
        /// Decoding and re-encoding: Send waits.
        case encoding
        case ready(PreparedPhoto)
    }

    let id: String
    var phase: Phase

    var photo: PreparedPhoto? { if case .ready(let p) = phase { return p }; return nil }
    var isEncoding: Bool { phase == .encoding }
}

enum PhotoDraft {
    /// How many more may be added.
    static func slots(_ items: [PhotoDraftItem]) -> Int { max(0, PhotoLimits.maxPhotos - items.count) }

    static func prepared(_ items: [PhotoDraftItem]) -> [PreparedPhoto] { items.compactMap(\.photo) }

    static func usedBytes(_ items: [PhotoDraftItem]) -> Int { prepared(items).reduce(0) { $0 + $1.bytes } }

    static func anyEncoding(_ items: [PhotoDraftItem]) -> Bool { items.contains { $0.isEncoding } }

    /// Send needs words or photos, and waits for every photo to be encoded.
    static func canSend(text: String, items: [PhotoDraftItem]) -> Bool {
        if anyEncoding(items) { return false }
        return !items.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What VoiceOver says for a thumbnail's remove button.
    static func removeLabel(index: Int, count: Int) -> String { "Photo \(index + 1) of \(count), remove" }

    static func photoLabel(index: Int, count: Int) -> String { "Photo \(index + 1) of \(count)" }

    static func countLabel(_ n: Int) -> String { n == 1 ? "1 photo" : "\(n) photos" }
}

// MARK: - Upload

struct PhotoPieceRef: Hashable {
    let photo: Int
    let index: Int
}

/// The upload as a pure machine. The driver asks `startable` for pieces (at most 3 in flight), posts each with a
/// fresh clientId, and reports every answer to `finished`; when `phase` is `.ready` every piece got its 202 and
/// `inputImages` may go. 429 backs off and retries, 503 stops, a piece that fails in transit is retried a few
/// times. After `attachment_missing`, `resend` puts the named photos' pieces back once.
struct PhotoUploadMachine: Equatable {
    enum Phase: Equatable {
        case uploading
        /// Every piece was accepted: send `inputImages`.
        case ready
        /// Nothing more will be posted; the reason is shown.
        case stopped(String)
    }

    static let macOfflineMessage = "Your Mac went offline"
    static let maxAttempts = 3
    static let maxRateLimits = 12
    static let backoffStart: TimeInterval = 0.5
    static let backoffCap: TimeInterval = 4

    let counts: [Int]
    private(set) var phase = Phase.uploading
    private var pending: [PhotoPieceRef]
    private var inFlight = Set<PhotoPieceRef>()
    private var done = Set<PhotoPieceRef>()
    private var attempts: [PhotoPieceRef: Int] = [:]
    private var rateLimits: [PhotoPieceRef: Int] = [:]
    private var streak = 0
    private(set) var backoffUntil: Date?
    private(set) var resent = false

    /// `counts[i]` is photo i's piece count.
    init(counts: [Int]) {
        self.counts = counts
        pending = counts.enumerated().flatMap { p, n in (0..<n).map { PhotoPieceRef(photo: p, index: $0) } }
        if pending.isEmpty { phase = .ready }
    }

    var total: Int { counts.reduce(0, +) }
    var doneCount: Int { done.count }
    var inFlightCount: Int { inFlight.count }
    var progressLabel: String { "Uploading \(done.count) of \(total)" }

    /// How often the piece has been posted (1 on the first post): the driver gives each post a new clientId.
    func attempt(of piece: PhotoPieceRef) -> Int { attempts[piece] ?? 0 }

    /// The pieces to post now: up to 3 in flight, none while backing off.
    mutating func startable(now: Date) -> [PhotoPieceRef] {
        guard phase == .uploading else { return [] }
        if let until = backoffUntil, now < until { return [] }
        backoffUntil = nil
        var out: [PhotoPieceRef] = []
        while inFlight.count < PhotoLimits.maxInFlight, !pending.isEmpty {
            let p = pending.removeFirst()
            inFlight.insert(p)
            attempts[p, default: 0] += 1
            out.append(p)
        }
        return out
    }

    /// Seconds until a piece may start (0 now), when there is nothing in flight to wait for.
    func wait(now: Date) -> TimeInterval { max(0, backoffUntil?.timeIntervalSince(now) ?? 0) }

    mutating func finished(_ piece: PhotoPieceRef, _ outcome: SessionCommandOutcome, now: Date) {
        guard inFlight.remove(piece) != nil else { return }
        if case .stopped = phase { return }
        switch outcome {
        case .accepted:
            done.insert(piece)
            streak = 0
            if done.count == total { phase = .ready }
        case .rateLimited:
            let n = rateLimits[piece, default: 0] + 1
            rateLimits[piece] = n
            if n > Self.maxRateLimits { stop(outcome.failureMessage ?? "Too many messages in a minute."); return }
            pending.insert(piece, at: 0)
            streak += 1
            backoffUntil = now.addingTimeInterval(min(Self.backoffCap, Self.backoffStart * pow(2, Double(streak - 1))))
        case .macOffline:
            stop(Self.macOfflineMessage)
        case .failed(let message):
            // A transport hiccup: try again, then say so.
            if attempt(of: piece) >= Self.maxAttempts { stop(message) } else { pending.insert(piece, at: 0) }
        case .invalid, .tooLarge, .unauthorized, .retired, .relayTooOld:
            stop(outcome.failureMessage ?? "The photo didn't go.")
        }
    }

    private mutating func stop(_ why: String) {
        phase = .stopped(why)
        pending = []
    }

    /// After `attachment_missing`: resend these photos' pieces, once. False when it was already done (the second
    /// time is final) or none of the ids named a photo.
    mutating func resend(photos: [Int]) -> Bool {
        let valid = photos.filter { counts.indices.contains($0) }
        guard !resent, !valid.isEmpty, phase == .ready else { return false }
        resent = true
        for p in Set(valid).sorted() {
            for i in 0..<counts[p] {
                let ref = PhotoPieceRef(photo: p, index: i)
                done.remove(ref)
                attempts[ref] = 0
                rateLimits[ref] = 0
                pending.append(ref)
            }
        }
        phase = .uploading
        return true
    }
}

// MARK: - Which message an `inputImages` result belongs to

/// `inputImages` clientId -> the photo message's bubble. A resend after `attachment_missing` goes out under a new
/// clientId, and the phone stops waiting after 30 s (or loses the POST), but the Mac still answers: for a while
/// after that the answer finds its bubble, so a late "delivered" settles it instead of leaving "No answer". Not
/// cleared when the message settles, only when it is old.
struct PhotoResultRoutes: Equatable {
    /// How long a late result is still welcome.
    static let keepFor: TimeInterval = 5 * 60

    private var routes: [String: (bubble: String, at: Date)] = [:]

    static func == (a: PhotoResultRoutes, b: PhotoResultRoutes) -> Bool {
        a.routes.count == b.routes.count && a.routes.allSatisfy { b.routes[$0.key]?.bubble == $0.value.bubble && b.routes[$0.key]?.at == $0.value.at }
    }

    var isEmpty: Bool { routes.isEmpty }

    mutating func record(clientId: String, bubble: String, now: Date) {
        prune(now: now)
        routes[clientId] = (bubble, now)
    }

    /// The bubble this result answers for, nil when none was sent under that id or it is too old.
    func bubble(for clientId: String, now: Date) -> String? {
        guard let r = routes[clientId], now.timeIntervalSince(r.at) <= Self.keepFor else { return nil }
        return r.bubble
    }

    mutating func prune(now: Date) {
        routes = routes.filter { now.timeIntervalSince($0.value.at) <= Self.keepFor }
    }

    mutating func removeAll() { routes = [:] }
}

// MARK: - A photo message, as the room draws it

struct PhotoSend: Equatable {
    enum Phase: Equatable {
        case uploading(done: Int, total: Int)
        /// `inputImages` is out: the Mac is putting the photos into the session.
        case typing
    }

    let count: Int
    /// "image" or "path", as the row said when it was sent.
    let attach: String?
    var phase: Phase
    /// `attached` from the result (how many photos Claude received as images).
    var attached: Int?
}

/// What a photo message says, from the Mac's words and what the phone knows.
enum PhotoCopy {
    static func uploading(_ done: Int, _ total: Int) -> String { "Uploading \(done) of \(total)" }

    /// "Typing into tmux…": where the Mac is putting them.
    static func typing(host: String?) -> String {
        let h = host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return h.isEmpty ? "Typing into the session…" : "Typing into \(h)…"
    }

    /// The receipt for a delivered message: the Mac's own sentence when it sent one, else the facts.
    static func delivered(detail: String?, attached: Int?, count: Int, attach: String?) -> String {
        if let d = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty { return d }
        let noun = count == 1 ? "photo" : "photos"
        switch attached {
        case let a? where a >= count: return "Sent \(count) \(noun) to Claude"
        case 0?: return attach == "path" ? "Sent as a file location — Claude opens the photo itself (not attached)"
                                         : "Sent, but Claude took the photo as a file location, not an image"
        case let a?: return "Sent, but Claude received \(a) of \(count) photos"
        case nil: return "Sent the \(count == 1 ? "photo" : "photos") to Claude — it hasn't logged \(count == 1 ? "it" : "them") yet"
        }
    }

    /// The reasons only a photo message meets. Anything else falls to `SessionResultCopy`; nil means "not mine".
    static func refusal(reason: String?, detail: String?) -> String? {
        switch reason {
        case "attachment_missing": return "Part of a photo didn't reach your Mac — send it again"
        case "attachment_invalid": return detail ?? "Your Mac couldn't use the photo."
        case "attach_unsupported": return detail ?? "This terminal can't take photos from Page."
        case "attach_busy": return PhotoOffer.busyReason
        default: return nil
        }
    }

    static let noAnswer = "No answer from your Mac. It may still arrive; check the story before sending again."
}

// MARK: - Recognising a photo message in the transcript

/// The transcript's text for a message with photos is "[Image #1] [Image #2]what are these?", or "[Image]" /
/// "[2 images]" when it has no words (the Mac sends the count as `images`). On the path route the message has the
/// caption and "Photo from my phone: <path>" lines instead. The bubble shows the caption and a chip, and the
/// phone's own pending bubble is matched to the entry by that caption.
enum PhotoEcho {
    static let pathLinePrefix = "Photo from my phone: "

    /// The words the person wrote, with the chips, placeholders and path lines removed.
    static func caption(of text: String) -> String {
        var lines: [String] = []
        for raw in text.components(separatedBy: "\n") {
            if raw.hasPrefix(pathLinePrefix) { continue }
            lines.append(raw)
        }
        var t = lines.joined(separator: "\n")
        t = t.replacingOccurrences(of: #"\[Image #\d+\]\s?"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"^\s*\[(?:Image|\d+ images)\]\s*$"#, with: "", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The entry carried photos (by the Mac's count, or by the path route's lines).
    static func isPhotoMessage(text: String, images: Int) -> Bool {
        images > 0 || text.contains(pathLinePrefix) || text.range(of: #"\[Image #\d+\]"#, options: .regularExpression) != nil
    }

    /// Claude Code folds a long caption into "[Pasted text #7 +14 lines]".
    private static func isPastedPlaceholder(_ s: String) -> Bool {
        s.range(of: #"^\[Pasted text #\d+ \+\d+ lines\]$"#, options: .regularExpression) != nil
    }

    /// The transcript entry is the message the phone sent with these photos and this caption.
    static func echoes(entryText: String, images: Int, caption sent: String) -> Bool {
        guard isPhotoMessage(text: entryText, images: images) else { return false }
        let e = TranscriptTimeline.normalise(caption(of: entryText)), s = TranscriptTimeline.normalise(sent)
        if e == s { return true }
        if isPastedPlaceholder(e) { return true }
        return TranscriptTimeline.echoes(e, s)
    }
}
