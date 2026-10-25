import Foundation
import WidgetKit

/// Keeps the widget's copy of the relay credentials in step with the
/// pairing, and asks WidgetKit to redraw when what it shows has changed.
@MainActor
enum WidgetShare {
    /// Writes the current pairing's URL, token and Mac name into the shared
    /// Keychain group, or deletes the copy when not paired.
    static func sync() {
        if let creds = RelayCredentials.current() {
            SharedWidgetStore.save(SharedWidgetCredentials(url: creds.baseURL.absoluteString, token: creds.token,
                                                           macName: PairingStore.currentMacName()))
        } else {
            SharedWidgetStore.save(nil)
        }
        reload()
    }

    private static var lastKey: String?

    /// Redraws the widget, at most once per change of what it shows.
    static func reload(needsYou: Int? = nil, working: Int? = nil) {
        let key = "\(needsYou.map(String.init) ?? "-")|\(working.map(String.init) ?? "-")"
        if needsYou != nil || working != nil {
            guard key != lastKey else { return }
            lastKey = key
        }
        WidgetCenter.shared.reloadAllTimelines()
    }
}
