// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AnalysisEngine",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AnalysisEngine", targets: ["AnalysisEngine"])
    ],
    dependencies: [
        .package(path: "../MoveLoadCore")
    ],
    targets: [
        .target(name: "AnalysisEngine", dependencies: ["MoveLoadCore"]),
        .testTarget(name: "AnalysisEngineTests", dependencies: ["AnalysisEngine"])
    ]
)
