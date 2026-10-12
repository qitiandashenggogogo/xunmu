// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacEverything",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MacEverything", targets: ["MacEverything"]), .executable(name: "SearchBench", targets: ["SearchBench"])],
    // Sparkle 2 (official distribution).
    // Pinned exactly to the newest stable 2.x tag verified on 2026-10-10:
    //   git ls-remote --tags --refs https://github.com/sparkle-project/Sparkle
    //   -> 2.10.0 = eef1a539a373c1f1a320624b1130fc5de7b2e100 (newest stable; the
    //   only newer-looking tag, 2.10.0-beta.1, is a prerelease)
    // The pin alone is not validation. Local builds and signed-bundle checks
    // have passed; a real two-version network update is still untested.
    // See docs/UPDATES.md.
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "SearchCore"),
        .target(name: "SearchIndex", dependencies: ["SearchCore", "CSQLite"]),
        .target(name: "DarwinScanner", publicHeadersPath: "include"),
        .target(name: "SearchScanner", dependencies: ["SearchCore", "DarwinScanner"]),
        .target(name: "SearchUI", dependencies: ["SearchCore", "SearchDiagnostics", .product(name: "Sparkle", package: "Sparkle")]),
        // Local-only diagnostics. Zero dependencies, no network, no crash upload.
        .target(name: "SearchDiagnostics"),
        .executableTarget(name: "MacEverything", dependencies: ["SearchCore", "SearchIndex", "SearchScanner", "SearchUI", "SearchDiagnostics"]),
        .executableTarget(name: "SearchBench", dependencies: ["SearchCore", "SearchIndex", "SearchScanner"]),
        .testTarget(name: "AcceptanceTests", dependencies: ["SearchCore", "SearchIndex", "SearchScanner", "SearchUI", "SearchBench"]),
        .testTarget(name: "SearchIndexTests", dependencies: ["SearchCore", "SearchIndex"]),
        .testTarget(name: "SearchScannerTests", dependencies: ["SearchCore", "SearchScanner"]),
        .testTarget(name: "SearchUITests", dependencies: ["SearchCore", "SearchUI"]),
        .testTarget(name: "SearchDiagnosticsTests", dependencies: ["SearchDiagnostics"])
    ],
    swiftLanguageModes: [.v6]
)
