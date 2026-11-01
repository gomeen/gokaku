import SwiftUI
import GogakuCore
import CGogakuCore

/// 普通输入设置页：输入方案、模糊音、候选字号、英文释义、输入区字母、调频、
/// 按应用默认英文与快速添加排除应用。设置变更经 settings.save() 通知输入法热更新。
struct NormalInputPage: View {
    @Binding var settings: GogakuCore.Settings
    @Binding var message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("输入方案") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("方案", selection: $settings.inputScheme) {
                        Text("小鹤双拼（默认）").tag(InputScheme.xiaohe)
                        Text("全拼").tag(InputScheme.fullPinyin)
                    }
                    .pickerStyle(.radioGroup).labelsHidden()
                    .onChange(of: settings.inputScheme) { _, _ in save() }
                    Text("两种方案共用调频数据；切换立即生效。")
                        .foregroundStyle(.secondary).font(.callout)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("模糊音（默认全关）").font(.callout.weight(.medium))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96))], alignment: .leading) {
                            ForEach(InputScheme.fuzzyPairs, id: \.id) { pair in
                                Toggle(pair.id, isOn: Binding(
                                    get: { settings.fuzzyPinyin.contains(pair.id) },
                                    set: { on in
                                        if on { settings.fuzzyPinyin.insert(pair.id) } else { settings.fuzzyPinyin.remove(pair.id) }
                                        save()
                                    }))
                            }
                        }
                    }
                }
                .padding(8)
            }

            GroupBox("候选窗与输入区") {
                VStack(alignment: .leading, spacing: 10) {
                    Stepper(value: Binding(get: { settings.candidateFontSize }, set: { settings.candidateFontSize = $0; save() }), in: 12...16) {
                        Text("候选字号：\(settings.candidateFontSize) 号（注释 −1，序号 −3，12–16）")
                    }
                    Toggle("候选旁英文释义（词性＋译文；无合格词性数据时只显示译文）", isOn: $settings.glossEnabled)
                        .onChange(of: settings.glossEnabled) { _, _ in save() }
                    Toggle("在宿主正文显示输入的字母（下划线）", isOn: $settings.inputLettersEnabled)
                        .onChange(of: settings.inputLettersEnabled) { _, _ in save() }
                    Picker("显示内容", selection: $settings.fullPinyinPreedit) {
                        Text("展开全拼（ni'hao）").tag(true)
                        Text("原始编码（nihc）").tag(false)
                    }
                    .pickerStyle(.radioGroup)
                    .padding(.leading, 20)
                    .onChange(of: settings.fullPinyinPreedit) { _, _ in save() }
                }
                .padding(8)
            }

            GroupBox("中文模式下的英文候选与调频") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("给英文候选（词表＋词频；SCOWL／wordfreq 数据包就绪后生效）", isOn: $settings.englishCandidatesEnabled)
                        .onChange(of: settings.englishCandidatesEnabled) { _, _ in save() }
                    Toggle("本地中文调频（只学习普通模式完整上屏的中文）", isOn: $settings.frequencyEnabled)
                        .onChange(of: settings.frequencyEnabled) { _, _ in save() }
                    HStack {
                        Button("清空调频数据") {
                            let dir = Settings.chineseDirectory
                            try? FileManager.default.removeItem(at: dir)
                            message = "已清空调频数据；自定义词语不受影响。输入法下次重载后生效。"
                        }
                        Text("数据存 ~/Library/Application Support/Gogaku/chinese/，30 秒防抖、原子写入。")
                            .foregroundStyle(.secondary).font(.callout)
                    }
                }
                .padding(8)
            }

            GroupBox("按应用默认英文") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("这些应用切入时为临时英文；手动 Shift 可覆盖，Esc 回到默认。每行一个 bundle id：")
                        .foregroundStyle(.secondary).font(.callout)
                    TextEditor(text: Binding(
                        get: { settings.appDefaultEnglish.joined(separator: "\n") },
                        set: { settings.appDefaultEnglish = $0.split(whereSeparator: \.isNewline).map(String.init); save() }))
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 88)
                }
                .padding(8)
            }

            GroupBox("快速添加（Control＋Shift＋A 可改）") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("快捷键：Control＋Shift＋")
                        TextField("a", text: Binding(
                            get: { settings.quickAddShortcut.key },
                            set: { settings.quickAddShortcut.key = String($0.prefix(1)).lowercased(); save() }))
                            .frame(width: 40)
                    }
                    Text("把当前应用、当前输入框 60 秒内最近一次完整上屏的中文候选连同实际拼音加为拼音词；排除应用中不生效。每行一个 bundle id：")
                        .foregroundStyle(.secondary).font(.callout)
                    TextEditor(text: Binding(
                        get: { settings.quickAddExcludedApplications.sorted().joined(separator: "\n") },
                        set: { settings.quickAddExcludedApplications = Set($0.split(whereSeparator: \.isNewline).map(String.init)); save() }))
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 64)
                }
                .padding(8)
            }

            if !message.isEmpty {
                Text(message).foregroundStyle(.secondary).font(.callout)
            }
        }
    }

    private func save() {
        let value = settings
        DispatchQueue.global(qos: .utility).async {
            try? value.save()   // 发布 settings.changed，输入法热更新
        }
    }
}

/// 自定义词语页：短码短语与拼音词两个列表，支持新增／编辑／删除／启用／排序／自动读音。
struct CustomWordsPage: View {
    enum Kind: Int32, CaseIterable, Identifiable {
        case shortcode = 0, pinyin = 1
        var id: Int32 { rawValue }
        var title: String { self == .shortcode ? "短码短语" : "拼音词" }
    }

    @Binding var message: String
    @State private var words: [CustomWord] = []
    @State private var corrupt = false
    @State private var editing: CustomWord?
    @State private var showSheet = false
    @State private var saveError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if corrupt {
                Label("custom-words.tsv 已损坏，已备份为 .corrupt 并按空表启动；确认下方内容后保存即可恢复。",
                      systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            ForEach([Kind.shortcode, .pinyin]) { kind in
                GroupBox(kind.title) {
                    VStack(alignment: .leading, spacing: 8) {
                        if kind == .pinyin {
                            Text("内容 1–16 个汉字；读音为每字一个规范全拼音节（如 hui'yi）。两种方案通用，模糊音生效，作为高权重词参与组句。")
                                .foregroundStyle(.secondary).font(.callout)
                        } else {
                            Text("编码 1–32 个小写字母；内容任意纯文本（可含空格、换行），最多 512 个字符，原样上屏；与输入方案无关，完整匹配时置顶。")
                                .foregroundStyle(.secondary).font(.callout)
                        }
                        ForEach(Array(currentWords(kind).enumerated()), id: \.offset) { pair in
                            let index = globalIndex(kind, pair.offset)
                            HStack {
                                Toggle("", isOn: Binding(
                                    get: { words[index].enabled },
                                    set: { words[index].enabled = $0; save() }))
                                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(displayTitle(words[index])).font(.callout.weight(.medium))
                                    Text(displaySubtitle(words[index])).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("上") { move(index, -1) }.controlSize(.small)
                                Button("下") { move(index, 1) }.controlSize(.small)
                                Button("编辑") { editing = words[index]; showSheet = true }.controlSize(.small)
                                Button("删除") { words.remove(at: index); save() }.controlSize(.small)
                            }
                        }
                        if currentWords(kind).isEmpty {
                            Text("暂无\(kind.title)。").foregroundStyle(.secondary).font(.callout)
                        }
                        HStack {
                            Button("新增\(kind.title)") {
                                editing = CustomWord(kind: Int32(kind.rawValue), enabled: true, code: "", pinyin: "", content: "")
                                showSheet = true
                            }
                            if corrupt { Button("确认内容并恢复文件") { save() } }
                        }
                    }
                    .padding(8)
                }
            }
            if !message.isEmpty {
                Text(message).foregroundStyle(.secondary).font(.callout)
            }
        }
        .onAppear { load() }
        .sheet(isPresented: $showSheet) {
            WordEditSheet(original: editing) { result in
                if let word = result {
                    if let original = editing, let existing = words.firstIndex(of: original) {
                        words[existing] = word
                    } else {
                        words.append(word)
                    }
                    save()
                }
                showSheet = false
            }
        }
    }

    private func currentWords(_ kind: Kind) -> [CustomWord] { words.filter { $0.kind == kind.rawValue } }
    private func globalIndex(_ kind: Kind, _ withinKind: Int) -> Int {
        var seen = -1
        for (i, w) in words.enumerated() where w.kind == kind.rawValue {
            seen += 1
            if seen == withinKind { return i }
        }
        return 0
    }
    private func move(_ index: Int, _ delta: Int) {
        let target = index + delta
        guard words.indices.contains(index), words.indices.contains(target), words[target].kind == words[index].kind else { return }
        words.swapAt(index, target)
        save()
    }
    private func displayTitle(_ w: CustomWord) -> String {
        w.kind == Int32(GC_WORD_SHORTCODE) ? w.code : w.content
    }
    private func displaySubtitle(_ w: CustomWord) -> String {
        w.kind == Int32(GC_WORD_SHORTCODE) ? w.content.replacingOccurrences(of: "\n", with: " ⏎ ") : w.pinyin
    }
    private func load() {
        let path = Settings.customWordsPath.path
        let result = CustomWordStore.readRecoveringCorrupt(path: path)
        words = result.words
        corrupt = result.corrupt
    }
    private func save() {
        let path = Settings.customWordsPath.path
        if CustomWordStore.write(path: path, words: words) {
            corrupt = false
            message = "已保存；1 秒内在输入法中生效。"
            let value = settings_snapshot()
            DispatchQueue.global(qos: .utility).async { try? value.save() }   // 通知输入法重载
        } else {
            saveError = true
            message = "保存失败：目录不可写或权限不足。"
        }
    }
    private func settings_snapshot() -> GogakuCore.Settings { GogakuCore.Settings.load() }
}

/// 词条编辑表单：校验非法编码、音节与超长内容并给出具体原因；拼音词支持自动读音。
struct WordEditSheet: View {
    let original: CustomWord?
    let onDone: (CustomWord?) -> Void
    @State private var draft = CustomWord(kind: Int32(GC_WORD_SHORTCODE), enabled: true, code: "", pinyin: "", content: "")
    @State private var error: String?
    @State private var autoLoading = false

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
                        let dict = engineDictPath()
                        DispatchQueue.global(qos: .userInitiated).async {
                            let pinyin = CustomWordStore.autoPinyin(dictPath: dict, hanzi: hanzi)
                            DispatchQueue.main.async {
                                if let pinyin { draft.pinyin = pinyin } else {
                                    error = "自动读音失败：词典中缺少某字的常用读音，可逐字手填。"
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
        .onAppear { if let original { draft = original } }
    }

    private func engineDictPath() -> String {
        if let env = ProcessInfo.processInfo.environment["GOGAKU_ENGINE_DATA"] {
            return env + "/sc.dict"
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Gogaku/libime-1.1.17/data/sc.dict").path
    }
}
