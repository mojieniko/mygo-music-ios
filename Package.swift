// swift-tools-version: 5.10
// MyGo Music iOS 版 Swift Package 配置

import PackageDescription

let package = Package(
    name: "MyGoMusic",
    defaultLocalization: "zh-Hans",
    platforms: [
        .iOS(.v16),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "MyGoMusicCore",
            targets: ["MyGoMusicCore"]
        ),
        .library(
            name: "MyGoMusicUI",
            targets: ["MyGoMusicUI"]
        )
    ],
    targets: [
        .target(name: "MyGoMusicCore"),
        .target(
            name: "MyGoMusicUI",
            dependencies: ["MyGoMusicCore"]
        ),
        .executableTarget(
            name: "MyGoMusicVerifier",
            dependencies: ["MyGoMusicCore", "MyGoMusicUI"]
        ),
        .testTarget(
            name: "MyGoMusicTests",
            dependencies: ["MyGoMusicCore", "MyGoMusicUI"]
        )
    ]
)
