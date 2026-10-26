import XCTest
@testable import ClaudePowerMode

/// The form behind the Tower: every control reads and writes its own
/// `Config` field and nothing else, and the save rules (trimming, the
/// relay and Codex checks, defaults on reset) hold.
final class PreferencesFormTests: XCTestCase {
    /// One change per form field, each to a value the defaults do not hold.
    private let changes: [(field: String, change: (inout PreferencesForm) -> Void)] = [
        ("relayEnabled", { $0.relayEnabled.toggle() }),
        ("relayURL", { $0.relayURL = "https://a.b.workers.dev" }),
        ("interventionDetectionEnabled", { $0.interventionDetectionEnabled.toggle() }),
        ("idlePageOnlyWhenAwaySeconds", { $0.idlePageOnlyWhenAwaySeconds = 777 }),
        ("idlePageDelaySeconds", { $0.idlePageDelaySeconds = 777 }),
        ("holdAwakeForPendingPageMinutes", { $0.holdAwakeForPendingPageMinutes = 777 }),
        ("headlessResumeFallbackEnabled", { $0.headlessResumeFallbackEnabled.toggle() }),
        ("remoteSessionsEnabled", { $0.remoteSessionsEnabled.toggle() }),
        ("phoneStartSessionsEnabled", { $0.phoneStartSessionsEnabled.toggle() }),
        ("keepAwakeLidClosedOnAC", { $0.keepAwakeLidClosedOnAC.toggle() }),
        ("keepAwakeLidClosedOnBattery", { $0.keepAwakeLidClosedOnBattery.toggle() }),
        ("requireRecentTranscriptActivity", { $0.requireRecentTranscriptActivity.toggle() }),
        ("transcriptActivityWindowSeconds", { $0.transcriptActivityWindowSeconds = 777 }),
        ("checkIntervalSeconds", { $0.checkIntervalSeconds = 77 }),
        ("lowBatteryCutoff", { $0.lowBatteryCutoff = 17 }),
        ("lowBatteryAction", { $0.lowBatteryAction = $0.lowBatteryAction == .off ? .pause : .off }),
        ("lowBatteryPauseGraceSeconds", { $0.lowBatteryPauseGraceSeconds = 77 }),
        ("recoveryThreshold", { $0.recoveryThreshold = 77 }),
        ("recoveryRequiresAC", { $0.recoveryRequiresAC.toggle() }),
        ("resumeAfterBatteryRecovery", { $0.resumeAfterBatteryRecovery.toggle() }),
        ("earlyBatteryPause", { $0.earlyBatteryPause.toggle() }),
        ("codexBackendEnabled", { $0.codexBackendEnabled.toggle() }),
        ("codexPath", { $0.codexPath = "/x/codex" }),
        ("localModelsEnabled", { $0.localModelsEnabled.toggle() }),
        ("rateLimitWatcherEnabled", { $0.rateLimitWatcherEnabled.toggle() }),
        ("autoResumeEnabled", { $0.autoResumeEnabled.toggle() }),
        ("carryOnPrompt", { $0.carryOnPrompt = "keep going please" }),
        ("holdAssertionUntilReset", { $0.holdAssertionUntilReset.toggle() }),
        ("wakeViaPmsetEnabled", { $0.wakeViaPmsetEnabled.toggle() }),
        ("stuckAlertsEnabled", { $0.stuckAlertsEnabled.toggle() }),
        ("stuckAfterMinutes", { $0.stuckAfterMinutes = 77 }),
        ("turnSummaryEnabled", { $0.turnSummaryEnabled.toggle() }),
        ("batteryForecastPageEnabled", { $0.batteryForecastPageEnabled.toggle() }),
        ("usageForecastPageEnabled", { $0.usageForecastPageEnabled.toggle() }),
        ("cardGlow", { $0.cardGlow = .full }),
    ]

    /// The stored properties whose values differ between two values, by name.
    private func changedLabels<T>(_ a: T, _ b: T) -> [String] {
        zip(Mirror(reflecting: a).children, Mirror(reflecting: b).children)
            .filter { pair in String(describing: pair.0.value) != String(describing: pair.1.value) }
            .map { pair in pair.0.label ?? "" }
    }

    func testThereAreThirtyFourControlsAndEachIsTested() {
        let formFields = Mirror(reflecting: PreferencesForm(Config())).children.compactMap { $0.label }
        XCTAssertEqual(formFields.count, 35)
        XCTAssertEqual(changes.map(\.field).sorted(), formFields.sorted())
    }

    func testEachControlWritesOnlyItsOwnConfigField() {
        let baseline = PreferencesForm(Config())
        for (field, change) in changes {
            var form = baseline
            change(&form)
            XCTAssertNotEqual(form, baseline, field)
            let out = form.merged(onto: Config(), changedFrom: baseline)
            XCTAssertEqual(changedLabels(out, Config()), [field], "control \(field)")
        }
    }

    func testEachControlReadsItsOwnConfigField() {
        let baseline = PreferencesForm(Config())
        for (field, change) in changes {
            var probe = baseline
            change(&probe)
            let config = probe.merged(onto: Config(), changedFrom: baseline)
            XCTAssertEqual(changedLabels(PreferencesForm(config), baseline), [field], "the form shows \(field) from the config")
        }
    }

    func testSavedRelayURLIsNormalised() {
        let baseline = PreferencesForm(Config())
        var form = baseline
        form.relayURL = " https://a.b.workers.dev/ws/ "
        XCTAssertEqual(form.merged(onto: Config(), changedFrom: baseline).relayURL, "https://a.b.workers.dev")
    }

    func testPlaceholderRelayShowsAsEmpty() {
        XCTAssertEqual(PreferencesForm(Config()).relayURL, "")
    }

    // MARK: normalising for save

    func testNormalisedForSaveTrimsTheTextFields() {
        var f = PreferencesForm(Config())
        f.relayURL = "  https://a.b.workers.dev \n"
        f.codexPath = "  /x/codex  "
        f.carryOnPrompt = "  keep going  "
        let n = f.normalisedForSave()
        XCTAssertEqual(n.relayURL, "https://a.b.workers.dev")
        XCTAssertEqual(n.codexPath, "/x/codex")
        XCTAssertEqual(n.carryOnPrompt, "keep going")
        XCTAssertEqual(n.lowBatteryCutoff, f.lowBatteryCutoff, "other fields are unchanged")
    }

    func testBlankResumePromptBecomesTheDefault() {
        var f = PreferencesForm(Config())
        f.carryOnPrompt = "   "
        XCTAssertEqual(f.normalisedForSave().carryOnPrompt, Config().carryOnPrompt)
        XCTAssertEqual(Config().carryOnPrompt, "carry on")
    }

    func testACleanFormIsReturnedEqual() {
        let f = PreferencesForm(Config())
        XCTAssertEqual(f.normalisedForSave(), f)
    }

    // MARK: validation

    func testRelayOnWithNoURLCannotBeSaved() {
        var f = PreferencesForm(Config())
        f.relayEnabled = true
        f.relayURL = ""
        XCTAssertEqual(f.validationError(), "Enter your relay’s URL, or turn off “Send pages to my phone”.")
        f.relayEnabled = false
        XCTAssertNil(f.validationError())
    }

    func testAPlainHTTPRelayCannotBeSaved() {
        var f = PreferencesForm(Config())
        f.relayURL = "http://example.com"
        XCTAssertTrue(f.validationError()?.hasPrefix("Use https://") ?? false, f.validationError() ?? "nil")
    }

    func testACodexPathMustBeExecutable() {
        var f = PreferencesForm(Config())
        f.codexPath = "/no/such/codex"
        XCTAssertEqual(f.validationError(isExecutable: { _ in false }),
                       "No executable codex at /no/such/codex. Leave the field blank to auto-detect.")
        XCTAssertNil(f.validationError(isExecutable: { _ in true }))
        f.codexPath = "   "
        XCTAssertNil(f.validationError(isExecutable: { _ in false }), "blank means auto-detect")
    }

    // MARK: reset

    func testResetKeepsTheRelayAndCodexSetupOnly() {
        var f = PreferencesForm(Config())
        f.relayEnabled = true
        f.relayURL = "https://x.workers.dev"
        f.codexPath = "/x/codex"
        f.lowBatteryCutoff = 20
        f.carryOnPrompt = "keep going"
        let r = f.resetToDefaults()
        XCTAssertEqual(r.lowBatteryCutoff, 10)
        XCTAssertEqual(r.carryOnPrompt, "carry on")
        XCTAssertTrue(r.relayEnabled)
        XCTAssertEqual(r.relayURL, "https://x.workers.dev")
        XCTAssertEqual(r.codexPath, "/x/codex")
    }

    func testResetEqualsTheDefaultFormExceptForTheKeptFields() {
        var f = PreferencesForm(Config())
        f.lowBatteryCutoff = 20
        f.stuckAfterMinutes = 60
        XCTAssertEqual(f.resetToDefaults(), PreferencesForm(Config()))
    }
}

/// The Tower's drawing helpers: slider maths and where a battery label sits.
final class TowerViewLogicTests: XCTestCase {
    func testSliderValueAtTheEdgesAndMiddle() {
        XCTAssertEqual(NWSlider.value(at: 0, width: 100, range: 0...50, step: 1), 0)
        XCTAssertEqual(NWSlider.value(at: 50, width: 100, range: 0...50, step: 1), 25)
        XCTAssertEqual(NWSlider.value(at: 100, width: 100, range: 0...50, step: 1), 50)
    }

    func testSliderClampsBeyondTheTrack() {
        XCTAssertEqual(NWSlider.value(at: 130, width: 100, range: 0...50, step: 1), 50)
        XCTAssertEqual(NWSlider.value(at: -5, width: 100, range: 0...50, step: 1), 0)
    }

    func testSliderSnapsToItsStep() {
        XCTAssertEqual(NWSlider.value(at: 44, width: 100, range: 0...50, step: 5), 20, "22 snaps to 20")
        XCTAssertEqual(NWSlider.value(at: 22, width: 100, range: 0...50, step: 1), 11)
    }

    func testSliderWithNoWidthGivesTheLowerBound() {
        XCTAssertEqual(NWSlider.value(at: 40, width: 0, range: 5...50, step: 1), 5)
    }

    func testBatteryLabelsSitWhereTheyFit() {
        let wide = NWBatteryBar.labelLayout(cutoffX: 120, earlyX: nil)
        XCTAssertTrue(wide.cutoffTrailing)
        XCTAssertEqual(wide.earlyRow, 0)
        let crowded = NWBatteryBar.labelLayout(cutoffX: 20, earlyX: 60)
        XCTAssertFalse(crowded.cutoffTrailing, "no room on the left: right of the tick")
        XCTAssertEqual(crowded.earlyRow, 1, "the pause-early label drops a row")
        let apart = NWBatteryBar.labelLayout(cutoffX: 20, earlyX: 200)
        XCTAssertEqual(apart.earlyRow, 0)
        XCTAssertEqual(NWBatteryBar.labelLayout(cutoffX: 20, earlyX: nil).earlyRow, 0)
    }
}
