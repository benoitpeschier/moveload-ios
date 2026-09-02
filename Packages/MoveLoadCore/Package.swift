// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MoveLoadCore",
    defaultLocalization: "fr",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MoveLoadCore", targets: ["MoveLoadCore"])
    ],
    targets: [
        .target(name: "MoveLoadCore", resources: [.process("Localizable.xcstrings")]),
        .testTarget(name: "MoveLoadCoreTests", dependencies: ["MoveLoadCore"])
    ]
)
