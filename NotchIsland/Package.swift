// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "NotchIsland",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "NotchIsland", path: "Sources/NotchIsland")
    ],
    swiftLanguageModes: [.v5]
)
