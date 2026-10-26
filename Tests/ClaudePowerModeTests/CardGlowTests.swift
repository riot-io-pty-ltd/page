import Combine
import XCTest
@testable import ClaudePowerMode

/// The Mac "Card glow" setting, end to end: the enum and its tokens, the
/// config key (default, old files, bad values, round trip), the Preferences
/// merge rules, the Tower control, the bottom-glow falloff, the live appearance
/// value and the render harness flag.
final class CardGlowTests: XCTestCase {

    /// Decodes a config the way `Config.loadResult` does, collecting per-key issues.
    private func decodeConfig(_ json: String) throws -> (config: Config, issues: [String]) {
        let issues = Config.DecodeIssues()
        let decoder = JSONDecoder()
        decoder.userInfo[Config.decodeIssuesKey] = issues
        let config = try decoder.decode(Config.self, from: Data(json.utf8))
        return (config, issues.messages)
    }

    // MARK: - The enum and its tokens

    func testRawValuesAreOffSubtleFull() {
        XCTAssertEqual(CardGlow.off.rawValue, "off")
        XCTAssertEqual(CardGlow.subtle.rawValue, "subtle")
        XCTAssertEqual(CardGlow.full.rawValue, "full")
    }

    func testIntensityIsZeroHalfAndOne() {
        XCTAssertEqual(CardGlow.off.intensity, 0)
        XCTAssertEqual(CardGlow.subtle.intensity, 0.5)
        XCTAssertEqual(CardGlow.full.intensity, 1)
    }

    func testLabelsAreOffSubtleFull() {
        XCTAssertEqual(CardGlow.off.label, "Off")
        XCTAssertEqual(CardGlow.subtle.label, "Subtle")
        XCTAssertEqual(CardGlow.full.label, "Full")
    }

    func testCaseIterableOrderIsOffSubtleFull() {
        XCTAssertEqual(CardGlow.allCases, [.off, .subtle, .full])
    }

    func testTowerDetailLinesAreDistinctAndNonEmpty() {
        let lines = CardGlow.allCases.map { TowerOptions.cardGlowDetail($0) }
        XCTAssertEqual(Set(lines).count, 3, "each level has its own line")
        XCTAssertTrue(lines.allSatisfy { !$0.isEmpty })
    }

    // MARK: - Default and config decoding

    func testDefaultConfigIsOff() {
        XCTAssertEqual(Config().cardGlow, .off)
    }

    func testMissingKeyDecodesToOffWithoutAnIssue() throws {
        let (config, issues) = try decodeConfig("{}")
        XCTAssertEqual(config.cardGlow, .off)
        XCTAssertEqual(issues, [], "a missing key is not a problem")
    }

    func testOldConfigWithoutTheFieldKeepsEveryOtherValue() throws {
        let json = #"{"lowBatteryCutoff": 15, "relayEnabled": true, "keepAwakeLidClosedOnBattery": true, "carryOnPrompt": "go on"}"#
        let (config, issues) = try decodeConfig(json)
        XCTAssertEqual(config.cardGlow, .off)
        XCTAssertEqual(config.lowBatteryCutoff, 15)
        XCTAssertTrue(config.relayEnabled)
        XCTAssertTrue(config.keepAwakeLidClosedOnBattery)
        XCTAssertEqual(config.carryOnPrompt, "go on")
        XCTAssertEqual(issues, [])
    }

    func testSubtleAndFullDecode() throws {
        XCTAssertEqual(try decodeConfig(#"{"cardGlow": "subtle"}"#).config.cardGlow, .subtle)
        XCTAssertEqual(try decodeConfig(#"{"cardGlow": "full"}"#).config.cardGlow, .full)
        XCTAssertEqual(try decodeConfig(#"{"cardGlow": "off"}"#).config.cardGlow, .off)
    }

    func testUnknownStringFallsBackToOffAndIsReported() throws {
        let (config, issues) = try decodeConfig(#"{"cardGlow": "neon", "lowBatteryCutoff": 15}"#)
        XCTAssertEqual(config.cardGlow, .off)
        XCTAssertEqual(config.lowBatteryCutoff, 15, "one bad key does not cost the others")
        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue(issues.first?.contains("cardGlow") ?? false, issues.first ?? "nil")
    }

    func testWrongTypeFallsBackToOffAndIsReported() throws {
        for json in [#"{"cardGlow": 1}"#, #"{"cardGlow": true}"#, #"{"cardGlow": ["full"]}"#] {
            let (config, issues) = try decodeConfig(json)
            XCTAssertEqual(config.cardGlow, .off, json)
            XCTAssertEqual(issues.count, 1, json)
            XCTAssertTrue(issues.first?.contains("cardGlow") ?? false, json)
        }
    }

    func testRoundTripsThroughEncodeAndDecode() throws {
        for level in CardGlow.allCases {
            var original = Config()
            original.cardGlow = level
            let data = try JSONEncoder().encode(original)

            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(object?["cardGlow"] as? String, level.rawValue, "written as its raw value")

            let issues = Config.DecodeIssues()
            let decoder = JSONDecoder()
            decoder.userInfo[Config.decodeIssuesKey] = issues
            let decoded = try decoder.decode(Config.self, from: data)
            XCTAssertEqual(decoded.cardGlow, level)
            XCTAssertEqual(decoded, original)
            XCTAssertEqual(issues.messages, [])
        }
    }

    // MARK: - Preferences merge and reset

    func testFormShowsTheSavedLevel() {
        var c = Config()
        c.cardGlow = .subtle
        XCTAssertEqual(PreferencesForm(c).cardGlow, .subtle)
        XCTAssertEqual(PreferencesForm(Config()).cardGlow, .off)
    }

    func testMergeWritesCardGlowWhenTheControlChanged() {
        let baseline = PreferencesForm(Config())
        var form = baseline
        form.cardGlow = .subtle
        XCTAssertEqual(form.merged(onto: Config(), changedFrom: baseline).cardGlow, .subtle)
    }

    func testMergeWritesEachChangedLevel() {
        let baseline = PreferencesForm(Config())
        for level in [CardGlow.subtle, .full] {
            var form = baseline
            form.cardGlow = level
            XCTAssertEqual(form.merged(onto: Config(), changedFrom: baseline).cardGlow, level, level.rawValue)
        }
    }

    func testMergeKeepsAHandEditedValueWhenTheControlDidNotChange() {
        // config.json was hand-edited to "full" while the window was open;
        // the window still shows what it opened with, and the control is untouched.
        var onDisk = Config()
        onDisk.cardGlow = .full
        let baseline = PreferencesForm(Config())
        let form = baseline
        XCTAssertEqual(form.merged(onto: onDisk, changedFrom: baseline).cardGlow, .full)
    }

    func testMergeLeavesOtherHandEditedFieldsAlone() {
        var onDisk = Config()
        onDisk.lowBatteryCutoff = 15
        let baseline = PreferencesForm(Config())
        var form = baseline
        form.cardGlow = .full
        let merged = form.merged(onto: onDisk, changedFrom: baseline)
        XCTAssertEqual(merged.cardGlow, .full)
        XCTAssertEqual(merged.lowBatteryCutoff, 15, "a field the control did not touch keeps its hand edit")
    }

    func testResetToDefaultsReturnsOff() {
        var form = PreferencesForm(Config())
        form.cardGlow = .full
        XCTAssertEqual(form.resetToDefaults().cardGlow, .off)
    }

    func testResetThenSaveWritesOff() {
        var c = Config()
        c.cardGlow = .full
        let baseline = PreferencesForm(c)
        let reset = baseline.resetToDefaults()
        XCTAssertEqual(reset.merged(onto: c, changedFrom: baseline).cardGlow, .off)
    }

    // MARK: - Bottom glow falloff

    func testFalloffIsOneAtTheCentreAndZeroAtTheEdge() {
        XCTAssertEqual(NWBottomGlow.falloff(0), 1, accuracy: 1e-12)
        XCTAssertEqual(NWBottomGlow.falloff(1), 0, accuracy: 1e-12)
    }

    func testFalloffClampsOutsideZeroToOne() {
        XCTAssertEqual(NWBottomGlow.falloff(-0.5), NWBottomGlow.falloff(0), accuracy: 1e-12)
        XCTAssertEqual(NWBottomGlow.falloff(-1e9), 1, accuracy: 1e-12)
        XCTAssertEqual(NWBottomGlow.falloff(1.5), NWBottomGlow.falloff(1), accuracy: 1e-12)
        XCTAssertEqual(NWBottomGlow.falloff(1e9), 0, accuracy: 1e-12)
    }

    func testFalloffIsMonotonicallyNonIncreasing() {
        let steps = 1000
        var previous = NWBottomGlow.falloff(0)
        for i in 1...steps {
            let value = NWBottomGlow.falloff(Double(i) / Double(steps))
            XCTAssertLessThanOrEqual(value, previous + 1e-12, "rises at step \(i)")
            previous = value
        }
    }

    func testFalloffHasNoHardBandAndApproachesZeroSmoothly() {
        // No step between neighbouring samples is large: a hard band would jump.
        let steps = 1000
        var largestJump = 0.0
        var previous = NWBottomGlow.falloff(0)
        for i in 1...steps {
            let value = NWBottomGlow.falloff(Double(i) / Double(steps))
            largestJump = max(largestJump, previous - value)
            previous = value
        }
        XCTAssertLessThan(largestJump, 0.01)

        // It is already close to nothing well before the edge, and never a flat band.
        XCTAssertLessThan(NWBottomGlow.falloff(0.9), 0.001)
        XCTAssertLessThan(NWBottomGlow.falloff(0.99), 0.000001)
        XCTAssertGreaterThan(NWBottomGlow.falloff(0.5), 0)
        XCTAssertLessThan(NWBottomGlow.falloff(0.5), 1)
    }

    // MARK: - Live appearance value

    func testSetCardGlowPublishesOnlyWhenTheValueChanges() {
        let appearance = NWAppearance()
        var seen: [CardGlow] = []
        var cancellables = Set<AnyCancellable>()
        appearance.$cardGlow.sink { seen.append($0) }.store(in: &cancellables)

        appearance.set(cardGlow: .off)   // same as the start: no publish
        appearance.set(cardGlow: .full)
        appearance.set(cardGlow: .full)  // same again: no publish
        appearance.set(cardGlow: .off)

        XCTAssertEqual(seen, [.off, .full, .off], "the initial value, then one publish per change")
    }

    // MARK: - Render harness flag

    func testRenderFlagParsesEachLevel() {
        XCTAssertEqual(RenderHarness.cardGlow(arguments: ["ClaudePowerMode", "--card-glow", "off"]), .off)
        XCTAssertEqual(RenderHarness.cardGlow(arguments: ["ClaudePowerMode", "--card-glow", "subtle"]), .subtle)
        XCTAssertEqual(RenderHarness.cardGlow(arguments: ["ClaudePowerMode", "--card-glow", "full"]), .full)
    }

    func testRenderFlagDefaultsToOff() {
        XCTAssertEqual(RenderHarness.cardGlow(arguments: []), .off, "flag absent")
        XCTAssertEqual(RenderHarness.cardGlow(arguments: ["--render-ui", "out"]), .off, "flag absent")
        XCTAssertEqual(RenderHarness.cardGlow(arguments: ["--card-glow"]), .off, "value missing")
        XCTAssertEqual(RenderHarness.cardGlow(arguments: ["--card-glow", "neon"]), .off, "unknown value")
    }

    func testRenderFlagFindsItsValueAmongOtherArguments() {
        XCTAssertEqual(RenderHarness.cardGlow(arguments: ["--render-ui", "out", "--card-glow", "full"]), .full)
    }

    // MARK: - Tower control map

    func testCardGlowIsMappedExactlyOnceInTheAboutSection() {
        let entries = TowerControlMap.entries.filter { $0.old == "cardGlow" }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.section, .about)
        XCTAssertEqual(TowerControlMap.fieldNames.filter { $0 == "cardGlow" }.count, 1)
    }

    func testPreferencesFormHasThirtyFiveFieldsWithOneCardGlow() {
        let fields = Mirror(reflecting: PreferencesForm(Config())).children.compactMap { $0.label }
        XCTAssertEqual(fields.count, 35)
        XCTAssertEqual(fields.filter { $0 == "cardGlow" }.count, 1)
    }
}
