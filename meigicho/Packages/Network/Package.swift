// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Network",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "Network", targets: ["Network"]),
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../Domain"),
    ],
    targets: [
        .target(
            name: "Network",
            dependencies: ["Core", "Domain"]
        ),
        .testTarget(
            name: "NetworkTests",
            dependencies: ["Network"]
        ),
    ]
)
