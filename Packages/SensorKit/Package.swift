// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SensorKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SensorKit", targets: ["SensorKit"])
    ],
    dependencies: [
        .package(path: "../MoveLoadCore")
    ],
    targets: [
        .target(name: "SensorKit", dependencies: ["MoveLoadCore"]),
        .testTarget(name: "SensorKitTests", dependencies: ["SensorKit"])
    ]
)
