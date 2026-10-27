import XCTest
@testable import ClaudePowerMode

/// kitty.conf: the parser, the plan that turns a file into "add these lines",
/// the search for the file, the include reader, and enable / undo / setup
/// state against temp folders only. Every I/O call passes its URL, so nothing
/// here reads the real ~/.config/kitty.
final class KittyConfigFileTests: XCTestCase {
    private typealias K = KittyConfigFile

    private let allow = K.allowLine
    private let listen = K.listenLine
    private let marker = K.marker
    /// What Page appends to a file that already ends with a newline and a blank line.
    private var block: String { marker + "\n" + allow + "\n" + listen + "\n" }

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("kitty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var conf: URL { dir.appendingPathComponent("kitty.conf") }

    private func put(_ text: String, at url: URL? = nil, mode: Int = 0o644) throws {
        let target = url ?? conf
        try text.write(to: target, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
    }

    private func text(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    private func mode(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    }

    private func names() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }

    private func backups() -> [String] {
        names().filter { $0.hasPrefix("kitty.conf.bak-page-") }.sorted()
    }

    private func failure<T>(_ r: Result<T, K.Failure>) -> K.Failure? {
        if case .failure(let f) = r { return f }
        return nil
    }

    // MARK: parsing

    func testTheLastLineWinsAndCommentsDoNot() {
        let s = K.parse("# allow_remote_control no\nallow_remote_control yes\n")
        XCTAssertEqual(s.allowRemoteControl, "yes")
        XCTAssertEqual(s.allowLineNumber, 2)
    }

    func testALaterLineOverridesAnEarlierOne() {
        let s = K.parse("allow_remote_control no\nlisten_on tcp:a:1\nallow_remote_control socket-only\nlisten_on unix:/tmp/x\n")
        XCTAssertEqual(s.allowRemoteControl, "socket-only")
        XCTAssertEqual(s.allowLineNumber, 3)
        XCTAssertEqual(s.listenOn, "unix:/tmp/x")
        XCTAssertEqual(s.listenLineNumber, 4)
    }

    func testTabsIndentationAndCommentLinesAreHandled() {
        let s = K.parse("\tallow_remote_control\tsocket-only\n    listen_on   unix:/tmp/x  \n   # listen_on tcp:1:2\n")
        XCTAssertEqual(s.allowRemoteControl, "socket-only")
        XCTAssertEqual(s.allowLineNumber, 1)
        XCTAssertEqual(s.listenOn, "unix:/tmp/x")
        XCTAssertEqual(s.listenLineNumber, 2)
    }

    func testOtherSettingsAreIgnored() {
        XCTAssertEqual(K.parse("font_size 12\nmap ctrl+a new_window\n"), K.Settings())
    }

    // MARK: the plan

    func testWithNoFileItWritesBothLinesUnderTheMarker() {
        XCTAssertEqual(K.plan(text: nil), .write(text: block, added: [allow, listen]))
    }

    func testItAppendsAfterABlankLine() {
        XCTAssertEqual(K.plan(text: "font_size 12\n"), .write(text: "font_size 12\n\n" + block, added: [allow, listen]))
    }

    func testAFileWithoutATrailingNewlineGetsOneBeforeTheAppend() {
        XCTAssertEqual(K.plan(text: "font_size 12"), .write(text: "font_size 12\n\n" + block, added: [allow, listen]))
    }

    func testBothSettingsAlreadyRightIsAlreadyDone() {
        for value in ["socket-only", "socket", "yes"] {
            XCTAssertEqual(K.plan(text: "allow_remote_control \(value)\n\(listen)\n"), .alreadyDone, value)
        }
    }

    func testOnlyTheAllowLineMissingAddsOnlyTheListenLine() {
        XCTAssertEqual(K.plan(text: "allow_remote_control socket-only\n"),
                       .write(text: "allow_remote_control socket-only\n\n" + marker + "\n" + listen + "\n", added: [listen]))
    }

    func testAllowRemoteControlNoIsAConflictOnThatLine() {
        guard case .conflict(let why) = K.plan(text: "allow_remote_control no\n") else {
            return XCTFail("expected a conflict")
        }
        XCTAssertTrue(why.contains("line 1"), why)
    }

    func testATcpListenAddressIsAConflictOnThatLine() {
        guard case .conflict(let why) = K.plan(text: "allow_remote_control socket-only\nlisten_on tcp:localhost:1234\n") else {
            return XCTFail("expected a conflict")
        }
        XCTAssertTrue(why.contains("line 2"), why)
    }

    func testSettingsOnlyTheEffectiveTextHoldsCountAsDone() {
        XCTAssertEqual(K.plan(text: "font_size 12\n", effective: "allow_remote_control socket-only\n\(listen)\n"), .alreadyDone)
    }

    // MARK: taking the lines back out

    func testRemovingWhatThePlanAddedRestoresTheOriginal() {
        for original in ["font_size 12\n", "", "font_size 12\n\n", "map ctrl+a new_window\nfont_size 12\n"] {
            guard case .write(let written, _) = K.plan(text: original) else {
                return XCTFail("expected a write for \(original.debugDescription)")
            }
            XCTAssertEqual(K.removingPageLines(from: written), original, original.debugDescription)
        }
    }

    func testWithNoMarkerThereIsNothingToRemove() {
        XCTAssertNil(K.removingPageLines(from: "font_size 12\nallow_remote_control socket-only\n"))
    }

    func testALineTheUserChangedAfterTheMarkerIsKept() {
        let edited = "font_size 12\n\n" + marker + "\n" + allow + "\nlisten_on unix:/tmp/mine\n"
        XCTAssertEqual(K.removingPageLines(from: edited), "font_size 12\nlisten_on unix:/tmp/mine\n")
    }

    func testHasPageLinesOnlyWhenTheMarkerIsThere() {
        XCTAssertFalse(K.hasPageLines("allow_remote_control socket-only\n"))
        XCTAssertFalse(K.hasPageLines("# Added by Page: something else\n"))
        XCTAssertTrue(K.hasPageLines(block))
    }

    // MARK: where the file is

    func testTheKittyConfigDirectoryIsUsedWhenNothingExists() {
        let u = K.configURL(env: ["KITTY_CONFIG_DIRECTORY": "/k"], home: "/h", exists: { _ in false })
        XCTAssertEqual(u.path, "/k/kitty.conf")
    }

    func testTheFirstExistingFileInKittysOrderWins() {
        let u = K.configURL(env: ["KITTY_CONFIG_DIRECTORY": "/k", "XDG_CONFIG_HOME": "/x"],
                            home: "/h", exists: { $0 == "/x/kitty/kitty.conf" })
        XCTAssertEqual(u.path, "/x/kitty/kitty.conf")
    }

    func testTheLibraryPreferencesFileIsFound() {
        let u = K.configURL(env: [:], home: "/h", exists: { $0 == "/h/Library/Preferences/kitty/kitty.conf" })
        XCTAssertEqual(u.path, "/h/Library/Preferences/kitty/kitty.conf")
    }

    func testWithNothingThereTheDefaultIsDotConfig() {
        XCTAssertEqual(K.configURL(env: [:], home: "/h", exists: { _ in false }).path, "/h/.config/kitty/kitty.conf")
    }

    func testPlainIncludesResolveAgainstTheFilesFolder() {
        XCTAssertEqual(K.includePaths(in: "include colors.conf", baseDirectory: "/c"), ["/c/colors.conf"])
        XCTAssertEqual(K.includePaths(in: "include /abs/y.conf", baseDirectory: "/c"), ["/abs/y.conf"])
    }

    func testATildeInAnIncludeIsExpanded() {
        XCTAssertEqual(K.includePaths(in: "include ~/x.conf", baseDirectory: "/c"),
                       [("~/x.conf" as NSString).expandingTildeInPath])
    }

    func testGlobAndEnvironmentIncludesAreLeftToKitty() {
        XCTAssertEqual(K.includePaths(in: "globinclude *.conf\nenvinclude X\n# include nope.conf\n", baseDirectory: "/c"), [])
    }

    // MARK: the file (temp folders only)

    func testEnableBacksUpTheFileAndAppendsKeepingItsPermissions() throws {
        try put("font_size 12\n", mode: 0o644)
        let outcome = try K.enable(url: conf, now: Date(timeIntervalSince1970: 1_800_000_000)).get()
        XCTAssertEqual(outcome.added, [allow, listen])
        let backup = try XCTUnwrap(outcome.backup)
        XCTAssertTrue(backup.lastPathComponent.hasPrefix("kitty.conf.bak-page-"), backup.lastPathComponent)
        XCTAssertEqual(text(backup), "font_size 12\n")
        XCTAssertEqual(text(conf), "font_size 12\n\n" + block)
        XCTAssertEqual(mode(conf), 0o644)
        XCTAssertEqual(mode(backup), 0o644)
    }

    func testARestrictiveFileKeepsItsPermissionsAndItsBackupDoesToo() throws {
        try put("font_size 12\n", mode: 0o600)
        let outcome = try K.enable(url: conf).get()
        XCTAssertEqual(mode(conf), 0o600)
        XCTAssertEqual(mode(try XCTUnwrap(outcome.backup)), 0o600)
    }

    func testNoTempFileIsLeftBehind() throws {
        try put("font_size 12\n")
        _ = try K.enable(url: conf).get()
        XCTAssertEqual(names().filter { $0.hasPrefix(".kitty.conf.page-") }, [])
    }

    func testWithNoFileItCreatesOneWithNoBackup() throws {
        let outcome = try K.enable(url: conf).get()
        XCTAssertNil(outcome.backup)
        XCTAssertEqual(outcome.added, [allow, listen])
        XCTAssertEqual(text(conf), block)
        XCTAssertEqual(backups(), [])
    }

    func testItCreatesAMissingKittyFolder() throws {
        let nested = dir.appendingPathComponent("kitty/kitty.conf")
        _ = try K.enable(url: nested).get()
        XCTAssertEqual(text(nested), block)
    }

    func testASecondEnableChangesNothingAndMakesNoNewBackup() throws {
        try put("font_size 12\n")
        _ = try K.enable(url: conf).get()
        let after = text(conf)
        let second = try K.enable(url: conf).get()
        XCTAssertEqual(second.added, [])
        XCTAssertNil(second.backup)
        XCTAssertEqual(text(conf), after)
        XCTAssertEqual(backups().count, 1)
    }

    func testASymlinkedFileIsEditedWhereItLivesAndTheLinkStays() throws {
        let real = dir.appendingPathComponent("dotfiles-kitty.conf")
        try put("font_size 12\n", at: real)
        try FileManager.default.createSymbolicLink(atPath: conf.path, withDestinationPath: real.path)
        guard case .success(let p) = K.preview(url: conf) else { return XCTFail("preview should work through a link") }
        XCTAssertEqual(p.linkTarget?.lastPathComponent, "dotfiles-kitty.conf")
        let outcome = try K.enable(url: conf).get()
        XCTAssertEqual(outcome.url.lastPathComponent, "dotfiles-kitty.conf")
        XCTAssertEqual(text(real), "font_size 12\n\n" + block)
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: conf.path), "the link is still a link")
        XCTAssertEqual(names().filter { $0.hasPrefix("dotfiles-kitty.conf.bak-page-") }.count, 1)
        XCTAssertTrue(K.undo(url: conf))
        XCTAssertEqual(text(real), "font_size 12\n")
    }

    func testALinkToNowhereIsLeftAlone() throws {
        try FileManager.default.createSymbolicLink(atPath: conf.path, withDestinationPath: dir.appendingPathComponent("gone.conf").path)
        XCTAssertEqual(failure(K.enable(url: conf)), .symlink)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("gone.conf").path))
        XCTAssertFalse(K.undo(url: conf))
    }

    func testAConflictingFileIsUnchangedAndNoBackupIsMade() throws {
        try put("allow_remote_control no\n")
        let f = failure(K.enable(url: conf))
        guard case .conflict(let why)? = f else { return XCTFail("expected a conflict, got \(String(describing: f))") }
        XCTAssertTrue(why.contains("line 1"), why)
        XCTAssertEqual(text(conf), "allow_remote_control no\n")
        XCTAssertEqual(backups(), [])
    }

    func testUndoPutsTheOriginalBackAndKeepsACopyOfWhatItRemoves() throws {
        let original = "font_size 12\n"
        try put(original)
        _ = try K.enable(url: conf, now: Date(timeIntervalSince1970: 1_800_000_000)).get()
        let enabled = try XCTUnwrap(text(conf))
        XCTAssertTrue(K.undo(url: conf, now: Date(timeIntervalSince1970: 1_800_000_060)))
        XCTAssertEqual(text(conf), original)
        XCTAssertTrue(backups().contains { text(dir.appendingPathComponent($0)) == enabled },
                      "the file as it was before Undo is kept in a backup")
    }

    func testUndoWithNothingOfPagesInTheFileChangesNothing() throws {
        try put("font_size 12\n")
        XCTAssertFalse(K.undo(url: conf))
        XCTAssertEqual(text(conf), "font_size 12\n")
        XCTAssertEqual(backups(), [])
    }

    func testSetupStateFollowsTheFile() throws {
        guard case .needed = K.setupState(url: conf) else { return XCTFail("a missing file needs setup") }
        _ = try K.enable(url: conf).get()
        XCTAssertEqual(K.setupState(url: conf), .done)
    }

    func testSettingsInAnIncludedFileCountAsDone() throws {
        try put("allow_remote_control socket-only\nlisten_on unix:/tmp/x\n", at: dir.appendingPathComponent("colors.conf"))
        try put("include colors.conf\n")
        XCTAssertEqual(K.setupState(url: conf), .done)
        XCTAssertEqual(try K.enable(url: conf).get().added, [])
        XCTAssertEqual(text(conf), "include colors.conf\n")
    }

    // MARK: includes, links, backups and line endings

    /// A conflict in an included file names that file and its own line.
    func testAConflictInAnIncludedFileNamesThatFile() throws {
        try put("font_size 12\nallow_remote_control no\n", at: dir.appendingPathComponent("colors.conf"))
        try put("include colors.conf\n")
        guard case .needed(let why) = K.setupState(url: conf) else { return XCTFail("expected needed") }
        XCTAssertTrue(why.contains("colors.conf line 2"), why)
        XCTAssertFalse(why.contains("kitty.conf"), why)
    }

    /// A kitty.conf that is a symlink and already has the settings counts as done.
    func testASymlinkedFileThatAlreadyHasTheSettingsIsDone() throws {
        let real = dir.appendingPathComponent("dotfiles-kitty.conf")
        try put("allow_remote_control socket-only\n\(listen)\n", at: real)
        try FileManager.default.createSymbolicLink(atPath: conf.path, withDestinationPath: real.path)
        XCTAssertEqual(K.setupState(url: conf), .done)
    }

    /// The copy made before Undo doesn't overwrite the copy made by Set up in
    /// the same second.
    func testUndoInTheSameSecondKeepsTheBackupOfTheOriginal() throws {
        let original = "font_size 12\n"
        try put(original)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try K.enable(url: conf, now: now).get()
        XCTAssertTrue(K.undo(url: conf, now: now))
        XCTAssertTrue(backups().contains { text(dir.appendingPathComponent($0)) == original },
                      "the pre-Page copy survives; backups: \(backups())")
    }

    /// Windows line endings are read like any other.
    func testWindowsLineEndingsAreReadLikeAnyOther() {
        XCTAssertEqual(K.plan(text: "allow_remote_control socket-only\r\n\(listen)\r\n"), .alreadyDone)
    }

    func testWindowsLineEndingsKeepTheirLineNumbersAndIncludes() throws {
        let s = K.parse("font_size 12\r\nallow_remote_control no\r\n")
        XCTAssertEqual(s.allowRemoteControl, "no")
        XCTAssertEqual(s.allowLineNumber, 2)
        XCTAssertEqual(K.includePaths(in: "include a.conf\r\ninclude b.conf\r\n", baseDirectory: "/k"), ["/k/a.conf", "/k/b.conf"])
        try put("allow_remote_control socket-only\r\n\(listen)\r\n", at: dir.appendingPathComponent("w.conf"))
        try put("include w.conf\r\n")
        XCTAssertEqual(K.setupState(url: conf), .done)
    }

    func testPagesLinesComeOutOfAWindowsFile() throws {
        try put("font_size 12\r\n")
        _ = try K.enable(url: conf).get()
        XCTAssertTrue(K.hasPageLines(at: conf))
        XCTAssertTrue(K.undo(url: conf))
        XCTAssertEqual(text(conf), "font_size 12\r\n")
    }

    func testKittysOtherSpellingsOfYesAreAccepted() {
        for value in ["y", "yes", "true", "socket", "socket-only"] {
            XCTAssertEqual(K.plan(text: "allow_remote_control \(value)\n\(listen)\n"), .alreadyDone, value)
        }
    }

    func testPasswordAndNoStayConflicts() {
        for value in ["password", "no"] {
            guard case .conflict = K.plan(text: "allow_remote_control \(value)\n\(listen)\n") else {
                return XCTFail("\(value) should be a conflict")
            }
        }
    }

    func testSeveralActionsInOneSecondEachKeepTheirOwnBackup() throws {
        try put("font_size 12\n")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try K.enable(url: conf, now: now).get()
        XCTAssertTrue(K.undo(url: conf, now: now))
        _ = try K.enable(url: conf, now: now).get()
        XCTAssertTrue(K.undo(url: conf, now: now))
        XCTAssertEqual(backups().count, 4)
        XCTAssertEqual(Set(backups()).count, 4)
    }
}
