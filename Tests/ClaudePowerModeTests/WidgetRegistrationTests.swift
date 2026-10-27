import XCTest
import PageWidgetSupport

/// Whether macOS knows Page's widget extension, read from pluginkit's output
/// (pure parsing; the process runs elsewhere), and where System Settings keeps
/// the widget switches.
final class WidgetRegistrationTests: XCTestCase {
    private let appex = "/Applications/Page.app/Contents/PlugIns/PageWidgets.appex"
    private let id = PageWidgetConstants.extensionBundleID

    /// The `pluginkit -m -A -D -v` shape: flag column, id(version), uuid, date, path; tab separated.
    private func line(_ flag: String, path: String, id: String = "local.Page.widgets", version: String = "1.0") -> String {
        "\(flag.isEmpty ? "     " : "   " + flag + "  ")\(id)(\(version))\t6F1C0B2E-3D4A-4B8C-9E21-7A5D0C9F1B22\t2026-10-27 09:12:44 +0000\t\(path)"
    }

    private func parse(_ output: String, expected: String? = nil) -> WidgetRegistration.Status {
        WidgetRegistration.parse(pluginkitOutput: output, expectedPath: expected)
    }

    // MARK: what the parser reads

    func testNothingListedIsNotRegistered() {
        XCTAssertEqual(parse("", expected: appex), .notRegistered)
        XCTAssertEqual(parse("\n\n", expected: appex), .notRegistered)
    }

    func testOtherPeoplesWidgetsAreNotPage() {
        let other = "      com.checkitt.widget(3.0.4)\tAF0ACFC5-C1E1-4D16-AFE3-246C8D9D5E41\t2026-08-29 10:41:54 +0000\t/Applications/Ground News.app/Contents/PlugIns/Widget.appex"
        XCTAssertEqual(parse(other, expected: appex), .notRegistered)
    }

    func testAnIdWhoseNameOnlyStartsTheSameIsNotPage() {
        let longer = line("+", path: appex, id: "local.Page.widgets.extra")
        XCTAssertEqual(parse(longer, expected: appex), .notRegistered)
    }

    func testALineWithNoPathIsSkipped() {
        XCTAssertEqual(parse("+   local.Page.widgets(1.0)", expected: appex), .notRegistered)
    }

    func testOnAtTheExpectedPathIsRegistered() {
        XCTAssertEqual(parse(line("+", path: appex), expected: appex), .registered(path: appex))
    }

    func testBlankAndQuestionMarkFlagsCountAsOn() {
        XCTAssertEqual(parse(line("", path: appex), expected: appex), .registered(path: appex))
        XCTAssertEqual(parse(line("?", path: appex), expected: appex), .registered(path: appex))
    }

    func testSwitchedOffIsDisabled() {
        XCTAssertEqual(parse(line("-", path: appex), expected: appex), .disabled(path: appex))
    }

    /// `man pluginkit`: `!` is "elected to use the plug-in for debugger use", so it is in use.
    func testElectedForDebuggerUseIsRegistered() {
        XCTAssertEqual(parse(line("!", path: appex), expected: appex), .registered(path: appex))
    }

    /// `=` is "superseded by another plug-in": macOS uses another copy, so this one is not the one showing.
    func testSupersededByAnotherCopyIsElsewhere() {
        let other = "/Users/someone/build/Page.app/Contents/PlugIns/PageWidgets.appex"
        let output = [line("=", path: appex), line("+", path: other)].joined(separator: "\n")
        XCTAssertEqual(parse(output, expected: appex), .elsewhere(path: other))
        XCTAssertEqual(parse(line("=", path: appex), expected: appex), .elsewhere(path: appex),
                       "with no other copy listed it still is not plain registered")
    }

    func testAnotherCopysPathIsElsewhere() {
        let build = "/Users/someone/projects/mac-on-claude-code/build/Page.app/Contents/PlugIns/PageWidgets.appex"
        XCTAssertEqual(parse(line("+", path: build), expected: appex), .elsewhere(path: build))
    }

    func testTheLineForThisCopyWinsOverAnotherCopy() {
        let build = "/Users/someone/build/Page.app/Contents/PlugIns/PageWidgets.appex"
        let output = [line("-", path: build), line("+", path: appex)].joined(separator: "\n")
        XCTAssertEqual(parse(output, expected: appex), .registered(path: appex))
    }

    func testWithoutAnExpectedPathTheFirstLineIsTaken() {
        XCTAssertEqual(parse(line("-", path: appex), expected: nil), .disabled(path: appex))
    }

    func testSymlinkedAndPrivateAliasesCountAsTheSameCopy() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PageRegistrationAlias-\(UUID().uuidString)", isDirectory: true)
        let appexFolder = folder.appendingPathComponent("Page.app/Contents/PlugIns/PageWidgets.appex", isDirectory: true)
        try FileManager.default.createDirectory(at: appexFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let expected = appexFolder.path
        // /var is a symlink to /private/var on macOS: the same folder under its other name.
        guard expected.hasPrefix("/var/") else { throw XCTSkip("temporary folder is not under /var") }
        let alias = "/private" + expected
        XCTAssertEqual(parse(line("+", path: alias), expected: expected), .registered(path: alias))
    }

    func testOnlyTheIdentifierLineCounts() {
        let other = line("+", path: appex, id: "local.Other.widgets")
        XCTAssertEqual(parse(other, expected: appex), .notRegistered)
    }

    // MARK: the words

    func testEveryStatusHasWordsAndOnlyRegisteredIsGood() {
        let statuses: [WidgetRegistration.Status] = [
            .checking, .registered(path: appex), .disabled(path: appex), .elsewhere(path: appex),
            .notRegistered, .unavailable(reason: "No widgets in this copy of Page"),
        ]
        for s in statuses {
            let l = WidgetRegistration.line(s)
            XCTAssertFalse(l.text.isEmpty, "\(s) has no words")
            XCTAssertEqual(l.good, s == .registered(path: appex), "\(s) has the wrong colour")
        }
    }

    func testUnavailableShowsItsOwnReason() {
        XCTAssertEqual(WidgetRegistration.line(.unavailable(reason: "Built without widgets")).text, "Built without widgets")
    }

    func testAbbreviateShortensAHomeFolderPathAndDropsThePlugInTail() {
        let path = "/Users/roysinclair/Downloads/Page.app/Contents/PlugIns/PageWidgets.appex"
        XCTAssertEqual(WidgetRegistration.abbreviate(path, home: "/Users/roysinclair"), "~/Downloads/Page.app")
        XCTAssertEqual(WidgetRegistration.abbreviate("/Applications/Page.app/Contents/PlugIns/PageWidgets.appex",
                                                     home: "/Users/roysinclair"), "/Applications/Page.app")
    }

    /// Probe: the home test is a plain prefix, so a sibling folder such as
    /// /Users/roysinclairX reads as "~X/…", which is wrong.
    func testAbbreviateDoesNotTreatASiblingFolderAsHome() {
        let path = "/Users/roysinclairX/Page.app/Contents/PlugIns/PageWidgets.appex"
        XCTAssertEqual(WidgetRegistration.abbreviate(path, home: "/Users/roysinclair"), "/Users/roysinclairX/Page.app")
    }

    // MARK: where System Settings keeps them

    func testSettingsOpensDesktopAndDockFromMacOS13() {
        XCTAssertEqual(WidgetRegistration.settingsURL(osMajor: 14).absoluteString,
                       "x-apple.systempreferences:com.apple.Desktop-Settings.extension")
        XCTAssertEqual(WidgetRegistration.settingsURL(osMajor: 15).absoluteString,
                       "x-apple.systempreferences:com.apple.Desktop-Settings.extension")
        XCTAssertEqual(WidgetRegistration.settingsURL(osMajor: 12).absoluteString,
                       "x-apple.systempreferences:com.apple.preference.dock")
    }

    func testSettingsPathNamesTheRightPlace() {
        XCTAssertEqual(WidgetRegistration.settingsPath(osMajor: 14), "System Settings → Desktop & Dock → Widgets")
        XCTAssertEqual(WidgetRegistration.settingsPath(osMajor: 13), "System Settings → Desktop & Dock")
        XCTAssertEqual(WidgetRegistration.settingsPath(osMajor: 12), "System Preferences → Dock")
    }

    func testDesktopWidgetsStartAtMacOS14() {
        XCTAssertFalse(WidgetRegistration.hasDesktopWidgets(osMajor: 13))
        XCTAssertTrue(WidgetRegistration.hasDesktopWidgets(osMajor: 14))
    }

    func testExtensionSitsInsideTheAppsPlugIns() {
        XCTAssertEqual(WidgetRegistration.extensionPath(inApp: "/Applications/Page.app"), appex)
        XCTAssertEqual(PageWidgetConstants.extensionBundleID, id)
    }
}
