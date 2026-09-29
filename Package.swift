// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UsageRings",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "UsageRingsCore",
            path: "Sources/UsageRingsCore"
        ),
        .executableTarget(
            name: "UsageRings",
            dependencies: ["UsageRingsCore"],
            path: "Sources/UsageRings"
        ),
        .testTarget(
            name: "UsageRingsCoreTests",
            // `UsageRings` (the executable) is a test dep so
            // `MenuBarIconRenderTests` can call the real
            // `MenuBarIcon.makeImage` API and assert pixel-level
            // behaviour (mono ring adapts to `.dark` colour scheme) —
            // catching the fix-round-1 regression where the renderer
            // baked in the SwiftUI environment's default appearance.
            dependencies: ["UsageRingsCore", "UsageRings"],
            path: "Tests/UsageRingsCoreTests",
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
