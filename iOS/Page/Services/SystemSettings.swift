import Foundation
import UIKit

/// Jumps out to iOS Settings.
enum SystemSettings {
    @MainActor
    static func openNotifications() {
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
    }
}
