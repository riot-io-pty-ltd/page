import XCTest
@testable import ClaudePowerMode

/// The Terminals catalog, pure: each host's status from its facts, the rows
/// and their one action, the summary line and the sentences the Tower prints.
/// Every fact is handed in, so nothing here reads the machine.
final class TerminalCatalogTests: XCTestCase {
    private typealias C = TerminalCatalog

    private func facts(installed: Bool = true, typable: Int = 0, blocked: Int = 0,
                       blocker: String? = nil, setup: C.SetupState = .notNeeded) -> C.Facts {
        C.Facts(installed: installed, use: C.HostUse(typable: typable, blocked: blocked, blocker: blocker), setup: setup)
    }

    private func host(_ name: String, canType: Bool, blocker: String? = nil) -> SessionHostInfo {
        SessionHostInfo(host: name, canType: canType, typeBlocker: blocker, canInterrupt: canType)
    }

    private func row(_ id: C.ID, _ rows: [C.Row]) -> C.Row {
        rows.first { $0.id == id }!
    }

    private func statusRow(_ status: C.Status) -> C.Row {
        C.Row(id: .tmux, name: "x", symbol: "x", capabilityLine: "", note: "", status: status, action: nil)
    }

    private func isNotInstalled(_ status: C.Status) -> Bool {
        if case .notInstalled = status { return true }
        return false
    }

    // MARK: status

    func testTypableSessionsMeanInUse() {
        XCTAssertEqual(C.status(C.entry(.tmux), facts(typable: 2)), .inUse(2))
    }

    func testOnlySessionsPageCanTypeIntoAreCountedInUse() {
        XCTAssertEqual(C.status(C.entry(.kitty), facts(typable: 1, blocked: 1, blocker: "x")), .inUse(1))
    }

    func testABlockedSessionBesideAWorkingOneIsNamedInAnAmberNote() {
        let rows = C.rows([.kitty: facts(typable: 1, blocked: 1, blocker: "no socket")])
        let r = row(.kitty, rows)
        XCTAssertEqual(r.status, .inUse(1))
        XCTAssertEqual(r.note, "1 session can't be typed into: no socket")
        XCTAssertTrue(r.noteIsWarning)
        let two = row(.wezterm, C.rows([.wezterm: facts(typable: 1, blocked: 2, blocker: "b")]))
        XCTAssertEqual(two.note, "2 sessions can't be typed into: b")
    }

    func testAHostWithNothingBlockedHasNoWarning() {
        let rows = C.rows([.tmux: facts(typable: 2)])
        XCTAssertFalse(row(.tmux, rows).noteIsWarning)
        XCTAssertEqual(row(.tmux, rows).note, "Nothing to set up — run Claude inside it")
    }

    func testKittyWithItsLinesInPlaceButBlockedSessionsSaysRestartNotAddTheLines() {
        let f: [C.ID: C.Facts] = [.kitty: facts(blocked: 1, blocker: KittyBridge.remoteControlHint, setup: .done)]
        let added = row(.kitty, C.rows(f, pageAddedKittyLines: true))
        XCTAssertEqual(added.status, .needsSetup("Restart kitty to turn on the lines Page added"))
        XCTAssertEqual(added.note, "Restart kitty to turn on the lines Page added")
        XCTAssertEqual(added.action, .undo)
        let byUser = row(.kitty, C.rows(f, pageAddedKittyLines: false))
        XCTAssertEqual(byUser.status, .needsSetup("Restart kitty to turn on the remote control lines in kitty.conf"))
        XCTAssertNil(byUser.action)
    }

    func testKittyBlockedBeforeItsLinesExistStillOffersSetUp() {
        let f: [C.ID: C.Facts] = [.kitty: facts(blocked: 1, blocker: "add the lines", setup: .needed("off"))]
        let r = row(.kitty, C.rows(f))
        XCTAssertEqual(r.status, .needsSetup("add the lines"))
        XCTAssertEqual(r.action, .setUp(label: "Set up…"))
    }

    func testARunningKittyThatNeverReadTheLinesIsNeedsSetupEvenWithNoSession() {
        let f: [C.ID: C.Facts] = [.kitty: facts(setup: .needsRestart)]
        let r = row(.kitty, C.rows(f, pageAddedKittyLines: true))
        XCTAssertEqual(r.status, .needsSetup("Restart kitty to turn on the lines Page added"))
        XCTAssertEqual(r.action, .undo)
        XCTAssertTrue(r.noteIsWarning)
    }

    func testBlockedAndWorkingKittySessionsAlongsideRestartNote() {
        let f: [C.ID: C.Facts] = [.kitty: facts(typable: 1, blocked: 1, blocker: KittyBridge.remoteControlHint, setup: .done)]
        let r = row(.kitty, C.rows(f, pageAddedKittyLines: true))
        XCTAssertEqual(r.note, "1 session can't be typed into: Restart kitty to turn on the lines Page added")
        XCTAssertEqual(r.action, .undo)
    }

    func testOnlyBlockedSessionsMeanNeedsSetupWithTheHostsReason() {
        XCTAssertEqual(C.status(C.entry(.kitty), facts(blocked: 1, blocker: "x")), .needsSetup("x"))
    }

    func testBlockedWithNoReasonGetsAFallback() {
        XCTAssertEqual(C.status(C.entry(.wezterm), facts(blocked: 1)), .needsSetup("Page can't type into it yet"))
    }

    func testTerminalAndITermStillNeedingAutomationAreNeedsSetupEvenWhenTypable() {
        XCTAssertEqual(C.status(C.entry(.terminal), facts(typable: 1, setup: .needed("why"))), .needsSetup("why"))
        XCTAssertEqual(C.status(C.entry(.iTerm), facts(typable: 1, setup: .needed("why"))), .needsSetup("why"))
    }

    func testTmuxAndKittyStayInUseWhileTheirSetupIsNeeded() {
        XCTAssertEqual(C.status(C.entry(.tmux), facts(typable: 1, setup: .needed("why"))), .inUse(1))
        XCTAssertEqual(C.status(C.entry(.kitty), facts(typable: 1, setup: .needed("why"))), .inUse(1))
    }

    func testEveryHostWithNoSessionsAndNotInstalledLinksItsSite() {
        for entry in C.entries {
            XCTAssertEqual(C.status(entry, facts(installed: false)), .notInstalled(entry.downloadURL), entry.name)
        }
    }

    func testARunningSessionCountsEvenWhenTheAppIsNotInstalled() {
        XCTAssertEqual(C.status(C.entry(.iTerm), facts(installed: false, typable: 1)), .inUse(1))
    }

    func testBlockedSessionsOnANotInstalledHostAreNeedsSetupNotNotInstalled() {
        XCTAssertEqual(C.status(C.entry(.herdr), facts(installed: false, blocked: 1, blocker: "x")), .needsSetup("x"))
    }

    func testAnInstalledHostWithSetupNeededNeedsSetup() {
        XCTAssertEqual(C.status(C.entry(.cmux), facts(setup: .needed("w"))), .needsSetup("w"))
    }

    func testAnInstalledHostIsReadyWhenSetupIsDoneNotNeededOrUnchecked() {
        for setup in [C.SetupState.done, .notNeeded, .unchecked] {
            XCTAssertEqual(C.status(C.entry(.kitty), facts(setup: setup)), .ready, "\(setup)")
        }
    }

    func testTerminalAndITermAreOnlyReadyOnceMacOSHasSaidYes() {
        for id in [C.ID.terminal, .iTerm] {
            XCTAssertEqual(C.status(C.entry(id), facts(setup: .done)), .ready, "\(id)")
            XCTAssertEqual(C.status(C.entry(id), facts(setup: .unchecked)), .notChecked, "\(id)")
        }
    }

    func testEveryHostReadsInUseReadyAndNeedsSetupTheSameWay() {
        for entry in C.entries {
            XCTAssertEqual(C.status(entry, facts(typable: 1, setup: .done)), .inUse(1), entry.name)
            XCTAssertEqual(C.status(entry, facts(setup: .done)), .ready, entry.name)
            XCTAssertEqual(C.status(entry, facts(blocked: 1, blocker: "b")), .needsSetup("b"), entry.name)
        }
    }

    func testChipTextIsWhatTheRowShows() {
        XCTAssertEqual(C.Status.inUse(2).chipText, "In use · 2")
        XCTAssertEqual(C.Status.ready.chipText, "Ready")
        XCTAssertEqual(C.Status.notChecked.chipText, "Not checked")
        XCTAssertEqual(C.Status.needsSetup("x").chipText, "Needs setup")
        XCTAssertEqual(C.Status.notInstalled(C.entry(.tmux).downloadURL).chipText, "Not installed")
    }

    // MARK: facts from sessions

    func testHostUseCountsEachHostAndIgnoresTheRest() {
        let use = C.hostUse(from: [host("tmux", canType: true), host("tmux", canType: true),
                                   host("kitty", canType: false, blocker: "r"), host("Ghostty", canType: true),
                                   host("unknown", canType: true)])
        XCTAssertEqual(Set(use.keys), Set([C.ID.tmux, .kitty]))
        XCTAssertEqual(use[.tmux], C.HostUse(typable: 2, blocked: 0, blocker: nil))
        XCTAssertEqual(use[.kitty], C.HostUse(typable: 0, blocked: 1, blocker: "r"))
    }

    func testWireNamesMapToTheirHosts() {
        let use = C.hostUse(from: [host("iTerm2", canType: true), host("Claude Squad", canType: false, blocker: "b")])
        XCTAssertEqual(use[.iTerm]?.typable, 1)
        XCTAssertEqual(use[.claudeSquad]?.blocked, 1)
    }

    func testTheFirstBlockerOfAHostIsKept() {
        let use = C.hostUse(from: [host("kitty", canType: false, blocker: "a"), host("kitty", canType: false, blocker: "b")])
        XCTAssertEqual(use[.kitty]?.blocker, "a")
        XCTAssertEqual(use[.kitty]?.blocked, 2)
    }

    func testWireHostsResolveToIDs() {
        XCTAssertEqual(C.id(forWireHost: "iTerm"), .iTerm)
        XCTAssertEqual(C.id(forWireHost: "iTerm2"), .iTerm)
        XCTAssertEqual(C.id(forWireHost: "Terminal"), .terminal)
        XCTAssertNil(C.id(forWireHost: "VS Code"))
        XCTAssertNil(C.id(forWireHost: "Ghostty"))
    }

    func testEveryEntryResolvesFromItsOwnWireName() {
        for entry in C.entries {
            XCTAssertEqual(C.id(forWireHost: entry.wireHost), entry.id, entry.name)
        }
    }

    // MARK: the catalog

    func testEveryHostIsListedOnce() {
        XCTAssertEqual(C.entries.count, 8)
        XCTAssertEqual(Set(C.entries.map(\.id)), Set(C.ID.allCases))
    }

    func testEveryHostCanBeRepliedTo() {
        for entry in C.entries { XCTAssertTrue(entry.capabilities.reply, entry.name) }
    }

    func testOnlyCmuxCanStartSessions() {
        XCTAssertEqual(C.entries.filter { $0.capabilities.startSessions }.map(\.id), [.cmux])
    }

    func testOnlyTerminalCannotStopATurn() {
        XCTAssertEqual(C.entries.filter { !$0.capabilities.interrupt }.map(\.id), [.terminal])
    }

    func testCapabilityLinesReadAsTheTowerPrintsThem() {
        XCTAssertEqual(C.entry(.cmux).capabilities.line, "Reply · see the screen · stop a turn · start sessions")
        XCTAssertEqual(C.entry(.terminal).capabilities.line, "Reply")
        XCTAssertEqual(C.Capabilities(reply: false).line, "")
    }

    func testNamesLineListsTheHostsInCatalogOrder() {
        XCTAssertEqual(C.namesLine, "Terminal, iTerm2, tmux, cmux, WezTerm, kitty, Herdr and Claude Squad")
    }

    func testEveryHostLinksToAnHTTPSSite() {
        for entry in C.entries { XCTAssertEqual(entry.downloadURL.scheme, "https", entry.name) }
    }

    // MARK: rows

    func testEmptyFactsMakeEveryRowNotInstalled() {
        let rows = C.rows([:])
        XCTAssertEqual(rows.count, 8)
        for r in rows { XCTAssertTrue(isNotInstalled(r.status), r.name) }
    }

    func testRowsKeepCatalogOrder() {
        XCTAssertEqual(C.rows([:]).map(\.id), C.entries.map(\.id))
    }

    func testRowsCarryTheCapabilityLine() {
        let rows = C.rows([:])
        XCTAssertEqual(row(.cmux, rows).capabilityLine, C.entry(.cmux).capabilities.line)
    }

    func testANotInstalledHostGetsItButtonToItsSite() {
        let rows = C.rows([:])
        XCTAssertEqual(row(.herdr, rows).action, .getIt(C.entry(.herdr).downloadURL))
        XCTAssertEqual(row(.herdr, rows).action?.title, "Get it ↗")
    }

    func testITermNeedingAutomationOffersAllow() {
        let rows = C.rows([.iTerm: facts(setup: .needed("x"))])
        XCTAssertEqual(row(.iTerm, rows).status, .needsSetup("x"))
        XCTAssertEqual(row(.iTerm, rows).action, .allow)
    }

    func testKittyNeedingSetupOffersSetUp() {
        let rows = C.rows([.kitty: facts(setup: .needed("x"))])
        XCTAssertEqual(row(.kitty, rows).action, .setUp(label: "Set up…"))
    }

    func testKittyWithPageLinesOffersUndoAndWithoutThemNoButton() {
        let f: [C.ID: C.Facts] = [.kitty: facts(setup: .done)]
        XCTAssertEqual(row(.kitty, C.rows(f, pageAddedKittyLines: true)).action, .undo)
        XCTAssertNil(row(.kitty, C.rows(f, pageAddedKittyLines: false)).action)
    }

    func testCmuxNeedingItsSocketOffersSetUp() {
        let rows = C.rows([.cmux: facts(setup: .needed("x"))])
        XCTAssertEqual(row(.cmux, rows).action, .setUp(label: "Set up…"))
    }

    func testAReadyHostWithNothingToDoHasNoButtonAndSaysSo() {
        let rows = C.rows([.wezterm: facts(setup: .notNeeded)])
        XCTAssertEqual(row(.wezterm, rows).status, .ready)
        XCTAssertNil(row(.wezterm, rows).action)
        XCTAssertEqual(row(.wezterm, rows).note, "Nothing to set up — run Claude inside it")
    }

    func testTerminalWithUncheckedAutomationIsNotCheckedAndOffersAllow() {
        let rows = C.rows([.terminal: facts(setup: .unchecked)])
        XCTAssertEqual(row(.terminal, rows).status, .notChecked)
        XCTAssertEqual(row(.terminal, rows).action, .allow)
        XCTAssertEqual(row(.terminal, rows).note, "Open Terminal or click Allow… to check")
        XCTAssertFalse(row(.terminal, rows).noteIsWarning)
    }

    func testITermWithUncheckedAutomationAsksToOpenITerm2() {
        let rows = C.rows([.iTerm: facts(setup: .unchecked)])
        XCTAssertEqual(row(.iTerm, rows).note, "Open iTerm2 or click Allow… to check")
    }

    func testTerminalWithPermissionGrantedHasNoButton() {
        let rows = C.rows([.terminal: facts(setup: .done)])
        XCTAssertNil(row(.terminal, rows).action)
    }

    func testTheActionTitlesAreTheButtonLabels() {
        XCTAssertEqual(C.Action.allow.title, "Allow…")
        XCTAssertEqual(C.Action.undo.title, "Undo")
        XCTAssertEqual(C.Action.setUp(label: "Set up…").title, "Set up…")
    }

    // MARK: summary

    func testSummaryCountsInUseAndHostsNeedingSetup() {
        let statuses: [C.Status] = [.inUse(1), .inUse(2), .inUse(1), .needsSetup("a"), .needsSetup("b"),
                                    .needsSetup("c"), .ready, .notInstalled(URL(string: "https://example.com")!)]
        XCTAssertEqual(C.summary(statuses.map { statusRow($0) }), "3 of 8 in use · 3 need setup")
    }

    func testOneHostNeedingSetupIsSingular() {
        let statuses: [C.Status] = [.needsSetup("a")] + Array(repeating: C.Status.ready, count: 7)
        XCTAssertEqual(C.summary(statuses.map { statusRow($0) }), "0 of 8 in use · 1 needs setup")
    }

    func testNothingNeedingSetupLeavesThatPartOut() {
        XCTAssertEqual(C.summary(Array(repeating: C.Status.ready, count: 8).map { statusRow($0) }), "0 of 8 in use")
    }

    // MARK: the sentences

    func testKittyConfirmShowsBothLinesThePathAndTheBackup() {
        let text = C.kittyConfirmText(path: "/home/k/kitty.conf",
                                      added: [KittyConfigFile.allowLine, KittyConfigFile.listenLine], creating: false)
        XCTAssertTrue(text.contains(KittyConfigFile.allowLine))
        XCTAssertTrue(text.contains(KittyConfigFile.listenLine))
        XCTAssertTrue(text.contains("/home/k/kitty.conf"))
        XCTAssertTrue(text.contains("kitty.conf.bak-page-"))
        XCTAssertTrue(text.contains("Restart kitty"))
    }

    func testKittyConfirmNamesTheFileALinkPointsAt() {
        let text = C.kittyConfirmText(path: "/home/k/kitty.conf", added: [KittyConfigFile.allowLine],
                                      creating: false, linkTarget: "/home/k/dotfiles/kitty.conf")
        XCTAssertTrue(text.contains("/home/k/dotfiles/kitty.conf"), text)
        XCTAssertTrue(text.contains("is a link to it"), text)
    }

    func testKittyConfirmSaysThereIsNothingToBackUpWhenCreating() {
        let text = C.kittyConfirmText(path: "/k/kitty.conf", added: [KittyConfigFile.allowLine], creating: true)
        XCTAssertTrue(text.contains("nothing to back up"))
        XCTAssertFalse(text.contains("bak-page"))
    }

    func testKittyDoneSaysSoWhenNothingWasAdded() {
        let outcome = KittyConfigFile.Outcome(url: URL(fileURLWithPath: "/k/kitty.conf"), backup: nil, added: [])
        XCTAssertEqual(C.kittyDoneText(outcome), TowerStatusLine(text: "kitty already lets Page in.", tone: .good))
    }

    func testKittyDoneNamesTheFileAndTheBackup() {
        let outcome = KittyConfigFile.Outcome(url: URL(fileURLWithPath: "/k/kitty.conf"),
                                              backup: URL(fileURLWithPath: "/k/kitty.conf.bak-page-20260101-000000"),
                                              added: [KittyConfigFile.allowLine])
        let line = C.kittyDoneText(outcome)
        XCTAssertEqual(line.tone, .good)
        XCTAssertTrue(line.text.contains("/k/kitty.conf"), line.text)
        XCTAssertTrue(line.text.contains("kitty.conf.bak-page-20260101-000000"), line.text)
        XCTAssertTrue(line.text.contains("Restart kitty"), line.text)
    }

    func testAutomationNoticeForDeniedIsBadAndPointsAtSystemSettings() {
        let line = C.automationNotice(.denied, appName: "iTerm2")
        XCTAssertEqual(line.tone, .bad)
        XCTAssertTrue(line.text.contains("System Settings"), line.text)
    }

    func testAutomationNoticeForGrantedIsGood() {
        XCTAssertEqual(C.automationNotice(.granted, appName: "Terminal").tone, .good)
    }

    func testAutomationNoticeForTheOthersSaysWhatToDo() {
        XCTAssertEqual(C.automationNotice(.notAsked, appName: "Terminal").tone, .quiet)
        XCTAssertEqual(C.automationNotice(.appNotRunning, appName: "Terminal").tone, .bad)
        XCTAssertTrue(C.automationNotice(.appNotRunning, appName: "Terminal").text.contains("Open it"))
        XCTAssertEqual(C.automationNotice(.unknown, appName: "Terminal").tone, .bad)
    }
}
