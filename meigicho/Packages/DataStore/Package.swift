// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DataStore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DataStore", targets: ["DataStore"]),
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../Domain"),
    ],
    targets: [
        .target(
            name: "DataStore",
            dependencies: ["Core", "Domain"]
        ),
        .testTarget(
            name: "DataStoreTests",
            dependencies: ["DataStore"]
        ),
    ]
)
