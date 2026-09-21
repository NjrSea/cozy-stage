// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ScreenSwitcherApp",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "ScreenSwitcherApp",
            targets: ["ScreenSwitcherApp"]
        )
    ],
    dependencies: [
        .package(path: "../Packages/PagedNavigationCore"),
        .package(path: "../Packages/KeyboardShortcuts"),
        .package(path: "../Packages/ScreenDomainCore"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", exact: "1.19.2")
    ],
    targets: [
        .executableTarget(
            name: "ScreenSwitcherApp",
            dependencies: [
                .product(name: "PagedNavigationCore", package: "PagedNavigationCore"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "ScreenDomainCore", package: "ScreenDomainCore")
            ]
        ),
        .testTarget(
            name: "ScreenSwitcherAppTests",
            dependencies: [
                "ScreenSwitcherApp",
                .product(name: "PagedNavigationCore", package: "PagedNavigationCore"),
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing")
            ],
            exclude: ["__Snapshots__"]
        )
    ]
)
