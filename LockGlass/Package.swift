// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "LockGlass",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "LockGlass", path: "Sources/LockGlass")
    ],
    swiftLanguageModes: [.v5]
)
