// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "threadable_better_player",
    platforms: [
        .iOS("12.0")
    ],
    products: [
        .library(
            name: "threadable-better-player",
            targets: ["threadable_better_player"]
        )
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "threadable_better_player",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            path: "Sources/ThreadableBetterPlayer",
            resources: [
                .process("PrivacyInfo.xcprivacy")
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("UIKit"),
                .linkedFramework("Foundation"),
                .linkedFramework("MediaPlayer"),
                .linkedFramework("Network")
            ]
        )
    ]
)
