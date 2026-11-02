// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Rook",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "Rook", path: "Sources/Rook")
    ],
    swiftLanguageModes: [.v5]
)
