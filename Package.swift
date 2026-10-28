// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Moire",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Moire", targets: ["Moire"]),
        .library(name: "MoireKit", targets: ["MoireKit"]),
        .executable(name: "moire-bench", targets: ["MoireBench"]),
        // Shipped inside the app as Contents/Helpers/moire.
        .executable(name: "moire-cli", targets: ["MoireCLI"]),
    ],
    targets: [
        .target(name: "MoireKit"),
        .executableTarget(
            name: "Moire",
            dependencies: ["MoireKit"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .executableTarget(name: "MoireBench", dependencies: ["MoireKit"]),
        .executableTarget(name: "MoireCLI", dependencies: ["MoireKit"]),
        .testTarget(name: "MoireKitTests", dependencies: ["MoireKit"]),
        .testTarget(
            name: "MoireTests",
            dependencies: ["Moire", "MoireKit"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)
