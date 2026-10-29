// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "slopWidget",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "slopWidget",
            targets: ["slopWidget"]
        ),
        .library(
            name: "slopWidgetExtension",
            targets: ["slopWidgetExtension"]
        ),
    ],
    targets: [
        .target(
            name: "slopWidget",
            path: "slopWidget",
            exclude: [
                "Assets.xcassets",
                "Preview Content",
            ]
        ),
        .target(
            name: "slopWidgetExtension",
            path: "slopWidgetExtension"
        ),
    ]
)
