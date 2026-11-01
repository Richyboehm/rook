// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "RBTools",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "RBTools", path: "Sources/RBTools")
    ],
    swiftLanguageModes: [.v5]
)
