// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "KShowSub",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.0.0"),
        .package(url: "https://github.com/dioKaratzas/swift-subtitle-kit.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "KShowSubCore",
            dependencies: [
                .product(name: "SubtitleKit", package: "swift-subtitle-kit"),
            ],
            path: "Sources/KShowSubCore"
        ),
        .executableTarget(
            name: "KShowSub",
            dependencies: [
                "KShowSubCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SubtitleKit", package: "swift-subtitle-kit"),
            ],
            path: "Sources/KShowSub",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "SupportingFiles/Info.plist"
                ])
            ]
        ),
        .executableTarget(
            name: "KShowSubCoreTestRunner",
            dependencies: [
                "KShowSubCore",
                .product(name: "SubtitleKit", package: "swift-subtitle-kit"),
            ],
            path: "Tests/KShowSubCoreTestRunner"
        ),
    ]
)
