// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SyncKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SyncKit", targets: ["SyncKit"])
    ],
    targets: [
        .target(name: "SyncKit"),
        .testTarget(name: "SyncKitTests", dependencies: ["SyncKit"])
    ]
)
