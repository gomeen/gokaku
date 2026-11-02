import SwiftUI
import GogakuCore

/// 快捷键页：VS Code「键盘快捷方式」式表格（原型 .kshead 结构）。
/// 头部卡片：标题行（⌨ 图标＋「键盘快捷方式」＋右侧搜索框）与筛选胶囊分行；
/// 表格统一四列「命令名称 → 键帽（210）→ 来源（90）→ 操作（104）」，
/// 可编辑行、固定行与空状态行共用同一列宽与对齐。
/// 三个可配置命令统一纳入（普通／学习、学习方向、快速添加）；固定操作按真实
/// 普通／学习语义展示，不可编辑。冲突草稿由页面统一持有：录制产生的冲突
/// 不写入设置，「冲突」筛选与行内提示都能看到。
struct ShortcutsPage: View {
    @Binding var settings: GogakuCore.Settings
    @State private var query = ""
    @State private var filter: Filter = .all
    /// 录制产生的冲突草稿：不写入设置、不覆盖最后有效绑定。
    @State private var conflictDraft: ConflictDraft?

    /// 冲突草稿：哪条命令、尝试的组合、与谁冲突。
    private struct ConflictDraft: Equatable {
        let command: ConfigurableCommand
        let attempted: Shortcut
        let clashName: String
    }

    enum Filter: String, CaseIterable {
        case all = "全部"
        case changed = "我修改的"
        case conflict = "冲突"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 用户裁决 2026-11-02：去掉标题行，筛选胶囊与搜索同行。
            headerCard
            groupHeader("模式与快速添加")
            commandRows
            groupHeader("组合中的操作")
            fixedRows
        }
    }

    // MARK: 头部（筛选胶囊与搜索同行；无卡片背景，底部 hairline）

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    ForEach(Filter.allCases, id: \.self) { item in
                        filterTab(item)
                    }
                }
                Spacer(minLength: 12)
                SettingsSearchField(text: $query, placeholder: "搜索",
                                    accessibilityName: "搜索命令或快捷键",
                                    background: SettingsPalette.windowBackground)
                    .frame(maxWidth: 300)
            }
            .padding(.bottom, 10)
            SettingsRowDivider()
        }
        .accessibilityElement(children: .contain)
    }

    /// 筛选胶囊（.kstab：高 28、radius 999；选中 accent-soft 底＋accent-ring 描边）。
    private func filterTab(_ item: Filter) -> some View {
        let isSelected = filter == item
        let isConflict = item == .conflict
        return Button {
            filter = item
        } label: {
            HStack(spacing: 6) {
                if isConflict {
                    Text("⚠").font(.system(size: 11)).accessibilityHidden(true)
                }
                Text(item.rawValue)
                Text("\(count(for: item))")
                    .font(.system(size: 10.5))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(isSelected ? SettingsPalette.cardBackground
                                       : Color.primary.opacity(0.06)))
            }
            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? SettingsPalette.accentText : SettingsPalette.secondaryText)
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            .background(
                Capsule().fill(isSelected ? SettingsPalette.accentSoft : Color.clear)
                    .overlay(Capsule().strokeBorder(
                        isSelected ? SettingsPalette.accentRing : Color.clear, lineWidth: 1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityLabel("\(item.rawValue)筛选，\(count(for: item)) 条")
    }

    // MARK: 分组标题（.ksgroup：11/600 次级色＋hairline 线）

    private func groupHeader(_ name: String) -> some View {
        HStack(spacing: 10) {
            Text(name).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SettingsPalette.secondaryText)
            Rectangle().fill(SettingsPalette.hairline).frame(height: 1)
        }
        .padding(.horizontal, 2)
        .padding(.top, 16)
        .padding(.bottom, 4)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: 可编辑命令行

    @ViewBuilder private var commandRows: some View {
        let commands = ConfigurableCommand.allCases.filter { visible($0) }
        if commands.isEmpty {
            emptyRow
        } else {
            VStack(spacing: 0) {
                ForEach(Array(commands.enumerated()), id: \.element) { index, command in
                    CommandRow(command: command,
                               settings: settings,
                               conflictText: conflictText(for: command),
                               onCommit: { commit($0, for: command) },
                               onConflictDraft: { recordConflictDraft(command, attempted: $0, clash: $1) },
                               onEditingStart: { clearConflictDraft(except: $0) })
                    if index < commands.count - 1 { SettingsRowDivider() }
                }
            }
        }
    }

    // MARK: 固定操作行

    @ViewBuilder private var fixedRows: some View {
        let operations = KeyCombo.fixedOperations().filter { visible($0) }
        if operations.isEmpty && ConfigurableCommand.allCases.filter({ visible($0) }).isEmpty {
            emptyRow
        } else {
            VStack(spacing: 0) {
                ForEach(Array(operations.enumerated()), id: \.element.id) { index, operation in
                    FixedRow(operation: operation)
                    if index < operations.count - 1 { SettingsRowDivider() }
                }
            }
        }
    }

    /// 空状态行（.ksempty：跨全部四列居中）。
    private var emptyRow: some View {
        Text("没有匹配的快捷键")
            .font(.system(size: 11.5))
            .foregroundStyle(SettingsPalette.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .padding(.horizontal, 12)
    }

    // MARK: 筛选计数与可见性

    private func count(for filter: Filter) -> Int {
        switch filter {
        case .all: return ConfigurableCommand.allCases.count + KeyCombo.fixedOperations().count
        case .changed: return ConfigurableCommand.allCases.filter { isChanged($0) }.count
        case .conflict: return ConfigurableCommand.allCases.filter { conflictText(for: $0) != nil }.count
        }
    }

    private func isChanged(_ command: ConfigurableCommand) -> Bool {
        command.shortcut(in: settings) != command.defaultShortcut
    }

    /// 冲突展示文本：冲突草稿优先（未写入），其次是当前设置下已存在的冲突。
    private func conflictText(for command: ConfigurableCommand) -> String? {
        if let draft = conflictDraft, draft.command == command {
            return "未写入：与「\(draft.clashName)」冲突"
        }
        let shortcut = command.shortcut(in: settings)
        guard shortcut.isValid else { return nil }
        guard let clash = KeyCombo.conflict(target: command, keyID: shortcut.key,
                                            modifiers: shortcut.modifiers, settings: settings) else { return nil }
        return "与「\(clash)」冲突"
    }

    private func visible(_ command: ConfigurableCommand) -> Bool {
        let shortcut = command.shortcut(in: settings)
        return ShortcutQuery.matches(query: query,
                                     name: command.displayName,
                                     identifier: command.rawValue,
                                     detail: command.detail,
                                     shortcut: shortcut)
            && matchesFilter(command)
    }

    private func matchesFilter(_ command: ConfigurableCommand) -> Bool {
        switch filter {
        case .all: return true
        case .changed: return isChanged(command)
        case .conflict: return conflictText(for: command) != nil
        }
    }

    private func visible(_ fixed: KeyCombo.FixedOperation) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        // 与可编辑行一致：完整组合查询按规范化组合精确匹配，否则文本子串。
        if let combo = ShortcutQuery.parseCombo(trimmed) {
            guard let fixedCombo = fixed.combo else { return false }
            return filter == .all && fixedCombo.keyID == combo.key
                && fixedCombo.modifiers == combo.modifiers
        }
        let comboText = fixed.combo?.displayText ?? ""
        let hay = "\(fixed.name) \(fixed.detail) \(fixed.modes) \(comboText)".lowercased()
        if !trimmed.isEmpty && !hay.contains(trimmed.lowercased()) { return false }
        return filter == .all
    }

    // MARK: 写回与冲突草稿

    /// 唯一写回路径：编辑器通过 Binding 提交到这里，立即保存；
    /// 该命令的冲突草稿随之清除（成功录制／清除／恢复默认都经过这里）。
    private func commit(_ shortcut: Shortcut, for command: ConfigurableCommand) {
        command.setShortcut(shortcut, in: &settings)
        if conflictDraft?.command == command { conflictDraft = nil }
        SettingsStore.shared.submit(settings)
    }

    /// 录制裁决冲突：记录草稿（不写入设置），「冲突」筛选与计数即可见。
    private func recordConflictDraft(_ command: ConfigurableCommand, attempted: Shortcut, clash: String) {
        conflictDraft = ConflictDraft(command: command, attempted: attempted, clashName: clash)
    }

    /// 开始编辑（录制）其他命令时清除旧草稿；编辑同一命令时保留待更新。
    private func clearConflictDraft(except command: ConfigurableCommand) {
        if let draft = conflictDraft, draft.command != command { conflictDraft = nil }
    }
}

// MARK: - 表格行（可编辑命令）

/// 可编辑命令行：统一四列「命令名称 → 键帽 → 来源 → 操作」。
/// 操作按钮在行悬停或录制中显示（原型 .ksact__btns hover 行为）。
private struct CommandRow: View {
    let command: ConfigurableCommand
    let settings: GogakuCore.Settings
    let conflictText: String?
    let onCommit: (Shortcut) -> Void
    let onConflictDraft: (Shortcut, String) -> Void
    let onEditingStart: (ConfigurableCommand) -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 0) {
            // 命令列（自适应，长名称换行不挤压键帽列）。
            Text(command.displayName)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(SettingsPalette.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)
                .padding(.vertical, 11)
            // 键帽 210 ＋ 来源 90 ＋ 操作 104（列宽由编辑器内部统一常量驱动）。
            ShortcutEditor(command: command,
                           shortcut: Binding(
                               get: { command.shortcut(in: settings) },
                               set: { onCommit($0) }),
                           settings: settings,
                           layout: .tableRow(source: sourceLabel),
                           conflictName: conflictText ?? "",
                           onConflictDraft: onConflictDraft,
                           onEditingStart: onEditingStart,
                           actionsVisible: hovered)
        }
        .background(hovered ? SettingsPalette.accentSoft : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(command.displayName)，来源\(sourceLabel)")
    }

    private var sourceLabel: String {
        let shortcut = command.shortcut(in: settings)
        if !shortcut.isValid { return "已清除" }
        return shortcut == command.defaultShortcut ? "默认" : "自定义"
    }
}

// MARK: - 表格行（固定操作）

/// 固定操作行：与可编辑行共用同一四列列宽；操作列为空。
private struct FixedRow: View {
    let operation: KeyCombo.FixedOperation
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 0) {
            // 命令列（.ksrow--fixed：名称次级色、500 字重）。
            Text(operation.name)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(SettingsPalette.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)
                .padding(.vertical, 11)
            // 键帽列 210。
            HStack(spacing: 5) {
                if let combo = operation.combo {
                    ForEach(fixedCaps(combo), id: \.self) { cap in
                        SettingsKeycap(label: cap)
                    }
                } else {
                    Text("—").font(.system(size: 12))
                        .foregroundStyle(SettingsPalette.tertiaryText)
                }
            }
            .frame(width: SettingsPalette.keyColumnWidth, alignment: .leading)
            .padding(.horizontal, 12)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(operation.combo.map { "固定操作 \(operation.name)：\($0.displayText)" }
                                ?? "固定操作 \(operation.name)")
            // 来源列 90。
            Text("固定")
                .font(.system(size: 11.5))
                .foregroundStyle(SettingsPalette.secondaryText)
                .frame(width: SettingsPalette.sourceColumnWidth, alignment: .leading)
            // 操作列 104（固定行无操作）。
            Color.clear
                .frame(width: SettingsPalette.actionColumnWidth)
                .padding(.trailing, 12)
        }
        .background(hovered ? SettingsPalette.accentSoft : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }

    private func fixedCaps(_ combo: KeyCombo) -> [String] {
        var result: [String] = []
        let flags = NSEvent.ModifierFlags(rawValue: combo.modifiers)
        if flags.contains(.control) { result.append("⌃") }
        if flags.contains(.option) { result.append("⌥") }
        if flags.contains(.shift) { result.append("⇧") }
        if flags.contains(.command) { result.append("⌘") }
        let label = KeyCombo.keyLabels[combo.keyID]
            ?? (combo.keyID.count == 1 ? combo.keyID.uppercased() : combo.keyID)
        result.append(label)
        return result
    }
}

// MARK: - 搜索的组合规范化（与录制一致的组合语义）

/// 快捷键搜索解析：把「cmd k」「⌘K」「ctrl+shift+a」等写法规范化为
/// 与录制一致的（keyID, modifiers）做精确匹配；解析不出完整组合时
/// 退回普通文本子串匹配（名称／命令标识／说明／组合显示文本）。
/// 纯函数放在 GogakuSettings 内，不改动共享核心 KeyCombo.swift。
enum ShortcutQuery {
    /// query 是否匹配该命令。query 为空白时匹配一切。
    static func matches(query: String, name: String, identifier: String,
                        detail: String, shortcut: Shortcut) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if let combo = parseCombo(trimmed) {
            guard shortcut.isValid else { return false }
            return combo.key == shortcut.key && combo.modifiers == shortcut.modifiers
        }
        let hay = "\(name) \(identifier) \(detail) \(display(shortcut))".lowercased()
        return hay.contains(trimmed.lowercased())
    }

    // MARK: 组合解析

    /// 把用户输入解析为规范组合；不是完整组合（缺修饰键、缺键、含未知词）时返回 nil。
    static func parseCombo(_ input: String) -> (key: String, modifiers: UInt)? {
        let tokens = tokenize(input)
        var modifiers: UInt = 0
        var key: String?
        for token in tokens {
            if let flag = modifierFlag(token) {
                modifiers |= flag
            } else if key == nil, let normalized = normalizeKey(token) {
                key = normalized
            } else {
                return nil   // 未知词：不是组合查询，交给文本匹配。
            }
        }
        guard let key, modifiers != 0 else { return nil }
        return (key, modifiers)
    }

    /// 拆 token：＋、-、空格都是分隔符；⌘⌥⇧⌃ 符号各自成词。
    private static func tokenize(_ input: String) -> [String] {
        let symbolSet = CharacterSet(charactersIn: "⌘⌥⇧⌃")
        var tokens: [String] = []
        var current = ""
        for scalar in input.unicodeScalars {
            if scalar == "+" || scalar == "-" || scalar == " " || CharacterSet.newlines.contains(scalar) {
                if !current.isEmpty { tokens.append(current); current = "" }
                if symbolSet.contains(scalar) { tokens.append(String(scalar)) }
            } else if symbolSet.contains(scalar) {
                if !current.isEmpty { tokens.append(current); current = "" }
                tokens.append(String(scalar))
            } else {
                current.unicodeScalars.append(scalar)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens.filter { !$0.isEmpty }
    }

    /// 修饰词 → ModifierFlags（与录制采集的四修饰位一致）。
    private static func modifierFlag(_ token: String) -> UInt? {
        switch token.lowercased() {
        case "cmd", "command", "⌘", "meta":
            return NSEvent.ModifierFlags.command.rawValue
        case "ctrl", "control", "⌃":
            return NSEvent.ModifierFlags.control.rawValue
        case "alt", "option", "opt", "⌥":
            return NSEvent.ModifierFlags.option.rawValue
        case "shift", "⇧":
            return NSEvent.ModifierFlags.shift.rawValue
        default:
            return nil
        }
    }

    /// 键名规范化：特殊键别名、F 键、单字符小写化（与存储的规范键标识一致）。
    private static func normalizeKey(_ token: String) -> String? {
        let lowered = token.lowercased()
        let aliases: [String: String] = [
            "return": "return", "enter": "return", "ret": "return",
            "tab": "tab", "space": "space",
            "esc": "esc", "escape": "esc",
            "delete": "backspace", "backspace": "backspace", "del": "backspace",
            "forwarddelete": "forwarddelete",
            "home": "home", "end": "end", "pageup": "pageup", "pagedown": "pagedown",
            "left": "left", "right": "right", "up": "up", "down": "down",
            "←": "left", "→": "right", "↑": "up", "↓": "down",
        ]
        if let alias = aliases[lowered] { return alias }
        if let label = aliasByLabel[lowered] { return label }
        // F 键：f1–f19。
        if lowered.hasPrefix("f"), lowered.dropFirst().allSatisfy(\.isNumber),
           let number = Int(lowered.dropFirst()), (1...19).contains(number) {
            return lowered
        }
        // 单字符：字母／数字／标点小写化（标点按存储的移位后字符原样匹配）。
        if lowered.count == 1 { return lowered }
        return nil
    }

    /// 显示名反查（「⌦」「Delete」等键帽文案 → 规范键标识）。
    private static let aliasByLabel: [String: String] = [
        "return": "return", "tab": "tab", "space": "space",
        "delete": "backspace", "esc": "esc", "⌦": "forwarddelete",
        "home": "home", "end": "end", "page up": "pageup", "page down": "pagedown",
    ]

    private static func display(_ shortcut: Shortcut) -> String {
        shortcut.isValid ? KeyCombo(shortcut: shortcut)?.displayText ?? "" : "未设置"
    }
}
