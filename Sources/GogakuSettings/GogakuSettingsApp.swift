import SwiftUI
import Translation
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
    var subtitle: String {
        switch self {
        case .resources: return "管理中文与英语的本地翻译资源。"
        case .normalInput: return "小鹤／全拼、模糊音、候选窗与英文候选。"
        case .customWords: return "短码短语与拼音词；保存后 1 秒内在输入法中生效。"
        case .shortcuts: return "在 Gogaku 输入源激活时切换模式与快速添加。"
        case .privacy: return "决定记录哪些学习内容，以及哪些输入无需提示。"
        case .records: return "回顾最近 30 天采用的表达与主动尝试。"
        }
    }
    var hasEditableSettings: Bool { self == .normalInput || self == .shortcuts || self == .privacy }
}

private struct SettingsView: View {
    @State private var page: SettingsPage = .resources
    @State private var settings = Settings.load()
    @State private var ignored = ""
    @State private var excluded = ""
    @State private var message = ""
    @State private var forwardStatus = "检查中"
    @State private var reverseStatus = "检查中"
    @State private var forwardInstalled = false
    @State private var reverseInstalled = false
    @State private var records: [LearningEvent] = []
    @State private var configuration: TranslationSession.Configuration?
    @State private var installing: Direction?
    @State private var modeKey = "k"
    @State private var directionKey = "j"
    @State private var modeModifiers: UInt = NSEvent.ModifierFlags([.control, .shift]).rawValue
    @State private var directionModifiers: UInt = NSEvent.ModifierFlags([.control, .shift]).rawValue
    private let store = LearningStore()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                pageHeader
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        switch page {
                        case .resources: resourcesPage
                        case .normalInput: NormalInputPage(settings: $settings, message: $message)
                        case .customWords: CustomWordsPage(message: $message)
                        case .shortcuts: shortcutsPage
                        case .privacy: privacyPage
                        case .records: recordsPage
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
                }
                .id(page)
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .font(.system(size: 13))
        .onAppear {
            ignored = settings.ignoredWords.sorted().joined(separator: "\n")
            excluded = settings.excludedApplications.sorted().joined(separator: "\n")
            modeKey = settings.modeShortcut.key; directionKey = settings.directionShortcut.key
            modeModifiers = settings.modeShortcut.modifiers; directionModifiers = settings.directionShortcut.modifiers
            refreshRecords()
        }
        .onChange(of: page) { _, value in
            message = ""
            if value == .records { refreshRecords() }
        }
        .task { await refreshResources() }
        .translationTask(configuration) { session in
            do {
                try await session.prepareTranslation()
                message = "资源准备已结束，请刷新状态。使用前仍需完成翻译验收。"
            } catch { message = "资源安装未完成，可以稍后重试。" }
            installing = nil
            await refreshResources()
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

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(page.title).font(.system(size: 22, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Text(page.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .padding(.bottom, 22)
    }

    @ViewBuilder private var footer: some View {
        if page.hasEditableSettings || !message.isEmpty {
            Divider().opacity(0.5)
            HStack(spacing: 14) {
                Text(message.isEmpty ? "修改后保存，即可用于之后的输入。" : message)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if page.hasEditableSettings {
                    Button("保存设置", action: save).buttonStyle(.borderedProminent)
                        .accessibilityLabel("保存设置")
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
        }
    }

    private func sectionTitle(_ title: String, lead: String = "") -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
            if !lead.isEmpty {
                Text(lead).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var sectionDivider: some View { Divider().opacity(0.45).padding(.vertical, 16) }

    private func settingRow<Control: View>(_ title: String, detail: String = "", @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .padding(.vertical, 14)
    }

    private var resourcesPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("本地翻译", lead: "语言资源由 macOS 管理，安装时会显示系统授权流程。")
            settingRow("中文 → 英语", detail: forwardStatus) {
                resourceButton(.zhToEn, installed: forwardInstalled)
            }
            settingRow("英语 → 中文", detail: reverseStatus) {
                resourceButton(.enToZh, installed: reverseInstalled)
            }
            HStack {
                Text("翻译策略：系统默认").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("刷新状态") { Task { await refreshResources() } }
                    .accessibilityLabel("刷新语言资源状态")
            }.padding(.top, 8)
            sectionDivider
            sectionTitle("开发版状态")
            Text("普通输入与真实宿主仍在验收。学习辅助和学习记录尚未启用。")
                .fixedSize(horizontal: false, vertical: true).padding(.vertical, 8)
            Text("资源安装后，还需完成双向质量、离线和性能验收。系统资源更新后，原有结论也需复核。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func resourceButton(_ direction: Direction, installed: Bool) -> some View {
        Button(installed ? "已安装" : (installing == direction ? "正在准备…" : "安装资源")) { install(direction) }
            .frame(width: 96)
            .disabled(installed || installing != nil)
            .accessibilityLabel(direction == .zhToEn ? "安装中文到英语资源" : "安装英语到中文资源")
    }

    private var shortcutsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("模式切换", lead: "菜单中也可执行相同操作。每个应用会记住自己的模式与方向。")
            settingRow("普通／学习", detail: "切换中文输入与语言学习模式") {
                shortcutControl(key: $modeKey, modifiers: $modeModifiers, label: "普通与学习切换")
            }
            settingRow("学习方向", detail: "切换中文到英语、英语到中文") {
                shortcutControl(key: $directionKey, modifiers: $directionModifiers, label: "学习方向切换")
            }
            sectionDivider
            sectionTitle("组合中的操作")
            settingRow("原文上屏", detail: "有学习组合时明确提交原文") {
                Text("⌘ Return").foregroundStyle(.secondary)
            }
            settingRow("取消组合", detail: "取消当前输入，不提交到宿主") {
                Text("Esc").foregroundStyle(.secondary)
            }
        }
    }

    private func shortcutControl(key: Binding<String>, modifiers: Binding<UInt>, label: String) -> some View {
        HStack(spacing: 8) {
            Picker("修饰键", selection: modifiers) {
                Text("Control＋Shift").tag(NSEvent.ModifierFlags([.control, .shift]).rawValue)
                Text("Control＋Option").tag(NSEvent.ModifierFlags([.control, .option]).rawValue)
                Text("Command＋Shift").tag(NSEvent.ModifierFlags([.command, .shift]).rawValue)
            }
            .labelsHidden().frame(width: 170).accessibilityLabel(label + "修饰键")
            TextField("字母", text: key).textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center).frame(width: 42).accessibilityLabel(label + "字母")
        }
        .frame(width: 220, alignment: .trailing)
    }

    private var privacyPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("学习记录", lead: "仅保留已确认成功的学习片段，30 天后过期。")
            settingRow("记录学习片段", detail: "普通输入、取消、预取和未采用的候选均不记录") {
                Toggle("记录学习片段", isOn: $settings.recording).labelsHidden().toggleStyle(.switch)
                    .accessibilityLabel("记录学习片段，保留30天")
            }
            Text("当前开发版尚未接通成功提交后的记录，开启此设置也不会开始采集。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            sectionDivider
            sectionTitle("排除应用", lead: "每行填写一个应用标识（bundle ID）。这些应用不保存学习记录。")
            TextField("例如 com.example.app", text: $excluded, axis: .vertical)
                .lineLimit(3...5).textFieldStyle(.roundedBorder).accessibilityLabel("排除应用，每行一个")
                .padding(.vertical, 8)
            sectionDivider
            sectionTitle("英语忽略词", lead: "每行一个词，适合姓名、品牌或无需拼写提示的表达。")
            TextField("每行一个忽略词", text: $ignored, axis: .vertical)
                .lineLimit(3...5).textFieldStyle(.roundedBorder).accessibilityLabel("英语忽略词，每行一个")
                .padding(.vertical, 8)
        }
    }

    private var recordsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                sectionTitle("最近的片段")
                Spacer()
                Button("刷新", action: refreshRecords).accessibilityLabel("刷新学习片段")
            }
            if records.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "text.book.closed").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text("暂无学习片段").font(.system(size: 15, weight: .medium))
                    Text("已确认成功的学习内容会显示在这里。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 230)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(records) { event in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(event.source + " → " + event.target).textSelection(.enabled)
                            Text("\(event.direction == .zhToEn ? "中→英" : "英→中") · \(event.category) · \(event.createdAt.formatted())")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            HStack {
                                if !event.issues.isEmpty {
                                    Button("排除此条误报") { store.dismissIssues(id: event.id) { _ in refreshRecords() } }
                                }
                                Spacer()
                                Button("删除片段") { store.delete(ids: [event.id]) { _ in refreshRecords() } }
                            }
                        }
                        .padding(.vertical, 14)
                        Divider().opacity(0.45)
                    }
                }
            }
            sectionDivider
            Text("采用帮助不代表掌握；工具生成的错误不作为用户错误。最多显示 1000 条，可在“学习与隐私”中暂停记录或排除应用。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func install(_ direction: Direction) {
        installing = direction
        let from = Locale.Language(identifier: direction == .zhToEn ? "zh-Hans" : "en")
        let to = Locale.Language(identifier: direction == .zhToEn ? "en" : "zh-Hans")
        if let current = configuration, current.source == from, current.target == to { configuration?.invalidate() }
        else { configuration = TranslationSession.Configuration(source: from, target: to) }
    }

    @MainActor private func refreshResources() async {
        let availability = LanguageAvailability()
        let zh = Locale.Language(identifier: "zh-Hans"), en = Locale.Language(identifier: "en")
        let forward = await availability.status(from: zh, to: en)
        let reverse = await availability.status(from: en, to: zh)
        forwardInstalled = forward == .installed; reverseInstalled = reverse == .installed
        forwardStatus = forwardInstalled ? "已安装" : (forward == .supported ? "尚未安装" : "当前系统不支持")
        reverseStatus = reverseInstalled ? "已安装" : (reverse == .supported ? "尚未安装" : "当前系统不支持")
    }

    private func save() {
        let keys = [modeKey.lowercased(), directionKey.lowercased()]
        guard keys.allSatisfy({ $0.utf8.count == 1 && $0.allSatisfy(\.isLetter) }),
              !(keys[0] == keys[1] && modeModifiers == directionModifiers) else {
            message = "请使用不同的英文字母快捷键。"; return
        }
        settings.ignoredWords = Set(ignored.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
        settings.excludedApplications = Set(excluded.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        settings.modeShortcut = Shortcut(key: keys[0], modifiers: modeModifiers)
        settings.directionShortcut = Shortcut(key: keys[1], modifiers: directionModifiers)
        do { try settings.save(); message = "已保存" }
        catch { message = "设置未保存，请检查磁盘和目录权限。" }
    }

    private func refreshRecords() {
        store.list { result in DispatchQueue.main.async {
            switch result {
            case .success(let items): records = items
            case .failure: message = "片段暂时无法读取，输入不受影响。"
            }
        } }
    }
}
