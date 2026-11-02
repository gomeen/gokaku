// 只读探针：枚举 TIS 输入源，dump 图标相关属性，证实输入源切换 HUD 的取图来源。
// 不注册、不启用、不切换输入源；仅调用 TISCreateInputSourceList / TISGetInputSourceProperty。
// 用法：swift probes/tis-icon-probe.swift [bundleID]
import AppKit
import Carbon
import CoreGraphics
import Foundation

// 单文件脚本没有 CryptoKit 的 Insecure.SHA256，用 FNV 前缀指纹区分文件版本；
// 精确 hash 由命令行 shasum 对照。
func fingerprint(_ data: Data) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in data.prefix(8192) {
        hash ^= UInt64(byte)
        hash = hash &* 0x100000001b3
    }
    return String(format: "fnv=%016x", hash) + ".len=\(data.count)"
}

let targetBundleID = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "org.gogaku.inputmethod"

func property(_ source: TISInputSource, _ key: CFString) -> CFTypeRef? {
    guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
}

func stringProp(_ source: TISInputSource, _ key: CFString) -> String? {
    property(source, key) as? String
}



func describeURLProp(_ source: TISInputSource, _ key: CFString) -> [String: Any]? {
    guard let url = property(source, key) as? URL else { return nil }
    let path = url.path
    let exists = FileManager.default.fileExists(atPath: path)
    var size: Int64 = -1
    var sha = ""
    if exists, let data = try? Data(contentsOf: url) {
        size = Int64(data.count)
        sha = fingerprint(data)
    }
    var error: Unmanaged<CFError>?
    let reachable = CFURLResourceIsReachable(url as CFURL, &error)
    return ["path": path, "exists": exists, "reachable": reachable, "bytes": size, "sha256_head": sha]
}

func iconRefNote(_ source: TISInputSource) -> [String: Any]? {
    guard let value = property(source, kTISPropertyIconRef) else { return nil }
    let pointer = Unmanaged.passUnretained(value).toOpaque()
    return ["pointer": "\(pointer)"]
}

func isReachableText(_ row: [String: Any]) -> String {
    guard let info = row["iconImageURL"] as? [String: Any] else { return "NULL" }
    return "\(info["path"] ?? "") exists=\(info["exists"] ?? false) reachable=\(info["reachable"] ?? false) bytes=\(info["bytes"] ?? -1) sha256_head=\(info["sha256_head"] ?? "")"
}

guard let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else {
    print(#"{"error":"TISCreateInputSourceList returned nil"}"#); exit(2)
}

var matched: [[String: Any]] = []
for source in list {
    let bundleID = stringProp(source, kTISPropertyBundleID) ?? ""
    let inputSourceID = stringProp(source, kTISPropertyInputSourceID) ?? ""
    let sourceType = (property(source, kTISPropertyInputSourceType) as? NSNumber)?.intValue ?? -1
    let sourceModeID = stringProp(source, kTISPropertyInputModeID) ?? ""

    let isTarget = bundleID == targetBundleID || inputSourceID.hasPrefix(targetBundleID + ".")
    let isABC = inputSourceID == "com.apple.keylayout.ABC"
    let isQingjian = bundleID == "app.qingjian.inputmethod" || inputSourceID.hasPrefix("app.qingjian.inputmethod.")
    guard isTarget || isABC || isQingjian else { continue }

    var row: [String: Any] = [
        "inputSourceID": inputSourceID,
        "bundleID": bundleID,
        "inputModeID": sourceModeID,
        "sourceType": sourceType,
        "name": stringProp(source, kTISPropertyLocalizedName) ?? "",
        "enabled": (property(source, kTISPropertyInputSourceIsEnabled) as? NSNumber)?.boolValue ?? false,
        "selected": (property(source, kTISPropertyInputSourceIsSelected) as? NSNumber)?.boolValue ?? false,
    ]
    row["iconImageURL"] = describeURLProp(source, kTISPropertyIconImageURL) ?? "NULL"
    row["iconRef"] = iconRefNote(source) ?? "NULL"
    matched.append(row)
    FileHandle.standardError.write(Data("ROW \(row["inputSourceID"] as? String ?? "?")  type=\(sourceType)  iconImageURL: \(isReachableText(row))  iconRef: \(row["iconRef"])\n".utf8))
}

let output: [String: Any] = [
    "targetBundleID": targetBundleID,
    "totalSourcesEnumerated": list.count,
    "rows": matched,
]
let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
