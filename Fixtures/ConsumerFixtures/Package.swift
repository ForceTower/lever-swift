// swift-tools-version: 6.2
import PackageDescription

/// Building `Lever` proves nothing about the consumption promise (spec §1), so
/// these two targets compile the same code against it under both default
/// isolation settings an app can pick. They exist only to be built by CI.
///
/// This package is deliberately separate: `default isolation` needs
/// tools-version 6.2, while the shipped package stays at 6.0 with no unsafe
/// flags, so it still resolves as a dependency by URL.
let package = Package(
    name: "ConsumerFixtures",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .watchOS(.v11),
        .tvOS(.v18),
        .visionOS(.v2),
    ],
    dependencies: [.package(path: "../..")],
    targets: [
        .target(
            name: "MainActorConsumer",
            dependencies: [.product(name: "Lever", package: "lever-swift")],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .target(
            name: "NonisolatedConsumer",
            dependencies: [.product(name: "Lever", package: "lever-swift")],
            swiftSettings: [.defaultIsolation(nil)]
        ),
    ],
    swiftLanguageModes: [.v6]
)
