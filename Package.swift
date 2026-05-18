// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudePowerMode",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "ClaudePowerMode",
            path: "Sources/ClaudePowerMode"
        )
    ]
)
