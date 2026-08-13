// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PersistenceKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PersistenceKit", targets: ["PersistenceKit"])
    ],
    dependencies: [
        .package(path: "../MoveLoadCore")
    ],
    targets: [
        .target(name: "PersistenceKit", dependencies: ["MoveLoadCore"]),
        .testTarget(name: "PersistenceKitTests", dependencies: ["PersistenceKit"])
    ]
)
