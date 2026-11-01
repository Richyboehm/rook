// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Aufraeumer",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "Aufraeumer", path: "Sources/Aufraeumer")
    ],
    swiftLanguageModes: [.v5]
)
