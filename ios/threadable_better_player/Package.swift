// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "betterplayer",
    platforms: [
        .iOS("14.0")
    ],
    products: [
        .library(
            name: "threadable-better-player",
            type: .static,
            targets: ["threadable_better_player_objc"]
        )
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "Cache",
            path: "Sources/Cache"
        ),
        .target(
            name: "GCDWebServer",
            path: "Sources/GCDWebServer",
            publicHeadersPath: "GCDWebServer",
            cSettings: [
                .headerSearchPath("GCDWebServer/Core"),
                .headerSearchPath("GCDWebServer/Requests"),
                .headerSearchPath("GCDWebServer/Responses")
            ]
        ),
        .target(
            name: "PINOperation",
            path: "Sources/PINOperation",
            publicHeadersPath: "Source"
        ),
        .target(
            name: "PINCache",
            dependencies: [
                "PINOperation"
            ],
            path: "Sources/PINCache",
            publicHeadersPath: "Source"
        ),
        .target(
            name: "HLSCachingReverseProxyServer",
            dependencies: [
                "GCDWebServer",
                "PINCache"
            ],
            path: "Sources/HLSCachingReverseProxyServer"
        ),
        .target(
            name: "threadable_better_player",
            dependencies: [
                "Cache",
                "GCDWebServer",
                "PINCache",
                "HLSCachingReverseProxyServer",
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            path: "Sources/threadable_better_player"
        ),
        .target(
            name: "threadable_better_player_objc",
            dependencies: [
                "threadable_better_player",
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            path: "Sources/threadable_better_player_objc",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include")
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("UIKit"),
                .linkedFramework("Foundation")
            ]
        )
    ]
)
