import XCTest
@testable import ClaudePowerMode
import PageWidgetSupport

/// The Tower's Widgets page and the widgets' look: the steps for each macOS,
/// the catalogue of what Page offers, the palette the widgets share with the
/// app, and the entitlements and URL scheme the build must carry.
final class WidgetTowerTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ClaudePowerModeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    private func plist(_ relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent(relativePath))
        return try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    // MARK: the steps

    func testDesktopStepsAreThreeAndEndWithDragging() {
        let steps = WidgetGuide.steps(osMajor: 14)
        XCTAssertEqual(steps.map(\.number), [1, 2, 3])
        XCTAssertEqual(steps.map(\.title), ["Right-click the desktop", "Search for Page", "Drag one out"])
        XCTAssertTrue(steps.allSatisfy { !$0.detail.isEmpty })
    }

    func testNotificationCenterStepsBeforeMacOS14() {
        let steps = WidgetGuide.steps(osMajor: 13)
        XCTAssertEqual(steps.map(\.number), [1, 2, 3])
        XCTAssertEqual(steps.first?.title, "Open Notification Center")
        XCTAssertNil(WidgetGuide.notificationCenterLine(osMajor: 13))
        XCTAssertNil(WidgetGuide.iPhoneNote(osMajor: 13))
        XCTAssertNotNil(WidgetGuide.notificationCenterLine(osMajor: 14))
        XCTAssertNotNil(WidgetGuide.iPhoneNote(osMajor: 14))
    }

    func testTheStepsMatchWhereSystemSettingsKeepsThem() {
        // The guide and the "Open widget settings" button must agree about desktop widgets.
        for major in [12, 13, 14, 15] {
            XCTAssertEqual(WidgetGuide.steps(osMajor: major).first?.title == "Right-click the desktop",
                           WidgetRegistration.hasDesktopWidgets(osMajor: major), "macOS \(major)")
        }
    }

    // MARK: the catalogue

    func testTheCatalogueOffersTwoWidgetsInTheirSizes() {
        XCTAssertEqual(WidgetCatalog.all.map(\.name), ["Page", "Claude usage"])
        XCTAssertEqual(WidgetCatalog.status.sizes, [.small, .medium, .large])
        XCTAssertEqual(WidgetCatalog.usage.sizes, [.small, .medium])
        XCTAssertEqual(Set(WidgetCatalog.all.map(\.kind)).count, 2)
        XCTAssertEqual(WidgetCatalog.status.kind, PageWidgetConstants.statusKind)
        XCTAssertEqual(WidgetCatalog.usage.kind, PageWidgetConstants.usageKind)
    }

    func testEveryCatalogueEntryHasAShortDetail() {
        for entry in WidgetCatalog.all {
            XCTAssertFalse(entry.detail.isEmpty)
            XCTAssertLessThanOrEqual(entry.detail.count, 100, "\(entry.name) detail is too long for the Tower")
        }
    }

    // MARK: palette

    /// The extension cannot link the app's Theme, so its numbers are copied; this keeps them equal.
    func testTheWidgetPaletteIsTheAppsNightWatchPalette() {
        let pairs: [(String, WidgetPalette.RGBA, NightWatch.RGBA)] = [
            ("background", WidgetPalette.background, NightWatch.Palette.background),
            ("backgroundDeep", WidgetPalette.backgroundDeep, NightWatch.Palette.backgroundDeep),
            ("surface", WidgetPalette.surface, NightWatch.Palette.surface),
            ("textPrimary", WidgetPalette.textPrimary, NightWatch.Palette.textPrimary),
            ("textSecondary", WidgetPalette.textSecondary, NightWatch.Palette.textSecondary),
            ("textTertiary", WidgetPalette.textTertiary, NightWatch.Palette.textTertiary),
            ("textQuiet", WidgetPalette.textQuiet, NightWatch.Palette.textQuiet),
            ("red", WidgetPalette.red, NightWatch.Palette.red),
            ("amber", WidgetPalette.amber, NightWatch.Palette.amber),
            ("green", WidgetPalette.green, NightWatch.Palette.green),
            ("teal", WidgetPalette.teal, NightWatch.Palette.teal),
            ("sky", WidgetPalette.sky, NightWatch.Palette.sky),
            ("violet", WidgetPalette.violet, NightWatch.Palette.violet),
            ("glass", WidgetPalette.glass, NightWatch.Palette.glass),
            ("star", WidgetPalette.star, NightWatch.Palette.star),
        ]
        for (name, w, a) in pairs {
            XCTAssertEqual(w.r, a.r, accuracy: 1e-9, "\(name) red")
            XCTAssertEqual(w.g, a.g, accuracy: 1e-9, "\(name) green")
            XCTAssertEqual(w.b, a.b, accuracy: 1e-9, "\(name) blue")
            XCTAssertEqual(w.a, a.a, accuracy: 1e-9, "\(name) alpha")
        }
    }

    func testEveryToneHasAColour() {
        for tone in [WidgetTone.needsYou, .working, .quiet, .paused, .asleep] {
            XCTAssertGreaterThan(WidgetPalette.color(for: tone).a, 0, "\(tone) is invisible")
        }
    }

    // MARK: the build's wiring

    func testBothEntitlementFilesPutTheWidgetsInTheSameGroup() throws {
        let group = "$(PAGE_TEAM_ID).\(PageWidgetConstants.groupSuffix)"
        let widget = try plist("Resources/PageWidgets.entitlements")
        let app = try plist("Resources/Page.entitlements")
        XCTAssertEqual(widget["com.apple.security.application-groups"] as? [String], [group])
        XCTAssertEqual(app["com.apple.security.application-groups"] as? [String], [group])
        XCTAssertEqual(widget["com.apple.security.app-sandbox"] as? Bool, true, "a WidgetKit extension must be sandboxed")
        XCTAssertNil(widget["com.apple.security.network.client"], "the widget has no network")
    }

    func testTheAppAndTheWidgetAgreeOnTheURLSchemeAndInfoKey() throws {
        let build = try String(contentsOf: repoRoot.appendingPathComponent("build.sh"), encoding: .utf8)
        XCTAssertTrue(build.contains(PageWidgetConstants.urlScheme), "build.sh registers the page-mac scheme")
        XCTAssertTrue(build.contains(PageWidgetConstants.groupInfoKey), "build.sh writes the group Info key")
        XCTAssertTrue(build.contains("PlugIns/\(PageWidgetConstants.extensionName)"), "build.sh puts the widget in PlugIns")
    }

    func testTheExtensionIdIsTheAppIdWithWidgets() {
        XCTAssertEqual(PageWidgetConstants.extensionBundleID, "local.Page.widgets")
        XCTAssertEqual(PageWidgetConstants.appGroup(bundle: Bundle(for: WidgetTowerTests.self)), nil,
                       "the test bundle has no group, so no widget data path opens")
    }
}

/// The large widget's row budget, the Widgets page's honesty about System Settings, and the hints.
final class WidgetLargeAndPageTests: XCTestCase {
    func testLargeRowsCountHeadersAndMoreLines() {
        // The reviewer's case: 2 decisions, 4 working, one more working: it used to draw 2 + 4 and overflow.
        let r = WidgetDisplay.largeRows(decisions: 2, inFlight: 4, moreWorking: true)
        XCTAssertEqual(r.decisions, 2)
        XCTAssertLessThan(r.inFlight, 4)
        XCTAssertGreaterThanOrEqual(r.inFlight, 1)
        func cost(_ d: Int, _ f: Int, moreD: Bool, moreF: Bool) -> Double {
            let L = WidgetDisplay.LargeLayout.self
            var t = 0.0
            if d > 0 { t += L.header + Double(d) * L.row + (moreD ? L.more : 0) }
            if f > 0 { t += L.header + Double(f) * L.row + (moreF ? L.more : 0) }
            if d > 0 && f > 0 { t += L.gap }
            return t
        }
        // The desktop's two large widgets: 364x382 and, on a smaller display, 329x345, each inside 16-point margins.
        for inner in [350.0, 313.0] {
            let room = WidgetDisplay.LargeLayout.room(forInnerHeight: inner)
            for d in 0...6 { for f in 0...6 {
                let rows = WidgetDisplay.largeRows(decisions: d, inFlight: f, room: room)
                XCTAssertLessThanOrEqual(rows.decisions, d)
                XCTAssertLessThanOrEqual(rows.inFlight, f)
                if d > 0 { XCTAssertGreaterThanOrEqual(rows.decisions, 1, "a waiting decision always shows") }
                let c = cost(rows.decisions, rows.inFlight, moreD: d > rows.decisions, moreF: f > rows.inFlight)
                // Over the room only when the one forced row (a waiting decision) does not fit at all.
                if rows.decisions + rows.inFlight > 1 {
                    XCTAssertLessThanOrEqual(c, room, "\(d) decisions, \(f) working in \(inner)pt")
                }
            } }
        }
    }

    func testLargeRoomIsWhatTheInnerHeightLeaves() {
        XCTAssertEqual(WidgetDisplay.LargeLayout.room(forInnerHeight: 350), WidgetDisplay.LargeLayout.room, "the 364x382 widget")
        XCTAssertEqual(WidgetDisplay.LargeLayout.room(forInnerHeight: 313), 199, "the 329x345 widget")
        XCTAssertEqual(WidgetDisplay.LargeLayout.room(forInnerHeight: 40), 0, "never negative")
        // The smaller widget shows fewer rows than the bigger one for the same snapshot.
        let big = WidgetDisplay.largeRows(decisions: 3, inFlight: 3, room: WidgetDisplay.LargeLayout.room(forInnerHeight: 350))
        let small = WidgetDisplay.largeRows(decisions: 3, inFlight: 3, room: WidgetDisplay.LargeLayout.room(forInnerHeight: 313))
        XCTAssertLessThan(small.decisions + small.inFlight, big.decisions + big.inFlight)
    }

    func testTheSafeInsetOnlyAddsWhatTheSystemMarginLacks() {
        XCTAssertEqual(WidgetInset.extra(systemMargin: 16), 0, "a normal system margin is never doubled")
        XCTAssertEqual(WidgetInset.extra(systemMargin: WidgetInset.minimum), 0)
        XCTAssertEqual(WidgetInset.extra(systemMargin: 0), WidgetInset.minimum, "no margin at all: the whole minimum")
        XCTAssertEqual(WidgetInset.extra(systemMargin: 4), WidgetInset.minimum - 4)
        XCTAssertEqual(WidgetInset.extra(systemMargin: -3), WidgetInset.minimum, "a nonsense margin counts as none")
    }

    func testTheDimmedDesktopDrawsInTheVibrantInk() {
        XCTAssertEqual(WidgetFaceMode.resolve(isFullColor: true, showsContainerBackground: true), .fullColor)
        XCTAssertEqual(WidgetFaceMode.resolve(isFullColor: false, showsContainerBackground: true), .vibrant, "accented or vibrant")
        XCTAssertEqual(WidgetFaceMode.resolve(isFullColor: true, showsContainerBackground: false), .vibrant,
                       "no backdrop of ours behind white text")
        XCTAssertEqual(WidgetFaceMode.resolve(isFullColor: false, showsContainerBackground: false), .vibrant)
    }

    func testLargeKeepsEverythingWhenItFits() {
        XCTAssertEqual(WidgetDisplay.largeRows(decisions: 1, inFlight: 2).decisions, 1)
        XCTAssertEqual(WidgetDisplay.largeRows(decisions: 1, inFlight: 2).inFlight, 2)
        XCTAssertEqual(WidgetDisplay.largeRows(decisions: 0, inFlight: 5).inFlight, 5)
    }

    func testTheSettingsRowExistsOnlyFromMacOS14AndNeverClaimsToAddWidgets() {
        XCTAssertNil(WidgetGuide.settingsDetail(osMajor: 12))
        XCTAssertNil(WidgetGuide.settingsDetail(osMajor: 13))
        let detail = WidgetGuide.settingsDetail(osMajor: 14) ?? ""
        XCTAssertTrue(detail.contains("can’t add a widget"))
        XCTAssertFalse(WidgetGuide.addDetail(osMajor: 14).isEmpty)
    }

    func testTheUnavailableHintDependsOnTheReasonAndNeverSaysToRunATerminalCommand() {
        let reasons = [WidgetSetup.Unavailable.notAnApp, WidgetSetup.Unavailable.noExtension,
                       WidgetSetup.Unavailable.noTeam, WidgetSetup.Unavailable.noAnswer]
        let hints = reasons.map { NWWidgetStatusRow.hint(.unavailable(reason: $0)) ?? "" }
        XCTAssertEqual(Set(hints).count, reasons.count, "each reason gets its own hint")
        for h in hints {
            XCTAssertFalse(h.isEmpty)
            XCTAssertFalse(h.contains("./install.sh"))
        }
    }

    func testTheControlMapDoesNotSayWidgetsAreAddedInSystemSettings() {
        let entry = TowerControlMap.entries.first { $0.old == "action: Open widget settings" }
        XCTAssertNotNil(entry)
        XCTAssertFalse(entry?.newControl.contains("where widgets are added") ?? true)
    }

    @MainActor
    func testTheGuideOpensByItselfTheFirstTimeMacOSSeesTheWidgetsAndStaysClosedAfterwards() {
        let store = TowerFixtures.store(section: .widgets)
        var answer: WidgetRegistration.Status = .notRegistered
        store.env.probeWidgets = { done in done(answer) }
        store.refreshWidgets()
        XCTAssertFalse(store.widgetGuideOpen)
        answer = .registered(path: "/Applications/Page.app/Contents/PlugIns/PageWidgets.appex")
        store.refreshWidgets()
        XCTAssertTrue(store.widgetGuideOpen)
        store.toggleWidgetGuide()
        store.refreshWidgets()
        XCTAssertFalse(store.widgetGuideOpen, "a guide the person closed stays closed")
    }
}
