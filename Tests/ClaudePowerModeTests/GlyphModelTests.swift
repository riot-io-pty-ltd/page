import XCTest
@testable import ClaudePowerMode

/// The menu-bar glyph: which state it shows, the battery arc, and the drawing
/// numbers for each state (including Reduce Motion).
final class GlyphModelTests: XCTestCase {
    private func battery(_ percent: Int, onAC: Bool = false, hasBattery: Bool = true) -> PowerSnapshot {
        PowerSnapshot(percent: percent, onAC: onAC, hasBattery: hasBattery, isCharging: false)
    }

    // MARK: headroom

    func testHeadroomIsTheShareAboveTheCutoff() {
        XCTAssertEqual(GlyphState.headroom(power: battery(55), cutoff: 10) ?? -1, 0.5, accuracy: 1e-9)
    }

    func testHeadroomIsNilWhenThereIsNoBatteryToWatch() {
        XCTAssertNil(GlyphState.headroom(power: battery(55, onAC: true), cutoff: 10), "on AC")
        XCTAssertNil(GlyphState.headroom(power: battery(-1, hasBattery: false), cutoff: 10), "no battery")
        XCTAssertNil(GlyphState.headroom(power: battery(55), cutoff: 100), "cutoff 100 leaves no span")
    }

    func testHeadroomIsClampedToTheUnitRange() {
        XCTAssertEqual(GlyphState.headroom(power: battery(5), cutoff: 10), 0)
        XCTAssertEqual(GlyphState.headroom(power: battery(100), cutoff: 10), 1)
        XCTAssertEqual(GlyphState.headroom(power: battery(10), cutoff: 10), 0)
    }

    // MARK: mode precedence

    func testModePrecedence() {
        XCTAssertEqual(GlyphState.mode(paused: true, needYou: 2, working: 3, keepingAwake: true), .paused)
        XCTAssertEqual(GlyphState.mode(paused: false, needYou: 2, working: 3, keepingAwake: true), .needsYou(count: 2))
        XCTAssertEqual(GlyphState.mode(paused: false, needYou: 0, working: 3, keepingAwake: true), .working(agents: 3))
        XCTAssertEqual(GlyphState.mode(paused: false, needYou: 0, working: 0, keepingAwake: true), .quiet)
        XCTAssertEqual(GlyphState.mode(paused: false, needYou: 0, working: 0, keepingAwake: false), .off)
    }

    // MARK: drawing

    func testNeedsYouDrawsTheCountAmberWithTwoRipples() {
        let d = GlyphDrawing.make(GlyphState(mode: .needsYou(count: 2)), phase: 0.25)
        XCTAssertEqual(d.countText, "2")
        XCTAssertEqual(d.dotColor, NightWatch.Palette.amber)
        XCTAssertEqual(d.ripples.count, 2)
        XCTAssertFalse(d.staticRing)
    }

    func testNeedsYouWithReduceMotionIsAStillRing() {
        let d = GlyphDrawing.make(GlyphState(mode: .needsYou(count: 2)), phase: 0.25, reduceMotion: true)
        XCTAssertTrue(d.staticRing)
        XCTAssertTrue(d.ripples.isEmpty)
        XCTAssertEqual(d.countText, "2")
    }

    func testCountIsCappedAtNinetyNinePlus() {
        XCTAssertEqual(GlyphDrawing.make(GlyphState(mode: .needsYou(count: 100))).countText, "99+")
        XCTAssertEqual(GlyphDrawing.make(GlyphState(mode: .needsYou(count: 99))).countText, "99")
    }

    func testWidthGrowsWithTheCount() {
        let two = GlyphDrawing.make(GlyphState(mode: .needsYou(count: 2)))
        let twelve = GlyphDrawing.make(GlyphState(mode: .needsYou(count: 12)))
        XCTAssertEqual(twelve.width - two.width, GlyphDrawing.countWidth, accuracy: 1e-9)
        XCTAssertGreaterThan(GlyphDrawing.make(GlyphState(mode: .needsYou(count: 2))).width, GlyphDrawing.side)
        XCTAssertEqual(GlyphDrawing.make(GlyphState(mode: .working(agents: 1))).width, GlyphDrawing.side, accuracy: 1e-9)
    }

    func testWorkingBreathesUnlessReduceMotion() {
        let calm = GlyphDrawing.make(GlyphState(mode: .working(agents: 1)), phase: 0)
        let peak = GlyphDrawing.make(GlyphState(mode: .working(agents: 1)), phase: 0.25)
        XCTAssertNotEqual(calm.dotRadius, peak.dotRadius, "breathes with the phase")
        XCTAssertEqual(calm.dotColor, NightWatch.Palette.teal)
        let still = GlyphDrawing.make(GlyphState(mode: .working(agents: 1)), phase: 0.25, reduceMotion: true)
        let stillOther = GlyphDrawing.make(GlyphState(mode: .working(agents: 1)), phase: 0.0, reduceMotion: true)
        XCTAssertEqual(still.dotRadius, stillOther.dotRadius, "fixed under Reduce Motion")
        XCTAssertEqual(still.dotRadius, 3.2, accuracy: 1e-9)
    }

    func testOffIsHollow() {
        let d = GlyphDrawing.make(GlyphState(mode: .off))
        XCTAssertTrue(d.hollow)
        XCTAssertEqual(d.dotColor, GlyphDrawing.colors(.dark).neutral.opacity(0.8))
    }

    func testQuietUsesStarWhiteOnADarkBar() {
        XCTAssertEqual(GlyphDrawing.make(GlyphState(mode: .quiet), appearance: .dark).dotColor, NightWatch.Palette.star)
        XCTAssertFalse(GlyphDrawing.make(GlyphState(mode: .quiet)).hollow)
    }

    func testPausedHasAHorizonAndADimmedDot() {
        let d = GlyphDrawing.make(GlyphState(mode: .paused))
        XCTAssertTrue(d.horizon)
        XCTAssertEqual(d.dotColor, NightWatch.Palette.teal.opacity(0.4))
        XCTAssertEqual(d.glow, 0.15, accuracy: 1e-9)
    }

    func testModifiersFollowTheirOwnFlags() {
        let lid = GlyphDrawing.make(GlyphState(mode: .quiet, lidClosedAwake: true))
        XCTAssertTrue(lid.moonTick)
        XCTAssertFalse(GlyphDrawing.make(GlyphState(mode: .quiet, lidClosedAwake: false)).moonTick)

        let phone = GlyphDrawing.make(GlyphState(mode: .quiet, phoneArmed: true))
        XCTAssertTrue(phone.phoneBadge)
        XCTAssertFalse(GlyphDrawing.make(GlyphState(mode: .quiet, phoneArmed: false)).phoneBadge)
    }

    func testHeadroomArcTurnsAmberWhenLow() {
        let high = GlyphDrawing.make(GlyphState(mode: .quiet, headroom: 0.5))
        XCTAssertEqual(high.arc, 0.5)
        XCTAssertEqual(high.arcColor, NightWatch.Palette.teal)
        let low = GlyphDrawing.make(GlyphState(mode: .quiet, headroom: 0.2))
        XCTAssertEqual(low.arcColor, NightWatch.Palette.amber)
        XCTAssertNil(GlyphDrawing.make(GlyphState(mode: .quiet)).arc, "no arc without a battery")
    }

    // MARK: timing

    func testBreathPeriod() {
        XCTAssertEqual(GlyphDrawing.breathPeriod(agents: 1), 4.0, accuracy: 1e-9)
        XCTAssertLessThan(GlyphDrawing.breathPeriod(agents: 10), 4.0)
        XCTAssertGreaterThanOrEqual(GlyphDrawing.breathPeriod(agents: 10), 2.5)
        XCTAssertEqual(GlyphDrawing.breathPeriod(agents: 1000), 2.5, accuracy: 1e-9, "never below 2.5 s")
        XCTAssertEqual(GlyphDrawing.breathPeriod(agents: 0), 4.0, accuracy: 1e-9)
    }

    func testRippleIntervalShortensWithTheWaitButNeverBelowOneAndAHalf() {
        XCTAssertEqual(GlyphDrawing.rippleInterval(longestWait: 0), 4.0, accuracy: 1e-9)
        XCTAssertEqual(GlyphDrawing.rippleInterval(longestWait: 120), 3.0, accuracy: 1e-9)
        XCTAssertEqual(GlyphDrawing.rippleInterval(longestWait: 3600), 1.5, accuracy: 1e-9)
    }

    func testCyclePhaseWrapsIntoTheUnitInterval() {
        XCTAssertEqual(GlyphDrawing.cyclePhase(at: 1.25, period: 1), 0.25, accuracy: 1e-9)
        XCTAssertEqual(GlyphDrawing.cyclePhase(at: -0.25, period: 1), 0.75, accuracy: 1e-9)
        XCTAssertEqual(GlyphDrawing.cyclePhase(at: 3, period: 0), 0)
        for t in stride(from: -10.0, through: 10.0, by: 0.37) {
            let p = GlyphDrawing.cyclePhase(at: t, period: 2.5)
            XCTAssertTrue((0..<1).contains(p), "phase \(p) at \(t)")
        }
    }

    func testOnlyMovingStatesAnimate() {
        XCTAssertTrue(GlyphAnimator.animates(.working(agents: 1)))
        XCTAssertTrue(GlyphAnimator.animates(.needsYou(count: 1)))
        XCTAssertFalse(GlyphAnimator.animates(.off))
        XCTAssertFalse(GlyphAnimator.animates(.quiet))
        XCTAssertFalse(GlyphAnimator.animates(.paused))
    }

    func testQuantisedPhaseRepeatsWithinAStep() {
        XCTAssertEqual(GlyphAnimator.quantised(0.26, steps: 24), GlyphAnimator.quantised(0.27, steps: 24))
        XCTAssertNotEqual(GlyphAnimator.quantised(0.26, steps: 24), GlyphAnimator.quantised(0.31, steps: 24))
        XCTAssertEqual(GlyphAnimator.quantised(0.999), 23.0 / 24.0, accuracy: 1e-9)
        let a = GlyphDrawing.make(GlyphState(mode: .working(agents: 2)), phase: GlyphAnimator.quantised(0.261))
        let b = GlyphDrawing.make(GlyphState(mode: .working(agents: 2)), phase: GlyphAnimator.quantised(0.265))
        XCTAssertEqual(a, b, "two frames in one step are the same drawing, so the second is skipped")
    }

    func testModifiersGetTheirOwnColumnOutsideTheArc() {
        let plain = GlyphDrawing.make(GlyphState(mode: .working(agents: 1), headroom: 0.5))
        let both = GlyphDrawing.make(GlyphState(mode: .working(agents: 1), lidClosedAwake: true, headroom: 0.5, phoneArmed: true))
        XCTAssertEqual(plain.dotArea, GlyphDrawing.side)
        XCTAssertEqual(both.dotArea, GlyphDrawing.side + GlyphDrawing.modifierColumn)
        XCTAssertGreaterThan(both.dotArea - 4.8, 9.5 + 7.6 + 0.6, "the badge starts beyond the arc's outer edge")
    }

    func testPausedWithPagesWaitingKeepsTheAmberCount() {
        let quiet = GlyphDrawing.make(GlyphState(mode: .paused))
        XCTAssertNil(quiet.countText)
        let waiting = GlyphDrawing.make(GlyphState(mode: .paused, waiting: 2))
        XCTAssertEqual(waiting.countText, "2")
        XCTAssertTrue(waiting.horizon, "still the dusk horizon")
        XCTAssertTrue(waiting.ripples.isEmpty && !waiting.staticRing, "no ripple at dusk")
        XCTAssertEqual(waiting.dotColor.r, NightWatch.Palette.amber.r, accuracy: 1e-9)
        XCTAssertEqual(GlyphDrawing.make(GlyphState(mode: .quiet, waiting: 3)).countText, nil, "only a paused glyph uses it")
    }
}
