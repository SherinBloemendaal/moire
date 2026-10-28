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
    dependencies: [
        // Checks for, downloads and installs new versions of the app.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        .target(name: "MoireKit"),
        .executableTarget(
            name: "Moire",
            dependencies: ["MoireKit", .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .executableTarget(name: "MoireBench", dependencies: ["MoireKit"]),
        .executableTarget(name: "MoireCLI", dependencies: ["MoireKit"]),
        .testTarget(name: "MoireKitTests", dependencies: ["MoireKit"], exclude: ["Fixtures"]),
        // Runs the built moire-cli; the dependency makes sure it is built before the tests.
        .testTarget(name: "MoireCLITests", dependencies: ["MoireCLI"]),
        .testTarget(
            name: "MoireTests",
            dependencies: ["Moire", "MoireKit"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)
