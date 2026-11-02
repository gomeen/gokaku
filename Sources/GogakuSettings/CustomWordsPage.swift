import SwiftUI
import GogakuCore
import CGogakuCore

/// 自定义词语页（2026-11-03 定稿）：保留原生管理（增删改、启停、排序、自动读音、
/// 校验），顶部「短码短语／拼音词」分段＋搜索框＋新增按钮；单行紧凑列表，
/// 长内容省略；编辑／删除／上移／下移放在选中行工具栏与右键菜单，不给每条
/// 词语常驻四个按钮；双击打开既有编辑表单（保存／取消）。
struct CustomWordsPage: View {
    enum Kind: Int32, CaseIterable, Identifiable {
        case shortcode = 0, pinyin = 1
        var id: Int32 { rawValue }
        var title: String { self == .shortcode ? "短码短语" : "拼音词" }
    }

    private struct WordEditRequest: Identifiable {
        let id = UUID()
        let word: CustomWord
        let storageIndex: Int?
    }

    @Binding var status: SaveStatus
    @State private var model = CustomWordListModel(words: [])
    @State private var corrupt = false
    @State private var kind: Kind = .shortcode
    @State private var search = ""
    @State private var selectedRowID: String?
    @State private var editing: WordEditRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if corrupt {
                Label("custom-words.tsv 已损坏，已备份为 .corrupt 并按空表启动；确认下方内容后保存即可恢复。",
                      systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            HStack(spacing: 12) {
                Picker("词语类型", selection: $kind) {
                    Text("短码短语").tag(Kind.shortcode)
                    Text("拼音词").tag(Kind.pinyin)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .accessibilityLabel("自定义词语类型")
                SettingsSearchField(text: $search, placeholder: "搜索内容、编码或读音",
                                    accessibilityName: "搜索自定义词语")
                    .frame(maxWidth: 300)
                Spacer()
                Button("新增\(kind.title)") {
                    editing = WordEditRequest(
                        word: CustomWord(kind: kind.rawValue, enabled: true, code: "", pinyin: "", content: ""),
                        storageIndex: nil)
                }
                .accessibilityLabel("新增\(kind.title)")
            }
            toolbar
            list
        }
        .onAppear { load() }
        .sheet(item: $editing) { request in
            WordEditSheet(original: request.word) { result in
                if let word = result {
                    if let index = request.storageIndex {
                        model.update(storageIndex: index, word: word)
                    } else {
                        model.append(word: word)
                    }
                    save()
                }
                editing = nil
            }
        }
    }

    private var searching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }
    private var rows: [CustomWordListModel.Row] { model.rows(kind: kind.rawValue, search: search) }
    private var selectedRow: CustomWordListModel.Row? {
        rows.first { $0.id == selectedRowID }
    }

    @ViewBuilder private var toolbar: some View {
        HStack(spacing: 10) {
            Text("\(kind.title) · \(rows.count) 条").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button("编辑") { if let row = selectedRow { editing = WordEditRequest(word: row.word, storageIndex: row.storageIndex) } }
                .controlSize(.small).disabled(selectedRow == nil)
                .accessibilityLabel("编辑选中词语")
            Button("删除") { if let row = selectedRow { model.remove(at: row.storageIndex); selectedRowID = nil; save() } }
                .controlSize(.small).disabled(selectedRow == nil)
                .accessibilityLabel("删除选中词语")
            Button("上移") { if let row = selectedRow { model.move(storageIndex: row.storageIndex, delta: -1, searching: searching); save() } }
                .controlSize(.small).disabled(!canMove(-1))
                .accessibilityLabel("上移选中词语")
            Button("下移") { if let row = selectedRow { model.move(storageIndex: row.storageIndex, delta: 1, searching: searching); save() } }
                .controlSize(.small).disabled(!canMove(1))
                .accessibilityLabel("下移选中词语")
            if corrupt {
                Button("确认内容并恢复文件") { save() }.controlSize(.small)
            }
        }
    }

    private func canMove(_ delta: Int) -> Bool {
        guard let row = selectedRow else { return false }
        return model.canMove(storageIndex: row.storageIndex, delta: delta, searching: searching)
    }

    @ViewBuilder private var list: some View {
        let currentRows = rows
        if currentRows.isEmpty {
            Text(search.isEmpty ? "暂无\(kind.title)。" : "没有匹配的\(kind.title)。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(currentRows.enumerated()), id: \.element.id) { index, row in
                        wordRow(row, isFirst: index == 0, isLast: index == currentRows.count - 1)
                        if index < currentRows.count - 1 { Divider().opacity(0.35) }
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: SettingsPalette.cardCornerRadius))
                .overlay(RoundedRectangle(cornerRadius: SettingsPalette.cardCornerRadius)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            }
        }
    }

    /// 单行：启用开关＋内容＋编码／读音（长内容省略）。
    private func wordRow(_ row: CustomWordListModel.Row, isFirst: Bool, isLast: Bool) -> some View {
        let word = row.word
        let title = word.kind == Int32(GC_WORD_SHORTCODE) ? word.code : word.content
        let subtitle = word.kind == Int32(GC_WORD_SHORTCODE)
            ? word.content.replacingOccurrences(of: "\n", with: " ⏎ ")
            : word.pinyin
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { model.words.indices.contains(row.storageIndex) && model.words[row.storageIndex].enabled },
                set: { newValue in
                    model.update(storageIndex: row.storageIndex, word: CustomWord(
                        kind: word.kind, enabled: newValue, code: word.code, pinyin: word.pinyin, content: word.content))
                    save()
                }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .accessibilityLabel("启用\(title)")
            VStack(alignment: .leading, spacing: 2) {
                Text(title.isEmpty ? "（空）" : title).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                Text(subtitle.isEmpty ? "—" : subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if searching {
                Text("搜索结果").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(selectedRowID == row.id ? SettingsPalette.accentSoft : Color.clear)
        .onTapGesture { selectedRowID = row.id }
        .onTapGesture(count: 2) {
            editing = WordEditRequest(word: word, storageIndex: row.storageIndex)
        }
        .contextMenu {
            Button("编辑") { editing = WordEditRequest(word: word, storageIndex: row.storageIndex) }
            Button("删除") { model.remove(at: row.storageIndex); if selectedRowID == row.id { selectedRowID = nil }; save() }
            Button("上移") { model.move(storageIndex: row.storageIndex, delta: -1, searching: searching); save() }
                .disabled(!model.canMove(storageIndex: row.storageIndex, delta: -1, searching: searching))
            Button("下移") { model.move(storageIndex: row.storageIndex, delta: 1, searching: searching); save() }
                .disabled(!model.canMove(storageIndex: row.storageIndex, delta: 1, searching: searching))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(word.kind == Int32(GC_WORD_SHORTCODE) ? "短码短语" : "拼音词") \(title)，\(subtitle)，\(word.enabled ? "已启用" : "已停用")")
    }

    private func load() {
        let result = CustomWordStore.readRecoveringCorrupt(path: Settings.customWordsPath.path)
        model = CustomWordListModel(words: result.words)
        corrupt = result.corrupt
        selectedRowID = nil
    }

    /// 写入 TSV v1（不迁移、不丢失词条）；成功后直接通知输入法重载
    /// （不再「为发通知再保存整份 settings.json」）；失败保留界面改动并提示。
    private func save() {
        if CustomWordStore.write(path: Settings.customWordsPath.path, words: model.words) {
            corrupt = false
            status = .saved
            DistributedNotificationCenter.default().postNotificationName(
                SettingsStore.changedNotification, object: nil, userInfo: nil, deliverImmediately: true)
        } else {
            status = .failed("自定义词语写入失败")
        }
    }
}

/// 词条编辑表单：校验非法编码、音节与超长内容并给出具体原因；拼音词支持自动读音。
/// 完整内容只在表单内显示；保留「保存／取消」，不把未完成词条写入词表。
struct WordEditSheet: View {
    let onDone: (CustomWord?) -> Void
    @State private var draft: CustomWord
    @State private var error: String?
    @State private var autoLoading = false

    init(original: CustomWord, onDone: @escaping (CustomWord?) -> Void) {
        self.onDone = onDone
        _draft = State(initialValue: original)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.kind == Int32(GC_WORD_SHORTCODE) ? "编辑短码短语" : "编辑拼音词")
                .font(.headline)
            if draft.kind == GC_WORD_SHORTCODE {
                TextField("编码（小写字母，1–32 个）", text: $draft.code)
                TextField("内容（原样上屏，可含空格换行，≤512 字符）", text: $draft.content, axis: .vertical)
                    .lineLimit(3...5)
            } else {
                TextField("内容（1–16 个汉字）", text: $draft.content)
                HStack {
                    TextField("读音（如 hui'yi，每字一个音节）", text: $draft.pinyin)
                    Button("自动读音") {
                        autoLoading = true
                        let hanzi = draft.content
                        let dict = Paths.engineData.appendingPathComponent("sc.dict").path
                        DispatchQueue.global(qos: .userInitiated).async {
                            let pinyin = CustomWordStore.autoPinyin(dictPath: dict, hanzi: hanzi)
                            DispatchQueue.main.async {
                                if let pinyin {
                                    draft.pinyin = pinyin
                                    error = nil
                                } else {
                                    error = "自动读音失败：词典不可用或某字没有可用读音，可逐字手填。"
                                }
                                autoLoading = false
                            }
                        }
                    }
                    .disabled(draft.content.isEmpty || autoLoading)
                }
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("取消") { onDone(nil) }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    if let problem = CustomWordStore.validate(kind: draft.kind, code: draft.code, pinyin: draft.pinyin, content: draft.content) {
                        error = problem
                    } else {
                        onDone(draft)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
