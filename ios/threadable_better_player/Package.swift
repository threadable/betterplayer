// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "threadable_better_player",
    platforms: [
        .iOS("14.0")
    ],
    products: [
        .library(
            name: "threadable-better-player",
            type: .static,
            targets: ["threadable_better_player"]
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
            name: "threadable_better_player_swift",
            dependencies: [
                "Cache",
                "GCDWebServer",
                "PINCache",
                "HLSCachingReverseProxyServer"
            ],
            path: "Sources/threadable_better_player_swift"
        ),
        .target(
            name: "threadable_better_player",
            dependencies: [
                "FlutterFramework",
                "threadable_better_player_swift"
            ],
            path: "Sources/threadable_better_player",
            publicHeadersPath: "include"
        )
    ]
)
