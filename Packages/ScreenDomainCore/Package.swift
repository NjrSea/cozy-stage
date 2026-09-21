// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "screen-domain-core",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "ScreenDomainCore",
            targets: ["ScreenDomainCore"]
        )
    ],
    targets: [
        .target(name: "ScreenDomainCore"),
        .testTarget(
            name: "ScreenDomainCoreTests",
            dependencies: ["ScreenDomainCore"]
        )
    ]
)
