import AppKit
import Carbon
import Foundation

// Visible AppKit host: keys go through the installed system IMK input source.
// Only synthetic test content in this process is returned to the driver.
//
// 安全约束（本文件是真实宿主回归的执行端）：
// 1. 每次注入按键前必须带 guard，核对前台应用身份（bundle id／pid）；不通过时
//    一律拒绝发送按键，并在回执里给出 guardOk=false 与当前前台身份。
// 2. 窗口标题带本轮唯一标记；探针自身窗口用标题标记核对「专属测试目标身份」。
//    其他宿主应用的窗口标题由驱动侧 ax-reader 在每次发送前核对（探针是无辅助
//    功能权限的独立 App，不做 AX 查询，避免弹出辅助功能授权对话框）。
// 3. combo 把「确认键＋后键」在同一次调用里背靠背投递，中间不等待回执，
//    用于严格立即输入矩阵（确认与后键之间没有人为延迟）。

final class ProbeTextView: NSTextView {
    var inserts = 0
    var insertionReceipts: [[String: UInt64]] = []
    /// 宿主侧 setMarkedText／insertText 实际耗时与参数（归因与验收用；不含正文语义）。
    var markedDurations: [UInt64] = []
    var markedArgLog: [[Int]] = []     // [selectedRange.location, selectedRange.length, textLength]
    var markedTextLog: [String] = []
    var keyLog: [[Int]] = []           // [keyCode, modifierFlags.rawValue]（验收诊断用）
    private var inputEventNs: UInt64?

    override func keyDown(with event: NSEvent) {
        let previous = inputEventNs
        inputEventNs = UInt64(max(0, event.timestamp) * 1_000_000_000)
        keyLog.append([Int(event.keyCode), Int(event.modifierFlags.rawValue)])
        defer { inputEventNs = previous }
        super.keyDown(with: event)
    }

    override func insertText(_ text: Any, replacementRange: NSRange) {
        inserts += 1
        let start = DispatchTime.now().uptimeNanoseconds
        super.insertText(text, replacementRange: replacementRange)
        let received = DispatchTime.now().uptimeNanoseconds
        var receipt: [String: UInt64] = ["receivedNs": received, "durationNs": received - start]
        if let begin = inputEventNs, begin > 0, received >= begin {
            receipt["eventNs"] = begin
            receipt["latencyNs"] = received - begin
        }
        insertionReceipts.append(receipt)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let start = DispatchTime.now().uptimeNanoseconds
        let text = string as? String ?? (string as? NSAttributedString)?.string ?? ""
        markedArgLog.append([Int(selectedRange.location), Int(selectedRange.length), text.utf16.count])
        markedTextLog.append(text)
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        markedDurations.append(DispatchTime.now().uptimeNanoseconds - start)
    }
}

let KEY_CODES: [String: Int] = [
    "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34, "j": 38,
    "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35, "q": 12, "r": 15, "s": 1,
    "t": 17, "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
    "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
    "0": 29, "-": 27, "=": 24, "[": 33, "]": 30, ";": 41, "'": 39, ",": 43, ".": 47,
    "/": 44, "\\": 42, "`": 50, "space": 49, "return": 36, "esc": 53, "delete": 51,
    "left": 123, "right": 124, "up": 125, "down": 126, "home": 115, "end": 119,
    "pageup": 116, "pagedown": 121, "tab": 48,
    "lshift": 56, "rshift": 60, "lcontrol": 59, "rcontrol": 62,
    "loption": 58, "roption": 61, "lcommand": 55, "rcommand": 54,
]

let originalApplication = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
let originalSource = currentID()
let app = NSApplication.shared
app.setActivationPolicy(.regular)
// 完整菜单：⌘A「全选」是菜单键等价行为，没有 Edit 菜单的裸窗口里 ⌘A 什么都不做，
// 驱动的 reset（⌘A→删除）会残留正文，被当成输入法缺陷误报。真实宿主都有菜单。
let mainMenu = NSMenu()
let editMenuItem = NSMenuItem()
let editMenu = NSMenu(title: "Edit")
editMenuItem.submenu = editMenu
mainMenu.addItem(editMenuItem)
for (title, action, key) in [("Undo", Selector(("undo:")), "z"),
                             ("Redo", Selector(("redo:")), "Z"),
                             ("Cut", Selector(("cut:")), "x"),
                             ("Copy", Selector(("copy:")), "c"),
                             ("Paste", Selector(("paste:")), "v"),
                             ("Select All", Selector(("selectAll:")), "a")] {
    editMenu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
}
app.mainMenu = mainMenu
let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 430),
    styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "Gogaku IMK regression host"
let field = ProbeTextView(frame: NSRect(x: 20, y: 290, width: 560, height: 110))
let second = ProbeTextView(frame: NSRect(x: 20, y: 170, width: 560, height: 110))
for view in [field, second] {
    view.font = .systemFont(ofSize: 22)
    view.isAutomaticSpellingCorrectionEnabled = false
    view.isAutomaticTextReplacementEnabled = false
    window.contentView!.addSubview(view)
}
// 安全输入字段（field=3）：聚焦时全局 SecureEventInput 生效，输入法读不到
// 宿主光标矩形，用于切换提示无锚点场景的真实复现。
let secureField = NSSecureTextField(frame: NSRect(x: 20, y: 30, width: 560, height: 110))
secureField.font = .systemFont(ofSize: 22)
window.contentView!.addSubview(secureField)
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(field)
app.activate(ignoringOtherApps: true)

func prop(_ source: TISInputSource, _ key: CFString) -> Any? {
    guard let p = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<CFTypeRef>.fromOpaque(p).takeUnretainedValue()
}
func currentID() -> String {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return "" }
    return prop(source, kTISPropertyInputSourceID) as? String ?? ""
}
func currentPID() -> pid_t { NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0 }

/// 窗口标记（专属测试目标身份）；空串表示未设置。
var marker = ""

func focusedView() -> NSTextView {
    if window.firstResponder === second { return second }
    return field
}

func state() -> [String: Any] {
    // 正文＝去掉 marked text 后的内容（输入区字母按规格以 marked text 显示，
    // 不算已确认正文；确认前正文字段用于组合泄漏检查）。
    func committedText(_ view: NSTextView) -> String {
        let full = view.string as NSString
        let marked = view.markedRange()
        guard marked.location != NSNotFound else { return full as String }
        let head = full.substring(with: NSRange(location: 0, length: marked.location))
        let tailLocation = marked.location + marked.length
        let tail = full.substring(from: tailLocation)
        return head + tail
    }
    func markedInfo(_ view: NSTextView) -> [String: Any] {
        let marked = view.markedRange()
        if marked.location == NSNotFound || marked.length <= 0 {
            return ["location": -1, "length": 0, "text": ""]
        }
        let full = view.string as NSString
        guard marked.location + marked.length <= full.length else {
            return ["location": marked.location, "length": marked.length, "text": ""]
        }
        return ["location": marked.location, "length": marked.length,
                "text": full.substring(with: marked)]
    }
    let active = focusedView()
    let marked = markedInfo(active)
    let stateDict: [String: Any] = [
        "text": committedText(field), "rawText": field.string, "second": committedText(second),
        "marked": marked, "markedText": marked["text"] as? String ?? "",
        "inserts": field.inserts,
        "markedCount": field.markedDurations.count,
        "hostFlags": hostFlags(),
        "source": currentID(), "front": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
        "frontPid": Int(currentPID()), "windowTitle": window.title, "marker": marker,
        "focused": window.firstResponder === field ? 1 : window.firstResponder === second ? 2 : 0,
        "selection": [active.selectedRange().location, active.selectedRange().length],
    ]
    return stateDict
}

/// 宿主文本栈设置（归因实验一次只改一个因素；不碰用户应用偏好）。
struct HostFlags {
    var allowsUndo = false
    var continuousSpellChecking = false
    var automaticSpellingCorrection = false
    var automaticTextReplacement = false
    var automaticTextCompletion = false
    var richText: Bool? = nil
}
var hostFlagsState = HostFlags()

func hostFlags() -> [String: Bool?] {
    ["allowsUndo": hostFlagsState.allowsUndo,
     "continuousSpellChecking": hostFlagsState.continuousSpellChecking,
     "automaticSpellingCorrection": hostFlagsState.automaticSpellingCorrection,
     "automaticTextReplacement": hostFlagsState.automaticTextReplacement,
     "automaticTextCompletion": hostFlagsState.automaticTextCompletion]
}

func applyHostFlags() {
    for view in [field, second] {
        view.allowsUndo = hostFlagsState.allowsUndo
        view.isContinuousSpellCheckingEnabled = hostFlagsState.continuousSpellChecking
        view.isAutomaticSpellingCorrectionEnabled = hostFlagsState.automaticSpellingCorrection
        view.isAutomaticTextReplacementEnabled = hostFlagsState.automaticTextReplacement
        view.isAutomaticTextCompletionEnabled = hostFlagsState.automaticTextCompletion
        if let rich = hostFlagsState.richText { view.isRichText = rich }
    }
}

func reply(_ value: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
}

func isShiftCode(_ code: Int) -> Bool { code == 56 || code == 60 }
func isControlCode(_ code: Int) -> Bool { code == 59 || code == 62 }
func isOptionCode(_ code: Int) -> Bool { code == 58 || code == 61 }
func isCommandCode(_ code: Int) -> Bool { code == 55 || code == 54 }

func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags = []) {
    let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
    if isShiftCode(Int(code)) {
        // Shift：down 必须带 .maskShift，up 清空；flags=[] 的 flagsChanged 会
        // 让系统修饰键状态错乱（后续按键被系统补 shift，见实测）。
        e.type = .flagsChanged
        e.flags = down ? [.maskShift] : []
    } else if isControlCode(Int(code)) {
        e.type = .flagsChanged
        e.flags = down ? [.maskControl] : (flags.contains(.maskAlternate) ? [.maskAlternate] : [])
    } else if isOptionCode(Int(code)) {
        e.type = .flagsChanged
        e.flags = down ? [.maskAlternate] : []
    } else if isCommandCode(Int(code)) {
        e.type = .flagsChanged
        e.flags = down ? [.maskCommand] : []
    } else {
        e.flags = flags
    }
    e.post(tap: .cghidEventTap)
}

/// 前台身份守卫：bundle 与 pid 都必须吻合；本进程自身还核对窗口标记。
struct GuardSpec {
    let bundle: String
    let pid: Int
    let marker: String
    let checksMarker: Bool
}

func evaluate(_ spec: GuardSpec?) -> (ok: Bool, front: String, frontPid: Int, reason: String) {
    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
    let frontPid = Int(currentPID())
    guard let spec else { return (true, front, frontPid, "no-guard") }
    if !spec.bundle.isEmpty && front != spec.bundle {
        return (false, front, frontPid, "front-bundle-mismatch")
    }
    if spec.pid != 0 && frontPid != spec.pid {
        return (false, front, frontPid, "front-pid-mismatch")
    }
    if spec.checksMarker, !spec.marker.isEmpty, frontPid == ProcessInfo.processInfo.processIdentifier {
        if !window.title.contains(spec.marker) {
            return (false, front, frontPid, "window-marker-mismatch")
        }
    }
    return (true, front, frontPid, "ok")
}

/// 投递一组按键动作：动作是 {"key": "名字"} 或 {"modifier": "shift", "hold": 秒}。
func perform(_ actions: [[String: Any]]) {
    for action in actions {
        if let name = action["key"] as? String {
            guard let code = KEY_CODES[name] else { continue }
            var flags: CGEventFlags = ((action["shift"] as? Bool) ?? false) ? .maskShift : []
            var modifiers: [Int] = []
            if (action["command"] as? Bool) == true { modifiers.append(55); flags.insert(.maskCommand) }
            if (action["control"] as? Bool) == true { modifiers.append(59); flags.insert(.maskControl) }
            if (action["option"] as? Bool) == true { modifiers.append(58); flags.insert(.maskAlternate) }
            for mc in modifiers { key(CGKeyCode(mc), down: true, flags: flags) }
            key(CGKeyCode(code), down: true, flags: flags)
            key(CGKeyCode(code), down: false, flags: flags)
            for mc in modifiers.reversed() { key(CGKeyCode(mc), down: false, flags: []) }
        } else if let modifier = action["modifier"] as? String {
            let name = modifier == "shift" ? "lshift" : (modifier == "control" ? "lcontrol"
                : (modifier == "option" ? "loption" : "lcommand"))
            guard let code = KEY_CODES[name] else { continue }
            let hold = (action["hold"] as? Double) ?? 0.05
            key(CGKeyCode(code), down: true)
            if hold > 0 { Thread.sleep(forTimeInterval: hold) }
            key(CGKeyCode(code), down: false)
        }
    }
}

/// 投递一个键描述：整数键码、键名（"space"）或 "shift+键名／shift+键码"。
func postCodeSpec(_ raw: Any) {
    let shifted: Bool
    var codeValue = 0
    if let s = raw as? String {
        if s.hasPrefix("shift+") {
            shifted = true
            let rest = String(s.dropFirst("shift+".count))
            if let numeric = Int(rest) {
                codeValue = numeric
            } else {
                codeValue = KEY_CODES[rest] ?? 0
            }
        } else if let named = KEY_CODES[s] {
            shifted = false
            codeValue = named
        } else {
            shifted = false
            codeValue = Int(s) ?? 0
        }
    } else {
        shifted = false
        codeValue = raw as? Int ?? 0
    }
    key(CGKeyCode(codeValue), down: true, flags: shifted ? .maskShift : [])
    key(CGKeyCode(codeValue), down: false, flags: shifted ? .maskShift : [])
}

func guardSpec(_ request: [String: Any]) -> GuardSpec? {
    guard let raw = request["guard"] as? [String: Any] else { return nil }
    let markerValue = raw["marker"] as? String ?? ""
    return GuardSpec(bundle: raw["bundle"] as? String ?? "",
                     pid: raw["pid"] as? Int ?? 0,
                     marker: markerValue,
                     checksMarker: !markerValue.isEmpty)
}

func handle(_ request: [String: Any]) {
    let op = request["op"] as? String ?? "state"
    var delay = 0.15
    var extra: [String: Any] = [:]
    switch op {
    case "reset":
        // 真实应用清空文本前不会保留活跃组合：先按 IMK 正确姿势丢弃 marked
        // text（直接 field.string="" 会在组合活跃时崩掉宿主文本栈，实测）。
        field.unmarkText(); second.unmarkText()
        field.string = ""; second.string = ""; field.inserts = 0
        field.insertionReceipts.removeAll()
        second.insertionReceipts.removeAll()
        field.setSelectedRange(NSRange(location: 0, length: 0))
        window.makeFirstResponder(field); app.activate(ignoringOtherApps: true)
    case "receipts":
        extra["insertionReceipts"] = field.insertionReceipts
    case "keys":
        extra["keys"] = field.keyLog
    case "resetKeys":
        field.keyLog.removeAll()
    case "resetReceipts":
        field.insertionReceipts.removeAll()
    case "markedReceipts":
        extra["markedDurationsNs"] = field.markedDurations
        extra["markedDurationsSecondNs"] = second.markedDurations
        extra["markedArgs"] = field.markedArgLog
        extra["markedTexts"] = field.markedTextLog
    case "resetMarkedReceipts":
        field.markedDurations.removeAll(); field.markedArgLog.removeAll(); field.markedTextLog.removeAll()
        second.markedDurations.removeAll(); second.markedArgLog.removeAll(); second.markedTextLog.removeAll()
    case "flags":
        // 归因实验：只改探针自身文本栈设置，不修改用户应用。
        if let raw = request["allowsUndo"] as? Bool { hostFlagsState.allowsUndo = raw }
        if let raw = request["continuousSpellChecking"] as? Bool { hostFlagsState.continuousSpellChecking = raw }
        if let raw = request["automaticSpellingCorrection"] as? Bool { hostFlagsState.automaticSpellingCorrection = raw }
        if let raw = request["automaticTextReplacement"] as? Bool { hostFlagsState.automaticTextReplacement = raw }
        if let raw = request["automaticTextCompletion"] as? Bool { hostFlagsState.automaticTextCompletion = raw }
        if let raw = request["richText"] as? Bool { hostFlagsState.richText = raw }
        applyHostFlags()
        extra["hostFlags"] = hostFlags()
    case "setMarker":
        marker = request["marker"] as? String ?? ""
        window.title = "Gogaku IMK regression host \(marker)"
        delay = 0.1
    case "set":
        field.unmarkText()
        field.string = request["text"] as? String ?? ""
        let selection = request["selection"] as! [Int]
        field.setSelectedRange(NSRange(location: selection[0], length: selection[1]))
        field.inserts = 0
        window.makeFirstResponder(field)
    case "burst":
        for raw in request["codes"] as! [Any] {
            postCodeSpec(raw)
        }
        delay = 0.5
    case "pace":
        // 逐键定时回到主 runloop；不能在这里 sleep，否则探针宿主无法接收
        // 已投递事件，测到的会是宿主人为阻塞后的突发处理。
        let spec = guardSpec(request)
        let codes = request["codes"] as! [Any]
        let interval = max(0, (request["intervalMs"] as? Double) ?? 15.0) / 1000.0
        func tick(_ index: Int) {
            let verdict = evaluate(spec)
            if !verdict.ok || index == codes.count {
                var result = state()
                result["guardOk"] = verdict.ok
                result["guardReason"] = verdict.reason
                result["guardIndex"] = verdict.ok ? -1 : index
                result["guardFront"] = verdict.front
                result["guardFrontPid"] = verdict.frontPid
                reply(result)
                return
            }
            postCodeSpec(codes[index])
            DispatchQueue.main.asyncAfter(deadline: .now() + interval) { tick(index + 1) }
        }
        tick(0)
        return
    case "combo":
        // 严格立即输入：steps 里的每一步背靠背投递，步骤之间没有人为延迟；
        // 每一步之前复查守卫，前台身份变化立即中止并不再投递后续按键。
        // 兼容两种形状：[[动作,...]]（多步）与 [动作,...]（单步，validate-real-hosts
        // 严格场景的 letters_action() 直接作为一步投递）。
        let rawSteps = request["steps"] as! [Any]
        let normalizedSteps: [[Any]] = rawSteps.first is [Any]
            ? rawSteps.map { $0 as! [Any] }
            : [rawSteps]
        let spec = guardSpec(request)
        var guardOK = true
        var reason = "ok"
        var front = ""
        var frontPid = 0
        var failedStep = -1
        for (index, step) in normalizedSteps.enumerated() {
            let actions = step.compactMap { $0 as? [String: Any] }
            let verdict = evaluate(spec)
            front = verdict.front; frontPid = verdict.frontPid
            if !verdict.ok {
                guardOK = false; reason = verdict.reason; failedStep = index
                break
            }
            perform(actions)
        }
        extra["guardOk"] = guardOK
        extra["guardReason"] = reason
        extra["guardStep"] = failedStep
        extra["guardFront"] = front
        extra["guardFrontPid"] = frontPid
        delay = (request["delay"] as? Double) ?? 0.2
    case "focus":
        let target: NSResponder
        switch request["field"] as? Int {
        case 2: target = second
        case 3: target = secureField
        default: target = field
        }
        window.makeFirstResponder(target)
        app.activate(ignoringOtherApps: true)
    case "select":
        let id = request["id"] as! String
        let list = TISCreateInputSourceList([kTISPropertyInputSourceID as String:id] as CFDictionary, true).takeRetainedValue() as! [TISInputSource]
        extra["status"] = list.first.map { TISSelectInputSource($0) } ?? -1
        delay = 0.6
    case "frontApp":
        NSRunningApplication.runningApplications(withBundleIdentifier:request["id"] as! String).first?.activate(options:[])
        delay = 0.7
    case "sources":
        let list = TISCreateInputSourceList(nil, false).takeRetainedValue() as! [TISInputSource]
        extra["sources"] = list.map { s -> [String: Any] in
            ["id": prop(s,kTISPropertyInputSourceID) as? String ?? "",
             "selectable":prop(s,kTISPropertyInputSourceIsSelectCapable) as? Bool ?? false,
             "ascii":prop(s,kTISPropertyInputSourceIsASCIICapable) as? Bool ?? false,
             "selected":prop(s,kTISPropertyInputSourceIsSelected) as? Bool ?? false]
        }
    case "hotkey":
        // 真实系统快捷键：完整修饰键过渡（down → 目标键 → up）。
        let modifierCode: CGKeyCode = request["modifier"] as? String == "cmd" ? 55 : 59
        let targetCode = CGKeyCode(request["code"] as! Int)
        let modFlags: CGEventFlags = request["modifier"] as? String == "cmd" ? .maskCommand : .maskControl
        key(modifierCode, down: true, flags: modFlags)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { key(targetCode, down: true, flags: modFlags) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { key(targetCode, down: false, flags: modFlags) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { key(modifierCode, down: false, flags: modFlags) }
        delay = 1.2
    case "shiftClick":
        // 真实 Shift 单击：按下＋松开 modifiers 键本身（flagsChanged），期间无其他按键。
        let side = request["side"] as? Int ?? 0
        let code: CGKeyCode = side == 1 ? 60 : 56
        key(code, down: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { key(code, down: false) }
        delay = 0.6
    case "key":
        // 逐键前台守卫：非探针前台一律拒发（事件会落进用户正在用的应用）。
        let verdict = evaluate(guardSpec(request))
        if verdict.ok {
            let code = CGKeyCode(request["code"] as! Int)
            key(code, down:true); key(code, down:false)
        } else {
            extra["guardBlocked"] = verdict.reason
            extra["front"] = verdict.front
        }
        delay = (request["delay"] as? Double) ?? 0.2
    case "shortcut":
        // Complete modifier transitions are required; setting flags on Space alone
        // is not a faithful system-shortcut reproduction.
        let option = request["option"] as? Bool ?? false
        key(59,down:true,flags:.maskControl)
        if option { key(58,down:true,flags:[.maskControl,.maskAlternate]) }
        let flags: CGEventFlags = option ? [.maskControl,.maskAlternate] : .maskControl
        DispatchQueue.main.asyncAfter(deadline:.now()+0.1) { key(49,down:true,flags:flags) }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.2) { key(49,down:false,flags:flags) }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.3) {
            if option { key(58,down:false,flags:.maskControl) }
            key(59,down:false)
        }
        delay = 1.0
    case "chord":
        // 修饰键和弦：显式 flags 的平衡 CGEvent 序列（修饰逐个按下→主键→逆序
        // 释放）。System Events 和弦在本机实测会留下悬挂修饰状态，吞掉后续
        // 全部字母（预译注释回归 2026-11-06）。
        let chordCode = CGKeyCode(request["code"] as! Int)
        let modNames = request["modifiers"] as? [String] ?? []
        let modMap: [String: (CGKeyCode, CGEventFlags)] =
            ["shift": (56, .maskShift), "control": (59, .maskControl),
             "option": (58, .maskAlternate), "command": (55, .maskCommand)]
        var chordFlags: CGEventFlags = []
        var sequence: [(CGKeyCode, Bool, CGEventFlags)] = []
        let chordVerdict = evaluate(guardSpec(request))
        if chordVerdict.ok {
            for name in modNames {
                if let (c, f) = modMap[name] { sequence.append((c, true, f)); chordFlags.insert(f) }
            }
            sequence.append((chordCode, true, chordFlags))
            sequence.append((chordCode, false, chordFlags))
            for name in modNames.reversed() {
                if let (c, f) = modMap[name] { sequence.append((c, false, f)) }
            }
        } else {
            extra["guardBlocked"] = chordVerdict.reason
            extra["front"] = chordVerdict.front
        }
        for (index, (c, down, f)) in sequence.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(index)) { key(c, down: down, flags: f) }
        }
        delay = 0.06 * Double(sequence.count) + 0.6
    case "quit": reply(state()); app.terminate(nil); return
    default: break
    }
    DispatchQueue.main.asyncAfter(deadline:.now()+delay) {
        var result=state(); for (k,v) in extra { result[k]=v }; reply(result)
    }
}
DispatchQueue.global().async {
    while let line = readLine() {
        guard let request = try? JSONSerialization.jsonObject(with:Data(line.utf8)) as? [String:Any] else { continue }
        DispatchQueue.main.async { handle(request) }
    }
    DispatchQueue.main.async { app.terminate(nil) }
}
DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { reply(["ready":true, "originalSource":originalSource, "originalApplication":originalApplication, "pid":Int(ProcessInfo.processInfo.processIdentifier)]) }
app.run()
