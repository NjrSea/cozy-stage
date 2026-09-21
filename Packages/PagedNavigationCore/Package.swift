// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "PagedNavigationCore",
    products: [
        .library(
            name: "PagedNavigationCore",
            targets: ["PagedNavigationCore"]
        )
    ],
    targets: [
        .target(name: "PagedNavigationCore"),
        .testTarget(
            name: "PagedNavigationCoreTests",
            dependencies: ["PagedNavigationCore"]
        )
    ]
)
