// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hypernote2",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything except the SwiftUI/WebKit shell: models, storage, API clients, recorder.
        .target(
            name: "HypernoteCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Menu bar app + WKWebView host.
        .executableTarget(
            name: "Hypernote2",
            dependencies: ["HypernoteCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "HypernoteCoreTests",
            dependencies: ["HypernoteCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
