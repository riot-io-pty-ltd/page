import Foundation
import PageWidgetSupport

/// Page's widget extension and macOS: is it known, and tell macOS about it.
/// Page cannot place a widget (macOS has no API for that); this does the part
/// before it, so the widgets are in the gallery the moment the user looks.
enum WidgetSetup {
    static let pluginkit = "/usr/bin/pluginkit"
    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    /// The reasons a copy cannot have widgets. The Widgets page chooses its hint by these, so they are
    /// constants, not loose strings.
    enum Unavailable {
        static let notAnApp = "This copy of Page isn’t an app (it runs from a build folder), so it has no widgets"
        static let noExtension = "This copy of Page was built without its widgets"
        static let noTeam = "This copy of Page isn’t signed with a developer team, so its widgets couldn’t get any data"
        static let noAnswer = "Couldn’t ask macOS about widgets (pluginkit didn’t answer)"
        static let noneHere = "No widgets in this copy of Page"
    }

    typealias Run = (_ path: String, _ args: [String]) -> ProcessRunner.Result

    /// The extension inside this app bundle, when this is a signed app that has one.
    /// Pure given the file system.
    static func bundledExtension(bundle: Bundle = .main, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        -> (app: String, appex: String)? {
        let app = bundle.bundlePath
        guard app.hasSuffix(".app") else { return nil }
        let appex = WidgetRegistration.extensionPath(inApp: app)
        return fileExists(appex) ? (app, appex) : nil
    }

    /// Why there is nothing to look for, or nil when this copy can have widgets.
    static func unavailableReason(bundle: Bundle = .main, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        if !bundle.bundlePath.hasSuffix(".app") {
            return Unavailable.notAnApp
        }
        if bundledExtension(bundle: bundle, fileExists: fileExists) == nil {
            return Unavailable.noExtension
        }
        if PageWidgetConstants.appGroup(bundle: bundle) == nil {
            return Unavailable.noTeam
        }
        return nil
    }

    /// Looks the extension up with pluginkit. Blocking: call off the main queue.
    static func status(bundle: Bundle = .main, run: Run = { ProcessRunner.run($0, $1, timeout: 8) }) -> WidgetRegistration.Status {
        if let why = unavailableReason(bundle: bundle) { return .unavailable(reason: why) }
        guard let found = bundledExtension(bundle: bundle) else { return .unavailable(reason: Unavailable.noneHere) }
        let r = run(pluginkit, ["-m", "-A", "-D", "-v", "-i", PageWidgetConstants.extensionBundleID])
        guard r.launched, !r.timedOut else { return .unavailable(reason: Unavailable.noAnswer) }
        return WidgetRegistration.parse(pluginkitOutput: r.stdout, expectedPath: found.appex)
    }

    /// Tells LaunchServices about this app and pluginkit about its extension, then looks again.
    /// Only ever this bundle's own paths. Blocking: call off the main queue.
    @discardableResult
    static func register(bundle: Bundle = .main, run: Run = { ProcessRunner.run($0, $1, timeout: 15) }) -> WidgetRegistration.Status {
        guard unavailableReason(bundle: bundle) == nil, let found = bundledExtension(bundle: bundle) else {
            return status(bundle: bundle, run: run)
        }
        // -R descends into the package to reach the extension; -trusted is what made pluginkit list it.
        _ = run(lsregister, ["-f", "-R", "-trusted", found.app])
        _ = run(pluginkit, ["-a", found.appex])
        // pluginkit takes a moment to publish what it was told.
        Thread.sleep(forTimeInterval: 1.0)
        return status(bundle: bundle, run: run)
    }

    /// At launch: when macOS has never heard of the widgets (a fresh install,
    /// a moved app), say so once, quietly. Never when the user switched them off.
    static func registerIfMissing(log: (String) -> Void = { Logger.shared.log($0) }) {
        switch status() {
        case .notRegistered, .elsewhere:
            let after = register()
            log("Widgets: registering with macOS → \(WidgetRegistration.line(after).text)")
        default: break
        }
    }
}
