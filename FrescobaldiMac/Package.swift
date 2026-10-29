// swift-tools-version: 6.0
//
// Frescobaldi for macOS: a native Swift/AppKit front end for LilyPond,
// forked from Frescobaldi 4.0.7 (https://frescobaldi.org).
//
// Build the app bundle with `scripts/build-app.sh`; `swift build` alone
// produces the bare executable.

import PackageDescription

var targets: [Target] = [
    // UI-free logic (lexer, log parsing, point-and-click links, LilyPond
    // discovery). Kept separate so it can be unit tested without AppKit.
    .target(
        name: "FrescobaldiCore",
        path: "Sources/FrescobaldiCore"
    ),
    .testTarget(
        name: "FrescobaldiCoreTests",
        dependencies: ["FrescobaldiCore"],
        path: "Tests/FrescobaldiCoreTests"
    ),
]
var products: [Product] = [
    .library(name: "FrescobaldiCore", targets: ["FrescobaldiCore"]),
]

#if os(macOS)
// The app needs AppKit, so it only exists on macOS. Elsewhere the core
// library and its tests still build (`swift test` on Linux).
targets.append(
    .executableTarget(
        name: "Frescobaldi",
        dependencies: ["FrescobaldiCore"],
        path: "Sources/Frescobaldi"
    )
)
products.append(.executable(name: "Frescobaldi", targets: ["Frescobaldi"]))
#endif

let package = Package(
    name: "FrescobaldiMac",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets,
    swiftLanguageModes: [.v5]
)
