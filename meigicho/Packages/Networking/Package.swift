// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Networking",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "Networking", targets: ["Networking"]),
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../Domain"),
    ],
    targets: [
        .target(
            name: "Networking",
            dependencies: ["Core", "Domain"]
        ),
        .testTarget(
            name: "NetworkingTests",
            dependencies: ["Networking"]
        ),
    ]
)
