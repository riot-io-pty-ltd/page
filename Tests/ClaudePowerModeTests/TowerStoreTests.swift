import XCTest
@testable import ClaudePowerMode

/// The Tower's store: what Apply writes and when, the coupled sliders, the
/// relay test, the power helper and usage capture. Everything outside the
/// store (disk, helper, network, alerts) is a recorded fake.
final class TowerStoreTests: XCTestCase {
    private final class Recorder {
        var loadResult: Config.LoadResult? = Config.LoadResult(config: Config(), problem: nil, backupURL: nil)
        var writes: [Config] = []
        var writeError: Error?
        var reloads = 0
        var closes = 0
        var alerts: [(title: String, text: String)] = []
        var beeps = 0
        var lines: [String] = []
        var probes: [URL] = []
        var probeCallbacks: [(String, Bool) -> Void] = []
        var installs = 0
        var usageCalls: [Bool] = []
    }

    private struct CaptureError: LocalizedError {
        var errorDescription: String? { "Can’t write settings.json" }
    }

    private func makeStore(_ config: Config = Config(),
                           configure: (inout TowerEnvironment, Recorder) -> Void = { _, _ in }) -> (TowerStore, Recorder) {
        let r = Recorder()
        var env = TowerEnvironment()
        env.loadConfig = { r.loadResult }
        env.runningConfig = { config }
        env.writeConfig = { c in
            if let e = r.writeError { throw e }
            r.writes.append(c)
        }
        env.reloadConfig = { r.reloads += 1 }
        env.close = { r.closes += 1 }
        env.showAlert = { r.alerts.append((title: $0, text: $1)) }
        env.beep = { r.beeps += 1 }
        env.log = { r.lines.append($0) }
        env.probeRelay = { _, done in r.probeCallbacks.append(done) }
        configure(&env, r)
        return (TowerStore(config: config, macName: "Studio MBP", env: env), r)
    }

    // MARK: loading and dirtiness

    func testLoadReadsTheFreshConfigAndResetsTheBaseline() {
        var fresh = Config()
        fresh.lowBatteryCutoff = 15
        let (s, r) = makeStore()
        r.loadResult = Config.LoadResult(config: fresh, problem: nil, backupURL: nil)
        s.load(section: .budget)
        XCTAssertEqual(s.form.lowBatteryCutoff, 15)
        XCTAssertEqual(s.baseline.lowBatteryCutoff, 15)
        XCTAssertFalse(s.isDirty)
        XCTAssertEqual(s.selection, .budget)
        XCTAssertNil(s.problem)
    }

    func testLoadFallsBackToTheRunningConfigWhenTheFileIsBroken() {
        var running = Config()
        running.lowBatteryCutoff = 20
        let (s, r) = makeStore(running)
        r.loadResult = Config.LoadResult(config: nil, problem: "config.json isn’t valid JSON", backupURL: nil)
        s.load()
        XCTAssertEqual(s.form.lowBatteryCutoff, 20)
        XCTAssertEqual(s.problem, "config.json isn’t valid JSON")
        XCTAssertEqual(s.selection, .power, "no section asked for, so the selection stays")
    }

    func testEditingMakesTheFormDirtyAndCancelWritesNothing() {
        let (s, r) = makeStore()
        s.form.keepAwakeLidClosedOnAC.toggle()
        XCTAssertTrue(s.isDirty)
        s.cancel()
        XCTAssertEqual(r.closes, 1)
        XCTAssertTrue(r.writes.isEmpty)
    }

    // MARK: coupled sliders

    func testMovingTheCutoffUpPullsRecoveryUp() {
        let (s, _) = makeStore()
        s.setCutoff(30)
        XCTAssertEqual(s.form.lowBatteryCutoff, 30)
        XCTAssertEqual(s.form.recoveryThreshold, 35)
    }

    func testMovingRecoveryDownPullsTheCutoffDown() {
        let (s, _) = makeStore()
        s.setRecovery(8)
        XCTAssertEqual(s.form.recoveryThreshold, 8)
        XCTAssertEqual(s.form.lowBatteryCutoff, 3)
    }

    // MARK: apply

    func testApplyRefusesARelayWithNoURL() {
        let (s, r) = makeStore()
        s.form.relayEnabled = true
        s.form.relayURL = "   "
        XCTAssertFalse(s.apply())
        XCTAssertEqual(r.writes.count, 0)
        XCTAssertEqual(r.beeps, 1)
        XCTAssertEqual(r.alerts.count, 1)
        XCTAssertEqual(r.alerts.first?.title, "Can’t save these settings")
        XCTAssertEqual(r.alerts.first?.text, "Enter your relay’s URL, or turn off “Send pages to my phone”.")
        XCTAssertEqual(r.closes, 0)
    }

    func testApplyWithAGoodFormWritesReloadsClosesAndClearsDirty() {
        let (s, r) = makeStore()
        s.form.relayEnabled = true
        s.form.relayURL = " https://a.b.workers.dev/ws "
        s.setCutoff(15)
        XCTAssertTrue(s.apply())
        XCTAssertEqual(r.writes.count, 1)
        XCTAssertEqual(r.writes.first?.relayURL, "https://a.b.workers.dev", "saved as the normalised base URL")
        XCTAssertEqual(r.writes.first?.lowBatteryCutoff, 15)
        XCTAssertEqual(r.reloads, 1)
        XCTAssertEqual(r.closes, 1)
        XCTAssertFalse(s.isDirty)
        XCTAssertTrue(r.lines.contains("Preferences saved"))
    }

    func testApplyKeepsAnEditMadeByHandOnDisk() {
        var onDisk = Config()
        onDisk.lowBatteryCutoff = 20
        let (s, r) = makeStore()
        r.loadResult = Config.LoadResult(config: onDisk, problem: nil, backupURL: nil)
        s.setRecovery(30)
        XCTAssertTrue(s.apply())
        XCTAssertEqual(r.writes.first?.lowBatteryCutoff, 20, "the file's own edit survives a save of other fields")
        XCTAssertEqual(r.writes.first?.recoveryThreshold, 30)
    }

    func testApplyWithAnUnreadableFileNeedsConfirmation() {
        let broken = Config.LoadResult(config: nil, problem: "malformed", backupURL: URL(fileURLWithPath: "/x/config.broken.json"))
        let (s, r) = makeStore { env, rec in
            rec.loadResult = broken
            env.confirmReplaceBrokenConfig = { info in
                XCTAssertTrue(info.contains("Saving replaces it"))
                XCTAssertTrue(info.hasSuffix("The broken file was copied to config.broken.json."), info)
                return false
            }
        }
        XCTAssertFalse(s.apply())
        XCTAssertTrue(r.writes.isEmpty)
    }

    func testApplyWithAnUnreadableFileAndConsentReplacesIt() {
        let (s, r) = makeStore { env, rec in
            rec.loadResult = Config.LoadResult(config: nil, problem: nil, backupURL: nil)
            env.confirmReplaceBrokenConfig = { _ in true }
        }
        XCTAssertTrue(s.apply())
        XCTAssertEqual(r.writes.count, 1)
    }

    func testWriteFailureIsReportedAndTheWindowStaysOpen() {
        struct Disk: LocalizedError { var errorDescription: String? { "disk full" } }
        let (s, r) = makeStore()
        r.writeError = Disk()
        s.form.lowBatteryCutoff = 12
        XCTAssertFalse(s.apply())
        XCTAssertEqual(r.alerts.first?.title, "Couldn’t save settings")
        XCTAssertEqual(r.closes, 0)
        XCTAssertTrue(s.isDirty, "nothing was saved, so the edit is still there")
    }

    func testResetToDefaultsKeepsTheRelaySetupAndCodexPath() {
        let (s, _) = makeStore()
        s.form.relayEnabled = true
        s.form.relayURL = "https://x.workers.dev"
        s.form.codexPath = "/x/codex"
        s.form.lowBatteryCutoff = 20
        s.resetToDefaults()
        XCTAssertEqual(s.form.lowBatteryCutoff, 10)
        XCTAssertTrue(s.form.relayEnabled)
        XCTAssertEqual(s.form.relayURL, "https://x.workers.dev")
        XCTAssertEqual(s.form.codexPath, "/x/codex")
    }

    // MARK: relay test

    func testTestRelayDoesNothingForAnInvalidURL() {
        let (s, r) = makeStore()
        s.form.relayURL = "http://example.com"
        s.testRelay()
        XCTAssertTrue(r.probeCallbacks.isEmpty)
        XCTAssertEqual(s.relayTest, .idle)
    }

    func testTestRelayShowsTheHostAndThenTheResult() {
        let (s, r) = makeStore()
        s.form.relayURL = "https://a.b.workers.dev"
        s.testRelay()
        XCTAssertEqual(s.relayTest, .testing(host: "a.b.workers.dev"))
        XCTAssertEqual(s.relayLine.line.text, "Testing a.b.workers.dev…")
        XCTAssertFalse(s.relayLine.canTest)
        XCTAssertEqual(r.probeCallbacks.count, 1)
        r.probeCallbacks[0]("Relay is up", true)
        XCTAssertEqual(s.relayTest, .result(message: "Relay is up", ok: true))
        XCTAssertEqual(s.relayLine.line.tone, .good)
        XCTAssertEqual(s.relayLine.line.text, "Relay is up")
    }

    func testFailedRelayTestIsBad() {
        let (s, r) = makeStore()
        s.form.relayURL = "https://a.b.workers.dev"
        s.testRelay()
        r.probeCallbacks[0]("401 Unauthorized", false)
        XCTAssertEqual(s.relayLine.line.tone, .bad)
    }

    func testAStaleRelayResultIsIgnoredAfterAnEdit() {
        let (s, r) = makeStore()
        s.form.relayURL = "https://a.b.workers.dev"
        s.testRelay()
        s.relayEdited()
        XCTAssertEqual(s.relayTest, .idle)
        r.probeCallbacks[0]("Relay is up", true)
        XCTAssertEqual(s.relayTest, .idle, "the answer to an old URL does not land")
    }

    func testOnlyTheNewestRelayTestCounts() {
        let (s, r) = makeStore()
        s.form.relayURL = "https://a.b.workers.dev"
        s.testRelay()
        s.testRelay()
        r.probeCallbacks[0]("old", true)
        XCTAssertEqual(s.relayTest, .testing(host: "a.b.workers.dev"))
        r.probeCallbacks[1]("new", false)
        XCTAssertEqual(s.relayTest, .result(message: "new", ok: false))
    }

    // MARK: Codex and local models

    func testCodexLineComesFromTheLookupOnlyWhenWatched() {
        let (s, _) = makeStore(configure: { env, _ in
            env.findCodex = { _ in "/opt/homebrew/bin/codex" }
        })
        XCTAssertNil(s.codexLine, "Codex is not watched")
        s.form.codexBackendEnabled = true
        XCTAssertEqual(s.codexLine?.text, "Using /opt/homebrew/bin/codex")
    }

    func testLocalModelsTextFollowsTheToggle() {
        let (s, _) = makeStore()
        s.preview(localLines: ["ollama · busy"])
        XCTAssertEqual(s.localModelsText, "ollama · busy")
        s.form.localModelsEnabled = false
        XCTAssertEqual(s.localModelsText, "Off.")
    }

    // MARK: power helper

    func testLidOnBatteryWithoutTheHelperInstallsItFirstAndUnticksOnCancel() {
        let (s, _) = makeStore { env, rec in
            env.installHelper = { done in rec.installs += 1; done(.cancelled, .missing) }
        }
        s.preview(helper: .missing)
        s.setLidClosedOnBattery(true)
        XCTAssertEqual(s.form.keepAwakeLidClosedOnBattery, false)
    }

    func testLidOnBatteryStaysTickedAfterAnInstall() {
        let (s, r) = makeStore { env, rec in
            env.installHelper = { done in rec.installs += 1; done(.installed, .available) }
        }
        s.preview(helper: .missing)
        s.setLidClosedOnBattery(true)
        XCTAssertEqual(r.installs, 1)
        XCTAssertTrue(s.form.keepAwakeLidClosedOnBattery)
        XCTAssertEqual(s.helperStatus, .available)
    }

    func testLidOnBatteryWithTheHelperPresentJustSetsIt() {
        let (s, r) = makeStore { env, rec in
            env.installHelper = { done in rec.installs += 1; done(.installed, .available) }
        }
        s.preview(helper: .available)
        s.setLidClosedOnBattery(true)
        XCTAssertEqual(r.installs, 0)
        XCTAssertTrue(s.form.keepAwakeLidClosedOnBattery)
        s.setLidClosedOnBattery(false)
        XCTAssertFalse(s.form.keepAwakeLidClosedOnBattery)
    }

    func testAFailedInstallAlertsAndUnticks() {
        let (s, r) = makeStore { env, rec in
            env.installHelper = { done in rec.installs += 1; done(.failed("no admin rights"), .missing) }
        }
        s.preview(helper: .missing)
        s.setLidClosedOnBattery(true)
        XCTAssertFalse(s.form.keepAwakeLidClosedOnBattery)
        XCTAssertEqual(r.alerts.first?.title, "Couldn’t install the power helper")
        XCTAssertEqual(r.alerts.first?.text, "no admin rights")
    }

    // MARK: usage capture (applied at once)

    func testUsageCaptureSuccessShowsTheBackupName() {
        let (s, r) = makeStore { env, rec in
            env.setUsageCapture = { on in rec.usageCalls.append(on); return "settings.json.bak" }
        }
        s.setUsageCapture(true)
        XCTAssertTrue(s.usageCapture.on)
        XCTAssertFalse(s.usageCapture.failed)
        XCTAssertTrue(s.usageCapture.text.hasSuffix(" Backup: settings.json.bak"))
        XCTAssertEqual(r.usageCalls, [true])
    }

    func testUsageCaptureFailureRevertsTheToggleAndNeverTouchesTheForm() {
        let (s, _) = makeStore { env, _ in
            env.setUsageCapture = { _ in throw CaptureError() }
        }
        let before = s.form
        s.setUsageCapture(true)
        XCTAssertFalse(s.usageCapture.on, "reverts to the opposite of the request")
        XCTAssertTrue(s.usageCapture.failed)
        XCTAssertEqual(s.usageCapture.text, "Can’t write settings.json")
        XCTAssertEqual(s.form, before)
        XCTAssertEqual(s.baseline, before)
    }

    // MARK: live data

    func testUpdateFeedsTheCard() {
        let (s, _) = makeStore()
        s.update(snapshot: nil, model: NowModel.build(NightWatchFixtures.needsYou()))
        XCTAssertEqual(s.card.subtitle, "Studio MBP · 5 working")
        XCTAssertEqual(s.card.attentionBadge, 3)
    }

    func testPreviewSetsTheLiveBits() {
        let (s, _) = makeStore()
        s.preview(helper: .available, installing: true, localLines: ["x"], problem: "bad")
        XCTAssertEqual(s.helperStatus, .available)
        XCTAssertTrue(s.helperInstalling)
        XCTAssertEqual(s.localLines, ["x"])
        XCTAssertEqual(s.problem, "bad")
    }
}

// MARK: - Apply, pure

final class TowerApplyTests: XCTestCase {
    func testOnlyChangedFieldsAreWrittenOntoTheFreshConfig() {
        var base = Config()
        base.lowBatteryCutoff = 20            // hand-edited on disk; the window never changed it
        let baseline = PreferencesForm(Config())
        var form = baseline
        form.recoveryThreshold = 30
        let out = TowerApply.config(form: form, baseline: baseline, base: base)
        XCTAssertEqual(out.lowBatteryCutoff, 20, "not overwritten by a stale control")
        XCTAssertEqual(out.recoveryThreshold, 30)
    }

    func testWithNoBaselineNothingChanges() {
        var base = Config()
        base.lowBatteryCutoff = 20
        base.carryOnPrompt = "keep going"
        XCTAssertEqual(TowerApply.config(form: PreferencesForm(base), baseline: nil, base: base), base)
    }

    func testTheResultGoesThroughValidation() {
        let baseline = PreferencesForm(Config())
        var form = baseline
        form.holdAwakeForPendingPageMinutes = 100_000
        let out = TowerApply.config(form: form, baseline: baseline, base: Config())
        XCTAssertEqual(out.holdAwakeForPendingPageMinutes, Config.Limits.holdAwakeMinutes.upperBound)
    }

    func testReplaceWarningWording() {
        let plain = TowerApply.replaceWarning(problem: nil, backupName: nil)
        XCTAssertTrue(plain.hasPrefix("The file is malformed."), plain)
        XCTAssertTrue(plain.contains("Saving replaces it with the settings shown here plus Page’s current settings."))
        XCTAssertFalse(plain.contains("copied to"))
        let copied = TowerApply.replaceWarning(problem: "Line 3 is broken", backupName: "config.bad.json")
        XCTAssertTrue(copied.hasPrefix("Line 3 is broken"), copied)
        XCTAssertTrue(copied.hasSuffix(" The broken file was copied to config.bad.json."))
    }
}
