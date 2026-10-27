// swift-tools-version:5.9
import PackageDescription
import Foundation

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

// The extension must record the SDK it is built with (LC_BUILD_VERSION `sdk`).
// SwiftPM's build links with `-target arm64-apple-macos12.0` and leaves the sdk
// at 12.0, and WidgetKit then treats the widget as built for macOS 12: no system
// content margins and no containerBackground semantics, so faces draw edge to
// edge and are clipped by the widget's rounded corners. The app is left alone
// (an older linked-on SDK keeps AppKit's behaviours as they are today).
//
// minos stays 12.0 here (the Info.plist's LSMinimumSystemVersion is what the
// system reads for an extension; the faces gate macOS 14 APIs themselves).
// The SDK version comes from the toolchain: `xcrun --show-sdk-version`.
func installedSDKVersion() -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["--sdk", "macosx", "--show-sdk-version"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return "14.0" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    // "27.0", or "15" on an SDK that omits the minor: ld wants major.minor.
    let ok = text.range(of: #"^[0-9]+(\.[0-9]+){0,2}$"#, options: .regularExpression) != nil
    guard ok else { return "14.0" }
    return text.contains(".") ? text : text + ".0"
}

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
                                           "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain",
                                           "-Xlinker", "-platform_version", "-Xlinker", "macos",
                                           "-Xlinker", "12.0", "-Xlinker", installedSDKVersion()])]
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
