// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Fensterholer",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "Fensterholer", path: "Sources/Fensterholer")
    ],
    swiftLanguageModes: [.v5]
)
