// 切换/查询系统输入源（TISSelectInputSource；仅本机开发与验收用）。
// 用法：
//   swift scripts/tis-select.swift <inputSourceID>   # 切换，如 org.gogaku.inputmethod.Hans
//   swift scripts/tis-select.swift --current         # 只打印当前输入源 ID
// 不注册、不启用输入源；目标必须已在系统设置中启用才能选中。
import AppKit
import Carbon
import Foundation

func property(_ source: TISInputSource, _ key: CFString) -> CFTypeRef? {
    guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
}

func sourceID(_ source: TISInputSource) -> String {
    (property(source, kTISPropertyInputSourceID) as? String) ?? ""
}

let argument = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "--current"
if argument == "--current" {
    let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    FileHandle.standardOutput.write((sourceID(current) + "\n").data(using: .utf8)!)
    exit(0)
}

let wanted = argument
let list = TISCreateInputSourceList([kTISPropertyInputSourceID as String: wanted] as CFDictionary, true)
    .takeRetainedValue() as! [TISInputSource]
guard let target = list.first else {
    FileHandle.standardError.write(("input source not found: \(wanted)\n").data(using: .utf8)!)
    exit(1)
}
let status = TISSelectInputSource(target)
FileHandle.standardOutput.write(((status == noErr ? "selected: " : "error: ") + wanted + "\n").data(using: .utf8)!)
exit(status == noErr ? 0 : 2)
