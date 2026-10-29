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
            ],
            linkerSettings: [
                // Force the widget's AppIntent type metadata to stay in the
                // binary; nothing in the app references it, so dead_strip
                // would otherwise remove it and the runtime could not resolve
                // the widget tap by type name.
                .unsafeFlags([
                    "-Xlinker", "-u",
                    "-Xlinker", "_$s10slopWidget24CycleOpenCodeMeterIntentVMn",
                ], .when(platforms: [.iOS]))
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
