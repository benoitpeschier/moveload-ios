// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MovesenseVendor",
    defaultLocalization: "fr",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "MovesenseVendor", targets: ["MovesenseVendor"])
    ],
    dependencies: [
        .package(path: "../MoveLoadCore"),
        .package(path: "../SensorKit")
    ],
    targets: [
        .target(
            name: "MovesenseVendor",
            dependencies: ["MoveLoadCore", "SensorKit"],
            resources: [.process("Localizable.xcstrings")]
        )
    ]
)
