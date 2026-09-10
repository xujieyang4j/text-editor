// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "LumenEditorNative",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "LumenEditorCore", targets: ["LumenEditorCore"]),
        .executable(name: "LumenEditor", targets: ["LumenEditorApp"]),
        .executable(name: "LumenPluginWorker", targets: ["LumenPluginWorker"]),
        .executable(name: "LumenParserWorker", targets: ["LumenParserWorker"])
    ],
    targets: [
        .target(
            name: "LumenPTYSupport",
            path: "Sources/LumenPTYSupport",
            publicHeadersPath: "include"
        ),
        .target(
            name: "LumenEditorCore",
            dependencies: ["LumenPTYSupport"],
            path: "Sources/LumenEditorCore",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "LumenEditorApp",
            dependencies: ["LumenEditorCore"],
            path: "Sources/LumenEditorApp",
            resources: [
                .copy("Resources/CodeMirrorParserBundle.js")
            ],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("StrictConcurrency")
            ],
            linkerSettings: [.linkedFramework("JavaScriptCore")]
        ),
        .executableTarget(
            name: "LumenPluginWorker",
            dependencies: ["LumenEditorCore"],
            path: "Sources/LumenPluginWorker",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ],
            linkerSettings: [.linkedFramework("JavaScriptCore")]
        ),
        .executableTarget(
            name: "LumenParserWorker",
            path: "Sources/LumenParserWorker",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ],
            linkerSettings: [.linkedFramework("JavaScriptCore")]
        ),
        .testTarget(
            name: "LumenEditorCoreTests",
            dependencies: ["LumenEditorCore"],
            path: "Tests/LumenEditorCoreTests",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "LumenEditorAppTests",
            dependencies: ["LumenEditorApp", "LumenEditorCore"],
            path: "Tests/LumenEditorAppTests",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        )
    ]
)
