import XCTest
@testable import ClaudePowerMode
import PageWidgetSupport

/// Telling macOS about the widgets: which bundle is asked about, which
/// commands run, and that nothing runs for a copy that has no widgets.
/// Fake app bundles in a temp folder and a recording runner; no real
/// pluginkit, lsregister or Page.app is touched.
final class WidgetSetupTests: XCTestCase {
    /// Records every command and answers from a fixed reply.
    private final class Recorder {
        var calls: [(path: String, args: [String])] = []
        var pluginkitStdout = ""
        var launched = true

        func run(_ path: String, _ args: [String]) -> ProcessRunner.Result {
            calls.append((path, args))
            return ProcessRunner.Result(status: 0, stdout: pluginkitStdout, stderr: "", timedOut: false, launched: launched)
        }

        var lsregisterCalls: [[String]] { calls.filter { $0.path == WidgetSetup.lsregister }.map(\.args) }
        var pluginkitAdds: [[String]] { calls.filter { $0.path == WidgetSetup.pluginkit && $0.args.first == "-a" }.map(\.args) }
    }

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PageWidgetSetupTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// A fake Page.app: an Info.plist (with the group key when given) and, when asked, the widget folder.
    private func makeApp(group: String?, withExtension: Bool = true, name: String = "Page") throws -> Bundle {
        let app = root.appendingPathComponent("\(name)-\(UUID().uuidString).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": "local.Page", "CFBundleName": "Page",
                                   "CFBundleExecutable": "Page", "CFBundlePackageType": "APPL"]
        if let group { info[PageWidgetConstants.groupInfoKey] = group }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        if withExtension {
            try FileManager.default.createDirectory(
                at: contents.appendingPathComponent("PlugIns/\(PageWidgetConstants.extensionName)", isDirectory: true),
                withIntermediateDirectories: true)
        }
        return try XCTUnwrap(Bundle(path: app.path))
    }

    private let group = "RQRMN9LT93.\(PageWidgetConstants.groupSuffix)"

    // MARK: what counts as a Page that can have widgets

    func testAFullyBuiltSignedAppHasNoReason() throws {
        let app = try makeApp(group: group)
        XCTAssertNil(WidgetSetup.unavailableReason(bundle: app))
        XCTAssertEqual(WidgetSetup.bundledExtension(bundle: app)?.appex,
                       WidgetRegistration.extensionPath(inApp: app.bundlePath))
    }

    func testAnAppWithoutItsExtensionSaysItWasBuiltWithoutWidgets() throws {
        let app = try makeApp(group: group, withExtension: false)
        XCTAssertNil(WidgetSetup.bundledExtension(bundle: app))
        XCTAssertEqual(WidgetSetup.unavailableReason(bundle: app)?.contains("without its widgets"), true)
    }

    func testAnUnsignedAppSaysItHasNoTeamForItsGroup() throws {
        let app = try makeApp(group: nil)
        XCTAssertEqual(WidgetSetup.unavailableReason(bundle: app)?.contains("developer team"), true)
    }

    func testAGroupWithoutTheTeamPrefixIsNotUsed() throws {
        let app = try makeApp(group: PageWidgetConstants.groupSuffix)
        XCTAssertNil(PageWidgetConstants.appGroup(bundle: app))
        XCTAssertNotNil(WidgetSetup.unavailableReason(bundle: app))
    }

    func testABuildFolderIsNotAnAppWithWidgets() throws {
        let folder = root.appendingPathComponent("build-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let bundle = try XCTUnwrap(Bundle(path: folder.path))
        XCTAssertEqual(WidgetSetup.unavailableReason(bundle: bundle)?.contains("isn’t an app"), true)
    }

    // MARK: status

    func testStatusAsksPluginkitAboutThisIdAndReadsItsAnswer() throws {
        let app = try makeApp(group: group)
        let appex = WidgetRegistration.extensionPath(inApp: app.bundlePath)
        let rec = Recorder()
        rec.pluginkitStdout = "      \(PageWidgetConstants.extensionBundleID)(1.0)\t6F1C0B2E-3D4A-4B8C-9E21-7A5D0C9F1B22\t2026-10-27 09:12:44 +0000\t\(appex)\n"
        let status = WidgetSetup.status(bundle: app, run: rec.run)
        XCTAssertEqual(status, .registered(path: appex))
        let query = try XCTUnwrap(rec.calls.first)
        XCTAssertEqual(query.path, WidgetSetup.pluginkit)
        XCTAssertTrue(query.args.contains("-m"))
        XCTAssertEqual(query.args.last, PageWidgetConstants.extensionBundleID)
    }

    func testStatusWhenPluginkitDoesNotAnswerSaysSo() throws {
        let app = try makeApp(group: group)
        let rec = Recorder()
        rec.launched = false
        if case .unavailable = WidgetSetup.status(bundle: app, run: rec.run) {} else {
            XCTFail("a pluginkit that cannot launch should read as unavailable, not as not registered")
        }
    }

    func testStatusOfACopyWithoutWidgetsRunsNothing() throws {
        let app = try makeApp(group: nil)
        let rec = Recorder()
        _ = WidgetSetup.status(bundle: app, run: rec.run)
        XCTAssertTrue(rec.calls.isEmpty)
    }

    // MARK: register

    func testRegisterTellsLaunchServicesThenPluginkitThenLooksAgain() throws {
        let app = try makeApp(group: group)
        let appex = WidgetRegistration.extensionPath(inApp: app.bundlePath)
        let rec = Recorder()
        rec.pluginkitStdout = "+    \(PageWidgetConstants.extensionBundleID)(1.0)\t6F1C0B2E\t2026-10-27 09:12:44 +0000\t\(appex)\n"
        let status = WidgetSetup.register(bundle: app, run: rec.run)
        XCTAssertEqual(status, .registered(path: appex))
        XCTAssertEqual(rec.lsregisterCalls.first?.last, app.bundlePath, "LaunchServices is told about this app")
        XCTAssertEqual(rec.pluginkitAdds, [["-a", appex]], "pluginkit is told about this extension, and only this one")
    }

    /// Probe: the spike showed pluginkit listed the extension only after
    /// `lsregister -f -R -trusted <app>`, and `pluginkit -a` alone did nothing.
    func testLaunchServicesIsAskedForATrustedRecursiveRegistration() throws {
        let app = try makeApp(group: group)
        let rec = Recorder()
        _ = WidgetSetup.register(bundle: app, run: rec.run)
        let args = try XCTUnwrap(rec.lsregisterCalls.first)
        XCTAssertTrue(args.contains("-R"), "lsregister needs -R to see the extension inside the app")
        XCTAssertTrue(args.contains("-trusted"), "lsregister needs -trusted for pluginkit to list it")
    }

    func testRegisterForACopyWithoutWidgetsTouchesNothingButAStatusCheck() throws {
        let app = try makeApp(group: group, withExtension: false)
        let rec = Recorder()
        let status = WidgetSetup.register(bundle: app, run: rec.run)
        XCTAssertTrue(rec.lsregisterCalls.isEmpty)
        XCTAssertTrue(rec.pluginkitAdds.isEmpty)
        XCTAssertNotEqual(status, .registered(path: ""), "no widgets, so nothing is registered")
    }
}
