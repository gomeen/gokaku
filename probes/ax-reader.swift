// AX 文本读取辅助（仅测试工具使用；输入法本身不需要辅助功能权限）。
//
// 两种用法：
// 1) 常驻模式（推荐，真实宿主回归用）：--stdin，每行一个 JSON 命令，输出一行 JSON。
//      {"op":"front"}                     前台应用／窗口／焦点元素信息
//      {"op":"check","marker":"XXX"}      前台窗口标题是否含标记（专属测试目标身份）
//      {"op":"windows"}                   前台应用的窗口列表（标题＋编号）
//      {"op":"focus","role":"AXTextArea","index":0}  按 role 聚焦第 index 个元素
//      {"op":"quit"}
// 2) 单次模式：ax-reader [--pid N] [--chrome] [--focus-role R] [--focus-index I]
//      [--require-marker TEXT] [--windows]
// 输出：{"ok":true,"app":"...","pid":N,"title":"...","texts":["..."],"focusedValue":"..."}
import AppKit
import ApplicationServices
import Foundation

func textsOf(_ element: AXUIElement, depth: Int, into out: inout [String]) {
    guard depth < 12 else { return }
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
    if let v = value as? String, !v.isEmpty { out.append(v) }
    var children: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
    if let kids = children as? [AXUIElement] {
        for kid in kids { textsOf(kid, depth: depth + 1, into: &out) }
    }
}

/// CFTypeRef → AXUIElement：条件转换在 Swift 6 下会报错，改用类型标识核对。
func asElement(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

func stringAttribute(_ element: AXUIElement, _ name: String) -> String {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return "" }
    return value as? String ?? ""
}

func selectedRange(of element: AXUIElement) -> [Int] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, "AXSelectedTextRange" as CFString, &value) == .success,
          let ax = value else { return [-1, 0] }
    var range = CFRange()
    guard AXValueGetValue(ax as! AXValue, .cfRange, &range) else { return [-1, 0] }
    return [range.location, range.length]
}

/// 找到 role 匹配的第 index 个元素并聚焦。
@discardableResult
func focusRole(_ role: String, index: Int, in root: AXUIElement) -> Bool {
    var found = 0
    func walk(_ element: AXUIElement, depth: Int) -> Bool {
        guard depth < 14 else { return false }
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        if let r = roleRef as? String, r == role {
            if found == index {
                return AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
            }
            found += 1
        }
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        if let kids = children as? [AXUIElement] {
            for kid in kids where walk(kid, depth: depth + 1) { return true }
        }
        return false
    }
    return walk(root, depth: 0)
}

func windowList(of app: AXUIElement) -> [[String: Any]] {
    var windowsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
          let windows = windowsRef as? [AXUIElement] else { return [] }
    var result: [[String: Any]] = []
    for window in windows {
        var identifier: CFTypeRef?
        var number = -1
        if AXUIElementCopyAttributeValue(window, "AXWindowNumber" as CFString, &identifier) == .success,
           let n = identifier as? NSNumber { number = n.intValue }
        result.append(["title": stringAttribute(window, kAXTitleAttribute as String),
                       "id": number,
                       "identifier": stringAttribute(window, kAXIdentifierAttribute as String)])
    }
    return result
}

final class Reader {
    var pid: pid_t = 0
    var chrome = false

    func appElement() -> (AXUIElement, String, pid_t)? {
        if pid != 0 {
            let element = AXUIElementCreateApplication(pid)
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
            return (element, name, pid)
        }
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focused)
        if let element = asElement(focused) {
            var appPid: pid_t = 0
            AXUIElementGetPid(element, &appPid)
            let name = NSRunningApplication(processIdentifier: appPid)?.localizedName ?? ""
            return (element, name, appPid)
        }
        if let front = NSWorkspace.shared.frontmostApplication {
            return (AXUIElementCreateApplication(front.processIdentifier),
                    front.localizedName ?? "", front.processIdentifier)
        }
        return nil
    }

    func front(includeTexts: Bool) -> [String: Any] {
        guard let (app, name, appPid) = appElement() else {
            return ["ok": false, "reason": "no-accessible-application"]
        }
        // Chrome 需要显式激活辅助功能树。
        if chrome {
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        var frontBundle = ""
        if let front = NSWorkspace.shared.frontmostApplication {
            frontBundle = front.bundleIdentifier ?? ""
        }
        var axBundle = ""
        if appPid != 0 {
            axBundle = NSRunningApplication(processIdentifier: appPid)?.bundleIdentifier ?? ""
        }
        var windowRef: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef)
        var winTitle = ""
        var out: [String] = []
        var focusedValue = ""
        var focusedRole = ""
        var focusedIdentifier = ""
        var selectedText = ""
        var range = [-1, 0]
        if let window = asElement(windowRef) {
            winTitle = stringAttribute(window, kAXTitleAttribute as String)
            if includeTexts { textsOf(window, depth: 0, into: &out) }
            var focusedEl: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXFocusedUIElementAttribute as CFString, &focusedEl)
            if let f = asElement(focusedEl) {
                if includeTexts {
                    var v: CFTypeRef?
                    AXUIElementCopyAttributeValue(f, kAXValueAttribute as CFString, &v)
                    focusedValue = v as? String ?? ""
                    selectedText = stringAttribute(f, "AXSelectedText")
                }
                focusedRole = stringAttribute(f, kAXRoleAttribute as String)
                focusedIdentifier = stringAttribute(f, kAXIdentifierAttribute as String)
                range = selectedRange(of: f)
            }
        }
        return ["ok": true, "app": name, "pid": Int(appPid), "title": winTitle,
                "frontBundle": frontBundle, "axBundle": axBundle,
                "texts": out, "focusedValue": focusedValue,
                "focusedRole": focusedRole, "focusedIdentifier": focusedIdentifier,
                "selectedText": selectedText, "selectedRange": range]
    }

    func check(marker: String) -> [String: Any] {
        let info = front(includeTexts: false)
        guard info["ok"] as? Bool == true else { return info }
        let title = info["title"] as? String ?? ""
        let ok = marker.isEmpty ? true : title.contains(marker)
        var result = info
        result["marker"] = marker
        result["markerOk"] = ok
        return result
    }
}

func emit(_ value: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

let arguments = CommandLine.arguments
func argument(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let reader = Reader()
if let value = argument("--pid") { reader.pid = pid_t(value) ?? 0 }
reader.chrome = arguments.contains("--chrome")

if arguments.contains("--stdin") {
    while let line = readLine() {
        guard let data = line.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
        switch request["op"] as? String ?? "front" {
        case "front":
            emit(reader.front(includeTexts: (request["texts"] as? Bool) ?? true))
        case "check":
            emit(reader.check(marker: request["marker"] as? String ?? ""))
        case "windows":
            guard let (app, _, _) = reader.appElement() else { emit(["ok": false, "reason": "no-accessible-application"]); continue }
            emit(["ok": true, "windows": windowList(of: app)])
        case "focus":
            guard let (app, _, _) = reader.appElement() else { emit(["ok": false, "reason": "no-accessible-application"]); continue }
            var windowRef: CFTypeRef?
            AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef)
            var ok = false
            if let window = asElement(windowRef) {
                ok = focusRole(request["role"] as? String ?? "AXTextArea",
                               index: request["index"] as? Int ?? 0, in: window)
            }
            emit(["ok": ok])
        case "quit":
            emit(["ok": true]); exit(0)
        default:
            emit(["ok": false, "reason": "unknown-op"])
        }
    }
    exit(0)
}

if arguments.contains("--windows") {
    guard let (app, _, _) = reader.appElement() else {
        print(#"{"ok":false,"reason":"no-accessible-application"}"#)
        exit(2)
    }
    emit(["ok": true, "windows": windowList(of: app)])
    exit(0)
}

if let role = argument("--focus-role") {
    guard let (app, _, _) = reader.appElement() else {
        print(#"{"ok":false,"reason":"no-accessible-application"}"#)
        exit(2)
    }
    var windowRef: CFTypeRef?
    AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef)
    if let window = asElement(windowRef) {
        _ = focusRole(role, index: Int(argument("--focus-index") ?? "0") ?? 0, in: window)
    }
}

var info = reader.front(includeTexts: true)
if let marker = argument("--require-marker") {
    let title = info["title"] as? String ?? ""
    var marked = info
    marked["marker"] = marker
    marked["markerOk"] = title.contains(marker)
    info = marked
}
emit(info)
if argument("--require-marker") != nil {
    exit((info["markerOk"] as? Bool) == true ? 0 : 3)
}
