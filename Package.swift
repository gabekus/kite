// swift-tools-version: 6.0
import Foundation
import PackageDescription

// KiteCore is plain Foundation so it builds on macOS and Windows alike.
// Platform shells (KiteMac today, KiteWindows later) sit on top of it.
var targets: [Target] = [
    .target(name: "KiteCore"),
    .testTarget(name: "KiteCoreTests", dependencies: ["KiteCore"]),
]
var products: [Product] = [
    .library(name: "KiteCore", targets: ["KiteCore"]),
]

#if os(macOS)
// The Chromium engine is built only after scripts/fetch-cef.sh has run.
// Without it Kite still builds and runs on WebKit.
let cefDirectory = Context.packageDirectory + "/ThirdParty/cef"
let hasCEF = FileManager.default.fileExists(atPath: cefDirectory + "/build/libcef_dll_wrapper/libcef_dll_wrapper.a")

var macDependencies: [Target.Dependency] = ["KiteCore"]

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

targets.append(
    .executableTarget(
        name: "KiteMac",
        dependencies: macDependencies,
        resources: [.copy("Shaders")],
        swiftSettings: [.swiftLanguageMode(.v5)]
    )
)
products.append(.executable(name: "Kite", targets: ["KiteMac"]))
#endif

let package = Package(
    name: "Kite",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
