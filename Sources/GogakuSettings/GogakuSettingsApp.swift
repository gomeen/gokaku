import SwiftUI
import GogakuCore

/// 包内构建身份（Contents/Resources/build-identity.json）。
/// 设置页与诊断输出展示完整预发布版本；缺失时回退 Info.plist 三段版本。
enum BuildIdentity {
    static let displayVersion: String = {
        let bundle = Bundle.main
        guard let url = bundle.url(forResource: "build-identity", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let full = object["fullVersion"] as? String else {
            let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
            let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
            return "\(short)（构建 \(build)，无身份记录）"
        }
        let build = object["buildNumber"] as? Int ?? 0
        let dirty = (object["dirty"] as? Bool ?? false) ? " dirty" : ""
        return "\(full) 构建\(build)\(dirty)"
    }()
}

@main struct GogakuSettingsApp: App {
    var body: some Scene {
        Window("Gogaku 设置", id: "settings") {
            SettingsView().frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 900, height: 620)
    }
}

private enum SettingsPage: String, CaseIterable, Identifiable {
    case resources, normalInput, customWords, shortcuts, privacy, records
    var id: Self { self }
    var title: String {
        switch self {
        case .resources: return "语言资源"
        case .normalInput: return "普通输入"
        case .customWords: return "自定义词语"
        case .shortcuts: return "快捷键"
        case .privacy: return "学习与隐私"
        case .records: return "学习片段"
        }
    }
    var symbol: String {
        switch self {
        case .resources: return "character.book.closed"
        case .normalInput: return "keyboard"
        case .customWords: return "text.badge.plus"
        case .shortcuts: return "command"
        case .privacy: return "hand.raised"
        case .records: return "text.book.closed"
        }
    }
}

/// 设置外壳：200pt 侧栏、六页、内容滚动区、固定底部状态栏。
/// 立即保存：普通选项／应用列表／快捷键改动立即提交，连续文本输入合并 300ms，
/// 失焦或关闭窗口时提交剩余有效改动；保存状态由 SettingsStore 回调驱动。
private struct SettingsView: View {
    @State private var page: SettingsPage = .normalInput
    @State private var settings = Settings.load()
    @State private var status: SaveStatus = .idle
    @State private var records: [LearningEvent] = []
    private let store = LearningStore()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                // 页面只保留标题，无副标题与重复说明。
                Text(page.title).font(.system(size: 22, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 28)
                    .padding(.top, 26)
                    .padding(.bottom, 18)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        switch page {
                        case .resources: ResourcesPage()
                        case .normalInput: NormalInputPage(settings: $settings)
                        case .customWords: CustomWordsPage(status: $status)
                        case .shortcuts: ShortcutsPage(settings: $settings)
                        case .privacy: PrivacyPage(settings: $settings)
                        case .records: RecordsPage(records: $records) { refreshRecords() }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
                }
                .id(page)
                statusBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .font(.system(size: 13))
        .tint(SettingsPalette.accent)
        .onAppear {
            SettingsStore.shared.onStatus = { newStatus in
                status = SaveStatus(storeStatus: newStatus)
                if case .saved = newStatus {
                    // 输入法收到通知重载后，同步一份最新值避免界面显示旧缓存。
                    settings = Settings.load()
                }
            }
            refreshRecords()
        }
        .onChange(of: page) { _, newValue in
            if newValue == .records { refreshRecords() }
        }
        .onDisappear {
            // 关闭窗口／视图销毁时提交剩余有效改动（如 300ms 合并中的文本）。
            SettingsStore.shared.flushPending()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Gogaku")
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 18)
                .padding(.top, 22)
            List(SettingsPage.allCases, selection: $page) { item in
                Label(item.title, systemImage: item.symbol)
                    .padding(.vertical, 4)
                    .tag(item)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            Text("本机开发版")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
            Text(BuildIdentity.displayVersion)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
        }
        .frame(width: 200)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// 固定底部状态栏：保存中／已保存／失败及重试。失败不伪报成功，不无限重试。
    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle().fill(Color(nsColor: status.tone))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(status.text.isEmpty ? "改动立即保存" : status.text)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .accessibilityLabel("保存状态：\(status.text.isEmpty ? "无待保存改动" : status.text)")
            if case .failed = status {
                Button("重试") {
                    SettingsStore.shared.retry()
                    status = .saving
                }
                .controlSize(.small)
                .accessibilityLabel("重试保存")
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.98))
        .overlay(Divider().opacity(0.5), alignment: .top)
    }

    private func refreshRecords() {
        store.list { result in DispatchQueue.main.async {
            switch result {
            case .success(let items): records = items
            case .failure: break   // 片段读取失败只在片段页展示；不影响输入。
            }
        } }
    }
}

// MARK: - 语言资源页（不提供 Apple Translation 查询与安装入口）

private struct ResourcesPage: View {
    @State private var bundled: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard("随包语言资源") {
                VStack(alignment: .leading, spacing: 8) {
                    if bundled.isEmpty {
                        Text("正在读取随包资源…").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    ForEach(bundled, id: \.self) { line in
                        Text(line).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    }
                    Text("以上为实际随包数据。资源缺失时普通输入自动降级，不影响已安装词库。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            SettingsCard("功能状态") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("普通输入：已在本机开发范围验证，完整宿主与性能验收仍在进行。",
                          systemImage: "keyboard").font(.system(size: 12))
                    Label("学习功能尚未开放：正式翻译模型未过质量门槛；菜单保持置灰。",
                          systemImage: "book.closed").font(.system(size: 12)).foregroundStyle(.secondary)
                    Label("本页不提供系统语言资源安装入口；翻译模型质量与安装流程另行验收。",
                          systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { loadBundled() }
    }

    private func loadBundled() {
        let data = Paths.engineData
        let names = ["sc.dict", "zh_CN.lm", "english-words.txt", "gloss.tsv"]
        bundled = names.map { name in
            let url = data.appendingPathComponent(name)
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey]), let size = values.fileSize {
                return "\(name) · \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))"
            }
            return "\(name) · 未随包提供"
        }
    }
}

// MARK: - 学习与隐私页

private struct PrivacyPage: View {
    @Binding var settings: GogakuCore.Settings
    @State private var ignored = ""
    @ObservedObject private var catalog = AppCatalog()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard("学习记录") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("记录学习片段（仅保留已确认成功的学习片段，30 天后过期）",
                           isOn: Binding(get: { settings.recording },
                                         set: { settings.recording = $0; submit() }))
                        .font(.system(size: 13))
                        .accessibilityLabel("记录学习片段，保留30天")
                    Text("当前开发版尚未接通成功提交后的记录；此开关只保存偏好，不解除真实学习记录门禁，也不会开始采集。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            SettingsCard("排除应用（不保存学习记录）") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("这些应用的输入不保存学习记录；与「普通输入」页的快速添加排除相互独立。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    AppListEditor(mode: .excluded(ids: Binding(
                        get: { settings.excludedApplications },
                        set: { settings.excludedApplications = $0; submit() })),
                        emptyText: "尚未排除任何应用。",
                        addSheetTitle: "添加不记录学习内容的应用",
                        accessibilityPrefix: "学习记录排除",
                        catalog: catalog)
                }
            }
            SettingsCard("英语忽略词") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("每行一个词，适合姓名、品牌或无需拼写提示的表达。连续输入合并保存。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    TextEditor(text: Binding(
                        get: { ignored },
                        set: { newValue in
                            ignored = newValue
                            applyIgnored()
                        }))
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 96)
                        .accessibilityLabel("英语忽略词，每行一个")
                }
            }
        }
        .onAppear { ignored = settings.ignoredWords.sorted().joined(separator: "\n") }
    }

    /// 连续文本输入合并 300ms 后提交（SettingsStore 内部去抖）。
    private func applyIgnored() {
        settings.ignoredWords = Set(ignored.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty })
        submit(coalesce: true)
    }

    private func submit(coalesce: Bool = false) {
        SettingsStore.shared.submit(settings, coalesce: coalesce)
    }
}

// MARK: - 学习片段页（真实存储读取）

private struct RecordsPage: View {
    @Binding var records: [LearningEvent]
    let onRefresh: () -> Void
    private let store = LearningStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("最近的片段").font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("刷新", action: onRefresh).accessibilityLabel("刷新学习片段")
            }
            if records.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "text.book.closed").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text("暂无学习片段").font(.system(size: 15, weight: .medium))
                    Text("已确认成功的学习内容会显示在这里。学习功能尚未开放。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(records) { event in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(event.source + " → " + event.target).textSelection(.enabled)
                            Text("\(event.direction == .zhToEn ? "中→英" : "英→中") · \(event.category) · \(event.createdAt.formatted())")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            HStack {
                                if !event.issues.isEmpty {
                                    Button("排除此条误报") { store.dismissIssues(id: event.id) { _ in onRefresh() } }
                                }
                                Spacer()
                                Button("删除片段") { store.delete(ids: [event.id]) { _ in onRefresh() } }
                            }
                        }
                        .padding(.vertical, 14)
                        Divider().opacity(0.45)
                    }
                }
            }
            Text("采用帮助不代表掌握；工具生成的错误不作为用户错误。最多显示 1000 条，可在「学习与隐私」中暂停记录或排除应用。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
