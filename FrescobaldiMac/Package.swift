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
// The app and the MCP server need AppKit, CoreGraphics and Darwin sockets,
// so they only exist on macOS. Elsewhere the core library and its tests
// still build (`swift test` on Linux).
targets += [
    .executableTarget(
        name: "Frescobaldi",
        dependencies: ["FrescobaldiCore", "FrescobaldiMCP"],
        path: "Sources/Frescobaldi"
    ),
    // MCP server for Claude and other AI clients: file tools, plus a bridge
    // (Unix socket) to the running app. Bundled as Contents/Helpers/frescobaldi-mcp.
    .target(
        name: "FrescobaldiMCP",
        dependencies: ["FrescobaldiCore"],
        path: "Sources/FrescobaldiMCP"
    ),
    .executableTarget(
        name: "frescobaldi-mcp",
        dependencies: ["FrescobaldiMCP"],
        path: "Sources/frescobaldi-mcp"
    ),
    .testTarget(
        name: "FrescobaldiMCPTests",
        dependencies: ["FrescobaldiMCP"],
        path: "Tests/FrescobaldiMCPTests"
    ),
]
products += [
    .executable(name: "Frescobaldi", targets: ["Frescobaldi"]),
    .executable(name: "frescobaldi-mcp", targets: ["frescobaldi-mcp"]),
]
#endif

let package = Package(
    name: "FrescobaldiMac",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets,
    swiftLanguageModes: [.v5]
)
