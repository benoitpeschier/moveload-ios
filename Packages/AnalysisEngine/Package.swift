// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AnalysisEngine",
    defaultLocalization: "fr",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AnalysisEngine", targets: ["AnalysisEngine"])
    ],
    dependencies: [
        .package(path: "../MoveLoadCore")
    ],
    targets: [
        .target(name: "AnalysisEngine", dependencies: ["MoveLoadCore"],
                resources: [.process("Localizable.xcstrings")]),
        .testTarget(name: "AnalysisEngineTests", dependencies: ["AnalysisEngine"])
    ]
)
