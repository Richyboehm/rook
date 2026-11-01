// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Richy",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "Richy", path: "Sources/Richy")
    ],
    swiftLanguageModes: [.v5]
)
