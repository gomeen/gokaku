import Foundation
import AppKit

/// 规范键组合：录制、存储与输入法事件匹配共用同一转换逻辑（2026-11-03 定稿）。
/// `keyID` 是规范键标识；macOS 特殊键（F 键等）与 keyCode 的映射留在本平台层，
/// 不进入共享核心 C ABI。
public struct KeyCombo: Codable, Equatable, Hashable, Sendable {
    public var keyID: String
    public var modifiers: UInt   // NSEvent.ModifierFlags rawValue（四修饰位）

    public init(keyID: String, modifiers: UInt) {
        self.keyID = keyID
        self.modifiers = modifiers
    }

    public init?(shortcut: Shortcut) {
        guard shortcut.isValid else { return nil }
        guard KeyCombo.isBindable(keyID: shortcut.key, modifiers: shortcut.modifiers) else { return nil }
        self.init(keyID: shortcut.key, modifiers: shortcut.modifiers)
    }

    public var shortcut: Shortcut { Shortcut(key: keyID, modifiers: modifiers) }

    public static let modifierMask = NSEvent.ModifierFlags([.control, .shift, .option, .command]).rawValue

    // MARK: 特殊键映射（平台层）

    /// keyCode → 规范键标识。F 键与功能键必须按 keyCode 判定：
    /// 它们的 charactersIgnoringModifiers 是系统私用区字符，不稳定。
    public static let keyCodeMap: [Int: String] = [
        36: "return", 48: "tab", 49: "space", 51: "backspace", 53: "esc",
        117: "forwarddelete", 115: "home", 119: "end", 116: "pageup", 121: "pagedown",
        123: "left", 124: "right", 125: "down", 126: "up",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6",
        98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
        105: "f13", 107: "f14", 113: "f15",
    ]

    public static let keyLabels: [String: String] = [
        "return": "Return", "tab": "Tab", "space": "Space", "backspace": "Delete",
        "esc": "Esc", "forwarddelete": "⌦", "home": "Home", "end": "End",
        "pageup": "Page Up", "pagedown": "Page Down",
        "left": "←", "right": "→", "down": "↓", "up": "↑",
    ]

    public static func modifierSymbols(_ modifiers: UInt) -> String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var out = ""
        if flags.contains(.control) { out += "⌃" }
        if flags.contains(.option) { out += "⌥" }
        if flags.contains(.shift) { out += "⇧" }
        if flags.contains(.command) { out += "⌘" }
        return out
    }

    public var displayText: String {
        if keyID.isEmpty { return "未设置" }
        let label: String
        if let mapped = Self.keyLabels[keyID] {
            label = mapped
        } else if Self.isFunctionKey(keyID) {
            label = keyID.uppercased()
        } else {
            label = keyID.count == 1 ? keyID.uppercased() : keyID
        }
        return Self.modifierSymbols(modifiers) + label
    }

    // MARK: NSEvent 转换

    /// 把按键事件转换为规范组合；不构成可匹配组合时返回 nil。
    /// - 字母／数字／标点：charactersIgnoringModifiers 的单标量（字母小写化；
    ///   带修饰键的标点保留移位后字符，如 Shift＋1 → `!`）。
    /// - F 键与功能键：按 keyCode 表。
    public static func from(event: NSEvent) -> KeyCombo? {
        guard event.type == .keyDown else { return nil }
        let modifiers = event.modifierFlags.intersection(NSEvent.ModifierFlags(rawValue: modifierMask)).rawValue
        if let mapped = keyCodeMap[Int(event.keyCode)] { return KeyCombo(keyID: mapped, modifiers: modifiers) }
        guard let chars = event.charactersIgnoringModifiers,
              chars.count == 1,
              let scalar = chars.unicodeScalars.first else { return nil }
        // 私用区（未知功能键）与控制字符不可绑定。
        if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return nil }
        if CharacterSet.controlCharacters.contains(scalar) { return nil }
        // 字母小写化，其余字符原样（带修饰键的标点保留移位后字符，如 Shift＋1 → !）。
        let lowered = String(scalar).lowercased()
        guard lowered.count == 1, let normalized = lowered.unicodeScalars.first else { return nil }
        return KeyCombo(keyID: String(Character(normalized)), modifiers: modifiers)
    }

    // MARK: 绑定资格

    /// 单独修饰键不构成快捷键（由调用方在 flagsChanged 时不结束录制保证）；
    /// 无修饰键的可打印字符不允许绑定，F 键除外。
    public static func isBindable(keyID: String, modifiers: UInt) -> Bool {
        guard !keyID.isEmpty, modifiers != 0 else { return false }
        if isFunctionKey(keyID) { return true }
        return keyID.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    /// F 键判定（裸键绑定资格专用：F1–F19 可无修饰键绑定）。
    public static func isFunctionKey(_ keyID: String) -> Bool {
        guard keyID.hasPrefix("f"), keyID.dropFirst().allSatisfy(\.isNumber),
              let number = Int(keyID.dropFirst()) else { return false }
        return (1...19).contains(number)
    }

    /// 无修饰键只有 F 键可绑定；单独修饰键不构成快捷键（录制层保证不结束录制）。
    public static func recordingRejection(keyID: String, modifiers: UInt) -> String? {
        if modifiers == 0 {
            if isFunctionKey(keyID) { return nil }
            return "请加上修饰键（Control／Option／Shift／Command），或改用 F1–F15"
        }
        return isBindable(keyID: keyID, modifiers: modifiers) ? nil : "这个键不支持，请换一个"
    }

    // MARK: 冲突检查

    /// 固定输入操作（按真实普通／学习语义；不可编辑，只用于冲突检查与展示）。
    /// Shift 单击与 `,`／`.` 翻页是组合内条件占用，不是固定组合，不在此列。
    public struct FixedOperation {
        public let name: String
        public let detail: String
        public let combo: KeyCombo?
        public let modes: String
        /// 界面行标识（同一操作名可能出现在多个组合上）。
        public let id: String
        init(_ name: String, _ detail: String, keyID: String?, modifiers: UInt, modes: String) {
            self.name = name
            self.detail = detail
            self.combo = keyID.map { KeyCombo(keyID: $0, modifiers: modifiers) }
            self.modes = modes
            self.id = (keyID ?? "shift-click") + "+\(modifiers)"
        }
    }

    public static func fixedOperations() -> [FixedOperation] {
        let ctrl = NSEvent.ModifierFlags([.control]).rawValue
        let cmd = NSEvent.ModifierFlags([.command]).rawValue
        return [
            FixedOperation("取消组合", "取消当前输入，不提交到宿主", keyID: "esc", modifiers: 0, modes: "普通＋学习"),
            FixedOperation("原文上屏", "学习组合中明确提交原文，不执行翻译", keyID: "return", modifiers: cmd, modes: "学习"),
            FixedOperation("行首／行尾", "组合中移动拼音光标或选择位置", keyID: "a", modifiers: ctrl, modes: "普通"),
            FixedOperation("光标后退／前进", "组合中逐字符移动", keyID: "b", modifiers: ctrl, modes: "普通"),
            FixedOperation("行首／行尾", "组合中移动到行首或行尾", keyID: "e", modifiers: ctrl, modes: "普通"),
            FixedOperation("光标后退／前进", "组合中逐字符移动", keyID: "f", modifiers: ctrl, modes: "普通"),
            FixedOperation("下一／上一候选", "组合中跨页切换候选", keyID: "n", modifiers: ctrl, modes: "普通"),
            FixedOperation("下一／上一候选", "组合中跨页切换候选", keyID: "p", modifiers: ctrl, modes: "普通"),
            FixedOperation("删除个人学习词", "组合中删除选中候选的个人学习记录", keyID: "backspace", modifiers: ctrl, modes: "普通"),
            FixedOperation("原文上屏", "普通组合中按宿主快捷键规则交还宿主", keyID: "return", modifiers: ctrl, modes: "普通"),
        ]
    }

    /// 与其他可配置命令或固定操作冲突时返回冲突名称；无冲突返回 nil。
    /// 只检查本输入法实际消费的组合，不宣称能检测其他应用或系统快捷键。
    public static func conflict(target: ConfigurableCommand, keyID: String, modifiers: UInt, settings: Settings) -> String? {
        guard !keyID.isEmpty else { return nil }
        for command in ConfigurableCommand.allCases where command != target {
            let other = command.shortcut(in: settings)
            if other.isValid, other.key == keyID, other.modifiers == modifiers {
                return command.displayName
            }
        }
        let combo = KeyCombo(keyID: keyID, modifiers: modifiers)
        for fixed in fixedOperations() where fixed.combo == combo {
            return "\(fixed.name)（固定，\(fixed.modes)）"
        }
        return nil
    }
}
