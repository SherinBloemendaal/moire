// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Moire",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Moire", targets: ["Moire"]),
        .library(name: "MoireKit", targets: ["MoireKit"]),
        .executable(name: "moire-bench", targets: ["MoireBench"]),
    ],
    targets: [
        .target(name: "MoireKit"),
        .executableTarget(
            name: "Moire",
            dependencies: ["MoireKit"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .executableTarget(name: "MoireBench", dependencies: ["MoireKit"]),
        .testTarget(name: "MoireKitTests", dependencies: ["MoireKit"]),
    ]
)
