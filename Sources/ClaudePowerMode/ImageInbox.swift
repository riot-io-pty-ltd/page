import CryptoKit
import Foundation
import ImageIO

/// Photos a phone sends into a Claude session (`images-v1`,
/// SESSIONS-PROTOCOL.md "Images"). The phone shrinks and re-encodes each
/// photo, then sends it in pieces of at most 32 KiB, each its own sealed
/// `imagePart` command, followed by one `inputImages` naming the photos and
/// carrying the caption. This file holds the Mac's receiving half, all pure
/// or confined to one folder:
///
///   - `ImagePart` / `ImageRef`: the two ops' image fields, parsed with strict
///     bounds (anything out of range drops the whole field);
///   - `ImageAssembler`: puts the pieces back together in memory, bounded in
///     count, size and time, and checks the length and SHA-256;
///   - `ImageCheck`: JPEG or PNG by its first bytes, a size cap, and a refusal
///     for any photo that still carries location data;
///   - `ImageStore`: the private temporary folder the photo is written to just
///     before Page pastes its path, and its cleanup.
///
/// Logs carry ids, counts and sizes only, never image data, captions or paths.

// MARK: - wire fields

/// One piece of a photo (`imagePart`). Every piece repeats the photo's
/// metadata, so pieces may arrive in any order.
struct ImagePart: Equatable {
    let imageId: String
    let index: Int
    let total: Int
    /// The whole photo's size and lowercase hex SHA-256.
    let bytes: Int
    let sha256: String
    let mime: String
    let data: Data

    /// 32 KiB raw: the sealed command then stays under the Worker's 64 KiB body cap.
    static let maxDataBytes = 32 * 1024

    /// nil unless every field is present and in range.
    static func parse(_ obj: [String: Any]) -> ImagePart? {
        guard let id = obj["imageId"] as? String, ImageWire.isImageId(id),
              let total = ImageWire.int(obj["total"]), (1...ImageAssembler.maxParts).contains(total),
              let index = ImageWire.int(obj["index"]), index >= 0, index < total,
              let bytes = ImageWire.int(obj["bytes"]), (1...ImageAssembler.maxBytes).contains(bytes),
              let sha = (obj["sha256"] as? String)?.lowercased(), ImageWire.isSHA256(sha),
              let mime = obj["mime"] as? String, ImageWire.mimes.contains(mime),
              let b64 = obj["data"] as? String, !b64.isEmpty, b64.utf8.count <= (maxDataBytes + 2) / 3 * 4 + 4,
              let data = Data(base64Encoded: b64), !data.isEmpty, data.count <= maxDataBytes, data.count <= bytes else { return nil }
        return ImagePart(imageId: id, index: index, total: total, bytes: bytes, sha256: sha, mime: mime, data: data)
    }
}

/// A photo an `inputImages` command carries.
struct ImageRef: Equatable {
    let id: String
    let sha256: String
    let bytes: Int
    let mime: String

    static let maxImages = 4
    /// 2.5 MiB raw across the message: 80 parts at most.
    static let maxTotalBytes = 5 * 512 * 1024

    /// nil unless it is an array of 1–4 well-formed, distinct photos within
    /// the total size: a malformed list is dropped whole, never in part.
    static func parseList(_ value: Any?) -> [ImageRef]? {
        guard let items = value as? [Any], (1...maxImages).contains(items.count) else { return nil }
        var out: [ImageRef] = []
        for item in items {
            guard let o = item as? [String: Any],
                  let id = o["id"] as? String, ImageWire.isImageId(id),
                  let sha = (o["sha256"] as? String)?.lowercased(), ImageWire.isSHA256(sha),
                  let bytes = ImageWire.int(o["bytes"]), (1...ImageAssembler.maxBytes).contains(bytes),
                  let mime = o["mime"] as? String, ImageWire.mimes.contains(mime),
                  !out.contains(where: { $0.id == id }) else { return nil }
            out.append(ImageRef(id: id, sha256: sha, bytes: bytes, mime: mime))
        }
        guard out.reduce(0, { $0 + $1.bytes }) <= maxTotalBytes else { return nil }
        return out
    }
}

enum ImageWire {
    static let mimes: Set<String> = ["image/jpeg", "image/png"]

    /// `[A-Za-z0-9_-]{8,64}`.
    static func isImageId(_ s: String) -> Bool {
        (8...64).contains(s.utf8.count) && s.utf8.allSatisfy { c in
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x2D
        }
    }

    /// 64 lowercase hex characters.
    static func isSHA256(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    /// A JSON integer (never a Bool, never a fraction).
    static func int(_ any: Any?) -> Int? {
        guard let n = any as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d == d.rounded(), abs(d) < 1e12 else { return nil }
        return Int(d)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - reassembly

/// A photo whose pieces all arrived and whose length and SHA-256 matched.
struct AssembledImage: Equatable {
    let id: String
    let data: Data
    /// What the phone declared; `ImageCheck` decides from the bytes.
    let mime: String
}

/// Puts photos back together from their `imagePart` pieces (pure; the
/// caller passes the time). Pieces are keyed by (imageId, index) inside the
/// authenticated plaintext, so a repeated identical piece is ignored and a
/// conflicting one spoils that photo. A photo is kept at most 120 s after
/// its last piece; at most 8 are open and 6 MiB held at once. A photo that
/// was handed to an `inputImages` is remembered for 15 minutes, so its
/// pieces can't be replayed into a new one.
struct ImageAssembler {
    static let maxParts = 32
    static let maxBytes = 1024 * 1024
    static let maxOpen = 8
    static let maxHeldBytes = 6 * 1024 * 1024
    static let ttl: TimeInterval = 120
    static let consumedWindow: TimeInterval = 15 * 60

    enum AddOutcome: Equatable {
        /// Kept; more pieces to come.
        case stored
        /// The last missing piece: the photo is whole (not yet checked).
        case complete
        /// The same piece again: nothing changed.
        case duplicate
        /// Dropped (the string is for the log): over a limit, a photo already
        /// used, or one already spoiled.
        case dropped(String)
        /// A piece that contradicts the photo's other pieces: the photo is spoiled.
        case spoiled(String)
    }

    enum TakeOutcome: Equatable {
        case ready([AssembledImage])
        /// Photos whose pieces haven't all arrived (ids, in the command's order).
        case missing([String])
        /// A photo that can't be used: the phone-safe reason.
        case invalid(String)
    }

    private struct Pending {
        let sessionId: String
        let viewer: String?
        let bytes: Int
        let sha256: String
        let mime: String
        let total: Int
        var parts: [Int: Data] = [:]
        var lastAt: Date
        var spoiled: String?

        var received: Int { parts.values.reduce(0) { $0 + $1.count } }
        var isComplete: Bool { parts.count == total }
    }

    private var pending: [String: Pending] = [:]
    private var consumed: [String: Date] = [:]

    var openCount: Int { pending.count }
    var heldBytes: Int { pending.values.reduce(0) { $0 + $1.received } }

    static let mismatchMessage = "A photo arrived damaged — send it again"

    mutating func add(_ part: ImagePart, sessionId: String, viewer: String?, now: Date) -> AddOutcome {
        prune(now: now)
        if consumed[part.imageId] != nil { return .dropped("already used") }
        if var p = pending[part.imageId] {
            if p.spoiled != nil { return .dropped("spoiled") }
            guard p.sessionId == sessionId, p.viewer == viewer, p.bytes == part.bytes, p.sha256 == part.sha256,
                  p.mime == part.mime, p.total == part.total else {
                p.spoiled = Self.mismatchMessage
                p.parts = [:]
                pending[part.imageId] = p
                return .spoiled("pieces disagree")
            }
            if let have = p.parts[part.index] {
                if have == part.data { return .duplicate }
                p.spoiled = Self.mismatchMessage
                p.parts = [:]
                pending[part.imageId] = p
                return .spoiled("conflicting piece")
            }
            guard p.received + part.data.count <= p.bytes else {
                p.spoiled = Self.mismatchMessage
                p.parts = [:]
                pending[part.imageId] = p
                return .spoiled("more data than declared")
            }
            guard heldBytes + part.data.count <= Self.maxHeldBytes else { return .dropped("memory cap") }
            p.parts[part.index] = part.data
            p.lastAt = now
            pending[part.imageId] = p
            return p.isComplete ? .complete : .stored
        }
        guard pending.count < Self.maxOpen else { return .dropped("too many open photos") }
        guard heldBytes + part.data.count <= Self.maxHeldBytes else { return .dropped("memory cap") }
        var p = Pending(sessionId: sessionId, viewer: viewer, bytes: part.bytes, sha256: part.sha256, mime: part.mime,
                        total: part.total, lastAt: now)
        p.parts[part.index] = part.data
        pending[part.imageId] = p
        return p.isComplete ? .complete : .stored
    }

    /// The photos `refs` names, if every one is whole and matches what the
    /// command says about it (session, viewer, size, hash, type). Only a
    /// `.ready` take uses them up; after `.missing` the complete ones stay.
    mutating func take(_ refs: [ImageRef], sessionId: String, viewer: String?, now: Date) -> TakeOutcome {
        prune(now: now)
        var missing: [String] = []
        var images: [AssembledImage] = []
        for ref in refs {
            if consumed[ref.id] != nil { return .invalid("That photo was already sent — send it again") }
            guard let p = pending[ref.id] else { missing.append(ref.id); continue }
            if let why = p.spoiled { return .invalid(why) }
            guard p.sessionId == sessionId, p.viewer == viewer, p.bytes == ref.bytes, p.sha256 == ref.sha256,
                  p.mime == ref.mime else { return .invalid(Self.mismatchMessage) }
            guard p.isComplete else { missing.append(ref.id); continue }
            var data = Data(capacity: p.bytes)
            for i in 0..<p.total { data.append(p.parts[i]!) }
            guard data.count == p.bytes, ImageWire.sha256Hex(data) == p.sha256 else {
                var bad = p
                bad.spoiled = Self.mismatchMessage
                bad.parts = [:]
                pending[ref.id] = bad
                return .invalid(Self.mismatchMessage)
            }
            images.append(AssembledImage(id: ref.id, data: data, mime: p.mime))
        }
        if !missing.isEmpty { return .missing(missing) }
        for ref in refs {
            pending[ref.id] = nil
            consumed[ref.id] = now
        }
        return .ready(images)
    }

    /// Whether every photo `refs` names has all its pieces (cheap; no hashing).
    func hasAllPieces(_ refs: [ImageRef]) -> Bool {
        refs.allSatisfy { pending[$0.id]?.isComplete == true || pending[$0.id]?.spoiled != nil || consumed[$0.id] != nil }
    }

    mutating func prune(now: Date) {
        pending = pending.filter { now.timeIntervalSince($0.value.lastAt) <= Self.ttl }
        consumed = consumed.filter { now.timeIntervalSince($0.value) <= Self.consumedWindow }
    }

    /// Forgets everything (the pairing changed).
    mutating func reset() {
        pending = [:]
        consumed = [:]
    }
}

// MARK: - checking

/// What a photo must be before Page writes it to disk: JPEG or PNG by its
/// own first bytes (the declared type is ignored), readable by ImageIO, at
/// most 4096 px on the long edge and 40 megapixels, and free of location
/// data. The phone strips metadata when it re-encodes; a GPS block here
/// means that went wrong, so the photo is refused rather than passed on.
enum ImageCheck {
    enum Kind: String, Equatable {
        case jpeg, png

        var fileExtension: String { self == .jpeg ? "jpg" : "png" }
        var mime: String { self == .jpeg ? "image/jpeg" : "image/png" }
    }

    struct Failure: Error, Equatable {
        let detail: String
    }

    static let maxEdge = 4096
    static let maxPixels = 40_000_000
    /// Phones send one frame; a gain map or a few MPO pictures are tolerated, more is refused.
    static let maxFrames = 8

    static let notImageMessage = "That photo isn't a JPEG or PNG"
    static let unreadableMessage = "Page couldn't read that photo — send it again"
    static let tooLargeMessage = "That photo is too large (4096 px on its long edge at most)"
    static let locationMessage = "Your phone sent location data with the photo, so Page didn't use it"

    /// Pure. JPEG `FF D8 FF` or PNG `89 50 4E 47 0D 0A 1A 0A`; anything else is nil.
    static func sniff(_ data: Data) -> Kind? {
        let b = [UInt8](data.prefix(8))
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return .jpeg }
        if b == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] { return .png }
        return nil
    }

    /// Pure. Whether any of the property sets (one per frame, plus the
    /// file's) carries a GPS block. ImageIO folds XMP location tags into it too.
    static func hasLocation(_ properties: [[CFString: Any]]) -> Bool {
        properties.contains { $0[kCGImagePropertyGPSDictionary] != nil }
    }

    static func check(_ data: Data) -> Result<Kind, Failure> {
        guard let kind = sniff(data) else { return .failure(Failure(detail: notImageMessage)) }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              CGImageSourceGetCount(source) >= 1,
              let type = CGImageSourceGetType(source) as String?,
              type == (kind == .jpeg ? "public.jpeg" : "public.png"),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, w > 0, h > 0 else {
            return .failure(Failure(detail: unreadableMessage))
        }
        // Every frame (an MPO JPEG or an APNG holds more than one, each with its own metadata) and the file's own.
        let count = CGImageSourceGetCount(source)
        guard count <= maxFrames else { return .failure(Failure(detail: unreadableMessage)) }
        var all = [props]
        for i in 1..<count { all.append(CGImageSourceCopyPropertiesAtIndex(source, i, options) as? [CFString: Any] ?? [:]) }
        if let file = CGImageSourceCopyProperties(source, options) as? [CFString: Any] { all.append(file) }
        if hasLocation(all) { return .failure(Failure(detail: locationMessage)) }
        guard max(w, h) <= maxEdge, w * h <= maxPixels else { return .failure(Failure(detail: tooLargeMessage)) }
        // A header can parse while the pixels can't (a truncated or crafted file): decode it once, now.
        let decode = [kCGImageSourceShouldCache: false, kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard CGImageSourceCreateImageAtIndex(source, 0, decode) != nil else {
            return .failure(Failure(detail: unreadableMessage))
        }
        return .success(kind)
    }
}

// MARK: - storage

/// Where photos from the phone are written for Claude to read:
/// `<temporary folder>/page-images/<session>/<random>.jpg|png`. The macOS
/// per-user temporary folder (`/var/folders/…/T/`) is already private to
/// this user and has no spaces; the folders Page makes in it are 0700, and
/// each file is created exclusively, 0600, never following a link. Paths
/// are canonical (`realpath`) and must match `safePathPattern` before
/// anyone types them. The phone never names any part of a path.
///
/// Claude Code keeps its own copy of a pasted photo in the session's
/// transcript, so deleting Page's copy never breaks the conversation:
/// files go after 24 hours, a session's folder an hour after the session
/// ends, and everything when the pairing changes.
struct ImageStore {
    static let folderName = "page-images"
    static let maxAge: TimeInterval = 24 * 3600
    static let endedSessionAge: TimeInterval = 3600
    static let safePathPattern = #"^/[A-Za-z0-9._/-]+\.(jpg|png)$"#

    /// The folder `page-images` lives in.
    let base: URL

    /// The per-user temporary folder.
    static let standard = ImageStore(base: FileManager.default.temporaryDirectory)

    static let saveFailedMessage = "Page couldn't save the photo on your Mac"

    var root: URL { base.appendingPathComponent(Self.folderName, isDirectory: true) }

    /// Pure. A path Page may type: absolute, plain characters, `.jpg` / `.png`.
    static func isSafePath(_ path: String) -> Bool {
        !path.contains("..") && path.range(of: safePathPattern, options: .regularExpression) != nil
    }

    /// Pure. The folder name for a session: its id when that is plain
    /// (Claude's are UUIDs), else a hash of it.
    static func folderName(forSession sessionId: String) -> String {
        let plain = (1...64).contains(sessionId.utf8.count) && sessionId.utf8.allSatisfy { c in
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x2D || c == 0x5F
        }
        return plain ? sessionId : "s" + String(ImageWire.sha256Hex(Data(sessionId.utf8)).prefix(32))
    }

    /// Writes one photo and returns its canonical path.
    func write(_ data: Data, kind: ImageCheck.Kind, sessionId: String) -> Result<String, ImageCheck.Failure> {
        let fail = ImageCheck.Failure(detail: Self.saveFailedMessage)
        guard let dir = privateDirectory(root),
              let sessionDir = privateDirectory(URL(fileURLWithPath: dir).appendingPathComponent(Self.folderName(forSession: sessionId)))
        else { return .failure(fail) }
        let path = sessionDir + "/" + UUID().uuidString.lowercased() + "." + kind.fileExtension
        guard Self.isSafePath(path) else { return .failure(fail) }
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return .failure(fail) }
        var ok = true
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { if n < 0 && errno == EINTR { continue }; ok = false; break }
                off += n
            }
        }
        if close(fd) != 0 { ok = false }
        guard ok else { unlink(path); return .failure(fail) }
        return .success(path)
    }

    /// Removes files Page wrote (an undelivered photo).
    func remove(_ paths: [String]) {
        let prefix = (canonical(root.path) ?? root.path) + "/"
        for p in paths where p.hasPrefix(prefix) && Self.isSafePath(p) { unlink(p) }
    }

    /// Deletes files older than `maxAge`, and the folders of sessions not in
    /// `live` (folder names, `folderName(forSession:)`) whose newest file is
    /// over an hour old. Never follows a link.
    func cleanup(now: Date, live: Set<String>) {
        let fm = FileManager.default
        guard let rootPath = canonical(root.path), isOwnedDirectory(rootPath) else { return }
        for name in (try? fm.contentsOfDirectory(atPath: rootPath)) ?? [] {
            let dir = rootPath + "/" + name
            guard isOwnedDirectory(dir) else { continue }
            var newest = Date.distantPast
            var remaining = 0
            for file in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                let path = dir + "/" + file
                var st = stat()
                guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
                let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
                if now.timeIntervalSince(mtime) > Self.maxAge {
                    unlink(path)
                } else {
                    remaining += 1
                    newest = max(newest, mtime)
                }
            }
            if !live.contains(name) && (remaining == 0 || now.timeIntervalSince(newest) > Self.endedSessionAge) {
                removeTree(dir)
            } else if remaining == 0 {
                // A live session's folder: a photo may be landing in it right now, and rmdir fails if so.
                rmdir(dir)
            }
        }
    }

    /// Deletes every photo Page wrote (the pairing changed).
    func wipeAll() {
        guard let rootPath = canonical(root.path), isOwnedDirectory(rootPath) else { return }
        removeTree(rootPath)
    }

    // MARK: helpers

    /// Creates (or checks) `url` as a real directory owned by this user, mode
    /// 0700, and returns its canonical path. nil for a link or anything else.
    private func privateDirectory(_ url: URL) -> String? {
        let path = url.path
        if mkdir(path, 0o700) != 0 && errno != EEXIST { return nil }
        guard isOwnedDirectory(path) else { return nil }
        chmod(path, 0o700)
        return canonical(path)
    }

    private func isOwnedDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR && st.st_uid == getuid()
    }

    private func canonical(_ path: String) -> String? {
        guard let r = realpath(path, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }

    /// One level of regular files, then the folder (or the folder's
    /// session folders, for the root). Links are unlinked, never followed.
    private func removeTree(_ dir: String) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
            let path = dir + "/" + name
            var st = stat()
            guard lstat(path, &st) == 0 else { continue }
            if (st.st_mode & S_IFMT) == S_IFDIR && st.st_uid == getuid() {
                removeTree(path)
            } else {
                unlink(path)
            }
        }
        rmdir(dir)
    }
}
