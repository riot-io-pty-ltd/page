import Foundation

/// Whether macOS knows Page's widget extension, read from `pluginkit`, and
/// where System Settings keeps the switches. Pure: the app runs the command
/// and hands the text here.
public enum WidgetRegistration {
    public enum Status: Equatable {
        /// Not looked yet.
        case checking
        /// macOS has the extension, at `path`, and it is switched on.
        case registered(path: String)
        /// macOS has it, but the user turned it off in System Settings.
        case disabled(path: String)
        /// macOS knows an extension with this id at another path than the app
        /// that is running (an old copy, a build folder).
        case elsewhere(path: String)
        /// macOS has never heard of it.
        case notRegistered
        /// This copy of Page has no extension to register (a build from a
        /// terminal, or unsigned), so there is nothing to look for.
        case unavailable(reason: String)
    }

    /// Pure. `pluginkit -m -A -D -v -i <id>` output: lines like
    /// `+    local.Page.widgets(1.0)\t<uuid>\t<date>\t/Applications/Page.app/Contents/PlugIns/PageWidgets.appex`.
    /// The first column is the user's election (`man pluginkit`): `+` on, `-` off,
    /// `!` elected for debugger use (it is in use, so it counts as on), `=`
    /// superseded by another plug-in (another copy of Page's widgets is the one
    /// macOS uses), `?` or blank unset (which counts as on, as macOS does).
    public static func parse(pluginkitOutput: String, id: String = PageWidgetConstants.extensionBundleID,
                             expectedPath: String?) -> Status {
        struct Hit { var flag: Character; var path: String }
        var hits: [Hit] = []
        for rawLine in pluginkitOutput.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard line.contains(id + "(") || line.contains(id + "\t") else { continue }
            let flag = line.first(where: { !$0.isWhitespace }).flatMap { "+-!?=".contains($0) ? $0 : nil } ?? " "
            let fields = line.split(separator: "\t", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let path = fields.last(where: { $0.hasPrefix("/") }) else { continue }
            hits.append(Hit(flag: flag, path: path))
        }
        guard !hits.isEmpty else { return .notRegistered }
        func same(_ a: String, _ b: String) -> Bool {
            URL(fileURLWithPath: a).resolvingSymlinksInPath().path == URL(fileURLWithPath: b).resolvingSymlinksInPath().path
        }
        let mine = expectedPath.flatMap { e in hits.first { same($0.path, e) } }
        guard let hit = mine ?? (expectedPath == nil ? hits.first : nil) else { return .elsewhere(path: hits[0].path) }
        if hit.flag == "=" {
            // This copy is the one macOS passed over: name the copy it uses instead, when it lists one.
            return .elsewhere(path: hits.first { $0.path != hit.path && $0.flag != "=" }?.path ?? hit.path)
        }
        return hit.flag == "-" ? .disabled(path: hit.path) : .registered(path: hit.path)
    }

    /// Pure. The words under the status chip, and whether it is good news.
    public static func line(_ s: Status) -> (text: String, good: Bool) {
        switch s {
        case .checking: return ("Checking whether macOS sees Page’s widgets…", false)
        case .registered: return ("macOS sees Page’s widgets", true)
        case .disabled: return ("Page’s widgets are switched off in System Settings (Login Items & Extensions → Widgets)", false)
        case .elsewhere(let path): return ("macOS has Page’s widgets from another copy of Page (\(abbreviate(path))), not this one", false)
        case .notRegistered: return ("macOS hasn’t found Page’s widgets yet", false)
        case .unavailable(let reason): return (reason, false)
        }
    }

    /// Pure. "~/Downloads/Page.app" for a path inside the home folder.
    public static func abbreviate(_ path: String, home: String = NSHomeDirectory()) -> String {
        let trimmed = path.components(separatedBy: "/Contents/PlugIns/").first ?? path
        if trimmed == home { return "~" }
        // `home + "/"`, so /Users/roysinclairX is not read as inside /Users/roysinclair.
        let prefix = home.hasSuffix("/") ? home : home + "/"
        return trimmed.hasPrefix(prefix) ? "~/" + trimmed.dropFirst(prefix.count) : trimmed
    }

    /// Pure. Where the extension should be inside an app bundle at `bundlePath`.
    public static func extensionPath(inApp bundlePath: String) -> String {
        bundlePath + "/Contents/PlugIns/" + PageWidgetConstants.extensionName
    }

    /// Pure. The System Settings pane for desktop and Notification Center
    /// widgets. macOS 13 and later keep it in Desktop & Dock (pane
    /// `com.apple.Desktop-Settings.extension`); macOS 12 only has the Dock
    /// pane, since widgets there live in Notification Center alone.
    public static func settingsURL(osMajor: Int) -> URL {
        let pane = osMajor >= 13 ? "com.apple.Desktop-Settings.extension" : "com.apple.preference.dock"
        return URL(string: "x-apple.systempreferences:\(pane)")!
    }

    /// Pure. The one line that says where to go in this macOS.
    public static func settingsPath(osMajor: Int) -> String {
        osMajor >= 14 ? "System Settings → Desktop & Dock → Widgets"
            : (osMajor == 13 ? "System Settings → Desktop & Dock" : "System Preferences → Dock")
    }

    /// Pure. Whether this macOS can put widgets on the desktop (macOS 14);
    /// before that they live in Notification Center only.
    public static func hasDesktopWidgets(osMajor: Int) -> Bool { osMajor >= 14 }
}
