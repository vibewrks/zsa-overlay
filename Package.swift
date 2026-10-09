// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MoonlanderOverlay",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MoonlanderOverlay", targets: ["MoonlanderOverlay"]),
        .library(name: "MoonlanderOverlayKit", targets: ["MoonlanderOverlayKit"]),
    ],
    targets: [
        // Overlay model, rendering, window management, sidecar client.
        .target(
            name: "MoonlanderOverlayKit",
            resources: [.copy("Resources/keymap.json")],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        // Thin entry point; keeps `@main` out of the testable target.
        .executableTarget(
            name: "MoonlanderOverlay",
            dependencies: ["MoonlanderOverlayKit"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "MoonlanderOverlayTests",
            dependencies: ["MoonlanderOverlayKit"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)
