// swift-tools-version: 6.0
import Foundation
import PackageDescription

// KiteCore is plain Foundation so it builds on macOS and Windows alike.
// Platform shells (KiteMac, KiteWindows) sit on top of it.
var targets: [Target] = [
    .target(name: "KiteCore"),
    .testTarget(name: "KiteCoreTests", dependencies: ["KiteCore"]),
]
var products: [Product] = [
    .library(name: "KiteCore", targets: ["KiteCore"]),
]
var packageDependencies: [Package.Dependency] = []

#if os(macOS)
// The Chromium engine is built only after scripts/fetch-cef.sh has run.
// Without it Kite still builds and runs on WebKit.
let cefDirectory = Context.packageDirectory + "/ThirdParty/cef"
let hasCEF = FileManager.default.fileExists(atPath: cefDirectory + "/build/libcef_dll_wrapper/libcef_dll_wrapper.a")

var macDependencies: [Target.Dependency] = ["KiteCore", .product(name: "Sparkle", package: "Sparkle")]

// Sparkle: over-the-air updates for release builds (scripts/release.sh). A build only checks for
// updates when bundle-app.sh gave it a feed (KITE_UPDATE_FEED); see docs/updates.md.
packageDependencies.append(.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"))

// The ad blocker (Brave's adblock-rust) is built only after scripts/build-adblock.sh
// has run. Without it Kite builds and runs with no ad blocking.
let adblockLibrary = Context.packageDirectory + "/Sources/KiteAdblock/rust/target/lib"
let hasAdblock = FileManager.default.fileExists(atPath: adblockLibrary + "/libkite_adblock.a")
if hasAdblock {
    targets.append(
        .target(
            name: "KiteAdblock",
            exclude: ["rust"],
            linkerSettings: [.unsafeFlags(["-L", adblockLibrary, "-lkite_adblock"])]
        )
    )
    macDependencies.append("KiteAdblock")
}

if hasCEF {
    let cefFlags = ["-I", cefDirectory, "-std=c++20", "-fno-rtti", "-fno-exceptions", "-fno-threadsafe-statics", "-fno-strict-aliasing"]
    let cefLink: [LinkerSetting] = [
        .unsafeFlags(["-L", cefDirectory + "/build/libcef_dll_wrapper", "-lcef_dll_wrapper"]),
        .linkedFramework("AppKit"),
        .linkedFramework("IOSurface"),
    ]
    targets += [
        .target(
            name: "CEFBridge",
            dependencies: hasAdblock ? ["KiteAdblock"] : [],
            cxxSettings: [.unsafeFlags(cefFlags)],
            linkerSettings: cefLink
        ),
        .executableTarget(
            name: "KiteHelper",
            cxxSettings: [.unsafeFlags(cefFlags)],
            linkerSettings: cefLink
        ),
    ]
    products.append(.executable(name: "KiteHelper", targets: ["KiteHelper"]))
    macDependencies.append("CEFBridge")
}

// The `kite` CLI and MCP server. Built as kite-cli: a "kite" binary would collide
// with "Kite" on a case-insensitive disk. bundle-app.sh installs it as Contents/Helpers/kite.
targets.append(.executableTarget(name: "KiteCLI", dependencies: ["KiteCore"]))
products.append(.executable(name: "kite-cli", targets: ["KiteCLI"]))

targets.append(
    .executableTarget(
        name: "KiteMac",
        dependencies: macDependencies,
        resources: [.copy("Shaders")],
        swiftSettings: [.swiftLanguageMode(.v5)],
        // Kite.app keeps Sparkle.framework in Contents/Frameworks (bundle-app.sh); a bare
        // `swift build` binary finds it next to itself through SwiftPM's @loader_path.
        linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
    )
)
products.append(.executable(name: "Kite", targets: ["KiteMac"]))
#endif

#if os(Windows)
// The Windows shell (docs/windows.md). Win32 for now; Chromium (CEF) joins it once
// scripts/fetch-cef.ps1 has run, the same way CEFBridge does on macOS.
targets.append(
    .executableTarget(
        name: "KiteWindows",
        dependencies: ["KiteCore"],
        swiftSettings: [.swiftLanguageMode(.v5)],
        linkerSettings: [
            .linkedLibrary("user32"),
            .linkedLibrary("dwmapi"),
            .linkedLibrary("advapi32"),
        ]
    )
)
products.append(.executable(name: "Kite", targets: ["KiteWindows"]))
#endif

let package = Package(
    name: "Kite",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: packageDependencies,
    targets: targets
)
