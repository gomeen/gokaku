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
    @NSApplicationDelegateAdaptor(SettingsAppDelegate.self) private var appDelegate
    var body: some Scene {
        Window("Gogaku 设置", id: "settings") {
            SettingsView().frame(minWidth: 1000, minHeight: 520, maxHeight: 800)
        }
        .defaultSize(width: 1100, height: 800)
        Window("检查更新", id: "updates") {
            UpdateView()
        }
        .defaultSize(width: 560, height: 480)
    }
}

private enum SettingsPage: String, CaseIterable, Identifiable {
    // 顺序即侧栏顺序：普通输入是核心高频页，排首位并作为默认落地页。
    case normalInput, resources, customWords, skin, shortcuts, privacy, records
    var id: Self { self }
    var title: String {
        switch self {
        case .resources: return "学习翻译"
        case .normalInput: return "普通输入"
        case .customWords: return "自定义词语"
        case .skin: return "皮肤"
        case .shortcuts: return "快捷键"
        case .privacy: return "学习与隐私"
        case .records: return "学习片段"
        }
    }
}

/// 设置外壳（对应原型 .shell--a）：200pt 文字侧栏、六页、页头 22/600、
/// 内容滚动区（水平内边距 26）、固定底部状态栏。侧栏选中态用 accent-soft 底＋
/// accent-text 文字（原型 .nav__item），无图标。立即保存：普通选项／应用列表／
/// 快捷键改动立即提交，连续文本输入合并 300ms，失焦或关闭窗口时提交剩余有效改动；
/// 保存状态由 SettingsStore 回调驱动。
private struct SettingsView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var updates = UpdateController.shared
    @State private var page: SettingsPage = .normalInput
    @State private var settings = Settings.load()
    @State private var status: SaveStatus = .idle
    @State private var records: [LearningEvent] = []
    @StateObject private var skinEditor = SkinEditorSession()
    private let store = LearningStore()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            // 侧栏右描边（.side { border-right: 1px solid var(--border) }）。
            Rectangle().fill(SettingsPalette.border).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                // 页面只保留标题（原型 .pagehead：22/600，padding 22 26 14）。
                if page != .skin {
                    Text(page.title).font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(SettingsPalette.primaryText)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.horizontal, 26)
                        .padding(.top, 22)
                        .padding(.bottom, 14)
                }
                if page == .skin {
                    SkinPage(settings: $settings, editor: skinEditor)
                        .padding(.horizontal, 36).padding(.top, 30).padding(.bottom, 18)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        switch page {
                        case .resources: ResourcesPage(settings: $settings)
                        case .normalInput: NormalInputPage(settings: $settings)
                        case .customWords: CustomWordsPage(status: $status)
                        case .skin: EmptyView()
                        case .shortcuts: ShortcutsPage(settings: $settings)
                        case .privacy: PrivacyPage(settings: $settings)
                        case .records: RecordsPage(records: $records) { refreshRecords() }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // .scroller：padding 2 26 18。
                    .padding(.horizontal, 26)
                    .padding(.bottom, 18)
                }
                .id(page)
                }
                statusBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(SettingsPalette.windowBackground)
        .background(SkinWindowGuard(editor: skinEditor).frame(width: 0, height: 0))
        .font(.system(size: 13))
        .tint(SettingsPalette.accent)
        .onAppear {
            SettingsAppDelegate.editor = skinEditor
            updates.startAutoLoop()
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

    // MARK: 侧栏（.side：side-bg 底、文字导航、底部版本）

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // .side__title：14/600，padding 18 16 10。
            Text("Gogaku")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SettingsPalette.primaryText)
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 10)
            // .nav：gap 1，padding 0 8。
            VStack(alignment: .leading, spacing: 1) {
                ForEach(SettingsPage.allCases) { item in
                    SidebarItem(title: item.title, isSelected: page == item) {
                        if page == .skin, item != .skin {
                            guard skinEditor.mayLeave() else { return }
                            skinEditor.discard()
                        }
                        page = item
                    }
                }
            }
            .padding(.horizontal, 8)
            .accessibilityElement(children: .contain)
            Spacer(minLength: 0)
            // .side__foot：meta 11 / ver mono 10，padding 12 16 14。
            VStack(alignment: .leading, spacing: 5) {
                Text("本机开发版")
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsPalette.secondaryText)
                Text(BuildIdentity.displayVersion)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(SettingsPalette.tertiaryText)
                Button {
                    openWindow(id: "updates")
                } label: {
                    HStack(spacing: 6) {
                        Text("检查更新")
                            .font(.system(size: 11))
                        if updates.hasUpdate {
                            Circle().fill(Color.green).frame(width: 6, height: 6)
                                .accessibilityLabel("有可用更新")
                        }
                    }
                    .foregroundStyle(SettingsPalette.accentText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(updates.hasUpdate ? "检查更新，有可用更新" : "检查更新")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 14)
        }
        .frame(width: 200)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(SettingsPalette.sidebarBackground)
    }

    /// 固定底部状态栏（.statusbar：min-height 36、win-bg 底、顶部 border 线、
    /// 圆点 7×7）：保存中／已保存／失败及重试。失败不伪报成功，不无限重试。
    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle().fill(status.dotColor)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(status.text.isEmpty ? "修改后立即生效" : status.text)
                .font(.system(size: 11))
                .foregroundStyle(SettingsPalette.secondaryText)
                .accessibilityLabel("保存状态：\(status.text.isEmpty ? "无待保存改动" : status.text)")
            Spacer(minLength: 8)
            if case .failed = status {
                Button("重试") {
                    SettingsStore.shared.retry()
                    status = .saving
                }
                .controlSize(.small)
                .accessibilityLabel("重试保存")
            }
        }
        .padding(.horizontal, 26)
        .frame(minHeight: 36)
        .background(SettingsPalette.windowBackground)
        .overlay(Rectangle().fill(SettingsPalette.border).frame(height: 1), alignment: .top)
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

/// 侧栏导航项（.nav__item：13px、padding 6 10、radius 6；选中 accent-soft 底＋
/// accent-text 文字＋600 字重，悬停中性灰底；无图标，与原型一致）。
private struct SidebarItem: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? SettingsPalette.accentText : SettingsPalette.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? SettingsPalette.accentSoft
                              : hovered ? Color.primary.opacity(0.13) : Color.clear))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityLabel(title)
    }
}

// MARK: - 学习翻译页（2026-11-06 双端统一计划：只保留火山 NMT，无本地模型）

private struct ResourcesPage: View {
    @Binding var settings: GogakuCore.Settings
    @State private var environment = LearningTranslation.Environment(ready: false, missing: [], hasCredentials: false)
    @State private var accessKey = ""
    @State private var secretKey = ""
    @State private var loadedAccessKey = ""
    @State private var loadedSecretKey = ""
    @State private var dirty = false
    @State private var testing = false
    @State private var testMessage: String?
    @State private var testIsError = false
    @State private var lastFailure: String?
    @State private var confirmingRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            translationSection
            SettingsRule()
            boundarySection
        }
        .onAppear {
            refreshEnvironment()
            loadCredentials()
        }
        .onChange(of: settings.learningTranslationEnabled) { _, _ in
            refreshEnvironment()
        }
        .confirmationDialog("移除已保存的火山翻译凭据？", isPresented: $confirmingRemoval) {
            Button("移除凭据", role: .destructive) {
                do {
                    try LearningTranslation.removeCredentials()
                    settings.learningTranslationEnabled = false
                    submit()
                    accessKey = ""; secretKey = ""
                    loadedAccessKey = ""; loadedSecretKey = ""
                    dirty = false
                    lastFailure = nil
                    testMessage = nil
                    refreshEnvironment()
                } catch {
                    lastFailure = "移除凭据失败：\(error.localizedDescription)"
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("移除后学习翻译会立即停用；已保存的设置与学习数据不受影响。")
        }
    }

    private var translationSection: some View {
        section("学习翻译") {
            VStack(alignment: .leading, spacing: 0) {
                SettingsRow("启用学习翻译",
                            detail: "关闭时普通输入完全离线；开启后学习模式会把源文发送到火山翻译 API。") {
                    Toggle("", isOn: Binding(get: { settings.learningTranslationEnabled },
                                             set: { settings.learningTranslationEnabled = $0; submit() }))
                        .toggleStyle(.switch)
                        .accessibilityLabel("启用学习翻译")
                }
                SettingsRowDivider()
                SettingsRow("状态") {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(environment.ready ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(statusText)
                            .font(.system(size: 12))
                            .foregroundStyle(SettingsPalette.primaryText)
                    }
                }
                if let lastFailure {
                    Text(lastFailure)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.red)
                        .padding(.bottom, 8)
                        .accessibilityLabel("最近一次翻译失败：\(lastFailure)")
                }
                SettingsRowDivider()
                credentialsBlock
                SettingsRowDivider()
                usageBlock
            }
        }
    }

    private var credentialsBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("火山翻译凭据")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SettingsPalette.primaryText)
                Text(environment.hasCredentials ? "已配置" : "未配置")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(environment.hasCredentials ? Color.green.opacity(0.12) : Color.orange.opacity(0.12))
                    .foregroundStyle(environment.hasCredentials ? Color.green : Color.orange)
                    .clipShape(Capsule())
            }
            .padding(.vertical, 12)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Access Key ID")
                        .font(.system(size: 11.5))
                        .foregroundStyle(SettingsPalette.secondaryText)
                    TextField("AKLT…", text: $accessKey)
                        .font(.system(size: 12, design: .monospaced))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(SettingsPalette.secondaryText.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(SettingsPalette.secondaryText.opacity(0.35), lineWidth: 1))
                        .onChange(of: accessKey) { _, _ in syncDirty() }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Secret Access Key")
                        .font(.system(size: 11.5))
                        .foregroundStyle(SettingsPalette.secondaryText)
                    SecureField("TWp…", text: $secretKey)
                        .font(.system(size: 12, design: .monospaced))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(SettingsPalette.secondaryText.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(SettingsPalette.secondaryText.opacity(0.35), lineWidth: 1))
                        .onChange(of: secretKey) { _, _ in syncDirty() }
                }
            }

            HStack(spacing: 10) {
                Button("保存凭据") {
                    do {
                        try LearningTranslation.saveCredentials(
                            VolcengineCredentials(accessKeyId: accessKey, secretAccessKey: secretKey))
                        loadedAccessKey = accessKey; loadedSecretKey = secretKey
                        dirty = false
                        lastFailure = nil
                        refreshEnvironment()
                    } catch {
                        lastFailure = "保存凭据失败：\(error.localizedDescription)"
                    }
                }
                .font(.system(size: 12))
                .buttonStyle(.borderedProminent)
                .tint(Color.green)
                .disabled(accessKey.isEmpty || secretKey.isEmpty || !dirty)

                Button(testing ? "测试中…" : "连接测试") {
                    runConnectionTest()
                }
                .font(.system(size: 12))
                .disabled(testing || dirty || (!environment.hasCredentials && (accessKey.isEmpty || secretKey.isEmpty)))

                if environment.hasCredentials {
                    Button("移除凭据", role: .destructive) { confirmingRemoval = true }
                        .font(.system(size: 12))
                }
                if dirty {
                    Text("有未保存修改")
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsPalette.secondaryText)
                }
            }
            .padding(.vertical, 12)

            if let testMessage {
                Text(testMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(testIsError ? Color.red : Color.green)
                    .padding(.bottom, 8)
                    .accessibilityLabel(testMessage)
            }

            HStack(spacing: 6) {
                Image(systemName: "lock.shield").font(.system(size: 11))
                Text("凭据仅写入本机 0600 文件，不进设置导出、主题包、日志或安装包。")
                    .font(.system(size: 11))
            }
            .foregroundStyle(Color.green)
            .background(Color.green.opacity(0.1))
            .padding(8)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            if !environment.ready {
                Text("缺失：\(environment.missing.joined(separator: "、"))。")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.orange)
                    .padding(.top, 8)
            }
        }
    }

    private var usageBlock: some View {
        let month = Self.currentMonthID()
        let used = settings.volcengineUsageMonth == month ? max(0, settings.volcengineUsageCharacters) : 0
        return VStack(alignment: .leading, spacing: 6) {
            Text("本机本月请求字符统计")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(SettingsPalette.primaryText)
            Text("\(used.formatted()) 字符 · \(month)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(SettingsPalette.primaryText)
            Text("仅统计本机成功请求；不代表账户余额或官方免费额度。失败请求不计入。")
                .font(.system(size: 11))
                .foregroundStyle(SettingsPalette.secondaryText)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var boundarySection: some View {
        section("行为与边界") {
            VStack(alignment: .leading, spacing: 8) {
                bullet("普通输入不需要网络，也不经过翻译进程。")
                bullet("只有学习模式且此开关开启时才发送学习源文；不会发送宿主周边正文、学习记录或设备标识。")
                bullet("翻译失败、超时、限流或凭据失效时保留可编辑输入，不自动提交原文、不弹窗打断；⌘Return 可明确原文上屏。")
                bullet("学习记录采集仍关闭；本页开关只保存学习翻译偏好，不解除记录门禁。")
                bullet("不随包本地模型或运行时；不再提供模型下载、后端选择或 beam。")
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text("·").foregroundStyle(SettingsPalette.secondaryText)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(SettingsPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusText: String {
        if !environment.ready {
            return environment.hasCredentials ? "凭据已配置，但翻译辅助进程缺失" : "未配置凭据"
        }
        return settings.learningTranslationEnabled ? "已启用（凭据已配置）" : "凭据已配置；学习翻译未启用"
    }

    private static func currentMonthID() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: Date())
    }

    private func refreshEnvironment() {
        environment = LearningTranslation.environment()
    }

    private func loadCredentials() {
        guard let credentials = LearningTranslation.credentials() else { return }
        accessKey = credentials.accessKeyId
        secretKey = credentials.secretAccessKey
        loadedAccessKey = credentials.accessKeyId
        loadedSecretKey = credentials.secretAccessKey
        dirty = false
    }

    private func syncDirty() {
        dirty = accessKey != loadedAccessKey || secretKey != loadedSecretKey
    }

    private func runConnectionTest() {
        testing = true
        testMessage = nil
        Task {
            do {
                let result = try await LearningTranslation.testConnection()
                await MainActor.run {
                    testing = false
                    testIsError = false
                    testMessage = "连接成功：译文「\(result.target)」· \(Int(result.milliseconds.rounded()))ms"
                    lastFailure = nil
                }
            } catch {
                await MainActor.run {
                    testing = false
                    testIsError = true
                    let message = LearningTranslation.connectionErrorMessage(error)
                    testMessage = "连接失败：\(message)"
                    lastFailure = message
                }
            }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SettingsPalette.primaryText)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func submit() {
        SettingsStore.shared.submit(settings)
    }
}

// MARK: - 学习与隐私页（原型为三个 section＋hr；排除应用按规格保留原生应用列表）

private struct PrivacyPage: View {
    @Binding var settings: GogakuCore.Settings
    @State private var ignored = ""
    @ObservedObject private var catalog = AppCatalog()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            section("学习记录") {
                SettingsRow("记录学习片段",
                            detail: "当前开发版尚未接通成功提交后的记录；此开关只保存偏好，不解除真实学习记录门禁，也不会开始采集。") {
                    Toggle("", isOn: Binding(get: { settings.recording },
                                             set: { settings.recording = $0; submit() }))
                        .toggleStyle(.switch)
                        .accessibilityLabel("记录学习片段，保留30天")
                }
            }
            SettingsRule()
            section("排除应用") {
                AppListEditor(mode: .excluded(ids: Binding(
                    get: { settings.excludedApplications },
                    set: { settings.excludedApplications = $0; submit() })),
                    emptyText: "尚未排除任何应用。",
                    addSheetTitle: "添加不记录学习内容的应用",
                    accessibilityPrefix: "学习记录排除",
                    catalog: catalog)
            }
            SettingsRule()
            section("英语忽略词") {
                ignoreEditor
            }
        }
        .onAppear { ignored = settings.ignoredWords.sorted().joined(separator: "\n") }
    }

    /// section 标题（.section__title：15/600）。
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SettingsPalette.primaryText)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    /// 忽略词文本域（原型 .textarea mono 四行＋占位「每行一个忽略词」）。
    private var ignoreEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: Binding(
                get: { ignored },
                set: { newValue in
                    ignored = newValue
                    applyIgnored()
                }))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(SettingsPalette.primaryText)
                .scrollContentBackground(.hidden)
                .background(SettingsPalette.cardBackground)
                .frame(height: 96)
                .padding(5)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(SettingsPalette.borderStrong, lineWidth: 1))
                .accessibilityLabel("英语忽略词，每行一个")
            if ignored.isEmpty {
                Text("每行一个忽略词")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(SettingsPalette.tertiaryText)
                    .padding(.horizontal, 11)
                    .padding(.top, 11)
                    .allowsHitTesting(false)
            }
        }
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

// MARK: - 学习片段页（真实存储读取；原型 listhead＋记录行＋出厂空状态）

private struct RecordsPage: View {
    @Binding var records: [LearningEvent]
    let onRefresh: () -> Void
    private let store = LearningStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // .listhead：标题与刷新按钮两端对齐。
            HStack {
                Text("最近的片段").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SettingsPalette.primaryText)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("刷新", action: onRefresh).controlSize(.small)
                    .accessibilityLabel("刷新学习片段")
            }
            .padding(.top, 2)
            if records.isEmpty {
                // .empty：虚线框空状态。
                VStack(spacing: 5) {
                    Image(systemName: "text.book.closed").font(.system(size: 26))
                        .foregroundStyle(SettingsPalette.tertiaryText)
                    Text("暂无学习片段").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(SettingsPalette.primaryText)
                    Text("已确认成功的学习内容会显示在这里。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(SettingsPalette.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(SettingsPalette.borderStrong,
                                      style: StrokeStyle(lineWidth: 1, dash: [4])))
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(records) { event in
                        recordRow(event)
                    }
                }
            }
        }
    }

    /// 记录行（原型 .rec：左 pair＋meta，右操作按钮）。
    private func recordRow(_ event: LearningEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(event.source + " → " + event.target)
                    .font(.system(size: 13))
                    .foregroundStyle(SettingsPalette.primaryText)
                    .textSelection(.enabled)
                Text("\(event.direction == .zhToEn ? "中→英" : "英→中") · \(event.category) · \(event.createdAt.formatted())")
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsPalette.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 4) {
                if !event.issues.isEmpty {
                    Button("排除此条误报") { store.dismissIssues(id: event.id) { _ in onRefresh() } }
                        .controlSize(.small)
                        .accessibilityLabel("排除此条误报：\(event.source)")
                }
                Button("删除片段") { store.delete(ids: [event.id]) { _ in onRefresh() } }
                    .controlSize(.small)
                    .accessibilityLabel("删除片段：\(event.source)")
            }
        }
        .padding(.vertical, 10)
    }
}
