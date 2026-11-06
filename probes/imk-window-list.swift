// 列出屏幕上 Gogaku 输入法进程的窗口（预译注释回归专用：定位候选窗）。
// 输出：windowNumber ownerPID ownerName layer x y w h（每窗口一行）。
// 用法：DEVELOPER_DIR=/Applications/Xcode.app/.../Developer swift probes/imk-window-list.swift
import CoreGraphics
import Foundation

// --all：含离屏窗口（面板 dismiss 会停到 -10000,‑10000，用于区分隐藏与不存在）。
var options: CGWindowListOption = [.excludeDesktopElements]
if CommandLine.arguments.contains("--all") {
    options.insert(.optionAll)
} else {
    options.insert(.optionOnScreenOnly)
}
let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
for window in list {
    let owner = window["kCGWindowOwnerName"] as? String ?? ""
    guard owner.contains("Gogaku") else { continue }
    let number = window["kCGWindowNumber"] as? Int ?? 0
    let pid = window["kCGWindowOwnerPID"] as? Int ?? 0
    let layer = window["kCGWindowLayer"] as? Int ?? 0
    let bounds = window["kCGWindowBounds"] as? [String: NSNumber] ?? [:]
    let x = bounds["X"]?.intValue ?? 0, y = bounds["Y"]?.intValue ?? 0
    let w = bounds["Width"]?.intValue ?? 0, h = bounds["Height"]?.intValue ?? 0
    print("\(number) \(pid) \(owner) layer=\(layer) \(x) \(y) \(w) \(h)")
}
