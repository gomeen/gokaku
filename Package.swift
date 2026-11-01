// swift-tools-version: 6.0
import PackageDescription
import Foundation
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let nativeFlags: [LinkerSetting] = [
    .unsafeFlags(["-L", root + "/.build/native", "-L", root + "/.build/core", "-Xlinker", "-rpath", "-Xlinker", root + "/.build/native", "-Xlinker", "-rpath", "-Xlinker", root + "/.build/core"]),
]
let package = Package(
    name: "Gogaku", platforms: [.macOS("26.0")],
    products: [.executable(name: "GogakuInput", targets: ["GogakuInput"]), .executable(name: "GogakuSettings", targets: ["GogakuSettings"]), .executable(name: "GogakuTranslator", targets: ["GogakuTranslator"])],
    targets: [
        .systemLibrary(name: "CGogakuEngine"), .systemLibrary(name: "CGogakuCore"), .systemLibrary(name: "CSQLite"),
        .target(name: "GogakuHost", linkerSettings: [.linkedFramework("InputMethodKit")]),
        .target(name: "GogakuCore", dependencies: ["CGogakuEngine", "CGogakuCore", "CSQLite"], linkerSettings: nativeFlags),
        .executableTarget(name: "GogakuInput", dependencies: ["GogakuCore", "GogakuHost"], linkerSettings: nativeFlags + [.linkedFramework("InputMethodKit"), .linkedFramework("Carbon")]),
        .executableTarget(name: "GogakuSettings", dependencies: ["GogakuCore"], linkerSettings: nativeFlags),
        .executableTarget(name: "GogakuTranslator", dependencies: ["GogakuCore"], linkerSettings: nativeFlags),
        .testTarget(name: "GogakuCoreTests", dependencies: ["GogakuCore", "GogakuHost"], linkerSettings: nativeFlags)
    ], swiftLanguageModes: [.v5])
