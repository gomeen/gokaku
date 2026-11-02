import SwiftUI
import GogakuCore

/// 快捷键页：VS Code「键盘快捷方式」式表格。三个可配置命令统一纳入；
/// 固定操作按真实普通／学习语义展示，不可编辑。
struct ShortcutsPage: View {
    @Binding var settings: GogakuCore.Settings
    @State private var query = ""
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable {
        case all = "全部"
        case changed = "我修改的"
        case conflict = "冲突"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SettingsSearchField(text: $query, placeholder: "搜索命令或快捷键",
                                    accessibilityName: "搜索快捷键")
                    .frame(maxWidth: 300)
                Spacer()
                Picker("筛选", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { item in
                        Text("\(item.rawValue)（\(count(for: item))）").tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 330)
                .accessibilityLabel("快捷键筛选")
            }
            table
        }
    }

    private func count(for filter: Filter) -> Int {
        switch filter {
        case .all: return ConfigurableCommand.allCases.count + KeyCombo.fixedOperations().count
        case .changed: return ConfigurableCommand.allCases.filter { isChanged($0) }.count
        case .conflict: return ConfigurableCommand.allCases.filter { conflict(for: $0) != nil }.count
        }
    }

    private func isChanged(_ command: ConfigurableCommand) -> Bool {
        command.shortcut(in: settings) != command.defaultShortcut
    }

    /// 冲突状态：当前绑定与其他可配置命令或适用状态下的固定输入操作相同。
    private func conflict(for command: ConfigurableCommand) -> String? {
        let shortcut = command.shortcut(in: settings)
        guard shortcut.isValid else { return nil }
        return KeyCombo.conflict(target: command, keyID: shortcut.key, modifiers: shortcut.modifiers, settings: settings)
    }

    private func visible(_ command: ConfigurableCommand) -> Bool {
        let shortcut = command.shortcut(in: settings)
        let hay = "\(command.displayName) \(command.rawValue) \(command.detail) \(shortcut.key)".lowercased()
        if !query.isEmpty && !hay.lowercased().contains(query.lowercased()) { return false }
        switch filter {
        case .all: return true
        case .changed: return isChanged(command)
        case .conflict: return conflict(for: command) != nil
        }
    }

    private func visible(_ fixed: KeyCombo.FixedOperation) -> Bool {
        let hay = "\(fixed.name) \(fixed.detail) \(fixed.modes)".lowercased()
        if !query.isEmpty && !hay.contains(query.lowercased()) { return false }
        return filter == .all
    }

    @ViewBuilder private var table: some View {
        VStack(spacing: 0) {
            groupHeader("模式与快速添加")
            let commands = ConfigurableCommand.allCases.filter { visible($0) }
            if commands.isEmpty {
                emptyRow
            }
            ForEach(Array(commands.enumerated()), id: \.element) { index, command in
                commandRow(command)
                if index < commands.count - 1 { Divider().opacity(0.35) }
            }

            groupHeader("固定输入操作（不可编辑）")
            let fixed = KeyCombo.fixedOperations().filter { visible($0) }
            if fixed.isEmpty && commands.isEmpty {
                emptyRow
            }
            ForEach(Array(fixed.enumerated()), id: \.element.id) { index, operation in
                fixedRow(operation)
                if index < fixed.count - 1 { Divider().opacity(0.35) }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: SettingsPalette.cardCornerRadius))
        .overlay(RoundedRectangle(cornerRadius: SettingsPalette.cardCornerRadius)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private var emptyRow: some View {
        Text("没有匹配的快捷键").font(.system(size: 12)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity).padding(.vertical, 16)
    }

    private func groupHeader(_ name: String) -> some View {
        HStack(spacing: 8) {
            Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private func commandRow(_ command: ConfigurableCommand) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(command.displayName).font(.system(size: 13))
                Text(command.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            sourceLabel(for: command)
            ShortcutEditor(command: command,
                           shortcut: Binding(get: { command.shortcut(in: settings) },
                                             set: { commit($0, for: command) }),
                           settings: settings,
                           conflictName: conflict(for: command) ?? "")
            .frame(width: 150, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private func sourceLabel(for command: ConfigurableCommand) -> some View {
        let shortcut = command.shortcut(in: settings)
        return Text(sourceLabel(shortcut: shortcut, default: command.defaultShortcut))
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(width: 52, alignment: .leading)
    }

    private func sourceLabel(shortcut: Shortcut, default defaultShortcut: Shortcut) -> String {
        if !shortcut.isValid { return "已清除" }
        return shortcut == defaultShortcut ? "默认" : "自定义"
    }

    @ViewBuilder private func fixedRow(_ fixed: KeyCombo.FixedOperation) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(fixed.name).font(.system(size: 13))
                Text("\(fixed.detail)（\(fixed.modes)）").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let combo = fixed.combo {
                HStack(spacing: 3) {
                    Text(combo.displayText).font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                }
                .accessibilityLabel("固定操作 \(fixed.name)：\(combo.displayText)")
            } else {
                Text("按住期间判定").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Text("固定").font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Color.clear.frame(width: 130, height: 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private func commit(_ shortcut: Shortcut, for command: ConfigurableCommand) {
        command.setShortcut(shortcut, in: &settings)
        // 有效快捷键改动立即提交；保存状态由壳层的 SettingsStore.onStatus 统一驱动。
        SettingsStore.shared.submit(settings)
    }
}
