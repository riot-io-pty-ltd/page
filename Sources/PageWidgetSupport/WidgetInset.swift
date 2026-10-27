import SwiftUI
import WidgetKit

/// The safe inset under the faces. The faces draw with no padding of their own because the system
/// adds content margins around `containerBackground` content (macOS 14 and later). When a widget is
/// treated as built for an older macOS the system adds none, and a face then runs to the rounded
/// edge and is clipped. `WidgetSafeInset` reads the margins the system reports and adds only what is
/// missing up to a minimum, so a normal 16-point margin is never doubled.
public enum WidgetInset {
    /// The least margin, in points, a face keeps from each edge (the macOS desktop's own is 16).
    public static let minimum = 12.0

    /// Pure. What to add to a margin the system reports so the edge keeps `minimum`.
    public static func extra(systemMargin: Double, minimum: Double = WidgetInset.minimum) -> Double {
        max(0, minimum - max(0, systemMargin))
    }
}

public struct WidgetSafeInset: ViewModifier {
    public init() {}

    @ViewBuilder
    public func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            SafeInsetReader(content: content)
        } else {
            content // before macOS 14 the extension pads by hand (see pageBackground)
        }
    }
}

@available(macOS 14.0, *)
private struct SafeInsetReader<Content: View>: View {
    let content: Content
    @Environment(\.widgetContentMargins) private var margins

    var body: some View {
        content
            .padding(.top, WidgetInset.extra(systemMargin: Double(margins.top)))
            .padding(.leading, WidgetInset.extra(systemMargin: Double(margins.leading)))
            .padding(.bottom, WidgetInset.extra(systemMargin: Double(margins.bottom)))
            .padding(.trailing, WidgetInset.extra(systemMargin: Double(margins.trailing)))
    }
}
