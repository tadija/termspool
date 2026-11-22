// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TermSpool",
    platforms: [.macOS(.v14)],
    products: [.library(name: "TermSpool", targets: ["TermSpool"])],
    targets: [
        .target(name: "CTermSpool", linkerSettings: [.linkedLibrary("util", .when(platforms: [.linux]))]),
        .target(name: "TermSpool", dependencies: ["CTermSpool"]),
        .testTarget(name: "TermSpoolTests", dependencies: ["TermSpool", "CTermSpool"])
    ]
)
