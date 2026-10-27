import XCTest
@testable import ClaudePowerMode
import PageWidgetSupport

/// The file side of the widgets: what lands in the group folder, how often
/// WidgetKit is asked to reload, and the quit note. A temp folder and a
/// synchronous queue; the timers are never started.
final class WidgetPublisherTests: XCTestCase {
    /// Shared with the publisher's closures, so no test object is captured.
    private final class Box {
        var reloads = 0
        var now = Date(timeIntervalSince1970: 1_790_000_000)
    }

    private var dir: URL!
    private var box: Box!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PageWidgetPublisherTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        box = Box()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func publisher(folder: URL? = nil) -> WidgetPublisher {
        let target = folder ?? dir
        let box = self.box!
        return WidgetPublisher(directory: { target }, reload: { box.reloads += 1 }, clock: { box.now }, queue: nil)
    }

    private func onDisk() -> WidgetSnapshot? { WidgetSnapshotStore.load(from: dir) }

    func testAnOfferWritesTheFileAndReloadsOnce() throws {
        let p = publisher()
        p.offer(WidgetFixtures.needsYou(now: box.now))
        XCTAssertEqual(p.writes, 1)
        XCTAssertEqual(box.reloads, 1)
        var expected = WidgetFixtures.needsYou(now: box.now)
        expected.writtenAt = box.now
        XCTAssertEqual(onDisk(), expected.bounded())
    }

    func testTheSameStateAgainWithinAMinuteWritesAndReloadsNothingMore() {
        let p = publisher()
        let same = WidgetFixtures.quiet(now: box.now)
        p.offer(same)
        box.now.addTimeInterval(30)
        p.offer(same)
        XCTAssertEqual(p.writes, 1)
        XCTAssertEqual(box.reloads, 1)
    }

    func testAChangeAfterAFewSecondsIsWrittenWithTheNewState() {
        let p = publisher()
        p.offer(WidgetFixtures.working(now: box.now))
        box.now.addTimeInterval(6)
        p.offer(WidgetFixtures.needsYou(now: box.now))
        XCTAssertEqual(p.writes, 2)
        XCTAssertEqual(onDisk()?.mood, .needsYou)
    }

    func testRefreshNowWritesAndReloadsWhateverTheThrottle() {
        let p = publisher()
        p.offer(WidgetFixtures.quiet(now: box.now))
        p.refreshNow()
        XCTAssertEqual(p.writes, 2)
        XCTAssertEqual(box.reloads, 2)
    }

    func testRefreshWithNothingOfferedDoesNothing() {
        let p = publisher()
        p.refreshNow()
        XCTAssertEqual(p.writes, 0)
        XCTAssertEqual(box.reloads, 0)
        XCTAssertNil(onDisk())
    }

    func testTheQuitNoteKeepsTheLastNumbersAndSaysNotRunning() {
        let p = publisher()
        p.offer(WidgetFixtures.needsYou(now: box.now))
        box.now.addTimeInterval(120)
        p.publishQuit()
        let note = onDisk()
        XCTAssertEqual(note?.running, false)
        XCTAssertEqual(note?.needYou, WidgetFixtures.needsYou(now: box.now).needYou)
        XCTAssertEqual(note?.writtenAt, box.now)
        XCTAssertEqual(note.map { $0.freshness(now: box.now) }, .notRunning)
        XCTAssertEqual(box.reloads, 2, "the quit note is reloaded so the widgets show it")
    }

    func testQuitWithNothingOfferedWritesNothing() {
        let p = publisher()
        p.publishQuit()
        XCTAssertEqual(p.writes, 0)
        XCTAssertNil(onDisk())
    }
}
