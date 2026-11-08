// swift-tools-version: 6.0
import PackageDescription
import Foundation
// 包根在 macos/；相对构建根始终相对仓库根，而不是 SwiftPM 的工作目录。
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let configuredBuildRoot = ProcessInfo.processInfo.environment["GOGAKU_BUILD_ROOT"] ?? ""
let buildRoot = URL(fileURLWithPath: configuredBuildRoot.isEmpty ? ".build" : configuredBuildRoot,
                    relativeTo: root).standardizedFileURL.resolvingSymlinksInPath().path
let nativeFlags: [LinkerSetting] = [
    .unsafeFlags(["-L", buildRoot + "/native", "-L", buildRoot + "/core", "-Xlinker", "-rpath", "-Xlinker", buildRoot + "/native", "-Xlinker", "-rpath", "-Xlinker", buildRoot + "/core"]),
]
let package = Package(
    name: "Gogaku", platforms: [.macOS("26.0")],
    products: [.executable(name: "GogakuInput", targets: ["GogakuInput"]), .executable(name: "GogakuSettings", targets: ["GogakuSettings"]), .executable(name: "GogakuTranslator", targets: ["GogakuTranslator"])],
    targets: [
        .systemLibrary(name: "CGogakuEngine"), .systemLibrary(name: "CGogakuCore"), .systemLibrary(name: "CSQLite"),
        .target(name: "GogakuHost", linkerSettings: [.linkedFramework("InputMethodKit")]),
        .target(name: "GogakuKit", dependencies: ["CGogakuEngine", "CGogakuCore", "CSQLite"], linkerSettings: nativeFlags),
        .executableTarget(name: "GogakuInput", dependencies: ["GogakuKit", "GogakuHost"], linkerSettings: nativeFlags + [.linkedFramework("InputMethodKit"), .linkedFramework("Carbon")]),
        .executableTarget(name: "GogakuSettings", dependencies: ["GogakuKit"], linkerSettings: nativeFlags),
        .executableTarget(name: "GogakuTranslator", dependencies: ["GogakuKit"], linkerSettings: nativeFlags),
        .testTarget(name: "GogakuKitTests", dependencies: ["GogakuKit", "GogakuHost", "GogakuInput", "GogakuSettings"], linkerSettings: nativeFlags)
    ], swiftLanguageModes: [.v5])
