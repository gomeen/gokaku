import CoreGraphics
import CoreServices
import Darwin
import Foundation

// 切换提示浮层观察器：只读 CGWindowList，不注入任何事件、不抢焦点。
//
// 用法：toast-watch <ownerPid> <durationSeconds>
// 对指定进程（输入法）每 100ms 采样一次屏上窗口；基线之后新出现的
// layer=25（statusBar）窗口即切换提示浮层（ToastWindow，borderless NSPanel），
// 出现／消失各输出一行 JSON。候选窗 layer=101、菜单图标属独立进程，
// 都不会误报。退出时输出 {"done":true}。

func pidPath(_ pid: Int32) -> String {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return "" }
    return String(cString: buffer)
}

guard CommandLine.arguments.count >= 3,
      let owner = Int32(CommandLine.arguments[1]),
      let duration = Double(CommandLine.arguments[2]), duration > 0 else {
    FileHandle.standardError.write(Data("usage: toast-watch <ownerPid> <durationSeconds>\n".utf8))
    exit(2)
}

func emit(_ value: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

let start = Date()

func sample() -> (layer25: [CGWindowID: [String: Any]], panelCount: Int) {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    var layer25: [CGWindowID: [String: Any]] = [:]
    var panels = 0
    for window in list {
        guard let pid = window[kCGWindowOwnerPID as String] as? Int32, pid == owner else { continue }
        let layer = window[kCGWindowLayer as String] as? Int ?? -1
        if layer == 25, let id = window["kCGWindowWindowID"] as? CGWindowID {
            let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
            layer25[id] = ["bounds": bounds]
        } else if layer == 101 {
            panels += 1
        }
    }
    return (layer25, panels)
}

emit(["ready": true, "ownerPid": Int(owner), "ownerPath": pidPath(owner)])
let baseline = Set(sample().layer25.keys)
var seen = baseline
var appearedAt: [CGWindowID: Date] = [:]
let deadline = start.addingTimeInterval(duration)

while Date() < deadline {
    usleep(100_000)
    let now = sample()
    let current = Set(now.layer25.keys)
    for id in current.subtracting(seen) {
        appearedAt[id] = Date()
        emit(["tMs": Int(Date().timeIntervalSince(start) * 1000), "event": "shown",
              "windowID": Int(id), "info": now.layer25[id] ?? [:]])
    }
    for id in seen.subtracting(current) {
        let life = appearedAt[id].map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
        emit(["tMs": Int(Date().timeIntervalSince(start) * 1000), "event": "hidden",
              "windowID": Int(id), "lifeMs": life])
    }
    seen = current
}

emit(["done": true, "tMs": Int(Date().timeIntervalSince(start) * 1000),
      "panelCount": sample().panelCount, "layer25Count": seen.count])
