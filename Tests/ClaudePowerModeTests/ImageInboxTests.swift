import CoreGraphics
import ImageIO
import XCTest
@testable import ClaudePowerMode

/// The receiving half of `images-v1` (SESSIONS-PROTOCOL.md "Images"): the
/// two ops' image fields, reassembly, the photo check and the private folder.
/// Everything is pure or works in a temporary folder of its own.
final class ImageInboxTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_761_300_000)

    // MARK: fixtures

    /// A solid square written by ImageIO, optionally with a GPS block.
    static func image(_ type: String = "public.png", width: Int = 16, height: Int = 16, gps: Bool = false) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out as CFMutableData, type as CFString, 1, nil)!
        var props: [CFString: Any] = [:]
        if gps {
            props[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLatitudeRef: "N",
                                                    kCGImagePropertyGPSLongitude: 0.12, kCGImagePropertyGPSLongitudeRef: "W"]
        }
        CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private func parts(of data: Data, id: String = "imageAAAA1", size: Int = 8, mime: String = "image/png") -> [ImagePart] {
        let sha = ImageWire.sha256Hex(data)
        let chunks = stride(from: 0, to: data.count, by: size).map { data.subdata(in: $0..<min($0 + size, data.count)) }
        return chunks.enumerated().map { i, c in
            ImagePart(imageId: id, index: i, total: chunks.count, bytes: data.count, sha256: sha, mime: mime, data: c)
        }
    }

    private func ref(_ data: Data, id: String = "imageAAAA1", mime: String = "image/png") -> ImageRef {
        ImageRef(id: id, sha256: ImageWire.sha256Hex(data), bytes: data.count, mime: mime)
    }

    private func partObject(_ p: ImagePart) -> [String: Any] {
        ["imageId": p.imageId, "index": p.index, "total": p.total, "bytes": p.bytes, "sha256": p.sha256, "mime": p.mime,
         "data": p.data.base64EncodedString()]
    }

    // MARK: wire fields

    func testAPartParsesOnlyWithEveryFieldInRange() {
        let data = Data("hello photo".utf8)
        let good = parts(of: data, size: 64)[0]
        XCTAssertEqual(ImagePart.parse(partObject(good)), good)

        func with(_ key: String, _ value: Any?) -> ImagePart? {
            var o = partObject(good)
            o[key] = value
            return ImagePart.parse(o)
        }
        XCTAssertNil(with("imageId", "short"), "ids are 8–64 characters")
        XCTAssertNil(with("imageId", "has space in it"))
        XCTAssertNil(with("imageId", String(repeating: "a", count: 65)))
        XCTAssertNil(with("index", 1), "index must be below total")
        XCTAssertNil(with("index", -1))
        XCTAssertNil(with("index", true), "a Bool is not a number")
        XCTAssertNil(with("index", 0.5))
        XCTAssertNil(with("total", 33), "32 pieces at most")
        XCTAssertNil(with("bytes", ImageAssembler.maxBytes + 1), "1 MiB per photo at most")
        XCTAssertNil(with("bytes", 3), "a piece can't be bigger than its photo")
        XCTAssertNil(with("sha256", "abc"))
        XCTAssertNil(with("mime", "image/heic"), "JPEG and PNG only")
        XCTAssertNil(with("data", "not base64!"))
        XCTAssertNil(with("data", Data(count: ImagePart.maxDataBytes + 1).base64EncodedString()), "32 KiB per piece at most")
        XCTAssertNil(with("data", nil))
        XCTAssertEqual(with("sha256", good.sha256.uppercased())?.sha256, good.sha256, "hex is read case-insensitively")
    }

    func testAPhotoListIsDroppedWholeWhenAnyEntryIsBad() {
        let a: [String: Any] = ["id": "imageAAAA1", "sha256": String(repeating: "a", count: 64), "bytes": 10, "mime": "image/png"]
        var b = a
        b["id"] = "imageBBBB2"
        XCTAssertEqual(ImageRef.parseList([a, b])?.map(\.id), ["imageAAAA1", "imageBBBB2"])
        XCTAssertNil(ImageRef.parseList([a, a]), "ids must be distinct")
        XCTAssertNil(ImageRef.parseList([]), "at least one photo")
        XCTAssertNil(ImageRef.parseList(Array(repeating: a, count: 5).enumerated().map { i, o in
            var x = o; x["id"] = "imageIIII\(i)"; return x
        }), "4 photos at most")
        var bad = b
        bad["mime"] = "image/gif"
        XCTAssertNil(ImageRef.parseList([a, bad]), "one bad entry drops the list")
        var big = b
        big["bytes"] = ImageAssembler.maxBytes
        var big2 = a
        big2["bytes"] = ImageAssembler.maxBytes
        var big3 = a
        big3["id"] = "imageCCCC3"
        big3["bytes"] = ImageAssembler.maxBytes
        XCTAssertNil(ImageRef.parseList([big2, big, big3]), "2.5 MiB across the message at most")
        XCTAssertNil(ImageRef.parseList("nope"))
    }

    func testTheCommandParsesImageFieldsOnlyForTheirOwnOp() throws {
        let p = parts(of: Data("abcdefgh".utf8), size: 64)[0]
        var part = partObject(p)
        part["op"] = "imagePart"; part["clientId"] = "c1"; part["ts"] = 1; part["sessionId"] = "s1"
        let cmd = try XCTUnwrap(SessionCommand.parse(JSONSerialization.data(withJSONObject: part)))
        XCTAssertEqual(cmd.imagePart, p)
        XCTAssertNil(cmd.images)

        part["op"] = "input"
        XCTAssertNil(try XCTUnwrap(SessionCommand.parse(JSONSerialization.data(withJSONObject: part))).imagePart)

        let input: [String: Any] = ["op": "inputImages", "clientId": "c2", "ts": 1, "sessionId": "s1", "text": "",
                                    "images": [["id": p.imageId, "sha256": p.sha256, "bytes": p.bytes, "mime": p.mime]]]
        let cmd2 = try XCTUnwrap(SessionCommand.parse(JSONSerialization.data(withJSONObject: input)))
        XCTAssertEqual(cmd2.images?.first?.id, p.imageId)
    }

    // MARK: reassembly

    func testPiecesInAnyOrderMakeTheWholePhoto() {
        let data = Data((0..<50).map { UInt8($0) })
        var a = ImageAssembler()
        let ps = parts(of: data)
        for p in ps.reversed().dropLast() { XCTAssertEqual(a.add(p, sessionId: "s1", viewer: "v1", now: t0), .stored) }
        XCTAssertEqual(a.take([ref(data)], sessionId: "s1", viewer: "v1", now: t0), .missing(["imageAAAA1"]))
        XCTAssertEqual(a.add(ps[0], sessionId: "s1", viewer: "v1", now: t0), .complete)
        XCTAssertTrue(a.hasAllPieces([ref(data)]))
        XCTAssertEqual(a.take([ref(data)], sessionId: "s1", viewer: "v1", now: t0),
                       .ready([AssembledImage(id: "imageAAAA1", data: data, mime: "image/png")]))
        XCTAssertEqual(a.openCount, 0)
    }

    func testARepeatedPieceIsIgnoredAndAConflictingOneSpoilsThePhoto() {
        let data = Data((0..<20).map { UInt8($0) })
        var a = ImageAssembler()
        let ps = parts(of: data)
        XCTAssertEqual(a.add(ps[0], sessionId: "s1", viewer: "v1", now: t0), .stored)
        XCTAssertEqual(a.add(ps[0], sessionId: "s1", viewer: "v1", now: t0), .duplicate)
        let forged = ImagePart(imageId: ps[0].imageId, index: 0, total: ps[0].total, bytes: ps[0].bytes, sha256: ps[0].sha256,
                               mime: ps[0].mime, data: Data(repeating: 9, count: 8))
        XCTAssertEqual(a.add(forged, sessionId: "s1", viewer: "v1", now: t0), .spoiled("conflicting piece"))
        XCTAssertEqual(a.add(ps[1], sessionId: "s1", viewer: "v1", now: t0), .dropped("spoiled"))
        XCTAssertEqual(a.take([ref(data)], sessionId: "s1", viewer: "v1", now: t0), .invalid(ImageAssembler.mismatchMessage))
    }

    func testPiecesThatDisagreeOnThePhotoSpoilIt() {
        let data = Data((0..<20).map { UInt8($0) })
        var a = ImageAssembler()
        let ps = parts(of: data)
        XCTAssertEqual(a.add(ps[0], sessionId: "s1", viewer: "v1", now: t0), .stored)
        XCTAssertEqual(a.add(ps[1], sessionId: "s2", viewer: "v1", now: t0), .spoiled("pieces disagree"), "another session")
        var b = ImageAssembler()
        XCTAssertEqual(b.add(ps[0], sessionId: "s1", viewer: "v1", now: t0), .stored)
        let otherHash = ImagePart(imageId: ps[1].imageId, index: 1, total: ps[1].total, bytes: ps[1].bytes,
                                  sha256: String(repeating: "0", count: 64), mime: ps[1].mime, data: ps[1].data)
        XCTAssertEqual(b.add(otherHash, sessionId: "s1", viewer: "v1", now: t0), .spoiled("pieces disagree"))
    }

    func testAWrongHashOrADifferentCommandIsInvalid() {
        let data = Data((0..<20).map { UInt8($0) })
        let ps = parts(of: data).map {
            ImagePart(imageId: $0.imageId, index: $0.index, total: $0.total, bytes: $0.bytes,
                      sha256: String(repeating: "a", count: 64), mime: $0.mime, data: $0.data)
        }
        var a = ImageAssembler()
        for p in ps { _ = a.add(p, sessionId: "s1", viewer: "v1", now: t0) }
        let claimed = ImageRef(id: "imageAAAA1", sha256: String(repeating: "a", count: 64), bytes: 20, mime: "image/png")
        XCTAssertEqual(a.take([claimed], sessionId: "s1", viewer: "v1", now: t0), .invalid(ImageAssembler.mismatchMessage))

        var b = ImageAssembler()
        for p in parts(of: data) { _ = b.add(p, sessionId: "s1", viewer: "v1", now: t0) }
        XCTAssertEqual(b.take([ref(data)], sessionId: "s1", viewer: "v2", now: t0), .invalid(ImageAssembler.mismatchMessage),
                       "another viewer's photo")
        XCTAssertEqual(b.take([ref(data)], sessionId: "s9", viewer: "v1", now: t0), .invalid(ImageAssembler.mismatchMessage),
                       "another session's photo")
        XCTAssertEqual(b.take([ref(data, mime: "image/jpeg")], sessionId: "s1", viewer: "v1", now: t0),
                       .invalid(ImageAssembler.mismatchMessage))
    }

    func testAPhotoExpiresTwoMinutesAfterItsLastPiece() {
        let data = Data((0..<20).map { UInt8($0) })
        var a = ImageAssembler()
        let ps = parts(of: data)
        _ = a.add(ps[0], sessionId: "s1", viewer: "v1", now: t0)
        _ = a.add(ps[1], sessionId: "s1", viewer: "v1", now: t0.addingTimeInterval(100))
        XCTAssertEqual(a.openCount, 1, "100 s after the first piece, but the second refreshed it")
        a.prune(now: t0.addingTimeInterval(100 + ImageAssembler.ttl + 1))
        XCTAssertEqual(a.openCount, 0)
        XCTAssertEqual(a.take([ref(data)], sessionId: "s1", viewer: "v1", now: t0.addingTimeInterval(300)), .missing(["imageAAAA1"]))
    }

    func testAUsedPhotoCantBeReplayedForFifteenMinutes() {
        let data = Data((0..<10).map { UInt8($0) })
        var a = ImageAssembler()
        for p in parts(of: data) { _ = a.add(p, sessionId: "s1", viewer: "v1", now: t0) }
        guard case .ready = a.take([ref(data)], sessionId: "s1", viewer: "v1", now: t0) else { return XCTFail("not ready") }
        for p in parts(of: data) { XCTAssertEqual(a.add(p, sessionId: "s1", viewer: "v1", now: t0.addingTimeInterval(60)), .dropped("already used")) }
        XCTAssertEqual(a.take([ref(data)], sessionId: "s1", viewer: "v1", now: t0.addingTimeInterval(60)),
                       .invalid("That photo was already sent — send it again"))
        let later = t0.addingTimeInterval(ImageAssembler.consumedWindow + 1)
        XCTAssertEqual(a.add(parts(of: data)[0], sessionId: "s1", viewer: "v1", now: later), .stored)
    }

    func testOpenPhotosAndHeldBytesAreBounded() {
        var a = ImageAssembler()
        for i in 0..<ImageAssembler.maxOpen {
            let p = ImagePart(imageId: "imageOpen\(i)", index: 0, total: 2, bytes: 16, sha256: String(repeating: "a", count: 64),
                              mime: "image/png", data: Data(count: 8))
            XCTAssertEqual(a.add(p, sessionId: "s1", viewer: "v1", now: t0), .stored)
        }
        let ninth = ImagePart(imageId: "imageOpen9", index: 0, total: 2, bytes: 16, sha256: String(repeating: "a", count: 64),
                              mime: "image/png", data: Data(count: 8))
        XCTAssertEqual(a.add(ninth, sessionId: "s1", viewer: "v1", now: t0), .dropped("too many open photos"))

        var b = ImageAssembler()
        let chunk = Data(count: ImagePart.maxDataBytes)
        var added = 0
        outer: for img in 0..<7 {
            for i in 0..<32 {
                let p = ImagePart(imageId: "imageBig\(img)x", index: i, total: 32, bytes: ImageAssembler.maxBytes,
                                  sha256: String(repeating: "b", count: 64), mime: "image/png", data: chunk)
                let r = b.add(p, sessionId: "s1", viewer: "v1", now: t0)
                if r == .dropped("memory cap") { break outer }
                added += 1
            }
        }
        XCTAssertEqual(added * ImagePart.maxDataBytes, ImageAssembler.maxHeldBytes, "6 MiB held at most")
        XCTAssertLessThanOrEqual(b.heldBytes, ImageAssembler.maxHeldBytes)
    }

    func testMoreDataThanDeclaredSpoilsThePhoto() {
        var a = ImageAssembler()
        let p0 = ImagePart(imageId: "imageMore1", index: 0, total: 2, bytes: 10, sha256: String(repeating: "a", count: 64),
                           mime: "image/png", data: Data(count: 8))
        let p1 = ImagePart(imageId: "imageMore1", index: 1, total: 2, bytes: 10, sha256: String(repeating: "a", count: 64),
                           mime: "image/png", data: Data(count: 8))
        XCTAssertEqual(a.add(p0, sessionId: "s1", viewer: "v1", now: t0), .stored)
        XCTAssertEqual(a.add(p1, sessionId: "s1", viewer: "v1", now: t0), .spoiled("more data than declared"))
    }

    func testResetForgetsEverything() {
        var a = ImageAssembler()
        let data = Data((0..<10).map { UInt8($0) })
        _ = a.add(parts(of: data)[0], sessionId: "s1", viewer: "v1", now: t0)
        a.reset()
        XCTAssertEqual(a.openCount, 0)
    }

    // MARK: checking

    func testJPEGAndPNGPassByTheirOwnBytes() {
        XCTAssertEqual(ImageCheck.check(Self.image("public.png")), .success(.png))
        XCTAssertEqual(ImageCheck.check(Self.image("public.jpeg")), .success(.jpeg))
        XCTAssertEqual(ImageCheck.sniff(Self.image("public.png")), .png, "a PNG sent as image/jpeg is still a PNG")
        XCTAssertEqual(ImageCheck.Kind.jpeg.fileExtension, "jpg")
    }

    func testOtherFormatsAndBrokenFilesAreRefused() {
        XCTAssertEqual(ImageCheck.check(Self.image("public.tiff")), .failure(.init(detail: ImageCheck.notImageMessage)))
        XCTAssertEqual(ImageCheck.check(Self.image("com.compuserve.gif")), .failure(.init(detail: ImageCheck.notImageMessage)))
        XCTAssertEqual(ImageCheck.check(Data("hello".utf8)), .failure(.init(detail: ImageCheck.notImageMessage)))
        let png = Self.image("public.png")
        XCTAssertEqual(ImageCheck.check(png.prefix(20)), .failure(.init(detail: ImageCheck.unreadableMessage)), "a header with nothing behind it")
        XCTAssertEqual(ImageCheck.check(Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(count: 40)), .failure(.init(detail: ImageCheck.unreadableMessage)))
    }

    func testAPhotoWithLocationDataIsRefused() {
        let tagged = Self.image("public.jpeg", gps: true)
        let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(tagged as CFData, nil)!, 0, nil) as? [CFString: Any]
        XCTAssertNotNil(props?[kCGImagePropertyGPSDictionary], "the fixture carries GPS")
        XCTAssertEqual(ImageCheck.check(tagged), .failure(.init(detail: ImageCheck.locationMessage)))
        XCTAssertEqual(ImageCheck.check(Self.image("public.jpeg", gps: false)), .success(.jpeg))
    }

    func testLocationDataInAnyFrameOrTheFileIsFound() throws {
        let gps: [CFString: Any] = [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 51.5]]
        XCTAssertFalse(ImageCheck.hasLocation([[:]]))
        XCTAssertTrue(ImageCheck.hasLocation([[:], gps]), "a second picture (MPO) or the file's own properties")
        // A two-frame APNG without location data still passes: every frame is read, not refused for being there.
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out as CFMutableData, "public.png" as CFString, 2, nil))
        let frame = [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.1]] as CFDictionary
        CGImageDestinationAddImage(dest, ctx.makeImage()!, frame)
        CGImageDestinationAddImage(dest, ctx.makeImage()!, frame)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        XCTAssertEqual(CGImageSourceGetCount(CGImageSourceCreateWithData(out, nil)!), 2)
        XCTAssertEqual(ImageCheck.check(out as Data), .success(.png))
    }

    func testAnOversizedPhotoIsRefused() {
        XCTAssertEqual(ImageCheck.check(Self.image("public.png", width: 4097, height: 2)), .failure(.init(detail: ImageCheck.tooLargeMessage)))
    }

    // MARK: storage

    private func tempBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("page-imgstore-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return base
    }

    private func mode(_ path: String) -> Int {
        var st = stat()
        XCTAssertEqual(lstat(path, &st), 0)
        return Int(st.st_mode & 0o777)
    }

    func testAPhotoIsWrittenPrivatelyUnderARandomName() throws {
        let store = ImageStore(base: try tempBase())
        let data = Self.image()
        let path = try store.write(data, kind: .png, sessionId: "6f1f2b2e-6a54-4b52-9d2c-3f1f7d7b8a90").get()
        XCTAssertTrue(ImageStore.isSafePath(path), path)
        XCTAssertTrue(path.hasSuffix(".png"))
        XCTAssertTrue(path.contains("/page-images/6f1f2b2e-6a54-4b52-9d2c-3f1f7d7b8a90/"))
        XCTAssertEqual(FileManager.default.contents(atPath: path), data)
        XCTAssertEqual(mode(path), 0o600)
        let dir = (path as NSString).deletingLastPathComponent
        XCTAssertEqual(mode(dir), 0o700)
        XCTAssertEqual(mode((dir as NSString).deletingLastPathComponent), 0o700)
        XCTAssertEqual(realpath(path, nil).map { p -> String in defer { free(p) }; return String(cString: p) }, path, "canonical")
        let second = try store.write(data, kind: .jpeg, sessionId: "6f1f2b2e-6a54-4b52-9d2c-3f1f7d7b8a90").get()
        XCTAssertNotEqual(second, path)
        XCTAssertTrue(second.hasSuffix(".jpg"))
    }

    func testOnlyPlainAbsoluteImagePathsAreSafeToType() {
        XCTAssertTrue(ImageStore.isSafePath("/private/var/folders/cd/x_y/T/page-images/s1/abc-1.jpg"))
        XCTAssertFalse(ImageStore.isSafePath("relative/a.png"))
        XCTAssertFalse(ImageStore.isSafePath("/a b/c.png"), "no spaces")
        XCTAssertFalse(ImageStore.isSafePath("/a/b.gif"))
        XCTAssertFalse(ImageStore.isSafePath("/a/../b.png"))
        XCTAssertFalse(ImageStore.isSafePath("/a/b.png\n/c"))
        XCTAssertFalse(ImageStore.isSafePath("/a/$(x).png"))
    }

    func testAStrangeSessionIdBecomesAHashedFolderName() {
        XCTAssertEqual(ImageStore.folderName(forSession: "6f1f2b2e-6a54"), "6f1f2b2e-6a54")
        let odd = ImageStore.folderName(forSession: "../etc/passwd")
        XCTAssertTrue(odd.hasPrefix("s"))
        XCTAssertEqual(odd.count, 33)
        XCTAssertFalse(odd.contains("/"))
    }

    func testALinkInPlaceOfTheFolderIsRefused() throws {
        let base = try tempBase()
        let elsewhere = try tempBase()
        try FileManager.default.createSymbolicLink(atPath: base.appendingPathComponent(ImageStore.folderName).path,
                                                   withDestinationPath: elsewhere.path)
        let store = ImageStore(base: base)
        XCTAssertEqual(store.write(Self.image(), kind: .png, sessionId: "s1"), .failure(.init(detail: ImageStore.saveFailedMessage)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [], "nothing written through the link")
    }

    func testCleanupDeletesOldFilesAndEndedSessionsFolders() throws {
        let store = ImageStore(base: try tempBase())
        let now = Date()
        let live = try store.write(Self.image(), kind: .png, sessionId: "live1").get()
        let oldLive = try store.write(Self.image(), kind: .png, sessionId: "live1").get()
        let ended = try store.write(Self.image(), kind: .png, sessionId: "ended1").get()
        let endedFresh = try store.write(Self.image(), kind: .png, sessionId: "ended2").get()
        func age(_ path: String, _ seconds: TimeInterval) throws {
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-seconds)], ofItemAtPath: path)
        }
        try age(oldLive, ImageStore.maxAge + 60)
        try age(ended, ImageStore.endedSessionAge + 60)
        try age(endedFresh, 60)
        store.cleanup(now: now, live: ["live1"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: live))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldLive), "older than a day")
        XCTAssertFalse(FileManager.default.fileExists(atPath: (ended as NSString).deletingLastPathComponent), "an hour after the session ended")
        XCTAssertTrue(FileManager.default.fileExists(atPath: endedFresh), "the session ended under an hour ago")
    }

    func testWipeAndRemoveDeleteOnlyPagesOwnFiles() throws {
        let base = try tempBase()
        let store = ImageStore(base: base)
        let a = try store.write(Self.image(), kind: .png, sessionId: "s1").get()
        let outside = base.appendingPathComponent("keep.png").path
        FileManager.default.createFile(atPath: outside, contents: Data("x".utf8))
        store.remove([outside, a])
        XCTAssertFalse(FileManager.default.fileExists(atPath: a))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside), "only paths inside page-images")
        _ = try store.write(Self.image(), kind: .png, sessionId: "s2").get()
        store.wipeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside))
    }
}
