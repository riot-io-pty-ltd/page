import XCTest
import PageWidgetSupport

/// Where a click on a widget goes: `page-mac://now`, `page-mac://item/<id>`,
/// `page-mac://widgets`. A route only ever shows; nothing in a URL approves,
/// denies or types.
final class WidgetRouteTests: XCTestCase {
    private func url(_ s: String) -> URL { URL(string: s)! }

    func testBuildsTheThreeRoutes() {
        XCTAssertEqual(WidgetRoute.now.url.absoluteString, "page-mac://now")
        XCTAssertEqual(WidgetRoute.widgets.url.absoluteString, "page-mac://widgets")
        XCTAssertEqual(WidgetRoute.item(id: "sess-bottle-flip-permission-1").url.absoluteString,
                       "page-mac://item/sess-bottle-flip-permission-1")
    }

    func testEveryRouteParsesBackToItself() {
        let routes: [WidgetRoute] = [.now, .widgets, .item(id: "sess-bottle-flip-permission-1"),
                                     .item(id: "inflight-local-ollama"), .item(id: "sess.x_y~1"),
                                     .item(id: "sess a b")]
        for r in routes {
            XCTAssertEqual(WidgetRoute.parse(r.url), r, "\(r) did not round trip through \(r.url)")
        }
    }

    func testAnIdWithPercentEncodableCharactersRoundTrips() {
        let id = "sess-é?#&=+"
        XCTAssertEqual(WidgetRoute.parse(WidgetRoute.item(id: id).url), .item(id: id))
    }

    func testAnyOtherHostIsRefused() {
        // No route may approve, deny, type or stop anything.
        for s in ["page-mac://approve/sess-a", "page-mac://deny/sess-a", "page-mac://type?text=yes",
                  "page-mac://stop", "page-mac://", "page-mac:now"] {
            XCTAssertNil(WidgetRoute.parse(url(s)), "\(s) should not be a route")
        }
    }

    func testAnotherSchemeIsRefused() {
        for s in ["https://now", "page://now", "page-mac-dev://now", "file:///Applications/Page.app", "mailto:x@y.z"] {
            XCTAssertNil(WidgetRoute.parse(url(s)), "\(s) should not be a route")
        }
    }

    func testItemNeedsOneSafeId() {
        XCTAssertNil(WidgetRoute.parse(url("page-mac://item")))
        XCTAssertNil(WidgetRoute.parse(url("page-mac://item/")))
        XCTAssertNil(WidgetRoute.parse(url("page-mac://item/a/b")), "a second path segment is not an id")
        XCTAssertNil(WidgetRoute.parse(url("page-mac://item/a%0Ab")), "a control character is not an id")
        XCTAssertNil(WidgetRoute.parse(url("page-mac://item/a%09b")), "a tab is not an id")
    }

    func testIdLengthIsCappedAtTheRouteLimit() {
        let ok = String(repeating: "x", count: WidgetRoute.maxIdLength)
        let tooLong = String(repeating: "x", count: WidgetRoute.maxIdLength + 1)
        XCTAssertEqual(WidgetRoute.parse(url("page-mac://item/" + ok)), .item(id: ok))
        XCTAssertNil(WidgetRoute.parse(url("page-mac://item/" + tooLong)))
    }

    func testQueryAndFragmentAreIgnoredNotObeyed() {
        XCTAssertEqual(WidgetRoute.parse(url("page-mac://now?approve=1")), .now)
        XCTAssertEqual(WidgetRoute.parse(url("page-mac://item/sess-a?approve=1#deny")), .item(id: "sess-a"))
        XCTAssertEqual(WidgetRoute.parse(url("page-mac://widgets?open=1")), .widgets)
    }

    /// An id with a slash travels as %2F and comes back as the same id; a raw second segment is still refused.
    func testAnIdWithASlashStillRoundTrips() {
        XCTAssertEqual(WidgetRoute.parse(WidgetRoute.item(id: "sess/with/slash").url), .item(id: "sess/with/slash"))
    }
}
