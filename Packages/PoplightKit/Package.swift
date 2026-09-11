// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PoplightKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PoplightKit", targets: ["PoplightKit"]),
    ],
    targets: [
        .target(
            name: "PoplightKit",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
        .testTarget(
            name: "PoplightKitTests",
            dependencies: ["PoplightKit"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
    ]
)
