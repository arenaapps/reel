// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Reel",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Reel",
            path: "Sources/Reel",
            swiftSettings: [.unsafeFlags(["-Onone"], .when(configuration: .debug))]
        ),
        .testTarget(name: "ReelTests", dependencies: ["Reel"], path: "Tests/ReelTests")
    ]
)
