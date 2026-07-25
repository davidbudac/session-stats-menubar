// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SessionStatsBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SessionStatsBar",
            path: "Sources/SessionStatsBar",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
