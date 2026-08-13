// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MovesenseVendor",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "MovesenseVendor", targets: ["MovesenseVendor"])
    ],
    dependencies: [
        .package(path: "../MoveLoadCore"),
        .package(path: "../SensorKit")
    ],
    targets: [
        .binaryTarget(name: "MDSBinary", path: "Vendor/MDS.xcframework"),
        .target(
            name: "CMDS",
            dependencies: ["MDSBinary"],
            path: "Sources/CMDS",
            publicHeadersPath: "include"
        ),
        .target(
            name: "MovesenseVendor",
            dependencies: ["MoveLoadCore", "SensorKit", "CMDS"],
            linkerSettings: [
                .linkedLibrary("stdc++"),
                .linkedLibrary("z")
            ]
        )
    ]
)
