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
            path: "slopWidgetExtension",
            linkerSettings: [
                // SwiftPM links the extension code as a static archive. Because
                // xtool sets the executable entry point to _NSExtensionMain, none
                // of the archive members are referenced and the whole widget ends
                // up dead-stripped (an empty binary with no __text section, which
                // also makes the code-signing step fail). Force every member in.
                .unsafeFlags(["-Xlinker", "-all_load"], .when(platforms: [.iOS]))
            ]
        ),
        .testTarget(
            name: "slopWidgetTests",
            dependencies: ["slopWidget"],
            path: "Tests/slopWidgetTests"
        ),
    ]
)
