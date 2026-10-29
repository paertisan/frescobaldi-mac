// swift-tools-version: 6.0
//
// Frescobaldi for macOS: a native Swift/AppKit front end for LilyPond,
// forked from Frescobaldi 4.0.7 (https://frescobaldi.org).
//
// Build the app bundle with `scripts/build-app.sh`; `swift build` alone
// produces the bare executable.

import PackageDescription

let package = Package(
    name: "FrescobaldiMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Frescobaldi", targets: ["Frescobaldi"]),
    ],
    targets: [
        // UI-free logic (lexer, log parsing, point-and-click links, LilyPond
        // discovery). Kept separate so it can be unit tested without AppKit.
        .target(
            name: "FrescobaldiCore",
            path: "Sources/FrescobaldiCore"
        ),
        .executableTarget(
            name: "Frescobaldi",
            dependencies: ["FrescobaldiCore"],
            path: "Sources/Frescobaldi"
        ),
        .testTarget(
            name: "FrescobaldiCoreTests",
            dependencies: ["FrescobaldiCore"],
            path: "Tests/FrescobaldiCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
