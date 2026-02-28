// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeScope",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "ClaudeScope",
            path: "Sources/ClaudeScope"
        )
    ]
)
