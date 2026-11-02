import SwiftUI
import AppKit
import GogakuCore

/// 应用列表行组件：图标＋名称（不常显 bundle ID），三种范围共用同一套列表
/// 与可搜索添加弹层；范围状态由调用方各自的绑定持有，互不串值。
/// 行样式对应原型 .approw（32×32 图标＋名称 13）；「按应用默认英文」不显示
/// 计数文本（原型仅排除列表显示「N 个应用已排除」）。
struct AppListEditor: View {
    enum Mode {
        /// 按应用默认英文：每行有启用开关和移除；关闭后保留该行。
        case defaultEnglish(entries: Binding<[EnglishAppEntry]>)
        /// 排除类列表：加入即排除，移除即恢复，无开关。
        case excluded(ids: Binding<Set<String>>)
    }

    let mode: Mode
    let emptyText: String
    let addSheetTitle: String
    let accessibilityPrefix: String
    @ObservedObject var catalog: AppCatalog
    @State private var pickerOpen = false

    /// 「按应用默认英文」无计数文本（原型一致）；排除列表显示「N 个应用已排除」。
    private var showsSummary: Bool {
        switch mode {
        case .defaultEnglish: return false
        case .excluded: return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // .apptoolbar：计数与「添加应用…」两端对齐。
            HStack {
                if showsSummary {
                    Text(summaryText).font(.system(size: 11.5))
                        .foregroundStyle(SettingsPalette.secondaryText)
                        .accessibilityLabel(accessibilityPrefix + "列表：" + summaryText)
                }
                Spacer()
                Button("添加应用…") { pickerOpen = true }
                    .controlSize(.small)
                    .accessibilityLabel("添加" + accessibilityPrefix + "应用")
            }
            rows
        }
        .sheet(isPresented: $pickerOpen) {
            AppPickerSheet(catalog: catalog, mode: mode, title: addSheetTitle)
        }
    }

    private var summaryText: String {
        switch mode {
        case .defaultEnglish(let entries):
            let list = entries.wrappedValue
            let on = list.filter(\.enabled).count
            return list.isEmpty ? "0 个应用" : "\(list.count) 个应用 · \(on) 个启用"
        case .excluded(let ids):
            return "\(ids.wrappedValue.count) 个应用已排除"
        }
    }

    @ViewBuilder private var rows: some View {
        switch mode {
        case .defaultEnglish(let entries):
            let list = entries.wrappedValue
            if list.isEmpty {
                emptyView
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(list.indices, id: \.self) { index in
                        let item = list[index]
                        rowView(id: item.id, name: catalog.entry(for: item.id)?.name,
                                icon: catalog.entry(for: item.id)?.icon, enabled: item.enabled) { newValue in
                            entries.wrappedValue[index].enabled = newValue
                        } onRemove: {
                            entries.wrappedValue.remove(at: index)
                        }
                        if index < list.count - 1 { SettingsRowDivider() }
                    }
                }
            }
        case .excluded(let ids):
            let list = ids.wrappedValue.sorted()
            if list.isEmpty {
                emptyView
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(list, id: \.self) { id in
                        rowView(id: id, name: catalog.entry(for: id)?.name,
                                icon: catalog.entry(for: id)?.icon, enabled: nil,
                                onToggle: nil) {
                            ids.wrappedValue.remove(id)
                        }
                        if id != list.last { SettingsRowDivider() }
                    }
                }
            }
        }
    }

    /// 单行（.approw：图标 32×32 圆角 8＋名称 13；垂直内边距 7）；
    /// 未安装或无法解析的应用保留记录并使用通用图标，
    /// 只有缺少名称时才用标识作回退。
    @ViewBuilder private func rowView(id: String, name: String?, icon: NSImage?,
                                      enabled: Bool?, onToggle: ((Bool) -> Void)?, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(SettingsPalette.secondaryText)
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(name ?? id).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SettingsPalette.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if name == nil {
                    Text("未安装或无法解析").font(.system(size: 10))
                        .foregroundStyle(SettingsPalette.tertiaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let enabled, let onToggle {
                Toggle("", isOn: Binding(get: { enabled }, set: onToggle))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .accessibilityLabel((name ?? id) + "切入时默认英文")
            }
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SettingsPalette.tertiaryText)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("移除" + (name ?? id))
        }
        .padding(.vertical, 7)
    }

    /// 空状态（.appempty：虚线框、radius 8、11.5 次级色）。
    private var emptyView: some View {
        Text(emptyText).font(.system(size: 11.5))
            .foregroundStyle(SettingsPalette.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(SettingsPalette.borderStrong,
                                  style: StrokeStyle(lineWidth: 1, dash: [4])))
    }
}

/// 可搜索添加弹层：搜索名称或 bundle id；点一项即添加，可连续操作；
/// 支持文件选择器添加其他位置的 .app。行样式对应原型 .addrow
/// （图标 28×28＋名称＋bundle id 等宽小字＋右侧状态文字）。
struct AppPickerSheet: View {
    let catalog: AppCatalog
    let mode: AppListEditor.Mode
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var pickError = ""

    /// 排除类列表的状态文案与「按应用默认英文」不同（原型一致）。
    private var actionWord: String { isExcluded ? "排除" : "添加" }
    private var doneWord: String { isExcluded ? "已排除" : "已添加" }
    private var isExcluded: Bool {
        switch mode {
        case .defaultEnglish: return false
        case .excluded: return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // .appmodal__head：标题＋计数。
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SettingsPalette.primaryText)
                Spacer()
                Text("\(doneWord) \(addedCount)/\(catalog.entries.count)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(SettingsPalette.tertiaryText)
            }
            SettingsSearchField(text: $query, placeholder: "搜索应用名或 bundle id",
                                accessibilityName: "搜索应用")
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if filtered.isEmpty {
                        Text("没有匹配的应用。").font(.system(size: 12))
                            .foregroundStyle(SettingsPalette.secondaryText)
                            .padding(.vertical, 20)
                    }
                    ForEach(filtered) { entry in
                        addButton(entry)
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(minHeight: 260, maxHeight: 340)
            if !pickError.isEmpty {
                Text(pickError).font(.system(size: 11)).foregroundStyle(SettingsPalette.danger)
            }
            // .appmodal__foot：提示文字与「完成」。
            HStack {
                Button("选择其他位置的 .app…") {
                    if catalog.pickViaPanel() == nil {
                        pickError = "未能读取所选应用的 bundle id。"
                    } else {
                        pickError = ""
                    }
                }
                .controlSize(.small)
                Spacer()
                Text("点一项即\(actionWord)，可连续操作")
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsPalette.secondaryText)
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.small)
                    .accessibilityLabel("完成添加应用")
            }
        }
        .padding(18)
        .frame(width: 460)
    }

    private var addedCount: Int {
        switch mode {
        case .defaultEnglish(let entries): return entries.wrappedValue.count
        case .excluded(let ids): return ids.wrappedValue.count
        }
    }

    private func isAdded(_ id: String) -> Bool {
        switch mode {
        case .defaultEnglish(let entries): return entries.wrappedValue.contains { $0.id == id }
        case .excluded(let ids): return ids.wrappedValue.contains(id)
        }
    }

    private func add(_ id: String) {
        switch mode {
        case .defaultEnglish(let entries):
            if !entries.wrappedValue.contains(where: { $0.id == id }) {
                entries.wrappedValue.append(EnglishAppEntry(id: id, enabled: true))
            }
        case .excluded(let ids):
            ids.wrappedValue.insert(id)
        }
    }

    private var filtered: [AppCatalog.Entry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return catalog.entries }
        return catalog.entries.filter { $0.name.lowercased().contains(q) || $0.id.lowercased().contains(q) }
    }

    /// 添加行（.addrow：图标 28×28 圆角 7＋名称＋bundle id＋状态文字）。
    @ViewBuilder private func addButton(_ entry: AppCatalog.Entry) -> some View {
        let added = isAdded(entry.id)
        Button {
            add(entry.id)
        } label: {
            HStack(spacing: 10) {
                Image(nsImage: entry.icon ?? NSImage()).resizable().interpolation(.high)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name).font(.system(size: 12.5))
                        .foregroundStyle(SettingsPalette.primaryText)
                        .lineLimit(1)
                    Text(entry.id).font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(SettingsPalette.secondaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(added ? doneWord : actionWord)
                    .font(.system(size: 11))
                    .foregroundStyle(added ? SettingsPalette.tertiaryText : SettingsPalette.accentText)
                    .padding(.horizontal, 8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(added)
        .padding(.vertical, 5)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityLabel((added ? doneWord + " " : actionWord + " ") + entry.name)
    }
}
