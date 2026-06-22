// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PillCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "PillCore", targets: ["PillCore"])
    ],
    targets: [
        .target(name: "PillCore"),
        .testTarget(name: "PillCoreTests", dependencies: ["PillCore"])
    ]
)
