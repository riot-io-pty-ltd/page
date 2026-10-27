import Foundation

/// Where a click on a widget goes. Page registers `page-mac://`; the widget
/// puts one of these URLs on the widget (or on a row of the large one) and the
/// app turns it into "show the popover here". A route only ever shows or
/// selects: nothing a URL can say approves, denies or types anything.
public enum WidgetRoute: Equatable {
    /// The popover.
    case now
    /// The popover with this row (a decision or an in-flight card) selected.
    case item(id: String)
    /// The Tower, on its Widgets page.
    case widgets

    public static let maxIdLength = 160

    public var url: URL {
        var c = URLComponents()
        c.scheme = PageWidgetConstants.urlScheme
        switch self {
        case .now:
            c.host = "now"
        case .item(let id):
            c.host = "item"
            c.percentEncodedPath = "/" + (id.addingPercentEncoding(withAllowedCharacters: Self.idAllowed) ?? "")
        case .widgets:
            c.host = "widgets"
        }
        return c.url ?? URL(string: "\(PageWidgetConstants.urlScheme)://now")!
    }

    private static let idAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    /// Pure. The route a URL names, or nil for anything else (another scheme,
    /// an unknown host, an empty or oversized or control-character id).
    public static func parse(_ url: URL) -> WidgetRoute? {
        guard url.scheme?.lowercased() == PageWidgetConstants.urlScheme,
              let host = url.host?.lowercased() else { return nil }
        switch host {
        case "now": return .now
        case "widgets": return .widgets
        case "item":
            // The id as it was encoded: a "/" inside it travels as %2F, so a raw "/" after the first one is a
            // second path segment, not part of the id.
            let encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
            let tail = encoded.hasPrefix("/") ? String(encoded.dropFirst()) : encoded
            guard !tail.contains("/"), let raw = tail.removingPercentEncoding,
                  !raw.isEmpty, raw.count <= maxIdLength,
                  raw.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
            return .item(id: raw)
        default: return nil
        }
    }
}
