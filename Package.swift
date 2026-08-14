// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lever",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .watchOS(.v11),
        .tvOS(.v18),
        .visionOS(.v2),
    ],
    products: [
        .library(name: "Lever", targets: ["Lever"])
    ],
    targets: [
        .target(name: "Lever"),
        .testTarget(name: "LeverTests", dependencies: ["Lever"]),
    ],
    swiftLanguageModes: [.v6]
)
