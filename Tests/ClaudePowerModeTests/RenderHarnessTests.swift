import XCTest
@testable import ClaudePowerMode

/// The render harness (`--render-ui <dir>`): how its directory argument is
/// read, and which surfaces it promises to draw. The renders themselves are
/// checked by eye, not here.
final class RenderHarnessTests: XCTestCase {
    func testTheDirectoryIsTheArgumentAfterTheFlag() {
        XCTAssertEqual(RenderHarness.flag, "--render-ui")
        XCTAssertEqual(RenderHarness.outputDirectory(arguments: ["x", "--render-ui", "/tmp/o"]), "/tmp/o")
        XCTAssertNil(RenderHarness.outputDirectory(arguments: ["x"]))
        XCTAssertNil(RenderHarness.outputDirectory(arguments: ["x", "--render-ui"]), "the flag with no directory")
        XCTAssertNil(RenderHarness.outputDirectory(arguments: []))
    }

    @MainActor
    func testEverySurfaceHasAUniqueName() {
        let names = RenderSurfaces.all().map(\.name)
        XCTAssertFalse(names.isEmpty)
        XCTAssertEqual(Set(names).count, names.count, "duplicate surface names")
    }

    @MainActor
    func testTheTowerSurfacesAreAllThere() {
        let names = Set(RenderSurfaces.all().map(\.name))
        let expected = ["tower-power", "tower-budget", "tower-macsPhones", "tower-attention", "tower-agents",
                        "tower-shortcuts", "tower-pairing", "tower-about",
                        "tower-power-tall", "tower-budget-tall", "tower-macsPhones-tall", "tower-attention-tall",
                        "tower-agents-tall", "tower-power-ac-custom-tall", "tower-macs-phones-problem", "tower-budget-empty"]
        for name in expected {
            XCTAssertTrue(names.contains(name), "missing surface \(name)")
        }
    }

    @MainActor
    func testTowerSurfacesRenderAtAFixedHeight() {
        let towers = RenderSurfaces.all().filter { $0.name.hasPrefix("tower-") }
        XCTAssertFalse(towers.isEmpty)
        for s in towers {
            XCTAssertNotNil(s.height, "\(s.name) renders at its own height")
        }
        for s in towers where s.name.hasSuffix("-tall") {
            XCTAssertEqual(s.height, 1500 + 28 * 2, s.name)
        }
    }

    @MainActor
    func testThePopoverAndPanelSurfacesAreThere() {
        let names = Set(RenderSurfaces.all().map(\.name))
        for name in ["popover-needs-you", "popover-selected", "popover-composer", "popover-hold", "popover-stop-hold",
                     "popover-failed-receipt", "popover-overflow", "popover-all-quiet", "popover-stopped",
                     "popover-paused", "popover-on-battery", "popover-starting", "dispatch", "dispatch-failed",
                     "welcome-back", "welcome-back-calm", "welcome-back-phone", "components", "glyphs"] {
            XCTAssertTrue(names.contains(name), "missing surface \(name)")
        }
    }
}
