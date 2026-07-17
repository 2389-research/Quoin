// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Quoin",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "QuoinCore", targets: ["QuoinCore"]),
        .library(name: "QuoinRender", targets: ["QuoinRender"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.8.0"),
        // The Mermaid engine is Quoin's own published package — consumed from
        // GitHub exactly like any other host app would (first-party, so exempt
        // from the one-third-party-dependency policy).
        .package(url: "https://github.com/2389-research/MermaidKit.git", from: "1.3.0"),
        // The math engine — Quoin's own published package, same policy.
        .package(url: "https://github.com/2389-research/Vinculum.git", from: "1.4.2"),
    ],
    targets: [
        .target(
            name: "QuoinCore",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "MermaidLayout", package: "MermaidKit"),
                .product(name: "VinculumLayout", package: "Vinculum"),
            ],
            path: "Sources/QuoinCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "QuoinRender",
            dependencies: [
                "QuoinCore",
                .product(name: "MermaidRender", package: "MermaidKit"),
                .product(name: "VinculumRender", package: "Vinculum"),
            ],
            path: "Sources/QuoinRender",
            // Still Swift 5 language mode: the remaining Swift-6 errors are
            // all `sending self` in the settle/pin DispatchQueue.main.async
            // closures — the caret/viewport machinery. That migration is
            // staged (road-to-1.0 Phase E2/E3) behind the ReaderModel
            // characterization tests, not rushed. Builds on the 6.0
            // toolchain today.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "QuoinCoreTests",
            dependencies: ["QuoinCore"],
            path: "Tests/QuoinCoreTests",
            // The conformance snapshot is read via #filePath, not the bundle.
            exclude: ["Snapshots/renderer-metrics.json"]
        ),
        // The render layer only compiles with AppKit/UIKit present, so this
        // target's sources are all guarded `#if canImport(AppKit) || UIKit`
        // and it runs on the macOS CI runner (empty elsewhere, e.g. Linux).
        .testTarget(
            name: "QuoinRenderTests",
            dependencies: ["QuoinRender", "QuoinCore"],
            path: "Tests/QuoinRenderTests",
            // The golden digest is read via #filePath, not the test bundle.
            exclude: ["Snapshots/render-digests.json"],
            // Matches QuoinRender's Swift 5 mode — it exercises the AppKit
            // render types whose Sendability the E2/E3 migration completes.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
