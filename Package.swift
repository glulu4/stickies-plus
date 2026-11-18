// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "StickiesPlus",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "StickiesPlus",
            path: "Sources/StickiesPlus",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ],
    swiftLanguageVersions: [.v5]
)
