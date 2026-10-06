// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SilentSpy",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .executableTarget(
            name: "SilentSpy"
        )
    ]
)
