// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Launchpad",
    platforms: [.macOS("26.0")],
    targets: [
        .target(
            name: "LaunchpadCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Launchpad",
            dependencies: ["LaunchpadCore"],
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        .testTarget(
            name: "LaunchpadCoreTests",
            dependencies: ["LaunchpadCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
