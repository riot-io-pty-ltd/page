// swift-tools-version:5.9
import PackageDescription

// Three targets:
//  - PageWidgetSupport: what the app and the widget extension share. The
//    snapshot Page writes, the routes a click opens, how widgets are looked up
//    in macOS, and the widget views. Foundation and SwiftUI only (it is linked
//    into an app extension, so nothing here may touch AppKit's app APIs).
//  - PageWidgets: the WidgetKit extension. build.sh wraps its executable as
//    Page.app/Contents/PlugIns/PageWidgets.appex and signs it before the app.
//  - ClaudePowerMode: the app.
//
// The package stays on macOS 12 (the app's deployment target). The extension
// uses macOS 14 APIs (containerBackground) behind `#available`.
let appExtensionFlag: [SwiftSetting] = [.unsafeFlags(["-application-extension"])]

let package = Package(
    name: "ClaudePowerMode",
    platforms: [.macOS(.v12)],
    targets: [
        .target(
            name: "PageWidgetSupport",
            path: "Sources/PageWidgetSupport",
            swiftSettings: appExtensionFlag
        ),
        .executableTarget(
            name: "PageWidgets",
            dependencies: ["PageWidgetSupport"],
            path: "Sources/PageWidgets",
            swiftSettings: appExtensionFlag,
            // What Xcode passes for an app extension: the extension entry point
            // replaces main, and AppKit's app-only API is refused at link time.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-application_extension",
                                           "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
        .executableTarget(
            name: "ClaudePowerMode",
            dependencies: ["PageWidgetSupport"],
            path: "Sources/ClaudePowerMode"
        ),
        .testTarget(
            name: "ClaudePowerModeTests",
            dependencies: ["ClaudePowerMode", "PageWidgetSupport"],
            path: "Tests/ClaudePowerModeTests"
        )
    ]
)
