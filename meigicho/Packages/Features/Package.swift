// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Features",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "Features", targets: ["Features"]),
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../DesignSystem"),
        .package(path: "../Domain"),
    ],
    targets: [
        .target(
            name: "Features",
            dependencies: ["Core", "DesignSystem", "Domain"]
        ),
    ]
)
