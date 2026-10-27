import XCTest
@testable import ClaudePowerMode

/// The Tower (settings window): the section list, the card, the formatting
/// and option rules, the Power and Budget pages, the shortcut list, and the
/// map that proves every old Preferences control still has a home.
final class TowerModelTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = utc
        return c
    }
    private let now = NightWatchFixtures.boardNow()

    private func utcDate(_ d: Int, _ h: Int, _ m: Int) -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 10; comps.day = d; comps.hour = h; comps.minute = m
        return utcCalendar.date(from: comps)!
    }

    // MARK: sections

    func testSectionOrderAndTitlesMatchTheBoard() {
        XCTAssertEqual(TowerSection.allCases, [.power, .budget, .macsPhones, .attention, .agents, .phoneApprovals, .terminals, .shortcuts, .pairing, .about])
        XCTAssertEqual(TowerSection.allCases.map(\.title),
                       ["Power", "Budget", "Macs & phones", "Attention", "Agents", "Phone approvals", "Terminals", "Shortcuts", "Pairing & encryption", "About Page"])
    }

    func testSectionMovesClampAtTheEnds() {
        XCTAssertEqual(TowerSection.moved(from: .power, by: -1), .power)
        XCTAssertEqual(TowerSection.moved(from: .about, by: 1), .about)
        XCTAssertEqual(TowerSection.moved(from: .power, by: 2), .macsPhones)
        XCTAssertEqual(TowerSection.moved(from: .about, by: -4), .phoneApprovals)
    }

    // MARK: the card

    func testCardFollowsTheWorkingAgentsAndAttention() {
        let m = NowModel.build(NightWatchFixtures.needsYou())
        let card = TowerCardModel.build(model: m, macName: "Studio MBP")
        XCTAssertEqual(card.title, "The Tower")
        XCTAssertEqual(card.subtitle, "Studio MBP · 5 working")
        XCTAssertEqual(card.dot, .running)
        XCTAssertEqual(card.attentionBadge, m.attentionCount)
        XCTAssertEqual(card.rings, m.rings)
    }

    func testCardWhilePausedShowsThePausedDot() {
        let card = TowerCardModel.build(model: NowModel.build(NightWatchFixtures.pausedForBattery()), macName: "Studio MBP")
        XCTAssertEqual(card.subtitle, "Studio MBP · paused for battery")
        XCTAssertEqual(card.dot, .paused)
    }

    func testCardWithNoAgentsSaysAllQuiet() {
        var i = NightWatchFixtures.allQuiet()
        i.snapshot = NightWatchFixtures.snapshot()
        let card = TowerCardModel.build(model: NowModel.build(i), macName: "Studio MBP")
        XCTAssertTrue(card.subtitle.hasSuffix("all quiet"), card.subtitle)
    }

    func testCardBeforeTheFirstSnapshotIsStarting() {
        let card = TowerCardModel.build(model: nil, macName: "Studio MBP")
        XCTAssertEqual(card.subtitle, "Studio MBP · starting…")
        XCTAssertEqual(card.dot, .starting)
        XCTAssertTrue(card.rings.isEmpty)
        XCTAssertEqual(card.attentionBadge, 0)
    }

    // MARK: formatting

    func testDurationReadsSecondsAndMinutes() {
        XCTAssertEqual(TowerFormat.duration(0), "Off")
        XCTAssertEqual(TowerFormat.duration(0, zero: "Always"), "Always")
        XCTAssertEqual(TowerFormat.duration(45), "45 s")
        XCTAssertEqual(TowerFormat.duration(180), "3 min")
        XCTAssertEqual(TowerFormat.duration(90), "1m 30s")
    }

    func testHoldAwakeReadout() {
        XCTAssertEqual(TowerFormat.holdAwake(minutes: 0), "Don’t")
        XCTAssertEqual(TowerFormat.holdAwake(minutes: 45), "45 min")
        XCTAssertEqual(TowerFormat.holdAwake(minutes: 150), "2h 30m")
    }

    func testHoldSegmentLabels() {
        XCTAssertEqual(TowerFormat.holdSegment(minutes: 0), "Off")
        XCTAssertEqual(TowerFormat.holdSegment(minutes: 30), "30m")
        XCTAssertEqual(TowerFormat.holdSegment(minutes: 60), "1h")
        XCTAssertEqual(TowerFormat.holdSegment(minutes: 90), "1h 30m")
    }

    func testPercentRoundsToAWholeNumber() {
        XCTAssertEqual(TowerFormat.percent(61.6), "62%")
        XCTAssertEqual(TowerFormat.percent(0), "0%")
    }

    func testResetTextTodayIsClockOnly() {
        let now = utcDate(26, 1, 0), at = utcDate(26, 3, 0)
        XCTAssertEqual(TowerFormat.resetText(at, now: now, timeZone: utc), "03:00")
    }

    func testResetTextFurtherOutNamesTheDay() {
        let now = utcDate(26, 1, 0), at = utcCalendar.date(byAdding: .day, value: 3, to: utcDate(26, 23, 0))!
        let text = TowerFormat.resetText(at, now: now, timeZone: utc)
        XCTAssertTrue(text.hasSuffix(" 23:00"), text)
        XCTAssertEqual(text.count, 9, "three-letter day, a space, then HH:mm: \(text)")
    }

    // MARK: segmented options

    func testCutoffOptionsAddTheCurrentValueInItsPlace() {
        XCTAssertEqual(TowerOptions.cutoffOptions(current: 10).map { $0.value }, [5, 10, 15, 20])
        XCTAssertEqual(TowerOptions.cutoffOptions(current: 10).map { $0.label }, ["5%", "10%", "15%", "20%"])
        XCTAssertEqual(TowerOptions.cutoffOptions(current: 12).map { $0.value }, [5, 10, 12, 15, 20])
        XCTAssertTrue(TowerOptions.cutoffOptions(current: 12).map { $0.label }.contains("12%"))
        XCTAssertEqual(TowerOptions.cutoffOptions(current: 0).map { $0.value }, [0, 5, 10, 15, 20])
    }

    func testHoldOptionsAddTheCurrentValueInItsPlace() {
        let at60 = TowerOptions.holdOptions(current: 60)
        XCTAssertEqual(at60.map { $0.label }, ["Off", "30m", "1h"])
        let at90 = TowerOptions.holdOptions(current: 90)
        XCTAssertEqual(at90.map { $0.value }, [0, 30, 60, 90])
        XCTAssertEqual(at90.map { $0.label }, ["Off", "30m", "1h", "1h 30m"])
        let at45 = TowerOptions.holdOptions(current: 45)
        XCTAssertEqual(at45.map { $0.value }, [0, 30, 45, 60])
        XCTAssertTrue(at45.map { $0.label }.contains("45m"))
        XCTAssertEqual(TowerOptions.holdOptions(current: 0).map { $0.value }, [0, 30, 60])
    }

    func testActionLabelsAreTheNewWords() {
        XCTAssertEqual(TowerOptions.actionLabel(.pause), "Pause")
        XCTAssertEqual(TowerOptions.actionLabel(.afterTurn), "After step")
        XCTAssertEqual(TowerOptions.actionLabel(.off), "Off")
        XCTAssertEqual(TowerOptions.actionDetail(.pause), "pause now and summarise")
    }

    // MARK: rules between controls

    func testMovingCutoffUpPullsRecoveryAlong() {
        XCTAssertEqual(TowerRules.recovery(afterCutoff: 30, recovery: 25), 35)
        XCTAssertEqual(TowerRules.recovery(afterCutoff: 10, recovery: 25), 25)
        XCTAssertEqual(TowerRules.recovery(afterCutoff: 98, recovery: 25), 100, "capped at 100")
        XCTAssertEqual(TowerRules.recovery(afterCutoff: 25, recovery: 25), 25)
    }

    func testMovingRecoveryDownPullsCutoffAlong() {
        XCTAssertEqual(TowerRules.cutoff(afterRecovery: 8, cutoff: 10), 3)
        XCTAssertEqual(TowerRules.cutoff(afterRecovery: 5, cutoff: 10), 0, "floored at 0")
        XCTAssertEqual(TowerRules.cutoff(afterRecovery: 25, cutoff: 10), 10)
    }

    func testOnlyPausingActionsPauseAgents() {
        XCTAssertTrue(TowerRules.pausesAgents(.pause))
        XCTAssertTrue(TowerRules.pausesAgents(.afterTurn))
        XCTAssertFalse(TowerRules.pausesAgents(.off))
    }

    func testDependentFieldsFollowTheirToggles() {
        var c = Config()
        c.stuckAlertsEnabled = false
        XCTAssertFalse(TowerRules.stuckMinutesEnabled(PreferencesForm(c)))
        c.stuckAlertsEnabled = true
        XCTAssertTrue(TowerRules.stuckMinutesEnabled(PreferencesForm(c)))
        c.codexBackendEnabled = false
        XCTAssertFalse(TowerRules.codexPathEnabled(PreferencesForm(c)))
        c.codexBackendEnabled = true
        XCTAssertTrue(TowerRules.codexPathEnabled(PreferencesForm(c)))
    }

    func testLidOnBatteryInstallsTheHelperFirstWhenMissing() {
        XCTAssertEqual(TowerRules.lidBattery(turningOn: true, helper: .missing), .installHelperFirst)
        XCTAssertEqual(TowerRules.lidBattery(turningOn: true, helper: .available), .set(true))
        XCTAssertEqual(TowerRules.lidBattery(turningOn: true, helper: .unknown), .set(true))
        XCTAssertEqual(TowerRules.lidBattery(turningOn: false, helper: .missing), .set(false))
    }

    func testLidOnBatteryStaysTickedOnlyAfterAnInstall() {
        XCTAssertTrue(TowerRules.lidBatteryAfterInstall(.installed))
        XCTAssertFalse(TowerRules.lidBatteryAfterInstall(.cancelled))
        XCTAssertFalse(TowerRules.lidBatteryAfterInstall(.failed("x")))
    }

    // MARK: relay and Codex lines

    func testRelayLineWhenEmpty() {
        let on = TowerLines.relay(enabled: true, url: "")
        XCTAssertEqual(on.line.text, "Enter your relay’s URL.")
        XCTAssertEqual(on.line.tone, .bad)
        XCTAssertFalse(on.canTest)
        let off = TowerLines.relay(enabled: false, url: "   ")
        XCTAssertEqual(off.line.text, "")
        XCTAssertEqual(off.line.tone, .quiet)
        XCTAssertFalse(off.canTest)
    }

    func testRelayLineForAGoodURLAllowsTheTest() {
        let r = TowerLines.relay(enabled: true, url: " https://a.b.workers.dev ")
        XCTAssertEqual(r.line.text, "Will connect to https://a.b.workers.dev")
        XCTAssertEqual(r.line.tone, .quiet)
        XCTAssertTrue(r.canTest)
    }

    func testRelayLineRefusesPlainHTTPAndThePlaceholder() {
        let http = TowerLines.relay(enabled: true, url: "http://example.com")
        XCTAssertTrue(http.line.text.hasPrefix("Use https://"), http.line.text)
        XCTAssertEqual(http.line.tone, .bad)
        XCTAssertFalse(http.canTest)
        let placeholder = TowerLines.relay(enabled: true, url: Config.placeholderRelayURL)
        XCTAssertTrue(placeholder.line.text.hasPrefix("The relay URL is still the example placeholder"), placeholder.line.text)
        XCTAssertEqual(placeholder.line.tone, .bad)
        XCTAssertFalse(placeholder.canTest)
    }

    func testCodexLineFollowsWhatIsFound() {
        XCTAssertNil(TowerLines.codex(enabled: false, configured: "", found: "/opt/homebrew/bin/codex"))
        let missing = TowerLines.codex(enabled: true, configured: "", found: nil)
        XCTAssertEqual(missing?.tone, .bad)
        XCTAssertTrue(missing?.text.hasPrefix("codex wasn’t found") ?? false)
        let auto = TowerLines.codex(enabled: true, configured: "  ", found: "/opt/homebrew/bin/codex")
        XCTAssertEqual(auto?.text, "Using /opt/homebrew/bin/codex")
        XCTAssertEqual(auto?.tone, .quiet)
        let wrong = TowerLines.codex(enabled: true, configured: "/x/codex", found: "/opt/homebrew/bin/codex")
        XCTAssertEqual(wrong?.tone, .bad)
        XCTAssertEqual(wrong?.text, "Nothing executable at that path — auto-detect would use /opt/homebrew/bin/codex")
        let same = TowerLines.codex(enabled: true, configured: "/opt/homebrew/bin/codex", found: "/opt/homebrew/bin/codex")
        XCTAssertEqual(same?.text, "Using /opt/homebrew/bin/codex")
    }

    func testLocalModelsAndUsageLines() {
        XCTAssertEqual(TowerLines.localModels(enabled: false, lines: ["ollama"]), "Off.")
        XCTAssertEqual(TowerLines.localModels(enabled: true, lines: []), "No local model servers or tools running right now.")
        XCTAssertEqual(TowerLines.localModels(enabled: true, lines: ["a", "b"]), "a\nb")
        XCTAssertTrue(TowerLines.usageCaptured(on: true, backupName: "settings.json.bak").hasSuffix(" Backup: settings.json.bak"))
        XCTAssertEqual(TowerLines.usageCaptured(on: false, backupName: nil), "Off — your status line is back as it was.")
    }

    // MARK: Power page

    private func power(percent: Int = 41, onAC: Bool = false, charging: Bool = false, hasBattery: Bool = true) -> PowerSnapshot {
        PowerSnapshot(percent: percent, onAC: onAC, hasBattery: hasBattery, isCharging: charging)
    }

    private func forecast41() -> BatteryForecast.Estimate {
        BatteryForecast.Estimate(percent: 41, cutoff: 10, drainPerHour: 17, minutesToCutoff: 110)
    }

    func testHeroOnBatteryWithAForecast() {
        let hero = PowerPage.hero(PowerInputs(power: power(), forecast: forecast41(), awake: .none, cutoff: 10,
                                              action: .pause, earlyPause: true))
        XCTAssertEqual(hero.bigText, "41%")
        XCTAssertEqual(hero.line, "on battery · cutoff in about 1 h 50 min at this rate")
        XCTAssertEqual(hero.bar?.fill ?? -1, 0.41, accuracy: 1e-9)
        XCTAssertEqual(hero.bar?.cutoff ?? -1, 0.10, accuracy: 1e-9)
        XCTAssertEqual(hero.bar?.cutoffLabel, "cutoff 10%")
        XCTAssertEqual(hero.bar?.pauseEarly ?? -1, 0.13, accuracy: 1e-9)
        XCTAssertEqual(hero.bar?.pauseEarlyLabel, "pause early")
        XCTAssertEqual(hero.bar?.pauseEarlyOn, true)
    }

    func testHeroRecomputesTheTimeForAChangedCutoff() {
        let hero = PowerPage.hero(PowerInputs(power: power(), forecast: forecast41(), awake: .none, cutoff: 15, action: .pause))
        XCTAssertEqual(hero.line, "on battery · cutoff in about 1 h 32 min at this rate")
    }

    func testHeroOnACAndCharging() {
        let charging = PowerPage.hero(PowerInputs(power: power(percent: 80, onAC: true, charging: true), awake: .none, cutoff: 10))
        XCTAssertEqual(charging.line, "charging · the cutoff only applies on battery")
        XCTAssertNotNil(charging.bar, "the bar still shows on AC")
        let onAC = PowerPage.hero(PowerInputs(power: power(percent: 80, onAC: true), awake: .none, cutoff: 10))
        XCTAssertEqual(onAC.line, "on AC · the cutoff only applies on battery")
    }

    func testHeroWithNoBatteryIsAC() {
        let hero = PowerPage.hero(PowerInputs(power: .noBattery, awake: .none, cutoff: 10))
        XCTAssertEqual(hero.bigText, "AC")
        XCTAssertNil(hero.bar)
        XCTAssertEqual(hero.line, "no battery in this Mac · agents keep it awake until they stop")
    }

    func testHeroWhilePausedNamesTheCutoffAndResume() {
        for phase in [BatteryPolicy.Phase.grace, .drained] {
            let hero = PowerPage.hero(PowerInputs(power: power(percent: 10), phase: phase, awake: .none, cutoff: 10,
                                                  recoveryThreshold: 25))
            XCTAssertEqual(hero.line, "paused at the 10% cutoff · agents resume at 25%", "\(phase)")
        }
    }

    func testHeroWithPauseOffSaysTheMacStopsBeingKeptAwake() {
        let hero = PowerPage.hero(PowerInputs(power: power(), forecast: forecast41(), awake: .none, cutoff: 10, action: .off))
        XCTAssertNil(hero.bar?.pauseEarly)
        XCTAssertEqual(hero.line, "on battery · at 10% the Mac stops being kept awake")
    }

    func testHeroWithoutAForecastSaysSo() {
        let hero = PowerPage.hero(PowerInputs(power: power(), awake: .none, cutoff: 10, action: .pause))
        XCTAssertEqual(hero.line, "on battery · cutoff at 10% · the forecast needs a few minutes of drain")
        let atCutoff = PowerPage.hero(PowerInputs(power: power(percent: 10), awake: .none, cutoff: 10, action: .pause))
        XCTAssertEqual(atCutoff.line, "on battery · at the cutoff now")
    }

    func testPauseEarlyMarkerDimsWhenTheToggleIsOff() {
        let hero = PowerPage.hero(PowerInputs(power: power(), forecast: forecast41(), awake: .none, cutoff: 10,
                                              action: .pause, earlyPause: false))
        XCTAssertEqual(hero.bar?.pauseEarlyOn, false)
        XCTAssertNotNil(hero.bar?.pauseEarly)
    }

    func testMinutesToCutoff() {
        XCTAssertEqual(PowerPage.minutesToCutoff(percent: 41, cutoff: 10, drainPerHour: 17), 109)
        XCTAssertEqual(PowerPage.minutesToCutoff(percent: 10, cutoff: 10, drainPerHour: 17), 0)
        XCTAssertEqual(PowerPage.minutesToCutoff(percent: 5, cutoff: 10, drainPerHour: 17), 0)
        XCTAssertNil(PowerPage.minutesToCutoff(percent: 41, cutoff: 10, drainPerHour: 0))
    }

    func testPauseEarlyPercent() {
        XCTAssertEqual(PowerPage.pauseEarlyPercent(cutoff: 10, drainPerHour: 60), 20)
        XCTAssertEqual(PowerPage.pauseEarlyPercent(cutoff: 10, drainPerHour: 17), 13)
        XCTAssertEqual(PowerPage.pauseEarlyPercent(cutoff: 10, drainPerHour: nil), 15, "nominal 30 points an hour")
        XCTAssertEqual(PowerPage.pauseEarlyPercent(cutoff: 10, drainPerHour: 1), 11, "at least one point above the cutoff")
        XCTAssertEqual(PowerPage.pauseEarlyPercent(cutoff: 99, drainPerHour: 60), 100, "never above 100")
    }

    func testLidChipStates() {
        let blocked = PowerPage.lidChip(PowerInputs(power: power(), awake: .none, lidBlocker: "Something holds the lid",
                                                    cutoff: 10, keepAwakeLidClosedOnBattery: true))
        XCTAssertEqual(blocked, LidChip(text: "Something holds the lid", tone: .blocked))
        XCTAssertEqual(PowerPage.lidChip(PowerInputs(power: power(), awake: .none, lidClosedOnBattery: true, cutoff: 10)),
                       LidChip(text: "Lid closed · awake on battery", tone: .active))
        XCTAssertEqual(PowerPage.lidChip(PowerInputs(power: power(percent: 80, onAC: true), awake: .none, cutoff: 10,
                                                     keepAwakeLidClosedOnAC: true)),
                       LidChip(text: "Lid closed · awake while agents work", tone: .active))
        XCTAssertEqual(PowerPage.lidChip(PowerInputs(power: power(percent: 80, onAC: true), awake: .none, cutoff: 10,
                                                     keepAwakeLidClosedOnAC: false)),
                       LidChip(text: "Lid closed · the Mac sleeps", tone: .idle))
        XCTAssertEqual(PowerPage.lidChip(PowerInputs(power: power(), awake: .none, cutoff: 10,
                                                     keepAwakeLidClosedOnBattery: false)),
                       LidChip(text: "Lid closed · the Mac sleeps", tone: .idle))
        XCTAssertEqual(PowerPage.lidChip(PowerInputs(power: .noBattery, awake: .none, cutoff: 10, keepAwakeLidClosedOnAC: true))?.tone,
                       .active, "a desktop is judged by the AC option")
    }

    func testResumeDetailWording() {
        XCTAssertEqual(PowerPage.resumeDetail(recoveryThreshold: 25, requiresAC: true), "when back on AC at 25%")
        XCTAssertEqual(PowerPage.resumeDetail(recoveryThreshold: 40, requiresAC: false), "when back at 40%")
    }

    // MARK: Budget page

    private func usage(fivePct: Double = 62, sevenPct: Double? = 30, fiveReset: Date?, sevenReset: Date? = nil,
                       updatedAt: Date) -> UsageSnapshot {
        UsageSnapshot(fiveHour: .init(pct: fivePct, resetsAt: fiveReset),
                      sevenDay: sevenPct.map { UsageSnapshot.Window(pct: $0, resetsAt: sevenReset) },
                      updatedAt: updatedAt)
    }

    func testBudgetRingsForBothWindows() {
        let now = utcDate(26, 1, 0)
        let u = usage(fiveReset: utcDate(26, 3, 0), sevenReset: utcDate(28, 23, 0), updatedAt: now.addingTimeInterval(-60))
        let b = BudgetModel.build(usage: u, hitAt: nil, now: now, timeZone: utc)
        XCTAssertEqual(b.rings.map(\.kind), [.fiveHour, .sevenDay])
        XCTAssertEqual(b.rings.map(\.kind.rawValue), ["5-hour", "7-day"])
        XCTAssertEqual(b.rings.map(\.percentText), ["62%", "30%"])
        XCTAssertEqual(b.rings[0].progress, 0.62, accuracy: 1e-9)
        XCTAssertEqual(b.rings[1].progress, 0.30, accuracy: 1e-9)
        XCTAssertEqual(b.rings[0].resetText, "resets 03:00")
        XCTAssertNil(b.forecastLine)
        XCTAssertEqual(b.updatedLine, "updated just now")
    }

    func testBudgetWithoutAResetTimeSaysSo() {
        let now = utcDate(26, 1, 0)
        let b = BudgetModel.build(usage: usage(fiveReset: nil, updatedAt: now), hitAt: nil, now: now, timeZone: utc)
        XCTAssertEqual(b.rings[0].resetText, "no reset time")
    }

    func testBudgetForecastLineNamesTheHitTime() {
        let now = utcDate(26, 1, 0)
        let b = BudgetModel.build(usage: usage(sevenPct: nil, fiveReset: utcDate(26, 3, 0), updatedAt: now),
                                  hitAt: utcDate(26, 2, 40), now: now, timeZone: utc)
        XCTAssertTrue(b.forecastLine?.hasPrefix("At this pace you’ll hit the 5-hour limit around ") ?? false, b.forecastLine ?? "nil")
        XCTAssertTrue(b.forecastLine?.hasSuffix("02:40") ?? false)
        XCTAssertEqual(b.rings.count, 1, "no seven-day window captured")
    }

    func testBudgetWithNoUsageIsEmpty() {
        let b = BudgetModel.build(usage: nil, hitAt: utcDate(26, 2, 40), now: now, timeZone: utc)
        XCTAssertTrue(b.rings.isEmpty)
        XCTAssertNil(b.forecastLine)
        XCTAssertNil(b.updatedLine)
    }

    func testBudgetUpdatedLineAgesOut() {
        let now = utcDate(26, 1, 0)
        let old = BudgetModel.build(usage: usage(fiveReset: nil, updatedAt: now.addingTimeInterval(-120)), hitAt: nil, now: now, timeZone: utc)
        XCTAssertEqual(old.updatedLine, "updated 2 min ago")
    }

    func testBudgetRingIsHighAtEightyPercent() {
        XCTAssertTrue(BudgetRing(kind: .fiveHour, progress: 0.8, percentText: "80%", resetText: "").isHigh)
        XCTAssertFalse(BudgetRing(kind: .fiveHour, progress: 0.79, percentText: "79%", resetText: "").isHigh)
    }

    func testBudgetProgressIsClamped() {
        let now = utcDate(26, 1, 0)
        let b = BudgetModel.build(usage: usage(fivePct: 150, fiveReset: nil, updatedAt: now), hitAt: nil, now: now, timeZone: utc)
        XCTAssertEqual(b.rings[0].progress, 1)
    }

    // MARK: shortcuts

    func testShortcutGroupsAreTheThreeSpecGroups() {
        XCTAssertEqual(ShortcutCatalog.groups.map(\.title), ["ANYWHERE", "IN THE NOW PANEL", "IN THE MENU"])
    }

    func testShortcutsIncludeEveryKeyTheTrustModelNames() {
        let keys = ShortcutCatalog.groups.flatMap(\.items).map(\.keys)
        for expected in [["⌥", "⌘", "P"], ["⌘", "N"], ["↑", "↓"], ["1"], ["↵"], ["esc"], ["T"], ["O"],
                                    ["hold", "⌘", "."], ["⌘", "P"], ["⌘", ","], ["⌘", "L"], ["⌘", "R"], ["⌘", "Q"]] {
            XCTAssertTrue(keys.contains(expected), "missing \(expected)")
        }
        XCTAssertNotEqual(["⌥", "⌘", "P"], ["⌘", "P"], "the Now panel and Pair phone are different keys")
    }

    func testNoShortcutIsTwoOrAutoAllow() {
        for item in ShortcutCatalog.groups.flatMap(\.items) {
            XCTAssertFalse(item.keys.contains("2"), item.title)
            let text = (item.title + " " + item.detail + " " + item.keys.joined(separator: " ")).lowercased()
            XCTAssertFalse(text.contains("always allow"), item.title)
            XCTAssertFalse(text.contains("auto"), "\(item.title): \(text)")
            XCTAssertFalse(text.contains("don't ask"), item.title)
        }
    }

    // MARK: the control map

    func testEveryPreferencesFieldAppearsOnceInTheMap() {
        let mirrored = Mirror(reflecting: PreferencesForm(Config())).children.compactMap { $0.label }
        XCTAssertEqual(mirrored.count, 35)
        XCTAssertEqual(TowerControlMap.fieldNames.count, mirrored.count)
        XCTAssertEqual(Set(TowerControlMap.fieldNames), Set(mirrored))
        XCTAssertEqual(Set(TowerControlMap.fieldNames).count, TowerControlMap.fieldNames.count, "no field twice")
    }

    func testActionsAreAllMapped() {
        let text = TowerControlMap.entries.map { ($0.old + " " + $0.newControl).lowercased() }
        for keyword in ["usage capture", "power helper", "reset to defaults", "cancel", "apply", "cmux",
                        "hooks", "diagnostics", "pair phone", "config", "open log", "reload config",
                        "kitty", "automation", "get it"] {
            XCTAssertTrue(text.contains { $0.contains(keyword) }, "no action for \(keyword)")
        }
    }

    func testEverySectionHasAnEntry() {
        for section in TowerSection.allCases {
            XCTAssertTrue(TowerControlMap.entries.contains { $0.section == section }, "no control home in \(section.title)")
        }
    }

    func testSectionSubtitlesAreShort() {
        for s in TowerSection.allCases {
            XCTAssertFalse(s.subtitle.isEmpty, s.title)
            XCTAssertLessThanOrEqual(s.subtitle.count, 120, s.title)
        }
    }

    // MARK: agents and phones

    func testBackendLineReadsSessionCounts() {
        let seven = Coordinator.BackendInfo(id: .claude, displayName: "Claude Code", enabled: true,
                                            sessionCount: 7, activeCount: 5, waitingCount: 2)
        XCTAssertEqual(TowerAgents.backendLine(seven, fallback: "—"), "7 sessions · 5 active · 2 waiting")
        let one = Coordinator.BackendInfo(id: .claude, displayName: "Claude Code", enabled: true,
                                          sessionCount: 1, activeCount: 0, waitingCount: 0)
        XCTAssertEqual(TowerAgents.backendLine(one, fallback: "—"), "1 session")
        let off = Coordinator.BackendInfo(id: .codex, displayName: "Codex", enabled: false,
                                          sessionCount: 0, activeCount: 0, waitingCount: 0)
        XCTAssertEqual(TowerAgents.backendLine(off, fallback: "—"), "off")
        XCTAssertEqual(TowerAgents.backendLine(nil, fallback: "not running"), "not running")
    }

    func testBackendProblemWinsOverCounts() {
        let broken = Coordinator.BackendInfo(id: .codex, displayName: "Codex", enabled: true, sessionCount: 2,
                                             activeCount: 0, waitingCount: 0, problem: "codex wasn’t found")
        XCTAssertEqual(TowerAgents.backendLine(broken, fallback: "—"), "codex wasn’t found")
    }

    func testRelayChipByState() {
        XCTAssertEqual(TowerPhone.relayChip(.connected), TowerPhone.RelayChip(text: "Relay connected", tone: .good))
        XCTAssertEqual(TowerPhone.relayChip(.connecting).tone, .working)
        XCTAssertEqual(TowerPhone.relayChip(.off), TowerPhone.RelayChip(text: "Phone relay off", tone: .quiet))
        XCTAssertEqual(TowerPhone.relayChip(nil), TowerPhone.RelayChip(text: "Phone relay off", tone: .quiet))
        XCTAssertEqual(TowerPhone.relayChip(.misconfigured("x")), TowerPhone.RelayChip(text: "Relay not set up · x", tone: .bad))
    }
}
